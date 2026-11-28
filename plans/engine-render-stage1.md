# 段 1: Bistro を Blender どおりの見た目で PC 60 fps — 計画（残りの読み替え版・相談用）

**2026-11-27 一本化・L5〜L7 の決めに合わせて読み替えた版**（main 6f549c941。元の版は 2026-11-26・レビュー 3 回目 90 点）。

変えた所:
- 済んだ項目（1a・1d・2c の 1 = L1）に「済み（コミット）」と目印を付けて短くした。2-0・2a は L5（`plans/engine-render-look-l5-l7.md`）へ移ったので、そちらを指すだけにした。
- 1d で入れなかった「太陽の範囲の決め方」（元の決め 2）を、残りの項目として 3（カスケード）へまとめた（今の控えはカメラが動くと太陽の地図で外れる・1 節）。
- 2b（contact shadows）・4a（SSR）を、Spec の Pass ではなく L5 が作る「描き手の中の画面の上の pass」（`Render3d.ScreenPasses` の表）と `Scene3d.ScreenInputs` に乗る形に書き直した。CPU は L5 の決め 1（案 2: GPU は AST・CPU は Flix で同じ式・gl-parity の px の上限）に合わせた。
- 2d（TAA）を描き手の中の「色の pass の後の pass」にし、前のコマの色と視点の行列を描き手が持つ形にした（4a と共有）。3・4b・2c の残りも一本化の後の書き方（AST の木で 1 回・`flagRows` の 1 行・uniform の handle の表）に合わせた。
- 見積もりを直近の実績（計画の物差しの 1/4〜1/5 + 門の待ち）で引き直し、項目ごとに wasm の増えの見込みと W2 の門（+3%）との関係を書いた。GPU の予算の線（16.7 ms）とスマホの Low の扱いを項目ごとに書いた。
- 順を「L5 → リリース → L6 → L7 → リリース」の後に引き直し、W1（`plans/engine-wasm-shader-prebake.md`・別の担当が書いている途中）との前後を書いた。
- 10 節は決まった物を消し、残る物と新しく出た物に推す答えを付けた。古い 4 節（案 A・B・C）と 2-0・2a の本文は消した（決めは L5 の計画の 3 節）。

状態: 計画（git に入れない）。レビュー 1 回目 80 点（必須 4・推奨 12・軽微 10）・2 回目 89 点（必須は全部直った・推奨 2・軽微 3）をこの版で直した。engine の拡張なので、人の了承の後に項目ごとに実装する。
**事実** は今の main のソースの引用（`bin/fge refactor` で引いた）。**推測** は「推測:」と書く。時間は実時間。

## 0. 結論

1. **段 1 の残りは L7 の後のリリースから始め、最初は 2b（contact shadows）。** L5 が作る道（奥行きの R32Float・`ScreenInputs`・`ScreenPasses` の表・CPU の `SoftRaster3d.ScreenEffects`）に行 1 つと光の式の入力 1 つを足すだけで、一番安く Bistro の接地の影に効く。
2. **画面の上の技（2b・2d・4a）は全部 L5 の道に乗せる。** PassPlan の Pass は足さない。2b と 4a は「色の pass の前」の行、2d は新しく「色の pass の後」の段を表に足す。前のコマの色と視点の行列は描き手が持ち、2d と 4a が共有する。
3. **3（カスケード）に、1d で残った太陽の範囲の決め方を入れる。** 今の控えは鍵に光の行列を入れているので、カメラが動くと太陽の地図は毎コマ描き直しになる。カスケードごとに「目に中心を置き、3 軸を格子に丸める」（元の決め 2 の (b)・了承済み）。ただし (b) は既定の 1 枚の地図を約 2 倍粗くするので、どの場面に当てるかを人に聞く（10 節の 4）。
4. **1b・1c・1e は条件つき**（人の決め）。L7 の後に Bistro の CPU を測り、4 ms の線を超えた時か draw の数が効いていると分かった時だけ入れる。今の見込みでは入れない。
5. **見積もり（実時間）**: 必ずやる道（2b・2c の残り・3・4b・2d・4a）で 10〜15 時間 + レビュー 3 回 1.5〜3 時間 = **11.5〜18 時間**。条件つき（1b・1c・1e・specular AA・bloom の作り直し）を入れて +8〜12.5 時間。
6. **wasm**: 必ずやる道の合わせて推測 +11〜21 KB（brotli）。W2 の記録（retro3d 1,551,695 B）の 3% は約 46 KB で、L5〜L7 の見込み +10〜18 KB と合わせると記録を書き換えないままでは門に近づく。**W1 を段 1 の残りより先に入れる**のと、**リリースごとに記録を書き換える**のを推す（10 節の 2・3）。
7. **GPU**: 1920×1080 の夜は、L5〜L7 の後で推測 8.5〜11 ms、段 1 の残りを全部足して 10.5〜15 ms で、PC 60 fps（16.7 ms）の内に入る見込み。3840×2160 では 18〜22.5 ms で超える。関門は 1920×1080 の 16.7 ms の線で見て、超えたら項目に入る前に止めて相談する（5.1）。
8. 区切りのリリースは 2 回（2b・3・2c の残り・4b の後と、2d・4a の後）。

## 1. 今の engine の事実（main 6f549c941）

### 1.1 済んだ物と、その後の形

| 事実 | 根拠 |
|---|---|
| 1a 済み: 3D の描き手の中の pass ごとの GPU の時間（`Render3d.GpuSpans`・WebGPU は `RenderPaint.Internal.WebGpuTimer`・GL は `GpuTimer`） | e87d13676 |
| 1d 済み: 動かない物の影の地図の控え（`Render3d.GlShadowCache` は `glBlitFramebuffer` で写す・`Render3d.WebGpuShadowCache` は控えを読んで frag depth を書く三角形で写す・表は `Render3d.ShadowCacheTable`（残す数を超えた控えを古く使った物から消す・数は使った数の 2 倍・下限 16（36b9884fc のコミットの文）・`refactor show Render3d.GlShadowCache.endFrame`））。診断 `shadowMapsReused`・`shadowMapsRedrawn`・知らせ `@shadow-cache-miss-hint`・試しの旗 `FLIX_GE_SHADOW_CACHE=off` | 36b9884fc・04ae89308・69adf60bb |
| **1d の控えの鍵は「控えの一辺・光の行列・集まりの識別」**。太陽の行列は `Scene3d.Internal.SunShadow.setupOf` が毎コマ「カメラの視錐台を囲む球」から作り、x・y を 1 画素に丸めるだけなので、**カメラが歩くか向きを変えると太陽の控えは外れる**（元の決め 2 は入っていない） | `refactor show Render3d.ShadowMaps.cacheKeyOf`・`Scene3d.Internal.SunShadow.setupOf` |
| `setupOf` の `depthBias = bias / (reach + 2r)`・`normalShift = normalBias × texel` は球の半径 r に依る（カスケードごとに違う値になる） | 同上 |
| 2c の 1 済み: 環境マップからの拡散の光（SH）`Scene3d.withSkyContribution`（L1）。あわせて L2（HDR の環境マップ `Texture3d.decodeHdr`）・L3・L4 | 122d264af〜1b7fec24c |
| 2-0・2a は L5 へ移った。main にはまだ無い（`refactor search R32Float`・`ScreenInputs` は 0 件）。L5 は別の担当が worktree で実装中 | refactor search |
| 1b・1c・1e は手つかず（`refactor search ShadowCasting` は `Scene3d.shadowCastingBillboardsOf`・`Render3d.ShadowMaps.ShadowPass` の 2 件・`minCaster`・`StaticCells`・`Cascade`・`anisotropy`・`withTaa` は 0 件）。`Render3d.StaticRows` の頭の WhyNot（持ち越す物を視錐台で間引かない）はそのまま | refactor search・`render_gl/src/Render3d/StaticRows.flix` 6 行 |
| WebGPU の場面の pass（`Render3d.WebGpuRenderer.encodeScene`）は描き先の前の中身に描き足し（load）、viewport と scissor で場面の矩形だけに描く | `refactor show Render3d.WebGpuRenderer.encodeScene`（レビューで確かめ） |

### 1.2 シェーダーの 1 本化の後の書き方（29cfa391c）

