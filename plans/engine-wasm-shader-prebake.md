# W1: 3D のシェーダーの字を書き出しの時に作り、ブラウザの wasm から ShaderAst の木と printer を外す — 計画（実装の前）

状態: 計画（git に入れない）。engine main 6f549c941（シェーダーの 1 本化 29cfa391c と W2 の門 abab6dd6d・6f549c941 の後）の上で書いた。
**事実**はソースの行（`bin/fge refactor` で引いた）か実測。**推測**は「推測:」と書く。測りは 2026-11-27・M4 Pro。
元の 1 行: `plans/engine-render-look-l5-l7.md` の 12 節の W1。人の決め（11-26）「W1 は一本化の後の段階に」。実装は **L5 を main に取り込んだ直後**に始める（10 節）。
レビュー: 1 回目 74 点（必須 6・望ましい 12）→ この版で全部に手を入れた（どこをどう直したかは末尾の「レビューへの答え」）。

## 0. 結論

- ブラウザ版では、3D の描き手のシェーダーの字を **書き出し（`bin/fge export-web`）の時に JVM で作って wasm に埋め、実行時は表を引くだけ**にする。業界の語で言うと、Unreal の **ShaderLibrary**（packaging の時に作るシェーダーの束）と、Unity の **ShaderVariantCollection**（遊んで使った変種を記録し、書き出しはその分だけ作る）の組み合わせ。
- 作る分は「全部の組」ではなく **ゲームが使った分**。全部の組は材質の frag だけで 1 言語 3,072 本・1 本 13〜25 KB（2.4 節）なので持てない。使った分は PC で遊んだ時に描き手が記録したファイル（`web/shader-variants.json`・git に入れる）から決める。
- 材質の frag は、材質の Spec の部品（ShaderGen が実行時に作る字）を入れる **プレースホルダー 2 つを持つ template** として前もって作る。実行時はプレースホルダーを ShaderGen の字で置き換えるだけ。ShaderGen・ShaderDoc は今のまま wasm に残る（Studio と材質の Spec で実行時に作る字）。
- 見込み: retro3d-horror-starter の classes.wasm.br は 1,515 KB から **推測 −80〜−90 KB（−5.3〜−6%）**。一本化の前の 1,432.8 KB 前後に戻る。確からしさは表の大きさに掛かるので W1-0 で数え直す（8 節）。2D の rpg-starter は 3D のシェーダーを載せていないので変わらない。
- PC（デスクトップ）は今のまま実行時に作る。絵は変えない（字がバイトまで同じことを門で見る）。見積もり: **16〜20 時間**（5 節）。

## 1. 何を解くか

シェーダーの 1 本化（29cfa391c）で、render_gl の 3D の描き手のシェーダーは `Render3dShaders` の木（`ShaderAst`）で 1 回書き、`ShaderAst.Glsl` と `ShaderAst.Wgsl` が print する形になった。
代わりに retro3d-horror-starter のブラウザ版の classes.wasm.br が 1,432.8 KB → 1,515 KB（+5.7%）に増え、人の決めた上限 +6% まで 0.3% しか残っていない（`testdata/web-size.tsv` の記録は 1,551,695 バイト）。
L5〜L7 は木に AO・cluster・霧の式を足すので、このままではもっと増える。ブラウザは字を作る必要が無い（どの字になるかは書き出しの時に決まっている）ので、字を作るコードを wasm に載せない。

## 2. 今の事実（main 6f549c941）

### 2.1 変種を決める鍵

| 鍵 | 在りか | 中身 |
|---|---|---|
| 場面の変種 `ShaderVariant` | `Render3d.ProgramKey.ShaderVariant`（= `Scene3d.PreloadVariant`・`Scene3d.flix:1031`） | `pointShadows`（`+ps`）・`physicalUnits`（`+pu`）・`psx`（`+psx`）・`skyIrradiance`（`+sh`）の 4 つの Bool。16 通り。字は `Render3d.ProgramKey.variantKeyOf`（表 `flagRows` の key を並べた物）。場面のデータだけで決まる（`Scene3d.preloadVariantOf`） |
| 変種のフラグの表 | `Render3d.ProgramKey.flagRows`（`FlagRow`） | **欄 `feature` に `Render3dShaders.ShaderFeature`（木を組む関数の record）を持つ**。`rowsOf` が呼ぶたびに `flagRows()` を組み、`variantKeyOf`・`kindCodeBitsOf`・`billboardVariantOf` が実行時にそこを通る（4.3 で問題になる） |
| 材質のプログラムの形 `ProgramKind` | `Render3d.ProgramKey.ProgramKind` | `skinned`・`uv`・`normalMap`・`lightmap`・`blend`・`doubleSided`・`coverage`・`metallicRoughness`・`variant`。鍵の字は `Render3d.ProgramKey.materialKey` |
| 形を決める所 | `Render3d.ScenePlan.kindOf`（162〜167 行） | `coverage` 以外の欄はメッシュと材質のデータで決まる。`coverage` だけは `Render3d.ScenePlan.isCoverageCutout(coverage, m)` で、**描き先が標本を持つか（MSAA）で変わる**ので PC とブラウザで違いうる（レビューで欄を全部照らした。ほかに描き手で変わる欄は無い） |
| 先に作る宣言 | `Scene3d.PreloadCmd`・`App.withPreload3d`・`App.Internal.AutoPreload` | 変種の字は `Scene3d.preloadVariantKey`。材質の形までは集めない |

`TestShaderDump.surfaceKinds` が数える「材質の frag の字を変える正しい組」は、uv と法線マップの 3 通り × lightmap・blend・doubleSided・coverage・metallicRoughness の 2⁵ = **1 変種あたり 96**。× 16 変種 × 材質が絵を読むか（`readsTextures`）2 通り = **1 言語 3,072 本**。

### 2.2 実行時に字を作っている所

`bin/fge refactor usages <名前> --callers` で引いた、テストの外の呼び手（レビューで `Render3dGlsl`・`Render3dWgsl` の字の関数 60 本を全部引き直した）。

| 字 | 作る関数 | 呼ぶ所（src） |
|---|---|---|
| 頂点の色の frag・vertex | `Render3dGlsl.litFragmentSource(For)`・`litVertexSource(For)`／`Render3dWgsl.litFragmentSourceFor`・`litVertexSourceFor` | `Render3d.VariantPrograms.litProgramOfVariant`・`Render3d.buildSkinnedPrograms`（Render3d.flix:1005〜1006・呼び手は `GlRows.depthProgramFor` と `Preload.uploadCmd`）・`Render3d.WebGpuRenderer.variantFragmentOf`・`psxVertexModuleOf`（1122 行） |
| ビルボードと影の地図の frag | `Render3dGlsl.billboard*SourceFor`／`Render3dWgsl.billboard*SourceFor`・`billboardRowRightVertexSource`・`billboardShadowFragmentSource` | `Render3d.VariantPrograms.billboardProgramFor`・`Render3d.WebGpuBillboards.create`・`modulesOf`・`rowRightVertexModuleOf`（83 行） |
| 空・奥行き・blit・骨つきの置いた物 | `Render3dGlsl.skyFragmentSource`・`depthFragmentSource`・`blit*Source`・`skinnedMeshVertexSource`／`Render3dWgsl.skyVertexSource`・`skyFragmentSource`・`depthFragmentSource` | `Render3d.skyProgramOf`・`Render3d.buildPrograms`・`Render3d.buildSkinnedPrograms`・`Render3d.WebGpuSky.create`・`Render3d.WebGpuRenderer.createWith`・**`Render3d.WebGpuMipmaps.create`（59 行・mip を作るコピーの vertex に空の vertex を使う。作るのは `WebGpuMaterials.create`）** |
| 材質の vertex | `Render3dGlsl.materialVertexSourceFor`／`Render3dWgsl.materialVertexSourceFor`（手書きの `MeshVertex`。ただし `MeshVertex.vertexSnapSource` が `ShaderAst.Glsl.print`・`ShaderAst.Wgsl.print` を呼ぶ） | `Render3d.Material.buildMaterial`・`Render3d.WebGpuMaterials.vertexModuleOf` |
| 材質の frag | `Render3dGlsl.materialFragmentSource(glsl, kind)`／`Render3dWgsl.materialFragmentSource(wgsl, kind)`。中で `Render3dShaders.glslMaterialPart`・`wgslMaterialPart` が ShaderGen の字を `Body.Text` の定義 1 つ（`r3d_material`）と、cutout の α の字の式（`ShaderAst.rawExprIn`）に包む | `Render3d.Material.buildMaterial`・`Render3d.WebGpuMaterials.compileProgram` |
| 材質の部品 | `ShaderGen.compile3d`・`ShaderGen.Wgsl.compile3d`（ShaderDoc の Spec から） | 同上。**残す** |
| 2D の描き手のシェーダー | `RenderShader`・`RenderShaderCache` | **残す**（木を使っていない・wasm で 2.3 KB） |
| Studio | PC だけ | 関係しない |

