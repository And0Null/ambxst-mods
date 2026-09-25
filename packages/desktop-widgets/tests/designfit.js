// Design-fit check for the desktop-widgets catalog.
//
// Extracts the `designs` catalog plus pixelRect / normalizeKids / applyDesign FROM the
// service QML — the shipped code, not a copy — and asserts the rules a design has to
// obey. Run with node; exits non-zero on the first broken rule.
//
//   node tests/designfit.js
const fs = require("fs");
const path = require("path");

const SVC = path.join(__dirname, "../overlays/modules/services/DesktopWidgetsService.qml");
const svc = fs.readFileSync(SVC, "utf8");

function block(startRe, endRe) {
  const s = svc.search(startRe);
  if (s < 0) { console.error("no encontrado:", startRe); process.exit(1); }
  const e = svc.indexOf(endRe, s);
  return svc.slice(s, e + endRe.length);
}
function fn(name) {
  const re = new RegExp("function " + name + "\\([^)]*\\) \\{[\\s\\S]*?\\n    \\}");
  const m = svc.match(re);
  if (!m) { console.error("no pude extraer " + name); process.exit(1); }
  return m[0];
}

const designs = eval(block(/readonly property var designs: \[/, "    ];").replace(/^readonly property var designs: /, ""));

const root = {
  previewRefW: 1920, previewRefH: 1080,
  designs: designs,
  saveGuard: { stop: () => {} },
  save: () => {},
  widgets: [], design: "",
};
root.pixelRect = eval("(function(root){ return " + fn("pixelRect") + "; })(root)");
root.normalizeKids = eval("(function(root){ return " + fn("normalizeKids") + "; })(root)");
root.previewRect = eval("(function(root){ return " + fn("previewRect") + "; })(root)");

// A service function assigns to root's own properties as BARE identifiers and reaches
// Timers by their QML ids, so the shim has to reproduce the singleton scope: a `with`
// proxy that intercepts only root's keys and the extra ids, leaving local vars local.
function scoped(fnSrc, obj, extra) {
  const handler = {
    has: (t, k) => (k in obj || k in extra),
    get: (t, k) => (k in extra ? extra[k] : obj[k]),
    set: (t, k, v) => { obj[k] = v; return true; },
  };
  return new Function("scope", "with (scope) { return " + fnSrc + "; }")(new Proxy({}, handler));
}
root.referenceScreen = () => ({ w: 1920, h: 1080 });
root.normalizeFamily = eval("(function(root){ return " + fn("normalizeFamily") + "; })(root)");
root.anchorFor = eval("(function(root){ return " + fn("anchorFor") + "; })(root)");
root.anchorsFor = eval("(function(root){ return " + fn("anchorsFor") + "; })(root)");
root.parse = scoped(fn("parse"), root, { root: root });
root.applyDesign = scoped(fn("applyDesign"), root,
  { root: root, saveGuard: root.saveGuard, save: root.save, normalizeKids: root.normalizeKids });

// Rules, with the numbers they came from.
const EDGE = 8;            // WidgetLayer.edgeMargin: the clamp must never fire
const TOP_CLEAR = 48;      // the bar hides the first 45 rows of every output
const DOCK_H = 71;         // the dock owns the last 71 rows of the middle ~520 columns
const DOCK_HALF_W = 260;
const MIN_KID_W = 200, MIN_KID_H = 150;   // a group child has to render, not just fit
const SCREENS = [[1366, 768], [1920, 1080]];

// Which content families each widget implements. A design asking for a family a widget
// does not have would silently render the full one, so the test refuses it: this map
// grows as the families land.
const FAMILIES = {
  clock: ["compact", "full", "detailed"],
  weather: ["compact", "full", "detailed"], system: ["compact", "full", "detailed"],
  calendar: ["full"], group: ["full"],
};

let fails = 0;
console.log(`diseños: ${designs.map(d => d.id).join(", ")}\n`);

for (const d of designs) {
  const lines = [];
  for (const [W, H] of SCREENS) {
    const visible = d.entries.filter(e => e.enabled !== false);
    const rects = visible.map(e => Object.assign({ type: e.type }, root.pixelRect(e, W, H)));
    for (const r of rects) {
      if (r.x < 0 || r.y < 0 || r.x + r.w > W - EDGE || r.y + r.h > H - EDGE)
        lines.push(`${W}x${H}: ${r.type} se sale o depende del clamp -> x${r.x} y${r.y} ${r.w}x${r.h}`);
      if (r.y < TOP_CLEAR)
        lines.push(`${W}x${H}: ${r.type} arranca en y=${r.y}, debajo de la barra (min ${TOP_CLEAR})`);
      if (r.x < W / 2 + DOCK_HALF_W && r.x + r.w > W / 2 - DOCK_HALF_W && r.y + r.h > H - DOCK_H)
        lines.push(`${W}x${H}: ${r.type} llega a y=${r.y + r.h} sobre el dock (max ${H - DOCK_H})`);
    }
    for (let i = 0; i < rects.length; i++)
      for (let k = i + 1; k < rects.length; k++) {
        const a = rects[i], b = rects[k];
        if (a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y)
          lines.push(`${W}x${H}: ${a.type} y ${b.type} se solapan`);
      }
    for (const e of d.entries) {
      if (e.type !== "group") continue;
      const n = (e.children || []).length;
      if (!n) { lines.push(`${W}x${H}: grupo sin hijos`); continue; }
      const innerW = e.w - 32, innerH = e.h - 32;              // WidgetFrame's 16px margins
      const kw = e.direction === "row" ? (innerW - (n - 1) * 14) / n : innerW;
      const kh = e.direction === "row" ? innerH : (innerH - (n - 1) * 14) / n;
      if (kh < MIN_KID_H || kw < MIN_KID_W)
        lines.push(`${W}x${H}: grupo ${e.direction} deja ${Math.round(kw)}x${Math.round(kh)} por hijo (min ${MIN_KID_W}x${MIN_KID_H})`);
    }
    if (!visible.length) lines.push(`${W}x${H}: no muestra nada`);
  }

  // every requested family must exist
  for (const e of d.entries) {
    const fam = e.family || "full";
    if (!(FAMILIES[e.type] || ["full"]).includes(fam))
      lines.push(`${e.type} no implementa la familia "${fam}"`);
    for (const kid of (e.children || [])) {
      const kt = typeof kid === "string" ? kid : kid.type;
      const kf = typeof kid === "string" ? "full" : (kid.family || "full");
      if (!(FAMILIES[kt] || ["full"]).includes(kf))
        lines.push(`${e.type}: el hijo ${kt} no implementa "${kf}"`);
    }
  }

  // applyDesign must reproduce the geometry exactly, and normalise children to objects
  root.widgets = [];
  root.applyDesign(d.id);
  const applied = root.widgets;
  if (applied.length !== d.entries.length)
    lines.push(`applyDesign devolvio ${applied.length} entradas, el diseno tiene ${d.entries.length}`);
  d.entries.forEach((e, i) => {
    const a = applied[i];
    if (!a) return;
    for (const [W, H] of SCREENS) {
      const p = root.pixelRect(e, W, H), q = root.pixelRect(a, W, H);
      if (p.x !== q.x || p.y !== q.y || p.w !== q.w || p.h !== q.h)
        lines.push(`applyDesign movio ${e.type} en ${W}x${H}: ${p.x},${p.y} -> ${q.x},${q.y}`);
    }
    if (a.children.length && typeof a.children[0] !== "object")
      lines.push(`los hijos de ${e.type} no se normalizaron a objetos`);
  });

  // 6. families AND directions survive a save/parse round trip. A whitelist in the
  //    parser that does not know a tier silently rewrites the layout, which is exactly
  //    how the first "detailed" clock shipped as a "full" one.
  const roundTrip = () => {
    const cfg = JSON.stringify({
      design: "custom", opacity: 0.5,
      widgets: [
        { type: "clock", family: "compact", ax: "left", ox: 10, ay: "top", oy: 20, w: 280, h: 80, children: [] },
        { type: "clock", family: "detailed", ax: "left", ox: 10, ay: "top", oy: 120, w: 280, h: 240, children: [] },
        { type: "group", direction: "row", ax: "left", ox: 10, ay: "top", oy: 400, w: 810, h: 222,
          children: [{ type: "clock", family: "detailed" }, "weather"] },
      ],
    });
    const out = root.parse(cfg);
    if (out[0].family !== "compact") lines.push(`round trip: compact -> ${out[0].family}`);
    if (out[1].family !== "detailed") lines.push(`round trip: detailed -> ${out[1].family}`);
    if (out[2].direction !== "row") lines.push(`round trip: direction row -> ${out[2].direction}`);
    if (out[2].children[0].family !== "detailed") lines.push(`round trip: hijo detailed -> ${out[2].children[0].family}`);
    if (out[2].children[1].type !== "weather") lines.push(`round trip: hijo string -> ${JSON.stringify(out[2].children[1])}`);
  };
  roundTrip();

  // the picker thumbnail must stay inside its box
  for (const e of d.entries) {
    const b = root.previewRect(e, 66, 28);
    if (b.x < 0 || b.y < 0 || b.x + b.w > 66 || b.y + b.h > 28)
      lines.push(`miniatura fuera de caja: ${e.type} -> ${b.x},${b.y} ${b.w}x${b.h}`);
  }

  fails += lines.length;
  console.log(`${lines.length ? "FAIL" : "OK  "} ${d.id.padEnd(8)} ${d.entries.length} entradas, ${d.entries.filter(e => e.enabled !== false).length} visibles`);
  lines.slice(0, 5).forEach(l => console.log("        " + l));
}

console.log(`\nRESULTADO: ${fails === 0 ? "PASS — todos los diseños entran, sin solapes, sin barra ni dock encima" : "FAIL (" + fails + ")"}`);
process.exit(fails === 0 ? 0 : 1);