| 事実 | 根拠 |
|---|---|
| 3D の描き手のシェーダーは render_gl の `ShaderAst` の木で 1 回書き、入口 `ShaderAst.FragmentEntry`・`VertexEntry` から GLSL と WGSL を出す | `refactor search FragmentEntry / VertexEntry` |
| 手書きの入口は forbid の `render3d-shader-entry-by-hand` が止める。外すのは置いた物・材質・lit の頂点（`Render3dGlsl.MeshVertex`・`Render3dWgsl.MeshVertex`）と、WebGPU の道具の pass（`Render3d.WebGpuMipmaps`・`Render3d.WebGpuShadowCache`） | `bin/lint-rules/forbid.json` 437 行 |
| 文 `ShaderAst.Stmt` に `For`・`If`・`Return`・`Discard` などはあるが **`Break` は無い**（`For` の条件の式で止める） | `refactor show ShaderAst.Stmt` |
| 組み込みの関数 `BuiltinFn` に絵を読む物は `TextureSize` と `TargetDepthTexel`（影の地図の奥行きを画素で読む・src で使うのは `Render3dShaders.shadowLitFraction` だけ）。色や R32F の描き先を画素で読む物はまだ無い（L5-0 の (c) で足す） | `refactor show ShaderAst.BuiltinFn`・`usages ShaderAst.targetDepthTexel` |
| 変種のフラグの表 `Render3d.ProgramKey.flagRows` は今 `+ps`・`+pu`・`+psx`・`+sh` の 4 行。L5-0b が Bool の列を group 0 の binding の一覧にまとめる | `refactor show Render3d.ProgramKey.flagRows / FlagRow` |
| 差し込む点 `Render3dShaders.ShaderFeature` = `declarations`・`beforeLight`・`colorOut`・`spotShadow`・`clipOut`（太陽の影を差し替える欄は無い） | `refactor show Render3dShaders.ShaderFeature` |
| 太陽の影の読みは AST の関数 `Render3dShaders.sunLitAt`（`SunFade` の減り方・PCF は `shadowLitFraction`）。CPU は `SoftRaster3d.Sun.litAt`。式のそろいは `ExprRows.sunLitLine` | `refactor show Render3dShaders.sunLitAt`・search |
| 材質の絵の読み `sg_texMip` の本文は今も engine の `ShaderGen.texMipSource`・`ShaderGen.Wgsl.texMipSource` が字で作り、`Render3dShaders.texMip` が AST の extern として包む。**`sg_texMip` を呼ぶ字は `ShaderGen.compile3d` が材質の Spec から作る**（使う所は `compile3d`・`texMip`・テストの 3 か所で、どれも 3D の材質） | `refactor show Render3dShaders.texMip`・`usages ShaderGen.texMipSource` |
| 1,200 行に近いファイル: `SoftRaster3d.flix` 1184・`Render3d/WebGpuRenderer.flix` 1171・`ShaderAst.flix` 1103・`LightModel3d/Codegen.flix` 1081・`Render3d.flix` 1057・`Scene3d.flix` 1041 | `wc -l` |
| CPU の光の入力 `SoftRaster3d.Lights` は今も位置で並べた引数（X1 はまだ） | L5〜L7 の計画 1.1 |

### 1.3 L5〜L7 が作る物（この計画の前提）

中身は `plans/engine-render-look-l5-l7.md` が正（人が了承済み・13 節の 1〜16）。ここには段 1 の残りが使う物と節の番号だけを並べる。

| L5〜L7 が作る物 | 使う項目 | 節 |
|---|---|---|
| `RenderTarget.Format.R32Float`・奥行きの Pass `ps_depth_far` と `range` の決め方 | 2b・2d・4a | 4.1・4.2 |
| `Scene3d.ScreenInputs`（閉じた型・PostStack だけが作る・一番大きい場面 1 つにだけ入る） | 2b・2d・4a | 4.1 |
| `ScreenEffects3d`（技の値の型と表の値の 1 か所）と PostStack の alias・with・of | 2b・2d・4a | 4.4 |
| `Render3d.ScreenPasses.passesOf`（pass の表）と `GlScreenPasses`・`WebGpuScreenPasses` | 2b・2d・4a | 9.3 |
| 光の式の木の画面の入力と差し込む点の表 | 2b・4a | 4.1・9.1 |
| group 0 の binding の一覧 `Group0Binding`（L5-0b） | 2b・3・4a | 9.2 |
| texture unit の予算（16）と外す順・`@texture-unit-budget` | 2b・4a・1e | 9.4 |
| CPU の同じ式の置き場 `SoftRaster3d.ScreenEffects` | 2b・4a | 4.5 |
| gl-parity の判定（`toleranceOf` の px・差の出うる画素を結果と独立に数える）と数の線 | 2b・4a・3・4b | 3.4 |
| `@screen-effects-no-float-target` | 2b・2d・4a | 4.2 |

### 1.4 wasm の門（W2）

| 事実 | 根拠 |
|---|---|
| `make web-load-check` が `classes.wasm.br` を `testdata/web-size.tsv` の記録と比べ、`WEB_SIZE_GROWTH`（既定 3）% を超えて増えたら止める。作業中は 3D の retro3d-horror-starter だけ（記録 1,551,695 B・3% ≈ 46 KB）。2D の rpg-starter は `web-load-check-2d`（リリースの門・記録 1,063,361 B） | `Makefile` 471 行・abab6dd6d・6f549c941 |
| 記録の書き換えは `make web-size-update`（理由をコミットに）。増えた所は `bin/fge wasm-size <後> --diff <前>` | `docs/web-capture.md` 140 行 |
| 一本化で retro3d が +5.7%（上限 +6%）。ShaderAst の木と printer と変種ごとの組み立てがブラウザで実行時に走るため | 依頼文・一本化の計画 5.2 |
| W1 の計画は別の担当が `plans/engine-wasm-shader-prebake.md` に書いている途中（2026-11-27 時点でファイルは無い）。L5〜L7 の計画 12 節の W1 は「材質の Spec で実行時に作る字は残す」 | `ls plans`・L5〜L7 の計画 12 節 |

推測: wasm の増えは「AST の木（frag の式）」と「実行時の Flix（表を組む・uniform を送る・Doc を読む）」に分かれる。W1 が入ると前の分はほぼ 0 になる。`ShaderGen` が作る材質の字（4b・1e）は W1 でも減らない。CPU の描き手（engine_tools の `SoftRaster3d`）はブラウザの入口から届かないので入らない見込み（L5-5 の `--diff` の結果で確かめ直す）。

## 2. 済んだ項目

### 1a. 測る — 済み（e87d13676）

pass ごとの GPU の時間を診断に出した。測った値は末尾の「測った値」。答え: 夜の重さは点の灯りの影の GPU（11.7 ms）で、CPU は 2〜3 ms（4 ms の線の内）。

### 1d. 動かない物の影の地図の持ち越し — 済み（36b9884fc）。太陽の範囲の決め方だけ残り → 3 へ

太陽・スポット・点光源の atlas の面ごとに控え、毎コマ写して動く物だけを描く。Bistro の夜 26.0 → 14.0 ms・昼 10.3 → 9.0 ms。控えあり・なしでバイト一致。
**入れなかった物**: 元の決め 2（太陽の範囲を目に置き 3 軸を格子に丸める）。今は歩くか向きを変えると太陽の控えが外れる。カスケードはカスケードごとに同じ決め方を使うので、3 の中で 1 回だけ作る。

### 2c の 1. 環境マップからの拡散の光 — 済み（122d264af・L1）

`Scene3d.withSkyContribution`。元の決め 3 は L1 で入った。

### 2-0・2a. 奥行きの絵の形式と順・SSAO — L5 へ移った

`plans/engine-render-look-l5-l7.md` の L5（4 節）。元の「Spec の mask の Pass」は、L5 の決め 1・2 で「描き手の中の pass・GPU は AST・CPU は Flix」に替わった。

## 3. 残りの項目

各項目に「形・触るファイル・新しい pub・実時間・wasm・Low・前提」を書く。共通の決まり（L5 の道に乗る物の数え方）は 4 節。

### 2b. contact shadows（実時間 1〜1.5 時間・GPU は AST・CPU は Flix）

太陽の影の地図の 1 画素より細かい接地の影（椅子の脚・窓枠の下）を、画面の奥行きの上で光の向きへ短く進めて足す。名前は Unreal・Unity HDRP の Contact Shadows。

- **ゲームの書き方**: `PostStack.withContactShadows(Some({ length = 0.3 | PostStack.contactShadows() }), stack)`。後がけの Doc（`post.json`）からも `"contactShadows": { … }`。
  欄（開いたレコード `ScreenEffects3d.ContactShadows`）: `length`（m・既定 0.3）・`thickness`・`steps`（8〜24 に丸める）・`strength`・`fadeDistance`。
- **PostStack**: L5 と同じ。技が 1 つでもあれば `ps_depth_far` を先に描き、`ScreenInputs#contactShadows = Some(…)` を入れる。
- **描き手の中の順**: 影の地図 → AO の mask → **接地の影の mask** → 映り込み → 霧 → 色の pass（4.3）。`ScreenPasses` の表に 1 行（全部の解像度・ぼかし無し。半分だと接地の線がにじむ）。
- **式（AST の frag 1 本・`For`）**: 画素の位置から太陽の向きへ `length` を `steps` 回に分けて進み、各点を画面へ写して `ps_depth_far` と比べ、`thickness` の中で前にあれば隠れる。最大を取る（分岐なし）。揺らしは画素の位置だけの interleaved gradient noise（L5 の AO と同じ関数）。
- **掛け方**: 光の式の木の新しい入力 `ScalarInput.ScreenSunOcclusion` を、**太陽の項だけ**に掛ける（環境の光と、もう影の中の所は暗くならない）。差し込む点は `beforeLight`（4.1 の `+cs`）。半透明は読まない（L5 の AO と同じ理由）。
- **mask の置き場（10 節の 1）**: L5-0 の (h)（材質の frag の texture unit の実数）の結果で決める。
  - (b) `+cs` と `+ssr` の分（+2）を足しても 16 に収まれば: 接地の影は自分の R8（全部の解像度）・texture unit +1・binding `ContactShadowMask`。外す順では `+ao` と一緒に外す。AO は L5 のまま触らない。
  - (a) 収まらなければ: AO は L5 の `scale` のまま作り、接地の影の pass が「材質の frag と同じ読み方で取った AO」を r に、自分の値を g に書いて、全部の解像度の RG8 1 枚にまとめる（材質の frag は `+ao` の有無に依らず r = AO・g = 接地の影で読む・片方だけの時は無い方を 1 で書く）。L5 の 9.3 の `ScreenPass.format` に `Rg8` を足す。
  推す: (h) で +2 が 16 に収まれば (b)（AO の重さと gl-parity の上限を変えない）、収まらなければ (a)。