字の関数を直に呼ばない（呼び手 0）とレビューで確かめた所: `Render3d.Preload`（`uploadCmd` は `buildSkinnedPrograms` 経由）・`WebGpuStatic`・影の pass（`Shadow`・`WebGpuShadows`・影の控え）・`GlOffscreen`。
光の式の木の字は `Render3dShaders.treeFunction` だけが `LightModel3d.Codegen.toGlsl`・`toWgsl` を呼ぶ。点光源の影は `Render3dShaders.pointShadowLit` だけが `LightModel3d.PointShadowCodegen` を呼ぶ。

**木の外で `ShaderAst` を実行時に使う所（レビューで見つかった）**: `Render3d.Uniforms.UniformRow`（Uniforms.flix:33）は欄 `ty = ShaderAst.Ty`・`wgsl = Option[ShaderAst.Access]` を持ち、`rowOf`（48〜140 行）が `Ty.Mat4` などを組む。`rowOf` の呼び手 `locationsOf` は `Render3d.programUniformsOf`（Render3d.flix:1038）から呼ばれ、WebGL2 でプログラムを組むたびに通る。今の wasm に `ShaderAst.Case$Ty$Mat4::<clinit>` などが載っている（`wasm-size --by name --grep ShaderAst`）。

### 2.3 wasm の中身（retro3d-horror-starter・`build/web-load-check` の書き出し）

`bin/fge wasm-size … --by module` の brotli の割り戻し:

| module | 割り戻し |
|---|---|
| `Render3dShaders` | 31.9 KB |
| `ShaderAst`・`.Wgsl`・`.Glsl`・`.Entry` | 21.0 + 9.2 + 7.7 + 6.6 KB |
| `LightModel3d.Codegen`・`PointShadowCodegen` | 20.8 + 5.5 KB |
| `Render3dGlsl`・`Render3dWgsl`・両方の `MeshVertex` | 1.1 + 2.4 + 2.4 + 1.3 KB（数を返す関数 `dataTextureWidth`・`drawBinding`・`cameraSnapAt`・`instanceBytes` などは残る） |
| （残す）`ShaderGen`・`ShaderGen.Internal.SpecKey`・`ShaderGen.Wgsl`・`ShaderDoc`・`ShaderEval` | 16.1 + 12.2 + 4.2 + 8.6 + 10.0 KB |

`--without` で関数を抜いて code 区画を詰め直した値（実際に外した時に一番近い・`go/cmd_wasmsize.go` の `writeWasmWithout`）:

| 抜いた物 | code 区画の brotli |
|---|---|
| A: `Render3dShaders`・`ShaderAst*`・`LightModel3d.Codegen`・`PointShadowCodegen`・`Render3dGlsl*`・`Render3dWgsl*` | 1,363.3 → 1,261.4 KB（**−101.9 KB**。`Render3dGlsl*`・`Render3dWgsl*` の数の関数も抜いているので、上限を少し高く見た値） |
| B: 木と光の式の Codegen だけ（ShaderAst の printer は残す） | −58.3 KB |
| C: `ShaderAst*` だけ | −38.9 KB |

rpg-starter（2D）の wasm には `Render3dShaders`・`ShaderAst`・`LightModel3d.Codegen` が 1 本も無い（`ShaderGen` 13.9 KB だけ）。

### 2.4 字の大きさ（`make shader-dump OUT=w1probe`・`TestShaderDump`）

- 今 dump する 1,507 本（材質の frag は全組でなく代表）= 3,243 万字・組んだ時間 1,911 ms（1 本あたり約 1.3 ms）・`make shader-dump` 全体は 31.5 秒（sync-layers を含む）。
- 材質の frag 1,224 本 = 30.6 MB（1 本 13〜25 KB）。全部の組（3,072 本 × 2 言語）なら推測: 120〜150 MB。
- 小さな 3D のゲーム 1 本ぶん（psx の 1 変種・頂点の色・ビルボード・空・奥行き・材質 2 形・vertex 一式）: WGSL 69,857 バイト → xz 6,464 バイト・GLSL 55,625 → 5,648 バイト（手元に brotli が無いので xz で測った。brotli の大きな窓も同じ程度の見込み）。

### 2.5 書き出しの道（`go/exportweb_build.go` の `buildWasm`）と走らせる道

- 書き出し: ① `flix build-fatjar --entrypoint WebMain.main` → ② バイトコードの付け替え（`fge.teavmfix.Rewrite`）→ ②' 位置の相対化 → ②'' 素材の埋め込み（`fge.teavmfix.Embed` が空の版の `fge.web.EmbeddedData` を中身入りの class に差し替える。`web.embed` がある時だけ）→ ③ TeaVM（`fge.teavmfix.BuildWasm`）。②'' が「空の版の Java の class を書き出しの時に差し替えて wasm に載せる」前例。
- 置き場の engine_full_web は `ensureFullWebFresh`（`go/exportweb_fullweb.go:109`）が作業コピーの engine の時だけ作り直す。`~/.flix_ge/engines/<版>` や Studio に同梱した engine は自分で make しない。
- ゲームの `make run` は `mk/game.mk:102` の `$(FGE_RUN) run`（go の `fge run`）。

## 3. 形

### 3.1 推す案 A: ShaderLibrary（書き出しで作る）＋ ShaderVariantCollection（PC で記録）

```
PC で遊ぶ（fge run / fge debug）
  └ 描き手が新しい変種・材質の形を使うたびに、その論理の鍵を web/shader-variants.json へ足す
bin/fge export-web
  ①' shader-bake.jar（engine の版に付いてくる JVM の道具）が web/shader-variants.json を読み、
     GLSL と WGSL の字（材質の frag はプレースホルダーつきの template）を作って表にする
  ②''' 空の版の fge.web.ShaderLibraryData を表入りの class に差し替える
ブラウザ
  └ 描き手は字を表から引く（作るコードを参照しない → TeaVM が落とす）
```

#### 字を求める API を 1 つにする（render_gl）

- 新しい enum `Render3d.ShaderSourceKey`（字の種類。言語を持たない）: `LitVertex(skinned, psx)`・`LitFragment(variant)`・`BillboardVertex(variant, right)`・`BillboardFragment(variant)`・`BillboardShadowFragment`・`SkyVertex`・`SkyFragment`・`DepthFragment`・`BlitVertex`・`BlitFragment`・`MeshVertex(skinned)`・`MaterialVertex(skinned, uv, lightmap, psx)`・`MaterialFragmentTemplate(kind, readsTextures)`。L5〜L7 の新しい pass はここに case を足す。鍵の字は `Render3d.ShaderSourceKey.toKeyString`。
- 新しい record `Render3d.ShaderSourceProvider = { glsl: ShaderSourceKey -> Option[String], wgsl: ShaderSourceKey -> Option[String] }`（純粋。記録は別の所でする・下）。
  - PC の実体 `Render3dShaders.makeRuntimeProvider()`: 今の `Render3dGlsl`・`Render3dWgsl` の関数を match で呼ぶ（いつも `Some`・字は今と 1 字も同じ）。
  - ブラウザの実体（engine_web の `WebLayer.Internal.WebShaderLibrary`）: `fge.web.ShaderLibraryData.table()` を 1 回読んだ `Map[String, String]` を引く。
