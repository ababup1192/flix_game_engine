# 段 G（3D 拡張 段 5）: 3D の色を線形で計算する（rev11）

前提: C2 の後の形（光の式は `LightModel3d` の木に 1 回だけ・CPU は `make gen-light3d` の生成物 `SoftRaster3dLight`・GL は
`LightModel3d.Codegen.toGlsl` の字・gl-parity に式の行 E）。round10 §3.6 で足した範囲（emissive の強さ・段 4 の半透明・空）と
Q3 の決定（3D の絵を一斉に線形へ・1 版だけ project.json `scene3dLinearColor: false` で戻せる・0.80.0 で消す）を入れる。
版は 0.79.0 の予定（この段では番号を上げない）。**§12 の H1〜H7 と §13 の pub の口の一覧は人に決めてもらってから実装に入る。**

## 0. ねらいと結論

今は画像の画素の値（sRGB の値）のまま光を足し掛けしている。0.5 と書いた画素の光の量は約 0.21 で、光の落ち方・重なり・
影の境が硬く、重なった所が急に白くなる。3D の描き物の中だけ、色を**線形の量に戻してから**光を足し掛けし、
**3D の色を作った直後に 1 回だけ sRGB の値へ戻す**。光の式（木）は変えない。

決めたこと（理由は各節）:
1. **戻す所は 3D の色を作った直後**（GL は 4 つの frag の最後・CPU は同じ 4 か所の色の枝。半透明を混ぜる前・Depth と background は通さない）。
   描き先の形式（Rgba8Unorm / Rgba16Float）・2D・後処理・トーンマップは触らない（§3。Godot 4 の Compatibility の描き手と同じ形）。**H1 の推し**。
2. **材質の Spec は 2D と同じ sRGB の値で書く決まり**。描き手は Spec の出口（albedo.rgb と emission）を線形へ戻す（§2）。
   1 を超える emission の強さ（glTF の strength 40 など）は Spec に入れず、新しい欄 `emissionIntensity`（線形の倍率）で持つ（Godot の
   `emission_energy_multiplier`・Unity の Emission Intensity と同じ分け方）。
3. **切り替えはプロセスで 1 つの値**（作業場の project.json の `scene3dLinearColor` を JVM の中で 1 回だけ読んで控える。H3 の推し）。GL と CPU の描き手の入口がそれを読み、
   中の関数には引数で渡す（テストは引数で真偽を決める）。場面（`Scene3dCmd`）・`RasterReq`・`EngineConfig` の型には欄を足さない（0.80.0 で消す時に型が変わらず、
   字で組む所を 2 回壊さない。場面ごとに古い色へ戻せる口を、人の決めた「1 版だけ・project.json で」より広げない）。偽なら 0.78 と同じ式。
4. **mip の平均は色の絵だけ線形で**（`Mip.build` に平均の仕方。法線マップは今のまま・lightmap は `colorSpace` のとおり）（§4）。
5. glTF の factor・OBJ の Kd は今のまま sRGB の値として読む（§2。旗を偽にすれば 0.78 に戻る、を崩さない）。
6. 2D の絵は 1 画素も変えない。3D の絵は全部変わるので、新しい基準 `bench/baseline/0.79.0/` を撮る（古い基準は残す）。

## 1. 線形で扱う物・扱わない物（GL と CPU で同じ表）

| 値 | 線形の時 | 偽（0.78 の式）の時 |
|---|---|---|
| `Environment3d.ambient`・`PointLight` / `SpotLight` の color | sRGB → 線形にしてから intensity を掛ける（場面ごとに 1 回） | そのまま |
| `hemisphere`・光の intensity・range | 線形の量としてそのまま（H4: 今まで同じ明るさだった ambient 0.5 と hemisphere 0.5 が、線形では hemisphere の方が明るくなる） | そのまま |
| `withTint` の tint・ビルボードの tint | sRGB → 線形（物ごとに 1 回。CPU は `matOf`・`instanceTris`・`inkOf`） | そのまま |
| 頂点の色（材質の無い物） | 頂点ごとに sRGB → 線形にしてから三角形の中でつなぐ（GL は lit のプログラムだけの頂点シェーダーで・CPU は `instanceTris` で「戻した頂点の色 × 戻した tint」を頂点の欄へ。tint は三角形の中で一定なので GL の `vColor × uTint` と同じ値。Godot 4 で `vertex_color_is_srgb` を真にした時と同じ）。材質の Spec が読む `VertexColor` は戻さない（出口で戻す） | 今のまま（CPU は頂点の色 × tint を頂点に書く） |
| 材質の Spec の出口の albedo.rgb・emission | 画素ごとに sRGB → 線形（α は触らない） | そのまま |
| `emissionIntensity`（新） | 線形にした emission に掛ける | emission に掛ける（既定 1 なら今と同じ値） |
| ビルボードの絵の rgb | 画素ごとに sRGB → 線形 | そのまま |
| かすみの色・空の 3 色 | sRGB → 線形（場面ごとに 1 回）。空は線形の中で混ぜる | そのまま |
| lightmap | `colorSpace` で読み、intensity を掛けた**線形のまま**動く光と足す | 今のまま（画面の値へ戻して足す） |
| 法線マップ・影の地図・Output.Depth の灰色 | 数として読む（変換しない） | 同じ |
| `background`（何も描かれない画素の色） | 変換しない（計算しない色。戻して戻すと 8bit で 1 ずれうる） | 同じ |
| 出口 | 色を作った直後に線形 → sRGB（1 を超える値は同じ式で伸ばし、切らない。HDR の Pass に 1 超えが残る） | そのまま |

- 変換の式は今の `Texture3d.srgbToLinear` / `linearToSrgb`（区分の式）と同じ式の GLSL だけ。場面ごとの値の変換は engine の 1 か所
  （`Texture3d.srgbToLinearColor(c: Color): Color`（srgbToLinear の隣）。旗を引数に取らない — 0.80.0 で旗を消しても形が変わらない。呼ぶ側が `if (linear) srgbToLinearColor(c) else c` で選ぶ）に置き、
  GL の uniform を詰める所（`Render3d.lightDataOf(scene, linear)` — 旗の引数を足す — の頭で `picked` の点光源とスポットの color と ambient・fog をまとめて 1 回変換する。tint と空は `lightDataOf` の外なので、`State` の旗で変換する `Render3d.putSceneColor(state, loc, c)` を 1 つ作って通す — 6 か所: 材質の tint〔`Render3d/Material.flix:105`〕・lit の tint〔`Render3d.flix:618`〕・ビルボードの tint〔`Render3d.flix:953`、今は `glUniform3f` を直に呼ぶ〕・空の 3 色〔`Render3d.flix:567-569`〕）と CPU の `packPointLights` / `compileLights` / `compileFog` /
  `skyColorsOf` / `matOf` / `instanceTris`（材質の無い物は `mat < 0` で見分ける）/ `inkOf` の両方がそれを呼ぶ。光の color は戻してから `packPointLights` / `packSpotLights` に渡す
  （pack の形は今のまま — 中で color × intensity を掛けるので、color を先に戻せば足りる）。
- スポットの縁の smoothstep・toon の段は式のまま（toon の段は線形の光で切るので段の明るさの並びが変わる — 移行メモ）。
- 半透明の混ぜと MSAA の平均は、戻した後の sRGB の値どうし（§3・H1）。CPU も `blendRow` に入る前の材質の色を戻す（GL のハードウェアの混ぜと同じ値どうし）。

## 2. 材質の決まり（Spec は sRGB の値）

- 3D の材質の Spec は 2D の ShaderDoc と同じ「画面の値」で書く。描き手は出口の albedo.rgb と emission を線形へ戻す。
  `Scene3d.texturedMaterial`（絵 × 頂点の色）・ゲームの手書きの Spec はそのまま正しく見える。掛け算は戻す前でも後でもほぼ同じ（区分の式の差だけ）。
  Mix などの足し算は sRGB の中で混ぜたことになる（材質の中の混ぜは今の見え方のまま）— doc に書く。
