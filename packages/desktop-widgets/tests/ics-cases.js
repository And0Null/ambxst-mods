// Checks the calendar layer's pure ICS reader: ics.js.
//
// ics.js is read as TEXT and evaluated here, minus its leading `.pragma library`
// line (a Quickshell directive, not valid JS). So this runs the SHIPPED code, not
// a restatement of it: if the widget's copy of the parser changes, this test
// either follows it or fails.
//
// Every expected value below is hand-written. Where the dates are worth arguing
// about (weekly INTERVAL/BYDAY, monthly BYMONTHDAY=31, yearly on Feb 29) they were
// cross-checked against a different implementation, python3 + dateutil; see the
// report that accompanies this file. Nothing here computes its own expectations.
//
// The whole run is forced into America/Bogota (UTC-5, no DST), because half of
// these cases are about converting an instant into local wall clock. The harness
// re-executes itself under that TZ, so a bare `node tests/ics-cases.js` is
// always correct regardless of the shell's zone.
//
// node tests/ics-cases.js
"use strict";

const fs = require("fs"), path = require("path"), vm = require("vm"), cp = require("child_process");

// --- force the zone before anything reads a Date ----------------------------
if (process.env.TZ !== "America/Bogota") {
  const r = cp.spawnSync(process.execPath, [__filename], {
    env: Object.assign({}, process.env, { TZ: "America/Bogota" }),
    stdio: "inherit"
  });
  process.exit(r.status === null ? 1 : r.status);
}

const ICS = path.join(__dirname, "..", "overlays/modules/widgets/desktopwidgets/ics.js");
const SRC = fs.readFileSync(ICS, "utf8");
if (!/^\.pragma\s+library\s*\n/.test(SRC))
  throw new Error("ics.js no longer starts with a bare `.pragma library` line; fix the strip below");
const JS = SRC.replace(/^\.pragma\s+library\s*\n/, "");
if (/^[ \t]*\.pragma\s+library\s*$/m.test(JS)) throw new Error("a second .pragma line survived the strip");

const ctx = vm.createContext({});
vm.runInContext(JS, ctx, { filename: ICS });
const Ics = ctx;

for (const fn of ["parse", "parseErrors", "occurrences", "dayKey", "dayKeyToMs", "groupByDay"])
  if (typeof Ics[fn] !== "function") throw new Error("ics.js is missing the function " + fn);

// --- helpers (formatters and fixture builders, never expectation generators) --
const pad = (n) => String(n).padStart(2, "0");
const stamp = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
const at = (y, mo, d, h, mi) => new Date(y, mo - 1, d, h || 0, mi || 0, 0, 0).getTime();
const stamps = (list) => list.map((o) => stamp(o.startMs));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const CRLF = "\r\n", LF = "\n", BS = "\\";
const ics = (body, nl) =>
  ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//ambxst//ics-test//EN", "BEGIN:VEVENT"]
    .concat(body).concat(["END:VEVENT", "END:VCALENDAR"]).join(nl || CRLF) + (nl || CRLF);
const parse1 = (body, nl) => Ics.parse(ics(body, nl))[0];
const parseN = (body, nl) => Ics.parse(ics(body, nl));
const occ = (body, from, to, nl) => Ics.occurrences(parseN(body, nl), from, to);

const lines = [], fails = [];
const check = (ok, msg) => { lines.push(`  ${ok ? "OK  " : "FAIL"} ${msg}`); if (!ok) fails.push(msg); };
const section = (name) => lines.push("", name);

