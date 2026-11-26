// Flix の場面（SceneDump の 1 行 1 場面の JSON）を、比べる相手の buildScene の値と比べる。
//   npx tsx ../../harness/compare-scenes.ts <dump.jsonl>   （build/upstream で流す。make scene-compare）
// 小数は Float32 へ丸めてから相対 1e-5（絶対 1e-6 まで）で比べる。整数の配列は完全一致。
import { readFileSync } from 'node:fs';
import { buildScene, fieldWorldMatrices } from '../build/upstream/src/harness/scenes.ts';
import type { FieldScene, Geometry } from '../build/upstream/src/harness/types.ts';

const REL = 1e-5;
const ABS = 1e-6;

type Num = ArrayLike<number>;
let failures = 0;
let compared = 0;

function near(a: number, b: number) {
  const fa = Math.fround(a), fb = Math.fround(b);
  return Math.abs(fa - fb) <= Math.max(ABS, REL * Math.max(Math.abs(fa), Math.abs(fb)));
}

function floats(label: string, ours: Num, theirs: Num) {
  compared++;
  if (ours.length !== theirs.length) {
    failures++;
    console.log(`NG ${label}: 長さ ${ours.length} ≠ ${theirs.length}`);
    return;
  }
  let worst = -1, worstErr = 0;
  for (let i = 0; i < ours.length; i++) {
    if (!near(ours[i], theirs[i])) {
      const err = Math.abs(ours[i] - theirs[i]);
      if (err > worstErr) { worst = i; worstErr = err; }
    }
  }
  if (worst >= 0) {
    failures++;
    console.log(`NG ${label}: [${worst}] ${ours[worst]} ≠ ${theirs[worst]}`);
  }
}

function exact(label: string, ours: Num, theirs: Num) {
  compared++;
  const same = ours.length === theirs.length && Array.from(ours).every((v, i) => v === theirs[i]);
  if (!same) {
    failures++;
    const i = Array.from(ours).findIndex((v, k) => v !== theirs[k]);
    console.log(`NG ${label}: 長さ ${ours.length}/${theirs.length}・最初の違い [${i}] ${ours[i]} ≠ ${theirs[i]}`);
  }
}

function shape(label: string, ours: any, theirs: Geometry) {
  floats(`${label}.positions`, ours.positions, theirs.positions);
  floats(`${label}.normals`, ours.normals, theirs.normals);
  floats(`${label}.uvs`, ours.uvs, theirs.uvs);
  exact(`${label}.indices`, ours.indices, theirs.indices);
}

const lines = readFileSync(process.argv[2], 'utf8').split('\n').filter((l) => l.startsWith('{'));
for (const line of lines) {
  const ours = JSON.parse(line);
  const theirs = buildScene(ours.scenario, ours.level, null) as FieldScene;
  theirs.update(ours.t);
  const tag = `${ours.scenario}@${ours.level} t=${ours.t}`;
  floats(`${tag} camera.position`, ours.camera.position, theirs.camera.position);
  floats(`${tag} camera.target`, ours.camera.target, theirs.camera.target);
  floats(`${tag} materials.opacity`, ours.materials.map((m: any) => m.opacity), theirs.materials.map((m) => m.opacity ?? 1));
  floats(`${tag} sun.direction`, ours.sun.direction, theirs.sun!.direction);
  exact(`${tag} count`, [ours.count], [theirs.count]);
  exact(`${tag} geom`, ours.geom, theirs.geom);
  exact(`${tag} material`, ours.material, theirs.material);
  floats(`${tag} position`, ours.position, theirs.position);
  floats(`${tag} scale`, ours.scale, theirs.scale);
  floats(`${tag} quat`, ours.quat, theirs.quat);
  floats(`${tag} materials.color`, ours.materials.flatMap((m: any) => m.color), theirs.materials.flatMap((m) => m.color));
  floats(`${tag} materials.roughness`, ours.materials.map((m: any) => m.roughness), theirs.materials.map((m) => m.roughness));
  floats(`${tag} materials.metalness`, ours.materials.map((m: any) => m.metalness), theirs.materials.map((m) => m.metalness));
  if (theirs.groups) {
    exact(`${tag} groups.parent`, ours.groups.parent, theirs.groups.parent);
    floats(`${tag} groups.position`, ours.groups.position, theirs.groups.position);
    floats(`${tag} groups.quat`, ours.groups.quat, theirs.groups.quat);
  }
  if (theirs.pick) floats(`${tag} pick.points`, ours.pickPoints, theirs.pick.points);
  if (ours.worldColumns) {
    const world = new Float32Array(theirs.count * 16);
    fieldWorldMatrices(theirs, world);
    floats(`${tag} world`, ours.worldColumns, world);
  }
  theirs.geometries.forEach((g, i) => shape(`${tag} shape ${g.name}`, ours.shapes[i], g));
}
console.log(`${failures === 0 ? 'OK' : 'NG'} 場面 ${lines.length}・比べた配列 ${compared}・違い ${failures}`);
process.exit(failures === 0 ? 0 : 1);