- 新しい欄 `MaterialFields.emissionIntensity: Float64`（既定 1）と `Scene3d.withEmissionIntensity(k, m)`。線形の倍率（PointLight の intensity と同じ意味）。
  プログラムの鍵（`shaderHash`）には入れず、tint・lightmap と同じく**描く物ごとの uniform**（同じプログラムを強さの違う材質が共有する。`Material.flix` の
  tint と `bindLightmap` の WhyNot と同じ理由）。CPU の `Mat` にも欄。描き出しの鍵（`DrawHash`）には `≠ 1` の時だけ印のバイトを書く（欄を足す前の鍵の字を保つ流儀）。
- glTF（`Gltf`）の emissive: Spec は今の `絵の rgb × emissiveFactor`（絵が無ければ `Solid(factor)`）から strength を外し、`emissionIntensity = strength`。
  `GltfMaterial.emissive`（factor × strength の公開の値）の意味は変えない。spec の名前の `<emissive>` は factor だけにする（strength は uniform で木の形を変えないので、強さだけ違う材質がプログラムを共有する）。`Scene3d.withoutEmission` は `emissionIntensity` を 1 に戻す。
  偽の場面では `(絵 × factor) × strength` で、今の `絵 × (factor × strength)` と掛ける順だけが違う（8bit で 1 ずれうる。factor が 1 なら同じ値）。
- **glTF の baseColorFactor / emissiveFactor と OBJ の Kd は今のまま sRGB の値として読む**。glTF の決まりでは factor は線形の値だが、
  `Gltf.flix` の WhyNot（「OBJ の Kd も Blender の値をそのまま使う。直すと glTF だけ明るくなる」）のとおり、片方だけ直すと同じ Blender の色が形式で違って見え、
  直すと旗を偽にしても 0.78 に戻らない。glTF の COLOR_0（決まりでは線形）と、頂点の色に焼き込まれる baseColorFactor も同じく sRGB の値として読む
  （材質のある物は出口で・材質の無い物は頂点で戻すが、どちらも同じ値になる）。両方を線形として読む直しは H2 として人に聞き、この段ではやらない（WhyNot に線形化の後の理由を書き足す）。

## 3. 戻す所を 3D の色を作った直後にする理由（H1 の材料）

比べた 3 つの道:
- (A) **frag の最後で戻す**（推し）。3D の描き物の外から見た値の意味（sRGB の値）は今と同じで、描き先の形式・トーンマップ・ピントの Pass・2D の重ね方を全部そのまま使える。
- (B) 3D の場面ごとに別の Rgba16Float の描き先へ線形で描き、2D の描き先へ貼る時に戻す（今の Design の解像度の道 `Render3d.renderDesign` と同じ形）。
  半透明と MSAA は線形で混ぜられるが:
  - background の無い場面の透けた画素（α < 1 の縁・半透明が下の 2D に重なる所）は、貼る時に sRGB の 2D の上へ混ぜるので、線形で混ぜたことにならない（中途半端）。
  - Native の場面ごとに窓と同じ大きさの描き先と貼り直しが増える（1 場面あたり全面の読み書き 1 回）。
  - MSAA は今 2D と同じ Pass の標本（`dest#samples > 1`）を使っているので、別の描き先にも同じ数の標本を持たせる作りが要る。
  - CPU の描き手も層を float で持って貼る形へ組み直す（今の `drawScene` は 8bit の層・`drawSceneHdr` は float の層）。
- (C) 描き先を `GL_SRGB8_ALPHA8` にして 3D を描く間だけ `GL_FRAMEBUFFER_SRGB` を点ける。2D の Pass を読む面が sRGB の絵として線形に戻して読むようになり、2D の絵が変わる（G4 に反する）。

(A) で残る物（WhyNot として Render3d と SoftRaster3d の頭に書く）:
- 半透明の混ぜ（段 4 のガラス）と MSAA の resolve は、戻した後の sRGB の値どうし。round10 §3.6 の「半透明の混ぜは線形の Pass の上」「MSAA の resolve は線形で平均」はやらない。
- `PostProcess.tonemappedWith` の exposureStops は sRGB の値に掛かる（今と同じ）。lightmap の露出は線形の倍率の `intensity` に入れるのが正しくなる
  （`docs/lightmap.md` の「段 G が入ったら exposureStops へ戻す」の予告は「intensity にそのまま入れる（2.0 × 2^0.6 ≒ 3.03）」に直す）。round10 の段 5 のデモの
  「露出を exposureStops 0.6 へ」も同じく直す。
- round10 §3.6 の「`Lightmap.colorSpace` を Texture3d の側へ移す」もやらない: 材質の絵は Spec の出口でまとめて戻すので、絵ごとの色の空間を読むのは
  mip と lightmap だけ。`Lightmap.colorSpace` のままにして、ゲームの値を壊さない。

## 4. mip の平均（G2）

- `Mip.build(average: Mip.Average, tex)`（`Mip` の中の小さな enum `Average { case SrgbCurve, case Raw }`。2D と共通の `Mip` を scene3d の型に依らせない。
  `Texture3d.mipSpaceOf(use)` が `Texture3d.ColorSpace` を返し、`Texture3d.mipAverageOf(space)` が `Mip.Average` へ写す）。SrgbCurve は 2×2 の 4 つを 8bit の表（256 個の srgbToLinear）で
  線形へ戻して平均し、8bit へ戻す（256 個のしきい値を二分探索 — `linearToSrgb` の四捨五入と同じ値。描く糸の中で最初に貼る時に段を作るので、テクセルごとの pow で 2048² の絵が
  つっかえないように）。Raw は今の `(和 + 2) / 4`。α はどちらも今の式。白と黒の市松の 1 段上が 188（線形の 0.5）になる。`Mip.flix` の WhyNot（線形で平均しない）は書き直す。
- どちらで作るかは使い方で決める（GL と CPU で同じ判定を engine に 1 つ: `Texture3d.mipSpaceOf(use)`（旗を取らない。偽の描き手は呼ばずに Linear）・`use: Texture3d.TextureUse`
  = `case MaterialTexture`・`case NormalMap`・`case Lightmap(Texture3d.ColorSpace)`）: 材質の Tex の絵 = Srgb・法線マップ = Linear・lightmap = その `colorSpace`。
  線形でない描き手では全部 Linear（今の段の中身と同じ）。
  - 段の中の補間（bilinear）と段どうしの補間（trilinear）は sRGB の値のまま（GL の sampler と CPU の `sampleMipRgb` が同じ。WhyNot に書く — 補間まで線形にするには絵を
    `GL_SRGB8_ALPHA8` で上げる必要があり、CPU の読みも組み直しになる）。
  - 材質の Tex を一律に Srgb で平均するので、mask・ノイズに使う絵の遠くの段の値も少し変わる（移行メモに 1 行）。
- GL は材質・法線マップ・lightmap が `Render3d.Material.resolveTextureAs`（pub）を共有しているので、`Texture3d.TextureUse` を渡す引数を足し、中で `Texture3d.mipSpaceOf` を呼ぶ
  （線形でない描き手なら Linear）。呼び手は `resolveMaterialTexture`（`bindMaterialTextures` と法線マップの bind が通る包み）・`bindLightmap`・`Render3d.noteCulled` で、包みにも同じ引数を足す。
  `noteCulled` が前もって数える `materialTextureNames` は今 法線マップにも「材質の絵」の呼び名を付けているので、`(呼び名, 名前, TextureUse)` を返す形にし、
  間引いた物の絵も描く時と同じ鍵で数える（違う鍵で数えると `noteCulled` の WhyNot が防いでいる上げ直しが起きる）。同じ絵が 2 つの平均の仕方で GPU に
  2 枚乗り、`sweepTextures3d` の枚数と MB の上限に 2 回数えられる（WhyNot に書く — 色と法線の両方に同じ絵を貼る使い方は今の使い手に無い）。
