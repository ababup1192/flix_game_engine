# gl_parity — GL と SoftRaster の突き合わせ harness

同じ描画指定（`Render.PlacedItem` の列）を GL（実機の絵）と SoftRaster（bake・スナップショットの絵）の
両方で 1 コマ描き出し、画素を機械で突き合わせる。スナップショットは作らない — 基準は「もう片方の経路」。

## 回し方

```
make gl-parity            # リポジトリのルートから
make -C bench/gl_parity run   # ここから直接でも同じ
```

- 隠しウィンドウ（`FLIX_GE_HIDDEN=1`）で GL に描き出すので画面には何も出ない。
  ウィンドウを見たいときは `FLIX_GE_HIDDEN` を立てずに `../../bin/flix run`。
- 結果は 1 行 1 scene の表（`[parity] <scene> <段階> <一致 or 差>`）。
  A 段階（バイト一致を保証する層）に不一致があると exit 1。B 段階のうち許容差を置いた scene（3D の場面。
  `Scenes.toleranceOf`）は、違う画素がその数を超えると exit 1。
- 不一致の絵は `debug/diff/` に「GL | Soft | 違いヒート」で並ぶ。
  GL の絵は `debug/gl/`、SoftRaster の絵は `debug/soft/`。

- `FGE_INSTANCING=off make gl-parity` は 3D の物を batch にせず、物ごとの材質で来た順に 1 体ずつ描く。`debug/gl/` の SHA を on と比べる。
  `sameDepthOrder3d` だけは割れるのが正しい（同じ深さの面の順を見る場面）ので比べから外す。ほかが全部同じなら、`batchKeys3d` が見ている鍵の欄（`params`・`wrap`・`cutout`・法線マップの強さ・絵の名前）に漏れが無い。
  欄を外すと割れる事は `params` で確かめた（`batchKeys3d` の差 40 → 572 px で `make gl-parity` も落ちる）。ほかの欄は同じ形の場面にしてあるだけで、外して確かめてはいない。

## 線引き

何が「バイト一致」で何が「近似」かは docs/backend-parity.md の表が正典。
A 段階の scene に入れてよい絵の条件（整数座標・k/255 の色・軸平行縞のみ等）は
scene ファイル（src/Scenes.flix）の冒頭に書いてある。

## 注意

- flix.toml の `github:ababup1192/flix_game_engine` の行を消すと、`make sync` 系の
  lib 差し替え配管（エンジン最新の fpkg を受け取る仕組み）から外れる。消さないこと。