- **CPU**: `SoftRaster3d.ScreenEffects.contactShadowMask`（AO と同じファイル・同じ奥行きの配列から）。式の数と表の値は `ScreenEffects3d` の 1 か所から流す。生成した光の関数（`make gen-light3d`）の引数が 1 つ増えるので、前後で `javap -c` のバイト数を測る（8,000 バイトの JIT の上限に対する位置は測ってから言う）。
- **太陽の無い場面**: 効かないだけで止めない（L7 の霧と同じ。夜の場面のある look で常に書いてよい）。点光源の接地の影は v1 に入れない。
- **触るファイル**: engine `ScreenEffects3d.flix`・`Scene3d/Internal/ScreenInputs.flix`・`LightModel3d.flix`（入力 1 つ）・`LightModel3d/Codegen.flix`（入力の字だけ）。engine_world `PostStack.flix`・`PostStack/Internal/Passes.flix`・`PostStack/Internal/Doc.flix`・`docs/post.schema.json`。render_gl `Render3d/ScreenPasses.flix`（行 1 つと AST の frag）・`Render3d/ProgramKey.flix`（`+cs` の 1 行）・`Render3d/Uniforms.flix`。engine_tools `SoftRaster3d/ScreenEffects.flix`・`DrawHash.flix`。
- **新しい pub**: `ScreenEffects3d.ContactShadows`・`contactShadows()`・`PostStack.ContactShadows`（alias）・`contactShadows()`・`withContactShadows`・`contactShadowsOf`・`DebugView.ContactShadows`（`ScreenDebug` に `ContactShadows` の case）。内側: `VariantFlag.ContactShadows`（`+cs`）・`ScalarInput.ScreenSunOcclusion`・`R3dUniform.ContactShadowMask`（(a) なら L5 の `AoMask` を `ScreenMask` に）。
- **gl-parity**: 場面 `contactShadows3d`（仕上がり・240×140・床と椅子の脚 4 本。脚は細いので 160×90 にしない）。mask だけの場面は作らず、`ExprRows` の 1 step の判定の行で式のずれを先に見る。上限は L5 の 3.4 の決め方（差の出うる画素 = 太陽の向きへ `length` 以内に奥行きの段差がある画素を CPU の奥行きから数える）。
- **wasm**: 推測 +2〜4 KB（AST の frag・PostStack の Doc と pub）。W1 の後なら +1〜2 KB。
- **Low**: 切る（全部の解像度の mask の帯域・タイル型の GPU）。
- **前提**: L5 の全部・X1（L5 で入っていなければ 2b の前に）。L7 とは独立。

### 2c の残り. 色の仕上げ（必ずやる分 実時間 1〜1.5 時間）

1. **bloom の確かめ（0.5 時間・ゲームの側・必ずやる）**: Bistro を Blender の手本（Eevee の bloom か Glare）と並べ、look.kind.json の threshold・strength・emission の倍率で合わせられるかを先に見る。
   1 つの大きさのにじみで合わなければ、mip レベルを重ねる bloom（Call of Duty・Unity URP・Bevy の方式）に作り直す（条件つき +1〜1.5 時間）。bloom は色の曲線の前に画面全体へ掛ける後がけで奥行きも場面も読まないので、**今どおり PostStack の Spec の Pass のまま**にする（L5 の決め 2 は場面の光の式が読む技の話で、bloom は当たらない）。
2. **glb の `occlusionTexture`（ベイクした AO・0.5〜1 時間・必ずやる）**: 元の決め 4 は了承済み（L5 の後に入れる約束）。Bistro の glb が持つかを先に調べ、持てば読む（project.json の `"gltf"` の旗で選ぶ・既定は読まない）。
   形: 材質の絵の 1 枚として読み（`maxMaterialTextures()` = 6 の中・texture unit を増やさない）、材質の frag で環境の光（ambient・hemisphere・SH）に掛ける。L5 の AO の入力とは別の入力にし、`+ao` の無い場面でも効く（両方ある時は掛け合わせる）。
   **lightmap のある面には掛けない**（WhyNot: Blender でベイクした lightmap は AO を含むことが多く、二重に暗くなる）。CPU も同じ材質の読みなので 3 つの描き手で同じ式（生成した光の関数の引数が増えるので前後で `javap -c` のバイト数を測る）。`docs/scene3d.md` の「やらない事」から occlusionTexture を消す。
3. **鏡面のちらつき（specular AA・条件つき 0.5〜1 時間）**: 法線マップと低い roughness の鏡面のちらつきに、画面の上の法線の変わり方で roughness を上げる式（Godot の roughness limiter・Filament の specular AA）。
   形: 材質の frag の main（AST・`materialFragmentBody`）で `fwidth(n)` から広げる量を求め、光の式の木の新しい入力 `ScalarInput.NormalVariance` として PBR の roughness に足す（`+mr` の材質だけ）。光の式の木は画素の隣を見られないので、微分は木の外（AST の main）で取る。
   CPU は三角形の上の差から法線の変わり方を求める。GPU の `fwidth` は 2×2 の画素の差なので CPU と同じ値にはならない → gl-parity の上限は測ってから。**入れるのは 1 の並べで Bistro にちらつきが見えた時だけ**（10 節の 5）。
- **新しい pub**: 2 は `Scene3d.withOcclusionTexture`・欄 `MaterialFields#occlusion`（glb の旗は project.json のスキーマと migrations にも）。3 は内側だけ（`ScalarInput.NormalVariance`）。
- **wasm**: 必ずやる分 +1〜2 KB（glb の読み・実行時の Flix なので W1 で減らない）。条件つきの 3 は +0.5〜1 KB・mip の bloom は +1〜2 KB。
- **Low**: そのまま（安い）。
- **前提**: 無し（2 は L5 と独立に書けるが、両方ある時の掛け合わせを L5 の後に確かめる）。

### 2d. TAA（実時間 3〜4.5 時間・GPU の描き手だけ）

- **ゲームの書き方**: `PostStack.withTaa(on)`（`withFxaa` と並べる・元の決め 7 のまま）。MSAA と同時は `PostStack.Issue.TaaWithMsaa`（MSAA を切って TAA だけにする）。Bistro は MSAA 4 なので、試す時は look の MSAA を切る。
- **PostStack**: TAA は `ps_depth_far` を描く条件に入る（「技が 1 つでもあれば」に TAA を含む）。`ScreenInputs#taa = true` を入れる。FXAA の Pass は**置いたまま**にし、描き手が飛ばすか掛けるかを決める（下の FXAA の分け方）。
- **置き場（10 節の 7）**: 描き手の中の「**色の pass の後**」の pass。`ScreenPasses` の表の行にstage（`BeforeColor | AfterColor`） を足す。
  PostStack の Pass にしない理由: 揺らした投影と前のコマの視点の行列は描き手の中にしか無く、PostStack（engine_world）は render_gl を見ない。L5 の決め 2 と同じ置き場にそろえる。
- **描き先（同じ絵を読みながら書けないため）**:
  1. TAA を使う場面では、色の pass を場面の矩形の大きさの描き手の絵（Rgba16Float）へ描く（場面の描き先へ直に描かない）。
  2. TAA の pass はその絵と前のコマの絵を読み、`ScreenHistory` の新しい方へ書く。前の方と新しい方の 2 枚を交互に使う。
  3. 新しい方を**場面の矩形だけ**場面の描き先へ写し戻す（矩形の外と、場面より前に同じ描き先へ描いた物には触らない・blend は今の場面の pass と同じ）。
  場面の色の pass が描き足し（load）で前の中身に重ねていた物（2D の背景など）は TAA に混ざらない。
- **前のコマの色と視点の行列（4a と共有）**: `Render3d.ScreenHistory`（場面の並びの番号と大きさの鍵で場面ごと）。カメラが飛んだコマ（場面の切り替え・距離が大きい）と 1 コマ目は前の絵を捨てる。`RenderTarget.historyName`（PassPlan の Pass の前のコマ）は使わない。
- **揺らし**: 投影を毎コマ 1 画素未満ずらす（Halton(2,3) の 8 コマ）。**奥行きの場面（`ps_depth_far`）も同じ揺らしで描く**（揃えないと AO と接地の影の mask が色と半画素ずれる）。揺らしの番号を奥行きの場面へ渡す形は 2d-0 で決める。前の位置を求めるのは揺らしていない行列で。
- **式（AST の frag）**: 奥行きと、今と前のコマの視点の行列から、画素ごとに前の位置を求める（**動きの量はカメラだけ**・元の決め 8）。前の色を周りの 3×3 の色の範囲で切り（動く物の残像を抑える）、今の色と混ぜる。半透明の画素は奥の面の深さで前の位置を求めるので残像が出やすい（docs に書く）。
- **FXAA の分け方**: TAA が真なら、PostStack は `withFxaa` に依らず FXAA の Pass を置く。GPU の描き手は `ScreenInputs#taa` が真の時、その Pass を「入力をそのまま出力へ写す」形で飛ばす（後ろの Pass が FXAA の出力を名前で読んでも空にならない）。CPU（描き出し）は TAA を掛けず FXAA の Pass をそのまま掛ける。どちらも PostStack の組み方は 1 通りで、backend を知らなくてよい。
  CPU の絵は TAA のオン・オフで FXAA の Pass の有無が変わる分だけ変わる。`DrawHash` は FXAA の Pass の有無を今どおり見ているので、TAA の値そのものは入れない。`SoftRaster.dropped` に 1 行と `docs/backend-parity.md` の対応表。gl-parity でも切る。
