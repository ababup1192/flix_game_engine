# 対応表 — 3D の場面と post process

3D の場面（`Scene3d`）の光・空・かすみ・material と、post process（HDR・tonemap・bloom・被写界深度・FXAA）の値を決める時に引く。
2D の部品は [reference.md](reference.md)。API の細かい決まりは engine の `docs/scene3d.md` と `docs/shader-doc.md` が正で、ここは「どの値から始めるか」と「どの API を使うか」の入口。

## 目次

- 値の単位と色の扱い
- 見た目の名前 → 値の組（光と空気 / post process）
- したい事 → API
- post process の Pass の並びの手本
- 途中の Pass の絵を見る
- 見た目が悪い時の切り分け
- 出どころ

## 値の単位と色の扱い

- **色は画面の値（sRGB の hex）で書く。** 3D の描き手は中だけ線形の量へ戻して光を足し、出口で 1 回だけ画面の値へ戻す。
  光の `intensity`・`range`・`hemisphere`・lightmap の `intensity`・`Scene3d.withEmissionIntensity` は線形の量のまま掛かる
  （画面では約 1/2.2 乗で見える。同じ値なら `ambient` より `hemisphere` の方が明るい）。
- **長さは world の単位。** 下の表は 1 = 1 m の場面（かすみの near と far・光の `range`・影の `distance` と太陽の影の `bias`）。
- **露出は stop**（2 の stops 乗を掛ける）。`PostProcess.defaultExposure()` は +0.4 だが、HDR の Pass は画面の値のまま tonemap するので
  +0.4 では中間の明るさが持ち上がって白っぽくなる（0.3 → 0.55）。`docs/shader-doc.md` の目安は −0.6 前後（0.3 → 0.3）。
  **下の表の場面は −0.6 〜 +0.1 で、+0.4 を使う場面は 1 つも無い。** 白の点はどの場面も 4.0（`PostProcess.defaultWhitePoint()` と同じ）。
- **bloom のしきいは HDR の目盛り**（1 を超える所が光る所）。HDR でない 8bit の Pass で組む時は 0..1 の目盛りになる。
- bloom とぼかしの半径は画面の高さに対する割合（uv）。taps は読む点の数（`ShaderDoc.blurTaps`・64 まで）。
- 1 を超える明るさ（光る看板・炎・窓）は Spec の emission に書かず `Scene3d.withEmissionIntensity(k, m)` で渡す。

## 見た目の名前 → 値の組

**ここから選んで写して終わりにしない。** 近い行の値から始めて 1 枚描き出し、自分の場面の色 3 つ（[visual-dict.md](../visual-dict.md) の手順 2）に合わせて動かす。
空欄（—）はその場面が使っていない物。値は全部、実際に動いている場面から写した（下の「出どころ」）。

### 光と空気

