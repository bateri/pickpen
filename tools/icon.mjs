// Draws pickpen's icon, its mark (src/assets/mark.svg, which the view shows: three rows, the
// one in the middle picked), as PNGs, and writes them to src/assets/icon-<side>-<theme>.png.
// A terminal draws a program's icon only from the bytes it is given, so the program carries them
// (src/program/icons.rs); run this again after changing the shapes here and there.
//
//   node tools/icon.mjs
//
// It uses nothing but Node: the shapes are the SVG's strokes, lines with round ends and a rounded
// rectangle's outline, filled with coverage taken from a grid of samples in each pixel, and the PNG
// is written by hand around zlib.

import { writeFileSync } from "node:fs";
import { deflateSync, crc32 } from "node:zlib";

/** The width of every stroke, as the SVG's. */
const STROKE = 2;

/** The mark in its 24-unit box: a line from x, y to x, y; a rectangle's outline at x, y, width,
 * height, corner radius. */
const MARK = [
  { line: [7, 3.5, 17, 3.5] },
  { outline: [2, 8, 20, 8, 2.5] },
  { line: [7, 12, 17, 12] },
  { line: [7, 20.5, 17, 20.5] },
];

/** The part of that box an icon shows: all of it, the mark (x 1–23, y 2.5–21.5) and its margin. */
const FRAME = { x: 0, y: 0, side: 24 };

/** One colour for each ground, after MCP's `theme`: the ground the icon is made to stand on. */
const COLOURS = {
  dark: [0x5c, 0xc8, 0xa4],
  light: [0x0e, 0x76, 0x5c],
};

/** 32 pixels is what a terminal's strip asks for on a Retina screen; 64 for those that draw larger. */
const SIDES = [32, 64];

const SAMPLES = 8;

/** Whether a point is under the stroke of a shape. */
function inside(px, py, { line, outline }) {
  if (line) {
    const [x1, y1, x2, y2] = line;
    const along = Math.min(Math.max(((px - x1) * (x2 - x1) + (py - y1) * (y2 - y1)) / ((x2 - x1) ** 2 + (y2 - y1) ** 2), 0), 1);
    return Math.hypot(px - (x1 + along * (x2 - x1)), py - (y1 + along * (y2 - y1))) <= STROKE / 2;
  }
  // How far the point is from the rounded rectangle's edge, less inside it.
  const [x, y, w, h, r] = outline;
  const qx = Math.abs(px - (x + w / 2)) - (w / 2 - r);
  const qy = Math.abs(py - (y + h / 2)) - (h / 2 - r);
  const distance = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
  return Math.abs(distance) <= STROKE / 2;
}

function draw(side, [red, green, blue]) {
  const scale = FRAME.side / side;
  const rows = [];
  for (let row = 0; row < side; row++) {
    const line = Buffer.alloc(1 + side * 4); // a leading 0: no filter
    for (let column = 0; column < side; column++) {
      // A sample is covered when any stroke is under it, as one path's strokes are drawn.
      let hits = 0;
      for (let sy = 0; sy < SAMPLES; sy++) {
        for (let sx = 0; sx < SAMPLES; sx++) {
          const px = FRAME.x + (column + (sx + 0.5) / SAMPLES) * scale;
          const py = FRAME.y + (row + (sy + 0.5) / SAMPLES) * scale;
          if (MARK.some((shape) => inside(px, py, shape))) hits++;
        }
      }
      line.set([red, green, blue, Math.round((hits / (SAMPLES * SAMPLES)) * 255)], 1 + column * 4);
    }
    rows.push(line);
  }
  return png(side, Buffer.concat(rows));
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function png(side, pixels) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(side, 0);
  header.writeUInt32BE(side, 4);
  header.set([8, 6, 0, 0, 0], 8); // 8 bits, RGBA, deflate, no filter method, no interlace
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(pixels, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

let count = 0;
for (const [theme, colour] of Object.entries(COLOURS)) {
  for (const side of SIDES) {
    writeFileSync(new URL(`../src/assets/icon-${side}-${theme}.png`, import.meta.url), draw(side, colour));
    count += 1;
  }
}
console.log(`wrote ${count} icons to src/assets/`);