- **DebugView**: show（DebugView）の時は TAA を掛けない（L5 の 6 節の show は色の pass の代わり）。
- **退行の止め方**: gl-parity に入らないので、(1) `make gl-capture-check SCENES=scene3d` に TAA の knob（同じコマ番号から同じ揺らしなので 2 回撮りでバイト一致・この機械の基準の SHA）、(2) webgpu_v2 の部屋（GL と WebGPU）、(3) `.layers/render_gl` の `TestWgslDawn`・`TestGlslEsKeywords` に TAA の frag。
- **小段**: 2d-0 スパイク（揺らしの番号を奥行きの場面へ渡す形・場面の矩形の大きさの絵へ色の pass を描いて写し戻す形が WebGPU の staticGroup の bundle（描き先の形式ごと）と group 0 に触らないか・GL の矩形の写し・0.5〜0.8）→ 2d-1 表の段・描き手の絵・`ScreenHistory`（1.2〜1.8）→ 2d-2 式と FXAA の分け方と PostStack の pub・Doc（0.7〜1.0）→ 2d-3 門・docs・早見表・お題（0.6〜0.9）。
- **触るファイル**: engine `Scene3d/Internal/ScreenInputs.flix`・投影を作る所（揺らし）。engine_world `PostStack.flix`・`Passes.flix`・`Doc.flix`・`post.schema.json`。render_gl `Render3d/ScreenPasses.flix`（段と行）・新しい `Render3d/ScreenHistory.flix`・`GlScreenPasses`・`WebGpuScreenPasses`・FXAA の Pass を飛ばす所（`RenderPaint` の PassPlan を回す所）・`GpuSpans`（`taa`）。engine_tools `SoftRaster.flix`（`dropped`）。
- **新しい pub**: `PostStack.withTaa`・`isTaa`・`Issue.TaaWithMsaa`。内側: `ScreenInputs#taa`・`R3dUniform.PreviousViewProjection`・`Jitter`。
- **wasm**: 推測 +3〜5 KB（前のコマの控え・揺らし・AST の frag）。W1 の後なら +2〜3 KB。
- **Low**: 切る（FXAA のまま）。
- **前提**: L5（`ps_depth_far`・`ScreenInputs`・`ScreenPasses`）。2b とは独立。

### 3. カスケードの影と太陽の範囲（実時間 2〜3 時間・2 つに分ける）

`plans/engine-city-scale.md` の D（段 1 = `slopeBias`・段 2 = `cascades` 1〜4・`cascadeSplit`・2×1 / 2×2 の atlas）を、一本化の後の形で入れる。あわせて 1d で残った太陽の範囲の決め方を入れる。

- **3-1 太陽の範囲と bias（1〜1.5 時間）**:
  - 範囲: `Scene3d.Internal.SunShadow.setupOf` を「箱の中心を目に置き（半径 = distance・向きに依らない）、光の空間の 3 軸を格子 g に丸め、半径を √3·g/2 広げる」に替える（元の決め 2 の (b)・了承済み）。見回しでは描き直さず、歩いて格子を越えた時だけ 1d の控えを描き直す。
    了承の条件どおり、入れる前に Bistro の歩きと見回しで (a)・(b)・(c) の当たり率と 1 画素の粗さを測ってから決める。式は `setupOf` の中だけで、3 つの描き手が同じ値を読む。
  - **(b) をどの場面に当てるか（10 節の 4）**: (b) は既定の `cascades = 1` にも当たり、控えの得が無い場面（staticGroup が無い場面）まで 1 画素が約 2 倍粗くなる（推測: 球の半径 ≈ 0.6 × distance → distance）。推す: **staticGroup がある場面か `cascades ≥ 2` の時だけ (b)**、それ以外は今の球のまま（絵も今のまま）。staticGroup を載せ外しするゲームでは途中で太陽の影の粗さが切り替わるので、docs に 1 行書く（気になるなら `cascades = 2` にすれば切り替わらない）。
  - bias: `DirectionalShadow` に `slopeBias`（既定 0）と `biasInTexels`（既定 false = 今の m のまま）。Bistro の「通りに影がほぼ出ない」は 1 画素が bias の何倍にもなった所（city-scale の #7）と見ている。
  - 変わる絵: (b) を当てた場面の太陽の影（テンプレの reference・gl-parity の太陽の場面・ゲーム側の reference）。前後を人へ見せてから `make reference-update`。migrations の手書きに「staticGroup のある場面は太陽の影の範囲と粗さが変わる」。
- **3-2 カスケード（1〜1.5 時間）**:
  - 行列は Scene3d の純粋な関数 `Scene3d.directionalShadowCascadesOf(scene)`（中身は `Scene3d/Internal/SunShadow.flix`）。カスケードごとに 3-1 の決め方と格子（カスケードの半径から）。`depthBias` と `normalShift` は半径に依るのでカスケードごとに求める。
  - GPU の式: 差し込む点 `ShaderFeature` に `spotShadow` と同じ形の欄 `sunShadow: Definition -> Definition` を足し、`+csm` の時だけ `sunLitAt` をカスケードを選ぶ版に差し替える（view の z で選ぶ）。カスケードの選びは補助の関数 1 つに置き、材質の frag の `sunLitAt` と L7 の霧の 1 tap の読みが同じ関数を呼ぶ（L5〜L7 の担当へ今伝える・10 節の外の連絡事項）。カスケードの境目の混ぜは最初は無し。最後のカスケードの外は今の `SunFade` の減り方で照らされている側へ寄せる。
  - 変種のフラグ `+csm`（cascaded shadow maps）を `flagRows` に 1 行。立った時だけ配列の uniform を読む（`Render3d.Uniforms` に `SunCascadeMatrices`・`SunCascadeSplits`・`SunCascadeCount`・`SunCascadeBias`・`SunCascadeNormalShift`。今の `SunBias`・`SunNormalShift` は `+csm` の無い字のまま）。既定の字は今と同じ。
  - 地図は 1 枚の atlas（texture unit を増やさない）。1d の控えはカスケードごとに atlas の面として持つ: WebGPU は今の `Render3d.WebGpuShadowCache` の三角形で面へ写せる（点光源の atlas と同じ道）・GL は `glBlitFramebuffer` の範囲。鍵 `cacheKeyOf` はカスケードごとの行列で、遠いカスケードほど描き直しが少ない。
  - 控えの大きさ: 2048² × 4 B × 4 カスケード = 64 MB（4096 の atlas を 4 つに分けた時）。近いカスケードは格子が細かく鍵がよく替わるので、`ShadowCacheTable` の LRU で点光源の控えを追い出さないよう、太陽の控えは「カスケードの数 × 1 世代」だけ持つ別の枠にする（古い世代は替わった時に手放す）。
  - CPU は `SoftRaster3d.Sun`・`SoftRaster3d.ShadowMaps.sunOf` を atlas で同じに。`ExprRows` にカスケードの選びの行。
- **触るファイル**: engine `Scene3d.flix`（`DirectionalShadow` の欄と pub の 1 行だけ）・`Scene3d/Internal/SunShadow.flix`。render_gl `Render3dShaders.flix`（`ShaderFeature#sunShadow`・カスケードの選び）・`Render3d/ProgramKey.flix`・`Render3d/Uniforms.flix`・`Render3d/Shadow.flix`・`Render3d/WebGpuShadows.flix`・`Render3d/ShadowMaps.flix`・`ShadowCacheTable`・`GlShadowCache`・`WebGpuShadowCache`。engine_tools `SoftRaster3d/Sun.flix`・`SoftRaster3d/ShadowMaps.flix`・`DrawHash.flix`。
- **新しい pub**: `Scene3d.directionalShadowCascadesOf`・欄 `DirectionalShadow#slopeBias`・`biasInTexels`・`cascades`・`cascadeSplit`。内側: `VariantFlag.SunCascades`（`+csm`）・`ShaderFeature#sunShadow`・uniform 5 つ。
- **wasm**: 推測 +2〜4 KB（行列の配列・AST のカスケードの選び・uniform）。W1 の後なら +1〜2 KB。
- **Low**: 2 カスケードまで・1024。
- **前提**: 無し（L5 と独立）。L7 の後に入れるので、霧の筋がカスケードの境目で切れないかを宇宙船の構図で 1 回見る。

### 4a. SSR（実時間 2.5〜3.5 時間・GPU は AST・CPU は Flix・最初の版は滑らかな面だけ）

