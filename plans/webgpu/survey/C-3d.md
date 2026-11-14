# C: 3D の描き手を WebGPU に移す時の調べ（読むだけ）

凡例: 【確】= コードを読んで確かめた / 【推】= 推測。パスは /Users/abab/Desktop/flix_game_engine 直下からの相対。
render_gl/src/Render3d.flix = R3、Render3dGlsl.flix = GLSL。

## 0. 先に結論

1. 3D の描き手の「GL 依存」は 2 層。(a) 上の層（ScenePlan・Batch・Counts・Preload の予算・材質のキャッシュ鍵・Light の詰め替え）は GL を呼ばない純粋な Flix で、そのまま使える【確】。
   (b) 下の層（R3 の drawScene/drawBatch/uploadMesh、Shadow、Material の bind*、DataTexture、Instancing/JointTexture の上げ方）は `gl: GlContext` を直接引数に持つ【確】。WebGPU 版は (b) を丸ごと別実装にする。GlContext の裏に WebGPU を隠す案は不可（下の 2・4）。
2. `Scene3dRenderer.Renderer` の形は「ほぼ足りる」が、GL の物が型に 2 か所漏れている（Dest#framebuffer、RegisteredTexture#texId）。さらに本当の継ぎ目は Renderer の外（Frame.flix の emitMerged が 2D の run の途中で draw を呼ぶ）にある。WebGPU では「2D の render pass を 3D の場面ごとに閉じる」必要があり、ここが一番大きい非互換。
3. WebGL2 の回り道は多い（データをテクスチャに詰める・UBO 無し・計算シェーダー無し）。WebGPU では storage buffer と compute で消せるが、「消す」と GL 版と別の設計になり、2 つの描き手を保守することになる。得は主に CPU 側の代金（毎コマ Flix が組む instance 行列の詰め直し・uniform の呼び出し数）と、GPU 側の間引き。
4. シェーダーは GLSL を字で組み立てている（ShaderGen.compile3d の ShaderDoc の木 + LightModel3d.Codegen の式の木）。式の木から出す所は出口（Codegen の `Target` enum）に WGSL を足せるが、手書きの GLSL 文字列（Render3dGlsl の約 580 行）と ShaderGen の GLSL 部品（1218 行）は書き直し。

## 1. 3D の 1 コマの流れ

### 1.1 Flix 側の入口（2D との境目）
- ゲームは `Draw3d.drawScene3d(RenderCmd)` effect で場面を投げる。`RenderCmd = { at, clip, scene: Scene3dCmd }`（engine/src/scene3d/Scene3d.flix:806）。
  `Scene3dCmd` の欄: size・camera・instances・billboards・pointLights・spotLights・directionalLight・environment・resolution(Native|Design)・output(Color|Depth)・zIndex・time・textures・sky・environmentMap（Scene3d.flix:592-600）【確】。
- 描き手側の handler は `RenderPaintHandlers.handleDraw3d`（render_gl/src/PaintHandlers.flix:54）→ `RenderPaint.queueScene3d`（Paint.flix:749）で paint の `pendingScene3dHolder` に積むだけ【確】。テスト用の捨て handler は `Platform.runNoopDraw3d`（engine/src/platform/Platform.flix:136）。
- 描くのは `submitFrame` → `renderFrameMixed` の中で、2D の z の並びの 1 点（`Merged.MScene3d(i)`、Frame.flix の emitMerged）。そこで直前までの sprite/poly の run を flush してから `drawScene(viewport, i)` を呼ぶ【確】。

### 1.2 prepare（コマ頭・2D を描き始める前）: R3 `prepareScenes`（R3:389）
順番は次のとおり【確】。
1. `planScenes`（ScenePlan.flix:32）— 場面ごとに `sceneDrawsOf`:
   - 視錐台の判定（`Scene3d.isOutsideFrustum`）→ `splitByMaterial`（Material.flix:23）= 材質ごとの分けとプログラムの引き当て（初めての材質はここで GLSL を組む）→ `groupInOrder` で形（contentHash）× 鍵（kindBits・shaderHash・wrap・cutout・params・法線マップ）の batch → `groupByTextures`。
   - Output.Color の時の分け: plain（頂点の色・骨なし）・skinned・opaque（材質、プログラム番号順）・blended（半透明、1 体 1 batch）。Output.Depth の時は cutout か両面の材質だけ材質の道、それ以外は plain/skinned、半透明は描かない。
   - 影の描き材料 `shadowPlansOf`（Shadow.flix:22）も同時に作る（影を落とす光ごと）。
   - 姿勢の行の割り当て（`withPoseRows`・JointTexture.assignRow: 同じ姿勢は同じ行にまとめる）。
2. `JointTexture.upload`（姿勢を RGBA32F 1 枚へ 1 回）→ `Instancing.upload`（全場面の全 batch の 1 体ごとの値を RGBA32F 1 枚へ 1 回。texSubImage 1 回）。
3. `renderShadows`（Shadow.flix:36）— 場面ごと・影を落とす光ごと（スポット 1 本 + 太陽）に深度だけの FBO へ描く。mapSize ごとの何枚目かで FBO を分け、最後に 1 度だけ `endShadowPass`。
4. Design 解像度の場面は `renderDesign` で design px の FBO へ先に描き切る（R3:462）。Native の場面は後の `drawItem` で 2D の並びの中に描く。