- 描き手（GL の `Render3d.State`・WebGPU の `Render3d.WebGpuRenderer` の状態・`WebGpuMaterials` と `WebGpuMipmaps` を作る所）は作る時に `ShaderSourceProvider` を受け取って持ち、2.2 の呼ぶ所は全部ここを通す。ブラウザの束は `makeRuntimeProvider` を 1 度も参照しないので、TeaVM は木・printer・Codegen を辿らない。
- 「層を置く物差し」（実装が 2 つある所だけに境目）: PC の「その場で作る」とブラウザの「表を引く」の 2 つ。境目は描き手を作る時の引数 1 つで、新しい effect は足さない（effect にすると描き手の 30 か所以上の型に効果が増える）。

#### 材質の frag の template（プレースホルダー 2 つ）

- `Render3dShaders.materialFragmentTemplate(kind, readsTextures, lang)`: 材質の部品の字をプレースホルダー `/*@R3D_MATERIAL_PLACEHOLDER@*/`、cutout の α の式をプレースホルダーの名前 `r3d_cutoutAlphaPlaceholder` にした `MaterialPart` で print する。
- `Render3d.ShaderLibrary.withMaterialPart(template, partText, cutoutAlpha): String`: 正規表現でなく文字のまま置き換える（ShaderGen の字に `$` などが入りうる）。**cutout の α を先に、材質の部品を後に**置き換える（部品の字の中を二度置き換えないため）。cutout の α は coverage の版で 2 回以上出るので全部。
- **cutout の α は atom だけを受ける**（レビュー 1・2 回目の指摘）: ShaderAst は raw の字を素通しするが、`ShaderAst.precOfNode`（1040〜1054 行）が `Node.Raw` の字を `isAtomText`（444〜454 行）で見て強さを決め、`ShaderAst.Glsl.exprAt` は `precOfNode < ctx` の時だけ括弧を付ける。だから atom でない字は、出る位置（`lt(alpha, 0.5)` の左・`fwidth(alpha)` の引数・`sub(alpha, 0.5)` の左）ごとに括弧の有無が変わり、置き換える側で 1 つの規則にそろえられない。プレースホルダーの名前は atom なので、**template が直の print と一致するのは cutout の α が atom の時だけ**。そこで `withMaterialPart` は cutout の α が atom かを確かめ、atom でなければ `bug!`（ShaderGen が守る約束が破れた所。error-handling.md の「プログラマの前提」）。約束は ShaderGen の側のテスト「`compile3d`・`Wgsl.compile3d` の `cutoutAlpha` はどの Spec でも atom」で止める。今の cutout の α は `"materialCutoutAlpha()"` と `"albedo.a"` の 2 つで、どちらも atom（`TestShaderWorld3d` 350〜360 行）。atom の判定 `isAtomText` は **engine の側**の小さなモジュール `ShaderText`（`engine/src/shader/ShaderText.flix`・ShaderGen の隣）へ出し、render_gl の ShaderAst と `withMaterialPart`、engine の ShaderGen のテストが同じ 1 本を使う（engine のテストは render_gl を読めないので engine に置く。`withMaterialPart` から `ShaderAst` の残りを参照しないためでもある）。
- 成り立つことをレビューで確かめた所: `Body.Text` は `bodyText` で字のまま出る・GLSL の uniform の集め方（`glslUniformsOrBug`）は `bodyUniforms` が `Body.Generated` しか見ないので材質の字に依らない・微分の扱いは `partIn` と `rawExprIn` が `derivative = false` の決め打ち・宣言の並びは `texMip(part)` の deps が `readsTextures` だけで決まる。
- 見えない約束: `readsTextures` が真の時、`sg_texMip` の定義は材質の字の中にあり、木の側は `Body.Outside`（Render3dShaders.flix:319〜323）。等価のテスト（7 節）の材質に、絵を読む物と読まない物の両方を入れて止める。
- PC もブラウザも材質の frag はこの「template → 置き換え」の 1 本の道にする（PC は template をその場で作って、変種と形と `readsTextures` の鍵で控える）。置き換えの誤りは PC の絵とテストで見える。

#### 使う分を決める（ShaderVariantCollection）

- **記録するのは論理の鍵**（言語と描き手によらない）: 使った場面の変種（`variantKeyOf` の字）と、使った材質の形（`ProgramKind` から変種を除いた欄 + `readsTextures`）。鍵は場面から純粋な関数 `Render3d.ShaderLibrary.collectionKeysOf(scene: Scene3d.Scene3dCmd): CollectionKeys` で求める（中で `Render3d.ScenePlan.kindOf` と `Scene3d.preloadVariantOf` を呼ぶ・coverage は真偽の両方を返す）。描き手はこの関数を場面ごとに呼び、新しい鍵を見た時に控えへ足してファイルへ書く（IO はこの小さな関数だけ。`ShaderSourceProvider` は純粋のまま）。`ShaderSourceProvider` の中で記録しないのは、そこに来るのが GL だけの blit・`ByUniform` のビルボードのような言語ごとの物理の鍵だから。同じ純粋な関数を、7 節のテンプレートの門も使う。
- 作る側が両方の言語の要る字へ広げる（`Render3d.ShaderLibrary.requiredKeysOf(collection)`）:
  - 変種 v ごと: `LitVertex`（骨つきと無しの両方）・`LitFragment`・`BillboardVertex`（横の向き 3 通り）・`BillboardFragment`。
  - 材質の形ごと: `MaterialVertex`・`MaterialFragmentTemplate`。cutout の形は `coverage` の真偽の両方（2.1 の MSAA の差）。
  - いつも（**既定の一式**）: 既定の変種（`defaultShaderVariant`）の `LitVertex`（骨つきと無し）・`LitFragment`・`BillboardVertex`（横の向き 3 通り）・`BillboardFragment`、それに `SkyVertex`・`SkyFragment`・`DepthFragment`・`BlitVertex`・`BlitFragment`・`MeshVertex`（骨つきと無し）・`BillboardShadowFragment`。材質の形は入れない（材質の形は場面に依るので、いつも作る物が無い）。
- `collectionKeysOf` が `Render3d.ScenePlan` と同じ決め方を写す所（ずれると記録が漏れるので、列で持ち、下の「描き手が求めた鍵 ⊆ 記録から広げた鍵」のテストで止める）:

| | 写す決め方 | ScenePlan の側 |
|---|---|---|
| (a) | 奥行きの場面（`Output.Depth`）は `passVariantOf` の変種（既定）・coverage は偽・材質の形は `cutout or doubleSided` の材質だけ・半透明は外す | `ProgramKey.passVariantOf`・`ScenePlan.kindOf` の Depth の枝 |
| (b) | 影の pass は鍵が要らない（既定の一式の奥行き・ビルボードの影の frag で描く） | `Render3d.Shadow`・`WebGpuShadows` |
| (c) | multiMeshes は `groupedOf` でまとめた後の材質と形 | `Render3d.MultiMeshPlan` の `groupedOf` |
| (d) | 静的な組（`staticGroup`）の中の物も数える | `Render3d.StaticRows`・`WebGpuStatic` |
| (e) | 視錐台で消す前の全部の物を数える（カメラの向きで鍵が変わらないように） | ScenePlan の視錐台で消す所の手前 |

- ファイルの形（`web/shader-variants.json`）: `{ "version": 1, "variants": ["", "+psx"], "materialShapes": [{ "skinned": false, "uv": true, "normalMap": false, "lightmap": false, "blend": false, "doubleSided": false, "cutout": true, "metallicRoughness": false, "readsTextures": true }] }`。並べ替えて重ねず書く（git の差は新しい鍵の行だけ）。書く時は一時ファイルから rename。読む時は知らない欄と知らないフラグの字を読み飛ばし、無い欄は偽で読む（`docs/save-compat.md` の「欄は既定値で読む」と同じ考え）。`version` が今より新しければ書き出しを赤にする。L5-0b が `FlagRow`・`ProgramKind` を作り替えても、記録は欄の名前とフラグの字で持つので古い行はそのまま読める。
- **記録の旗は `fge run`・`fge debug`（go）の側で立てる**: ゲームの根に `web/WebMain.flix` がある時だけ、`FLIX_GE_SHADER_VARIANTS=<ゲームの根>/web/shader-variants.json` を付けてゲームを起こす。Makefile を通らない外のゲームと Studio から走らせた時にも届き、Web に出さない 3D のゲームのフォルダには書かない。読み込み（`Render3d.ShaderLibrary.loadCollection` は `Result` を返す・`saveCollection`）は error-handling.md に従い、無いのは正常（何も言わずに空から始める）・あるのに読めない時だけ `Log.fellBack` で 1 行言う。

