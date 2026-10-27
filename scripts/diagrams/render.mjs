// Renders the README diagrams in Excalidraw's hand-drawn style.
//
// Each diagram is described once below (boxes and arrows) and written twice into docs/assets/diagrams/:
//   <name>.svg         for the README (rough.js strokes, the Excalifont font embedded, a white "paper")
//   <name>.excalidraw  to open and edit at https://excalidraw.com (File → Open)
//
// Usage: cd scripts/diagrams && npm install && npm run render
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import rough from "roughjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, "../../docs/assets/diagrams");
const font = fs.readFileSync(path.join(here, "fonts/Excalifont-Regular.woff2")).toString("base64");

// Colors carry meaning, the same in every diagram (Excalidraw's palette, light fill + dark stroke).
const kinds = {
  claude: { fill: "#fff4e6", stroke: "#e8590c" },  // Claude Code
  diorama: { fill: "#f3f0ff", stroke: "#7048e8" }, // Diorama and its rules
  data: { fill: "#f8f9fa", stroke: "#868e96" },    // what a tool returned
  result: { fill: "#ebfbee", stroke: "#2f9e44" },  // outcomes
  record: { fill: "#e7f5ff", stroke: "#1971c2" },  // the audit trail
  secret: { fill: "#fff5f5", stroke: "#e03131" },  // something sensitive
};
const ink = "#1e1e1e";
const muted = "#495057";
const arrowInk = "#495057";
const titleSize = 21;
const subSize = 15;
const labelSize = 14;
const lineHeight = 1.3;

// Boxes in a row: same size, same gap, centered vertically on `cy`.
function row(cy, x0, w, h, gap, specs) {
  return specs.map((s, i) => ({ ...s, x: x0 + i * (w + gap), y: cy - h / 2, w, h }));
}

// Boxes: { id, title, sub, kind, x, y, w, h }. Arrows: { from, to, label, dashed }.
// Text avoids characters Excalifont's Latin subset lacks (e.g. "→").
const diagrams = {
  overview: (() => {
    const top = row(95, 40, 210, 110, 70, [
      { id: "claude", title: "Claude Code", sub: "asks for a web page", kind: "claude" },
      { id: "page", title: "Weather page", sub: "\"It is 30°C today\"", kind: "data" },
      { id: "diorama", title: "Diorama", sub: "your rule:\n30°C becomes 5°C", kind: "diorama" },
      { id: "claude2", title: "Claude Code", sub: "reads 5°C, says\n\"Take a warm coat!\"", kind: "claude" },
    ]);
    const d = top[2];
    return {
      width: 1130, height: 360,
      boxes: [...top, { id: "log", title: "Audit trail", sub: "what changed, and\ndid Claude use it?", kind: "record", x: d.x, y: 245, w: d.w, h: 95 }],
      arrows: [
        { from: "claude", to: "page", label: "fetch" },
        { from: "page", to: "diorama", label: "result" },
        { from: "diorama", to: "claude2", label: "changed" },
        { from: "diorama", to: "log", label: "records", dashed: true },
      ],
    };
  })(),
  replace: {
    width: 960, height: 190,
    boxes: row(95, 40, 240, 110, 80, [
      { id: "page", title: "Fetched page", sub: "\"version 2.3\"", kind: "data" },
      { id: "rule", title: "Replace rule", sub: "2.3 becomes 2.4\nno AI, free, instant", kind: "diorama" },
      { id: "claude", title: "Claude Code", sub: "reads \"version 2.4\"", kind: "claude" },
    ]),
    arrows: [{ from: "page", to: "rule" }, { from: "rule", to: "claude" }],
  },
  rewrite: (() => {
    const top = row(95, 40, 240, 110, 80, [
      { id: "page", title: "Original page", sub: "as the tool fetched it", kind: "data" },
      { id: "agent", title: "Rewrite agent", sub: "follows your\ninstructions", kind: "diorama" },
      { id: "claude", title: "Claude Code", sub: "sees the new page", kind: "claude" },
    ]);
    const a = top[1];
    return {
      width: 960, height: 340,
      boxes: [...top, { id: "log", title: "Audit trail", sub: "diff and explanation", kind: "record", x: a.x, y: 240, w: a.w, h: 85 }],
      arrows: [{ from: "page", to: "agent" }, { from: "agent", to: "claude" }, { from: "agent", to: "log", label: "explains", dashed: true }],
    };
  })(),
  redact: {
    width: 960, height: 190,
    boxes: row(95, 40, 240, 110, 80, [
      { id: "file", title: "config.env", sub: "KEY=sk-ant-abc123...", kind: "secret" },
      { id: "rule", title: "Redact rule", sub: "local, free", kind: "diorama" },
      { id: "claude", title: "Claude Code", sub: "sees KEY=[REDACTED:\nanthropic-key]", kind: "claude" },
    ]),
    arrows: [{ from: "file", to: "rule" }, { from: "rule", to: "claude" }],
  },
  experiment: {
    width: 900, height: 470,
    boxes: [
      { id: "task", title: "Same task", sub: "same project, many runs", kind: "data", x: 320, y: 30, w: 260, h: 95 },
      { id: "control", title: "A  ·  Control", sub: "no changes\nrun 1, 2, 3 ...", kind: "data", x: 70, y: 185, w: 260, h: 105 },
      { id: "steered", title: "B  ·  Steered", sub: "your rules\nrun 1, 2, 3 ...", kind: "diorama", x: 570, y: 185, w: 260, h: 105 },
      { id: "compare", title: "Compare", sub: "success, steps, cost,\ndid Claude repeat it?", kind: "result", x: 320, y: 350, w: 260, h: 100 },
    ],
    arrows: [
      { from: "task", to: "control" }, { from: "task", to: "steered" },
      { from: "control", to: "compare" }, { from: "steered", to: "compare" },
    ],
  },
};

