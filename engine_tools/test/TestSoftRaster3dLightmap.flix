// SoftRaster3d の lightmap（ベイクした光）を、ファイルの頭の光の式から導いた値で固定する。
//   lightmap を付けた物は環境光と hemisphere を足さない・点光源 1 本の分だけ明るくなる・
//   Srgb で intensity 1 の baked は読んだ値と同じ・s = 0.5 で intensity 2 の baked ≒ 0.686・Linear は読んだ値をそのまま線形の光にする・
//   toonSteps はベイクした光と動く光を足してから丸める・縮めて貼った lightmap はその maxLevels（既定 4・小さくした 2）の段までしか読まない・
//   使わない組み合わせ（骨つき・2 本目の uv 無し・材質無し）は今の式で描き、1 回知らせる・
//   名前が場面の textures に無い絵は 0 で読み、「lightmap の絵」として名前ごとに 1 回知らせる。
// 場面はどれも 8×8（design・倍率 1）。カメラは原点で +Z を向き、縦の画角 90 度。板は z = 2 で画面いっぱい（x y −2..2）。
mod SoftRaster3d.TestLightmap {
    import java.awt.image.BufferedImage
    import java.io.{ByteArrayOutputStream, PrintStream}
    import java.lang.System

    def white(): Color = { r = 1.0, g = 1.0, b = 1.0 }
    def black(): Color = { r = 0.0, g = 0.0, b = 0.0 }