- 段の置き場の鍵に平均の仕方を足す: GL の `textures3dRef`（contentHash）と `mipCopiesRef`（名前）・CPU の `TextureCache` の `mips`（コマをまたぐ控え。`fileMipKey` と `"tex3d:"+hash`）。
- CPU の絵の Map（`sceneTexturesOf` の `名前 → 段の列`。1 コマの全場面で 1 つ）: 鍵を `(名前, Texture3d.ColorSpace)` にする（同じ名前を Srgb の lightmap と法線マップに使う・
  colorSpace の違う 2 つの lightmap が同じ名前を使う、の取り合いを鍵で分ける）。鍵の空間は engine_tools の 1 つの関数 `SoftRaster.mipKeySpace(linear, use)`
  （`if (linear) Texture3d.mipSpaceOf(use) else Linear`）だけで決め、入れる側（`sceneTexturesOf`）と引く側の全部（Spec に渡す Map の写し・`matOf` の法線マップ・`bakedOf`・
  ビルボード）がこれを通る — 偽の時は全部の鍵が Linear になり、今と同じ段が今と同じ所から引かれる。Spec の読み（`ShaderEval.compileMaterial` が名前で引く）には
  `MaterialTexture` の鍵の段を名前の Map に写して渡し、`ShaderEval` の引き方は変えない。ビルボードは段 0 しか読まないので `MaterialTexture` の鍵で引き、ビルボードだけが使う
  名前もその鍵で入れる（今の材質の項目への相乗り〔`not Set.memberOf(name, materialSet)`〕と同じ形）。
- `Texture3d.limitSize` / `Mip.shrinkTo`（読み込みの時に縮める）は今の式のまま（読み込みは使い方を知らない）。

## 5. 切り替え（Q3 の旗・H3）

- 読む関数と控える関数を分ける:
  - `ProjectLoader.scene3dLinearColorOf(rootDir): Bool \ Fs.FileRead`（`rootDir/project.json` から `scene3dLinearColor` だけを寛く読む。無い・解けない・型違いは真。
    `loadProject` は title などが欠けると Err なので使わない。`ProjectLoader` の今の流儀〔Fs.FileRead だけ〕のまま。テストはこちら）。
  - `GameEngine.loadScene3dLinearColor(rootDir): Bool \ IO`（中で `Fs.FileRead.runWithIO` で包んで上を呼び、System property に控える。鍵は `fge.scene3dLinearColor:<正規化した絶対パス>` — ルートごとに
    JVM で 1 回だけ読む。`RenderCache.engineDigest` の「呼ぶたびに読み直さない」と同じ形で、GL〔文脈を作る時に 1 回〕と CPU〔描くたび〕が同じ JVM の中で食い違わず、
    CPU の絵と描き出しの鍵が別々に読んでも同じ値になる。旗を変えたら起動し直す〔常駐も〕— doc と移行メモに書く）。偽を読んだら鍵ごとに 1 行知らせる。
    doc に「engine の中だけ・0.80.0 で消える」。GL は `config#rootDir`・CPU は cwd を読む — 両方が同じ場所（ゲームのフォルダ）である前提を doc に書く（RenderCache の flix.toml と同じ前提）。
    WhyNot: 柱 3（engine/src から System の直の呼び出しを外す・C5）より前の 0.80.0 で消すので、lint の例外にしない。
- GL: `LwjglLayer.withLwjgl` と `GlOffscreen.prepare`（`RenderPaint.create` を呼ぶ 2 か所）が `GameEngine.loadScene3dLinearColor(config#rootDir)` を呼び、`RenderPaint.create` の cfg の欄 →
  `Render3d.fresh` の引数 → `Render3d.State` の欄。場面を描く所（`drawScene`）が `uLinearColor` と uniform の変換をこの値で決める。
- CPU: `SoftRaster.planDraw`（`drawAllInto` と `drawAllIntoHdr` の両方が通る 1 か所・`sceneTexturesOf` を呼ぶ所）が `GameEngine.loadScene3dLinearColor(".")` を読み、`DrawPlan` の欄に入れて
  `sceneTexturesOf`・`SoftRaster3d.drawScene*` へ渡す。描き出しの鍵は `RenderCache.keyOf` が同じ控えを読み、偽の時だけ `DrawHash.Inputs` の `runtime` の字に印を付け足す
  （`Inputs` の型は変えない。3D の場面の無いコマは旗を読まず、2D だけのコマの鍵は変わらない）。HeadlessRender・VideoOut の字の RasterReq・`SoftRaster.render*` / `renderPass` は全部この 2 つを通る
  （`drawScene*` を呼ぶのは `drawAllInto` / `drawAllIntoHdr` だけ・`DrawHash.computeKeyCached` を呼ぶのは `keyOf` だけ）。
- テスト: `SoftRaster3d.drawScene*` は旗を引数で受けるので両方を試せる。入口（`SoftRaster.render*`）を通すテストは `.layers/<名前>` に project.json が無く真。
- bench: gl_parity と bench/scene3d も同じ入口を通る（§7.2 の偽の確かめは bench の project.json を書き換えて流す）。
- 0.80.0（C4）で消す物は §13 の「0.80.0 で消す」の列。型の欄（`Scene3dCmd`・`RasterReq`・`EngineConfig`・`DrawHash.Inputs`）には足さないので、ゲームの字は壊れない。
  2 回変わるのは engine の中の口（`RenderPaint.create` の cfg・`Render3d.fresh`・`SoftRaster3d.drawScene*`・生成物 `SoftRaster3dLight.lightmapLightAt` の引数）だけで、
  外のゲームが呼んでいないことを実装の最初に usages と check-external で確かめる（H5）。

## 6. GL と CPU の中身

### 6.1 engine（共通）
- `LightModel3d`: `ScalarInput.LinearColor` を足し、`bakedLight` の中を `Select` で分ける（線形なら `LinearToSrgb` を通さない）。木は 1 本のまま
  （GL のプログラムも 1 本のまま）。Codegen の直す所: 口ごとの引数の並び（`Codegen.flix` の CPU の入口の表）に `linearColor` を足す・GLSL の名前の表に
  `LinearColor → float(uLinearColor)` の行・`scalarInputName`・入力ごとの Param の集め方。生成物の `engine_tools/test/gen/SoftRaster3dLightCases.flix` も作り直す。生成される `SoftRaster3dLight.lightmapLightAt` の引数が 1 つ増える（呼び手: `SoftRaster3d.evalLightBaked`・
  bench の `ExprRows.flix` の 1 か所）。`packPointLights` / `packSpotLights` は今の形。
- `Texture3d`: 変換の式は今のまま。
- 出口の組み立て（albedo を線形へ → 光を掛ける → かすみ → emission を足す → sRGB へ）は、今の「色 = albedo × tint × light と emission の足し方は木の外」の形のまま
  GL は `Render3dGlsl` の 1 つの関数 `r3d_surfaceOut(albedoLinear, tint, light, emission, intensity, p, fogOn)`（**線形に戻し済みの albedo を受ける** — 材質は `r3d_srgbToLinear3(albedo.rgb)`・ビルボードは `r3d_srgbToLinear3(texel.rgb)`・lit は頂点で戻した `vColor` をそのまま渡す。中で戻すと lit の頂点の色が 2 回戻る。emission の変換は中に残す〔lit とビルボードは 0〕。unlit のビルボードはかすみを掛けないので fogOn を引数に） に切り出して材質・lit・ビルボードの frag と bench の ExprRows が含め、CPU は
  `SoftRaster3d` の 1 つの関数に置く（WhyNot: 木に入れるとかすみの on/off・ビルボードの lit・Depth の枝まで木の入力にすることになり、この段の範囲を越える。木へ寄せるのは C2 の続きで）。
  代わりに E 段階に `r3d_surfaceOut` と CPU の同じ関数を突き合わせる行を 1 本足す（frag と同じ関数を含めるので、本物の組み立てが崩れれば行も落ちる）。
