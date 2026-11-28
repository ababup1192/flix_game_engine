# 太陽の光（平行光源）と、その影 — 計画（レビュー 2 回の指摘を反映）

## なぜ

今の 3D の光は、環境光・空からの光（上向きほど明るい）・点光源・スポットだけ。影を落とせるのはスポットだけ。
屋外（町・都市・野原）は、ほぼ全部が「遠くの 1 つの光（太陽）」で照らされるのに、それを表す光が無い。
PLATEAU の都市（`~/Documents/flix_ge_workspace/plateau_city`）では、建物の面ごとの明暗がつかず、建物の影も道に落ちない。
Unity の Directional Light・Unreal の Directional Light・Godot の DirectionalLight3D に当たる。

人の判断（2026-11-11）: 都市の動画を撮る前に、太陽の光など見栄えを良くする仕組みを入れる。

## 前提と順番

- **段 2 は PBR（作業ツリー `.claude/worktrees/agent-a236ff8c70f118212`・未コミット）がコミットされた後に、そこから新しい作業ツリーで始める。**
  PBR と太陽の差分を 1 つの未コミットの差分に混ぜない（別々にレビュー・コミットできなくなる）。コミットされていなければ、着手前に人へ聞く。
  太陽の鏡面は PBR の `specularTerm` に乗せる。
- **段 1 は `LightModel3d` と `Codegen` に触らないので、PBR を待たずに main から新しい作業ツリーで始めてよい。**
- 2 段に分けて進め、段ごとに門を通す:
  - **段 1（光の種類に依らない影の道）**: `Mat4.orthographic`・CPU の三角形の道の正射影・影の関数を「地図と行列を引数で受ける 1 本」にまとめる・`ShadowCaster` を `{ matrix, frustum, settings }` に。**スポットの絵が変わらない**ことを確かめる。
  - **段 2（太陽）**: 型・式・2 枚目の影の地図・場面・テスト・文書。

## ゲームから見た形

```flix
let sun = { intensity = 1.2, color = Color.rgb(1.0, 0.96, 0.88),
            shadow = Some({ distance = 600.0 | Scene3d.directionalShadow() })
          | Scene3d.directionalLight(Vec3.v3(-0.4, -1.0, -0.3)) }
let base = Scene3d.scene(camera, size);
{ directionalLight = Some(sun), environment = { ambient = Color.rgb(0.35, 0.37, 0.42) | base#environment } | base }
```

- `Scene3d.DirectionalLight = { direction, color, intensity, shadow = Option[DirectionalShadow] }`。作る関数 `Scene3d.directionalLight(direction)`（`spotLight(p, t, fov)` と同じ形で、レコードを丸ごと書かせない）。
- direction は光が進む向き（長さは問わない・内部で長さ 1 に）。
- **描く時に使う太陽は `Scene3d.directionalLightOf(scene): Option[DirectionalLight]` 1 つで決める**（`lightmapOf` と同じ考え）。direction の長さ 0・NaN・intensity ≤ 0・色が黒の時は None。
  GL・CPU・DrawHash はこれだけを読む。知らせる文は純粋な `Scene3d.directionalLightWarning(scene): Option[String]` が出し、呼ぶ側が鍵ごとに 1 回だけ言う
  （GL は `warnSceneOnce(state, "@sun:direction", line)`。`skyWarning` と同じ形。CPU は描き出しの側で同じ文面）。毎コマ通る道で `Log.warnThen` は使わない（初回だけを覚えられない）。
- **太陽は場面に 1 つまで**: `Scene3dCmd` に `directionalLight = Option[DirectionalLight]`。既定は None。`Environment3d` には足さない（ゲームが丸ごと書いているため）。
- `DirectionalShadow = { mapSize, bias, normalBias, pcfRadius, strength, distance, casterReach }`。既定値の関数 `Scene3d.directionalShadow()`
  の値は 2048・0.05 m・1.0・1・0.8・150 m・200 m（数は測って直す前提）。
  - **bias と normalBias は world の長さ（m）**。描く時に `bias / 奥行きの幅` へ直す（式を doc に書く）。normalBias は、点を `p + n × normalBias × 地図の 1 画素の world の幅` へずらしてから地図を引く。
    n は**法線マップを当てる前の頂点の法線**（裏の面の反転は当てる）。法線マップの後の法線でずらすと影の縁に模様が出る。
    段 1 でまとめる影の関数はずらす量を受ける形になり、**スポットは 0 を渡して絵を変えない**。
  - distance = カメラからどこまでに影を落とすか（Unity の Shadow Distance）。`min(distance, カメラの far)` を使う。
  - casterReach = 光の側へ、箱をどこまで延ばすか（画面の外の高い建物の影を拾う）。
  - mapSize が 0 以下なら影なし（スポットと同じ）。