### 1.3 draw（2D の z の 1 点・場面ごと）: R3 `drawItem`→`drawScene`（R3:418, 523）
パスの並び（Output.Color の時）【確】:
| # | パス | 中身 | GL の状態の出入り |
|---|---|---|---|
| a | 開始 | viewport・scissor 設定、地の色（background）を clear、深度 clear、DEPTH_TEST/CULL_FACE(CW, BACK)・BLEND 切り | beginScene |
| b | 環境マップ | `bindEnvironmentMap`（unit 12・sampler） | |
| c | 空 | `drawSky`: 深度テスト・カリングを切り、全画面の四角（6 頂点）1 draw。sky があれば background は使わない | 深度/カリングの切り替え 2 回 |
| d | 不透明（頂点の色） | plain を lit program で、skinned を skinned lit program で。batch ごとに `uInstanceBase` を入れて `drawElementsInstanced` | program 切り替え 2 回まで、`putLights`(約 20 uniform)・`putShadow`(7)・`putSunShadow`(9) |
| e | 不透明（材質） | `drawMaterials`: プログラム番号順。プログラムが変わるたび `useMaterialProgram`(view/proj・光・影・uTime・uDepthOut)。batch ごとに uCutout・uParamN・絵 unit 0〜5 の bind+sampler+uTexFlip+uTexLevels・法線マップ(unit 6)・lightmap(unit 8)・必要なら alpha-to-coverage の enable/disable・両面なら CULL_FACE 切り替え | batch ごとに最大 数十回の GL 呼び出し |
| f | ビルボード | CULL を切り、1 枚ごとに bindTexture + uniform 約 8 + `drawArrays`（1 枚 1 draw、instanced でない） | |
| g | 半透明 | depthMask(false)・blendFuncSeparate、`Scene3d.blendOrderOf` の順（遠い順）、1 体 1 batch | |
| h | 後がけ | `unbindShadowMap`・`releaseEnvironmentMap`・`releaseMaterialUnits`（sampler 外し）・`endScene`（DEPTH/CULL 切り・BLEND 戻し・viewport 戻し） | |
Output.Depth は d・e・f だけで fragment は灰色（距離）を出す（ピント用の Pass）。
Design の場面は draw 時に `blitDesign`（FBO を ONE, ONE_MINUS_SRC_ALPHA で重ねる全画面 1 draw）。

### 1.4 1 コマの draw call・状態切り替えの数を決める物
- draw call（`Counter.DrawCalls`・Counts.flix:7-29。`countDrawCall` は drawBatch・drawSky・drawBillboard で数える。blitDesign は数えていない【確: grep でなく Counts/R3 を読んで】）の下限式【推】:
  = (影を落とす光の数 × その影の batch 数) + 色の段の batch 数（plain + skinned + opaque + blended の各 batch。batch = 形 × 材質の鍵 × skinned、半透明は 1 体 1 batch、lightmap つきも 1 体 1 batch）+ ビルボードの数（視錐台の中）+ 空 1 + Design の blit。
- batch が増える要因: 形（Mesh3d.contentHash）の種類・材質の鍵（shaderHash × kindBits × wrap × cutout × params × 法線マップの絵と強さ）の種類・材質の絵の名前の組・骨つきか。同じ形で tint・world だけ違う物は 1 batch（tint は instance 側）。
  1 棟 1 形の都市は「形の種類 ≒ 物の数」で batch が増え、draw call が物の数に近づく（Batch.flix:48-50 のコメントが同じ事を書いている）。
- 状態切り替えの数は主に (i) 材質のプログラム切り替え回数（`inDrawOrder` でプログラム番号順にして減らす。`drawMaterials` は同じ番号が続けば再設定しない）、(ii) batch ごとの texture/sampler/uniform の更新、(iii) 場面ごとの beginScene/endScene、(iv) 影の地図の FBO の出入り（影を落とす光 × 場面）。
- 場面は 1 コマに 3 回組まれると plans/engine-scene3d-cpu.md が書く（色の Pass・影の地図・奥行きの Pass）【確・同 plan の記述】。
- 診断の欄: `FrameDiagnostics.Scene3dCounts`（instances・drawn・drawCalls・droppedPoint/SpotLights・meshUploads・meshEvictions・texture3dUploads・mipCopies・materialBuilds・jointUploads・targetRebuilds・cpuPhases[shadows/split/draw/endFrame/mip/preload]）。R3 `takeCounts` が返す。

## 2. `Scene3dRenderer.Renderer` の値（2D と 3D の境目）