| 見た目の名前 | 主な光（色・強さ・向き） | ambient / hemisphere | 点光源とスポット | 空（天頂 / 地平 / 地面） | かすみ（色・near〜far） | 影 |
|---|---|---|---|---|---|---|
| 夕暮れの屋外（小さな町を斜め上から） | 夕日 `#ffb27a`・2.6・高さ 22°→沈むと 6°（遠くに置いたスポット・画角 30°・range 600） | `#77708a` / 0。空からの光は lightmap（倍率 2 × 0.5）と tint `#f3e6ea` | 街灯 `#ffbf73`・1.5・range 6。窓の emission の倍率 7・街灯の硝子 6 | `#465a9c` / `#f2a777` / `#4a3d52` | — | スポットの影: mapSize 4096・bias 0.0006・pcfRadius 2・strength 0.8 |
| 夜の屋外（同じ町・月と街灯） | 月 `#a9bcff`・0.26・高さ 56° | `#202847` / 0。lightmap（2 × 0.15）と tint `#9fb0f0` | 上と同じ街灯 | `#070b24` / `#27315f` / `#0c0e1c` | — | 上と同じ（影は夕日と月の強い方 1 本だけ） |
| 晴れた昼の都市の俯瞰 | 太陽 `#fff2d9`・1.8・向き (−0.55, −0.62, −0.45)（`directionalLight`） | `#5c5c5c` / 0.32 | — | `#3b78c8` / `#c4d9ec` / `#5b6a5f` | 地平と同じ `#c4d9ec`・3500〜16000（もう 1 つの都市は 2600〜12000） | 太陽の影: distance 250・bias 0.3・normalBias 2.5（もう 1 つの都市は distance 600・ほかは既定） |
| 夕方の浜（歩く目線） | 太陽 `#ffcfa8`・1.5・高さ 16°（遠くに置いた影つきのスポット） | `#8f94aa` / 0.2 | — | `#1f4f9e` / `#ffb06a` / `#7a6252`（curve 0.6） | `#f4a877`・60〜420（見晴らしの良い高台は 120〜760） | スポットの影: mapSize 2048・pcfRadius 2・strength 0.9 |
| 夕方の森 | 同じ太陽 × 0.85 | `#8a9484` / 0.22 | 手の灯り × 0.1 | `#4a7aa0` / `#f2c594` / `#4a4a3a` | `#d6b48a`・22〜170 | 同上 |
| 洞窟（手の灯りだけ） | —（太陽 0） | `#4a5462` / 0.02 | 手の灯り `#fff0e0`・0.9 × 1.2・range 9（目の右上へずらす） | `#26303a` / `#31404a` / `#1d242a` | `#141a20`・10〜70 | — |
| 夜の集合住宅の外廊下（懐中電灯） | ベイクした光（lightmap の倍率 2.6・光る管の emission の倍率 55） | `#0c0e16` / 0 | 懐中電灯のスポット `#fff3e2`・1.1・range 11・円錐 55°・内側 18°・影なし | `#030516` / `#3a2a2e` / かすみの色（curve 0.25） | `#14151d`・6〜60 | —（ベイクに入っている） |
| 金属の通路（ベイクした光と映り込み） | ベイクした光（lightmap の倍率 2.2・光る筋の強さ 6.0）。環境マップの強さ 4.0（箱の補正つき） | `#2e3640` / 0.35 | 弾・拾う物・非常灯の弱い点光源 | —（Pass をかすみの色で Clear） | `#090c10`・6〜48 | — |
| 地下の階（月の影・たいまつ・水） | 月 `#a6bfff`・0.22・高さ 62°（`directionalLight`） | `#1a1f30` / 0 | たいまつ `#ff4d14`・1.0・range 5 / 手の灯り `#ffb066`・6.5・range 5.5 / 水の光 `#73ccff`・1.2・range 4 | — | — | 太陽の影: strength 0.55 |
| たいまつの部屋（一人称） | 影つきのスポット（たいまつの色 `#ff9a48`） | `#3a3058` + たいまつの色 × 0.1 / 0.28 | 壁のたいまつと手の灯り（8 本に収める） | — | — | スポットの影: mapSize 1024・bias 0.002・pcfRadius 1・strength 0.9 |
| 礼拝堂の昼（高い窓からの光） | 窓からの影つきのスポット（白に青を 3 割） | `#2a3040` + 灯りの色 × 0.1 / 0.16 | 窓の前の床に色の光（影なしのスポット） | — | — | 同じ・strength 0.85 |

### post process

読んだ場面の tonemap は全部 `PostProcess.Tonemap.AcesFitted`・白の点 4.0。bloom の縮め方はどれも「明るい所 0.5 倍 → ぼかし 2 回 0.25 倍」。