- **ゲームの書き方**: `PostStack.withScreenSpaceReflections(Some({ .. | PostStack.screenSpaceReflections() }), stack)`。欄（`ScreenEffects3d.ScreenSpaceReflections`）: `maxDistance`・`steps`（16〜32）・`thickness`・`roughnessCutoff`（既定 0.3）・`scale`（既定 0.5）。
- **描き手の中の順**: 4.3 の並び（mask → **映り込みの絵** → 霧 → 色の pass → TAA → 前のコマの控え）。映り込みの絵は `BeforeColor` の行・`scale` の大きさの RGBA16F（rgb = 映った色・a = 当たったか）。
- **式（AST の frag・`For`）**: 法線は奥行きから作る（L5 の AO と同じ関数・法線マップの細かさは映らない）。反射の向きに `steps` 回進み、最初に奥行きを越えた点（当たった step の番号の最小を取る形・分岐なし）の色を、**2d と共有する前のコマの色**から、前のコマの視点の行列で写し直して読む（場面の色はまだ描いていないため。Godot・Unreal も前のコマの色を読む形を持つ）。
- **掛け方**: 光の式の木の新しい入力 `Vec4Input.ScreenReflection` を、roughness が `roughnessCutoff` 未満の材質で環境マップの映り込みの代わりに読み、当たらない画素と画面の外は環境マップへ混ぜて戻す。差し込む点は `beforeLight`（`+ssr`）。粗い面は今どおり環境マップ。
- **前のコマの色**: 2d が作る `Render3d.ScreenHistory` を使う。TAA を切った場面でも SSR があれば描き手が控える（その時は色の pass は場面の描き先へ直に描き、場面の矩形を `ScreenHistory` へ写す）。実機の 1 コマ目とカメラが飛んだコマは環境マップに戻る。
- **CPU**: 描き出しには前のコマが無いので、`SoftRaster3d` の中で「SSR なしの場面の色」を先に 1 回描いてそれを前のコマとして渡す（カメラは同じなので写し直しは要らず、決まった絵になる）。式は `SoftRaster3d.ScreenEffects.reflection`（Flix）。
  GPU の 1 枚撮り（gl-parity・GpuShot）も同じく 1 回目を前のコマとして控えてから 2 回目を描く（通さないと GPU だけ前のコマが空で映らず、行が外れる）。前のコマの色は実機も描き出しも「霧の後・bloom の前の HDR」にそろえる。
  SSR の場面は CPU の描き出しが 2 回になる。人の決めの数の線に当て、超えたら GPU だけ（`SoftRaster.dropped`）か場面を小さくする案を数字つきで相談する（元の決め 1 の条件のまま）。光の関数の引数が増えるので `javap -c` のバイト数を前後で測る。
- **texture unit**: 映り込みの絵で +1。L5 の 9.4 の外す順の先頭に `+ssr` を足す（環境マップへ戻るだけで、外しても一番目立たない）。
- **触るファイル**: engine `ScreenEffects3d.flix`・`ScreenInputs.flix`・`LightModel3d.flix`・`Codegen.flix`（入力の字）。engine_world `PostStack.flix`・`Passes.flix`・`Doc.flix`・`post.schema.json`。render_gl `ScreenPasses.flix`・`ScreenHistory.flix`・`ProgramKey.flix`・`Uniforms.flix`。engine_tools `SoftRaster3d/ScreenEffects.flix`・`HeadlessRender.flix`（2 回描く）・`DrawHash.flix`。`docs/scene3d.md` の「やらない事」からスクリーン空間の反射を消す。
- **新しい pub**: `ScreenEffects3d.ScreenSpaceReflections`・`screenSpaceReflections()`・`PostStack.ScreenSpaceReflections`（alias）・`screenSpaceReflections()`・`withScreenSpaceReflections`・`screenSpaceReflectionsOf`・`DebugView.Reflections`（`ScreenDebug` に `Reflections`）。内側: `VariantFlag.ScreenSpaceReflections`（`+ssr`）・`Vec4Input.ScreenReflection`・`R3dUniform.ReflectionTexture`。
- **gl-parity**: 場面 `screenSpaceReflections3d`（240×140・濡れた床と箱 3 つ）。mask だけの場面は作らず、`ExprRows` に 1 step の当たりの行。上限は L5 の 3.4 の決め方（差の出うる画素 = 滑らかな面の画素で反射の向きに奥行きの段差がある所）。
- **wasm**: 推測 +2〜4 KB（2d が先なので前のコマの控えの分は入らない）。W1 の後なら +1〜3 KB。
- **Low**: 切る。
- **前提**: L5 の全部・2d の `ScreenHistory`・X1。

### 4b. 異方性フィルタ（実時間 0.5〜1 時間・3 つの描き手）

`plans/engine-city-scale.md` の F（`MaterialFields#anisotropy`・`Scene3d.withAnisotropy`・`Mip.anisoLodOf`）。一本化の後の形:

- `sg_texMip` を呼ぶ字は `ShaderGen.compile3d` が材質の Spec から作る（1.2）。なので **`compile3d` に anisotropy を渡し、`anisotropy > 1` の材質では呼ぶ字を `sg_texMipAniso` に切り替える**。本文は `ShaderGen.texMipSource` の隣に `sg_texMipAniso` を GLSL と WGSL の 2 つの字で書き、`TestShaderGenWgslPairs` に同じ数の行を足す。`Render3dShaders.texMip` の extern に `sg_texMipAniso` の版を足す。
  WhyNot（AST で書かない）: `sg_texMip` の本文と呼ぶ字は engine の `ShaderGen` が作り、`ShaderGen` は render_gl の AST を見られない（層の向き）。
- 材質のプログラムの鍵（`ShaderGen.hashMaterial`）と staticBatch のつなぐ単位の鍵に anisotropy を入れる（入れないと違う字の材質が 1 つのプログラムと束にまとまる）。
- CPU は `ShaderEval.evalMipTex` の隣。mip レベルの式は `Mip.anisoLodOf` 1 つ（3 つの描き手が読む）。
- GL の `TEXTURE_MAX_ANISOTROPY` は使わない（mip レベルを自分で選ぶ今の作りとかみ合わず、CPU とずれる）。既定 1 = 今と同じ字。
- **新しい pub**: `Scene3d.withAnisotropy`・欄 `MaterialFields#anisotropy`・`Mip.anisoLodOf`。
- **wasm**: 推測 +1〜2 KB（`ShaderGen` の字。W1 でも減らない）。
- **Low**: そのまま（地面の材質だけ）。
- **前提**: 無し。

### 1b. 束の中をグリッドのセルで間引く（条件つき・実時間 3〜4.5 時間・pub なし）

**入れるのは L7 の後に測った Bistro の CPU が 4 ms を超えた時か、色の pass と奥行きの pass の draw が重さの上位に残った時だけ**（人の決め）。中身は元の版のまま（`plans/engine-static-group.md` の中でする事 4）で、今の main との差だけ書く:

- グリッドのセル（作る時に 1 回・束全体で 64〜128 個）・つないだ形と体を Morton 順に詰め、見えるセルの続きを 1 回の draw の範囲にまとめる・色の pass は「範囲の組の鍵」で bundle を数個だけ控える・影の pass は bundle にせず範囲で直に描く・間引きは外れる側に倒す（絵は 0 差）。
- **1d の後の効き目**: 影の pass は控えが当たるコマで 0 回なので、間引きが効くのは**色の pass と L5 の奥行きの場面（`ps_depth_far`）**と、控えを描き直すコマ（光の錐台の外のセルを控えに描かない）だけ。元の見込みの本命（夜の点光源の 6 面）は 1d で消えた。
- 奥行きの場面は staticGroup の持ち越しの `Output.Depth` の行と bundle にそのまま乗り、セルの間引きも同じ判定で効く（L5 の 2 倍の draw を抑える）。
- 控えの鍵 `cacheKeyOf` にセルの世代を足す。`Render3d.StaticRows` の頭の WhyNot を書き直し、`docs/scene3d.md` の「区画に分ける」の行を直す。
- **触るファイル**: render_gl 新しい `Render3d/StaticCells.flix`・`StaticRows.flix`・`WebGpuStatic.flix`・`GlStatic.flix`・`ShadowMaps.flix`。engine の診断の欄（`scene3dCounts` にセル・範囲・bundle の数）。
- **wasm**: 推測 +4〜7 KB（実行時の Flix だけ・W1 で減らない）。

### 1c. 影を落とす物と小さい物（条件つき・実時間 1〜1.5 時間）

**入れるのは 1b と同じ条件の時だけ**（人の決め）。推測・提案: ゲームから「小物が影を落とさないように」の要望が出た時も入れてよいか、その時に人に聞く。中身は元の版のまま:

- `Scene3d.ShadowCasting`（`On` / `Off`）と `Scene3d.withShadowCasting(c, i)`（Unity の `ShadowCastingMode`・Godot の `cast_shadow`）。欄 `InstanceFields#shadowCasting`・`Scene3d.StaticBatch` のつなぐ単位の鍵に入れる。
- `DirectionalShadow#minCasterTexels`・`PointShadowMap#minCasterTexels`（既定 0）と判定 `Scene3d.isTooSmallForShadow`（3 つの描き手と 1b が読む）。3 のカスケードの後ならカスケードごとの閾。
- **1d との組み**: 控えの鍵に `minCasterTexels` を足す（集まりの識別 `carriedKey` は shadowCasting を変えると集まりを作り直すので替わる）。
- **wasm**: 推測 +1〜2 KB。

### 1e. つなぐ単位を広げる（条件つき・実時間 2.5〜4 時間・危険 高）

**入れるのは draw の数か材質の切り替えが重さの上位に残ったと分かった時だけ**（人の決め）。中身は元の版のまま（テクスチャの配列・大きさと形式ごとの組・つなぐ形の頂点に材質の番号）。一本化の後に増えた所:

- `ShaderAst` に配列の絵の型（`sampler2DArray`・`texture_2d_array`）と読む組み込みが無い → AST に足す（`Ty` と `BuiltinFn` に 1 つずつ）。`sg_texMip` を呼ぶ字と本文は `ShaderGen` が作るので、層の番号を取る版を `compile3d` と GLSL・WGSL の 2 つの字で足す（4b と同じ形）。
- L2 の Rgba16Float の絵は配列に入れない（材質の絵だけ）。texture unit は配列 1 つ = 1 枚に数える（L5 の 9.4 の数え方に 1 行）。
- 場面の絵の予算（256 MB・64 枚）の数え方が変わる（`docs/lightmap.md`）。
- **wasm**: 推測 +3〜6 KB（WebGL2 の Java・WebGPU の bind・AST の型）。

