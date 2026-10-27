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

// Excalidraw's palette.
const ink = "#1e1e1e";
const fills = { blue: "#a5d8ff", green: "#b2f2bb", yellow: "#ffec99", red: "#ffc9c9", violet: "#d0bfff", gray: "#e9ecef", orange: "#ffd8a8" };
const fontSize = 20;
const labelSize = 17;
const lineHeight = 1.25;

// Boxes: { id, x, y, w, h, text, fill, shape: "rect" | "diamond" | "ellipse" }.
// Arrows: { from, to, label, dashed }. Labels avoid characters Excalifont's Latin subset lacks (e.g. →).
const diagrams = {
  overview: {
    width: 960, height: 540,
    boxes: [
      { id: "claude", x: 40, y: 40, w: 230, h: 80, text: "🤖 Claude Code", fill: "blue" },
      { id: "page", x: 620, y: 40, w: 250, h: 80, text: "🌐 Weather page", fill: "gray" },
      { id: "diorama", x: 620, y: 190, w: 250, h: 150, text: "🎭 Diorama\nyour rules", fill: "violet", shape: "diamond" },
      { id: "claude2", x: 40, y: 225, w: 250, h: 80, text: "🤖 Claude Code\nnow reads: 5°C", fill: "blue" },
      { id: "answer", x: 40, y: 410, w: 250, h: 85, text: "💬 \"Take a warm\ncoat today!\"", fill: "yellow", shape: "ellipse" },
      { id: "log", x: 560, y: 410, w: 330, h: 85, text: "📒 What changed,\nand did Claude use it?", fill: "green" },
    ],
    arrows: [
      { from: "claude", to: "page", label: "fetches the page" },
      { from: "page", to: "diorama", label: "\"It is 30°C today\"" },
      { from: "diorama", to: "claude2", label: "\"It is 5°C today\"" },
      { from: "claude2", to: "answer" },
      { from: "diorama", to: "log", label: "records", dashed: true },
    ],
  },
  replace: {
    width: 960, height: 170,
    boxes: [
      { id: "page", x: 30, y: 40, w: 250, h: 90, text: "📄 The page says\n\"version 2.3\"", fill: "gray" },
      { id: "rule", x: 355, y: 30, w: 250, h: 110, text: "🔁 Replace rule\n2.3 becomes 2.4\nno AI, free", fill: "green" },
      { id: "claude", x: 680, y: 40, w: 250, h: 90, text: "🤖 Claude reads\n\"version 2.4\"", fill: "blue" },
    ],
    arrows: [{ from: "page", to: "rule" }, { from: "rule", to: "claude" }],
  },
  rewrite: {
    width: 960, height: 300,
    boxes: [
      { id: "page", x: 30, y: 40, w: 230, h: 90, text: "📄 Original page", fill: "gray" },
      { id: "agent", x: 340, y: 30, w: 290, h: 110, text: "🧠 Rewrite agent\nfollows your\ninstructions", fill: "violet" },
      { id: "claude", x: 710, y: 40, w: 230, h: 90, text: "🤖 Claude sees\nthe new page", fill: "blue" },
      { id: "log", x: 340, y: 200, w: 290, h: 80, text: "📒 What changed, and why", fill: "green" },
    ],
    arrows: [{ from: "page", to: "agent" }, { from: "agent", to: "claude" }, { from: "agent", to: "log", label: "explains", dashed: true }],
  },
  redact: {
    width: 960, height: 170,
    boxes: [
      { id: "file", x: 30, y: 40, w: 270, h: 90, text: "📄 config.env\nKEY=sk-ant-abc123...", fill: "gray" },
      { id: "rule", x: 375, y: 30, w: 220, h: 110, text: "🛡️ Redact rule\nlocal, free", fill: "red" },
      { id: "claude", x: 650, y: 25, w: 290, h: 120, text: "🤖 Claude sees\nKEY=[REDACTED:\nanthropic-key]", fill: "blue" },
    ],
    arrows: [{ from: "file", to: "rule" }, { from: "rule", to: "claude" }],
  },
  experiment: {
    width: 900, height: 520,
    boxes: [
      { id: "task", x: 300, y: 30, w: 300, h: 80, text: "📝 Same task,\nsame project", fill: "yellow" },
      { id: "control", x: 60, y: 170, w: 300, h: 80, text: "🅰️ Control\nno changes", fill: "gray" },
      { id: "steered", x: 540, y: 170, w: 300, h: 80, text: "🅱️ Steered\nyour rules", fill: "violet" },
      { id: "runsA", x: 60, y: 300, w: 300, h: 60, text: "run 1 · run 2 · run 3 ...", fill: "gray" },
      { id: "runsB", x: 540, y: 300, w: 300, h: 60, text: "run 1 · run 2 · run 3 ...", fill: "violet" },
      { id: "compare", x: 225, y: 410, w: 450, h: 85, text: "📊 Compare: success, steps, cost,\ndid Claude repeat the change?", fill: "green" },
    ],
    arrows: [
      { from: "task", to: "control" }, { from: "task", to: "steered" },
      { from: "control", to: "runsA" }, { from: "steered", to: "runsB" },
      { from: "runsA", to: "compare" }, { from: "runsB", to: "compare" },
    ],
  },
};

