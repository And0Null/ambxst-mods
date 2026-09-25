.pragma library

// ---------------------------------------------------------------------------
// ics.js — a pure iCalendar reader for the desktop widgets' calendar layer.
//
// WHY THIS FILE EXISTS
// The calendar widget needs two things the rest of the shell cannot hand it: dots
// on the days that carry events, and an agenda list for the days it is showing.
// Both come out of an ICS feed, which is a text format with three traps:
//   1. lines are FOLDED, so a SUMMARY can be cut mid-word across two physical
//      lines and only rejoins if you undo the fold first;
//   2. a date arrives in one of three flavours (trailing Z = UTC, TZID = some
//      other zone's wall clock, neither = floating local) and the widget only
//      ever speaks local milliseconds;
//   3. an RRULE turns one VEVENT into an unbounded stream of instances, and a
//      hostile or malformed rule must never be able to freeze the UI thread.
//
// This file is deliberately dependency-free: no Qt, no QML types, no imports, no
// I/O, no globals beyond its own. It is imported by the widget as
// `import "ics.js" as Ics`, and tests/ics-cases.js runs THIS SAME FILE by reading
// it as text, stripping the `.pragma library` line (a Quickshell directive, not
// JS) and evaluating the rest in a fresh vm context. That is why nothing below
// may touch `console`, `require`, `Date.now()` at load time, or any host object:
// doing so would stop the test from exercising the shipped code.
//
// DOCUMENTED LIMITATIONS — deliberate, they keep the file small and honest:
//   * TZID is NOT resolved. A `TZID=...` wall-clock time is treated as LOCAL
//     time, and VTIMEZONE blocks are stepped over. This feed is read on one
//     machine in one zone; carrying a zone database to re-derive what the
//     server already told us is not worth the bytes.
//   * WKST is ignored. Weeks are anchored to Monday, the RFC 5545 default.
//   * BYDAY with a leading ordinal is honoured for MONTHLY/YEARLY only; a plain
//     weekday list (the weekly case) is the one that matters in practice.
//   * Expansion is BOUNDED: at most MAX_OCCURRENCES per event, at most
//     MAX_ITERATIONS loop steps, and never more than HORIZON_MS past DTSTART.
//     A rule that would run forever gets truncated, never hung.
//   * EXDATE matches an instance by exact startMs. A feed that writes an EXDATE
//     in a different zone flavour than its DTSTART will not match; that is the
//     honest consequence of not resolving zones.
//
// PUBLIC API
//   parse(text)                        -> events[]; see the shape below. The
//                                         returned array also carries `.errors`.
//   parseErrors(text)                  -> { events, errors } for diagnostics.
//   occurrences(events, fromMs, toMs)  -> occurrences[] ascending by startMs.
//   dayKey(ms)                         -> "YYYY-MM-DD" in LOCAL time.
//   dayKeyToMs(key)                    -> local midnight of "YYYY-MM-DD".
//   groupByDay(events, fromMs, toMs)   -> { "YYYY-MM-DD": occurrences[] }, one
//                                         entry per day an occurrence COVERS.
//
// Event shape (parse):
//   { uid, summary, location, startMs, endMs, allDay, rrule, exdates, rdates }
//   rrule is the parsed RRULE object or null; exdates/rdates are arrays of ms.
// Occurrence shape (occurrences):
//   { uid, summary, location, startMs, endMs, allDay, recurring }
//   `recurring` is true when the instance came from an RRULE or an RDATE.
// ---------------------------------------------------------------------------

// Hard bounds. 2000 instances of one event is far more than any desktop widget
// can draw, and the iteration cap means a pathological rule costs milliseconds
// instead of a locked UI.
var MAX_OCCURRENCES = 2000;
var MAX_ITERATIONS = 20000;
var HORIZON_MS = 50 * 366 * 24 * 60 * 60 * 1000;   // ~50 years
var MAX_SPAN_MS = 366 * 24 * 60 * 60 * 1000;       // how far back groupByDay looks for a running event

// Monday-first weekday offsets, matching the Monday week anchor (RFC default WKST).
var DAY_OFFSET = { MO: 0, TU: 1, WE: 2, TH: 3, FR: 4, SA: 5, SU: 6 };

// ---------------------------------------------------------------------------
// Text handling
// ---------------------------------------------------------------------------

