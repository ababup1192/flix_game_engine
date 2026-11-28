# 3D の場面を組む CPU の時間を減らす — 計画

## なぜ

3D の箱庭（`~/Documents/flix_ge_workspace/lamplighter`）で、町を家ごとの物に分けたら描く物（Instance3d）が約 90 個から 857 個に増え、
1 コマが 5.7 ms から 14.1 ms（M4 Pro・960×540・垂直同期なし）に延びた。別の MacBook では 31〜38 fps しか出なかった。
GPU ではなく CPU で、時間は「描く物の一覧を組む」所に落ちていた。ゲームの側で形をつないで数を減らして避けた（857 → 約 250 個・5.7 ms）が、
物の多いゲームは同じ所で詰まる。1 個あたりの値段を下げる。

以前の決定（0.88.0 で性能は区切り・「動かない物の送り」は見送り）は、人が今回「エンジン側で速くできる余地があれば直す」と言ったので、この範囲では進めてよい。

## 測って分かっている事（main スレッドを jstack で 60 回拾った結果・約 250 個の今の状態）

- `Paint.submitGpuItems` の中にいる割合が約 7 割。その内訳:
  - `Render3d.prepareScenes` → `ScenePlan.planScenes` / `planScene` / `sceneDrawsOf`（約 3〜4 割）。中は `Scene3d.isOutsideFrustumFields` →
    `Scene3d.worldBoundsOfFields` → `Mesh3d.boundsOfPoints`・`Frustum.intersectsBox` → `Mat4.apply`、`Scene3d.drawCenterOf`
  - `Render3d.drawScene` / `drawBatch` / `drawBlended` / `meshDrawOf` / `meshEntry`（約 2 割）
  - `RenderPaint.buildProgram` → `ShaderGen.eqSpec` → `eqSpecTree`（再帰）・`ShaderGen.eqMaterial`・`hashMaterial`（約 1 割）。
    毎コマ、材質と面の Spec の木を丸ごと突き合わせている
- 一番上のフレームは `RecordExtend$Obj/Float64/Int32.lookupField`（record の欄の引き）が 4 割強。欄の多い record を回る所で効く
- GL の呼び出し（`glDrawElementsInstanced`・`glBlitFramebuffer`・present）は 2 割弱。ここは対象外
- 857 個の時は、同じ覗き方で `Frustum.intersectsBox`・`Mat4.apply`・`ShaderGen.eqSpecTree`・`ScenePlan.sceneDrawsOf` が毎回出ていた
- 場面は 1 コマに 3 回組まれる（色の Pass・影の地図・奥行きの Pass）。3 回とも同じ置いた物の並びを別々に組んでいる

## やる事（効きそうな順。1 つ入れるごとに測り、効かなければ戻す）

1. **材質とプログラムの引き当て**: 毎コマの `eqSpecTree` の丸ごとの突き合わせをやめる。`MaterialFields#shaderHash`（Lazy）のような、
   先に作ってある鍵で引き、木の突き合わせは「鍵が同じで、まだ同じと確かめていない組」の時だけにする。面（Item.Shader）の Spec も同じ。
2. **視錐台の判定の材料**: `worldBoundsOfFields` が毎コマ・毎 Pass、形の境界の 8 つの角を行列で写している。
   - world が単位行列の物は、形の境界をそのまま使う（写さない）
   - 形の境界（`Mesh3d.bounds`）が毎回頂点を数え直しているなら、形を作る時に 1 回だけ数えて持つ
   - `drawCenterOf` も同じ境界から出す（2 回数えない）
3. **同じ並びを 3 回組まない**: 1 コマの中で、同じ置いた物（同じ形・同じ world）の境界と描く順の点を、Pass をまたいで使い回せるなら使い回す。
   無理に入れない（キャッシュの鍵を作る方が高ければやめる）。
4. **record の欄の引き**: 熱い所（`Mat4.apply`・`Frustum.intersectsBox`・`sceneDrawsOf` の中）で、同じ record の欄を何度も引いている所を、
   1 回 let に受けてから使う形にする。record の作り（`Mat4` の表し方）は変えない。

## 決まり

- **pub の型と関数の形は変えない**（足すのは可）。変えないと進めない時は、実装せず分かった事と案を報告して止まる。
- **絵は 1 bit も変えない**。`make gl-parity`（全 scene 0 px）と、engine・render_gl・engine_world・engine_tools のテストが緑のまま。
  描く順（`blendOrderOf`・バッチの順）も変えない。
- GL と CPU の描き手（SoftRaster3d）が同じ判定を使う決まりは守る（片方だけ速い別の式にしない）。
- コメントは WhyNot。「前は遅かった」のような経緯は書かない。
- コミット・push・版上げ・リリースはしない。

## 測り方

- **ゲームで**: `cd ~/Documents/flix_ge_workspace/lamplighter` で、作業ツリーの fpkg を `lib/github/ababup1192/flix_game_engine/0.90.0/` の
  `flix_game_engine-0.90.0.fpkg` と `.toml` へ写し（`engine_full/artifact/package.fpkg`・`flix.toml`）、`rm -f packages.lock`、
  `/Users/abab/Desktop/flix_game_engine/bin/fge checkd --stop .`。そのうえで
  `FLIX_GE_FRAME_STATS=1 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 make run RUN_SECONDS=30` を流し、ログの `[frame-stats] … 間隔 avg` を読む
  （600 コマごと。最初の 1 行は読み込みを含むので 2 行目から）。路地は `START="at x=-14 z=-20"` を前に付ける。
  今の値: 始まりの広場 5.7 ms・路地 7.0 ms。**ゲームの `src/`・`assets/` は触らない。** `lib/` の 2 ファイルと `packages.lock` だけ。
  測り終えたら窓が残っていないか `pgrep -f build/headless/headless.jar` で確かめる（RUN_SECONDS で自分で終わる）。
- **どこにいるか**: 走っている間に `jstack <pid>` を 0.25 秒おきに 40〜60 回拾い、main スレッドのフレームを数える
  （`.devbox/nix/profile/default/bin/jstack`。pid は `pgrep -f build/headless/headless.jar`）。
- **エンジンの中で**: `bench/scene3d` があれば、その数字も前後で出す。

## 報告に書く事

- 入れた物ごとの、前後の 1 コマの時間（広場・路地）と、入れずに戻した物とその理由
- 触ったファイルと、足した pub
- 流したテストと結果・`make gl-parity`・`make sync-engine-full`
- 進めなかった所（pub を変えないと無理な物・record の作りを変えないと無理な物）と、その案