## 4. 共通の決まり（L5 の道に乗せる物）

L5〜L7 の計画の 9 節に、段 1 の残りが足す行だけを書く。L5 の実装が入った後、その節を正として直す。

### 4.1 変種のフラグの表に足す行

| フラグ | 材質の frag | lit の frag | ビルボードの frag | 空の frag | 奥行きの frag | 差し込む点 | 項目 |
|---|---|---|---|---|---|---|---|
| `+cs` | 受ける | 受ける | 受ける（光の当たる板の太陽の項） | 受けない | 受けない | `beforeLight` | 2b |
| `+ssr` | 受ける（`+mr` の材質） | 受けない（PBR が無い） | 受けない | 受けない | 受けない | `beforeLight` | 4a |
| `+csm` | 受ける | 受ける | 受ける（影を受ける板） | 受けない | 受けない | 新しい `sunShadow` | 3 |

TAA（2d）は AfterColor の pass だけで、材質の frag にフラグを立てない。

**変種の数と W1**: L5〜L7 の `+ao`・`+vf`・`+cl` に `+cs`・`+ssr`・`+csm` が加わり、フラグは今の 4 つと合わせて 10 になる。組み合わせは倍々で増えるので、W1（字を書き出しの時に作る）には「先に組むと宣言した変種（`Scene3d.preloadVariantOf`）だけを作る」を条件として渡す（10 節の 2）。

### 4.2 group 0 の binding

`Group0Binding` に `ReflectionTexture`（`+ssr`）を足す。2b は 10 節の 1 の答えで `ContactShadowMask` を足すか、L5 の `AoMask` を `ScreenMask`（RG8）にする。`+csm` は今の太陽の地図の binding のまま（atlas）。

### 4.3 pass の表

`ScreenPass` に `stage = BeforeColor | AfterColor` を足す（2d で）。並び: AO の mask → 横 → 縦 → 接地の影 → 映り込み → 霧 →（色の pass。DebugView の時は show がその代わり）→ TAA → 前のコマの控え。DebugView の時は TAA を掛けない。技の無い物は出ない。

### 4.4 texture unit の予算

L5 の数え（材質の frag 8 + 材質の絵 6 + L5〜L7 の 4 = 18）に、2b は 0（RG8）か +1（R8）・4a は +1 で最大 20。外す順は「`+ssr` → `+ao` と `+cs`（一緒に外す）→ 材質の 6 番目の絵」。L5-0 の (h) で実在する組を数えた結果を見て直す。

### 4.5 L5〜L7 の担当へ今伝えておく事（計画の外の連絡）

- 2b で mask を RG8 にまとめる場合に備え、`ScreenPass.format` に `Rg8` を足せる形にしておく（(h) の結果次第）。
- カスケードの選びを `sunLitAt` と L7 の霧の 1 tap の読みが共有する補助の関数に置けるよう、霧の raymarch は `sunLitAt` と同じ補助の関数で太陽の地図を読む。

## 5. 順と依存

```
L5（実装中）→ リリース → L6 → L7 → リリース
  → W1（別の担当の計画が出たら。render_gl を触るので段 1 の残りと並べない。推す: 段 1 の残りの前）
L7 の後: Bistro の CPU・GPU と draw の内訳を測る（1b・1c・1e の要否を決め直す）
2b（L5 の道に 1 行）
3（3-1 太陽の範囲と bias → 3-2 カスケード。L5 と独立）
2c の残り（bloom の確かめ → occlusionTexture。specular AA は並べで見えた時だけ）
4b（独立）
  → リリース（1 回目）
2d（AfterColor の段と ScreenHistory を作る）
4a（ScreenHistory を使う）
  → リリース（2 回目）
1b・1c・1e（測りで要ると分かった物だけ・どの時点でも入れられる）
```

- **L5 の何を前提にするか**: 2b・2d・4a は L5 の全部（R32Float・`ps_depth_far`・`ScreenInputs`・`ScreenPasses`・`SoftRaster3d.ScreenEffects`・group 0 の一覧）。3・4b・2c は L5 に依らない（render_gl を 1 人が書くため、L7 の後に回す）。
- **X1**: CPU の光の入力の record。L5 で入っていなければ 2b の前に入れる（2b・4a・2c の 2（occlusionTexture）・2c の 3 が光の関数の引数を足す。どれも前後で `javap -c` のバイト数を測る）。
- **L7 との関係**: 3 は L7 の霧が呼ぶ太陽の地図の読みを替えるので、L7 の後に入れて霧の筋を 1 回見る。2b の pass は L7 の霧の pass の前。
- **2b を最初にする理由**: L5 の道に乗る一番小さい項目で、道の作りの穴（行を足す時の手間）を早く見つけられる。Bistro の椅子の脚と窓枠の接地は Blender との差の上位。
- **2d を 4a の前にする理由**: 前のコマの色と視点の行列（`ScreenHistory`）と、場面の矩形の大きさの絵へ描いて写し戻す形を TAA の確かめ（2 回撮りのバイト一致）で先に固めてから、SSR がそれを読む。
- **W1 との前後**: W1 は render_gl のシェーダーの字の作り方を触るので、同じパッケージを 2 人に触らせない決まりにより段 1 の残りと並べない。2b・2d・4a・3 は AST の木を足すので、W1 を先に入れるのを推す（10 節の 2）。W1 が遅れる時は先に段 1 の残りを進め、リリースごとに記録を書き換える（10 節の 3）。
- **関門**: 各リリースの前に Bistro の夜・昼を同じ条件（WebGPU と GL・staticGroup・`FLIX_GE_NO_VSYNC=1`・600 コマの中央値・1920×1080 と 3840×2160）で測り、末尾の「測った値」に足す。
  **CPU が 4 ms を超えたら**次の項目に入る前に止めて相談（1b を先に）。**1920×1080 の夜の GPU が 16.7 ms を超えたら**次の技に入る前に止めて相談（点光源の影の本数・技ごとの `scale` と `steps`・Low の値を数字つきで出す）。

### 5.1 GPU の見込み（PC・M4 Pro・推測）

夜の土台: 測った値は 3840×2160 の 1d の後 14.0 ms。1d の前の「画素 1/4」（= 1920×1080 相当）の 17.9 ms から点光源の影の 11.5 → 0.26 ms を引くと、1920×1080 の 1d の後は約 6.5 ms。L5〜L7 の計画 8.3 の足し分（AO・霧・cluster・奥行きで +2〜4.5 ms）を乗せた値を下の 1 行目に置いた（技の足し分は解像度で縮むが、縮めずに数えて上に寄せた）。

| 項目 | GPU（1920×1080） | GPU（3840×2160） | CPU（1 コマ） |
|---|---|---|---|
| L5〜L7 の後の夜 | 8.5〜11 ms | 16〜18.5 ms | +0.3〜0.6 ms |
| 2b 接地の影（全部の解像度・16 steps） | +0.4〜0.8 ms | +0.4〜0.8 ms | 0.05 ms |
| 2c occlusionTexture | 0.1 ms 未満 | 0.1 ms 未満 | 0 |
| 2d TAA | +0.3〜0.5 ms | +0.3〜0.5 ms | 0.05 ms |
| 3 カスケード 4 つ | 控えが外れたコマだけ。読みは選びの分 0.1 ms | 同じ | 外れたコマだけ |
| 4a SSR（半分・24 steps） | +1.0〜2.0 ms | +1.0〜2.0 ms | 0.05 ms |
| 4b 異方性（地面の材質だけ・8） | +0.2〜0.5 ms | +0.2〜0.5 ms | 0 |
| 合わせて（段 1 の残りの分） | +2.0〜4.0 ms | +2.0〜4.0 ms | 0.2 ms 前後 |

全部を足すと 1920×1080 の夜は 10.5〜15 ms で 16.7 ms の線の内、3840×2160 では 18〜22.5 ms で超える。関門は 1920×1080 で見る。4K で 60 fps を狙う時は look で SSR の `scale` を 0.25 にするか点光源の影を 2 → 1 本にする（ゲームの側・関門の数字で決める）。L7 の後の測りで 1920×1080 が 13 ms を超えていたら、2b に入る前にこの見込みを測った値で引き直す。

### 5.2 スマホ（S24・WebGPU）の Low

`PostStack.resolveQuality` の Low で決める（ゲームは何も書かない）: 接地の影 切る・SSR 切る・TAA 切る（FXAA）・カスケード 2 つまで・1024・occlusionTexture と異方性はそのまま。測り方は L5〜L7 の計画 8.2 の段取り（区切りのリリースで 1 回）。

## 6. 見積もり（実時間）と wasm

物差し: 一本化は計画 18〜24 時間に対し約 6 時間・L1〜L4 は 14〜23 時間に対し約 2 時間 15 分・1a と 1d は 13〜18 時間に対し約 3.5 時間（レビューの直し込み）。計画の物差しの 1/4〜1/5 に、GPU の門の待ち（1 項目 20〜40 分）を足した。新しい道を最初に作る 2d は上に寄せた。見込みの 2 倍を超えたら止めて相談する。