- `directionalLightOf` が None なら、太陽なしと同じ（影の地図の Pass も描かない）。
- `Scene3d.scene()` の既定の ambient は白なので、太陽を足すと白く飛ぶ。doc の例で ambient を下げる。

## 中でする事

1. **光の式（`LightModel3d` の木。GL と CPU で 1 回だけ）**
   - 拡散: `color × intensity × facing × sunLit`。`l = −normalize(direction)`・`facing = clamp01(wrap + n·l)`（点光源・スポットと同じ形）。
     項は `lightingModel` の足し算の最後（`SumSpots` の後・Toon の内側）に置く。
   - PBR（metallicRoughness を持つ材質）: `l`・`facing` を束ねる小さな関数を作り、PBR 側の `specularTerm(SunColor × sunLit)` に渡す（`specularTerm` が Ref で読む名前に合わせる）。
     足す場所は `pbrModel` の `withSurface` の中の和（`SumPoints` と `SumSpots` の鏡面の隣）。`v`・`fZero`・`alpha` などはその中でしか見えない。
   - lightmap つきの面: 太陽の**拡散は足さない**（ベイクに含めるのが普通で二重になる）。**鏡面は足す**（ベイクに入るのは拡散だけ）。doc に書く。
   - **影の割合 `sunLit` は木の外で画素ごとに 1 回だけ求め**、拡散と鏡面の両方へ入力で渡す（PCF を 2 回引かない）。
     `sunLit = (n·l > 0 かつ uSunOn) ? 1 − strength × fade × (1 − f) : 1`（f = 地図の比べの割合・fade は下の薄め方）。この門と薄め方は GL と CPU が木の外にそれぞれ書く
     （届く光が正の時だけ地図を引く、スポットの WhyNot と同じ考え）。
     GL で求める所: `litFragmentSource`・`Render3d/Material.flix` の材質の frag・lightmap の枝。ビルボードは常に 1。
     Codegen は `ScalarInput.SunLit` を足し、GL では `scalarInputCode` を main で先に代入するグローバル変数の名前に写す（`toGlsl` の引数の並びを変えない）。CPU は今ある `Param.ScalarParam` で通す。
   - `Codegen.cpuEntries` に太陽の引数を足し、`make gen-light3d` で作り直し、`TestSoftRaster3dLight` を通す。
2. **影の地図（正射影・カスケード 1 段）**
   - 行列と視錐台は Scene3d の pub な関数 1 つ（例 `Scene3d.directionalShadowMatrix(scene)`）が Float64 で出し、GL と CPU が同じ物を使う（`Scene3d.shadowMatrix(spot)` と同じ考え）。
   - 箱: カメラの視錐台のうち `[near, D]`（D = `min(distance, far)`）の 8 つの角を囲む外接球（半径 r。カメラの回転で変わらない。中心と半径の式を doc の約束として書く）で横を決める。光の向きの奥行きは、球の手前に casterReach を延ばす。
   - 丸め: 地図の 1 画素の幅 = 2r / mapSize。光の空間での中心を `floor(c / 画素の幅) × 画素の幅` に。太陽の向きを毎コマ変える場面はちらつくことを doc に 1 行。
   - D の外は薄める: カメラの前の向きの深さ d で `fade = clamp01((D − d) / max(D × 0.1, 1e-6))`。置き場所は木の外の影の関数（上の sunLit）。
     ExprRows の行で GL と CPU を突き合わせる。地図の外は今の決まりどおり影なし（1）。