- `Scene3d`: `emissionIntensity`・`withEmissionIntensity`。`Texture3d`: `srgbToLinearColor`・`TextureUse`・`mipSpaceOf`（3D だけの考えなので 2D と共通の `Mip` に置かない）。`Mip.build` に色の空間。`ProjectLoader.scene3dLinearColorOf`・`GameEngine.loadScene3dLinearColor`。
- `Model3d.GltfMaterial.emissive` の doc（「線形の量」）を H2 に合わせて直す（factor は sRGB の値として読む・strength は線形の倍率）。

### 6.2 GL（render_gl）
- 色の変換の部品を 1 つに: `Render3dGlsl.colorSpaceSource()` = `uniform int uLinearColor;` と `r3d_srgbToLinear` / `r3d_linearToSrgb`（今の Texture3d のスカラーの GLSL）と
  vec3 版（`Texture3d.srgbToLinearGlsl` の WhyNot「vec3 の版にしない」は「光の式の木の中はスカラー・木の外の色の変換は vec3」に書き直す）`r3d_srgbToLinear3` / `r3d_linearToSrgb3`（`uLinearColor == 0` なら c のまま）。lit・材質・ビルボード・空の 4 つの frag が 1 回ずつ含め、
  `lightmapLightSource` からスカラーの定義を外す（2 重定義を作らない。`colorSpaceSource()` は `lightmapLightSource()` より前に置く）。
- 頂点の色の変換は lit のプログラムの頂点シェーダーだけ: `meshVertexSourceOf` に欄 `vertexColorToLinear: Bool` を足し、lit の 2 本（骨なし・骨つき）だけを真で組む。
  今 `materialVertexSource` の uv の無い形と深度のプログラムが `meshVertexSource()` / `skinnedMeshVertexSource()` を共有しているので、共有をやめる
  （共有したまま戻すと、uv の無い材質の Spec の `VertexColor` が線形の値になり、出口でもう一度戻して暗くなる）。lit の頂点シェーダーも `colorSpaceSource()` を含める
  （`meshVertexSourceOf` の declarations に入れる）。`uLinearColor` は場面ごとに光の uniform を入れる所（プログラムごとに通る・glUseProgram の後）で一緒に置く（作った時に 1 回だけにすると、後から作る材質のプログラムで置き忘れて既定の 0 = 偽の式で黙って描く）。場面のプログラムを使う所を `Render3d.useSceneProgram(state, program)`（glUseProgram と `uLinearColor` をまとめて置く）1 つに集め、置き忘れの余地を無くす（render_gl のテストは GL の文脈を作らないので、ここは字のテストにしない）。置き忘れは gl-parity が捕まえる（frag が 0 で描くと面全体の色が変わり、差の数が桁で変わる）。`uLinearColor` の location は各 locs（`MeshLocs`・`MaterialLocs`・ビルボード・空）に持たせ、毎回引かない。影の地図の深度のプログラムは -1 で何もしない（WhyNot）。lit の頂点シェーダーと frag の両方が `uniform int uLinearColor;` を宣言する（GLSL 330 では 1 つの uniform として結ばれる）— プログラムの種類ごとに受け持つ行の表を §7.3 に置く。
  `uEmissionIntensity` の location を `MaterialLocs` に足す。`materialVertexSource` の WhyNot とプログラムの鍵も直す。
  - lit: `vColor`（頂点で線形へ）× `uTint`（線形）× `lightAt` → `r3d_linearToSrgb3(fogged(c))`
  - 材質: `base = r3d_srgbToLinear3(albedo.rgb) * uTint`・`em = r3d_srgbToLinear3(emission) * uEmissionIntensity` → `r3d_linearToSrgb3(fogged(base * light) + em)`。
    lightmap の版は `lightmapLightAt` が `uLinearColor` を `ScalarInput.LinearColor` として読む。
  - ビルボード: `c = r3d_srgbToLinear3(texel.rgb) * uTint`、lit なら光とかすみ → 出口で戻す。unlit も同じ道。
  - 空: uniform の 3 色を線形で渡し、`r3d_linearToSrgb3(skyAt(d))`。Output.Depth の白・cutout・α・depthGray は触らない。
- 偽は uniform で変換を飛ばす（プログラムを分けない — 1 版だけの道でプログラムの数を倍にしない）。
- mip の鍵（§4）。

### 6.3 CPU（engine_tools）
- `SoftRaster3d`: `Lights`・`ShadeEnv`・`Fog`・`SkyColors`・`Mat`・`Ink` に線形かどうかと変換済みの値。出口の変換は色を作った直後の 4 か所だけ:
  `shadePixel` の色の枝（ビルボード・頂点の色・材質。Depth の枝は除く）・`blendRow` の中の `materialPixel` の結果（混ぜる前）・`skyFill` の色の枝。
  `putLayer` と background は何もしない。`materialPixel` の中では戻さず、呼び手 2 か所（`shadePixel` と `blendRow`）で戻す（中で戻すと材質の枝で 2 回かかる）。材質の無い物は線形の時だけ `instanceTris` が「戻した頂点の色 × 戻した tint」を頂点の欄に入れる（形は今のまま・入れる値だけ変える）。
- pub の `SoftRaster3d.lightAt` / `fogAt`（gl-parity の式の行が使う）は今の引数のまま（入力を線形と見なすかを知らない式。変換の行は別に足す）。
- 生成物 `SoftRaster3dLight` は木から作り直す（`make gen-light3d`）。
- `SoftRaster.sceneTexturesOf` / `mipChainOf`（§4）。

## 7. 確かめ方

### 7.1 2D は 1 画素も変えない（門）
- gl-parity の行を 2D と 3D に分ける: gl_parity の Main が、3D の場面を含む行の名前を `[parity3d] <名前>` の行として出す（`Scenes` の場面の描き物に
  `Scene3d.RenderCmd` があるかで決める。afterScene3d・windowPass3d・depthRed・hdrWindowHalf・lightmap など境目の行も、この印で機械的に決まる）。
  `bin/baseline-check.sh` に 2 つの口を足す: `--only-2d`（`[parity3d]` に無い行と、その行の CPU の絵の SHA だけを比べる）・`--gallery-base <フォルダ>`（gallery の基準を別に取る）。
  `--only-2d` は今のログの `[parity3d]` の名前で、控えと今の両方を除く（控えは HEAD で撮るので `[parity3d]` の行を持たない。`描いた数` の行〔cullOffscreen3d〕も 3D の側）。`[parity3d]` の判定は場面の描き物と `passes[].items` の両方を見る（windowPass3d は 3D が Pass の中にしかない）。`--only-2d` では room.png の比べも飛ばす。
- 比べる相手は §7.2 で今の HEAD から撮る控え（2D の行と CPU の 2D の絵）。`make baseline-check PARITY_BASELINE=<控えのフォルダ> ONLY_2D=1` で一致（0.76.0 とも一致するはずなので並べて見る）。
- `bin/gl-capture.sh --compare` に `--skip <フォルダ名>`（撮った物のフォルダ名と完全に一致する場面を比べない。3D の部屋は `bench/scene3d:` の START が空なのでフォルダ名は `scene3d`）を足し、
  `make gl-capture-check SKIP=scene3d` でテンプレの 2D の場面が 0.78.0 の基準と一致。
- テンプレの gallery: `make baseline-check GALLERY=1 ONLY_2D=1` の reference-gallery.sha256 の比べを、§7.2 で HEAD から撮った gallery の SHA の控え（`--gallery-base` で渡す）と行う
  （テンプレの reference は前から一致しない場面を含むので、reference ではなく gallery の控えと比べる）。テンプレの reference は撮り直さない（テンプレは Scene3d を使っていない）。