| 項目 | 元の見積もり | 実時間の見込み | 既定で絵が変わるか | wasm（brotli・推測） | W1 の後 | 確かめ |
|---|---|---|---|---|---|---|
| 2b | 6〜9 | 1〜1.5 | 変わらない | +2〜4 KB | +1〜2 | gl-parity 1 場面・`ExprRows`・webgpu_v2 |
| 2c の残り（必ずやる分） | 3〜5 | 1〜1.5 | 変わらない | +1〜2 KB | +1〜2 | Blender と並べる・gl-parity 1 場面 |
| 3 | 5〜7 | 2〜3 | **3-1 で (b) を当てた場面の太陽の影が 1 回変わる** | +2〜4 KB | +1〜2 | gl-parity（1・2・4 カスケード・atlas の境目）・控えの有無の対・Bistro の通り |
| 4b | 2〜3 | 0.5〜1 | 変わらない | +1〜2 KB | +1〜2 | gl-parity 1 場面 |
| 2d | 6〜8 | 3〜4.5 | 変わらない | +3〜5 KB | +2〜3 | gl-capture-check の 2 回撮り・webgpu_v2・動画 |
| 4a | 10〜14 | 2.5〜3.5 | 変わらない | +2〜4 KB | +1〜3 | gl-parity 1 場面・連番の描き出し |
| レビュー | — | 1.5〜3（3 回） | — | — | — | — |
| **必ずやる道** | 32〜46 | **11.5〜18** | | **+11〜21 KB** | +7〜14 | |
| 1b（条件つき） | 10〜16 | 3〜4.5 | 変わらない | +4〜7 KB | 同じ | 0 差の門・draw と bundle の数 |
| 1c（条件つき） | 3〜4 | 1〜1.5 | 変わらない | +1〜2 KB | 同じ | gl-parity 1 場面 |
| 1e（条件つき） | 8〜12 | 2.5〜4 | 変わらない | +3〜6 KB | +2〜4 | staticBatch の gl-parity・webgpu_v2 |
| specular AA（条件つき） | 1〜2 | 0.5〜1 | 変わらない | +0.5〜1 KB | +0〜0.5 | gl-parity 1 場面 |
| bloom の作り直し（条件つき） | 3〜4 | 1〜1.5 | 変わらない | +1〜2 KB | 同じ | Blender と並べる |

- W2 との関係: 記録の 3%（約 46 KB）に対し、L5〜L7 の見込み +10〜18 KB と必ずやる道の +11〜21 KB で、記録を書き換えなければ合わせて +21〜39 KB（門の手前）。条件つきを入れると超えうる。
  W1 の後の数は「先に組むと宣言した変種だけを作る」条件の時の見込み（全部の組み合わせを作ると字の分だけ逆に増える）。各項目の最初と最後に `bin/fge wasm-size <後> --diff <前>` で測って報告し、1 項目で +10 KB を超えたら止めて相談する。
- 各項目の後に Bistro の同じ視点（`assets/bistro.cameras.json`）で、Blender の手本と並べた絵と CPU/GPU の ms を残す。

## 7. 新しい pub（残りの項目）

| 項目 | pub | 数 | 出どころ |
|---|---|---|---|
| 2b | `ScreenEffects3d.ContactShadows`・`contactShadows()`・`PostStack.ContactShadows`・`contactShadows()`・`withContactShadows`・`contactShadowsOf`・`DebugView.ContactShadows` | 7 | Unreal・Unity HDRP の Contact Shadows |
| 2c | `Scene3d.withOcclusionTexture`・欄 `MaterialFields#occlusion` | 2 | glTF `occlusionTexture`・Godot の `ao_texture` |
| 2d | `PostStack.withTaa`・`isTaa`・`Issue.TaaWithMsaa` | 3 | Unity・Godot の TAA |
| 3 | `Scene3d.directionalShadowCascadesOf`・欄 `slopeBias`・`biasInTexels`・`cascades`・`cascadeSplit` | 5 | Unity Shadow Cascades・Godot PSSM・Bevy CascadeShadowConfig |
| 4a | `ScreenEffects3d.ScreenSpaceReflections`・`screenSpaceReflections()`・`PostStack.ScreenSpaceReflections`・`screenSpaceReflections()`・`withScreenSpaceReflections`・`screenSpaceReflectionsOf`・`DebugView.Reflections` | 7 | Unity HDRP・Godot の SSR |
| 4b | `Scene3d.withAnisotropy`・欄 `MaterialFields#anisotropy`・`Mip.anisoLodOf` | 3 | Unity Aniso Level・Bevy anisotropy_clamp |
| 1b | 診断の欄（セル・範囲・bundle の数） | 4 | — |
| 1c | `Scene3d.ShadowCasting`（On・Off）・`withShadowCasting`・`isTooSmallForShadow`・欄 `InstanceFields#shadowCasting`・`DirectionalShadow#minCasterTexels`・`PointShadowMap#minCasterTexels` | 6 | Unity ShadowCastingMode・Godot cast_shadow・Unreal RadiusThreshold（近い考え） |

必ずやる道で 27、条件つきを入れて 37（診断の欄を含む）。元の版の 2-0・2a の 9 と DebugView の AO は L5 の計画の 11 節へ移った。`ScreenDebug` の case（`ContactShadows`・`Reflections`）は `ScreenEffects3d` の閉じた enum の中で、migrations の auto.md に出る。
内側（pub でない）: `VariantFlag` の `+cs`・`+ssr`・`+csm`・光の式の入力 `ScreenSunOcclusion`・`ScreenReflection`・`NormalVariance`・occlusionTexture の入力・`ScreenInputs#taa`・`ShaderFeature#sunShadow`・uniform の handle。
比喩の名前は無い。`minCasterTexels` と `biasInTexels` は他のエンジンに同じ名前が無く、説明的に組んだ（地図の画素の数で決まることが読めるように）。

## 8. 誤った使い方を止める形（型 → lint → docs）

1. **型**: 技の値は `ScreenEffects3d` の開いたレコードを既定値の関数から書き替える形だけ（L5 と同じ）。`ScreenInputs` は閉じた型で PostStack だけが作る。影を落とすかは Bool でなく `ShadowCasting`。セル・控え・前のコマの色は描き手の中だけ（pub にしない）。
2. **組み方の問題**（描き出しの lint が止め、実機は 1 回知らせる）: `PostStack.Issue.TaaWithMsaa`。接地の影の太陽の無い場面は止めない（効かないだけ）。float の描き先が無い WebGL2 は L5 の `@screen-effects-no-float-target` で技を切る（新しい知らせを作らない）。
3. **知らせ**（warnOnce）: `@shadow-caster-hint`（1c）。`@texture-unit-budget` の文に SSR と接地の影を足す。
4. **lint**（`bin/lint-rules/forbid.json`）: L5 の「`PostStack.withCustom` に渡す Spec の名前が `ssao` で始まる物を止める」行に `contact_shadow`・`ssr`・`taa` を足し、それぞれの with へ案内する。
5. **docs**: `docs/scene3d.md` の「画面の上の技」の節（L5 が作る）に接地の影・映り込み・TAA を足し、太陽の影の表に欄。PBR の節の「やらない事」から SSR・異方性・occlusionTexture を消す。
   `docs/backend-parity.md` の対応表に TAA（CPU は FXAA で代える）と SSR（CPU は 2 回描く）。`agents-pack/AGENTS.core.md` の早見表に 5 行（接地の影・映り込み・TAA・異方性・カスケード）。
   `agents-pack/agent-eval/engine.json` にお題 4 本（「椅子の脚の下に細い影」→ expect `withContactShadows`・avoid `withCustom`／「濡れた床に街灯が映る」→ `withScreenSpaceReflections`／「動くと縁がちらつく」→ `withTaa`／「斜めの石畳がぼける」→ `withAnisotropy`）。1c を入れる時は「小物が影を落とさないように」→ `withShadowCasting`。

## 9. 決まりと門（項目ごと）

- 絵に触るので、**画素の差が出たら入れる前に止めて報告**（担当への依頼文に書く）。既定の場面は 0 差が条件（3-1 だけ意図した差・前後を見せてから `make reference-update`）。
- 門: `make gl-parity`（今ある行 0 px と新しい場面の `toleranceOf`）・`make baseline-check`・`make -C bench/webgpu_v2 run`・`make gl-capture-check SCENES=scene3d`（バイトまで同じ）・`.layers/render_gl` で `flix test`（`TestWgslDawn`・`TestGlslEsKeywords` に新しいフラグの版・L5 の「外した後に 16 を超える組が出ない」テスト）・`make test-engine`・`make verify SUITE=affected`・`make web-load-check`。リリースの前に全部と `make web-load-check-2d`。
- **テストの時間**: 新しい gl-parity の場面は 2b 1・4a 1（240×140・細い脚と床の映り込みは 160×90 だと数画素になり、差の出うる画素の数え方が成り立たない）・3 は 3・4b 1・2c 1（160×90）。mask だけの場面は作らず `ExprRows` の行で代える。
  推測の CPU の秒: 2b 0.1〜0.3・4a 0.2〜0.6（2 回描く）・3 0.15〜0.45・4b 0.05〜0.1・2c 0.05〜0.15 で合わせて 0.55〜1.6 秒。L5〜L7 が 1 割の予算（今 18 秒 → 1.8 秒）の 0.6〜1.8 秒を使う見込みなので、**同じ基準のままでは超えうる**（10 節の 6）。`make gl-parity-cpu`・`make gl-parity`・`make test JOBS=6` を項目の前後で測る。