定義: render_gl/src/Scene3dRenderer.flix:4-18【確】。
```
Renderer = {
  prepare   = (Int64 /*世代*/, String -> Option[RegisteredTexture] \ IO /*2D の絵の登録を名前で引く*/, Dest, List[Scene3d.RenderCmd]) -> Prepared \ IO,
  endFrame  = Int64 -> Unit \ IO,
  takeCounts= Unit -> FrameDiagnostics.Scene3dCounts \ IO,
  readsTexture = (String, List[Scene3d.RenderCmd]) -> Bool,        // 純粋。Render3d.readsTexture
  preload   = (Int64, String -> Option[RegisteredTexture] \ IO, Scene3d.PreloadCmd) -> Unit \ IO }
Prepared = { zIndexes = Vector[Int32], draw = (Viewport, Int32) -> Unit \ IO }
Viewport = { x, y, width, height : Int32, scaleX, scaleY : Float64 }      // GL の左下原点の画素
Dest     = { framebuffer = Int32, format = RenderTarget.Format, samples = Int32 }
RegisteredTexture = { texId = Int32, width, height : Float64, flipped = Bool, version = String }
```
作り手は 2 つ: `Render3d.makeRenderer(gl, config, drawMode)`（R3:361）と `Scene3dRenderer.none()`（Scene3dRenderer.flix:36）。WebLayer の `makeWarningRenderer`（engine_web/src/WebLayer.flix:51）は none の prepare だけ差し替えた物（`{ prepare = … | none() }` の形・3 つ目の実質的な作り手）【確】。`withoutPreload` は preload だけ none に替える。

### 2.1 3 つ目（WebGPU）をこの形のまま足せるか
- **型として足りる部分【確】**: 4 欄（prepare・endFrame・takeCounts・readsTexture・preload の 5 欄）は純粋な関数の欄で、GL の語は型に出ない。Counts・readsTexture・preload の宣言は共通のまま使える。`Prepared#draw` が「2D の並びの 1 点で呼ぶ」クロージャなので、中身を WebGPU にしても呼び手（Frame.flix）は変わらない。
- **GL の物が型に漏れている所【確】**:
  1. `Dest#framebuffer = Int32` — 描き終えた後に戻す FBO の名前（GL のハンドル）。WebGPU には「戻す FBO」が無い。`format` と `samples` は GPU 共通の語（wgpu の TextureFormat にそろえた名前）で漏れていない。
  2. `RegisteredTexture#texId = Int32` と `flipped`（レンダーターゲットは行 0 が下で v を反転して読む）— ビルボードと材質の絵が 2D の登録簿の GL テクスチャを直に貼る。WebGPU の描き手は 2D 側の GPU テクスチャを GPUTexture として知る必要がある。
  3. `Viewport` は「GL の左下原点の画素」（Scene3dRenderer.flix の doc）。WebGPU の viewport は左上原点。実装の中で y を反転すれば足りる（型は変えなくてよい）。
  4. `prepare` の `textureOf` は `IO` の関数を渡す形で、返す物（RegisteredTexture）が上の 2。
- **型の外の継ぎ目（こちらが本丸）【確】**:
  - draw が 2D の run の途中で呼ばれ、呼ぶ側は `gl.viewport`/`scissor` を戻す前提（Renderer 側が戻す、`drawItem` R3:430-433）。2D は同じ framebuffer・同じ stencil（mask 付き sprite はステンシル）・同じ MSAA に描いている。WebGPU では 2D の render pass を閉じて 3D の render pass（深度つき）を開き、また 2D の pass を `loadOp: load` で開き直す。2D 側（Frame.flix・RenderSprite・RenderShader 全部）も WebGPU 化されていれば pass の分割として自然に書けるが、2D だけ WebGL2・3D だけ WebGPU の混在は 1 つの canvas で不可（同じ canvas に 2 つの context は取れない）【推】。
  - 3D → 2D の逆向き: 2D の絵の登録簿（RenderAsset.TextureRegistry の GL テクスチャ）を 3D の材質が読む（`mipCopyOf` が `copyTextureLevel0`/`readTextureArgb` で写す）。2D がレンダーターゲットへ描いた絵を 3D のビルボードが読む（`readsTexture` が Pass の前のコマの写しを読むか決めるために在る）。2D と 3D が違う API だと、この共有ができない。
  - Pass（HDR・ポスト処理）と `Dest#samples`: 3D は描き先が標本を持つ時だけ alpha-to-coverage を使い（ScenePlan.flix:40-43 が `dest#samples > 1 and gl.hasAlphaToOne()`）、Design の場面は標本なし。WebGL2 版は alpha-to-one が無い（`hasAlphaToOne`、plans/engine-browser-3d.md の表）ので discard に落ちる。WebGPU は alpha-to-coverage はあるが alpha-to-one は無い【推・WebGPU の仕様の記憶】。
- 判定: **Renderer の 5 欄の形はそのままで良い。直すのは `Dest#framebuffer` と `RegisteredTexture#texId` の 2 点**（型を不透明なハンドルにする。AGENTS.md の「取り違えは型で止める」の対象）。ただしそれは WebGPU 版の最小の話で、2D も WebGPU に移すかどうかが先に決まる（plans/engine-browser.md が言う「コンシューマの切れ目は GL の層でなく Draw2d/Draw3d の effect の高さ」に合う: `Platform.Draw3d`（drawScene3d・preload3d）の handler を WebGPU 側で差し替えるのが一番低い切れ目で、Renderer の値を介さない）【推】。