- `bin/baseline-check.sh` は位置で引数を読んでいる（`gallery=${3:-}`）ので、`--only-2d` と `--gallery-base <フォルダ>` を足す時にフラグの読み方を作り直す。`--only-2d` では
  E 段階の行（3D の式）も比べない側に入れる。3D と 2D を重ねた行（afterScene3d など）の 2D の側は 2D の門から外れる — 見落としではないと WhyNot を `baseline-check.sh` の頭に書く
  （その 2D の側は §7.2 の偽の確かめで今と同じことを見る）。

### 7.2 偽 = 0.78（退行の網）
- 実装の前に今の HEAD で gl-parity の行・CPU と GL の絵の SHA・room.png・gl-capture の全場面の SHA・night_apartment の `make render`（gallery）の SHA を撮り、
  scratchpad に `baseline-check.sh` が読む形（`gl-parity.txt`・`gl-parity.sha256`・`scene3d.txt`）で控え、PNG そのものも写す（`bench/gl_parity/debug/{gl,soft,diff}/*.png`・
  `bench/scene3d/debug/room.png`・gl-capture の `build/gl-capture/a`・night_apartment の gallery — `diff-dirs` と前後の並べに要る）（C1・C2 の WIP を挟んでいるので 0.76.0 の基準に頼らない）。night_apartment は flix.toml で 0.75.0 に固定なので、check-external と同じく一時の写しの
  lib に worktree の engine_full の fpkg を置いて流す（ゲームのフォルダは汚さない）。前と後で同じ写し方。
- 実装の後、bench/gl_parity と bench/scene3d の project.json を一時に `"scene3dLinearColor": false` にして（コミットしない）流す:
  偽の門は 3 つ（`baseline-check.sh` に「控えに無い名前は飛ばす」口 `--only-known` を足して流す — §7.3 で足す行と絵は控えに無い）:
  - CPU の絵: 控えにある名前だけを SHA で完全一致（room.png も）。night_apartment も project.json を一時に偽にして（一時の写し・`make render` 用に assets も写す）gallery が控えと同じ。
    emission の掛ける順（§2）で 1 ずれた場面があれば、理由を報告に書いて受ける。
  - GL の絵: bench/gl_parity の `PixelDiff` に足す口（2 つのフォルダの同じ名前の絵の max ± と px・`make -C bench/gl_parity diff-dirs A=<控え> B=<今>`。python〔PIL が無い〕は使わない）で、
    成分の差の最大が 1 以下（シェーダーの字が変わるとドライバの式の並べ方で ±1 ずれうる）。ずれた枚数と px を報告する。
  - gl-capture の `scene3d`（実機の道の 3D）も同じ `diff-dirs` で並べて知らせる。
  - 行の差の数: 控えにある行だけを並べて知らせる（GL の絵が ±1 動けば差の px も動くので、門にするなら「差の px の増減 ≦ その行で GL の絵が動いた px」）。
  emission の掛ける順（§2）で偽の CPU の絵が 1 ずれた場面があれば、理由を報告に書いて受ける。

### 7.3 線形の絵（新しい基準）
- gl-parity: 3D の行は全部描き直し。上限を撮り直す前の条件（GL と CPU の片方だけに変換を入れ忘れた差を、新しい上限に吸い込ませない）:
  3D の各行の `max ±` が §7.2 の HEAD の控えの同じ行の `max ±` + 1 以下・差の px が控えの 2 倍を超えて増えた行は理由を説明できるまで撮り直さない
  （`[parity]` の行は `max ±N` を出しているので、`baseline-check.sh` に `--compare-max <控え>` を足して並べる）。線形では暗い所の丸めの差が大きく出る（sRGB の曲線の傾きは暗い所で約 11 倍）ので、
  暗い面の縁に ±1〜2 が増えるのは想定内とし、「説明」の基準は「差の画素が縁・段の境から 1 px 以内か」を `debug/diff` で見ること、とする。通った後に、B 段階の行の上限を線形で撮った差の数の 1.3 倍か
  今の上限の大きい方に取り直す（`Scenes` の許容の数と 0.79.0 の gl-parity.txt）。
- プログラムの種類ごとに受け持つ行: lit（頂点の色）・材質（uv あり / なし・法線マップ・lightmap・半透明・両面）・ビルボード（unlit は depthRed / afterScene3d・lit は `linearOverlap3d` に足す 1 枚）・空（skyGradient3d）。
- 足す行: `linearOverlap3d`（色の絵の材質 + 点光源 2 本の重なり + lit のビルボード 1 枚）・`mipSrgbAverage3d`（市松の床を遠くまで）・`emissionIntensity3d`（strength 40 相当）。
  skyGradient3d・glassPane3d・msaaEdges は既存の行が線形で撮り直しになる。
- bench/gl_parity/src/ExprRows.flix（refactor の索引の外なので grep で確かめる）: GLSL の組み立て（`lightSource() + lightmapLightSource()`）の頭（`lightmapLightSource()` より前）に `colorSpaceSource()` を含め
  `uLinearColor = 0` を置く・光の色は `srgbToLinearColor` に通さずに今の形の pack へ渡す・`lightmapLightAt` の LinearColor の引数は 0（既存の 9 行の値を変えない）。
- 式の行（E 段階）: 今の 9 行は全部 LinearColor = 0 なので、`lightmapLightAt` を LinearColor = 1 で回す行を足す（新しい Select の分かれ道を GL と CPU で突き合わせる）。
  `r3d_srgbToLinear3` / `r3d_linearToSrgb3` を `uLinearColor = 1` で GL で計算した値と CPU の `Texture3d` の式の値を突き合わせる行を 1 本足す（0 だと c のまま返り、何も確かめない）。既存の 9 行は通ったまま。
- 新しい基準 `bench/baseline/0.79.0/`: gl-parity.txt・gl-parity.sha256・gl-parity-cpu.tsv・scene3d.txt・gl-capture.sha256。描き出しの基準の変数を分ける:
  `PARITY_BASELINE`（baseline-check の行と絵。Makefile の新しい変数）と `GL_CAPTURE_BASELINE` を 0.79.0 へ。`BASELINE`（check-external の external.tsv・upgrade）と
  gallery の基準（`--gallery-base`）は 0.76.0 のまま読む（2D は変わらないので写さない）。0.76.0・0.78.0 は消さない。
- 変わった場面の前後の PNG（CPU と GL）を scratchpad に並べ、報告する。

### 7.4 テスト（1 テスト 1 アサート・期待値は式から）
- engine: `Mip.build` の Srgb の市松（1 段上が 188）・Linear は今の値・α は今の値／`srgbToLinearColor` の値／`bakedLight` の Select／
  `ProjectLoader.scene3dLinearColorOf` の読み（真・偽・無い・型違い）（テストはこの純粋な読みだけ。System property の控えはテストしない — Flix のテストは並列に走り、JVM 全体の値を取り合う）／`Gltf` の emissive の Spec と `emissionIntensity`・`GltfMaterial.emissive` は今の値／`Texture3d.mipSpaceOf` の表。
- engine_tools: §1 の表の行ごとに、0 と 1 以外の値（0.5 など。0 と 1 は sRGB の曲線の動かない点で、変換の抜けや 2 回がけを見られない）で 1 テストずつ、期待値は式から:
  材質の albedo・頂点の色（材質の無い物）・tint・ビルボードの絵・emission × emissionIntensity・かすみの色・空・lightmap の Srgb と Linear・background と Depth は変わらない
  （GL と CPU の両方が同じ行を抜けた時の網はこのテストだけ）。偽の道のテストは `drawScene*` を直に呼ぶテストが今 0 本なので、場面・絵の Map・`BufferedImage` を組む小さな下ごしらえを足す。／
  `TestSoftRaster3dLight`（生成物の一致）／線形の場面の画素（白い albedo・ambient 0.5 → 光 0.214 → 出口で 0.5 に戻る・点光源の att 0.25 が 0.537 になる、など式から）／
  半透明は戻した後の値どうしで混ざる／Depth と background は変換されない。入口（`SoftRaster.render*`）を通す今の 3D のテストは真（project.json の無い作業場）で描かれるので、色を見るテストは期待値を線形の式から出し直す（数を写し直さない）。光の式そのものを見るテストは変換を通らない口（`SoftRaster3d.lightAt` など）のまま。偽の道は `drawScene` を偽の引数で呼ぶテストで残す。