#### 表に無い鍵の時

- **既定の一式**（上の「いつも」）の鍵が無いのは、同じ engine の版の shader-bake.jar が作った表なので起こらない前提が破れた所 → `bug!`（error-handling.md の「プログラマの前提が破れた所」）。
- 記録に依る鍵（**既定でない変種**ごとの物・材質の形ごとの物）が無い時は、その描き物を描かずに続ける。どこで何が出なくなるか（10 か所）:

| 欠けた鍵 | 出なくなる物 | 飛ばす所（GL） | 飛ばす所（WebGPU） |
|---|---|---|---|
| 既定でない v の `LitFragment(v)`・`LitVertex(_, psx)` | その変種の場面の、頂点の色で描く物（材質を持たない物）全部 | `VariantPrograms.litProgramOfVariant` | `WebGpuRenderer.variantFragmentOf`・`psxVertexModuleOf` |
| 既定でない v の `BillboardVertex(v, _)`・`BillboardFragment(v)` | その変種の場面のビルボード全部 | `VariantPrograms.billboardProgramFor` | `WebGpuBillboards.modulesOf`・`rowRightVertexModuleOf` |
| `MaterialFragmentTemplate(kind, rt)`・`MaterialVertex(..)` | その形の材質の物だけ | `Material.buildMaterial`（frag と vertex の 2 か所） | `WebGpuMaterials.compileProgram`・`vertexModuleOf` |

  - `buildSkinnedPrograms`・`buildPrograms`・`skyProgramOf`・`WebGpuSky.create`・`WebGpuMipmaps.create`・`WebGpuBillboards.create`・`WebGpuRenderer.createWith` は既定の一式だけを読むので `Option` にしない（無ければ `bug!`）。`psxVertexModuleOf` の呼び手は psx の版だけなので、記録に依る側の鍵（`LitVertex(_, psx = true)`）として飛ばす側に置く。`rowRightVertexModuleOf` は既定の変種でも呼ばれうるので、既定の変種なら既定の一式の鍵を読み（無ければ `bug!`）、そうでない時だけ飛ばす側。
  - 型の変わる所: GL の `VariantPrograms.litProgramOfVariant`・`billboardProgramFor`・`Material.buildMaterial` は今 `ProgramUniforms`（`Option` でない）を返す。`Option` を返す形へ変え、呼び手（ScenePlan から描く所・`GlRows`・`Preload` の材質の先作り）を「`None` ならその描き物を飛ばす」へ直す。WebGPU の 4 か所も module・pipeline の控えを `Option` にする（推測: 呼び手まで含めて GL 10〜15 か所・WebGPU 10 か所前後。W1-0 で数え、W1-1 に +1.5 時間を入れた）。
  - 知らせ方: `Log.fellBack("shader", <鍵の字>, "skip", "web/shader-variants.json に無い。PC で fge run してその場面を一度通してから書き出し直す")` を**鍵ごとに初回の 1 回だけ**（毎フレーム通る経路なので）。ブラウザでは同じ字を `console.error` にも出す。

### 3.2 別案

| 案 | 中身 | wasm の減り | 落とした・後へ回した理由 |
|---|---|---|---|
| **A（推す）** | 上のとおり | 推測 −80〜−90 KB（8 節） | — |
| B: 全部の組を engine の版で作って配る | 記録をやめ、全部の鍵の字を engine の束に入れる | −102 KB − 束の大きさ | 材質の frag だけで 120〜150 MB（2.4）。定義ごとに字を分けて重ねない形にしても、main の本文が組ごとに違い 1 言語 10 MB を超える（推測） |
| C: 固定のプログラムだけ前もって作り、材質の frag は今のまま木で作る | template を作らない | −58 KB より少ない（材質の frag が木と光の式と ShaderAst を全部使うので、ほとんど残る） | 減りが半分以下。L5〜L7 の増えも材質の frag に入るので止まらない |
| D: 木を wasm の後から取る側へ分ける（wasm-split） | 表に無い時だけ木を取る | 先に取る側で −102 KB | 分ける仕組みがまだ無い（`plans/web-loading-p4.md` の 4 節）。分けると 2 本の合計が 25〜30% 太る（同 623 行）。A の後に、表に無い時の救いとして考える余地はある |
| E: 木を組むコードを軽くする（効果の受け渡しを生まない書き方へ） | 型の目印（`with Marker[t]`）や record の作り方を変える | 推測: 木の分の 2〜3 割（−20〜30 KB） | 字を作るコード自体は残り、L5〜L7 で増え続ける。W1-0 で 30 分だけ試して数字を残す（決める前に別案も軽く試す） |
| F: 書き出しの時にゲームの fatjar（①の物）を別の入口で走らせて字を作る | 新しい jar を作らない | A と同じ | `--entrypoint WebMain.main` の fatjar はもう 1 本の入口を持たない。入口を足すと build-fatjar を 2 回流すことになり、書き出しが分単位で延びる |
| G: gallery の場面から鍵を拾う | PC で遊ばなくてよい | A と同じ | 鍵は場面からの純粋な関数（`collectionKeysOf`）で求まるので、gallery の場面（`SceneRender.allShots` など）からも描き手なしで拾える。ただし gallery が全部の場面を通る保証は無く、遊んで初めて出る場面（階を移った後・Doc で psx を切り替えた）を落とす。**A に足す源ではなく、テンプレートの漏れの門（7 節）に使う** |
| H: 記録の時に字まで書く | shader-bake.jar が要らない | A と同じ | engine の版が上がると字が古くなり、記録を全部取り直すまで絵がずれる。論理の鍵なら版が上がっても読める |
| I: 材質の形の材質側の欄を書き出しの時に素材から拾い、変種だけを記録する | 記録の漏れが減る | A と同じ | 材質はゲームのコードが組む（`School.materialsOf` は `Scene3d.texturedMaterial` に `withEmission` を足す）ので、素材（glb と Doc）を読むだけでは決まらない。ゲームを走らせずに拾う道が無い |

## 4. 書き出しの道とブラウザの側

### 4.1 字を作る道具（shader-bake.jar）

- engine の中に小さな Flix のパッケージ `tools/shader-bake`（render_gl の層に依存・入口 `ShaderBake.main`）を置き、`make sync-engine-full-web` が fge-web-tools と同じく jar を作って置き場へ置く（engine の版と内容の hash で 1 回）。
- **配った engine（`~/.flix_ge/engines/<版>`・Studio に同梱）でも使えるように、リリースの束に shader-bake.jar を fge-web-tools と同じ置き場のエントリで入れる**。`/release` の手順と `release-guard` の「配る物の一覧」に 1 行足す。go の書き出しは jar を fge-web-tools と同じ探し方で探し、無ければ「engine を入れ直す（作業コピーなら engine の根で make sync-engine-full-web）」と出す。
- 引数: `web/shader-variants.json` の道・出す道。出す物は `{ "glsl": { 鍵: 字 }, "wgsl": { 鍵: 字 } }` の JSON 1 つ（鍵は `ShaderSourceKey.toKeyString`）。
- 字は PC の描き手と同じ関数（`makeRuntimeProvider()`）で作るので、作る道の違いで字がずれる所は無い。

### 4.2 wasm に載せる