    def okOf(r: Result[String, a]): a = match r {
        case Ok(v)  => v
        case Err(e) => bug!(e)
    }

    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 }

    /// 環境光が白の場面。
    def sceneOf(textures: List[Texture3d.Texture3d], instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        { instances = instances, textures = textures | Scene3d.scene(camera(), { x = 8.0, y = 8.0 }) }

    def render(scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let req: SoftRaster.RasterReq =
            { drawables = Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1, background = black(),
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true,
              scenes = { at = Vec2.zero(), clip = None, scene = scene } :: Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map.empty())

    /// render と、描く間に stderr へ出た字。
    def renderCaptured(scene: Scene3d.Scene3dCmd): (BufferedImage, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let img = render(scene);
        System.setErr(old);
        (img, buf.toString())

    def pixel(img: BufferedImage, x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO = channels(img.getRGB(x, y))

    def pixels(img: BufferedImage): List[Int32] \ IO = List.range(0, 64) |> List.map(k -> img.getRGB(Int32.remainder(k, 8), k / 8))

    /// text の中で key を含む行の数。
    def linesWith(key: String, text: String): Int32 = String.lines(text) |> List.count(String.contains(substr = key))

    /// 全部の画素が灰色 v（0..255）の 2 × 2 の絵。
    def grayMap(v: Int32): Texture3d.Texture3d =
        let argb = Int32.bitwiseOr(-16777216, v * 65536 + v * 256 + v);
        okOf(Texture3d.fromArgb(2, 2, Vector#{ argb, argb, argb, argb }))

    def whiteMaterial(): Scene3d.Material3d =
        Scene3d.material({ name = "lm", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(white()), alpha = ShaderDoc.Field.Const(1.0) }) })

    /// z = 2 の板（x y −2..2）の形。uv は左上の角が (0, 0)・右下の角が (1, 1)。withUv2 なら 2 本目の uv も同じ値で付ける。
    def plateMesh(withUv2: Bool): Mesh3d.Mesh3d =
        let mesh = okOf(Mesh3d.fromTexturedPolygons(
            { points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(2.0, 2.0, 2.0) :: Vec3.v3(2.0, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
              uvs = { x = 0.0, y = 0.0 } :: { x = 1.0, y = 0.0 } :: { x = 1.0, y = 1.0 } :: { x = 0.0, y = 1.0 } :: Nil,
              color = white() } :: Nil));
        if (withUv2) okOf(Mesh3d.withUvs2(Option.getWithDefault(Vector.empty(), Mesh3d.uvs(mesh)), mesh)) else mesh

    /// 白い材質の板（2 本目の uv つき）。
    def litPlate(): Scene3d.Instance3d = Scene3d.meshInstance(plateMesh(true), Mat4.identity()) |> Scene3d.withMaterial(whiteMaterial())

    /// 白い材質の板に、場面の絵 t の lightmap（colorSpace・intensity）を付けた物。
    def bakedPlate(t: Texture3d.Texture3d, colorSpace: Texture3d.ColorSpace, intensity: Float64): Scene3d.Instance3d =
        litPlate() |> Scene3d.withLightmap({ colorSpace = colorSpace, intensity = intensity | Scene3d.lightmap(Texture3d.name(t)) })

    /// (0, 0, 1) の白い点光源（intensity 0.5・range 4）だけを足した場面。
    def withPointLight(scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        { pointLights = { position = Vec3.v3(0.0, 0.0, 1.0), color = white(), intensity = 0.5, range = 4.0 } :: Nil | scene }

    def red(p: (Int32, Int32, Int32, Int32)): Int32 = let (_, r, _, _) = p; r

    // ── 環境光と hemisphere を足さない ──

    // 環境光が白・hemisphere 1 の場面で、ベイクした光が 0（黒い絵）の板は、動く光が無いので黒（足すと白になる）。
    // 板は真ん中を軸に 0.5 rad 上へ向けて、法線の y を正にする（hemisphere を足せば絵に出る向き）。
    @Test
    def testLightmapReplacesAmbientAndHemisphere(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let tilt = Mat4.mul(Mat4.translate(Vec3.v3(0.0, 0.0, 2.0)), Mat4.mul(Mat4.rotateX(0.5), Mat4.translate(Vec3.v3(0.0, 0.0, -2.0))));
        let plate = Scene3d.meshInstance(plateMesh(true), tilt) |> Scene3d.withMaterial(whiteMaterial())
            |> Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)));
        let base = sceneOf(t :: Nil, plate :: Nil);
        let img = render({ environment = { hemisphere = 1.0 | base#environment } | base });
        Assert.assertEq(expected = (255, 0, 0, 0), pixel(img, 4, 4))

    // 点光源 1 本を足すと、ベイクした光（灰 100）に、同じ光を環境光 0 の板に当てた分が線形の量どうしで足される
    // （画面の値の 8bit から戻した量どうしの和なので、丸めの ±2 の内）。
    @Test
    def testPointLightAddsOnTopOfBakedLight(): Unit \ {Assert, IO} =
        let t = grayMap(100);
        let baked = render(withPointLight(sceneOf(t :: Nil, bakedPlate(t, Texture3d.ColorSpace.Srgb, 1.0) :: Nil)));
        let dark = sceneOf(Nil, litPlate() :: Nil);
        let dynamicOnly = render(withPointLight({ environment = { ambient = black() | dark#environment } | dark }));
        let lin = (v: Int32) -> Texture3d.srgbToLinear(Int32.toFloat64(v) / 255.0);
        let sum = Texture3d.linearToSrgb(lin(100) + lin(red(pixel(dynamicOnly, 4, 4))));
        let (_, expected, _, _) = channels(SoftRaster.argbOfRgba(sum, sum, sum, 1.0));
        Assert.assertTrue(Int32.abs(red(pixel(baked, 4, 4)) - expected) <= 2)

    // ── baked の式 ──

    // Srgb・intensity 1 なら、baked を画面の値へ戻すと読んだ値 k / 255 と同じ（256 通り）。
    @Test
    def testSrgbIntensityOneKeepsReadValue(): Unit \ Assert =
        Assert.assertTrue(List.range(0, 256) |> List.forAll(k -> {
            let s = Int32.toFloat64(k) / 255.0;
            Float64.abs(Texture3d.linearToSrgb(bakedValue(true, 1.0, s)) - s) < 1.0e-9
        }))

    // Srgb・s = 0.5・intensity 2 の baked を画面の値へ戻すと linearToSrgb(0.2140 × 2) ≒ 0.686。
    @Test
    def testSrgbHalfWithIntensityTwoIsAbout0686(): Unit \ Assert =
        Assert.assertTrue(Float64.abs(Texture3d.linearToSrgb(bakedValue(true, 2.0, 0.5)) - 0.686) < 0.001)

    // Srgb の baked は線形の量（s = 0.5・intensity 2 → srgbToLinear(0.5) × 2）。
    @Test
    def testSrgbBakedIsLinearAmount(): Unit \ Assert =
        Assert.assertTrue(Float64.abs(bakedValue(true, 2.0, 0.5) - Texture3d.srgbToLinear(0.5) * 2.0) < 1.0e-12)

    /// 光の無い場面で lightmap から読んだ値 s が光の足し算に入る値（線形の量・toon なし）。
    def bakedValue(srgb: Bool, intensity: Float64, s: Float64): Float64 =
        let (r, _, _) = SoftRaster3dLight.lightmapLightAt(0, Vector.empty(), Vector.empty(), None, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
                                                    s, s, s, if (srgb) 1.0 else 0.0, intensity);
        r

    // toonSteps 2 で、ベイクした光 0.2 と点光源の分 0.1 × (1 − 1² / 4²)² ≒ 0.088 は、どちらも 1 つなら 0.25 未満で 0 に丸まるが、
    // 足してから丸めるので 0.288 → 0.5 になる（点光源は点の 1 手前・法線は光の向き）。
    @Test
    def testToonRoundsBakedPlusPointLightTogether(): Unit \ Assert =
        let env = { toonSteps = 2 | Scene3d.scene(camera(), { x = 8.0, y = 8.0 })#environment };
        let points = LightModel3d.packPointLights({ position = Vec3.v3(0.0, 0.0, 1.0), color = white(), intensity = 0.1, range = 4.0 } :: Nil);
        // Linear・intensity 1 なら baked は読んだ値のままなので、0.2 を渡すと baked が 0.2 になる。
        Assert.assertEq(expected = (0.5, 0.5, 0.5),
                        SoftRaster3dLight.lightmapLightAt(env#toonSteps, points, Vector.empty(), None, 0.0, 0.0, 2.0, 0.0, 0.0, -1.0,
                                                    0.2, 0.2, 0.2, 0.0, 1.0))

    // ── 段（mip）──
    // 256 × 256 の lightmap の左の 20 列だけが明るい（200・ほかは 40）。画面いっぱい（8 px）の板では 1 px が 32 texel で、
    // 画素 (0, 4)（2 本目の uv (0.0625, 0.5625)）は段の上限が無ければ lod 5（約 140）を読む。上限 4（Scene3d.lightmap の既定）なら
    // lod 3（約 160）、上限 2 なら lod 1（200）で、3 つとも違う値になる。

    def leftBandArgb(): Vector[Int32] =
        let gray = (v: Int32) -> Int32.bitwiseOr(-16777216, v * 65536 + v * 256 + v);
        Vector.range(0, 256 * 256) |> Vector.map(k -> if (Int32.remainder(k, 256) < 20) gray(200) else gray(40))

    /// 左の帯の lightmap（Srgb）を段の上限 maxLevels で板に貼った画素 (0, 4) と、Mip.build（SrgbCurve）の段 lod をその uv で読んだ値から出した画素。
    def bandPixelAndExpected(maxLevels: Int32, lod: Float64): ((Int32, Int32, Int32, Int32), (Int32, Int32, Int32, Int32)) \ IO =
        let argb = leftBandArgb();
        let t = okOf(Texture3d.fromArgb(256, 256, argb));
        let chain = List.toVector(Mip.build(Mip.Average.SrgbCurve, { width = 256, height = 256, pixels = argb }));
        let (r, g, b) = ShaderEval.sampleMipRgb(chain, { linear = true, repeat = false }, lod, 0.0625, 0.5625);
        let baked = (x: Float64) -> Texture3d.linearToSrgb(bakedValue(true, 1.0, x));
        let plate = litPlate() |> Scene3d.withLightmap({ maxLevels = maxLevels | Scene3d.lightmap(Texture3d.name(t)) });
        let img = render(sceneOf(t :: Nil, plate :: Nil));
        (pixel(img, 0, 4), channels(SoftRaster.argbOfRgba(baked(r), baked(g), baked(b), 1.0)))

    // 既定の上限（Scene3d.lightmapMaxLevels() = 4）で縮めて貼った lightmap は、Mip.build の段 3 を読む。
    @Test
    def testShrunkLightmapStopsAtDefaultMaxLevels(): Unit \ {Assert, IO} =
        let (actual, expected) = bandPixelAndExpected(Scene3d.lightmapMaxLevels(), 3.0);
        Assert.assertEq(expected = expected, actual)

    // maxLevels 2 の lightmap は、縮めて貼っても Mip.build の段 1 までしか読まない。
    @Test
    def testShrunkLightmapStopsAtItsOwnMaxLevels(): Unit \ {Assert, IO} =
        let (actual, expected) = bandPixelAndExpected(2, 1.0);
        Assert.assertEq(expected = expected, actual)

    // 上限の確かめが意味を持つ前提: 段 1・段 3・段 5 は、その画素で 3 つとも違う値。
    @Test
    def testBandLevelsDifferAtSampledPixel(): Unit \ Assert =
        let chain = List.toVector(Mip.build(Mip.Average.SrgbCurve, { width = 256, height = 256, pixels = leftBandArgb() }));
        let at = (lod: Float64) -> { let (r, _, _) = ShaderEval.sampleMipRgb(chain, { linear = true, repeat = false }, lod, 0.0625, 0.5625); r };
        Assert.assertEq(expected = 3, Set.size(List.toSet(at(1.0) :: at(3.0) :: at(5.0) :: Nil)))

    // 灰 128 の Srgb の lightmap を intensity 1 で貼ると、光の無い場面の画素は灰 128 のまま。
    @Test
    def testSrgbLightmapPixelKeepsReadValue(): Unit \ {Assert, IO} =
        let t = grayMap(128);
        let img = render(sceneOf(t :: Nil, bakedPlate(t, Texture3d.ColorSpace.Srgb, 1.0) :: Nil));
        Assert.assertEq(expected = (255, 128, 128, 128), pixel(img, 4, 4))

    // 灰 128 の Linear の lightmap は、128 / 255 を線形の光として linearToSrgb で画面の値へ戻した色。
    @Test
    def testLinearLightmapIsConvertedToScreenValue(): Unit \ {Assert, IO} =
        let t = grayMap(128);
        let v = Texture3d.linearToSrgb(128.0 / 255.0);
        let img = render(sceneOf(t :: Nil, bakedPlate(t, Texture3d.ColorSpace.Linear, 1.0) :: Nil));
        Assert.assertEq(expected = channels(SoftRaster.argbOfRgba(v, v, v, 1.0)), pixel(img, 4, 4))

    // ── 使わない組み合わせ ──

    // 2 本目の uv の無い板の lightmap は使わず、lightmap の無い同じ板と同じ画素で描く。
    @Test
    def testLightmapWithoutUv2DrawsLikePlain(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let plate = Scene3d.meshInstance(plateMesh(false), Mat4.identity()) |> Scene3d.withMaterial(whiteMaterial());
        let plain = render(sceneOf(t :: Nil, plate :: Nil));
        let (img, _) = renderCaptured(sceneOf(t :: Nil, Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)), plate) :: Nil));
        Assert.assertEq(expected = pixels(plain), pixels(img))

    // 2 本目の uv の無い板の lightmap は、使わないことを 1 回だけ知らせる。
    @Test
    def testLightmapWithoutUv2WarnsOnce(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let plate = Scene3d.meshInstance(plateMesh(false), Mat4.identity()) |> Scene3d.withMaterial(whiteMaterial());
        let (_, err) = renderCaptured(sceneOf(t :: Nil, Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)), plate) :: Nil));
        Assert.assertEq(expected = 1, linesWith("2 本目の uv が無い", err))

    // 材質の無い板（頂点の色）の lightmap は使わず、lightmap の無い同じ板と同じ画素で描く。
    @Test
    def testLightmapWithoutMaterialDrawsLikePlain(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let plate = Scene3d.meshInstance(plateMesh(true), Mat4.identity());
        let plain = render(sceneOf(t :: Nil, plate :: Nil));
        let (img, _) = renderCaptured(sceneOf(t :: Nil, Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)), plate) :: Nil));
        Assert.assertEq(expected = pixels(plain), pixels(img))

    // 材質の無い板の lightmap は、使わないことを 1 回だけ知らせる。
    @Test
    def testLightmapWithoutMaterialWarnsOnce(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let plate = Scene3d.meshInstance(plateMesh(true), Mat4.identity());
        let (_, err) = renderCaptured(sceneOf(t :: Nil, Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)), plate) :: Nil));
        Assert.assertEq(expected = 1, linesWith("材質が無い", err))

    /// 頂点 1 つ分の v を 4 頂点分に並べる。
    def eachOfFour(v: Vector[a]): Vector[a] = Vector.range(0, 4) |> Vector.flatMap(_ -> v)

    /// z = 2 の四角（x y −2..2）。4 頂点ともジョイント 0 に重み 1・2 本目の uv つき・白い材質。
    def skinnedPlate(): Scene3d.Instance3d =
        let mesh = okOf(Mesh3d.fromArrays({
            positions = Vector#{ -2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, -2.0, 2.0, -2.0, -2.0, 2.0 },
            normals = eachOfFour(Vector#{ 0.0, 0.0, -1.0 }), colors = eachOfFour(Vector#{ 1.0, 1.0, 1.0 }),
            indices = Vector#{ 0, 1, 2, 0, 2, 3 },
            skin = Some({ joints = eachOfFour(Vector#{ 0, 0, 0, 0 }), weights = eachOfFour(Vector#{ 1.0, 0.0, 0.0, 0.0 }) })
        })) |> Mesh3d.withUvs2(Vector#{ 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0 }) |> okOf;
        let rest = { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() };
        let skin = okOf(Skin3d.make({ names = Vector#{ "root" }, parents = Vector#{ -1 }, rest = Vector#{ rest },
                                      inverseBinds = None, rootTransform = Mat4.identity() }));
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withPose(Pose3d.compute(skin, Vector#{ rest })) |> Scene3d.withMaterial(whiteMaterial())

    // 骨つきの板の lightmap は使わず、lightmap の無い同じ板と同じ画素で描く。
    @Test
    def testLightmapOnSkinnedDrawsLikePlain(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let plain = render(sceneOf(t :: Nil, skinnedPlate() :: Nil));
        let (img, _) = renderCaptured(sceneOf(t :: Nil, Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)), skinnedPlate()) :: Nil));
        Assert.assertEq(expected = pixels(plain), pixels(img))

    // 骨つきの板の lightmap は、使わないことを 1 回だけ知らせる。
    @Test
    def testLightmapOnSkinnedWarnsOnce(): Unit \ {Assert, IO} =
        let t = grayMap(0);
        let (_, err) = renderCaptured(sceneOf(t :: Nil, Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)), skinnedPlate()) :: Nil));
        Assert.assertEq(expected = 1, linesWith("骨つき", err))

    // ── 名前が場面の textures に無い絵 ──

    /// 場面の textures に無い同じ名前 missing の lightmap を付けた 2 枚の板（左右に 1 ずつずらす）の場面。
    def missingLightmapScene(missing: String): Scene3d.Scene3dCmd =
        let plateAt = (x: Float64) -> Scene3d.meshInstance(plateMesh(true), Mat4.translate(Vec3.v3(x, 0.0, 0.0)))
            |> Scene3d.withMaterial(whiteMaterial()) |> Scene3d.withLightmap(Scene3d.lightmap(missing));
        sceneOf(Nil, plateAt(-1.0) :: plateAt(1.0) :: Nil)

    // 場面の textures に無い名前の lightmap は 0 で読む: 環境光は足さず、動く光も無いので、2 枚の板とも黒。
    @Test
    def testMissingLightmapReadsZero(): Unit \ {Assert, IO} =
        let (img, _) = renderCaptured(missingLightmapScene(Texture3d.name(grayMap(7))));
        Assert.assertEq(expected = ((255, 0, 0, 0), (255, 0, 0, 0)), (pixel(img, 1, 4), pixel(img, 6, 4)))

    // 場面の textures に無い名前の lightmap は、2 枚の板に付けても「lightmap の絵」として名前ごとに 1 回だけ知らせる。
    @Test
    def testMissingLightmapWarnsOncePerNameAsLightmap(): Unit \ {Assert, IO} =
        let missing = Texture3d.name(grayMap(7));
        let (_, err) = renderCaptured(missingLightmapScene(missing));
        Assert.assertEq(expected = 1, linesWith("lightmap の絵 '${missing}'", err))
}