// Undo RFC 5545 line folding: CRLF (or bare CR/LF) followed by one space or tab
// continues the previous line, and the whitespace character itself is consumed.
// Also drops a UTF-8 BOM, which real feeds do ship.
function _unfold(text) {
    var s = String(text == null ? "" : text);
    if (s.charCodeAt(0) === 0xFEFF) s = s.slice(1);
    s = s.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
    return s.replace(/\n[ \t]/g, "");
}

// Undo TEXT escapes in one pass. A single pass matters: doing `\,` then `\\`
// separately would turn an escaped backslash followed by a comma into the wrong
// thing, because the second replace would see the first one's output.
function _unescapeText(value) {
    return String(value == null ? "" : value).replace(/\\([\\;,nN])/g, function (_, c) {
        if (c === "n" || c === "N") return "\n";
        if (c === "\\") return "\\";
        if (c === ",") return ",";
        return ";";
    });
}

// Split on `sep` but not inside a double-quoted parameter value, so
// `SUMMARY;LANGUAGE="en:GB":Hello` survives.
function _splitOutsideQuotes(str, sep) {
    var out = [], buf = "", inQ = false;
    for (var i = 0; i < str.length; i++) {
        var ch = str.charAt(i);
        if (ch === '"') { inQ = !inQ; buf += ch; continue; }
        if (ch === sep && !inQ) { out.push(buf); buf = ""; continue; }
        buf += ch;
    }
    out.push(buf);
    return out;
}

// Split one content line into name / parameters / value. The name:value split
// must skip colons inside quoted parameter values, otherwise
// `DTSTART;TZID="America/New_York":...` loses its value.
function _splitProperty(line) {
    var inQ = false, colon = -1;
    for (var i = 0; i < line.length; i++) {
        var ch = line.charAt(i);
        if (ch === '"') inQ = !inQ;
        else if (ch === ":" && !inQ) { colon = i; break; }
    }
    if (colon < 0) return null;
    var head = line.slice(0, colon);
    var value = line.slice(colon + 1);
    var segs = _splitOutsideQuotes(head, ";");
    var name = segs[0].trim().toUpperCase();
    if (!name) return null;
    var params = {};
    for (var s = 1; s < segs.length; s++) {
        var eq = segs[s].indexOf("=");
        if (eq < 0) continue;
        var k = segs[s].slice(0, eq).trim().toUpperCase();
        var v = segs[s].slice(eq + 1).trim();
        if (v.length >= 2 && v.charAt(0) === '"' && v.charAt(v.length - 1) === '"') v = v.slice(1, -1);
        if (k) params[k] = v;
    }
    return { name: name, params: params, value: value };
}

// ---------------------------------------------------------------------------
// Date / duration / rule primitives
// ---------------------------------------------------------------------------

function _mkLocal(y, mo, d, h, mi, s, ms) {
    return new Date(y, mo, d, h || 0, mi || 0, s || 0, ms || 0).getTime();
}

function _parts(ms) {
    var d = new Date(ms);
    return {
        y: d.getFullYear(), mo: d.getMonth(), d: d.getDate(),
        h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds(), ms: d.getMilliseconds()
    };
}

// Monday-first weekday index of a local date: 0 = Monday ... 6 = Sunday.
function _mondayIndex(y, mo, d) {
    return (new Date(y, mo, d).getDay() + 6) % 7;
}

function _daysInMonth(y, mo) {
    return new Date(y, mo + 1, 0).getDate();
}

// Move a timestamp by whole days while keeping the local wall clock. Plain
// millisecond addition would drift by an hour across a DST change; rebuilding
// from the local date components cannot.
function _shiftDays(ms, n) {
    var p = _parts(ms);
    return _mkLocal(p.y, p.mo, p.d + n, p.h, p.mi, p.s, p.ms);
}

// The next local midnight after the one `ms` sits on, `days` days out.
function _midnightPlusDays(ms, days) {
    var p = _parts(ms);
    return _mkLocal(p.y, p.mo, p.d + days, 0, 0, 0, 0);
}

// Monday of the week containing `ms`, at the same wall-clock time (the time is
// preserved so a weekly rule's instances keep their hour).
function _weekAnchor(ms) {
    var p = _parts(ms);
    return _shiftDays(ms, -_mondayIndex(p.y, p.mo, p.d));
}