// ===========================================================================
section("1. timed events: Z is UTC, TZID is treated as local");
{
  const e = parse1([
    "UID:z-1",
    "DTSTART:20260115T170000Z",
    "DTEND:20260115T180000Z",
    "SUMMARY:Standup"
  ]);
  check(e.startMs === at(2026, 1, 15, 12, 0), "17:00Z lands at 12:00 local (UTC-5): " + stamp(e.startMs));
  check(e.endMs === at(2026, 1, 15, 13, 0), "18:00Z ends at 13:00 local: " + stamp(e.endMs));
  check(e.allDay === false && e.rrule === null && e.exdates.length === 0, "not all-day, no rule, no exdates");

  const t = parse1([
    "UID:tz-1",
    "DTSTART;TZID=America/New_York:20260115T090000",
    "DTEND;TZID=America/New_York:20260115T100000",
    "SUMMARY:Wall clock"
  ]);
  check(t.startMs === at(2026, 1, 15, 9, 0), "TZID wall clock is read as local 09:00: " + stamp(t.startMs));
  check(t.endMs === at(2026, 1, 15, 10, 0), "and its DTEND too: " + stamp(t.endMs));

  const f = parse1(["UID:float-1", "DTSTART:20260115T083000", "SUMMARY:Floating"]);
  check(f.startMs === at(2026, 1, 15, 8, 30), "no Z and no TZID is floating local: " + stamp(f.startMs));
  check(f.endMs === f.startMs, "a timed event with no DTEND is a point in time");
}

// ===========================================================================
section("2. all-day events: local midnight, exclusive DTEND");
{
  const one = parse1(["UID:d-1", "DTSTART;VALUE=DATE:20260310", "SUMMARY:Holiday"]);
  check(one.startMs === at(2026, 3, 10, 0, 0), "single all-day starts at local midnight: " + stamp(one.startMs));
  check(one.endMs === at(2026, 3, 11, 0, 0), "and ends at the NEXT local midnight (exclusive): " + stamp(one.endMs));
  check(one.allDay === true, "flagged all-day");

  const multi = parse1([
    "UID:d-2",
    "DTSTART;VALUE=DATE:20260310",
    "DTEND;VALUE=DATE:20260313",
    "SUMMARY:Conference"
  ]);
  check(multi.endMs === at(2026, 3, 13, 0, 0), "DTEND;VALUE=DATE:20260313 is exclusive -> " + stamp(multi.endMs));
  check((multi.endMs - multi.startMs) / 86400000 === 3, "spans 3 days, not 4");

  const bare = parse1(["UID:d-3", "DTSTART:20260310", "SUMMARY:Bare date"]);
  check(bare.allDay === true && bare.endMs === at(2026, 3, 11, 0, 0),
    "an 8-digit DTSTART with no VALUE=DATE is still all-day: " + stamp(bare.startMs));
}

// ===========================================================================
section("3. folded lines, escaped text, property parameters");
{
  // Physical line 1 ends after "plan"; line 2 begins with a space, so unfolding
  // deletes that space and the word closes back up into "planning".
  const folded = "SUMMARY;LANGUAGE=en:Team sync" + BS + ", plan" + CRLF +
                 " ning" + BS + "; and lunch" + BS + "nwith Ana";
  const e = parse1([
    "UID:fold-1",
    "DTSTART:20260401T100000",
    "DTEND:20260401T110000",
    folded,
    "LOCATION:Room 3" + BS + ", floor 2 " + BS + "; wing B " + BS + BS + " near the lift"
  ]);
  check(e.summary === "Team sync, planning; and lunch\nwith Ana",
    "fold rejoined and \\, \\; \\n unescaped -> " + JSON.stringify(e.summary));
  check(e.location === "Room 3, floor 2 ; wing B " + BS + " near the lift",
    "location \\\\ is one backslash -> " + JSON.stringify(e.location));

  const params = parse1([
    "UID:p-1",
    "DTSTART;VALUE=DATE;X-MICROSOFT-CDO-BUSYSTATUS=FREE:20260402",
    "X-MICROSOFT-CDO-ALLDAYEVENT:TRUE",
    'SUMMARY;LANGUAGE="en:GB":Quoted colon'
  ]);
  check(params.startMs === at(2026, 4, 2, 0, 0),
    "extra parameters after VALUE=DATE are skipped when splitting name:value");
  check(params.summary === "Quoted colon",
    "a colon inside a quoted parameter value does not split the line: " + JSON.stringify(params.summary));
}