- 表の版を入れたら（H6）engine に 1 本: 0〜1 を細かく刻み、表と式の差の最大が 3.9e-5（8bit の 1 段の 1/100）未満・1 を超える値と負の値は式と同じ値。
- render_gl: 生成した frag の字のテスト（`colorSpaceSource` が 1 回だけ・変換の関数の 2 重定義が無い・lit の頂点シェーダーだけが頂点の色を戻す）。今ある字のテスト（「3 つとも偽なら足す前と同じ字」など）は `colorSpaceSource` を含む字に取り直す。
- 触った全部のパッケージ（engine・engine_tools・render_gl・engine_world）で `make sync-layers` → `.layers/<名前>` で test、`make test-engine`。
- `make check-external`: 増える止まりは無い見込み（`materialFieldsOf` を閉じたパターンで受ける所だけが止まりうる）。出たら移行メモで説明する。

## 8. 速さの門

- CPU: `make scene3d-cpu`（bench/scene3d の部屋・温め 5・15 回の中央値）を前後で 3 回ずつ。**+10% を超えたら門を落とす**。
  見積もり（518k 画素 × 最大 9 回 × 30〜50ns を 12 コアで）は +30〜50% で、表の版はほぼ要る。表の版にするかは段取り 3 の中で pow だけの版を 1 回測って決め、
  §7.3 の上限と基準はその後に撮る（基準を撮ってから表の版に替えると撮り直しになる）。表の版でも +10% を越えたら、基準は撮らずに人に相談する。
  画素ごとの pow は、材質の画素で albedo 3・emission 3（emission の無い材質は飛ばす）・出口 3 の最大 9 回、材質の無い画素で出口の 3 回（頂点の色は頂点で戻す）。
  1 本で回すと +数十 ms の見込みで、並列（約 38ms）でも 10% を越えうる。越えたら `Texture3d` に同じ式を 4096 段の表と 2 点の間の直線でつなぐ版を足し
  （0〜1 の外は式へ。差は 8bit の 1 段の 1/100 未満で B 段階の上限に入る）、CPU の画素ごとの変換だけがそれを使う。`make gl-parity-cpu` も並べる（門にしない）。
- 段を作る時間: キャッシュの無い HeadlessRender の 1 枚目（`mipChainOf` は cache が None だと毎回 `Mip.build`）と `scene3d-cpu` で、SrgbCurve の段を作る時間を並べる。
- 読み込み: night_apartment の最初のコマまでの時間と、`scene3d-bench` の p95（GL は描く糸で `mipCopyOf` / `texture3dBound` の段を作るので最初のコマのつっかえ）を前後で並べる（知らせるだけ）。
- GPU の代わり: `make scene3d-bench`（実機の窓の p50 / p95）を前後で並べる（知らせるだけ）。

## 9. 文書・早見表・お題

- 新規 `docs/migrations/0.79.0.md`:
  - 3D の絵が全部変わる（2D は変わらない）。戻すなら 1 版だけ project.json `"scene3dLinearColor": false`（0.80.0 で消える）。
  - 合わせ直しの目安は §7.3 で撮った前後（room・gl-parity）を測ってから書く。予想: 環境光だけの面・lightmap だけの面はほとんど変わらない。
    線形のまま掛かる数（intensity × 届く量・hemisphere）は画面で約 1/2.2 乗で効くので、光の届く端が広く明るくなる → intensity と range は下げる方から試す。
    かすみ・空の混ぜは明るい方へ寄る。toon の段の並びが変わる。半透明は sRGB の値で混ぜる（今と同じ）。lightmap の露出は `intensity` に入れたまま。
    emissive の glb は strength が線形の倍率として効く（段 2 の明るすぎが直る）。材質の mask の遠くの段が少し変わる。
    Spec の emission に 1 を超える値を手で書いた所は、線形へ戻すと 1 次より強く伸びる（2.0 → 約 4.95）ので `withEmissionIntensity` へ移す。`withTint`・ambient と光の color・
    頂点の色に 1 を超える値（ヒットの白飛ばしなど）を書いた所も同じく強く伸びる（外のゲームを洗い出す時に一緒に探す）。
    旗を変えたら Studio から走らせたゲームも起動し直しが要る。hemisphere は線形の量なので、同じ値の ambient より明るく効く（H4）。HDR の Pass では出口が 1 を超える値を縮める（strength 40 → 約 4.85）ので、ブルームのしきい値と
    トーンマップの合わせ直しが要る。スポットの影の strength も光の量に掛かるので、影が薄く見える方へ変わる。
  - ゲームで直す物（Scene3d を使う外のゲームを check-external の顔ぶれと core-polish §7 の表〔dungeon3d_lab・hd2d_lab など〕から洗い出してから書く）: night_apartment（look.json・lights.json・lightmap の intensity・emission）と fps3d_lab（look.json 4 本・RoomView の定数）。この段では直さない。
    （`MaterialData` は pub でない enum なので、ゲームは材質を字で組めない。壊れうるのは `materialFieldsOf` の結果を閉じたパターンで受ける所だけで、engine の中では `DrawHash.putMaterial`。）
- `ProjectLoader.flix` の頭の project.json のキーの一覧に `scene3dLinearColor`（0.80.0 で消える）を足す。
- `docs/lightmap.md` の 26〜29 行を線形の形に直す。round10 の Q3 の「night_apartment と fps3d_lab は段 5 の中で合わせ直す」と段 5 のデモの「露出を exposureStops 0.6 へ」を、
  この計画に合わせて直す（合わせ直しは段 5 のデモで・露出は intensity）。3D の色の決まり（Spec は sRGB の値・出口で戻す・emissionIntensity）を 3D の文書に 1 節。
- `agents-pack/AGENTS.core.md` の早見表に 1 行（`scene3dLinearColor` と `withEmissionIntensity`）。`agents-pack/agent-eval/engine.json` にお題 1 本
  （prompt「0.79 にしたら 3D の部屋の色が変わった。前の見え方に一時的に戻したい」・expect `scene3dLinearColor`）。一時のフォルダに `make new-game` で作ったゲームで
  `make agent-eval ONLY=<お題>`。
- forbid.json はこの段では足さない（0.80.0 で `scene3dLinearColor` を知らせる行）。api-digest・check-docs-sync・precommit・jargon を回す。

## 10. 段取り

1. 実装の前: §7.2 の控えを撮る。
2. engine: `Mip`・`Scene3d`・`LightModel3d`・`ProjectLoader`・`Gltf` → `make gen-light3d` → engine のテスト。
3. CPU: `SoftRaster3d`・`SoftRaster`（`planDraw` の旗・mip の Map）・`RenderCache.keyOf` → engine_tools のテスト・`scene3d-still` → `scene3d-cpu` で速さを測り、表の版にするかを決める。
4. GL: `Render3dGlsl`（`colorSpaceSource`・lit の頂点シェーダー）・`Render3d`（uniform・mip の鍵・状態の旗）・`Paint` / `LwjglLayer` / `GlOffscreen` → render_gl のテスト。
   bench: gl_parity の `ExprRows`・`[parity3d]` の印・新しい行・`PixelDiff` の 2 つのフォルダの比べ、`--compare-max`、`bin/baseline-check.sh` の `--only-2d` / `--gallery-base`、Makefile の `PARITY_BASELINE` → gl-parity。
5. §7.2 → §7.1 → §7.3 → §8。
6. 文書・移行メモ・早見表・お題・ゲートの素振り。

