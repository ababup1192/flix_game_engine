# 板の instanced draw（C）と DoF の奥行きを 1 回目の描画から取る（D）

人の了承: 2026-11-18（「クオリティ下げずに改善させたい」）。描き手は GL と WebGPU の両方。CPU の描き手（SoftRaster）は変えない。
**画質は下げない・絵は変えない**が前提。絵が 1 画素でも変わる所は、入れる前に人へ出して止まる。

## 背景（測った数）

bench/hd2d_town のブラウザ版（PC の Chrome・WebGPU・1280×720）: 立ち始め draw 584（shadowPass 155・billboard 318・transparent 71・material 2・mesh 38）・1 コマの CPU 6.9 ms。
スマホ（Android Chrome・WebGPU）で 1 コマの CPU 16.9 ms（上限 16.7）。

- 板（ビルボード）は 1 枚 1 draw。視錐台の中の板 232〜354 枚・絵の種類 7〜21・**来た順で絵が替わる回数 81〜148**（`make explore-draws`）。
- 手前と奥のぼけ（PostStack の DepthOfField）は、奥行きの絵（ps_depth）のために 3D の場面を Output.Depth でもう一度描く（`dof=0` で 584 → 405）。
- C を入れると描き直しの pass の板もまとまるので、D で減る draw は 179 より小さくなる。**C を先に入れて測り、D の値打ちはその数で決める。**

## 段取り（順番）

1. **C を GL と WebGPU の両方に入れ、撮り比べて 0 差を確かめ、測る。**
2. **D は GL だけで試作し、撮り比べの差を数で出す。** 下の表のとおり、bench の本命（昼・霧なし・奥行きの絵は半分の大きさ）では縁の画素が変わる見込みが高い。
   差があれば**人へ出して止まる**（WebGPU の D は了承の後）。両方の描き手を作ってから止まる無駄を避ける。

## 汎用性

- C は描き手の中だけで決める（engine の Scene3d の口は変えない）。板を並べる 3D の場面ならどれでも効く。ゲームは何も書かない。
  同じ絵の板を続けて出すほど draw が減る（docs/scene3d.md に書く）。
- D は PostStack が奥行きの絵を要る時に自分で印を付ける（ゲームは何も書かない）。印は Scene3d の口として出す（自分で Output.Depth の場面を組むゲームも使える）。

## C. 同じ絵の板を 1 回の instanced draw で描く

### まとめ方

- 板の行（Render3d.SceneList の kindBillboard）を「板 1 枚」から「**来た順で続く、同じ絵の、描く板の並び（run）**」に変える。
  欄 4 = 並びの板の数・欄 8 = 並びの頭の値の位置（並びの値は values に続けて置く）・欄 1 = 絵の番号。
  視錐台の外の板は行を作らない（描かないので、間にあっても前後の同じ絵の板はつながる）。
- **絵が見つからない板は、視錐台の外でも数 0・絵の番号 −1 の行で残す**（今の知らせ方を変えない: WebGPU は missingBillboardTexturesOf・GL は描く時に名前ごとに 1 回）。
  そのために SceneList の `billboards` は「行ごとの頭の板の中身」にする（見つからない行の名前を引く・テスト用）。
- まとめる鍵は**絵だけ**。材質は板に無い（板の program・pipeline は場面に 1 つ）。光の当て方（当てない / 当てる / 太陽の影も受ける）・位置・大きさ・anchor・
  tint・貼る範囲（regionRect）・影を受ける点を離す長さは板ごとの値（instance の値）で渡す。Physical の光の変種・Output.Depth・Design の解像度は場面ごとに決まる。
- **板は抜き（α < 0.5 を捨てる・深度を書く）だけで、半透明の板は無い**（Scene3d.billboard に blend の欄が無い）。半透明の物（足元の楕円の影など）は材質の行で、
  今のまま遠い物から 1 行 1 体で描く。半透明の重なり順は変わらない。
- **並べ替えない**理由: カメラを向く板はどの画素も同じ深度で、目からの奥行きが同じ板どうし（格子に並べた木の列など）が重なると、先に描いた方が勝つ（深度は LESS）。
  絵ごとに並べ替えると勝ち方が変わる。来た順で続く物だけをまとめれば、instanced draw の中の板は来た順にラスタライズされる（GL・WebGPU とも primitive の順は守られる）ので、
  勝ち方は今と同じ。
