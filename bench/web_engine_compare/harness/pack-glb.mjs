// 外の bin と画像を持つ .gltf を、1 本の .glb にまとめ直す（計画の X3）。中身（頂点・材質・絵のバイト）は変えない。
//   node harness/pack-glb.mjs <入る .gltf> <出す .glb>   （make compare-assets が Sponza に使う）
// WhyNot: Blender で読み直して書き出さない — 材質や頂点の並びが書き直され、比べる相手と同じ幾何でなくなる恐れがある。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const src = resolve(process.argv[2]);
const out = resolve(process.argv[3]);
const dir = dirname(src);
const gltf = JSON.parse(readFileSync(src, 'utf8'));
const pad4 = (n) => (n + 3) & ~3;
const parts = [];
let length = 0;
const append = (bytes) => {
  const offset = length;
  parts.push(bytes);
  length += bytes.length;
  const padded = pad4(length);
  if (padded > length) { parts.push(Buffer.alloc(padded - length)); length = padded; }
  return offset;
};

const bufferOffsets = gltf.buffers.map((b) => append(readFileSync(join(dir, decodeURIComponent(b.uri)))));
for (const view of gltf.bufferViews) {
  view.byteOffset = (view.byteOffset ?? 0) + bufferOffsets[view.buffer];
  view.buffer = 0;
}
const mimeOf = (uri) => (/\.png$/i.test(uri) ? 'image/png' : 'image/jpeg');
for (const image of gltf.images ?? []) {
  if (!image.uri) continue;
  const bytes = readFileSync(join(dir, decodeURIComponent(image.uri)));
  gltf.bufferViews.push({ buffer: 0, byteOffset: append(bytes), byteLength: bytes.length });
  image.bufferView = gltf.bufferViews.length - 1;
  image.mimeType = image.mimeType ?? mimeOf(image.uri);
  delete image.uri;
}
gltf.buffers = [{ byteLength: length }];

let json = Buffer.from(JSON.stringify(gltf), 'utf8');
json = Buffer.concat([json, Buffer.alloc(pad4(json.length) - json.length, 0x20)]);
const bin = Buffer.concat(parts);
const header = Buffer.alloc(12);
header.writeUInt32LE(0x46546c67, 0);
header.writeUInt32LE(2, 4);
header.writeUInt32LE(12 + 8 + json.length + 8 + bin.length, 8);
const chunk = (type, body) => {
  const h = Buffer.alloc(8);
  h.writeUInt32LE(body.length, 0);
  h.writeUInt32LE(type, 4);
  return Buffer.concat([h, body]);
};
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, Buffer.concat([header, chunk(0x4e4f534a, json), chunk(0x004e4942, bin)]));
console.log(`[pack-glb] ${out}（${(12 + 8 + json.length + 8 + bin.length) / 1e6} MB）`);