// ===========================================================================
section("4. WEEKLY;BYDAY=MO,WE;INTERVAL=2;COUNT=6");
{
  const body = [
    "UID:w-1",
    "DTSTART:20260105T090000",
    "DTEND:20260105T100000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2;COUNT=6",
    "SUMMARY:Pairing"
  ];
  const got = stamps(occ(body, at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0)));
  const want = ["2026-01-05T09:00", "2026-01-07T09:00", "2026-01-19T09:00",
                "2026-01-21T09:00", "2026-02-02T09:00", "2026-02-04T09:00"];
  check(same(got, want), "every second week, Mon+Wed, 6 of them: " + got.join(" "));

  const o = occ(body, at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0));
  check(o.length === 6 && o.every((x) => x.recurring === true), "all six are flagged recurring");
  check(o.every((x) => x.endMs - x.startMs === 3600000), "each instance keeps the 1h duration");
  check(o.every((x) => x.uid === "w-1" && x.summary === "Pairing"), "instances carry uid and summary");
  check(o[0].startMs <= o[1].startMs && o[4].startMs <= o[5].startMs, "ascending by startMs");
}

// ===========================================================================
section("5. DAILY;UNTIL, in both a UTC and a floating value");
{
  // 20260205T080000Z is 03:00 local, so the 08:00 instance on Feb 5 is already
  // past it: four occurrences, not five.
  const z = stamps(occ(["UID:u-z", "DTSTART:20260201T080000",
    "RRULE:FREQ=DAILY;UNTIL=20260205T080000Z", "SUMMARY:Z until"],
    at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0)));
  check(same(z, ["2026-02-01T08:00", "2026-02-02T08:00", "2026-02-03T08:00", "2026-02-04T08:00"]),
    "UNTIL with Z is an instant, so Feb 5 08:00 local is excluded: " + z.join(" "));

  const f = stamps(occ(["UID:u-f", "DTSTART:20260201T080000",
    "RRULE:FREQ=DAILY;UNTIL=20260205T080000", "SUMMARY:float until"],
    at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0)));
  check(same(f, ["2026-02-01T08:00", "2026-02-02T08:00", "2026-02-03T08:00",
                 "2026-02-04T08:00", "2026-02-05T08:00"]),
    "UNTIL without Z is local and inclusive: " + f.join(" "));

  const i = stamps(occ(["UID:u-i", "DTSTART:20260201T080000",
    "RRULE:FREQ=DAILY;INTERVAL=3;COUNT=3", "SUMMARY:every third day"],
    at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0)));
  check(same(i, ["2026-02-01T08:00", "2026-02-04T08:00", "2026-02-07T08:00"]),
    "INTERVAL=3 steps three days at a time: " + i.join(" "));
}

// ===========================================================================
section("6. MONTHLY;BYMONTHDAY=31 skips the short months");
{
  const got = stamps(occ(["UID:m-31", "DTSTART:20260131T100000",
    "RRULE:FREQ=MONTHLY;BYMONTHDAY=31", "SUMMARY:Month end"],
    at(2026, 1, 1, 0, 0), at(2028, 1, 1, 0, 0)));
  const want = ["2026-01-31T10:00", "2026-03-31T10:00", "2026-05-31T10:00", "2026-07-31T10:00",
                "2026-08-31T10:00", "2026-10-31T10:00", "2026-12-31T10:00", "2027-01-31T10:00",
                "2027-03-31T10:00", "2027-05-31T10:00", "2027-07-31T10:00", "2027-08-31T10:00",
                "2027-10-31T10:00", "2027-12-31T10:00"];
  check(same(got, want), "Feb, Apr, Jun, Sep and Nov are all skipped: " + got.length + " in two years");
  check(got.indexOf("2026-02-31T10:00") < 0 && got.every((s) => s.slice(8, 10) === "31"),
    "every instance really is a 31st");

  const neg = stamps(occ(["UID:m-neg", "DTSTART:20260131T100000",
    "RRULE:FREQ=MONTHLY;BYMONTHDAY=-1", "SUMMARY:Last day"],
    at(2026, 1, 1, 0, 0), at(2026, 5, 1, 0, 0)));
  check(same(neg, ["2026-01-31T10:00", "2026-02-28T10:00", "2026-03-31T10:00", "2026-04-30T10:00"]),
    "BYMONTHDAY=-1 is the last day of each month: " + neg.join(" "));

  const bare = stamps(occ(["UID:m-bare", "DTSTART:20260131T100000",
    "RRULE:FREQ=MONTHLY", "SUMMARY:No BY*"],
    at(2026, 1, 1, 0, 0), at(2026, 5, 1, 0, 0)));
  check(same(bare, ["2026-01-31T10:00", "2026-03-31T10:00"]),
    "MONTHLY with no BY* skips the months that have no 31st: " + bare.join(" "));
}