## 3. GLSL

ファイル: render_gl/src/Render3dGlsl.flix（579 行・全部 `#version 330 core`・GLSL ES 3.0 と 330 core の出し分けは**無い**【確: ファイル内の #version は 330 core だけ】）。WebGL2 版は ANGLE/ブラウザが 330 の字を ES 3.00 へ受けるわけではないので、WebGl2.java 側（fge.web）が字を置き換えているはず【推・未確認。render_gl/java/fge/js と teavm を読んでいない】。

### 3.1 本数（固定のプログラム）【確】
| 名前 | 頂点 | 頂点の変種 | frag | 備考 |
|---|---|---|---|---|
| lit | litVertexSource(false) | plain | litFragmentSource | 頂点の色 |
| lit:skin | litVertexSource(true) | skinned | 同上 | |
| depth | meshVertexSource | | depthFragmentSource | 影の地図と Output.Depth で共用（色の出力は捨てる） |
| depth:skin | skinnedMeshVertexSource | | 同上 | |
| billboard | billboardVertexSource | | billboardFragmentSource | |
| sky | blitVertexSource | | skyFragmentSource | |
| blit | blitVertexSource | | blitFragmentSource | Design の貼り |
固定 7 本。

### 3.2 変種（材質のプログラム）
- 材質 1 つのプログラム = 頂点 `materialVertexSource({skinned, uv, lightmap})` + frag `materialFragmentSource(glsl, kind)`。
- 頂点の変種（組み立ての分岐）: 7 通り（(f,f,f)=meshVertex・(t,f,_)=skinnedMesh・(f,f,t)=uv2 付き・(f,t,lm=f/t)・(t,t,_)）【確】。
- `ProgramKind` の bool は 8 個: skinned・uv・normalMap・lightmap・blend・doubleSided・coverage・metallicRoughness（R3:184）。制約（normalMap は uv つきだけ・lightmap は骨なしだけ）を入れると**材質の木 1 つあたり最大 144 通り**【推・手計算: 骨なし(uv 無 32 + uv 有 64)=96、骨つき(uv 無 16 + uv 有 32)=48】。実際に出るのはその一部。
- さらに**材質の木ごとに別プログラム**（`ShaderGen.compile3d(spec, emission, metallicRoughness)` が ShaderDoc の木から GLSL の関数・uniform・paramNames・texReads・cutoutAlpha を作る）。鍵は `materialKey` = "3d" + kind の字 + `shaderHash`。LRU の上限は `max(64, pinned×2)`（Material.flix:646）。
  ゲームが材質の木を何種類使うかで本数が決まり、数十〜数百になりうる【推】。cutout・params・wrap・tint・emissionIntensity は uniform/instance で渡すので鍵に入れない。
- 字が変わらないための設計: blend・doubleSided・coverage・metallicRoughness は uniform の分岐にせず別プログラム（R3:182「使わない材質の GLSL の字が変わり、どの GPU でも同じ絵になる保証が崩れる」）。→ WebGPU では pipeline 側の state（blend・cull）に任せて `override` 定数に出来る物もあるが、字の固定は gl-parity の前提なので同じ方針を続けるなら別 shader module のまま。

