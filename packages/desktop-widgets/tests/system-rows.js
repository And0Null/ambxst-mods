// Checks the system card's row gate: which rows the card can afford at each height, and
// the invariant that whatever it chooses, the content still fits the card.
//
// Both functions are EXTRACTED from the shipped QML (SystemWidget.qml and the shared
// WidgetType.js), so this runs the real arithmetic, not a restatement of it.
//
// node tests/system-rows.js
const fs = require("fs"), path = require("path");

const DIR = path.join(__dirname, "..", "overlays/modules/widgets/desktopwidgets");
const SYS = fs.readFileSync(path.join(DIR, "SystemWidget.qml"), "utf8");
const RULE = fs.readFileSync(path.join(DIR, "WidgetType.js"), "utf8");

// Two extractors on purpose: these files indent differently. WidgetType.js is a plain
// module (functions close at column 0), the widget is QML (bodies indented four spaces),
// and a regex that guesses both cuts a function short at its first inner brace.
const inJs = (name, src) =>
  (src.match(new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{[\\s\\S]*?\\n\\}")) || [null])[0];
const inQml = (name, src) =>
  (src.match(new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{[\\s\\S]*?\\n    \\}")) || [null])[0];

const FRAME_MARGIN = Number((RULE.match(/var\s+FRAME_MARGIN\s*=\s*(\d+)/) || [0])[1]);
const typeScaleFor = eval("(function(FRAME_MARGIN){ return " + inJs("typeScaleFor", RULE) + "; })(" + FRAME_MARGIN + ")");
const rowsThatFit = eval("(function(){ return " + inQml("rowsThatFit", SYS) + "; })()");
if (typeof typeScaleFor !== "function" || typeof rowsThatFit !== "function")
  throw new Error("no pude extraer las funciones: revisá los extractores");

// the widget's own measured heights, read from the properties so the test can't drift
const num = (name) => Number((SYS.match(new RegExp(name + ":\\s*(\\d+)")) || [0])[1]);
const M = num("metricsHeight"), SPARK = num("sparkHeight"), DISK = num("diskHeight");

const lines = [], fails = [];
const check = (ok, msg) => { lines.push(`  ${ok ? "OK  " : "FAIL"} ${msg}`); if (!ok) fails.push(msg); };

const inner = (card) => card - FRAME_MARGIN * 2;
const NATURAL = 140;   // the system card's longest line at its base size

// what the card shows at each height, and whether what it shows still fits
for (const card of [190, 240, 280, 320, 360, 420]) {
  const h = inner(card), scale = typeScaleFor(inner(280), h, NATURAL, inner(190));
  const rows = rowsThatFit(h, scale, true, true, true, M, SPARK, DISK);
  const used = M + (rows.spark ? SPARK : 0) + (rows.disk ? DISK : 0);
  check(used * scale <= h + 0.5,
    `tarjeta ${card}: filas=${rows.spark ? "cpu+spark" : "cpu"}${rows.disk ? "+disk" : ""} ` +
    `usan ${(used * scale).toFixed(0)}px de ${h}px (escala ${scale.toFixed(2)})`);
}

// the gate must actually gate: short cards drop rows instead of squeezing them
const at = (card) => {
  const h = inner(card), s = typeScaleFor(inner(280), h, NATURAL, inner(190));
  return rowsThatFit(h, s, true, true, true, M, SPARK, DISK);
};
// A detailed card that is only as tall as a normal one still gains the sparkline: the
// family asks for more, the height decides how much actually arrives.
check(at(190).spark === true && at(190).disk === false,
  "detailed en tarjeta normal (190): el sparkline entra (145 de 158), el disco no");
check(at(240).spark === true && at(240).disk === false, "detailed (240): barras + sparkline, sin disco");
check(at(420).spark === true && at(420).disk === true, "tarjeta muy alta (420): también la línea de disco");
check(at(240).spark === true && rowsThatFit(inner(240), 1, false, true, true, M, SPARK, DISK).spark === false,
  "la familia full (no detailed) nunca agrega filas, por más alta que sea la tarjeta");
check(rowsThatFit(inner(240), 1, true, false, true, M, SPARK, DISK).spark === false,
  "sin historia de CPU (recién arrancado) el sparkline no se muestra");

console.log("filas del system por alto de tarjeta:");
console.log("  tarjeta   " + [190, 240, 280, 320, 360, 420].join("   "));
console.log("  filas     " + [190, 240, 280, 320, 360, 420].map((c) => {
  const r = at(c);
  return (r.spark ? "spark" : "—") + (r.disk ? "+disk" : "");
}).join("  "));
console.log("");
console.log(lines.join("\n"));
console.log("");
if (fails.length) {
  console.log(`RESULTADO: FAIL (${fails.length})`);
  process.exit(1);
}
console.log("RESULTADO: PASS — las filas se agregan sólo si entran, y siempre entran");