## 11. 残す事（この段でやらない）

- 線形の HDR の描き先で 3D を描いて貼る形（§3 の B）。半透明と MSAA を線形で混ぜたくなったら、2D を線形にするかの判断と一緒に別の計画で。
- ゲームの値の合わせ直し（段 5 のデモ）。glTF の factor と OBJ の Kd を線形として読む直し（H2）。
- 絵ごとの色の空間（`Texture3d` に ColorSpace）— 要るのは「線形の値を書いた色の絵を材質に貼る」時だけで、今の使い手に無い。

## 12. 人に決めてほしいこと（推しつき）

**2026-11-03 決定: H1〜H7 と §13 の口は、すべて人が推しのとおりに決めた。**

- **H1. 戻す所（§3）** — 推し: **(A) 3D の色を作った直後に戻す**。代わりに round10 §3.6 の 4 項目（半透明を線形の Pass で混ぜる・MSAA を線形で平均・
  `Lightmap.colorSpace` を Texture3d へ移す・露出を exposureStops へ戻す）を落とす。(B) は 2D と重なる縁で線形にならず、場面ごとの描き先と貼り直しが増え、
  CPU の描き手の組み直しも要る（見積もり +3〜4 日）。
- **H2. glTF の factor と OBJ の Kd** — 推し: **この段では今のまま（sRGB の値として読む）**。線形として読むなら glTF と OBJ を同じ版で両方直し、旗を偽にしても
  0.78 に完全には戻らないことを移行メモに書く。

- **H3. 旗の持ち方（§5）** — 偽の時は全部の段も Linear（今と同じ）になり、0.78 に戻る。推し: **プロセスで 1 つの値**（project.json を JVM の中で 1 回だけ読む・型に欄を足さない・ルートごとに JVM で 1 回だけ読む — 旗を変えたら起動し直す〔常駐も〕で良いか）。代わりの案は `RasterReq` と `EngineConfig` の欄
  （テストからも入口で真偽を選べるが、0.79 で欄を足して 0.80 で消すと、`RasterReq` を字で組む所〔engine_tools のテスト 13 ファイル・`DrawHash.putReq`・`VideoOut` の 2 か所〕を 2 回壊す）。
- **H4. hemisphere を線形の量として扱う（§1）** — 推し: **線形の量（変換しない）**。intensity と同じ「光の量」で、色ではないため。代わりに見た目は、今まで同じ明るさだった
  ambient 0.5 と hemisphere 0.5 で hemisphere の方が明るくなる（移行メモに書く）。
- **H5. 0.79 で足して 0.80 で形が変わる engine の中の口** — `RenderPaint.create` の cfg・`Render3d.fresh`・`SoftRaster3d.drawScene*`・生成物の `lightmapLightAt` の引数・
  `ProjectLoader.scene3dLinearColorOf`・`GameEngine.loadScene3dLinearColor`。加えて残す口のうち引数が変わる pub の 2 つ（`Mip.build`・`Render3d.Material.resolveTextureAs`）も、
  外の呼び手が無いことを usages と check-external で確かめる（Studio の server は `Preview{Hitbox,Items,Fx,Ui}` で同じ JVM から `SoftRaster.renderToImage` を呼び cwd は Studio のフォルダだが、どれも 2D のプレビュー — 3D の場面を渡す所が無いことを確かめる）（呼び手がいれば新しい名前を足して古い名前を残す）。core-polish §7 の「古い名前は 2 版以上残す」の例外として旗と一緒に 0.80.0 で消してよいか。推し: **よい**（ゲームが呼ばない engine の中の口。
  実装の最初に外のゲームが呼んでいないことを確かめる）。
- **H6. CPU の変換を表の版にする** — 推し: **測ってから決める（ほぼ入れる見込み）**。入れると GL との差が少し増え、B 段階の上限で受ける。
- **H7. 材質の絵を全部 Srgb として平均する（§4）** — 推し: **今は絵ごとの色の空間を持たない**。mask・ノイズなど数の絵を貼った材質は遠くの段の値が少し変わる。
  同じ名前の絵を 2 つの平均の仕方で使う時は鍵で分ける（止めない）。逃げ道は、数の絵を `Scene3d.withNormalMap` と同じく Linear で平均する口を後で足すこと（使い手が出たら `Texture3d` に色の空間を持たせる・§11）。

## 13. 足す pub の口（engine 拡張の相談の一覧）

| モジュール | 口 | 中身 |
|---|---|---|
| `Scene3d` | `MaterialFields.emissionIntensity: Float64`・`withEmissionIntensity(k, m)` | emission を線形に戻した後に掛ける倍率（既定 1） |
| `Texture3d` | `enum TextureUse { MaterialTexture, NormalMap, Lightmap(Texture3d.ColorSpace) }`・`mipSpaceOf(use)` | 段の平均の仕方（GL と CPU が同じ判定）。残す |
| `Mip` | `enum Average { SrgbCurve, Raw }`・`build(average, tex)`（引数が増える） | 色の絵は線形で平均。残す |
| `Texture3d` | `mipAverageOf(space)` | 色の空間 → 段の平均の仕方。残す |
| `SoftRaster3d`（engine_tools） | `drawScene` / `drawSceneHdr` の絵の引数が `名前 → 段の列` から `(名前, Texture3d.ColorSpace) → 段の列` へ | 残す |
| `Texture3d` | `srgbToLinearColor(c)` | 色を線形へ。残す |
| `LightModel3d` | `ScalarInput.LinearColor` | lightmap の足し方の分かれ道。0.80.0 で消す |
| `ProjectLoader` | `scene3dLinearColorOf(rootDir)` | project.json の旗だけを寛く読む。0.80.0 で消す |
| `GameEngine` | `loadScene3dLinearColor(rootDir)` | ルートごとに JVM で 1 回だけ読んで控える。0.80.0 で消す。GameEngine.flix は今 契約（eff と型）と System property の読みだけのファイルで、控えを置く所としてここで良いかも相談に含める（代わりは engine_tools と render_gl の両方から見える engine の小さなモジュール） |
| `RenderPaint`（render_gl） | `create` の cfg の欄・`Render3d.fresh` の引数・`Render3d.State` の欄 | 0.80.0 で消す |
| `SoftRaster3d`（engine_tools） | `drawScene` / `drawSceneHdr` に `linear` の引数 | 0.80.0 で消す |
| `Render3d.Material`（render_gl） | `resolveTextureAs` に `Texture3d.TextureUse` の引数 | 残す |
| `Render3dGlsl`（render_gl） | `colorSpaceSource()` | 色の変換の GLSL の部品 |

## レビューの記録

### 1 回目: 74 点（rev1・新しいレビュー役）
重い指摘: CPU で戻す所が putLayer の手前（半透明・Depth・background まで通る）／CPU は頂点の色 × tint を頂点に書いている／旗の CPU の通り道と描き出しの鍵／
mip の鍵と絵の Map／BASELINE の切り替えで check-external と gallery が止まる／移行メモの向きが逆／人の判断が要る決め事（§3.6 の 4 項目・glTF の factor・OBJ の Kd・場面の欄）／
GLSL の関数の 2 重定義と lightmap の木の 2 本立て。→ rev2 で全部に手当て（場面の欄をやめて描き手の状態に・glTF と OBJ は今のまま・§12 に H1・H2）。

### 2 回目: 78 点（rev2・新しいレビュー役）
重い指摘: lit の頂点シェーダーが uv の無い材質と深度に共有されている（2 回戻る）／reqOf は純粋で VideoOut は通らない・loadProject は寛く読めない／baseline-check.sh が基準を 1 つしか取らず
2D の行だけを比べられない／bench の ExprRows が壊れる／pub の口の一覧が無い・旗を型の欄にすると 2 回壊す（H3）／CPU の tint は頂点に掛けたままで良い・inkOf の抜け／1 を超える emission の Spec。
→ rev3 で全部に手当て（旗はプロセスで 1 つの値・入口は drawAllInto / drawAllIntoHdr / keyOf・`[parity3d]` の印と `--only-2d`・ExprRows・§13 の口の一覧・H3・H4）。

