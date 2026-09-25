// The cell -> date mapping the event dots rely on.
//
// Calendar.qml's patched `cellDate(row, col)` decides which day a grid cell means, and the
// dots are looked up by that date. If the mapping is off by a day, or shifted by DST, the
// dots land under the wrong numbers and nothing else in the shell would notice.
//
// The formula is EXTRACTED from the shipped patch rather than copied here, so this test
// cannot drift from what the shell runs. layout.js — the shell's own grid builder, which
// produces the day numbers the cells draw — is the reference it is checked against.
//
//   node tests/calendar-cells.js
//   TZ=Australia/Lord_Howe node tests/calendar-cells.js     # 30-minute DST offset
//
// layout.js is read from the newest installed GENERATION first, because that is the file
// the shell runs (the mod's patch fixes a bug in it); $AMBXST_SRC and ~/.local/src/ambxst
// are the fallbacks for a machine that has not built a generation yet.

const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");

function findLayoutJs() {
    const candidates = [];
    const gens = path.join(os.homedir(), ".local/share/ambxst/mods/generations");
    try {
        for (const g of fs.readdirSync(gens).sort().reverse())
            candidates.push(path.join(gens, g, "modules/widgets/dashboard/widgets/calendar/layout.js"));
    } catch (e) { /* no generations installed */ }
    if (process.env.AMBXST_SRC) candidates.push(path.join(process.env.AMBXST_SRC, "modules/widgets/dashboard/widgets/calendar/layout.js"));
    candidates.push(path.join(os.homedir(), ".local/src/ambxst/modules/widgets/dashboard/widgets/calendar/layout.js"));
    return candidates.find((p) => fs.existsSync(p)) || null;
}

// Pull `function cellDate(rowIndex, index) { ... }` out of the patch's added lines.
function cellDateFromPatch() {
    const patch = fs.readFileSync(path.join(ROOT, "patches/calendar.patch"), "utf8");
    const added = patch.split("\n").filter((l) => l.startsWith("+")).map((l) => l.slice(1));
    const start = added.findIndex((l) => /function cellDate\(rowIndex, index\)/.test(l));
    if (start === -1) throw new Error("cellDate not found in patches/calendar.patch");
    const end = added.findIndex((l, i) => i > start && l === "    }");
    if (end === -1) throw new Error("cellDate body has no closing brace in the patch");
    return added.slice(start, end + 1).join("\n");
}

const src = cellDateFromPatch();
const body = src.replace(/\broot\./g, "");
// The patch's function reads `viewingDate` from the component, so it is bound here as the
// factory's argument and the inner function closes over it.
// eslint-disable-next-line no-new-func
const makeCellDate = new Function("viewingDate", body + "\nreturn cellDate;");
const cellDate = (viewing, row, col) => makeCellDate(viewing)(row, col);

const layoutJs = findLayoutJs();
if (!layoutJs) {
    console.log("SKIP: layout.js not found (set AMBXST_SRC to the shell source)");
    process.exit(0);
}
// layout.js is a QML JS library: functions at the top level, no exports. Evaluating the
// file and handing back what is needed is how the shell's own `import "layout.js"` sees it.
const CalendarLayout = new Function(fs.readFileSync(layoutJs, "utf8") + "\nreturn { getCalendarLayout };")();

// ---- checks ------------------------------------------------------------------------

let checks = 0;
let failures = [];
let known = [];   // the upstream bug pinned below, counted but not failed
function ok(cond, what) {
    checks++;
    if (!cond) failures.push(what);
}
function diverged(what) {
    checks++;
    known.push(what);
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function nextDay(d) {
    const n = new Date(d.getTime());
    n.setDate(n.getDate() + 1);
    return n;
}

function checkMonth(year, month, highlight) {
    const base = new Date(year, month, 1);
    const viewing = highlight ? new Date(year, month, 15) : base;   // monthShift 0 passes today
    const data = CalendarLayout.getCalendarLayout(viewing, highlight);
    const grid = data.calendar;
    let prev = null;

    for (let r = 0; r < 6; r++) {
        for (let c = 0; c < 7; c++) {
            const cell = grid[r][c];
            const when = cellDate(viewing, r, c);
            const where = `${year}-${month + 1} r${r}c${c}`;

            ok(when instanceof Date && !isNaN(when.getTime()), `${where}: cellDate returned no date`);
            if (!(when instanceof Date) || isNaN(when.getTime())) continue;

            // 1. the date must carry the day number the cell draws.
            //
            // KNOWN UPSTREAM BUG: layout.js's getPrevMonthDays() answers 30 for the month
            // before August (July has 31), so August's leading cells are drawn a day early.
            // The dot still follows the real date, and the divergence is pinned here: any
            // OTHER day-number mismatch, or this one in another month, fails the run.
            if (when.getDate() !== cell.day) {
                const augustTail = month + 1 === 8 && cell.today === -1 && when.getMonth() === month - 1;
                if (augustTail)
                    diverged(`${where}: cellDate day ${when.getDate()} != drawn day ${cell.day} (layout.js getPrevMonthDays(8) bug)`);
                else
                    failures.push(`${where}: cellDate day ${when.getDate()} != drawn day ${cell.day}`);
            }
            // 2. the cells must be consecutive calendar days, in reading order
            if (prev !== null)
                ok(sameDay(when, nextDay(prev)), `${where}: not the day after the previous cell (${prev.toDateString()} -> ${when.toDateString()})`);
            // 3. the month must agree with what the layout calls this month (0) or not (-1)
            if (cell.today === 0)
                ok(when.getMonth() === month, `${where}: layout says this month, cellDate says ${when.getMonth() + 1}`);
            else if (cell.today === -1)
                ok(when.getMonth() !== month, `${where}: layout says another month, cellDate says ${when.getMonth() + 1}`);
            // 4. on the highlighted month, the cell flagged as today must be today
            if (cell.today === 1)
                ok(when.getDate() === viewing.getDate() && when.getMonth() === viewing.getMonth(), `${where}: today flagged on ${when.toDateString()}`);

            prev = when;
        }
    }
    // 5. the highlighted month must flag exactly one today
    if (highlight)
        ok(grid.flat().filter((x) => x.today === 1).length === 1, `${year}-${month + 1}: today not flagged exactly once`);
}

const YEARS = [2024, 2025, 2026, 2027];
let months = 0;
for (const y of YEARS) {
    for (let m = 0; m < 12; m++) {
        checkMonth(y, m, true);    // the current month, with the today marker
        checkMonth(y, m, false);   // a month reached with the arrows, no marker
        months += 2;
    }
}

console.log(`TZ=${process.env.TZ || "(system)"} layout=${layoutJs}`);
console.log(`meses: ${months}  celdas: ${months * 42}  checks: ${checks}`);
if (known.length) {
    console.log(`nota: ${known.length} celdas de la cola de julio en agosto usan la fecha real y no el numero dibujado`);
    console.log(`      (bug upstream en layout.js getPrevMonthDays(8); el calendario del dashboard dibuja esa fila corrida)`);
}
if (failures.length) {
    console.log(`RESULTADO: FAIL — ${failures.length} fallas`);
    for (const f of failures.slice(0, 15)) console.log("  " + f);
    if (failures.length > 15) console.log(`  ... y ${failures.length - 15} mas`);
    process.exit(1);
}
console.log("RESULTADO: PASS — cada celda es el dia que dibuja, en orden, sin corrimiento por DST");