| 見た目の名前 | 露出 | bloom（しきい / knee / 強さ / 半径 / taps） | ビネット | 彩度・色の仕上げ | MSAA |
|---|---|---|---|---|---|
| 夕暮れ〜夜の屋外（小さな町） | 0.0 | 0.95 / 0.7 / 0.9 / 0.045 / 12 | 0.34 | 彩度 +0.06。被写界深度: ぼかし 0.004・帯 0.25・ぼけ切るまで 0.5 | 4 |
| 晴れた昼の都市の俯瞰 | 0.0 | 1.0 / 0.6 / 0.25 / 0.03 / 12 | 0.18 | 彩度 +0.12 | 4 |
| 夕方の浜・森・洞窟（歩く目線） | 0.0（場所ごとに場面の明るさ × 1.0・洞窟 0.92） | 0.85 / 0.5 / 0.6 / 0.05 / 16 | 0.25 | — | 4 |
| 夜の集合住宅の外廊下 | −0.15 | 0.9 / 0.7 / 0.95 / 0.045 / 12 | 0.42 | 暗い所を `#0a1226` へ 0.4・底上げ 0.008・彩度 −0.05・フィルムの粒 0.02 | 4 |
| 金属の通路 | −0.3 | 2.0 / 0.6 / 0.4 / 0.04 / 12 | 0.35 | フィルムの粒 0.015 | 4 |
| 地下の階 | +0.1 | 0.9 / 0.6 / 0.45 / 0.035 / 12 | 0.45 | 彩度 +0.18 | 4 |
| たいまつの部屋（一人称） | −0.6 | 1.0 / 0.6 / 0.8 / 0.05 / 12 | 0.45 | 暗い所を `#1c1a3a` へ 0.35・明るい所を `#ffc078` の向きへ 0.12・底上げ 0.02・彩度 +0.1 | なし（場面の Pass は design の大きさの HDR） |
| 礼拝堂の昼 | −0.6 | 1.2 / 0.6 / 0.35 / 0.05 / 12 | 0.35 | 暗い所を `#1a2238` へ 0.35・明るい所を `#fff2dc` の向きへ 0.08 | なし |
| 溶岩の部屋 | −0.6 | 1.0 / 0.6 / 0.75 / 0.05 / 12 | 0.5 | 暗い所を `#2a0e18` へ 0.35・明るい所を `#ff9040` の向きへ 0.2・遠くを `#3a1410` へ 0.35 | なし |
| ドット絵の夜の村（HDR なし・tonemap なし） | — | 0.65 / 0.25 / 1.0 / 0.035 / 24（0..1 の目盛り） | 0.4 | 暗い所を `#4a4690` へ 0.12・明るい所を `#ffb068` の向きへ 0.15・底上げ 0.05・彩度 +0.12 | なし |
| ドット絵の昼の港（同じ並び） | — | 0.82 / 0.12 / 0.5 / 0.035 / 24 | 0.25 | 暗い所を `#4a6aa8` へ 0.1・明るい所を `#ffe0a8` の向きへ 0.08・底上げ 0.06・彩度 +0.1 | なし |

表から読める事: 昼ほど bloom の強さを下げる（0.25〜0.5）・夜と灯りの場面は上げる（0.8〜1.0）。光る物が多い場面はしきいを上げる（2.0）。
屋外は地平の色とかすみの色をそろえている。太陽を足した場面は ambient を灰色まで下げている（`Scene3d.scene()` の ambient は白）。

## したい事 → API

名前は `docs/api-digest/` で確かめた物だけ。型と引数は `make api Q=<名前>`。