// Deterministic seeds, so re-rendering gives the same strokes.
let seedCounter = 1;
const nextSeed = () => (seedCounter = (seedCounter * 48271) % 2147483647);

const gen = rough.generator();
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function shapeDrawable(b) {
  const opts = { stroke: ink, strokeWidth: 2, roughness: 1.1, fill: fills[b.fill], fillStyle: "hachure", hachureGap: 7, fillWeight: 1, seed: nextSeed() };
  if (b.shape === "diamond") {
    const cx = b.x + b.w / 2, cy = b.y + b.h / 2;
    return gen.polygon([[cx, b.y], [b.x + b.w, cy], [cx, b.y + b.h], [b.x, cy]], opts);
  }
  if (b.shape === "ellipse") return gen.ellipse(b.x + b.w / 2, b.y + b.h / 2, b.w, b.h, opts);
  // Rounded rectangle, like Excalidraw's default "round" edges.
  const r = Math.min(16, b.w / 4, b.h / 4), { x, y, w, h } = b;
  const d = `M ${x + r} ${y} L ${x + w - r} ${y} Q ${x + w} ${y} ${x + w} ${y + r} L ${x + w} ${y + h - r} Q ${x + w} ${y + h} ${x + w - r} ${y + h} ` +
    `L ${x + r} ${y + h} Q ${x} ${y + h} ${x} ${y + h - r} L ${x} ${y + r} Q ${x} ${y} ${x + r} ${y} Z`;
  return gen.path(d, opts);
}

/** Where the line from the box's center towards (tx, ty) leaves the box. */
function edgePoint(b, tx, ty, gap = 10) {
  const cx = b.x + b.w / 2, cy = b.y + b.h / 2, dx = tx - cx, dy = ty - cy;
  const hw = b.w / 2, hh = b.h / 2;
  let t;
  if (b.shape === "diamond") t = 1 / (Math.abs(dx) / hw + Math.abs(dy) / hh);
  else if (b.shape === "ellipse") t = 1 / Math.sqrt((dx / hw) ** 2 + (dy / hh) ** 2);
  else t = Math.min(hw / Math.abs(dx || 1e-9), hh / Math.abs(dy || 1e-9));
  const len = Math.hypot(dx, dy);
  return [cx + dx * t + (dx / len) * gap, cy + dy * t + (dy / len) * gap];
}

function arrowGeometry(a, boxes) {
  const f = boxes[a.from], t = boxes[a.to];
  const [x1, y1] = edgePoint(f, t.x + t.w / 2, t.y + t.h / 2);
  const [x2, y2] = edgePoint(t, f.x + f.w / 2, f.y + f.h / 2);
  return { x1, y1, x2, y2 };
}

function textBlock(text, cx, cy, size, extra = "") {
  const lines = text.split("\n");
  const top = cy - ((lines.length - 1) * size * lineHeight) / 2;
  return lines.map((l, i) => `<text x="${cx.toFixed(1)}" y="${(top + i * size * lineHeight).toFixed(1)}" font-size="${size}" text-anchor="middle" dominant-baseline="central"${extra}>${esc(l)}</text>`).join("");
}