// ===========================================================================
section("7. YEARLY, including the Feb 29 problem");
{
  const got = stamps(occ(["UID:y-leap", "DTSTART:20240229T080000",
    "RRULE:FREQ=YEARLY", "SUMMARY:Leap day"],
    at(2024, 1, 1, 0, 0), at(2037, 1, 1, 0, 0)));
  check(same(got, ["2024-02-29T08:00", "2028-02-29T08:00", "2032-02-29T08:00", "2036-02-29T08:00"]),
    "only the leap years get an instance: " + got.join(" "));

  const plain = stamps(occ(["UID:y-plain", "DTSTART:20260315T120000",
    "RRULE:FREQ=YEARLY;COUNT=3", "SUMMARY:Anniversary"],
    at(2026, 1, 1, 0, 0), at(2031, 1, 1, 0, 0)));
  check(same(plain, ["2026-03-15T12:00", "2027-03-15T12:00", "2028-03-15T12:00"]),
    "plain yearly repeats on the same day: " + plain.join(" "));

  // An ordinal BYDAY on a monthly rule: the last Friday of every month.
  const nth = stamps(occ(["UID:m-nth", "DTSTART:20260130T170000",
    "RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=6", "SUMMARY:Last Friday"],
    at(2026, 1, 1, 0, 0), at(2027, 1, 1, 0, 0)));
  check(same(nth, ["2026-01-30T17:00", "2026-02-27T17:00", "2026-03-27T17:00",
                   "2026-04-24T17:00", "2026-05-29T17:00", "2026-06-26T17:00"]),
    "BYDAY=-1FR is the last Friday of each month: " + nth.join(" "));
  check(nth.every((s) => new Date(Ics.dayKeyToMs(s.slice(0, 10)) + 17 * 3600000).getDay() === 5),
    "every one of them really is a Friday");
}

// ===========================================================================
section("8. EXDATE removes an instance, RDATE adds one");
{
  const got = stamps(occ(["UID:ex-1", "DTSTART:20260105T090000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6",
    "EXDATE:20260107T090000", "SUMMARY:No Wednesday"],
    at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0)));
  check(same(got, ["2026-01-05T09:00", "2026-01-12T09:00", "2026-01-14T09:00",
                   "2026-01-19T09:00", "2026-01-21T09:00"]),
    "the Jan 7 instance is gone, the other five stay (COUNT still counts it): " + got.join(" "));

  const two = stamps(occ(["UID:ex-2", "DTSTART:20260105T090000",
    "RRULE:FREQ=DAILY;COUNT=4",
    "EXDATE:20260106T090000", "EXDATE:20260107T090000", "SUMMARY:Two out"],
    at(2026, 1, 1, 0, 0), at(2026, 2, 1, 0, 0)));
  check(same(two, ["2026-01-05T09:00", "2026-01-08T09:00"]),
    "two EXDATE lines both apply: " + two.join(" "));

  const allday = stamps(occ(["UID:ex-3", "DTSTART;VALUE=DATE:20260105",
    "RRULE:FREQ=DAILY;COUNT=3", "EXDATE;VALUE=DATE:20260106", "SUMMARY:Date exdate"],
    at(2026, 1, 1, 0, 0), at(2026, 2, 1, 0, 0)));
  check(same(allday, ["2026-01-05T00:00", "2026-01-07T00:00"]),
    "EXDATE;VALUE=DATE removes an all-day instance: " + allday.join(" "));

  const o = Ics.occurrences(parseN(["UID:rd-1", "DTSTART:20260504T140000",
    "DTEND:20260504T150000", "RDATE:20260511T140000,20260518T140000", "SUMMARY:Extras"]),
    at(2026, 5, 1, 0, 0), at(2026, 6, 1, 0, 0));
  check(same(stamps(o), ["2026-05-04T14:00", "2026-05-11T14:00", "2026-05-18T14:00"]),
    "RDATE adds two more dates: " + stamps(o).join(" "));
  check(o[0].recurring === false && o[1].recurring === true && o[2].recurring === true,
    "the DTSTART instance is not recurring, the RDATE ones are");
  check(o.every((x) => x.endMs - x.startMs === 3600000), "RDATE instances reuse the event's duration");
}