### 3.3 機能の分かれ方
| 機能 | どこ | 分け方 |
|---|---|---|
| 光（ambient・hemisphere・toon・点光源 8・スポット 2・太陽 1） | `lightSource()`（Render3dGlsl:157）。式は `LightModel3d.Codegen.toGlsl("lightAt", …, lightingModel())` | 式の木から生成（CPU の描き手は同じ木から生成した Flix `SoftRaster3dLight`） |
| かすみ | `fogAt`（木から生成）+ `fogged`（uFogOn で分岐 = uniform 分岐） | 木 |
| PBR（metallic/roughness・鏡面・映り込み） | `metallicRoughnessSource()`: `pbrAt`（木）+ `environmentSource()`（`environmentDirectionAt` は木・UV は手書き）。kind#metallicRoughness の時だけ字に入る | 別プログラム |
| 環境マップ | uEnvMap(unit 12)・uEnvBoxOn/Min/Max/Center(箱の補正)・uEnvLevels。段は roughness×(levels−1) を textureLod に明示 | uniform の on/off（uEnvOn）。字は PBR 版だけ |
| 影（スポット 1 + 太陽 1） | `shadowSource()`/`sunShadowSource()`: `shadowLitFraction` を **texelFetch + 手計算の PCF（(2r+1)² 回のループ・CPU と同じ数え方）**。uShadowOn/uSunShadowOn の uniform 分岐 | 手書き（木の外）。sampler2DShadow を使わない（R3 Shadow.flix:121「比べ方を CPU とそろえる」） |
| skinning | `skinDeclarations`/`skinPrelude`: 頂点属性 aJoints(ivec4)・aWeights(vec4) + joint texture(unit 10) を texelFetch 4 本で mat4 に。最大 64 ジョイント（Skin3d.maxJoints） | 別プログラム（skinned=true） |
| lightmap | `lightmapSource()`: 2 本目の uv（location 7）・uLightmap(unit 8)・`sg_texMip`（微分で段を選ぶ）・`lightmapLightAt`（木） | 別プログラム（骨なしだけ） |
| 法線マップ | `normalMapSource()` + `applyNormalMapSource()`（手書きの TBN）。タンジェントは別 VBO（location 6・初めて要る時に上げる） | 別プログラム（uv つきだけ） |
| 材質の絵 | uTex0..5（unit 0〜5）・uTexFlipN・uTexLevelsN・`sg_texMip`（ShaderGen.texMipSource）で段を自分で選ぶ。sampler は 8 種を使い回し | uniform/sampler |
| cutout | uCutout で discard（uniform 分岐）か、coverage 版で alpha-to-coverage（α = clamp((a−0.5)/fwidth(a)+0.5)） | uniform + 別プログラム |
| 色の空間 | 頂点の色は lit の頂点シェーダーで sRGB→線形、材質は frag で戻し、最後に 1 回 `r3d_linearToSrgb3`。**描き先は sRGB フォーマットにしない**（Render3dGlsl.flix:9-11 の WhyNot） | 手書き |
| Output.Depth | uDepthOut（uniform 分岐）で灰色（距離）を出す | uniform |
| 空 | skyAt（木）。向きは NDC から | 別プログラム |
| 位置・法線の頂点 | instance 行列を `uInstanceBase + gl_InstanceID` で texelFetch（下の 4） | |
`sin` を使う hash ノイズ等が ShaderGen にある（plans/browser-spike.md:126 が「スマホの GPU は highp が無い」と書く）【確・同 plan】。

### 3.4 WebGPU への移し方の難所【推】
- WGSL は GLSL と文法が違い、手書き字列（約 580 行 + ShaderGen の GLSL 部品）を書き直す。`LightModel3d.Codegen` は `Target` enum（Flix | Glsl・Codegen.flix:20）の出口を足せる作りで、`toGlsl` の隣に WGSL を足せる（木から作る 5〜6 式: lightAt・fogAt・pbrAt・environmentDirectionAt・skyAt・lightmapLightAt）。
- 手書きで残る式（影の PCF・TBN・lightmap の段つき読み・r3d_surfaceOut・sg_texMip）は gl-parity の「式の行」で CPU と突き合わせる決まり（Render3dGlsl.flix の頭）。WGSL 版にも同じ突き合わせが要る。
- WGSL に `fwidth`・`dpdx` は在るが、uniformity 制約（微分は一様な制御の中だけ）で、`sg_texMip` を if の中に置けない所は GLSL と同じ事情（normalMapSource の WhyNot と一致）。
- `discard` と `texelFetch`・`textureLod` は WGSL に相当がある。`atan(x, y)` の引数順・極で 0 に固定する式は別途確認が要る。

## 4. WebGL2 の制約のために回り道をしている所（WebGPU で要らなくなる物）