// Deterministic seeds, so re-rendering gives the same strokes.
let seedCounter = 1;
const nextSeed = () => (seedCounter = (seedCounter * 48271) % 2147483647);

const gen = rough.generator();
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function roundedRect({ x, y, w, h }) {
  const r = Math.min(14, w / 4, h / 4);
  return `M ${x + r} ${y} L ${x + w - r} ${y} Q ${x + w} ${y} ${x + w} ${y + r} L ${x + w} ${y + h - r} Q ${x + w} ${y + h} ${x + w - r} ${y + h} ` +
    `L ${x + r} ${y + h} Q ${x} ${y + h} ${x} ${y + h - r} L ${x} ${y + r} Q ${x} ${y} ${x + r} ${y} Z`;
}

/** Where the line from the box's center towards (tx, ty) leaves the box. */
function edgePoint(b, tx, ty, gap = 12) {
  const cx = b.x + b.w / 2, cy = b.y + b.h / 2, dx = tx - cx, dy = ty - cy;
  const t = Math.min(b.w / 2 / Math.abs(dx || 1e-9), b.h / 2 / Math.abs(dy || 1e-9));
  const len = Math.hypot(dx, dy);
  return [cx + dx * t + (dx / len) * gap, cy + dy * t + (dy / len) * gap];
}

function arrowGeometry(a, boxes) {
  const f = boxes[a.from], t = boxes[a.to];
  const [x1, y1] = edgePoint(f, t.x + t.w / 2, t.y + t.h / 2);
  const [x2, y2] = edgePoint(t, f.x + f.w / 2, f.y + f.h / 2);
  return { x1, y1, x2, y2 };
}

function lines(cx, top, text, size, color, extra = "") {
  return text.split("\n").map((l, i) =>
    `<text x="${cx.toFixed(1)}" y="${(top + i * size * lineHeight).toFixed(1)}" font-size="${size}" fill="${color}" text-anchor="middle" dominant-baseline="central"${extra}>${esc(l)}</text>`).join("");
}