| したい事 | API | よくある間違い |
|---|---|---|
| 3D の場面を 2D の画面に置く | `Render.scene3d(at, { .. \| Scene3d.scene(camera, size) })` | 同じ z では ShaderDoc の面と 3D の場面が必ず手前（並べた順は使われない）。上に重ねる物は z を大きくする |
| 物を置く | `Scene3d.meshInstance(mesh, world)` → `withMaterial` / `withTint` / `withPose` | `instances` は `List`。毎コマ `++` で長い列を組むと重い（作り置きの列を後ろへつなぐ） |
| material の色・絵 | `Scene3d.material(spec)`・絵 1 枚は `Scene3d.texturedMaterial(名前, filter)` | 絵は場面の `textures` にも渡す（渡さないと黒い）。1 つの material が読める絵は `Scene3d.maxMaterialTextures()` まで |
| 金属と粗さ（PBR） | `Scene3d.withMetallicRoughness(metallic, roughness, m)`・絵は `withMetallicRoughnessTexture` | 付けない material はマットのまま。glb から読むのは `Gltf.loadTexturedPbrUsing` だけ |
| 法線マップ | `Scene3d.withNormalMap({ texture, strength }, m)` | uv つきの形にだけ当たる。OpenGL 流（緑が絵の上） |
| 切り抜き・半透明・両面 | `Scene3d.withCutout` / `withAlphaBlend` / `withDoubleSided` | 半透明の物は影を落とさず、奥行きの Pass に描かれない。1 つの物の中の三角形は並べ替えない |
| 光る面 | `Scene3d.withEmission(shade, m)` + `withEmissionIntensity(k, m)` | Spec の emission に 1 を超える色を書かない |
| 毎コマ変わる数を material へ | ShaderDoc の `Param` + `Scene3d.withParams` | 木の `Const` に動く値を書くと毎コマ program を作り直す |
| 点光源 | `{ position, color, intensity, range }` を `pointLights` へ | 計算するのは目に近い 8 本（`Scene3d.maxPointLights()`）。全部入れてよく、ゲームで選び直さない |
| スポット | `Scene3d.spotLight(position, target, fovY)` を `{ .. \| }` で替える | 2 本まで（`Scene3d.maxSpotLights()`）。縁の輪は `innerFovY` でぼかす |
| 太陽 | `Scene3d.directionalLight(direction)` を `directionalLight = Some(..)` | 1 つまで。足したら ambient を下げる。点光源を遠くに置いて代わりにしない |
| 落とした光の数を見る | `ctx#diagnostics` の `scene3dCounts#droppedPointLights` / `droppedSpotLights`・画面なしは `Scene3d.droppedLightsOf` | 8 番目と 9 番目の境で遠い光が点いたり消えたりする。離れた小さな光はまとめる |
| 影 | スポットは `shadow = Some({ mapSize, bias, pcfRadius, strength })`・太陽は `Scene3d.directionalShadow()` | 影を落とすのはスポット 1 本 + 太陽 1 つ。太陽の `bias` は world の m。ビルボードは影を受けない |
| ambient と hemisphere・toon | `environment = { ambient, hemisphere, toonSteps, fog, background }`（`Scene3d.Environment3d`） | `Scene3d.scene()` の ambient は白 |
| かすみ | `fog = Some({ color, near, far })`（`Scene3d.DistanceFog`） | 空にはかすみが掛からない。地平の色とそろえると継ぎ目が消える |
| 空 | `sky = Some(Scene3d.gradientSky(天頂, 地平, 地面))`・寄り方は `Scene3d.withSkyCurve` | 2D の面を下に置いて地平の高さを手で計算しない。`sky` があると `background` は使われない |
| 周りの景色を映す | `Scene3d.environmentMap(絵)` + `withEnvironmentIntensity` / `withEnvironmentBox` | 映るのは金属と粗さを持つ material だけ。室内は箱の補正を付ける |
| ベイクした光 | `Scene3d.withLightmap({ intensity = .. \| Scene3d.lightmap(名前) }, instance)` | 骨なしの物だけ。lightmap の面に太陽の拡散は足されない（engine の `docs/lightmap.md`） |
| 絵の板を 3D に立てる | `Scene3d.billboard(texture, regionRect, position, size)` + `withAnchor` / `withBillboardTint` / `unlit` | 炎や光る物は `unlit`。影は受けない |
| ドット絵と画素をそろえる / 窓の画素で描く | 場面の `resolution = Scene3d.Resolution.Design` / `Native` | Design の場面に MSAA は掛からない |
| HDR の Pass | `RenderTarget.withHdr(RenderTarget.windowDescriptor())` を `targets` へ（`App.withPassPlan`） | 透明から始める Pass（`LoadOp.ClearTransparent`）の中の 3D は CPU の描き出しに出ない。`Clear(色)` で始める |
| tonemap | `PostProcess.tonemapped(曲線, 露出, 白の点, spec)`・仕上げ付きは `tonemappedWith` | 1 で切って白飛びを隠さない。`pp_` で始まる名前は予約 |
| bloom | 下の手本（明るい所を抜く → 縮めてぼかす → 足す） | 全面で `TexBlur` を読まない。縮んだ Pass でぼかして `Sampler`（Linear）で読む |
| 被写界深度 | 同じ場面を `output = Scene3d.Output.Depth({ near, range })` で奥行きの Pass に描く | 場面を 2 回組む事になる。奥行きの Pass では空は白（一番奥） |
| 細い物の欠け | `RenderTarget.withMsaa(4, ..)` を場面の Pass に | CPU の描き出しには出ない（描き出した絵の縁は固いまま） |
| 縁をならす | `PostProcess.fxaaSpec("post")` | 読む Pass は窓の画素・scale 1・tonemap 済みの Rgba8Unorm。縮んだ Pass では縁がずれる |
| HUD | `App.withHudView` か、FXAA の面より上の層 | HUD と UI は tonemap しない（本編の面だけを包む） |