// ===========================================================================
section("9. DURATION instead of DTEND");
{
  const h = parse1(["UID:du-1", "DTSTART:20260610T090000", "DURATION:PT1H30M", "SUMMARY:Review"]);
  check(h.endMs === at(2026, 6, 10, 10, 30), "PT1H30M ends 90 minutes later: " + stamp(h.endMs));

  const m = parse1(["UID:du-2", "DTSTART:20260610T090000", "DURATION:PT45M", "SUMMARY:Call"]);
  check(m.endMs === at(2026, 6, 10, 9, 45), "PT45M ends 45 minutes later: " + stamp(m.endMs));

  const d = parse1(["UID:du-3", "DTSTART;VALUE=DATE:20260612", "DURATION:P2W", "SUMMARY:Fortnight"]);
  check(d.endMs === at(2026, 6, 26, 0, 0), "P2W is 14 days from local midnight: " + stamp(d.endMs));
  check((d.endMs - d.startMs) / 86400000 === 14, "and spans exactly 14 days");

  const d1 = parse1(["UID:du-4", "DTSTART;VALUE=DATE:20260612", "DURATION:P1D", "SUMMARY:One day"]);
  check(d1.endMs === at(2026, 6, 13, 0, 0), "P1D on an all-day event ends at the next midnight");

  const r = parse1(["UID:du-5", "DTSTART:20260610T090000", "DURATION:PT1H",
    "RRULE:FREQ=DAILY;COUNT=2", "SUMMARY:Recurring with duration"]);
  const ro = Ics.occurrences([r], at(2026, 6, 1, 0, 0), at(2026, 7, 1, 0, 0));
  check(ro.length === 2 && ro[1].endMs === at(2026, 6, 11, 10, 0),
    "a recurring event keeps its duration on later instances: " + stamps(ro).join(" "));
}

// ===========================================================================
section("10. junk in the file: VTODO, VTIMEZONE, VJOURNAL, VALARM, unknown props");
{
  const file = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//ambxst//ics-test//EN",
    "BEGIN:VTIMEZONE",
    "TZID:America/Bogota",
    "BEGIN:STANDARD",
    "DTSTART:19700101T000000",
    "TZOFFSETFROM:-0500",
    "TZOFFSETTO:-0500",
    "END:STANDARD",
    "END:VTIMEZONE",
    "BEGIN:VTODO",
    "UID:todo-1",
    "DTSTART:20260401T090000",
    "SUMMARY:Buy milk",
    "END:VTODO",
    "BEGIN:VEVENT",
    "UID:keep-1",
    "DTSTART:20260401T100000",
    "DTEND:20260401T110000",
    "SUMMARY:Real event",
    "X-APPLE-TRAVEL-DURATION:PT15M",
    "X-UNKNOWN-PROPERTY;X-PARAM=1:whatever",
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    "TRIGGER:-PT10M",
    "SUMMARY:Alarm!",
    "END:VALARM",
    "END:VEVENT",
    "BEGIN:VJOURNAL",
    "UID:j-1",
    "DTSTART:20260402T090000",
    "SUMMARY:Journal",
    "END:VJOURNAL",
    "END:VCALENDAR"
  ].join(CRLF) + CRLF;

  const evts = Ics.parse(file);
  check(evts.length === 1, "exactly one VEVENT comes out, got " + evts.length);
  check(evts[0].uid === "keep-1" && evts[0].summary === "Real event",
    "and it is the real one: " + evts[0].uid + " / " + JSON.stringify(evts[0].summary));
  check(evts[0].startMs === at(2026, 4, 1, 10, 0),
    "VTIMEZONE's DTSTART:19700101 did not become an event: " + stamp(evts[0].startMs));
  check(evts.errors.length === 0, "nothing was reported as skipped: " + JSON.stringify(evts.errors));
}