| # | 回り道（今） | 場所 | WebGPU なら | 得の中身 |
|---|---|---|---|---|
| 1 | uniform buffer を使わない。光・影・材質の値は uniform 1 個ずつ `gl.uniform*`（putLights 約 20 回・putShadow 7・putSunShadow 9・材質の uParamN・uTex 系 batch ごとに 10〜数十） | Light.flix:101、Shadow.flix:228-258、Material.flix:119 | bind group + uniform buffer 1 本（場面ごとに 1 回 `writeBuffer`）。パス内は dynamic offset | JNI/wasm→JS の呼び出し回数の減少（wasm で重い）。ただし Flix 側の値の組み立て（LightData の Array 詰め）は残る |
| 2 | 1 体ごとの値（world 4×vec4・法線 3×vec4・tint・emissionIntensity・poseRow）を **RGBA32F の 2D テクスチャ**へ詰め、頂点シェーダーが `texelFetch(uInstanceBase + gl_InstanceID)` で読む。1 体 8 texel = 128 byte。幅は 256 texel(= 64 ジョイント × 4)・1 行 32 体・行の上限 = MAX_TEXTURE_SIZE | Instancing.flix（冒頭コメント）・DataTexture・Render3dGlsl:98-116 | **storage buffer**（read-only）か `instance step` の頂点バッファ。行数の上限・テクスチャの 3 枚リング・`LINEAR は WebGL2 で不完全`の回避が全部消える | 上限（1 prepare の体数が `rows×32`）が消える。コードも消せる（DataTexture 121・Instancing 99 行相当）。詰める CPU 側（packDraw: 1 体 8 vec4 の f32 変換）は残る |
| 3 | joint texture（1 行 1 姿勢・1 ジョイント 4 texel・RGBA32F） | JointTexture.flix | storage buffer（UBO だと 16 KB 保証に重複無し姿勢が入らないと WhyNot に書いてある） | 行の上限・同じ姿勢のまとめ（assignRow）は残してもよい（まとめは帯域を減らす）。texelFetch 4 本 → storage 配列の読み |
| 4 | 3 枚のリングで前のコマの draw が読むテクスチャへ書かない（ドライバが GPU を待つ） | DataTexture.flix:33-34 | `queue.writeBuffer` は内部で staging を回す。自前のリングは不要 | コード削減 |
| 5 | 影の地図: 深度テクスチャ + `texelFetch` で自前の PCF。sampler2DShadow を使わない | Shadow.flix:121・Render3dGlsl:215 | `texture_depth_2d` + `textureLoad` でそのまま同じ式が書ける。`sampler_comparison` も使えるが、CPU との一致のため使わない方針なら変わらない | 回り道ではない（WebGL2 でも texelFetch は使える）。**深度テクスチャの比較は WebGPU でも自前のまま**【推】 |
| 6 | 影の描き先: `useNoColorBuffer`（drawBuffers[NONE]）・`DEPTH24` を `UNSIGNED_INT` で確保 | Shadow.flix:122-146、GlContext.texImageDepth24 | depth32float か depth24plus、色の attachment 無しの render pass（そのまま書ける） | 消える回り道は小さい |
| 7 | 浮動小数の描き先: `RGBA32F` の読みは LINEAR 不可（NEAREST のみ）、HDR は RGBA16F（`texImageRgba16fZero`、RenderTarget.Format は Rgba8Unorm | Rgba16Float の 2 つ）。拡張（EXT_color_buffer_float）依存 | rgba16float/rgba32float を Filterable/Renderable の feature で確認。32F の filtering は `float32-filterable` feature | 機能の判定が 1 か所になる。対応していない端末では Rgba8Unorm へ落とす既存の方針と同じ |
| 8 | MRT: **使っていない**【確: R3 に drawBuffers/COLOR_ATTACHMENT1 の呼び出し無し】 | | | 移植の障害にならない |
| 9 | 計算シェーダーが無いので CPU でやっている事: (a) 視錐台の間引き（Frustum.intersectsBox を物ごとに Flix で）、(b) batch のまとめ（groupInOrder・材質の鍵の比較）、(c) 半透明の並べ替え（Scene3d.blendOrderOf・目からの距離）、(d) 描く順（inDrawOrder・プログラム番号順）、(e) skinning は頂点シェーダー（GPU）でやっているので CPU ではない、ただし**姿勢の行列（Pose3d.jointMatrices）は CPU**、(f) メッシュのタンジェントを CPU（Mesh3d.tangents）、(g) mip の作成（CPU Mip.build または GPU generateMipmap）、(h) 環境マップの絵は事前 | ScenePlan・Batch・Material.splitByMaterial | compute で (a)(c) と indirect draw（`drawIndexedIndirect`）に出来る。ただし **CPU の描き手（SoftRaster3d）と GL が同じ判定を使う決まり**（plans/engine-scene3d-cpu.md「決まり」）で、compute に移すと 3 つ目の式の実装になり、描く順も変わりうる（半透明の順は絵が変わる） | 一番大きい余地だが、ここだけが「見た目が変わらない」保証と衝突する |
| 10 | インスタンス描き: WebGL2 の `drawElementsInstanced` を使用。batch にならない物も instance 数 1 | drawBatch R3:736 | `drawIndexed(count, instanceCount, …, firstInstance)` で first を渡せる。**GLSL の `uInstanceBase` uniform を batch ごとに更新**している所が `@builtin(instance_index)` + firstInstance で uniform 更新が要らなくなる | batch ごとの uniform 1 回が消える（`gl.uniform1i(instanceBase)` は drawBatch の唯一の uniform） |
| 11 | alpha-to-one が WebGL2 に無く、ブラウザは cutout を discard に落とす | GlContext.hasAlphaToOne | WebGPU にも alpha-to-one は無い【推】。alpha-to-coverage の縁のなめらかさはデスクトップに劣る | 変わらない |
| 12 | `GlContext` が int のハンドルで表す（Flix 0.78 が型引数つき interface に primitive を渡す所で VerifyError）。WebGL2 版は int と WebGLTexture の表 | GlContext.java 冒頭 | WebGPU のオブジェクト（GPUBuffer・GPUTexture・GPUBindGroup・pipeline…）は多種で、同じ int の表を持つと型が崩れる | この interface に WebGPU は載らない（GPUBindGroup・pipeline 等、GL に無い概念が要る）|

### GlContext の大きさ【確】
178 行・約 110 メソッド。WebGPU に写せる物は buffer・texture・sampler・draw の一部だけで、`useProgram`・`uniform*`・`getUniformLocation`・`bindVertexArray`・`activeTexture`・`bindFramebuffer`・`enable/disable`（状態機械）は pipeline・bind group・render pass に写らない。結論: GlContext の裏に隠さず、3D の下の層を別実装にする。

## 5. CPU の側の代金（Flix が毎コマやっている事）