- engine_web に空の版の Java の class `fge.web.ShaderLibraryData`（`static String[] table()`・`EmbeddedData` と同じ形。WhyNot: static final の定数にしない — javac が呼ぶ側へ値を写す）。
- `fge.teavmfix.Embed` に「シェーダーの表を差し替える」道を足し、②'' の隣の ②''' として流す。表は `[鍵, 切れ端の数, 切れ端…]` の繰り返し（Java の定数 1 つは 64 KB まで）。素材の符号（`EmbeddedCodec`）は通さない（隠す必要が無く、起動の時の復号の分が無駄）。
- ブラウザは描き手を作る時に表を 1 回だけ `Map` にする（推測: 数十本で 1 ms 未満）。
- 別案: 束の中の別ファイル（assets）にして起動の時に取る。WebGL2 の時だけ GLSL を取れるのが利点だが、描き手を作る前に Fs の待ち（LoadProgress）が要り、1 本 6 KB 前後のために起動の流れを触ることになる。推さない。

### 4.3 TeaVM に落とさせるために参照しない物（W1-1 で全部を外す）

1. 2.2 の呼ぶ所（15 か所）から `Render3dGlsl`・`Render3dWgsl` の字の関数を直に呼ぶのをやめ、`ShaderSourceProvider` を通す。`WebGpuMipmaps.create` まで provider を渡す道を作る（`WebGpuMaterials.create` ← `createWith`）。
2. **`Render3d.ProgramKey.FlagRow` の欄 `feature` を外す**。代わりに `Render3dShaders.featureOfFlag(flag: VariantFlag): ShaderFeature`（match。フラグを足すと網羅の検査で止まる）。L5-0b の `FlagRow` のリファクタと同じ所を触る（10 節）。
3. **`Render3d.Uniforms.UniformRow` から `ShaderAst` の型を外す**。実行時の名前の表は `name`・`glsl`（GLSL の宣言の型の字）・`length` の 3 つで足りる（`locationsOf`・`nameTable`・`handleIn` が読むのはこれだけ。WebGPU の欄の読みは実行時に引かない）。木で読む時の欄（`ty`・`wgsl`）は木の側の表へ分け、`ShaderAst.Ty` と `ShaderAst.Access` を組むのは `refOf`（木の側）だけにする。
4. ブラウザの WebLayer が描き手を作る時に、PC の既定（`makeRuntimeProvider` を使う作り方）を参照しない。作る関数は「`ShaderSourceProvider` を受け取る版」と「PC の既定の版」に分け、engine_web は前者だけを呼ぶ。

`Render3dShaders` の 80 の pub のうち、字を作る道の外から使われているのは `ProgramKey.FlagRow`・`flagRows` の 4 つだけ（レビューで全部引いた）。2 で外れる。

確かめる手: `bin/fge wasm-size <書き出し> --by module --grep <語>` で `ShaderAst`・`Render3dShaders`・`LightModel3d.Codegen`・`PointShadowCodegen` が **0 本**。web-load-check にこの 4 つの 0 本の検査を足す（7 節）。

## 5. 段階と見積もり

一本化の実績（計画 18〜24 時間に対し約 6 時間）は render_gl の中だけの仕事だった。W1 は go・Java・TeaVM の組み込みを含み、書き出し 1 回が分単位で試す回数がかさむので、同じ比は当てない。

| 段階 | 中身 | 時間 | 終わりの目印 |
|---|---|---|---|
| W1-0 | hd2d-starter でも `shotsInto` と同じ道で 3D の場面を組めるか（`TestShaderVariants` の形）を確かめる。L5 の後の main で 2.2 の呼ぶ所・4.3・2.2 の「`ShaderAst` を実行時に使う所」を `refactor usages` で引き直す。プレースホルダーのスパイク（`materialFragmentTemplate` を仮に書き、TestShaderDump の 2 材質 × 96 形 × 代表の変種で「置き換え = 直の print」）。`School.materialsOf` などから retro3d の論理の鍵を数えて表の大きさを見積もり直す。`--without` を測り直す。別案 E を 30 分 | 1.5 時間 | スパイクが全組で一致・数字を 13 節へ |
| W1-1 | render_gl: `ShaderSourceKey`・`ShaderSourceProvider`・`makeRuntimeProvider`・`materialFragmentTemplate`・`withMaterialPart`（atom でなければ `bug!`）・`ShaderAst` が engine の `ShaderText.isAtomText` を使う形へ・`featureOfFlag`・`collectionKeysOf`・`Uniforms` の分け。2.2 の 15 か所を provider へ・表に無い時に飛ばす 10 か所と、GL の 3 つの関数を `Option` にして呼び手まで直す分。PC の材質の frag も template の道へ | 6.5〜7.5 時間 | `make test-render_gl` 緑・`make shader-dump` の前後が `diff -r` で空・`TestRender3dGlslPinned` そのまま |
| W1-2 | 記録: `kindOf` と変種を決める所の後の記録・`loadCollection`・`saveCollection`・`requiredKeysOf`・`fge run`・`fge debug` の旗（`web/WebMain.flix` がある時だけ） | 2 時間 | 往復のテスト・広げ方のテスト（coverage の両方を含む）・go のテスト |
| W1-3 | `tools/shader-bake` と jar を作る make の配線（`sync-engine-full-web` の中）・リリースの束への追加・`fge.web.ShaderLibraryData`・`Embed` の ②'''・go の書き出しの段階・engine_web の `WebShaderLibrary` と WebLayer の配線 | 3.5〜4.5 時間 | retro3d が書き出せて、wasm-size の 4 つが 0 本 |
| W1-4 | 門と文書: web-load-check の 0 本の検査・3D のテンプレート（retro3d-horror-starter・hd2d-starter など `web/WebMain.flix` を持つ物）に記録の漏れのテスト `TestShaderVariants` と `web/shader-variants.json`・ShaderGen の「cutoutAlpha は atom」のテスト・`gates.json` の about・`make web-size-update`・`docs/web-export.md` と `docs/scene3d.md`・migrations・forbid.json の 1 行・早見表とお題（9 節） | 2〜2.5 時間 | `make web-load-check` 緑・`web-load-check-2d` 緑・`make test-retro3d-horror-starter`・`test-hd2d-starter` 緑 |
| W1-5 | 確かめ: `make webgpu-v1-check-web`・WebGL2 の頁・記録から 1 行わざと消して `console.error` と描かない物を見る・書き出しの時間・wasm の大きさ | 1 時間 | 絵の差 0・測りを 13 節へ |
| 計 | | **16.5〜19.5 時間**（丸めて 16〜20） | |

## 6. 触るファイル・新しい pub・migrations

### 6.1 触るファイル

- render_gl: `Render3dShaders.flix`（template と `makeRuntimeProvider`・`featureOfFlag`。1,200 行に近づくなら `Render3dShaders/Sources.flix` へ出す）・`Render3d/ProgramKey.flix`（`FlagRow` の `feature` を外す）・`Render3d/Uniforms.flix`（表を分ける）・`ShaderAst.flix`（`isAtomText` を engine の `ShaderText` へ出す）・新しい `Render3d/ShaderSourceKey.flix`・`Render3d/ShaderLibrary.flix`・呼ぶ所（`Render3d.flix`（`buildPrograms`・`buildSkinnedPrograms`・`skyProgramOf`）・`Render3d/VariantPrograms.flix`・`Material.flix`・`ScenePlan.flix`（記録）・`WebGpuRenderer.flix`・`WebGpuMaterials.flix`・`WebGpuMipmaps.flix`・`WebGpuBillboards.flix`・`WebGpuSky.flix`）・描き手を作る所（`LwjglLayer`・`Scene3dRenderer`・`GlOffscreen`・`GpuOffscreen` は PC の既定の版のまま）
- render_gl のテスト: `TestShaderDump.flix`（template の道で書き出す行を足す）・新しい `TestShaderLibrary.flix`・`TestUniformLayout.flix` などの `UniformRow` を使うテスト
- engine_web: `WebLayer`・`WebLayer.Internal.WebGpuLayer`（provider を渡す）・新しい `WebLayer/Internal/WebShaderLibrary.flix`・`java/fge/web/ShaderLibraryData.java`・`teavm/java/fge/teavmfix/Embed.java`
- 新しい `tools/shader-bake/`（flix.toml・`src/ShaderBake.flix`）
- go: `go/exportweb_build.go`（①' と ②'''）・`go/exportweb_paths.go`（jar の在りか）・`fge run`・`fge debug` を起こす所（旗）・テスト
- Makefile（`sync-engine-full-web` に jar・`web-load-check` に 0 本の検査）・`gates.json`（`web-load-check` と 3D のテンプレートの test の about）・リリースの手順（`release-guard` の配る物）
- 3D のテンプレート（retro3d-horror-starter・hd2d-starter など `web/WebMain.flix` を持つ物）: `web/shader-variants.json`・`test/TestShaderVariants.flix`・`src/render/SceneRender.flix`（今は非 pub の `sceneOf`・`loadRes` をテストから呼べるよう pub にする。テンプレートの中だけの変更）
- engine: 新しい `engine/src/shader/ShaderText.flix`（`isAtomText`）・ShaderGen のテスト「cutoutAlpha は atom」（`engine/test/` の ShaderGen のテストの隣）
- docs: `docs/web-export.md`（書き出しの段階・記録のファイル・表に無い時）・`docs/scene3d.md`（新しい pass は `ShaderSourceKey` に case を足す）・`docs/migrations/<版>.md`・`agents-pack/AGENTS.core.md`
- `bin/lint-rules/forbid.json`: render_gl の src で `Render3dGlsl.` / `Render3dWgsl.` の字の関数を `makeRuntimeProvider` の外から呼ばない（型で止められない分。順は型 → lint → docs）