## post process の Pass の並びの手本

HDR の場面 → 明るい所を抜く → 縮めてぼかす（2 回）→ 足して tonemap → FXAA。`Look` はゲームの Doc の値（上の表の欄）。
**型検査を通していない見本。名前は `docs/api-digest/` で確かめた。**

```flix
mod PostView {
    use fge::{Color, PostProcess, Render, RenderTarget, ShaderDoc, Vec2}
    use fge::ShaderDoc.{BinOp, Field, Out, Shade, TexChan}

    def k(v: Float64): Field = Field.Const(v)
    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })
    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })
    def linear(f: Field): Field = Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = f })
    def rgb(name: String, bindings: List[(String, Field)], f: TexChan -> Field): ShaderDoc.Spec =
        { name = name, cycleRate = 0.0, bindings = bindings,
          out = Out.Fill({ shade = Shade.Rgb({ r = f(TexChan.R), g = f(TexChan.G), b = f(TexChan.B) }), alpha = k(1.0) }) }
    def fill(size: Vec2.Vec2, spec: ShaderDoc.Spec): Render.PlacedItem =
        Render.shaderFill(spec, { position = Vec2.zero(), size = size }, 0.0, 0)

    def bright(look: Look): ShaderDoc.Spec =
        let read = c -> linear(Field.Tex({ name = "scene", chan = c }));
        let luma = PostProcess.luma709(read(TexChan.R), read(TexChan.G), read(TexChan.B));
        let over = Field.Smoothstep({ lo = look#bloomThreshold, hi = look#bloomThreshold + Float64.max(0.01, look#bloomKnee), of = luma });
        rgb("post_bright", ("over", over) :: Nil, c -> mul(read(c), Field.Ref("over")))

    def blur(aspect: Float64, src: String, radius: Float64, taps: Int32): ShaderDoc.Spec =
        rgb("post_blur_${src}", Nil, c -> linear(Field.TexBlur({ name = src, chan = c, radius = { x = radius / aspect, y = radius },
                                                              taps = ShaderDoc.blurTaps(taps), amount = k(1.0) })))

    def main(look: Look): ShaderDoc.Spec =
        let bloom = c -> mul(k(look#bloomStrength), linear(Field.Tex({ name = "bloomB", chan = c })));
        PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, look#exposure, look#whitePoint,
                               rgb("post_main", Nil, c -> add(Field.Tex({ name = "scene", chan = c }), bloom(c))))

    pub def chain(size: Vec2.Vec2, look: Look, clear: Color, scene: List[Render.PlacedItem]): Render.PassPlan =
        let black = RenderTarget.LoadOp.Clear(Color.rgb(0.0, 0.0, 0.0));
        let aspect = size#x / size#y;
        let small = s -> RenderTarget.withHdr({ scale = s | RenderTarget.defaultDescriptor() });
        let pass = (name, spec) -> { name = name, clear = black, items = fill(size, spec) :: Nil };
        { targets = Map#{ "scene" => RenderTarget.withMsaa(look#msaaSamples, RenderTarget.withHdr(RenderTarget.windowDescriptor())),
                          "bright" => small(0.5), "bloomA" => small(0.25), "bloomB" => small(0.25),
                          "post" => RenderTarget.windowDescriptor() }
          | Render.passPlan({ name = "scene", clear = RenderTarget.LoadOp.Clear(clear), items = scene }
                :: pass("bright", bright(look)) :: pass("bloomA", blur(aspect, "bright", look#bloomRadius, look#bloomTaps))
                :: pass("bloomB", blur(aspect, "bloomA", look#bloomRadius * 0.5, look#bloomTaps)) :: pass("post", main(look)) :: Nil) }

    pub def screenFill(size: Vec2.Vec2): Render.PlacedItem = fill(size, PostProcess.fxaaSpec("post"))
}
```

使い方: `App.withPassPlan` に `chain(..)` を渡し、View は `screenFill(size)` を 1 枚置く。描き出しは同じ計画を `Render.passSpecsOf` に通して
`HeadlessRender.renderPngWithPasses` へ渡す（`issues` が空でなければ Pass の読む順が違う）。