### 5.1 コードから見える毎コマの仕事【確】
- 場面ごと: `Scene3d.frustumOf`・`pickLights`（光の選択）・`lightDataOf`（LightData の約 30 個の `Array[Float32,Static]` を毎コマ作る。R3 `lightDataOf` Light.flix:9）・`matrixArray(view/proj)`（`Mat4.toColumns` → f32 に詰め直し・R3:775）・`Scene3d.directionalShadowOf`・`shadowMatrix`。
- 置いた物ごと（N 個）: `meshDrawOf`（instanceFieldsOf・skinningOf・`outside(placed)` = 視錐台の判定 = 境界の角 8 つを `Mat4.apply`・`Frustum.intersectsBox`）、`splitByMaterial`（材質の fields・vertexKindOf・`batchKeyOf`・`groupInOrder`（HashMap + Ref + Map））、`groupByTextures`（`hasSameTree` で木の突き合わせ）、`packDraw`（world・法線行列・tint を 1 体 32 float に f32 変換して FloatBuffer へ）、影の道でもう一度 `meshDrawOf`/`shapeBatches`（影を落とす光ごと）、Depth の Pass でも同じ。
- batch ごと: uniform 数回〜数十回 + `drawElementsInstanced`（wasm→JS の跨ぎ）。
- 姿勢（骨つきの物）ごと: `Pose3d.jointMatrices` と `assignRow` の `isSamePose`（同じ 1 つの値か → 行列比較）、packRows。
- 毎コマ頭・終わり: endFrame の `sweep*`（材質・影の FBO・場面の絵・DataTexture・頂点の合計）。

### 5.2 重い所に関する記述（計画書・docs が言っている事）
- plans/engine-scene3d-cpu.md【確・同文】: 3D の箱庭 lamplighter で物が約 90 → 857 個に増え、1 コマが 5.7 ms → 14.1 ms（M4 Pro・960×540・垂直同期なし）。別の MacBook は 31〜38 fps。**GPU でなく CPU**で、時間は「描く物の一覧を組む」所。jstack 60 回の内訳（約 250 個）: submitGpuItems 内が約 7 割 = planScenes/sceneDrawsOf（約 3〜4 割）+ drawScene/drawBatch/meshDrawOf/meshEntry（約 2 割）+ buildProgram→eqSpec（約 1 割）。GL の呼び出し（draw・blit・present）は 2 割弱。最上位のフレームは record の欄の引き `lookupField` が 4 割強。場面は 1 コマに 3 回組まれる。
- plans/engine-static-group.md【確】: 毎コマ全部の物を見直す方式（視錐台 → 材質 → batch → 描く順 → 行の上げ直し）なので時間が物の数に比例する。動かない物の束（StaticGroup3d）案（未着手・相談用）。見込み: 250 個のうち動かない 200 で 5.7 → 3〜4 ms（測っていない）。リスクに「GL の instance の行の持ち方（今は毎コマ 1 枚のテクスチャへ全部書く）を束ごとの持ち越しと両立させる」とある — **WebGPU の storage buffer なら束ごとに持ち越す設計が自然**【推】。
- plans/engine-city-scale.md【確】: 都市 3 km・2 km（plateau_city・ome_city）。1 棟 1 形で batch が物の数に近づく。弱点表: LOD 無し・置いた物ごとの視錐台判定だけ。H（MultiMesh/StaticGroup）は B（visibility range）と区画のつなぎで足りなくなってから。
- docs/performance.md §11「3D の場面の描く量」: 視錐台の外を間引くと 1 物あたりの uniform と draw call の仕事が減る（`scene3dCounts#drawn`）。
- docs/scene3d.md「重さを測る」: 診断は `App.withDiagnostics()` → `FrameDiagnostics.summaryLines`。
- CPU の描き手（SoftRaster3d）の bench: bench/baseline/0.79.0/scene3d.txt の room は CPU 描き 38〜44 ms（M4 Pro・並列）・157 ms（直列）。これは GL でなく CPU ラスタライザの時間。

### 5.3 スマホの基準【確（メモリの記録のみ・リポジトリの文書には無い）】
2026-11-06、Pages の fps3d-room（`?fps=1`）を Galaxy S24 Ultra で開いて **46.5 fps・cpu 20.7 ms**（~/.claude の memory project_phone_3d_baseline）。plans/engine-browser-3d.md:90 は「2026-11-05 に人の手元のスマホで bench/scene3d が 60 fps 安定（機種は未記録）」。
→ 20.7 ms の cpu は「JS/wasm 側の Flix の組み立て」が主で、**GPU より CPU が詰まっている**証拠として読める【推】。WebGPU が減らせるのは GL 呼び出しの跨ぎの回数（約 2 割）と instance 行の上げ直し。Flix の組み立て（約 7 割）は WebGPU にしても減らない — plans の 2 本（scene3d-cpu・static-group）の仕事が効く。

## 6. ブラウザで 3D を出す道: engine_web/src/WebLayer.flix の `withProject3d`

