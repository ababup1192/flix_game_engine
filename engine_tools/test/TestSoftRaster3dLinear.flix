// SoftRaster3d の 3D の色（線形の量で計算し、色を作った直後に画面の値へ戻す）を、Scene3d の頭の「3D の色」の表の行ごとに式から導いた値で確かめる。
//   値は 0 と 1 を避けて 0.5 などで置く（0 と 1 は sRGB の曲線で動かない点で、変換の抜けや 2 回がけが見えない）。
//   入口（SoftRaster.renderToImageFull）を通す場面は作業場に project.json が無いので線形で描かれる。
//   偽の道（0.78 の式）は drawScene を linear = false で直に呼ぶ場面で確かめる。
// 場面はどれも 8×8（倍率 1）。カメラは原点で +Z を向き、縦の画角 90 度。板は z = 2 で画面いっぱい（x y −2..2）。
mod TestSoftRaster3dLinear {
    import java.awt.image.BufferedImage

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    def okOf(r: Result[String, a]): a = match r {
        case Ok(v)  => v
        case Err(e) => bug!(e)
    }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 }

    /// 環境光が ambient で、絵 textures と置いた物 instances の場面。
    def sceneOf(ambient: Color, textures: List[Texture3d.Texture3d], instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        let base = Scene3d.scene(camera(), { x = 8.0, y = 8.0 });
        { instances = instances, textures = textures, environment = { ambient = ambient | base#environment } | base }

    /// z = 2 の板（頂点の色 c）。
    def plate(c: Color): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons({ points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(2.0, 2.0, 2.0) :: Vec3.v3(2.0, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
                                                   color = c } :: Nil), Mat4.identity())

    /// z = 2 の板（2 本目の uv つき・頂点の色は白）。
    def plateWithUv2(): Scene3d.Instance3d =
        let mesh = okOf(Mesh3d.fromTexturedPolygons(
            { points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(2.0, 2.0, 2.0) :: Vec3.v3(2.0, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
              uvs = { x = 0.0, y = 0.0 } :: { x = 1.0, y = 0.0 } :: { x = 1.0, y = 1.0 } :: { x = 0.0, y = 1.0 } :: Nil,
              color = gray(1.0) } :: Nil));
        Scene3d.meshInstance(okOf(Mesh3d.withUvs2(Option.getWithDefault(Vector.empty(), Mesh3d.uvs(mesh)), mesh)), Mat4.identity())

    /// 色 c・α a の材質。
    def solid(c: Color, a: Float64): Scene3d.Material3d =
        Scene3d.material({ name = "linear:solid", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(a) }) })

    /// 全部の画素が灰色 v（0..255）の 2 × 2 の絵。
    def grayTexture(v: Int32): Texture3d.Texture3d =
        let argb = Int32.bitwiseOr(-16777216, v * 65536 + v * 256 + v);
        okOf(Texture3d.fromArgb(2, 2, Vector#{ argb, argb, argb, argb }))

    def render(scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let req: SoftRaster.RasterReq =
            { drawables = Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1, background = gray(0.0),
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true,
              scenes = { at = Vec2.zero(), clip = None, scene = scene } :: Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map.empty())

    def renderUnconverted(scene: Scene3d.Scene3dCmd): BufferedImage \ IO = TestSoftRaster3dSupport.renderUnconvertedOn(8, scene)

    def redAt(img: BufferedImage, x: Int32, y: Int32): Int32 \ IO = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, img.getRGB(x, y)), 255)

    /// 0..1 の値 v を 8bit にした値（書き出しと同じ丸め）。
    def byteOf(v: Float64): Int32 = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, SoftRaster.argbOfRgba(v, v, v, 1.0)), 255)

    def lin(s: Float64): Float64 = Texture3d.srgbToLinear(s)

    def screen(l: Float64): Float64 = Texture3d.linearToSrgb(l)

    /// 画素の赤が、式の値 v を 8bit にした値と ±1 で同じか（足す順の違いの丸め）。
    def isNear(v: Float64, actual: Int32): Bool = Int32.abs(byteOf(v) - actual) <= 1

    // ── 材質の無い物 ──

    /// 頂点の色 0.5・環境光 0.5: 両方を線形へ戻して掛け、画面の値へ戻す。
    @Test
    def testVertexColorAndAmbientMultiplyInLinear(): Unit \ {Assert, IO} =
        let img = render(sceneOf(gray(0.5), Nil, plate(gray(0.5)) :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(0.5)), redAt(img, 4, 4)))

    /// tint 0.5（頂点の色は白・環境光は白）: tint も線形へ戻すので、画面の値は 0.5 のまま。
    @Test
    def testTintRoundTripsThroughLinear(): Unit \ {Assert, IO} =
        let img = render(sceneOf(gray(1.0), Nil, (plate(gray(1.0)) |> Scene3d.withTint(gray(0.5))) :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5)), redAt(img, 4, 4)))

    // ── 材質 ──

    /// 材質の albedo 0.5・環境光 0.5。
    @Test
    def testMaterialAlbedoIsLinearized(): Unit \ {Assert, IO} =
        let img = render(sceneOf(gray(0.5), Nil, (plate(gray(1.0)) |> Scene3d.withMaterial(solid(gray(0.5), 1.0))) :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(0.5)), redAt(img, 4, 4)))

    /// 材質のある物の tint 0.5・albedo 0.5・環境光は白。
    @Test
    def testMaterialTintIsLinearized(): Unit \ {Assert, IO} =
        let img = render(sceneOf(gray(1.0), Nil, (plate(gray(1.0)) |> Scene3d.withMaterial(solid(gray(0.5), 1.0)) |> Scene3d.withTint(gray(0.5))) :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(0.5)), redAt(img, 4, 4)))

    /// emission 0.5 × emissionIntensity 2（albedo は黒）: emission を線形へ戻してから倍率を掛ける。
    @Test
    def testEmissionIntensityScalesLinearEmission(): Unit \ {Assert, IO} =
        let m = solid(gray(0.0), 1.0) |> Scene3d.withEmission(ShaderDoc.Shade.Solid(gray(0.5))) |> Scene3d.withEmissionIntensity(2.0);
        let img = render(sceneOf(gray(1.0), Nil, (plate(gray(1.0)) |> Scene3d.withMaterial(m)) :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5) * 2.0), redAt(img, 4, 4)))

    /// 偽の道: emission 0.5 × emissionIntensity 2 は値のまま 1.0。
    @Test
    def testUnconvertedEmissionIntensityScalesValue(): Unit \ {Assert, IO} =
        let m = solid(gray(0.0), 1.0) |> Scene3d.withEmission(ShaderDoc.Shade.Solid(gray(0.25))) |> Scene3d.withEmissionIntensity(2.0);
        let img = renderUnconverted(sceneOf(gray(1.0), Nil, (plate(gray(1.0)) |> Scene3d.withMaterial(m)) :: Nil));
        Assert.assertEq(expected = byteOf(0.5), redAt(img, 4, 4))

    /// 偽の道: 頂点の色 0.5・環境光 0.5 は値のまま掛けた 0.25。
    @Test
    def testUnconvertedVertexColorMultipliesValues(): Unit \ {Assert, IO} =
        let img = renderUnconverted(sceneOf(gray(0.5), Nil, plate(gray(0.5)) :: Nil));
        Assert.assertEq(expected = byteOf(0.25), redAt(img, 4, 4))

    // ── ビルボード ──

    /// 光を当てないビルボード（絵は灰 128・tint 0.5）: 絵の rgb と tint を線形へ戻して掛ける。
    @Test
    def testUnlitBillboardTexelAndTintAreLinearized(): Unit \ {Assert, IO} =
        let t = grayTexture(128);
        let board = Scene3d.billboard(Texture3d.name(t), { position = Vec2.zero(), size = { x = 2.0, y = 2.0 } }, Vec3.v3(0.0, 0.0, 2.0), { x = 8.0, y = 8.0 })
            |> Scene3d.withAnchor({ x = 0.5, y = 0.5 }) |> Scene3d.withBillboardTint(gray(0.5)) |> Scene3d.unlit;
        let img = render({ billboards = board :: Nil | sceneOf(gray(1.0), t :: Nil, Nil) });
        Assert.assertTrue(isNear(screen(lin(128.0 / 255.0) * lin(0.5)), redAt(img, 4, 4)))

    /// 光を当てるビルボード（絵は灰 128・環境光 0.5）: 絵と光を線形の量で掛ける。
    @Test
    def testLitBillboardIsLitInLinear(): Unit \ {Assert, IO} =
        let t = grayTexture(128);
        let board = Scene3d.billboard(Texture3d.name(t), { position = Vec2.zero(), size = { x = 2.0, y = 2.0 } }, Vec3.v3(0.0, 0.0, 2.0), { x = 8.0, y = 8.0 })
            |> Scene3d.withAnchor({ x = 0.5, y = 0.5 });
        let img = render({ billboards = board :: Nil | sceneOf(gray(0.5), t :: Nil, Nil) });
        Assert.assertTrue(isNear(screen(lin(128.0 / 255.0) * lin(0.5)), redAt(img, 4, 4)))

    // ── 光・かすみ・空 ──

    /// 点光源（白・intensity 1・range 4・板の 1 手前）だけの光: 光の量は線形の量のまま、出口で画面の値へ戻す。
    @Test
    def testPointLightIsLinearAmount(): Unit \ {Assert, IO} =
        let lamp = { position = Vec3.v3(0.0, 0.0, 1.0), color = gray(1.0), intensity = 1.0, range = 4.0 };
        let scene = { pointLights = lamp :: Nil | sceneOf(gray(0.0), Nil, plate(gray(1.0)) :: Nil) };
        let light = SoftRaster3d.lightAt(scene#environment, lamp :: Nil, Nil, Vec3.v3(0.25, -0.25, 2.0), Vec3.v3(0.0, 0.0, -1.0));
        Assert.assertTrue(isNear(screen(light#r), redAt(render(scene), 4, 4)))

    /// 点光源の color 0.5 は線形へ戻してから intensity を掛ける。
    @Test
    def testPointLightColorIsLinearized(): Unit \ {Assert, IO} =
        let lamp = { position = Vec3.v3(0.0, 0.0, 1.0), color = gray(1.0), intensity = 1.0, range = 4.0 };
        let scene = { pointLights = { color = gray(0.5) | lamp } :: Nil | sceneOf(gray(0.0), Nil, plate(gray(1.0)) :: Nil) };
        let light = SoftRaster3d.lightAt(scene#environment, { color = gray(lin(0.5)) | lamp } :: Nil, Nil, Vec3.v3(0.25, -0.25, 2.0), Vec3.v3(0.0, 0.0, -1.0));
        Assert.assertTrue(isNear(screen(light#r), redAt(render(scene), 4, 4)))

    /// かすみの色 0.5（near 0・far 4・白い板・環境光は白）: 線形の量の中で寄せる。
    @Test
    def testFogColorMixesInLinear(): Unit \ {Assert, IO} =
        let base = sceneOf(gray(1.0), Nil, plate(gray(1.0)) :: Nil);
        let scene = { environment = { fog = Some({ color = gray(0.5), near = 0.0, far = 4.0 }) | base#environment } | base };
        let t = Num.sqrt(0.25 * 0.25 + 0.25 * 0.25 + 4.0) / 4.0;
        Assert.assertTrue(isNear(screen(1.0 + (lin(0.5) - 1.0) * t), redAt(render(scene), 4, 4)))

    /// 空の 3 色が 0.5 の空: 線形へ戻して混ぜ、画面の値へ戻すので 0.5 のまま。
    @Test
    def testSkyColorsRoundTripThroughLinear(): Unit \ {Assert, IO} =
        let scene = { sky = Some(Scene3d.gradientSky(gray(0.5), gray(0.5), gray(0.5))) | sceneOf(gray(1.0), Nil, Nil) };
        Assert.assertTrue(isNear(screen(lin(0.5)), redAt(render(scene), 4, 4)))

    /// 空の真上の白と地平の黒は線形の量の中で混ぜる（画素 (4, 0) の向きの高さ t で 1 × t を画面の値へ）。
    @Test
    def testSkyGradientMixesInLinear(): Unit \ {Assert, IO} =
        let scene = { sky = Some(Scene3d.gradientSky(gray(1.0), gray(0.0), gray(0.0))) | sceneOf(gray(1.0), Nil, Nil) };
        let dir = Scene3d.skyDirectionOf(Scene3d.skyBasisOf(scene), { x = 0.125, y = 1.0 - 0.5 / 8.0 * 2.0 });
        Assert.assertTrue(isNear(screen(Float64.min(1.0, Float64.abs(dir#y))), redAt(render(scene), 4, 0)))

    // ── lightmap ──

    /// Srgb の lightmap（灰 128・intensity 2）× albedo 0.5: ベイクした光を線形の量のまま掛ける。
    @Test
    def testSrgbLightmapStaysLinearAmount(): Unit \ {Assert, IO} =
        let t = grayTexture(128);
        let inst = plateWithUv2() |> Scene3d.withMaterial(solid(gray(0.5), 1.0))
            |> Scene3d.withLightmap({ intensity = 2.0 | Scene3d.lightmap(Texture3d.name(t)) });
        let img = render(sceneOf(gray(1.0), t :: Nil, inst :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(128.0 / 255.0) * 2.0), redAt(img, 4, 4)))

    /// Linear の lightmap（灰 128・intensity 1）× albedo 0.5: 読んだ値をそのまま線形の量として掛ける。
    @Test
    def testLinearLightmapIsReadAsAmount(): Unit \ {Assert, IO} =
        let t = grayTexture(128);
        let inst = plateWithUv2() |> Scene3d.withMaterial(solid(gray(0.5), 1.0))
            |> Scene3d.withLightmap({ colorSpace = Texture3d.ColorSpace.Linear | Scene3d.lightmap(Texture3d.name(t)) });
        let img = render(sceneOf(gray(1.0), t :: Nil, inst :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5) * 128.0 / 255.0), redAt(img, 4, 4)))

    // ── 変換しない物 ──

    /// 何も描かれない画素の background 0.5 は変換しない。
    @Test
    def testBackgroundIsNotConverted(): Unit \ {Assert, IO} =
        let base = sceneOf(gray(1.0), Nil, Nil);
        let img = render({ environment = { background = Some(gray(0.5)) | base#environment } | base });
        Assert.assertEq(expected = byteOf(0.5), redAt(img, 4, 4))

    /// Output.Depth の灰色（near 0・range 4）は変換しない。
    @Test
    def testDepthGrayIsNotConverted(): Unit \ {Assert, IO} =
        let base = sceneOf(gray(1.0), Nil, plate(gray(0.5)) :: Nil);
        let img = render({ output = Scene3d.Output.Depth({ near = 0.0, range = 4.0 }) | base });
        Assert.assertTrue(isNear(Num.sqrt(0.25 * 0.25 + 0.25 * 0.25 + 4.0) / 4.0, redAt(img, 4, 4)))

    // ── 半透明 ──

    /// 半透明（albedo 0.5・α 0.5）を白い板の上に重ねる: 画面の値へ戻した後の値どうしで混ぜる（0.5 × 0.5 + 1 × 0.5）。
    @Test
    def testBlendMixesScreenValues(): Unit \ {Assert, IO} =
        let glass = Scene3d.meshInstance(Mesh3d.fromPolygons({ points = Vec3.v3(-1.0, 1.0, 1.5) :: Vec3.v3(1.0, 1.0, 1.5) :: Vec3.v3(1.0, -1.0, 1.5) :: Vec3.v3(-1.0, -1.0, 1.5) :: Nil,
                                                                color = gray(1.0) } :: Nil), Mat4.identity())
            |> Scene3d.withMaterial(solid(gray(0.5), 0.5) |> Scene3d.withAlphaBlend(true));
        let img = render(sceneOf(gray(1.0), Nil, plate(gray(1.0)) :: glass :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5)) * 0.5 + 1.0 * 0.5, redAt(img, 4, 4)))

    // ── 組み立ての式（GL の r3d_surfaceOut と同じ SoftRaster3d.surfaceOutAt）──

    /// 材質の画素（albedo 0.5・emission 0.25 × 2・環境光 0.5・かすみの色 0.5）は SoftRaster3d.surfaceOutAt（線形・かすみあり）の値と同じ。
    @Test
    def testMaterialPixelMatchesSurfaceOutAt(): Unit \ {Assert, IO} =
        let m = solid(gray(0.5), 1.0) |> Scene3d.withEmission(ShaderDoc.Shade.Solid(gray(0.25))) |> Scene3d.withEmissionIntensity(2.0);
        let base = sceneOf(gray(0.5), Nil, (plate(gray(1.0)) |> Scene3d.withMaterial(m)) :: Nil);
        let scene = { environment = { fog = Some({ color = gray(0.5), near = 0.0, far = 4.0 }) | base#environment } | base };
        let p = Vec3.v3(0.25, -0.25, 2.0);
        let light = SoftRaster3d.lightAt({ ambient = gray(lin(0.5)) | scene#environment }, Nil, Nil, p, Vec3.v3(0.0, 0.0, -1.0));
        let c = SoftRaster3d.surfaceOutAt(scene#environment, true, Vec3.zero(), p, gray(lin(0.5)), gray(1.0), light, gray(0.25), 2.0, true);
        Assert.assertTrue(isNear(c#r, redAt(render(scene), 4, 4)))

    /// 材質の Spec の VertexColor（頂点の色 0.5）は頂点で戻さず、Spec の出口で 1 回だけ戻す（環境光は白なので画面の値は 0.5 のまま）。
    @Test
    def testSpecVertexColorIsLinearizedOnce(): Unit \ {Assert, IO} =
        let vc = (chan: ShaderDoc.TexChan) -> ShaderDoc.Field.VertexColor({ chan = chan });
        let m = Scene3d.material({ name = "linear:vc", cycleRate = 0.0, bindings = Nil,
                                   out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = vc(ShaderDoc.TexChan.R), g = vc(ShaderDoc.TexChan.G), b = vc(ShaderDoc.TexChan.B) }),
                                                              alpha = ShaderDoc.Field.Const(1.0) }) });
        let img = render(sceneOf(gray(1.0), Nil, (plate(gray(0.5)) |> Scene3d.withMaterial(m)) :: Nil));
        Assert.assertTrue(isNear(screen(lin(0.5)), redAt(img, 4, 4)))

    // ── 偽の道の絵 ──

    /// 偽の道: 材質の絵（灰 128）は Linear の鍵の段から読み、環境光 0.5 と値のまま掛ける。
    @Test
    def testUnconvertedMaterialTextureReadsLinearKey(): Unit \ {Assert, IO} =
        let t = grayTexture(128);
        let inst = plateWithUv2() |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest));
        let img = TestSoftRaster3dSupport.renderUnconvertedWith(8, Map#{ (Texture3d.name(t), Texture3d.ColorSpace.Linear) => texLevels(t) },
                                                                sceneOf(gray(0.5), t :: Nil, inst :: Nil));
        Assert.assertTrue(isNear(128.0 / 255.0 * 0.5, redAt(img, 4, 4)))

    /// 偽の道: Srgb の lightmap（灰 128・intensity 1）は Linear の鍵の段から読み、画面の値へ戻してから albedo 0.5 と掛ける。
    @Test
    def testUnconvertedLightmapReadsLinearKey(): Unit \ {Assert, IO} =
        let t = grayTexture(128);
        let inst = plateWithUv2() |> Scene3d.withMaterial(solid(gray(0.5), 1.0)) |> Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)));
        let img = TestSoftRaster3dSupport.renderUnconvertedWith(8, Map#{ (Texture3d.name(t), Texture3d.ColorSpace.Linear) => texLevels(t) },
                                                                sceneOf(gray(1.0), t :: Nil, inst :: Nil));
        Assert.assertTrue(isNear(0.5 * screen(lin(128.0 / 255.0)), redAt(img, 4, 4)))

    /// 絵 t の Raw の段の列（偽の描き手が作る段と同じ）。
    def texLevels(t: Texture3d.Texture3d): Vector[ShaderEval.TexData] =
        List.toVector(Mip.build(Mip.Average.Raw, { width = Texture3d.width(t), height = Texture3d.height(t), pixels = Texture3d.argb(t) }))
}