| Pass | 大きさと形式 | 決め方 |
|---|---|---|
| `scene` | 窓の画素・Rgba16Float・MSAA 4 | 3D はここだけで描く。ドット絵と画素をそろえる場面は design の大きさ（`defaultDescriptor`）で MSAA なし |
| `bright` | 0.5 倍・Rgba16Float | 縮んだ Pass へ Linear で読むと 2 × 2 の平均になる |
| `bloomA`・`bloomB` | 0.25 倍・Rgba16Float | 2 回目は半径を半分に。480 × 270 の全面は 129,600 画素・0.5 倍は 32,400・0.25 倍は 8,160 で、ぼかしの重さは画素 × taps |
| `post` | 窓の画素・Rgba8Unorm・scale 1 | FXAA が 1 テクセル = 1 画素を前提にする。FXAA の読みは 27 回 |

- 同じ名前・同じ補間・同じ半径と taps の読みは、r・g・b の 3 本に書いても 1 回だけ読む。
- **Spec は読み込みの時に 1 回組んで持つ。** View で毎コマ組むと、描き手が毎コマ木の中身を比べ直す。コマごとに変わる数（ピント・明るさの倍率）は `Field.Param` + `Render.withShaderParams` で渡す。
- 彩度・暗い所の色・フィルムの粒は 0..1 を前提にするので、`PostProcess.tonemappedWith` の `after` の中（tonemap の後）で掛ける。ビネットは tonemap の前の色に掛けている。
- MSAA の置き場は標本の数の倍（1920 × 1080 の Rgba16Float で 4 標本なら色 約 63 MB・深度 約 32 MB）。

### 被写界深度を足す時の差分（型検査を通していない）

```flix
// chain の passes に足す（"scene" の後ろ）。depthScene = 同じ場面を output = Scene3d.Output.Depth({ near, range }) で組んだ物
:: { name = "depth", clear = RenderTarget.LoadOp.Clear(Color.rgb(1.0, 1.0, 1.0)), items = depthScene }
:: pass("soft", blur(aspect, "scene", look#tiltBlur, look#tiltTaps))
// targets に足す: "depth" => small(0.5), "soft" => small(0.5)
// main の中: ピントの奥行き（灰色の 0.5）からの離れ具合で、くっきりした場面とぼかした場面を混ぜる。bindings に ("tilt", tilt) を置く
let depth = linear(Field.Tex({ name = "depth", chan = TexChan.R }));
let away = mul(k(2.0), Field.Un({ op = ShaderDoc.UnOp.Abs, of = add(depth, k(-0.5)) }));
let tilt = Field.Smoothstep({ lo = look#dofBand, hi = look#dofBand + look#dofSoft, of = away });
let sharp = c -> Field.Blend({ a = Field.Tex({ name = "scene", chan = c }), b = linear(Field.Tex({ name = "soft", chan = c })), by = Field.Ref("tilt") });
```

ピントを合わせたい距離が灰色の 0.5 になるよう `near` と `range` を決める。ぼかした場面は 0.5 倍の Pass に 1 回だけ作る（窓の画素ごとに何十回も場面を読まない）。

## 途中の Pass の絵を見る

bloom の出方がおかしい・暗い・白い時は、最後の 1 枚だけ見ても原因が分からない。**Pass を 1 枚ずつ描き出して、どこから崩れたかを見る。**

```flix
// 型検査を通していない見本。specs = Render.passSpecsOf(texInfo, plan)#specs（宣言の順）
let images = specs |> List.foldLeft((done, p) -> Map.insert(p#name, HeadlessRender.renderPassImageWith(cfg, done, p, None), done), Map.empty());
Map.get("bright", images) |> Option.forEach(img -> Filmstrip.renderFrame(SoftRaster.toArgbImage(img), "debug/pass_bright.png"))
```