### 6.2 新しい pub（人に相談する物・10 個）

| 置き場 | pub | 根拠 | 代わりの案 |
|---|---|---|---|
| render_gl | `Render3d.ShaderSourceKey`（enum）・`toKeyString` | 字の種類を enum で持てば、L5〜L7 で pass を足した時に PC の実体と作る道具の match が網羅の検査で止まる | 鍵を String で持つ: 書き間違いが実行時まで見えない |
| render_gl | `Render3d.ShaderSourceProvider`（record）・`Render3dShaders.makeRuntimeProvider` | 実装が 2 つ（PC とブラウザ）ある境目 | effect にする: 描き手の 30 か所以上の型に効果が増える |
| render_gl | `Render3dShaders.materialFragmentTemplate`・`Render3d.ShaderLibrary.withMaterialPart` | 材質の部品を実行時に作りつつ、それ以外を前もって作るため | 材質ごとに全部作る: Doc を Studio で触ると表が古くなる・材質の数だけ太る |
| render_gl | `Render3dShaders.featureOfFlag` | 4.3 の 2 | `FlagRow` に残す: 木が wasm に残る |
| render_gl | `Render3d.ShaderLibrary.requiredKeysOf`・`collectionKeysOf`・`loadCollection`・`saveCollection` | 記録の形と作る分の広げ方を 1 か所に | go で広げる: 変種の表（`flagRows`）を go へ写すことになる |

形の変わる pub: `Render3d.Uniforms.UniformRow`（欄 `ty`・`wgsl` を木の側の型へ移す。ゲームからは使われていない・W1-0 で確かめる）・描き手を作る関数（provider を受け取る版を足す）。engine に足す pub は `ShaderText.isAtomText` の 1 つ（engine のテストと render_gl の両方が読むため。engine の拡張なので相談の対象）。内側だけの物（`WebShaderLibrary`）は pub の数に入れない。
ゲームから見える pub は 0。ゲームが持つ物は git に入れる `web/shader-variants.json`（作るのは PC の描き手）だけ。

### 6.3 make のターゲット・道具

- ゲーム向けの新しい make のターゲットは作らない（記録は `fge run`・`fge debug` が旗を立てる）。
- engine だけ: `sync-engine-full-web` が jar も作る（推測: +20〜40 秒。13 節で測る）。
- 記録が無い 3D のゲーム（`web/WebMain.flix` があり、`web/shader-variants.json` が無い）の書き出しは、`--draft` の無い時は赤で止め、次の手（「`fge run` で 3D の場面を一度通す」）を出す。`--draft` の時は「いつも」の一式だけで書き出し、`DraftReasons` に「シェーダーの記録が無い」を足す（今の `--draft` の「門が赤でも書き出して draft のマーカーを付ける」の意味のまま、理由を 1 つ増やすだけ）。`web-load-check` は `--draft` で書き出す（Makefile:487）ので、記録の無いゲームを `WEB_LOAD_GAMES` に入れると、既定の変種の外の場面が `console.error` で赤になる。テンプレートは記録を git に入れてあるので当たらない。

### 6.4 migrations

`docs/migrations/<版>.md` に: ブラウザ版を出す 3D のゲームは engine-upgrade の後 `fge run`（`make run`）で 3D の場面を一度通して `web/shader-variants.json` を作り git へ入れる・表に無い鍵が出た時の `console.error` の字と直し方。2D だけのゲームと Web に出さないゲームは何もしない。

## 7. 門と退行の止め方（絵は変えない）

| 何を止めるか | 門 | 在りか |
|---|---|---|
| template の置き換えが直の print とバイトまで同じ | 材質（絵を読む・読まない・ShaderGen の本物の Spec 数種）× 96 形 × 16 変種のうち代表（`TestShaderDump.representativeKinds` と同じ数え方）× 2 言語で `withMaterialPart(template, 部品) == 直の print`。atom でない cutout の α を渡すと `bug!` で止まること（`Assert` で例外を見る）も 1 本 | `TestShaderLibrary` |
| 書き出しの表の往復で字が変わらない | JSON の書き → 読みで全部の字が同じ | `TestShaderLibrary` |
| 記録のファイルの読み書き | 版・知らない欄・無い欄・知らないフラグの字の読み方 | `TestShaderLibrary` |
| 1 本化の後の字が W1 の前後で同じ | `make shader-dump OUT=before`（W1 の前）と `OUT=after` を `diff -r` で空。dump に template の道の行を足し、そちらも空 | `make shader-dump`（W1-1 の終わりに手で） |
| 既定の字の SHA | `TestRender3dGlslPinned` はそのまま緑 | 既存 |
| 広げ方が描き手の求める字を覆う | PC の描き手（Dawn と GL）でテストの場面を描いた時に provider が求めた鍵 ⊆ `requiredKeysOf(collectionKeysOf(場面))`。場面には色の場面のほかに、奥行きの場面・MultiMesh・静的な組・影を落とす灯り・psx の変種を入れる（3.1 の (a)〜(e) を全部通す） | `TestShaderLibrary`（Dawn の版は `TestWebGpuScene3dDawn` の隣） |
| ShaderGen の cutout の α は atom | `ShaderGen.compile3d`・`Wgsl.compile3d` の `cutoutAlpha` が、ShaderDoc の Out の全部の形と代表の Spec で engine の `ShaderText.isAtomText` を満たす | engine の ShaderGen のテスト（`make test-engine`。`ShaderText` は engine にあるので engine のテストから読める） |
| **テンプレートの記録の漏れ** | 3D のテンプレートの `TestShaderVariants`: gallery を描く `SceneRender.shotsInto` と同じ道で場面を組む（`loadRes` → `Shots.names` → `Shots.worldOf` → `sceneOf` → `Render.softSceneOf(...)#scenes` と `passes` の中の scenes）。retro3d は階ごとの World を作って全部の階を通す。各場面の `collectionKeysOf` の鍵が `web/shader-variants.json` に全部あるか。描き手も画面も使わない純粋なテスト（1 本の時間は W1-4 で測る・推測 2〜4 秒で `test-retro3d-horror-starter` の 16 秒に足される） | `make test-retro3d-horror-starter`・`test-hd2d-starter`（gates.json の packages の `test` で選ばれる。新しい門の行は足さない） |
| ブラウザに木が残っていない | web-load-check で 4 つの module の関数が 0 本 | `make web-load-check`（release の門） |
| 最初の場面の表に無い鍵 | console の誤り 0 件（既存の web-load-check。最初の場面の 10 コマだけを見るので、2 部屋目からの漏れは上の `TestShaderVariants` で止める） | 同上 |
| ブラウザの絵 | `make webgpu-v1-check-web`・`make gl-capture-check`（pre-release） | 既存 |
| wasm の大きさ | `testdata/web-size.tsv` を W1 の後に `make web-size-update` で下げる（+3% の門が下がった所から始まる） | 既存 |