- 次の一手（今回は入れない）: 深度の値が同じになりうる組（目からの奥行きが刻み数個の幅に入る組）の中だけ来た順を守れば、組をまたいだ並べ替えは自由で、
  画面の重なりを調べずに O(n log n) で絵ごとにまとめられる。

### 影の段（shadowPass）

- 影の地図は**深度だけ**を LESS で書く（色の描き先が無い）。各画素は描いた物の一番近い深度になり、同じ深度なら同じ値なので、描く順で地図は変わらない。
  だから影の地図の板は**絵ごとに安定に並べ替えて**からまとめる。scissor・tile は pass ごとに決まり、並べ替えは pass の中だけ。太陽の地図・点光源の 6 面とも同じ。
- 並べ替えとまとめは `buildShadowList` の中で、**(板, 横の向き) の組を受け取ってから**行う（今は行を作った後に putBillboardRights で向きを入れている。
  向きは組のまま並べ替えて、値の欄 12〜14 へ書く）。太陽の地図は向きが pass で 1 つなので向きの無い組。
- 影の大きさの倍率（withShadowCasterScale）は今も影の地図の板の値に掛けてから行にしている（Scene3d.shadowCastingBillboardsOf）。instance の値でそのまま渡る。
- GL のシェーダーは「横の向きを instance の値から読む」uniform 1 つで切り替える（WebGPU は今の rowRight の頂点シェーダーのまま）。

### instance の値の渡し方

- 値の並びは今の Render3d.SceneList.billboardValueFloats（16 float = vec4 × 4）のまま。WebGPU は今も行の値を頂点の buffer 0 から読んでいる（stride 0）。
  - **WebGPU**: pipeline の頂点の buffer 0 の stride を 0 → 64 にし、`draw(6, 並びの板の数, 0, 0)`・頂点の buffer の大きさ = 数 × 64。WGSL は変えない。
  - **GL**: 今は uniform を板ごとに 8 個差して drawArrays。これを、場面の pass ごとに行の値の板の分を VBO へ 1 回送り（毎コマ 1 本の stream の buffer へ orphan して書く）、
    **板専用の VAO**（location 0 = 角・location 1〜4 = 値・divisor 1・stride 64）で `drawArraysInstanced(TRIANGLES, 0, 6, n)`。並びごとに 4 つの attribute の位置を
    並びの頭へ向け直す（GL 3.3・WebGL2 に base instance が無いので）。影の pass も同じ（pass ごとに送る。点光源の 6 面で送る回数が増えるのは、1 コマ 1 本へまとめる余地として残す）。
  - GL の貼る範囲の v の上下の返し（レンダーターゲットの絵 `texture#flipped`）は、今は GL が draw の時に返す。値を作る所（putBillboardValues）で
    `Context` に足す「レンダーターゲットの絵の v を返すか」（GL は真・WebGPU は偽）を見て返す。式は今の putUvRect と同じ Float64 の式（1 − v0・0 − dv）で f32 に丸める。
  - GL は行の欄 1 の texId（`tables#textureOf` で引いた物）で絵を付ける。drawBillboards に渡す textureOf と同じ関数であることが前提（prepare と draw は同じコマ・同じ登録）。
- 光の当て方は値の欄 3（0 / 1 / 2）。GL の frag は uLit・uReceive の代わりに flat の varying を読む。式（`lit && receive`）は同じ。
  sunLitAt は flat の値の分岐の中で影の地図を読むが、影の地図は NEAREST・段なしで、flat の値は primitive の中で同じなので問題ない。
- **GL は「同じになるはず」**: シェーダーの字が変わる（uniform → attribute・flat の varying）ので、GLSL として同じ値の保証は無い。撮り比べで確かめ、
  差が出たら GL だけ今の uniform の道に戻す。

### 数える所

- draw の数と分かれた理由（BatchBreak.Billboard）は、並び 1 つにつき 1 つ（今は板 1 枚につき 1 つ）。影の段は並び 1 つにつき ShadowPass 1 つ。
  FrameDiagnostics の欄・意味は変えない。描く物の数（Drawn）には今も板を入れない。
- 数を当てにしているテストを直す: TestSceneList・TestWebGpuScene3d・gl-parity の数・`make explore-draws` の出力（並びの数を足す）。

## D. DoF の奥行きを、場面を描き直さずに 1 回目の描画から取る（GL の試作）

### 口（engine）