function renderSVG(name, d) {
  const boxes = Object.fromEntries(d.boxes.map((b) => [b.id, b]));
  const paths = [];
  const pathSVG = (drawable, dash) => gen.toPaths(drawable).map((p) =>
    `<path d="${p.d}" stroke="${p.stroke}" stroke-width="${p.strokeWidth}" fill="${p.fill || "none"}" stroke-linecap="round"${dash ? ' stroke-dasharray="8 7"' : ""}/>`).join("");
  for (const b of d.boxes) {
    paths.push(pathSVG(shapeDrawable(b)));
    paths.push(textBlock(b.text, b.x + b.w / 2, b.y + b.h / 2, fontSize));
  }
  for (const a of d.arrows) {
    const { x1, y1, x2, y2 } = arrowGeometry(a, boxes);
    const opts = { stroke: ink, strokeWidth: 2, roughness: 0.9, seed: nextSeed() };
    paths.push(pathSVG(gen.line(x1, y1, x2, y2, opts), a.dashed));
    // Arrowhead: two short strokes back from the tip.
    const ang = Math.atan2(y2 - y1, x2 - x1), len = 16, spread = 0.45;
    for (const s of [-spread, spread]) {
      paths.push(pathSVG(gen.line(x2, y2, x2 - len * Math.cos(ang + s), y2 - len * Math.sin(ang + s), { ...opts, seed: nextSeed() })));
    }
    if (a.label) {
      // Beside the arrow's middle: above a horizontal arrow, to the side of a vertical one.
      const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, horizontal = Math.abs(x2 - x1) >= Math.abs(y2 - y1);
      const lx = horizontal ? mx : mx + 14, ly = horizontal ? my - 20 : my;
      const anchor = horizontal ? "" : ' text-anchor="start"';
      const halo = ' stroke="#ffffff" stroke-width="6" paint-order="stroke" stroke-linejoin="round"';
      paths.push(horizontal ? textBlock(a.label, lx, ly, labelSize, halo)
        : `<text x="${lx.toFixed(1)}" y="${ly.toFixed(1)}" font-size="${labelSize}" dominant-baseline="central"${anchor}${halo}>${esc(a.label)}</text>`);
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${d.width} ${d.height}" width="${d.width}" height="${d.height}" role="img" aria-label="${esc(name)} diagram">
<defs><style>@font-face{font-family:"Excalifont";src:url(data:font/woff2;base64,${font}) format("woff2");}
text{font-family:"Excalifont","Segoe UI Emoji","Apple Color Emoji","Noto Color Emoji",sans-serif;fill:${ink};}</style></defs>
<rect x="0" y="0" width="${d.width}" height="${d.height}" rx="18" fill="#ffffff"/>
${paths.join("\n")}
</svg>
`;
}

// .excalidraw: the same boxes and arrows as Excalidraw elements, with text bound to its container.
function renderExcalidraw(d) {
  const boxes = Object.fromEntries(d.boxes.map((b) => [b.id, b]));
  const elements = [];
  const base = (extra) => ({
    angle: 0, strokeColor: ink, backgroundColor: "transparent", fillStyle: "hachure", strokeWidth: 2, strokeStyle: "solid", roughness: 1, opacity: 100,
    groupIds: [], frameId: null, roundness: null, seed: nextSeed(), version: 1, versionNonce: nextSeed(), isDeleted: false, boundElements: [],
    updated: 1, link: null, locked: false, ...extra,
  });
  const text = (id, t, containerId, x, y, w, h, size) => base({
    id, type: "text", x, y, width: w, height: h, text: t, originalText: t, fontSize: size, fontFamily: 5, textAlign: "center",
    verticalAlign: "middle", containerId, autoResize: true, lineHeight, baseline: Math.round(size * 0.9),
  });
  for (const b of d.boxes) {
    const type = b.shape === "diamond" ? "diamond" : b.shape === "ellipse" ? "ellipse" : "rectangle";
    elements.push(base({
      id: b.id, type, x: b.x, y: b.y, width: b.w, height: b.h, backgroundColor: fills[b.fill],
      roundness: type === "rectangle" ? { type: 3 } : type === "diamond" ? { type: 2 } : null, boundElements: [{ type: "text", id: `${b.id}-text` }],
    }));
    const lines = b.text.split("\n").length, th = lines * fontSize * lineHeight;
    elements.push(text(`${b.id}-text`, b.text, b.id, b.x + 10, b.y + (b.h - th) / 2, b.w - 20, th, fontSize));
  }
  d.arrows.forEach((a, i) => {
    const { x1, y1, x2, y2 } = arrowGeometry(a, boxes), id = `arrow-${i}`;
    elements.push(base({
      id, type: "arrow", x: x1, y: y1, width: Math.abs(x2 - x1), height: Math.abs(y2 - y1), strokeStyle: a.dashed ? "dashed" : "solid",
      roundness: { type: 2 }, points: [[0, 0], [x2 - x1, y2 - y1]], lastCommittedPoint: null,
      startBinding: { elementId: a.from, focus: 0, gap: 10 }, endBinding: { elementId: a.to, focus: 0, gap: 10 },
      startArrowhead: null, endArrowhead: "arrow", elbowed: false, boundElements: a.label ? [{ type: "text", id: `${id}-text` }] : [],
    }));
    for (const end of [a.from, a.to]) elements.find((e) => e.id === end).boundElements.push({ type: "arrow", id });
    if (a.label) {
      const w = a.label.length * labelSize * 0.6, h = labelSize * lineHeight;
      elements.push(text(`${id}-text`, a.label, id, (x1 + x2) / 2 - w / 2, (y1 + y2) / 2 - h / 2, w, h, labelSize));
    }
  });
  return JSON.stringify({ type: "excalidraw", version: 2, source: "https://github.com/ridvanaltun/diorama", elements,
    appState: { viewBackgroundColor: "#ffffff", gridSize: null }, files: {} }, null, 2) + "\n";
}

fs.mkdirSync(outDir, { recursive: true });
for (const [name, d] of Object.entries(diagrams)) {
  // A rough width check (Excalifont is about 0.55 em per character), so a label never spills out of its box.
  for (const b of d.boxes) {
    const longest = Math.max(...b.text.split("\n").map((l) => [...l].length));
    if (longest * fontSize * 0.55 > b.w - (b.shape === "rect" || !b.shape ? 24 : 70)) console.warn(`${name}: “${b.text.split("\n")[0]}…” may be too wide for its box`);
  }
  seedCounter = [...name].reduce((s, c) => s + c.charCodeAt(0), 7);
  fs.writeFileSync(path.join(outDir, `${name}.svg`), renderSVG(name, d));
  seedCounter = [...name].reduce((s, c) => s + c.charCodeAt(0), 11);
  fs.writeFileSync(path.join(outDir, `${name}.excalidraw`), renderExcalidraw(d));
  console.log(`✓ docs/assets/diagrams/${name}.svg and .excalidraw`);
}