// One date value. Returns null when it cannot be understood (the caller records
// that and carries on rather than throwing).
//   VALUE=DATE / YYYYMMDD  -> all-day, local midnight
//   ...T......Z            -> UTC, converted to local
//   ...T......  / TZID=... -> local wall clock (see the TZID limitation above)
function _parseDateValue(value, params) {
    var v = String(value == null ? "" : value).trim();
    var declaredDate = params && String(params.VALUE || "").toUpperCase() === "DATE";
    if (declaredDate || /^\d{8}$/.test(v)) {
        var m0 = /^(\d{4})(\d{2})(\d{2})/.exec(v);
        if (!m0) return null;
        return { ms: _mkLocal(+m0[1], +m0[2] - 1, +m0[3], 0, 0, 0, 0), allDay: true, utc: false };
    }
    var m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(?:\.\d+)?(Z)?$/.exec(v);
    if (!m) return null;
    var Y = +m[1], Mo = +m[2] - 1, D = +m[3], H = +m[4], Mi = +m[5], S = m[6] ? +m[6] : 0;
    var utc = !!m[7];
    var ms = utc ? Date.UTC(Y, Mo, D, H, Mi, S) : _mkLocal(Y, Mo, D, H, Mi, S, 0);
    return { ms: ms, allDay: false, utc: utc };
}

// ISO duration -> { ms, dayCount }. dayCount is the length in whole days when
// the duration has no sub-day component, which is what an all-day event needs
// (its end is a local midnight, not start + 86400000).
function _parseDuration(value) {
    var m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/
        .exec(String(value == null ? "" : value).trim().toUpperCase());
    if (!m) return null;
    var sign = m[1] === "-" ? -1 : 1;
    var w = +(m[2] || 0), d = +(m[3] || 0), h = +(m[4] || 0), mi = +(m[5] || 0), s = +(m[6] || 0);
    // Seconds below a day, and whether there are any at all: the second question
    // is what decides if an all-day duration can be counted in whole days.
    var subDaySecs = h * 3600 + mi * 60 + s;
    return {
        ms: sign * ((w * 7 + d) * 24 * 3600 + subDaySecs) * 1000,
        dayCount: subDaySecs === 0 ? sign * (w * 7 + d) : null
    };
}

function _parseIntList(value) {
    var parts = String(value).split(","), out = [];
    for (var i = 0; i < parts.length; i++) {
        var n = parseInt(parts[i].trim(), 10);
        if (isFinite(n) && n !== 0) out.push(n);
    }
    return out.length ? out : null;
}

function _parseByDay(value) {
    var parts = String(value).split(","), out = [];
    for (var i = 0; i < parts.length; i++) {
        var m = /^([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)$/.exec(parts[i].trim().toUpperCase());
        if (!m) continue;
        out.push({ ord: m[1] ? parseInt(m[1], 10) : null, day: m[2] });
    }
    return out.length ? out : null;
}

// Parse an RRULE value. Unknown keys (WKST, BYSETPOS, X-*) are ignored on
// purpose — a feed is allowed to say more than we implement, and throwing over
// it would lose the whole event. Returns null when there is no usable FREQ.
function _parseRRule(value) {
    var out = {
        freq: null, interval: 1, count: null, until: null,
        byday: null, bymonthday: null, raw: String(value)
    };
    var parts = String(value).split(";");
    for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=");
        if (eq < 0) continue;
        var k = parts[i].slice(0, eq).trim().toUpperCase();
        var v = parts[i].slice(eq + 1).trim();
        if (k === "FREQ") {
            out.freq = v.toUpperCase();
        } else if (k === "INTERVAL") {
            var iv = parseInt(v, 10);
            if (isFinite(iv) && iv > 0) out.interval = iv;
        } else if (k === "COUNT") {
            var c = parseInt(v, 10);
            if (isFinite(c) && c >= 0) out.count = c;
        } else if (k === "UNTIL") {
            var u = _parseDateValue(v, {});
            if (u) out.until = u.ms;
        } else if (k === "BYDAY") {
            out.byday = _parseByDay(v);
        } else if (k === "BYMONTHDAY") {
            out.bymonthday = _parseIntList(v);
        }
        // every other key: ignored, never an error
    }
    if (out.freq !== "DAILY" && out.freq !== "WEEKLY" &&
        out.freq !== "MONTHLY" && out.freq !== "YEARLY") return null;
    return out;
}

