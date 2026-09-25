#!/usr/bin/env node
// Prints, as JSON, the days the SHIPPED ics.js says carry events — so a different
// implementation can be diffed against it (tests/ics-vs-oracle.py does exactly that).
//
// The shipped file is loaded the same way tests/ics-cases.js loads it: as TEXT, with
// the leading `.pragma library` directive (a Quickshell thing, not valid JS) stripped,
// evaluated in a fresh context, so this runs the real code and not a copy of it.
//
// Usage: node tests/ics-days.js [file.ics] [from YYYY-MM-DD] [to YYYY-MM-DD]
// Run it with TZ=America/Bogota (tests/ics-vs-oracle.py does it for you).
const fs = require("fs"), path = require("path"), vm = require("vm");

const DIR = path.join(__dirname, "..", "overlays/modules/widgets/desktopwidgets");
const ICS = fs.readFileSync(path.join(DIR, "ics.js"), "utf8").replace(/^\.pragma library[^\n]*\n/, "");

const sandbox = { console, Date, Math, JSON, Object, Array, String, Number, RegExp, isNaN, parseInt, parseFloat, Set, Map, Infinity, NaN, undefined };
vm.createContext(sandbox);
vm.runInContext(ICS, sandbox, { filename: "ics.js" });

const file = process.argv[2] || path.join(__dirname, "fixtures", "calendar-sample.ics");
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const from = process.argv[3] || iso(new Date());
const to = process.argv[4] || iso(new Date(Date.now() + 20 * 86400000));

const fromMs = sandbox.dayKeyToMs(from);
const toMs = sandbox.dayKeyToMs(to) + 86400000 - 1;
const byDay = sandbox.groupByDay(sandbox.parse(fs.readFileSync(file, "utf8")), fromMs, toMs);

const days = {};
for (const key of Object.keys(byDay)) {
    days[key] = byDay[key].map((o) => o.summary).sort();
}
console.log(JSON.stringify({ file: path.basename(file), from, to, days }, null, 1));