// ===========================================================================
section("11. window clipping of a multi-year rule");
{
  const body = ["UID:long-1", "DTSTART:20260101T090000",
    "RRULE:FREQ=DAILY;UNTIL=20310101T000000Z", "SUMMARY:Daily standup"];
  const june = stamps(occ(body, at(2029, 6, 1, 0, 0), at(2029, 6, 30, 23, 59)));
  check(june.length === 30, "30 days of June 2029, out of ~1800 in the rule: got " + june.length);
  check(june[0] === "2029-06-01T09:00" && june[29] === "2029-06-30T09:00",
    "clipped to the window's own days: " + june[0] + " .. " + june[29]);

  const oneDay = stamps(occ(body, at(2029, 6, 15, 0, 0), at(2029, 6, 15, 23, 59)));
  check(same(oneDay, ["2029-06-15T09:00"]), "a one-day window gets exactly one instance");

  const past = stamps(occ(body, at(2027, 3, 1, 0, 0), at(2027, 3, 3, 23, 59)));
  check(same(past, ["2027-03-01T09:00", "2027-03-02T09:00", "2027-03-03T09:00"]),
    "a window years after DTSTART still counts from the beginning: " + past.join(" "));

  const after = occ(body, at(2035, 1, 1, 0, 0), at(2036, 1, 1, 0, 0));
  check(after.length === 0, "a window past UNTIL yields nothing");

  const before = occ(body, at(2025, 1, 1, 0, 0), at(2025, 12, 31, 23, 59));
  check(before.length === 0, "a window before DTSTART yields nothing");

  // The bound must hold even when the rule asks for more than the cap allows.
  const t0 = Date.now();
  const huge = occ(["UID:cap-1", "DTSTART:20260101T090000",
    "RRULE:FREQ=DAILY;COUNT=99999", "SUMMARY:Forever"],
    at(2026, 1, 1, 0, 0), at(2126, 1, 1, 0, 0));
  const ms = Date.now() - t0;
  check(huge.length === 2000, "a COUNT=99999 daily rule is capped at 2000 instances: got " + huge.length);
  check(ms < 2000, "and the cap keeps the expansion from stalling the UI thread (" + ms + "ms)");

  // Non-recurring events in the window come along, mixed into the same ordering.
  const mixed = Ics.occurrences(parseN(["UID:single-1", "DTSTART:20290610T150000", "SUMMARY:One off"])
    .concat([{ uid: "rec-1", summary: "Daily", location: "", startMs: at(2029, 6, 9, 9, 0),
               endMs: at(2029, 6, 9, 9, 30), allDay: false,
               rrule: { freq: "DAILY", interval: 1, count: 2, until: null, byday: null, bymonthday: null },
               exdates: [], rdates: [] }]),
    at(2029, 6, 9, 0, 0), at(2029, 6, 11, 0, 0));
  check(same(stamps(mixed), ["2029-06-09T09:00", "2029-06-10T09:00", "2029-06-10T15:00"]),
    "recurring and non-recurring instances sort together by startMs: " + stamps(mixed).join(" "));
}

// ===========================================================================
section("12. CRLF and LF are the same file");
{
  const body = ["UID:nl-1", "DTSTART:20260105T090000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2;COUNT=6", "SUMMARY:Newlines"];
  const crlf = stamps(occ(body, at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0), CRLF));
  const lf = stamps(occ(body, at(2026, 1, 1, 0, 0), at(2026, 3, 1, 0, 0), LF));
  check(same(crlf, lf) && crlf.length === 6, "same six instances either way: " + lf.join(" "));

  const foldedLf = "SUMMARY:Two" + LF + " lines";
  const e = parse1(["UID:nl-2", "DTSTART:20260105T090000", foldedLf], LF);
  check(e.summary === "Twolines", "a fold after a bare LF also rejoins: " + JSON.stringify(e.summary));

  const mixed = "BEGIN:VCALENDAR" + LF + "BEGIN:VEVENT" + CRLF + "UID:nl-3" + LF +
                "DTSTART:20260105T090000" + CRLF + "SUMMARY:Mixed" + LF +
                "END:VEVENT" + CRLF + "END:VCALENDAR" + LF;
  check(Ics.parse(mixed).length === 1 && Ics.parse(mixed)[0].summary === "Mixed",
    "a file with both line endings parses");
}