// ---------------------------------------------------------------------------
// Recurrence expansion
// ---------------------------------------------------------------------------

// Candidate start times inside one month, at the DTSTART wall clock. Handles
// BYMONTHDAY (negative counts back from the end of the month) and BYDAY with a
// leading ordinal (2TU = second Tuesday, -1FR = last Friday).
function _monthCandidates(y, mo, base, rule) {
    var out = [];
    var dim = _daysInMonth(y, mo);
    var i, j;
    if (rule.bymonthday && rule.bymonthday.length) {
        for (i = 0; i < rule.bymonthday.length; i++) {
            var md = rule.bymonthday[i];
            var day = md > 0 ? md : dim + md + 1;
            if (day >= 1 && day <= dim) out.push(_mkLocal(y, mo, day, base.h, base.mi, base.s, base.ms));
        }
        return out;
    }
    if (rule.byday && rule.byday.length) {
        for (i = 0; i < rule.byday.length; i++) {
            var b = rule.byday[i], off = DAY_OFFSET[b.day];
            if (b.ord == null) {
                for (j = 1; j <= dim; j++) {
                    if (_mondayIndex(y, mo, j) === off) out.push(_mkLocal(y, mo, j, base.h, base.mi, base.s, base.ms));
                }
            } else if (b.ord > 0) {
                var first = 1 + ((off - _mondayIndex(y, mo, 1) + 7) % 7);
                var dPos = first + (b.ord - 1) * 7;
                if (dPos >= 1 && dPos <= dim) out.push(_mkLocal(y, mo, dPos, base.h, base.mi, base.s, base.ms));
            } else {
                var last = dim - ((_mondayIndex(y, mo, dim) - off + 7) % 7);
                var dNeg = last + (b.ord + 1) * 7;
                if (dNeg >= 1 && dNeg <= dim) out.push(_mkLocal(y, mo, dNeg, base.h, base.mi, base.s, base.ms));
            }
        }
        return out;
    }
    // No BY*: the DTSTART day-of-month, skipped when the month is too short
    // (RFC 5545's own answer for Jan 31 in a 30-day month).
    if (base.d <= dim) out.push(_mkLocal(y, mo, base.d, base.h, base.mi, base.s, base.ms));
    return out;
}

// Candidate start times inside one year, for YEARLY;BYDAY. A plain weekday list
// means every such weekday in the year; an ordinal means the nth one (negative
// counts back from the end of the year).
function _yearCandidates(y, base, rule) {
    var out = [];
    if (rule.bymonthday && rule.bymonthday.length) {
        var dim = _daysInMonth(y, base.mo);
        for (var i = 0; i < rule.bymonthday.length; i++) {
            var md = rule.bymonthday[i];
            var day = md > 0 ? md : dim + md + 1;
            if (day >= 1 && day <= dim) out.push(_mkLocal(y, base.mo, day, base.h, base.mi, base.s, base.ms));
        }
        return out;
    }
    if (rule.byday && rule.byday.length) {
        var byWeekday = {};
        var d = new Date(y, 0, 1);
        while (d.getFullYear() === y) {
            var key = (d.getDay() + 6) % 7;
            (byWeekday[key] = byWeekday[key] || []).push({ mo: d.getMonth(), d: d.getDate() });
            d.setDate(d.getDate() + 1);
        }
        for (var j = 0; j < rule.byday.length; j++) {
            var b = rule.byday[j];
            var list = byWeekday[DAY_OFFSET[b.day]] || [];
            if (b.ord == null) {
                for (var k = 0; k < list.length; k++) out.push(_mkLocal(y, list[k].mo, list[k].d, base.h, base.mi, base.s, base.ms));
            } else {
                var pick = b.ord > 0 ? list[b.ord - 1] : list[list.length + b.ord];
                if (pick) out.push(_mkLocal(y, pick.mo, pick.d, base.h, base.mi, base.s, base.ms));
            }
        }
        return out;
    }
    if (base.d <= _daysInMonth(y, base.mo)) {
        out.push(_mkLocal(y, base.mo, base.d, base.h, base.mi, base.s, base.ms));
    }
    return out;
}