- 入口（WebLayer.flix:40）: `withProjectUsing(rootDir, (gl, config) -> Render3d.makeRenderer(gl, config, DrawMode.Instanced), f)`。2D 用の `withProject` は `makeWarningRenderer`（none の prepare を差し替え・初回に 1 回警告）。**2D の入口から Render3d へ静的に届かせない**ため（3D を使わない wasm を太らせない・WhyNot）。
- `withWeb` は canvas の WebGL2（`new WebGl2()`）を `GlContext` として作り、`RenderPaint.create(gl, { …, scene3d = makeRenderer(gl, config), gpuTimer = RenderPaint.noFrameTimer() })` で 2D と 3D の描き手を同じ gl に載せる【確】。

デスクトップ（LwjglLayer）との違い【確のもの / 推のもの】:
| 違い | 確/推 | 中身 |
|---|---|---|
| GPU タイマー | 確 | ブラウザは `gpuTimer = RenderPaint.noFrameTimer()`（GPU の時間を測らない）。診断の GPU 欄は None |
| mip の作り方 | 確 | `prefersGpuMipmap()` が真 → 段 0 だけ上げて `generateMipmap`。デスクトップは CPU の `Mip.build`（絵が CPU の描き手とそろう）。GPU の平均は 8 bit のままで sRGB の曲線で平均する CPU とわずかに違う |
| alpha-to-one | 確 | WebGL2 に無く、cutout は discard（縁がなめらかでない） |
| 画像の解読 | 確 | `MessageDigest`・`HexFormat` が TeaVM に無く足した。画像の解読はブラウザで常に Err（plans/engine-browser-3d.md の記述・WebLayer:313 を読んでいない【推】） |
| RGBA32F の読み | 確 | LINEAR で読むと不完全なテクスチャ → NEAREST。データテクスチャが全部 NEAREST |
| 影の無い場面の uShadowMap | 確 | unit 0 のままだと feedback loop で draw が止まる → blank 1×1 の unit 9 を貼る（Shadow.flix:229-232） |
| 時計・入力・音・完了通知 | 確 | `fge.web`（JS を閉じ込めた Java）経由。ゲームのループは止まる形のまま、`presentFrame` で requestAnimationFrame まで待つ間だけブラウザへ手を返す。tickRate 60 に間引く |
| 起動 | 確 | `bootConfigOf`（縦持ちの design）・`handleLoadProgress`・遅延テクスチャ(`Deferred`)・`pendingTextures` |
| プリロード | 確 | `Preload.upload`（`App.withPreload3d`）は同じ。ブラウザ向けの特別扱いは WebLayer に無い |
| 頂点の uniform location | 確 | WebGl2.java は int と WebGLUniformLocation の表を持ち -1 を null に写す（GlContext.java 冒頭） |
| GL の誤り | 確(計画書) | WebGL2 の誤りは黙って進む・`getError` を読む所が無い（plans/engine-browser-3d.md） |

WebGPU 版を足す時の入口は、`withProject3d` と同じく**もう 1 本の入口**（例 withProject3dGpu）が自然で、`RenderPaint.create` に渡す `scene3d` と GL の `gl` を同じ canvas 上で持てないので、2D の描き手（RenderPaint 全体）も WebGPU 版が要る【推】。

## 7. 移しやすさの評価

| 部分 | そのまま | 手直し | 書き直し |
|---|---|---|---|
| ScenePlan・Batch・Counts・Preload の予算・Material の鍵とキャッシュ・Light の LightData 作り・Scene3d の純粋な関数 | ◎ | | |
| Renderer の形（prepare/endFrame/takeCounts/readsTexture/preload） | ○ | `Dest#framebuffer`・`RegisteredTexture#texId` を不透明な型に | |
| Render3d.drawScene/drawBatch/uploadMesh/DataTexture/Instancing/JointTexture/Shadow の GL 呼び出し | | | ◎（pipeline・bind group・buffer・render pass へ） |
| GLSL（Render3dGlsl 579 行 + ShaderGen の GLSL 部品） | | Codegen の式は出口を足す | 手書きの GLSL 全部を WGSL へ |
| 2D との pass の分け（Frame.flix の emitMerged が 2D の run の途中で draw を呼ぶ） | | | 2D も WebGPU 化し pass 分割 |
| gl-parity（GL と CPU を 0 px で比べる門） | | | WebGPU 用の第 3 の比較が要る（`RecordingGl`/GlCallLog のような記録も GL 専用） |

得（見込み）: (1) CPU 側の呼び出し回数の減（uniform・bind の跨ぎ。S24 の cpu 20.7 ms の一部）、(2) storage buffer による instance 上限・DataTexture 一式の削除と、StaticGroup の持ち越しがやりやすい、(3) compute による間引き・indirect draw（見た目を変えない縛りと衝突）、(4) 描き先の形式の機能判定の統一。
苦しい所: (1) 2D の run の途中に 3D が入る構造と 1 つの canvas に 1 context、(2) 2D のレンダーターゲット・絵の登録簿との共有、(3) GL と CPU が同じ式を使う決まりに 3 つ目が加わる、(4) 材質ごとに別プログラム（数十〜数百）の WGSL 生成と pipeline の数（blend・cull・depth・format の組で pipeline が増える）。