- `Scene3d.DepthTexture` を足す（Unity URP の Depth Texture・Bevy の depth prepass と同じ考え）: `Off`（既定）・`Write`（この場面の深度を描き終えた後に残す）・
  `Read`（Output.Depth の場面を、同じコマで最後に Write した場面の深度から灰色にして描く。使えない時は今のとおり自分の instances で描き直す）。`Scene3d.withDepthTexture`。
  - Read の場面は、使える時は自分の instances を描かない（doc に書く: 中身の違う場面に Read を付けると、違う絵になる）。
  - 1 コマに Write が 2 つあれば最後の物を読む（PostStack は 1 つにしか付けない）。
- PostStack: Write は View の絵の中の一番大きい 3D の場面（Clipped の中も含む・広さが同じなら先の物＝今の largestScene と同じ選び方を 1 つの関数にまとめる）に付ける。
  Item の木を辿り、その場面の Item だけを `Render.Item.Scene3d({ depthTexture = Write | cmd })` に置き換える。
  Read は奥行きの絵の場面を作る所（depthItemOf）全部に付ける: ps_depth（DoF の DepthBand・Physical）・ps_fogdepth（DepthBand と霧の時）・depthOnly（自分の Pass の SceneDepth か霧だけの時）。
- CPU の描き手は Read でも今のとおり描き直す（絵は変わらない）。

### 描き手（GL）

- Write の場面を描き終えたら、その場面の矩形の深度を、描き手の持つ深度の絵（keep）へ blitFramebuffer で写す。描き先の深度は D24S8 の renderbuffer なので、
  写し先は D24S8 の texture（GlContext に `texImageDepth24Stencil8` を足す・LwjglGl と WebGl2 の両方）。寿命は Design の描き先と同じ寿命の表（大きさが変わったら作り直す・
  使わなくなったら捨てる・終わる時に手放す）。
- Read の場面を描く時、**使える条件**（純粋な関数 1 つ・単体のテスト）がそろえば、場面の矩形を 1 枚の四角で塗る:
  - 同じコマ（世代）に Write で残した・カメラが同じ（Camera3d が ==）・場面の大きさと解像度が同じ・残した描き先が MSAA でない・
  - 画素の並び: 残した矩形と描く矩形が同じ大きさ（1:1）、または描く矩形がちょうど半分（2:1・両辺が偶数・矩形の位置も偶数）。それ以外は描き直す。
  - 画素ごとに残した深度を読み、目からの距離を near・far・lensShift・aspect から直に戻し（逆の行列を f32 で掛けるより丸めが小さい）、
    `clamp((distance − near) / range, 0, 1)`（今の depthGray と同じ式）を書く。深度が 1（何も描かれていない）の画素は捨てる（Pass の消した白が残る）。
  - 2:1 の時は、窓の画素 4 つの深度が平らな面にそろう（向かい合う 2 組の和が近い）なら平均（角の深度と同じ）、そろわないなら手前（深度の小さい方）。
- 残す深度に入る物 = 不透明の物・板（抜いた後）。半透明の材質の行と空は深度を書かない（今の Output.Depth の描き直しも半透明の行を描かない）。

### 今の DoF の結果と同じになる条件・ならない所

| 場合 | 結果 |
|---|---|
| 1:1（霧のある時の hdrAt(1.0)・Quality.Fixed で同じ大きさ）・MSAA なし | 画素の真ん中が同じ所を読む。違いは D24 の刻みと f32 の丸め。目安: near 0.1・距離 50 m で長さ約 1.5e-3。DepthBand の range 2 なら灰色で約 7e-4（RGBA16F の 0.5 付近の 1 刻み 2.4e-4 の約 3 倍）。ぼけの量の差として撮り比べで見る |
| **2:1（霧の無い DoF の既定 shrunk(0.5)・hd2d_town の昼）** | 平らな面の中は同じ（丸めの差だけ）。**物の縁は、今のラスタライズがどちらの面を拾うかを再現できず、縁の画素の約半分が違いうる**。さらに今の描き直しは半分の画素で絵を読む（mip の段が 1 つ粗い）ので、抜きの材質と板の α < 0.5 の境目が物の縁でない所でも変わりうる（ドット絵の板は抜きの境目が多い） |
| Quality.Fixed（basis = Design の半分）・窓の辺が奇数・場面の矩形が画素に乗らない | 1:1 か 2:1 にきっちりならなければ描き直す |
| MSAA の描き先（alpha to coverage の材質は標本ごとに深度が違う） | 描き直す |
| 2 つ以上の 3D の場面・Write の後に別のカメラの場面 | 条件がそろわなければ描き直す |