// Ascending list of candidate start times for one recurring event, from DTSTART
// up to (and including) `toMs`, also respecting UNTIL and COUNT. Bounded by
// MAX_OCCURRENCES, MAX_ITERATIONS and HORIZON_MS.
function _expandStarts(ev, toMs) {
    var rule = ev.rrule;
    var start = ev.startMs;
    var out = [];
    if (!rule) return out;
    var limit = Math.min(toMs == null ? Infinity : toMs,
                         rule.until == null ? Infinity : rule.until);
    var max = MAX_OCCURRENCES;
    var guard = MAX_ITERATIONS;
    var iv = rule.interval;
    var base = _parts(start);
    var done = false;
    var i, j;

    var take = function (cands) {
        // Push one batch of candidates (already ascending) and report whether the
        // rule is finished, so the caller's loop can stop early.
        if (cands.length && cands[0] > limit) return true;
        for (var k = 0; k < cands.length; k++) {
            var c = cands[k];
            if (c < start) continue;
            if (c > limit) break;
            if (out.length >= max) return true;
            out.push(c);
            if (rule.count != null && out.length >= rule.count) return true;
        }
        return out.length >= max;
    };

    if (rule.freq === "DAILY") {
        for (i = 0; i < guard && !done; i++) {
            var t = _shiftDays(start, i * iv);
            if (t - start > HORIZON_MS) break;
            done = take([t]);
        }
    } else if (rule.freq === "WEEKLY") {
        var anchor = _weekAnchor(start);
        for (i = 0; i < guard && !done; i++) {
            var ws = _shiftDays(anchor, i * iv * 7);
            if (ws - start > HORIZON_MS) break;
            var cands;
            if (rule.byday && rule.byday.length) {
                cands = [];
                for (j = 0; j < rule.byday.length; j++) cands.push(_shiftDays(ws, DAY_OFFSET[rule.byday[j].day]));
                cands.sort(function (a, b) { return a - b; });
            } else {
                cands = [_shiftDays(start, i * iv * 7)];
            }
            done = take(cands);
        }
    } else if (rule.freq === "MONTHLY") {
        for (i = 0; i < guard && !done; i++) {
            var total = base.mo + i * iv;
            var y = base.y + Math.floor(total / 12);
            var mo = total % 12;
            if (mo < 0) { mo += 12; y -= 1; }
            var anchorMs = _mkLocal(y, mo, 1, base.h, base.mi, base.s, base.ms);
            if (anchorMs - start > HORIZON_MS) break;
            if (anchorMs > limit) break;
            var mc = _monthCandidates(y, mo, base, rule);
            mc.sort(function (a, b) { return a - b; });
            done = take(mc);
        }
    } else if (rule.freq === "YEARLY") {
        for (i = 0; i < guard && !done; i++) {
            var yy = base.y + i * iv;
            var anchorY = _mkLocal(yy, 0, 1, base.h, base.mi, base.s, base.ms);
            if (anchorY - start > HORIZON_MS) break;
            if (anchorY > limit) break;
            var yc = _yearCandidates(yy, base, rule);
            yc.sort(function (a, b) { return a - b; });
            done = take(yc);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Component parsing
// ---------------------------------------------------------------------------

function _collectDates(props, errors) {
    var out = [];
    if (!props) return out;
    for (var i = 0; i < props.length; i++) {
        var vals = String(props[i].value).split(",");
        for (var j = 0; j < vals.length; j++) {
            var v = vals[j].trim();
            if (!v) continue;
            if (v.indexOf("/") >= 0) { errors.push("PERIOD value ignored: " + v); continue; }
            var d = _parseDateValue(v, props[i].params);
            if (d) out.push(d.ms);
            else errors.push("unparseable date value: " + v);
        }
    }
    return out;
}

// Turn one collected VEVENT's properties into an event object, or null when the
// component is unusable (no DTSTART). Every failure is recorded, never thrown.
function _finalize(props, index, errors) {
    var first = function (name) { return (props[name] && props[name].length) ? props[name][0] : null; };
    var dtstart = first("DTSTART");
    if (!dtstart) { errors.push("VEVENT without DTSTART, skipped"); return null; }
    var start = _parseDateValue(dtstart.value, dtstart.params);
    if (!start) { errors.push("VEVENT with unparseable DTSTART, skipped"); return null; }

    var uidProp = first("UID");
    var sumProp = first("SUMMARY");
    var locProp = first("LOCATION");

    var allDay = start.allDay;
    var startMs = start.ms;
    var endMs = null;

    var dtend = first("DTEND");
    if (dtend) {
        var e = _parseDateValue(dtend.value, dtend.params);
        if (e) endMs = e.ms;
        else errors.push("unparseable DTEND: " + dtend.value);
    }
    if (endMs == null) {
        var durProp = first("DURATION");
        if (durProp) {
            var dur = _parseDuration(durProp.value);
            if (dur) endMs = (allDay && dur.dayCount != null)
                ? _midnightPlusDays(startMs, dur.dayCount)
                : startMs + dur.ms;
            else errors.push("unparseable DURATION: " + durProp.value);
        }
    }
    if (endMs == null) {
        // A single all-day event runs to the next local midnight; a timed event
        // with no end is a point in time.
        endMs = allDay ? _midnightPlusDays(startMs, 1) : startMs;
    }

    var rrule = null;
    var rruleProp = first("RRULE");
    if (rruleProp) {
        rrule = _parseRRule(rruleProp.value);
        if (!rrule) errors.push("unsupported RRULE, event kept as a single instance: " + rruleProp.value);
    }

    return {
        uid: uidProp ? uidProp.value.trim() : ("generated-" + index),
        summary: sumProp ? _unescapeText(sumProp.value) : "",
        location: locProp ? _unescapeText(locProp.value) : "",
        startMs: startMs,
        endMs: endMs,
        allDay: allDay,
        rrule: rrule,
        exdates: _collectDates(props.EXDATE, errors),
        rdates: _collectDates(props.RDATE, errors)
    };
}

function _parse(text) {
    var errors = [];
    var events = [];
    var lines = _unfold(text).split("\n");
    var stack = [];
    var cur = null;

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (!line) continue;
        var prop = null;
        try { prop = _splitProperty(line); } catch (e) { prop = null; }
        if (!prop) { errors.push("line " + (i + 1) + ": not a content line, skipped"); continue; }

        if (prop.name === "BEGIN") {
            var comp = prop.value.trim().toUpperCase();
            stack.push(comp);
            // A VEVENT is collected even if it is not wrapped in VCALENDAR, which
            // is what a hand-written test fixture looks like.
            if (comp === "VEVENT") cur = {};
            continue;
        }
        if (prop.name === "END") {
            var closing = prop.value.trim().toUpperCase();
            if (stack.length) stack.pop();
            if (closing === "VEVENT" && cur) {
                var ev = _finalize(cur, events.length, errors);
                if (ev) events.push(ev);
                cur = null;
            }
            continue;
        }
        // Only properties at VEVENT depth are read. A nested VALARM (or anything
        // else) sits deeper on the stack, so its properties cannot leak into the
        // event it belongs to.
        if (cur && stack.length && stack[stack.length - 1] === "VEVENT") {
            if (!cur[prop.name]) cur[prop.name] = [];
            cur[prop.name].push(prop);
        }
    }
    // An unterminated VEVENT is still usable: keep what was understood.
    if (cur) {
        var last = _finalize(cur, events.length, errors);
        if (last) events.push(last);
        errors.push("unterminated VEVENT at end of input");
    }
    return { events: events, errors: errors };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Parse an ICS document. Never throws: a malformed document yields the events it
// could be understood to contain, and the skipped bits are described on the
// returned array's `.errors` (also available via parseErrors()).
function parse(text) {
    var res;
    try {
        res = _parse(text);
    } catch (e) {
        res = { events: [], errors: ["parser threw: " + (e && e.message ? e.message : String(e))] };
    }
    var events = res.events;
    events.errors = res.errors;
    return events;
}

// Same work as parse(), for callers that want the diagnostics without reaching
// into an array property.
function parseErrors(text) {
    try {
        return _parse(text);
    } catch (e) {
        return { events: [], errors: ["parser threw: " + (e && e.message ? e.message : String(e))] };
    }
}

// Every instance of every event that STARTS inside [fromMs, toMs], ascending.
// EXDATE removes an instance, RDATE adds one, a non-recurring event whose start
// falls in the window is included with recurring = false.
function occurrences(events, fromMs, toMs) {
    var out = [];
    if (!events || !events.length) return out;
    var lo = (fromMs == null) ? -Infinity : fromMs;
    var hi = (toMs == null) ? Infinity : toMs;

    for (var i = 0; i < events.length; i++) {
        var ev = events[i];
        if (!ev || typeof ev.startMs !== "number" || typeof ev.endMs !== "number") continue;

        var excluded = {};
        for (var x = 0; x < (ev.exdates || []).length; x++) excluded[ev.exdates[x]] = true;

        var starts = [], recurring = [];
        if (ev.rrule) {
            var expanded = _expandStarts(ev, hi);
            for (var e2 = 0; e2 < expanded.length; e2++) { starts.push(expanded[e2]); recurring.push(true); }
        } else {
            starts.push(ev.startMs);
            recurring.push(false);
        }
        var rdates = ev.rdates || [];
        for (var r = 0; r < rdates.length; r++) { starts.push(rdates[r]); recurring.push(true); }

        var dur = ev.endMs - ev.startMs;
        for (var s = 0; s < starts.length; s++) {
            var t = starts[s];
            if (excluded[t]) continue;
            if (t < lo || t > hi) continue;
            out.push({
                uid: ev.uid,
                summary: ev.summary,
                location: ev.location,
                startMs: t,
                endMs: t + dur,
                allDay: ev.allDay,
                recurring: recurring[s]
            });
        }
    }
    // Deterministic order: start, then uid, then summary, then end.
    out.sort(function (a, b) {
        if (a.startMs !== b.startMs) return a.startMs - b.startMs;
        if (a.uid !== b.uid) return a.uid < b.uid ? -1 : 1;
        if (a.summary !== b.summary) return a.summary < b.summary ? -1 : 1;
        return a.endMs - b.endMs;
    });
    return out;
}

// "YYYY-MM-DD" for a timestamp, in LOCAL time — the key a calendar cell uses.
function dayKey(ms) {
    var d = new Date(ms);
    var mo = d.getMonth() + 1, day = d.getDate();
    return d.getFullYear() + "-" + (mo < 10 ? "0" : "") + mo + "-" + (day < 10 ? "0" : "") + day;
}

// Local midnight of a "YYYY-MM-DD" key, so a widget can turn a cell into the
// bounds of a window without doing date math of its own.
function dayKeyToMs(key) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key == null ? "" : key).trim());
    if (!m) return null;
    return _mkLocal(+m[1], +m[2] - 1, +m[3], 0, 0, 0, 0);
}