### 3 回目: 80 点（rev3・新しいレビュー役）
重い指摘: GL の旗の読み場所がコードと合わない（withProject は字を持たない・create を呼ぶのは withLwjgl と GlOffscreen.prepare）／pub の関数の引数に linear を足すと 0.80 で 2 回壊れる／
生成物の口の形と新しい分かれ道の式の行／2D の門の変数の食い違い・gl-capture に除外の口が無い・[parity3d] は passes も見る／表の版を決める前に基準を撮る順。
→ rev4 で手当て（`ProjectLoader.scene3dLinearColorAt(rootDir)` に 1 つ・旗を取らない `srgbToLinearColor` / `mipSpaceOf`・pack は今の形・CPU は planDraw で 1 回・Inputs の型は変えない・
E 段階に LinearColor = 1 の行・`--skip`・速さを測ってから基準・H5・H6）。

### 4 回目: 83 点（rev4・新しいレビュー役）
重い指摘: GL の noteCulled の絵の数え方が §4 から抜けている／ExprRows の記述が pack の形と食い違う／控える関数の rootDir の扱いと ProjectLoader の流儀／表の版の精度のテストが無い。
→ rev5 で手当て（resolveTextureAs に TextureUse・呼ぶ所 4 つ・読む関数と控える関数を分けて最初の rootDir が勝つ・ExprRows を直す・表の精度のテスト・頂点シェーダーの宣言・
Srgb の段を作る時間・移行メモ 2 行・H2 に COLOR_0・名前を Texture3d.srgbToLinearColor / Texture3d.TextureUse / ScalarInput.LinearColor に）。

### 5 回目: 84 点（rev5・新しいレビュー役）
重い指摘: GL のスポットの色（spotArrays）が変換の一覧に無い／控えの鍵が rootDir に依らずテストが並列で揺れる・前例の指し違い／引数が変わる「残す」pub の口が外の確かめに入っていない／
材質の絵を一律 Srgb で平均するのは人に聞く事（H7）／名前の食い違い。
→ rev6 で手当て（lightDataOf の頭で光をまとめて変換・控えの鍵にパスと更新時刻・テストは純粋な読みだけ・H5 に 2 つ・H7・resolveMaterialTexture・
名前を srgbToLinearColor / ScalarInput.LinearColor / loadScene3dLinearColor / Texture3d.TextureUse に・出口の組み立ての WhyNot と E の行・GLSL の並べ順）。

### 6 回目: 84 点（rev6・新しいレビュー役）
重い指摘: `SKIP=scene3d__` が何も飛ばさない（フォルダ名は scene3d）／`make reference-check` は無く reference は前から落ちる場面がある／更新時刻つきの控えで絵と鍵が食い違いうる／
`drawScene*` の絵の引数の形が変わる（残す口）・同じ名前の取り合い。
→ rev7 で手当て（`--skip` は完全一致で `SKIP=scene3d`・gallery は HEAD の控えと `--gallery-base`・控えはルートごとに JVM で 1 回・CPU の絵の鍵を (名前, ColorSpace)・
§13 に drawScene* と Mip.Average・`Mip` は scene3d の型に依らない・ProjectLoader のキーの一覧・外のゲームの洗い出し・H3 と H7 に書き足し）。

### 7 回目: 84 点（rev7・新しいレビュー役）
重い指摘: CPU の絵の Map の鍵が偽の時に食い違い材質と lightmap が黒くなる／ビルボードの鍵が未定／E の出口の行が写しを確かめる／偽の GL の門が B 段階の上限で粗い。
→ rev8 で手当て（鍵の空間は `SoftRaster.mipKeySpace(linear, use)` 1 つ・ビルボードは MaterialTexture の鍵・`r3d_surfaceOut` を frag と ExprRows が共有・偽の GL は差の最大 1 以下・
glTF の名前は factor だけ・withoutEmission・Texture3d の WhyNot・lightDataOf の旗・段を作る時間・Studio の確かめ・H の並び）。

### 8 回目: 83 点（rev8・新しいレビュー役）
重い指摘: 上限の撮り直しが GL の入れ忘れを吸い込む／GL の tint と空は lightDataOf の外（6 か所）／偽の GL の差の最大を測る道具が無い。
→ rev9 で手当て（撮り直しの前に HEAD の控えと max ± を比べる `--compare-max`・`putSceneColor` と 6 か所・PixelDiff に 2 つのフォルダの比べ・`uLinearColor` は場面ごとに置く・
表の版でも越えたら相談・1 を超える色の移行メモ・Fs.FileRead の包み・GameEngine の置き場を相談に・重ねた行の WhyNot）。

### 9 回目: 84 点（rev9・新しいレビュー役）
重い指摘: 偽の門の条件どうしが食い違う（GL の ±1 と行の差の数・控えに無い行）／uLinearColor を置いたかのテストは GL の文脈が無く書けない。
→ rev10 で手当て（偽の門を CPU の SHA・GL の差の最大・行は知らせるだけの 3 つに・`--only-known`・`useSceneProgram` に集めて gl-parity の受け持ちの表・lit のビルボードの行・
`--only-2d` の名前の出どころ・surfaceOut の fogOn・Studio の確かめを答えた形に・暗い所の差の基準・assets も写す）。

### 10 回目: 85 点（rev10・新しいレビュー役）
「人が §12 に答えたら、この計画のまま実装に入ってよい」の線に届いた。確定のための指摘: `r3d_surfaceOut` を lit でも使うと頂点の色が 2 回戻る／テストの値が 0 と 1 に寄っている／
段取り 1 の控えが SHA だけ。→ rev11 で手当て（surfaceOut は線形に戻し済みの albedo を受ける・§1 の行ごとに 0.5 などで 1 テスト・控えに PNG も・locs に location・gl-capture の 3D も並べる）。
**ここで止め、§12（H1〜H7）と §13 を人に聞く。**

## 実装の記録（2026-11-03）

計画からずらした所:
- `uLinearColor` は `useSceneProgram` に集めず、光の uniform を入れる `Render3d.putLights`（lit・材質・ビルボードがプログラムを使うたびに必ず通る）で `LightData.linearColor` として入れる。空は `drawSky` で入れる。
- CPU の画素ごとの変換は H6 のとおり表の版（`Texture3d.colorLut` / `srgbToLinearLut` / `linearToSrgbLut`）。頂点の色も表で戻す。場面ごとの色（光・ambient・かすみ・空・tint）は式（`srgbToLinearColor`）。
- CPU の塗りは `SoftRaster3d.surfaceOutAt`（GL の `r3d_surfaceOut` と同じ式の pub の関数・E の行 `exprSurfaceOut`）を呼ばず、同じ並びを表の版で書く。`TestSoftRaster3dLinear.testMaterialPixelMatchesSurfaceOutAt` が材質の画素と突き合わせる。
- `Mip.build` の SrgbCurve は 256 の表としきい値の二分探索（データの `Mip.Mean` で持つ）。
- `ProjectLoader.scene3dLinearColorOf` は有るのに解けない・真偽でない時に 1 行知らせる。`RenderCache.keyOf` は 3D の場面の無いコマでは旗を読まない（2D だけのコマの鍵は変わらない）。
- gl-parity の上限: mipFloor の 3 つを 800 → 950・skinNormal を 400 → 450（線形の差の数の 1.3 倍）。
- 基準 `bench/baseline/0.79.0/`（gl-parity.txt・gl-parity.sha256・gl-parity-cpu.tsv・scene3d.txt・gl-capture.sha256）。Makefile の `PARITY_BASELINE` と `GL_CAPTURE_BASELINE` は 0.79.0。`BASELINE`（check-external）と gallery の基準は 0.76.0。