// ===========================================================================
section("13. dayKey() around local midnight");
{
  check(Ics.dayKey(at(2026, 1, 15, 0, 0)) === "2026-01-15", "local midnight is that day");
  check(Ics.dayKey(at(2026, 1, 15, 0, 0) - 1) === "2026-01-14", "one ms before midnight is the day before");
  check(Ics.dayKey(at(2026, 1, 15, 23, 59)) === "2026-01-15", "23:59 is still that day");
  check(Ics.dayKey(at(2026, 1, 15, 23, 59, 0) + 59999) === "2026-01-15", "23:59:59.999 is still that day");
  check(Ics.dayKey(Date.UTC(2026, 0, 1, 4, 59, 59)) === "2025-12-31",
    "04:59:59Z is 23:59:59 local on Dec 31: " + Ics.dayKey(Date.UTC(2026, 0, 1, 4, 59, 59)));
  check(Ics.dayKey(Date.UTC(2026, 0, 1, 5, 0, 0)) === "2026-01-01",
    "05:00:00Z is local midnight on Jan 1: " + Ics.dayKey(Date.UTC(2026, 0, 1, 5, 0, 0)));
  check(Ics.dayKey(at(2026, 12, 31, 23, 59)) === "2026-12-31", "the year boundary holds");
  check(Ics.dayKey(at(2026, 3, 10, 0, 0) - 1) === "2026-03-09", "and a DST-free month boundary holds");

  check(Ics.dayKeyToMs("2026-01-15") === at(2026, 1, 15, 0, 0), "dayKeyToMs round-trips a key");
  check(Ics.dayKey(Ics.dayKeyToMs("2026-01-15")) === "2026-01-15", "and dayKey(dayKeyToMs(k)) === k");
  check(Ics.dayKeyToMs("nonsense") === null, "an invalid key is null, not NaN");

  const grouped = Ics.groupByDay(parseN(["UID:g-1", "DTSTART:20260310T090000",
    "RRULE:FREQ=DAILY;COUNT=3", "SUMMARY:Three days"]), at(2026, 3, 1, 0, 0), at(2026, 4, 1, 0, 0));
  check(Object.keys(grouped).length === 3 && grouped["2026-03-11"] && grouped["2026-03-11"].length === 1,
    "groupByDay gives one bucket per covered day: " + Object.keys(grouped).join(" "));
}

// ===========================================================================
section("13b. groupByDay dots every day an occurrence COVERS");
{
  // A three-day all-day event: DTEND is exclusive, so 25/26/27 light up and 28 does not.
  const trip = Ics.groupByDay(parseN(["UID:span-1", "DTSTART;VALUE=DATE:20260925",
    "DTEND;VALUE=DATE:20260928", "SUMMARY:Trip"]), at(2026, 9, 1, 0, 0), at(2026, 10, 1, 0, 0));
  check(same(Object.keys(trip).sort(), ["2026-09-25", "2026-09-26", "2026-09-27"]),
    "a 25->28 all-day event dots the 25th, 26th and 27th and not the 28th: " + Object.keys(trip).sort().join(" "));
  check(trip["2026-09-26"][0].startMs === at(2026, 9, 25, 0, 0),
    "and the dot still points at the event's real start");

  // An event that crosses local midnight dots both nights.
  const night = Ics.groupByDay(parseN(["UID:span-2", "DTSTART:20260920T230000",
    "DTEND:20260921T010000", "SUMMARY:Flight"]), at(2026, 9, 1, 0, 0), at(2026, 10, 1, 0, 0));
  check(same(Object.keys(night).sort(), ["2026-09-20", "2026-09-21"]),
    "a 23:00->01:00 event dots both days: " + Object.keys(night).sort().join(" "));

  // A point-in-time event dots exactly one day.
  const point = Ics.groupByDay(parseN(["UID:span-3", "DTSTART:20260920T230000", "SUMMARY:Point"]),
    at(2026, 9, 1, 0, 0), at(2026, 10, 1, 0, 0));
  check(same(Object.keys(point), ["2026-09-20"]), "a zero-length event dots one day only");

  // An event already running when the window opens still dots the days inside it.
  const running = Ics.groupByDay(parseN(["UID:span-4", "DTSTART;VALUE=DATE:20260920",
    "DTEND;VALUE=DATE:20260925", "SUMMARY:Running"]), at(2026, 9, 22, 0, 0), at(2026, 9, 30, 0, 0));
  check(same(Object.keys(running).sort(), ["2026-09-22", "2026-09-23", "2026-09-24"]),
    "a trip already under way dots only the days inside the window: " + Object.keys(running).sort().join(" "));

  // A multi-day event never leaves the window: nothing outside [from, to] is bucketed.
  const clipped = Ics.groupByDay(parseN(["UID:span-5", "DTSTART;VALUE=DATE:20260910",
    "DTEND;VALUE=DATE:20261005", "SUMMARY:Long"]), at(2026, 9, 15, 0, 0), at(2026, 9, 17, 0, 0));
  check(same(Object.keys(clipped).sort(), ["2026-09-15", "2026-09-16", "2026-09-17"]),
    "a 25-day event is clipped to the window it is asked about: " + Object.keys(clipped).sort().join(" "));
}