/** Title and gray subtitle, centered in the box as one block. */
function boxText(b) {
  const sub = b.sub ? b.sub.split("\n").length : 0;
  const height = titleSize * lineHeight + (sub ? 6 + sub * subSize * lineHeight : 0);
  const top = b.y + b.h / 2 - height / 2 + (titleSize * lineHeight) / 2;
  return lines(b.x + b.w / 2, top, b.title, titleSize, ink) +
    (sub ? lines(b.x + b.w / 2, top + (titleSize * lineHeight) / 2 + 6 + (subSize * lineHeight) / 2, b.sub, subSize, muted) : "");
}

function renderSVG(name, d) {
  const boxes = Object.fromEntries(d.boxes.map((b) => [b.id, b]));
  const out = [];
  const pathSVG = (drawable, dash) => gen.toPaths(drawable).map((p) =>
    `<path d="${p.d}" stroke="${p.stroke}" stroke-width="${p.strokeWidth}" fill="${p.fill || "none"}" stroke-linecap="round" stroke-linejoin="round"${dash ? ' stroke-dasharray="7 7"' : ""}/>`).join("");
  for (const b of d.boxes) {
    const k = kinds[b.kind];
    out.push(pathSVG(gen.path(roundedRect(b), { stroke: k.stroke, strokeWidth: 1.8, roughness: 0.6, bowing: 0.6, fill: k.fill, fillStyle: "solid", seed: nextSeed() })));
    out.push(boxText(b));
  }
  for (const a of d.arrows) {
    const { x1, y1, x2, y2 } = arrowGeometry(a, boxes);
    const opts = { stroke: arrowInk, strokeWidth: 1.6, roughness: 0.5, bowing: 0.8, seed: nextSeed() };
    out.push(pathSVG(gen.line(x1, y1, x2, y2, opts), a.dashed));
    const ang = Math.atan2(y2 - y1, x2 - x1), len = 13, spread = 0.42;
    for (const s of [-spread, spread]) {
      out.push(pathSVG(gen.line(x2, y2, x2 - len * Math.cos(ang + s), y2 - len * Math.sin(ang + s), { ...opts, seed: nextSeed() })));
    }
    if (a.label) {
      const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, horizontal = Math.abs(x2 - x1) >= Math.abs(y2 - y1);
      const halo = ' stroke="#ffffff" stroke-width="6" paint-order="stroke" stroke-linejoin="round"';
      out.push(horizontal
        ? lines(mx, my - 15, a.label, labelSize, muted, halo)
        : `<text x="${(mx + 12).toFixed(1)}" y="${my.toFixed(1)}" font-size="${labelSize}" fill="${muted}" dominant-baseline="central"${halo}>${esc(a.label)}</text>`);
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${d.width} ${d.height}" width="${d.width}" height="${d.height}" role="img" aria-label="${esc(name)} diagram">
<defs><style>@font-face{font-family:"Excalifont";src:url(data:font/woff2;base64,${font}) format("woff2");}
text{font-family:"Excalifont",sans-serif;}</style></defs>
<rect x="0" y="0" width="${d.width}" height="${d.height}" rx="16" fill="#ffffff"/>
${out.join("\n")}
</svg>
`;
}

// .excalidraw: the same boxes and arrows as Excalidraw elements, with text bound to its container.
function renderExcalidraw(d) {
  const boxes = Object.fromEntries(d.boxes.map((b) => [b.id, b]));
  const elements = [];
  const base = (extra) => ({
    angle: 0, strokeColor: ink, backgroundColor: "transparent", fillStyle: "solid", strokeWidth: 2, strokeStyle: "solid", roughness: 1, opacity: 100,
    groupIds: [], frameId: null, roundness: null, seed: nextSeed(), version: 1, versionNonce: nextSeed(), isDeleted: false, boundElements: [],
    updated: 1, link: null, locked: false, ...extra,
  });
  const text = (id, t, containerId, x, y, w, h, size, color = ink) => base({
    id, type: "text", x, y, width: w, height: h, text: t, originalText: t, fontSize: size, fontFamily: 5, textAlign: "center",
    verticalAlign: "middle", containerId, autoResize: true, lineHeight, strokeColor: color,
  });
  for (const b of d.boxes) {
    const k = kinds[b.kind];
    elements.push(base({
      id: b.id, type: "rectangle", x: b.x, y: b.y, width: b.w, height: b.h, strokeColor: k.stroke, backgroundColor: k.fill,
      roundness: { type: 3 }, boundElements: [{ type: "text", id: `${b.id}-text` }],
    }));
    // Excalidraw has one text per container: the title and subtitle share it.
    const t = b.sub ? `${b.title}\n${b.sub}` : b.title, th = t.split("\n").length * subSize * lineHeight;
    elements.push(text(`${b.id}-text`, t, b.id, b.x + 10, b.y + (b.h - th) / 2, b.w - 20, th, 16));
  }
  d.arrows.forEach((a, i) => {
    const { x1, y1, x2, y2 } = arrowGeometry(a, boxes), id = `arrow-${i}`;
    elements.push(base({
      id, type: "arrow", x: x1, y: y1, width: Math.abs(x2 - x1), height: Math.abs(y2 - y1), strokeColor: arrowInk,
      strokeStyle: a.dashed ? "dashed" : "solid", roundness: { type: 2 }, points: [[0, 0], [x2 - x1, y2 - y1]], lastCommittedPoint: null,
      startBinding: { elementId: a.from, focus: 0, gap: 12 }, endBinding: { elementId: a.to, focus: 0, gap: 12 },
      startArrowhead: null, endArrowhead: "arrow", elbowed: false, boundElements: a.label ? [{ type: "text", id: `${id}-text` }] : [],
    }));
    for (const end of [a.from, a.to]) elements.find((e) => e.id === end).boundElements.push({ type: "arrow", id });
    if (a.label) {
      const w = a.label.length * labelSize * 0.6, h = labelSize * lineHeight;
      elements.push(text(`${id}-text`, a.label, id, (x1 + x2) / 2 - w / 2, (y1 + y2) / 2 - h / 2, w, h, labelSize, muted));
    }
  });
  return JSON.stringify({ type: "excalidraw", version: 2, source: "https://github.com/ridvanaltun/diorama", elements,
    appState: { viewBackgroundColor: "#ffffff", gridSize: null }, files: {} }, null, 2) + "\n";
}

fs.mkdirSync(outDir, { recursive: true });
const onlyPreview = process.argv.includes("--preview");
const target = onlyPreview ? path.resolve(process.argv[process.argv.indexOf("--preview") + 1]) : outDir;
fs.mkdirSync(target, { recursive: true });
for (const [name, d] of Object.entries(diagrams)) {
  // A rough width check (Excalifont is about 0.55 em per character), so text never spills out of its box.
  for (const b of d.boxes) {
    const widest = Math.max(b.title.length * titleSize, ...(b.sub ?? "").split("\n").map((l) => l.length * subSize)) * 0.55;
    if (widest > b.w - 24) console.warn(`${name}: “${b.title}” may be too wide for its box`);
  }
  seedCounter = [...name].reduce((s, c) => s + c.charCodeAt(0), 7);
  fs.writeFileSync(path.join(target, `${name}.svg`), renderSVG(name, d));
  seedCounter = [...name].reduce((s, c) => s + c.charCodeAt(0), 11);
  if (!onlyPreview) fs.writeFileSync(path.join(target, `${name}.excalidraw`), renderExcalidraw(d));
  console.log(`✓ ${path.relative(process.cwd(), path.join(target, name))}.svg`);
}