字がバイトまで同じなら、同じ GPU の上の絵も同じ。絵に触る担当には「画素の差が出たら入れる前に止めて報告」を依頼文に書く。

## 8. 重さと wasm の見込み

- wasm: `--without` A の −101.9 KB（code 区画・`Render3dGlsl*`・`Render3dWgsl*` の数の関数も入れた上限）から、足す物を引く。
  - 表（retro3d・2 言語）: 推測 12〜25 KB。小さなゲームの xz 12.1 KB（2.4）に、cutout の形を coverage の真偽で 2 倍・材質の template 1 本 13〜25 KB を足した幅。W1-0 で retro3d の論理の鍵を数えて詰める。
  - 境目・表を引くコード・表に無い時の道: 推測 3〜5 KB。
  - 残る数の関数: 推測 1〜2 KB。
  - GC の型の区画は AST の record の型が減る分さらに軽くなる（`--without` は code 区画だけを見るので数えていない）。
  - 計 **推測 −80〜−90 KB → classes.wasm.br 約 1,425〜1,435 KB（−5.3〜−6%）**。W1-5 で測る。
- 起動: 字を作る時間（ブラウザで 1 本数 ms の推測）が表を引くだけになる。3D の描き手を作る所と、初めての変種の場面に入るコマが少し軽くなる（推測。測るのは W1-5 の `fgeStats` の 1 コマの CPU の最大）。
- 書き出しの時間: ①' の JVM（起動 0.5〜1 秒 + Flix の初期化 + 数十本 × 1.3 ms）と ②''' で **推測 +2〜4 秒**。fatjar と TeaVM は分単位なので小さい。
- 遊べるまでの予算（16 秒・`go/exportweb_gate.go`）は束の大きさから出す見積もりなので、wasm が減る分だけ下がる（予算の件を直している別の担当の邪魔はしない）。
- PC: 今のまま実行時に作る。材質の frag だけ「template を作る → 置き換える」の 1 手が増える（template は控えるので、同じ形の 2 本目からは置き換えだけ）。記録は新しい鍵の時だけファイルへ書く。

## 9. 新しい仕組みとしての届け

- `agents-pack/AGENTS.core.md` の早見表に 1 行（「3D のゲームのブラウザ版で『web/shader-variants.json に無い』が出たら、`make run` でその場面を通して書き出し直す」）と、`agents-pack/agent-eval/engine.json` にお題を 1 本（記録のファイルが何か・誤りの直し方）。ゲームの足元で `make agent-eval ONLY=<お題>` が当たるのを確かめる。
- engine のリポだけの新しいコマンドは無い（`sync-engine-full-web` の中身と web-load-check の検査が増えるだけ）。

## 10. L5〜L7 とのぶつかり

- L5 は render_gl で動いている（別の担当）。W1 が触る所（`ProgramKey.FlagRow`・`Render3dShaders`・`Render3dWgsl` の binding・`Uniforms`・WebGpu の各モジュールの作る所）は L5 の L5-0b（`FlagRow` の Bool の列を binding の一覧へ）・AO の pass と重なる。**W1 は L5 を main に取り込んだ直後に始める**。L5-0b が `FlagRow` を作り替えるので、`feature` の欄を外すのはその後の形に合わせる。
- L5 の AO の pass・L6 の cluster・L7 の霧のシェーダーは、W1 の後は `ShaderSourceKey` に case を足す形で入る。足し忘れは (1) PC の実体と作る道具の match の網羅で、(2) 直に呼べば forbid.json で、(3) それでも漏れれば web-load-check の 0 本で止まる。
- 新しいフラグ（`+ao`・`+vf`・`+cl`）は記録の変種の字（`variantKeyOf`）にそのまま入る。古い記録の行は読めるまま（無いフラグは偽）。
- L6・L7 が木を大きくしても、ブラウザの wasm には字（表）しか増えない。W2 の +3% の門は、W1 の後の記録の値から始まる。
- 順の案: L5 → **W1** → L5 の後のリリース → L6 → L7。

## 11. 危ない所

| 危ない所 | 手当て |
|---|---|
| ShaderAst がプレースホルダーを触る（括弧で包む・並べ替える・検査で止める） | cutout の α は atom だけを受け（atom でなければ `bug!`）、ShaderGen の側のテストで約束を止める。並べ替えと検査は W1-0 のスパイクで全組を照らす。プレースホルダーは正しい識別子とコメントにして検査を通す |
| PC とブラウザで材質の形が違う（`coverage` は MSAA で変わる） | 広げ方で cutout の形は coverage の真偽の両方を作る。ほかの欄はデータだけで決まる（レビューで照らした） |
| 記録の漏れ（PC で通していない場面・Doc で psx を切り替えた） | 鍵ごとに 1 回の `Log.fellBack` と `console.error`・テンプレートは `TestShaderVariants` で止まる（gallery と全部の階。遊んで初めて出る場面は止まらない） |
| 配った engine に shader-bake.jar が無い | リリースの束に入れる（4.1）・`release-guard` が配る物の一覧で見る |
| `Uniforms` を分けると WebGL2 の location の引き方が変わる | 表の中身は変えず型だけ分ける。`TestShaderDump.testEveryGlslUniformIsInTheHandleTable` などの今のテストがそのまま緑 |
| `Render3dShaders` が 1,200 行に近づく | template と `makeRuntimeProvider` は子のモジュールへ |

## 12. 人に決めてほしい事（推す答えつき）

1. **W1 を L5 の直後・L5 の後のリリースの前に入れるか** → 入れる。L5 で wasm がさらに増えると +6% を超えうるので、リリースの前に戻しておく。
2. **使う分を PC で遊んだ記録（`web/shader-variants.json`・git に入れる）で決め、無ければ書き出しを赤にするか** → そうする。`--draft` だけ「いつも」の一式で通し、`DraftReasons` に理由を足す。代わりの「16 変種の固定のプログラムを全部作る」は表が 1 言語 推測 +20〜25 KB で減りの 4 分の 1 を使い、材質の形は結局記録が要るので推さない。
3. **記録の旗を `fge run`・`fge debug` の側で、`web/WebMain.flix` があるゲームにだけ自動で立てるか** → そうする。外のゲームと Studio から走らせた時にも届く。手で打つコマンドにすると忘れる。git の差が出るのは新しい形を使った時だけ。
4. **表に無い鍵の時、その描き物を描かずに鍵ごとに 1 回知らせるか**（「いつも」の鍵が無いのは `bug!`） → そうする。近い形で代わりに描くと、絵が何も知らせずに変わる。
5. **テンプレートの記録の漏れを、3D のテンプレートの flix test（`TestShaderVariants`・純粋・画面なし）で止めるか** → 止める。web-load-check は最初の場面しか見ず、gl-capture-check は retro3d の場面を撮らない（gates.json の retro3d の門にも入っていない）。代わりに retro3d の場面を gl-capture-check に足す案は、画面を開く 12 分の門の中なので作業中に回らない。
6. **`Render3d.Uniforms.UniformRow` を「実行時の表」と「木の側の欄」に分けるか**（門を「`ShaderAst.Ty` を除く」に緩める代わり） → 分ける。門を緩めると、残してよい物と残ってはいけない物の線が字の約束になる。
7. **PC の材質の frag も template の道にそろえるか** → そろえる。置き換えの誤りが PC の絵とテストで見え、ブラウザだけの道が無くなる。
8. **表を wasm の中（Java の定数）に入れるか、束の別ファイルにするか** → wasm の中（4.2）。
9. **`tools/shader-bake` を engine の中に新しいパッケージとして置き、`sync-engine-full-web` で jar を作り、リリースの束に入れるか** → そうする（3.2 の F は書き出しが分単位で延びる）。
10. **render_gl の新しい pub 10 個・engine の新しい pub 1 つ（`ShaderText.isAtomText`）と形の変わる pub 2 つ（6.2）** → 了承を。ゲームから見える pub は 0。

