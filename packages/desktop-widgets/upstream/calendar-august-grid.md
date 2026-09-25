# The month grid draws the wrong day numbers in August

`modules/widgets/dashboard/widgets/calendar/layout.js` — `getPrevMonthDays()`

Reproduced on the shell at commit `2a704c43` (Ambxst 1.3.8), and in 2024, 2025 and 2026.

## What you see

Open the dashboard calendar and go to **August**. The first row is the tail of July, and it
is numbered one day early:

| year | drawn | the days it means |
|---|---|---|
| 2024 | `28 29 30 1 2 3 4` | `29 30 31 1 2 3 4` |
| 2025 | `27 28 29 30 1 2 3` | `28 29 30 31 1 2 3` |
| 2026 | `26 27 28 29 30 1 2` | `27 28 29 30 31 1 2` |

Only August is affected; every other month, and every day of August itself, is correct.

## Why

```js
function getPrevMonthDays(month, year) {
    const leapYear = checkLeapYear(year);
    if (month == 3 && leapYear) return 29;
    if (month == 3 && !leapYear) return 28;
    if (month == 1) return 31;
    if ((month <= 7 && month % 2 == 1) || (month >= 8 && month % 2 == 0)) return 30;
    return 31;
}
```

The parity rule answers "does the month *before* this one have 30 days" using **this**
month's number. It is right for `{5, 7, 10, 12}` and wrong for `{1, 8}` — the month
following a 31-day month. `1` is patched over by the explicit `if (month == 1) return 31;`,
`8` is not: it reports July as 30 days.

`getCalendarLayout()` then starts the fill at `daysInPrevMonth - (weekdayOfMonthFirst - 1)`,
so one wrong number shifts the whole leading row (and the day numbers of the month that
follows it, since `toFill` keeps counting from there).

## Fix

```diff
 function getPrevMonthDays(month, year) {
-    const leapYear = checkLeapYear(year);
-    if (month == 3 && leapYear) return 29;
-    if (month == 3 && !leapYear) return 28;
-    if (month == 1) return 31;
-    if ((month <= 7 && month % 2 == 1) || (month >= 8 && month % 2 == 0)) return 30;
-    return 31;
+    // The length of the month before this one, asked of the calendar itself. The parity
+    // table this used to be answered 30 for July, so August's grid drew its leading days
+    // (27 28 29 30) a day early.
+    return new Date(year, month - 1, 0).getDate();
 }
```

`new Date(year, month - 1, 0)` is the last day of the previous month, with February and
leap years handled by the calendar, and the `checkLeapYear` special case in this function
goes away with it. (`getNextMonthDays()` has the same shape but is **not** buggy — the
parity rule happens to be right for the months that follow; it can be left alone.)

## Checking it

```js
const L = new Function(require("fs").readFileSync("layout.js", "utf8")
    + "\nreturn { getCalendarLayout, getPrevMonthDays };")();
for (const y of [2024, 2025, 2026]) {
    const g = L.getCalendarLayout(new Date(y, 7, 1), false);
    console.log(y, L.getPrevMonthDays(8, y), g.calendar[0].map((c) => c.day).join(" "));
}
// before: 2025 30 27 28 29 30 1 2 3      after: 2025 31 28 29 30 31 1 2 3
```

A harness that pins this (96 months, 3 timezones, every cell's date against the number it
draws) lives in the desktop-widgets mod: `tests/calendar-cells.js`. It failed on exactly the
August cells of 2024-2026, in every month view, before the fix above.