3. **GL（`render_gl`）**: 1 つの場面にスポットの影と太陽の影が並ぶ形にする。`ShadowCaster` を光の種類に依らない形 `{ matrix, frustum, settings }` に。太陽の分は `uSun*` の uniform の組と texture unit 12（0〜11 は使用中。GL 3.3・WebGL2 は 16 まで保証）。影の無い場面は blank の unit を指す（`putShadow` の WhyNot と同じ決まり）。GLSL の `shadowLitFraction` を、sampler・行列・bias・pcf を引数で受ける形にして 2 つの影で共有する。太陽の項は `uSunOn == 0` の時に飛ばす。
4. **CPU（`SoftRaster3d`）**: `Mat4.orthographic` を pub で足す。三角形の道に `Projection = Perspective(near) | Orthographic` を渡し、正射影では w = 1・clip の z ≥ −w で切る。`buildShadowMap` をスポットと太陽で共有。`Lights` に太陽を足す。
5. **描き出しの鍵**: `engine_tools/src/DrawHash.flix` の `putSceneCmd` に太陽を入れる（入れ忘れると描き出しの使い回しで古い絵が出る）。
6. **ビルボード**: lit のビルボードは今の点光源と同じ扱い（法線をカメラへ向けて光を受ける）。影は今どおり受けない。doc に書く。
7. **診断**: 影の地図の draw は `drawCalls` に・時間は `Phase.Shadows` に入る。

## 決まりと門

- **太陽の無い場面の絵は今と同じ**: `make gl-parity` の既存の全場面が今と同じ値・`make baseline-check` の SHA が変わらない・テンプレの reference が一致。
  GL のシェーダーの字は太陽の uniform の分だけ変わる（全部の材質のプログラムが共有する字のため。`TestRender3dGlslPinned` の固定した字と ShaderCache の作り直しは変わって当然）。CPU は太陽の項が 0 を足すだけなので、バイト一致のまま。
  字が変わった事で GL の SHA だけ割れた時は、CPU の SHA が一致し gl-parity の行が今の許容の中なら通し、割れた場面を報告する。
- **段 1 の後で、3D のスポットの影の場面（`spotShadow`・`skinBend`）と ExprRows の影の行（`shadow`・`shadowedLight`）が今と同じ値**であること（`castShadow` は 2D の影なので関係ない）。
- `bench/gl_parity` に場面を足す: 先に「正射影のカメラで箱 1 つ」（三角形の道の確かめ）、次に太陽だけ（影なし）・太陽と影・太陽とスポットの影が並ぶ・太陽と PBR の球。新しい場面は mapSize 512・pcf 1 で、許容は測ってから決める。式の行（ExprRows）に太陽と薄めの行。
- テスト: direction の長さが 1 でなくても同じ絵・長さ 0 で太陽なし・intensity 0 で太陽なしと同じ（影の Pass も描かない）・丸め（カメラを平行移動しても world の 1 点の地図の座標 × mapSize の小数部分が変わらない／カメラを回しても r が変わらない。Scene3d の純粋な関数の単体テスト）・distance の外は影なし・mapSize 0 で影なし。
- 重さ: 太陽なしの場面の 1 コマが変わらない（箱庭 約 5 ms）。太陽と影ありで、都市（区画ごと・約 50 個）の 1 コマを報告。
- 文書: `docs/scene3d.md` に節を 1 つ（付け方・ambient を下げる例・bias の単位・lightmap の面の扱い・ちらつき）・`docs/modules/` の逆引き 1 行・`make api-digest`・`agents-pack/AGENTS.core.md` の早見表 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本。
- pub の既存の型と関数の形は変えない。例外は engine の開発用の口（生成した `SoftRaster3dLight.lightAt`・`lightmapLightAt`、`SoftRaster3d.SpotShadow` の周り、`SoftRaster3d.shadowLitFractionAt` と ExprRows の影の関数の引数）。`Scene3dCmd` を丸ごと書くゲーム向けに追随メモへ 1 行。
- コメントは WhyNot。経緯は書かない。機械的な置き換えは `bin/fge refactor rewrite`。Python や perl での .flix の置換はしない。`git stash` は使わない。コミット・push・版上げはしない。

## やらない事

- カスケード 2 段以上・空気遠近（大気散乱）・神の光（光の筋）・雲の影
- 点光源の影（キューブマップ）

## 報告に書く事

- 足した pub・触ったファイル・式（前と後）
- 影の地図の箱の決め方と丸め方・薄め方の置き場所
- 段 1 の後のスポットの場面の値・段 2 の後のテストと gl-parity と baseline-check と reference の結果・`make sync-engine-full`
- 箱庭（太陽なし）と都市（太陽と影あり）の 1 コマ
- 迷って決めた所