## 13. 測った値（各段階の後にここへ足す）

| いつ | 何 | 値 |
|---|---|---|
| 計画（6f549c941） | retro3d classes.wasm.br | 1,515.3 KB（1,551,695 バイト） |
| 計画 | `--without` A / B / C | −101.9 / −58.3 / −38.9 KB（code 区画） |
| 計画 | `make shader-dump` | 1,507 本・組んだ時間 1,911 ms・全体 31.5 秒 |
| 計画 | 小さな 3D のゲーム 1 本ぶんの字 | WGSL 69.9 KB → xz 6.5 KB・GLSL 55.6 KB → xz 5.6 KB |

## レビューへの答え（1 回目 74 点）

- 必須 1（呼ぶ所の漏れ 4 つ）: 2.2・4.3・6.1・表に無い時の表に `buildSkinnedPrograms`・`WebGpuMipmaps.create`・`psxVertexModuleOf`・`rowRightVertexModuleOf` を足した。
- 必須 2（`Uniforms` が `ShaderAst.Ty` を実行時に持つ）: 2.2 の事実・4.3 の 3・12 の 6 に。推す答えは表を分ける。
- 必須 3（`rawExprIn` の字を見る）: 前提の文を直し、`isAtomText` を共有して同じ規則で包む形を 3.1 に。テストに atom でない cutout の α を足した。
- 必須 4（漏れの門）: 案 G の比べを直した（門の形は 2 回目の必須 B で差し替えた）。
- 必須 5（外のゲームと Studio）: 旗を `fge run`・`fge debug` へ・リリースの束に jar を入れる手順を 4.1 と 6.1 に。
- 必須 6（表に無い時の作り）: 「いつも」は `bug!`・記録に依る物は 8 か所で飛ばす表と、鍵ごとに 1 回の知らせを 3.1 に。見積もりに入れた。
- 望ましい 1〜12: 4.3-4 を消した・記録する所を `kindOf` の後へ・表の大きさを幅で書き W1-0 で数える・案 H と I を足した・記録のファイルの形と版・`--draft` の理由・A の上限の注記・見積もりを 14〜18 時間に（一本化の比は当てない）・置き換えの順と文字のまま・プレースホルダーの語と jargon の warn の語・名前（`ShaderSourceKey`・`ShaderSourceProvider`・`makeRuntimeProvider`・`withMaterialPart`・`requiredKeysOf`・`loadCollection`・`saveCollection`）・pub の数と問いの追加。

## レビューへの答え（2 回目 85 点）

- 必須 A（atom でない cutout の α を括弧で包むとバイトが合わない・`ShaderAst.Glsl.exprAt` は `precOfNode < ctx` の時だけ括弧を付ける）: 包むのをやめ、`withMaterialPart` は atom でなければ `bug!`・ShaderGen の側に「cutoutAlpha は atom」のテストを置く形に（3.1・7・11）。`isAtomText` は `ShaderText` へ出して ShaderAst・`withMaterialPart`・ShaderGen のテストが同じ 1 本を使う。
- 必須 B（gl-capture-check は retro3d を撮らない）: 鍵を場面からの純粋な関数 `collectionKeysOf` で求める形にし、3D のテンプレートの flix test `TestShaderVariants` で gallery と全部の階を照らす（7・W1-4・12 の 5）。新しい門の行は足さず、gates.json の test の about に書く。
- 望ましい 1: 既定の一式を列で書き、飛ばす 10 か所を「既定でない変種」と材質の形に限って `bug!` の側と分けた。
- 望ましい 2: GL の 3 つの関数を `Option` にして呼び手まで直す分を W1-1 に +1.5 時間。jargon の warn の語を言い換えた。
- 望ましい 3: 実行時の表を `name`・`glsl`・`length` の 3 つに。

## レビューへの答え（3 回目 90 点）

- 必須（engine の ShaderGen のテストは render_gl の `ShaderText` を読めない）: `isAtomText` を engine の `engine/src/shader/ShaderText.flix` に置き、ShaderAst・`withMaterialPart`・ShaderGen のテストが使う形に（3.1・6.1・6.2・7・12 の 10）。
- 望ましい 1: `collectionKeysOf` が写す決め方 (a)〜(e) を 3.1 に列で書き、7 節の ⊆ のテストの入力に奥行きの場面・MultiMesh・静的な組を入れた。
- 望ましい 2: `TestShaderVariants` を `shotsInto` と同じ道で組む形に・`sceneOf`・`loadRes` を触るファイルに・階ごとの World・時間は W1-4 で測る。
- 望ましい 3: `psxVertexModuleOf` を記録に依る側へ・hd2d-starter で組めるかを W1-0 で確かめる。

## 出典にした engine の場所

- `render_gl/src/Render3d/ProgramKey.flix`（`ShaderVariant`・`VariantFlag`・`FlagRow`・`flagRows`・`rowsOf`・`variantKeyOf`・`ProgramKind`・`materialKey`）・`Render3d/VariantPrograms.flix`・`Render3d/ScenePlan.flix`（`isCoverageCutout`・`kindOf`）・`Render3d/Uniforms.flix`（`UniformRow`・`rowOf`・`locationsOf`）・`Render3d.flix`（`buildPrograms`・`buildSkinnedPrograms`・`skyProgramOf`・`programUniformsOf`）・`Render3d/WebGpuMipmaps.flix`・`WebGpuRenderer.flix`・`WebGpuBillboards.flix`
- `render_gl/src/Render3dGlsl.flix`・`Render3dWgsl.flix`・`Render3dShaders.flix`（`treeFunction`・`generatedBody`・`partIn`・`materialPartOf`・`glslMaterialPart`・`wgslMaterialPart`・`texMip`・`materialFragmentBody`・`featureOf`・`pointShadowsFeature`・`psxFeature`）・`ShaderAst.flix`（`rawExprIn`・`generatedText`・`precOfNode`・`isAtomText`）
- `render_gl/test/TestShaderDump.flix`（`surfaceKinds`・`representativeKinds`・`allSources`）・`render_gl/test/TestRender3dGlslPinned.flix`
- `engine/src/scene3d/Scene3d.flix`（`PreloadCmd` 1011 行・`PreloadVariant` 1031 行・`preloadVariantKey` 1039 行）
- `templates/retro3d-horror-starter/src/School.flix`（`materialsOf`）・`src/View.flix`（`preloadScenes`）
- `go/exportweb_build.go`（`buildWasm`）・`go/exportweb_fullweb.go`（`ensureFullWebFresh`）・`go/cmd_wasmsize.go`（`writeWasmWithout`）・`go/exportweb_gate.go`（16 秒の予算）・`go/cmd_exportweb.go`（`--draft`）・`mk/game.mk`（`run`）・`engine_web/java/fge/web/EmbeddedData.java`・`engine_web/teavm/java/fge/teavmfix/Embed.java`
- `Makefile`（`shader-dump`・`web-load-check`）・`gates.json`（`web-load-check`・`web-load-check-2d`・`gl-capture-check`）・`testdata/web-size.tsv`
- 計画: `plans/engine-render-look-l5-l7.md`（11〜13 節）・`plans/web-loading-p4.md`（wasm-split の測り）

## 人の決め（2026-11-27）

「よいよ」。12 節の 1〜10 は推す答えのとおり了承。engine の pub 1 つ（`ShaderText.isAtomText`）と render_gl の新しい pub 10 個・形の変わる pub 2 つ、記録が無ければブラウザ版の書き出しを赤にする（`--draft` は既定の一式で通す）ことを含む。始めるのは L5 を main に取り込んだ直後。

## 実装後の決め（2026-11-27）

- A: 表に無い材質の形は頂点の色で描く（console.error と門の赤で気づく）。人が推しで了承。
- B: engine_full の `ShaderVariants.missingFrom` / `recordFromEnv` を残す。人が推しで了承。
- 結果: retro3d の classes.wasm.br 1,584,184 → 1,453,087 B（−8.3%）・遊べるまで 15.0 → 14.5 秒。main に da66aea74 で取り込み。