- 前の Pass を読まない Pass（`scene`・`depth`）だけなら `HeadlessRender.renderPassImage(cfg, p, None)` で足りる。全部まとめては `HeadlessRender.passImagesOf`。
- `SoftRaster.toArgbImage` は HDR の絵を 0..1 に切って 8bit にする。**`scene` の絵で真っ白な所が、tonemap の前に 1 を超えている所**。
- 見る順: `scene`（光と material）→ `bright`（何が光る物として残ったか）→ `bloomB`（にじみの広さ）→ `post`（露出と色の仕上げ）。
- **奥行き**: 場面の `output` を `Scene3d.Output.Depth({ near, range })` にする（near で黒・near + range で白・空は白・半透明の物は出ない）。
- **光だけ・material だけ**を出す API は無い。回り道（試していない）: material だけ = 光を全部外し（`pointLights`・`spotLights` を空・`directionalLight = None`）、
  ambient を白・hemisphere 0・かすみなしで描く。光だけ = 全部の物を白い 1 色の material に差し替えて描く。
- MSAA は CPU の描き出しに出ない。縁は窓で確かめる（FXAA は描き出しにも出る）。出なかった指定は `SoftRaster.dropped` に入る。

## 見た目が悪い時の切り分け

| 見え方 | まず疑う所 | 直し方 |
|---|---|---|
| 全体が白っぽい・中間の色が浅い | 露出が既定の +0.4 のまま / 太陽を足したのに ambient が白のまま | 露出を −0.6 前後から始める。ambient を灰色へ下げる |
| 明るい所が真っ白で段差が無い | 場面の Pass が HDR でない・1 で切っている | `RenderTarget.withHdr` の Pass + `PostProcess.tonemapped`。光る物は `withEmissionIntensity` |
| 暗い所が黒くつぶれる | ambient と hemisphere が低い | ambient を上げる（灯りの少ない夜の場面でも `#1a1f30`〜`#202847`）・hemisphere を足す。仕上げで底上げ（0.008〜0.06） |
| 影に縞・面にまだら | bias と影の地図の粗さ | 太陽は `bias`（world の m。既定 0.05・広い都市で 0.3）と `normalBias`、`mapSize` を上げ `pcfRadius` で縁をならす |
| 影の縁が歩くとちらつく | 光の位置か向きが毎コマ動いている | 光の中心を粗い刻み（4 m など）に丸める。太陽の向きを毎コマ変えない |
| 細い物が欠ける・縁がぎざぎざ | MSAA が場面の Pass に無い / FXAA の前提が外れている | 場面の Pass に `withMsaa(4, ..)`。FXAA は窓の画素・scale 1・tonemap 済みの Pass を読ませる |
| bloom がにじみすぎる・何でも光る | しきいが低い・強さが高い | `bright` の絵を出して残っている物を見る。しきいを上げ（0.85〜2.0）、強さを下げる（昼 0.25〜0.5） |
| 面が黒い・絵が出ない | Pass や絵の名前が無い・後ろの Pass を読んでいる・絵を `textures` に渡していない | 1 回だけ出る知らせを読む。`Render.passSpecsOf` の `issues` を出す |
| 遠くの物と空の境が見える | かすみの色と地平の色が違う | かすみの色を空の地平の色にそろえる |
| 描き出しにだけ 3D が出ない | 透明から始める Pass の中に 3D がある | Pass を `LoadOp.Clear(色)` で始める |

## 出どころ

値は、実際に動いている 9 つの場面の look の Doc（JSON）と、場面を組む View・post process の View から写した（2026-11 時点）。

- 夕暮れから夜へ変わる小さな町を斜め上から見る場面（夕暮れと夜の 2 行・被写界深度の差分）
- 実在の都市の建物を俯瞰する場面 2 つ（かすみの距離と影の距離が違う）
- 夕方の浜から森・洞窟・遺跡へ歩く場面（場所ごとの空気を前後でなめらかにつなぐ。Spec を読み込みで 1 回組む形）
- 夜の集合住宅を懐中電灯で歩く場面（ベイクした光）
- 金属の通路を一人称で進む場面（ベイクした光・環境マップ・金属と粗さ）
- 地下の階を見下ろす場面（月の影・たいまつ・水面）
- 一人称の部屋 3 種（たいまつ・礼拝堂・溶岩）。光の届く距離はこの場面だけの単位なので表に入れていない
- ドット絵の村と港に Pass の後処理を掛けた場面（HDR と tonemap を使わない並び）

分かっている穴は `plans/webgpu/analysis-render-structure.md`（色 1 枚しか後の Pass へ渡せない・光だけの絵が出せない・場面を 2 回組む）。