- 条件は設定（窓の大きさ・Quality・MSAA）から決まり、コマごとには入れ替わらない（窓の大きさを変えた時だけ）。
- 別案（今回は選ばない）: 色の pass で距離を 2 枚目の描き先（MRT）へ同時に書けば値は描き直しと同じ式になるが、全部の材質のシェーダーと 2D の pass に手が入る。
  奥行きの絵を窓と同じ画素にする案は、ぼけの縁は細かくなるが絵が変わる。

### 試作の間の扱いと口の了承

- GL だけの試作の間、WebGPU は Write を何もしない物として扱い、Read は今のとおり自分の instances で描き直す（CPU の描き手も同じ）。
  TestWebGpuScene3d に「Read の場面を Off と同じ行で描く」を 1 本足す。
- `Scene3d.DepthTexture` / `withDepthTexture` は engine の公開の口を足す変更（AGENTS.md の「エンジン拡張は事前相談」）。人の了承は目的（品質を下げずに改善）に対する物なので、
  **口の形は D の差を人へ出す時に一緒に確かめ、それまでは試作のコミットに留める**（C と別のコミットにし、了承が無ければ落とせる形）。入れる時に
  agents-pack の早見表 1 行・agent-eval のお題 1 本・docs/scene3d.md を足す。
- 2:1 の「平らにそろう」の幅は D24 の刻み 4 個（向かい合う 2 組の和の差 ≤ 4 / 2^24）。大きさの比べは RenderTarget が丸めた**実際の描き先の画素の数**で、
  偶数の位置は Write の描き先の画素で数える。GL は行 0 が下なので、場面の矩形が窓の中ほどにある時の uv の向きをテストで見る。
- 空は GL（drawSky は深度の判定を切り depthMask は触らないが描くのは深度を消した直後で、空の四角は深度を書かない…と確かめてから書く）。
- **WebGPU に入れる時の覚え書き**: Write の場面だけ専用の深度の texture（TEXTURE_BINDING つき）で描く（同じ描き先の深度は次の場面の pass が clearDepth で消す）・
  depth24plus は copyTextureToTexture できない・MSAA なら描き直す。

### 数える所

- Read で塗った場面は DrawCalls を 1 増やすだけ（分かれた理由の欄・FrameDiagnostics の欄は足さない）。blit は数えない。描き直しの draw（場面の行ぶん）が消える。

## 見積もり（実時間）

- C: 3〜4 時間（SceneList の並び・GL の VBO とシェーダー・WebGPU の stride・影の並べ替え・テスト・gl-parity・撮り比べ）。
- D の GL の試作と撮り比べ: 4〜6 時間。WebGPU まで入れるなら合わせて 8〜12 時間。

## テストと確かめの段取り

1. 純粋な所のテスト（render_gl の TestSceneList）: 続く同じ絵の板が 1 行になる・視錐台の外の板をまたいでつながる・違う絵で分かれる・見つからない絵は外でも数 0 の行・
   値の位置が並びの頭・影の行は絵ごとに並べ替わる（点光源の向きは組のまま）・GL の v の返し。D の使える条件の関数。
2. engine_world の TestPostStack: Write が一番大きい場面にだけ付く（Clipped の中）・奥行きの絵の場面がどれも Read・奥行きの絵を描かない時は印を付けない。
3. **撮り比べは毎回同じ絵で撮る**: 時刻と入力を固定する。
   - GL: `FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=<フォルダ> FLIX_GE_FIXED_DT`（bin/gpu_run.sh の walk / final・または explore を同じ環境変数で）の決まったコマ。
   - WebGPU と WebGL2: 書き出した頁を `?capture=<n>`（dt 1/60 固定・n コマ目）で `bin/fge web-capture` が撮る（`&backend=webgl2` で WebGL2）。
   - 前の絵は今の HEAD の束・jar で撮る（worktree を HEAD のまま 1 本 export / build して控える）。まず前どうしを 2 回撮って 0 差になるのを確かめてから比べる。
   - 場面: 立ち始め・広場・夜の町。`bin/fge pixel-diff` と自前の数（平均の差・最大の差・差 > 2 の画素の割合）。
4. `make gl-parity`・`make test-engine`・層（render_gl・engine_world・engine_tools）・hd2d_town の 142 本。
5. 測り: PC の Chrome の debug=1 で draw・batch breaks・1 コマの CPU を前と後の表に（立ち始めと広場）。手元の窓（JVM・GL）も。dof=0 の差から 1 draw の値段を出す。