// ===========================================================================
section("14. malformed input never throws, and says what it skipped");
{
  let threw = null, res = null;
  try {
    res = Ics.parse("this is not an ics file at all\nrandom words\n:BEGIN\nBEGIN:VEVENT\n" +
                    "SUMMARY:No DTSTART here\nEND:VEVENT\n" +
                    "BEGIN:VEVENT\nUID:ok-1\nDTSTART:not-a-date\nEND:VEVENT\n" +
                    "BEGIN:VEVENT\nUID:ok-2\nDTSTART:20260101T000000\n" +
                    "RRULE:FREQ=HOURLY;COUNT=3\nEND:VEVENT\n" +
                    "BEGIN:VEVENT\nUID:ok-3\nDTSTART:20260101T000000\nDURATION:banana\nEND:VEVENT");
  } catch (e) { threw = e; }
  check(threw === null, "parse() did not throw on garbage" + (threw ? ": " + threw.message : ""));
  check(res.length === 2, "the two usable VEVENTs survived, got " + res.length);
  check(res[0].uid === "ok-2" && res[0].rrule === null,
    "an unsupported FREQ keeps the event as a single instance instead of dropping it");
  check(res[0].endMs === res[0].startMs, "and it keeps a sane (point) end");
  check(res[1].uid === "ok-3" && res[1].endMs === res[1].startMs,
    "an unparseable DURATION leaves a point-in-time event");
  check(Array.isArray(res.errors) && res.errors.length >= 3,
    "the skipped bits are listed on parse().errors (" + res.errors.length + "): " + JSON.stringify(res.errors.slice(0, 3)));
  check(Ics.parseErrors("junk").errors.length >= 1, "parseErrors() reports the same way");
  check(Ics.parse(null).length === 0 && Ics.parse("").length === 0, "null and empty input give an empty list");
  check(Ics.occurrences(null, 0, 1).length === 0 && Ics.occurrences([], 0, 1).length === 0,
    "occurrences() tolerates a missing or empty list");

  // A rule that could loop forever is bounded, not hung.
  const t0 = Date.now();
  const hostile = Ics.occurrences(parseN(["UID:h-1", "DTSTART:20260101T000000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO;INTERVAL=0;COUNT=100000;BYMONTHDAY=99;BYSETPOS=3;WKST=SU",
    "SUMMARY:Hostile"]), at(2026, 1, 1, 0, 0), at(2100, 1, 1, 0, 0));
  const ms = Date.now() - t0;
  check(hostile.length <= 2000 && ms < 2000,
    "a hostile rule (INTERVAL=0, unknown keys) is bounded in " + ms + "ms, " + hostile.length + " instances");
}

// ===========================================================================
console.log("ics.js: parse + recurrences, under TZ=" + process.env.TZ +
            " (offset " + (-new Date(2026, 0, 15).getTimezoneOffset() / 60) + "h)");
console.log(lines.join("\n"));
console.log("");
if (fails.length) {
  console.log(`RESULTADO: FAIL (${fails.length} de ${fails.length + lines.filter((l) => l.indexOf("  OK  ") === 0).length})`);
  process.exit(1);
}
console.log(`RESULTADO: PASS — ${lines.filter((l) => l.indexOf("  OK  ") === 0).length} checks`);