// Occurrences bucketed by the LOCAL day they fall on — exactly what the dots
// need: `groupByDay(evts, from, to)["2026-03-10"].length`.
//
// An occurrence lands on EVERY day it covers, not just the day it starts: a
// three-day trip must dot all three cells, and an event from 23:00 to 01:00 dots
// both nights. DTEND is exclusive, so an all-day event ending on the 28th dots
// the 25th, 26th and 27th and not the 28th. A zero-length (point) event dots its
// own day only.
//
// The lookup reaches back MAX_SPAN_MS before fromMs, so an event that begins
// before the window but is still running inside it is dotted too; a calendar
// cell cannot see what started off-screen. Anything longer than a year that
// started before the window is the one case this misses, which no real event is.
function groupByDay(events, fromMs, toMs) {
    var out = {};
    var lo = (fromMs == null) ? -Infinity : fromMs;
    var hi = (toMs == null) ? Infinity : toMs;
    var widened = (lo === -Infinity) ? -Infinity : lo - MAX_SPAN_MS;
    var list = occurrences(events, widened, hi);

    for (var i = 0; i < list.length; i++) {
        var o = list[i];
        var first = dayKeyToMs(dayKey(o.startMs));
        // The last day the occurrence touches: one millisecond before its end.
        var last = (o.endMs > o.startMs) ? dayKeyToMs(dayKey(o.endMs - 1)) : first;
        for (var day = first; day !== null && day <= last && day <= hi; day = _shiftDays(day, 1)) {
            if (day < lo) continue;
            var k = dayKey(day);
            if (!out[k]) out[k] = [];
            out[k].push(o);
        }
    }
    return out;
}