- 描き手ごとの式の外（太陽の範囲・カスケードの選び・セル・小さい物の判定）は Scene3d の純粋な関数 1 つで決めて 3 つが読む。`engine_tools/src/DrawHash.flix` に新しい欄を入れる（TAA の値そのものは入れない・CPU の絵に効くのは FXAA の Pass の有無だけで、それは今どおり入っている）。
- CPU に入れない物（TAA）は `SoftRaster.dropped` と `docs/backend-parity.md` の対応表。
- 新しいファイルの後は `make sync-engine-full`・`make sync-layers`・`engine_full/src` と根の `src/` の symlink。pub を足したら `docs/api-digest` を作り直す（`make check-docs-sync`）。migrations は `<版>.auto.md`（生成物）と `<版>.md`（手書き。3-1 の太陽の影・occlusionTexture の旗）に分ける。
- 1,200 行に近いファイル（1.2）には呼ぶ 1〜2 行だけ。中身は新しいモジュール（`Render3d/ScreenHistory.flix`・`Scene3d/Internal/SunShadow.flix`・`Render3d/StaticCells.flix` など）へ。
- コメントは WhyNot。`.flix` の名前は `bin/fge refactor`。コミット・push・版上げは人の了承の後。

## 10. 人に決めてほしい事（推す答えつき）

**決まった物**（ここでは聞かない）: 元の 1（案 C → L5 の決め 1 で案 2 へ読み替え済み・数の線はそのまま）・2（太陽の範囲は (b)。測ってから最終に決める条件つき）・3（SH・L1 で入った）・4（occlusionTexture を読む・2c の残りに入れた）・5（mask の形 → L5 の決め 2）・6（1e は条件つき）・7（`withTaa`）・8（動きの量はカメラだけ）。
元の 1 の線により、SSR（4a）も CPU に入れ、線を超えたら GPU だけにする（数字を持って相談）。元の 9（リリース 4 回）は下の 7 に置き換えた。

1. **2b の接地の影の mask の置き場** → L5-0 の (h) で `+cs` と `+ssr` の分（+2）が 16 に収まれば分けた R8（AO の重さと gl-parity の上限を変えない）、余りが無ければ AO を `scale` のまま作って全部の解像度の RG8 1 枚にまとめる。
2. **W1 を段 1 の残りより先に入れるか** → 先に入れる（render_gl を触るので並べない）。W1 には「先に組むと宣言した変種だけを作る」を条件として渡す（フラグが 10 になり、全部の組み合わせを作ると字の分だけ wasm が増える）。
3. **W2 の記録（`testdata/web-size.tsv`）をいつ書き換えるか** → 区切りのリリースごとに `make web-size-update` で書き換え、増えの内訳（`--diff` の上位）をコミットに書く。書き換えないと 3% の幅を L5〜L7 と段 1 の残りで分け合い、条件つきの 1b・1e で門に当たる。
4. **太陽の範囲 (b) をどの場面に当てるか**（了承済みの (b) が既定の 1 枚の地図を約 2 倍粗くする事が分かった） → staticGroup がある場面か `cascades ≥ 2` の時だけ (b)。それ以外は今の球のまま（絵も今のまま）。別案は「既定の `mapSize` を 2048 → 4096 に上げて全部 (b)」（地図 1 枚 16 → 64 MB・全部の太陽の影の場面の SHA が変わる）。
5. **specular AA（2c の 3）を条件つきにするか** → 条件つき。Bistro を Blender と並べてちらつきが見えた時だけ入れる（CPU と GPU の微分の取り方が違い、gl-parity の上限が広くなるため）。
6. **gl-parity の 1 割の線の基準をいつ取り直すか** → 区切りのリリースごとに取り直す（W2 の記録と同じ扱い）。取り直さないと L5〜L7 と段 1 の残りの場面で 1 割を超えうる（9 節の見込み 1.15〜3.4 秒）。取り直しても 1 リリースで 1 割を超えたら、場面を小さくする案を数字つきで相談する。
7. **区切りのリリースを 2 回（2b・3・2c の残り・4b の後と、2d・4a の後）にするか** → する。門が緑なら出す（11-16 に任された判断）。1b・1c・1e は入れた時の次のリリースに乗せる。
8. **TAA を描き手の中の「色の pass の後」の pass にし、前のコマの色と視点の行列を描き手が持って SSR と共有するか** → する（PostStack の Pass にすると揺らした投影と前の行列を PassPlan へ出す入口が要る）。TAA の場面は色の pass を場面の矩形の大きさの絵へ描いて写し戻し、FXAA の Pass は GPU が飛ばし CPU が掛ける。奥行きの場面へ同じ揺らしを渡す形は 2d-0 のスパイクで決めて報告する。

## 11. やらない事

- 物ごとの動きの量（motion vector）の書き出し・TAA の upscale（TSR・FSR のような解像度を上げる形）
- SSR の粗い面（mip レベルを指定して読む映り込み）・法線マップの細かさを映す SSR
- 点光源の接地の影（2b は太陽だけ）
- 場面の Pass の描き先を 2 枚にする MRT
- GTAO・SSIL・SDFGI・clustered の影（段 2 以降）。volumetric fog と多数の点光源は L6・L7 が持つ
- 影の地図を区画ごとに持つ virtual shadow map・遠いカスケードを数コマおきに描き直す形（3 の後に要るか見る）
- GPU で間引きを決める形（indirect draw・compute の間引き）。WebGL2 に無く、1b のセルで足りるかを先に見る
- 法線の絵の pass（2b・4a・L5 は奥行きから法線を作る）
- LOD・遮蔽の間引き・visibility range（段 2）

## 測った値

### 1a・1d（2026-11-26）

2026-11-26・M4 Pro・Bistro（bistro_lab の写しを worktree の engine で）・street_night / street_day・staticGroup・描き先 3840×2160・
FLIX_GE_NO_VSYNC=1・600 コマの中央値（GPU は 16 コマに 1 回の値の中央値）。pointShadowLights = 2（draw 夜 6,192・昼 956）。
昼の 8.33 ms は 120 Hz の画面に張り付いた値。

| 描き手・場面 | 1 コマ ms | GPU 合計 | 影の地図 | scene3d | 後がけ・画面 | 影の draw 無し | 色の draw 無し | 画素 1/4 |
|---|---|---|---|---|---|---|---|---|
| WebGPU 夜 | 26.0 | 25.6 | point 11.7 | 12.1 | 1.7 | 13.9 | 13.3 | 17.9（point 11.5・scene 5.8） |
| WebGPU 昼 | 10.3 | 10.0 | sun 1.8 | 6.7 | 1.6 | 8.3〜9.0 | 8.33 | 8.33（GPU 5.4） |
| GL 夜 | 19.8 | 20.9 | point 8.1 | 11.7 | 1.1 | — | — | — |
| GL 昼 | 9.9 | 6.9 | sun 0.85 | 4.8 | 1.3 | — | — | — |

1d の後: WebGPU 夜 26.0 → 14.0（point 0.26）・昼 10.3 → 9.0（sun 0.4）・GL 夜 19.8 → 15.0（point 0.0・GPU 11.4）・GL 昼 9.9 → 9.8。
控えあり / なしの 96 コマは WebGPU 夜・昼・GL 夜でバイト一致。昼の sun 0.4 は止まったカメラの値で、歩くと太陽の控えは外れる（1 節・3-1 で直す）。

### L7 の後（ここへ足す）

（未）Bistro の夜・昼の CPU・GPU と draw の内訳（色・奥行き・影の pass ごと）。1b・1c・1e の要否と、GPU の線をこの値で決める。

## 人の決め（履歴）

### 2026-11-26

9 つの決め事は推す答えのとおり了承。1（案 C）には条件が 1 つ付いた: **テストが遅くなりすぎないこと**。
- 線: 新しい場面 1 つが 2 秒を超える、または gl-parity 全体が 1 割を超えて伸びるなら、その技は GPU の描き手だけにする（`SoftRaster.dropped` で報告）か場面を小さくする。どちらにするかは数字を持って相談する。
- 1 の案 C は、その後 L5 の決め 1（案 2: GPU は AST・CPU は Flix・gl-parity の px の上限）で読み替えた。線はそのまま当てる。

### 段 1 と段 2 の間の関門（2026-11-26）

段 1 を出した後に Bistro の PC のウィンドウの CPU を測り、roadmap の線で決める: 4 ms 以下なら段 2 へ・4〜8 ms は両方を少しずつ・8 ms 超なら段 2 の前に CPU を削る。

### 順の入れ替え（2026-11-26）

Bistro の測りで CPU は 1 コマ 2〜3 ms と分かり、重さは夜の点の灯りの影の GPU だった。段 1 は 1a → 1d を先にした（済み）。

### 2026-11-27（依頼文で伝えられた決め）

段 1 の残りは L5 → リリース → L6 → L7 → リリース の後。1b・1c の要否は L5〜L7 の後に Bistro の CPU を測って決め直す（今は 2〜3 ms・4 ms の線の内）。1e は draw の数が効いていると分かった時だけ。

### 2026-11-27（人の決め）

「おすすめで進めて」。10 節の 1〜8 は推す答えのとおり了承（2b の mask は R8 か RG8 1 枚・W1 を段 1 の残りより先・W2 の記録と gl-parity の基準は区切りのリリースごとに取り直す・太陽の範囲 (b) は staticGroup か cascades ≥ 2 の時だけ・specular AA は条件つき・区切りのリリース 2 回・TAA は描き手の中の色の pass の後で SSR と前のコマの色を共有）。
