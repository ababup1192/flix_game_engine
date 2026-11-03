// SoftRaster3d の見た目の口: 半透明（重ね方・深度を書かない・遠い順・cutout と両方・Output.Depth に描かない）・
// 両面（裏の面も塗る・裏の面の光の法線を裏返す）・空（地平の行が pitch で決まる・background の代わり・Output.Depth で白）。
// 場面は 8×8（design・倍率 1）。カメラは原点で +Z を向き、縦の画角 90 度（焦点 1）。
mod TestSoftRaster3dLook {
    import java.awt.image.BufferedImage

    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    def red(): Color = { r = 1.0, g = 0.0, b = 0.0 }
    def green(): Color = { r = 0.0, g = 1.0, b = 0.0 }
    def blue(): Color = { r = 0.0, g = 0.0, b = 1.0 }
    def black(): Color = { r = 0.0, g = 0.0, b = 0.0 }

    def cameraPitched(pitch: Float64): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = pitch, fovY = 1.5707963267948966, near = 0.1, far = 100.0 }

    /// 奥行き z の四角（x と y は −h..h）。front = 真ならカメラへ表を向ける（時計回り）。
    def quad(color: Color, z: Float64, h: Float64, front: Bool): Mesh3d.Polygon =
        let pts = Vec3.v3(0.0 - h, h, z) :: Vec3.v3(h, h, z) :: Vec3.v3(h, 0.0 - h, z) :: Vec3.v3(0.0 - h, 0.0 - h, z) :: Nil;
        { points = if (front) pts else List.reverse(pts), color = color }

    def solid(polys: List[Mesh3d.Polygon]): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(polys), Mat4.identity())

    /// 色 c・α a の材質（頂点の色は読まない）。
    def tinted(c: Color, a: Float64): Scene3d.Material3d =
        Scene3d.material({ name = "look:${Float64.toString(c#r)}:${Float64.toString(c#g)}:${Float64.toString(a)}", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(a) }) })

    /// 頂点の色・α 0.5 の半透明の材質。
    def vertexColorGlass(): Scene3d.Material3d =
        let chan = (c: ShaderDoc.TexChan) -> ShaderDoc.Field.VertexColor({ chan = c });
        Scene3d.material({ name = "look:vc", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = chan(ShaderDoc.TexChan.R), g = chan(ShaderDoc.TexChan.G),
                                                                                    b = chan(ShaderDoc.TexChan.B) }),
                                                      alpha = ShaderDoc.Field.Const(0.5) }) })
            |> Scene3d.withAlphaBlend(true)

    /// 色 c・α a の半透明の板 polys。
    def glass(c: Color, a: Float64, polys: List[Mesh3d.Polygon]): Scene3d.Instance3d =
        solid(polys) |> Scene3d.withMaterial(tinted(c, a) |> Scene3d.withAlphaBlend(true))

    def sceneOf(instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        { instances = instances | Scene3d.scene(cameraPitched(0.0), { x = 8.0, y = 8.0 }) }

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

    def pixel(img: BufferedImage, x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO = channels(img.getRGB(x, y))

    /// 8bit の値が want の ±1 か（0.5 × 255 の丸めの向きは問わない）。
    def near(want: Int32, got: Int32): Bool = Int32.abs(want - got) <= 1

    // ════════════════════════════════════════════════════════
    // 半透明
    // ════════════════════════════════════════════════════════

    // 奥の青い不透明の板の手前に α 0.5 の赤いガラス: 赤と青を半分ずつ（128, 0, 128）。
    @Test
    def testGlassMixesHalfWithOpaqueBehind(): Unit \ {Assert, IO} =
        let (_, r, g, b) = pixel(render(sceneOf(solid(quad(blue(), 4.0, 2.0, true) :: Nil) :: glass(red(), 0.5, quad(red(), 2.0, 1.0, true) :: Nil) :: Nil)), 4, 4);
        Assert.assertTrue(near(128, r) and g == 0 and near(128, b))

    // 1 つの物の中で、手前の赤（先）と奥の緑（後）の面が重なる: 深度を書かないので奥の緑も重なる（黒の下地に r 64・g 128）。
    // 深度を書くと奥の緑が隠れて（128, 0, 0）になる。
    @Test
    def testGlassDoesNotWriteDepth(): Unit \ {Assert, IO} =
        let both = solid(quad(red(), 2.0, 1.0, true) :: quad(green(), 4.0, 2.0, true) :: Nil) |> Scene3d.withMaterial(vertexColorGlass());
        let img = render(sceneOf(both :: Nil));
        let (_, r, g, _) = pixel(img, 4, 4);
        Assert.assertTrue(near(64, r) and near(128, g))

    // 手前の赤いガラスを先に渡しても、遠い緑のガラスから重ねる（どちらの順でも r 128・g 64）。
    @Test
    def testGlassIsDrawnFarToNearInEitherOrder(): Unit \ {Assert, IO} =
        let nearGlass = glass(red(), 0.5, quad(red(), 2.0, 1.0, true) :: Nil);
        let farGlass = glass(green(), 0.5, quad(green(), 4.0, 2.0, true) :: Nil);
        let rg = (scene: Scene3d.Scene3dCmd) -> { let (_, r, g, _) = pixel(render(scene), 4, 4); (r, g) };
        let (r1, g1) = rg(sceneOf(nearGlass :: farGlass :: Nil));
        let (r2, g2) = rg(sceneOf(farGlass :: nearGlass :: Nil));
        Assert.assertTrue(near(128, r1) and near(64, g1) and r1 == r2 and g1 == g2)

    // cutout も真なら α 0.3 の画素は捨てる: 奥の青い板がそのまま見える。
    @Test
    def testGlassWithCutoutDropsLowAlpha(): Unit \ {Assert, IO} =
        let cut = solid(quad(red(), 2.0, 1.0, true) :: Nil)
            |> Scene3d.withMaterial(tinted(red(), 0.3) |> Scene3d.withAlphaBlend(true) |> Scene3d.withCutout(true));
        Assert.assertEq(expected = (255, 0, 0, 255), pixel(render(sceneOf(solid(quad(blue(), 4.0, 2.0, true) :: Nil) :: cut :: Nil)), 4, 4))

    // Output.Depth にガラスは描かない: 真ん中の灰色は奥（z = 4）の板の距離（near 0・range 8 で 128）。
    @Test
    def testGlassIsSkippedInDepthOutput(): Unit \ {Assert, IO} =
        let scene = { output = Scene3d.Output.Depth({ near = 0.0, range = 8.0 })
                      | sceneOf(solid(quad(blue(), 4.0, 2.0, true) :: Nil) :: glass(red(), 0.5, quad(red(), 2.0, 1.0, true) :: Nil) :: Nil) };
        let (_, r, _, _) = pixel(render(scene), 4, 4);
        Assert.assertTrue(r >= 127 and r <= 132)

    // ════════════════════════════════════════════════════════
    // 両面
    // ════════════════════════════════════════════════════════

    // 裏をカメラへ向けた板: 両面でなければ捨てて黒、両面なら塗る。
    @Test
    def testDoubleSidedDrawsBackFace(): Unit \ {Assert, IO} =
        let back = (sides: Bool) -> solid(quad(red(), 2.0, 1.0, false) :: Nil) |> Scene3d.withMaterial(tinted(red(), 1.0) |> Scene3d.withDoubleSided(sides));
        Assert.assertEq(expected = ((255, 0, 0, 0), (255, 255, 0, 0)),
                        (pixel(render(sceneOf(back(false) :: Nil)), 4, 4), pixel(render(sceneOf(back(true) :: Nil)), 4, 4)))

    // Output.Depth でも両面の物は裏の面を描く: 真ん中の灰色は板（z = 2）の距離（near 0・range 8 で約 64）。表だけなら何も無くて黒。
    @Test
    def testDoubleSidedBackFaceIsInDepthOutput(): Unit \ {Assert, IO} =
        let back = (sides: Bool) -> solid(quad(red(), 2.0, 1.0, false) :: Nil) |> Scene3d.withMaterial(tinted(red(), 1.0) |> Scene3d.withDoubleSided(sides));
        let grayOf = (sides: Bool) -> { let (_, r, _, _) = pixel(render({ output = Scene3d.Output.Depth({ near = 0.0, range = 8.0 }) | sceneOf(back(sides) :: Nil) }), 4, 4); r };
        let drawn = grayOf(true);
        Assert.assertTrue(drawn >= 63 and drawn <= 67 and grayOf(false) == 0)

    // 環境光なし・目の所の点光源: 裏の面の法線を裏返すので、カメラへ向いた裏の面は照らされる（裏返さなければ真っ暗）。
    @Test
    def testDoubleSidedBackFaceIsLitFromItsSide(): Unit \ {Assert, IO} =
        let back = solid(quad(red(), 2.0, 1.0, false) :: Nil) |> Scene3d.withMaterial(tinted(red(), 1.0) |> Scene3d.withDoubleSided(true));
        let base = sceneOf(back :: Nil);
        let scene = { environment = { ambient = black() | base#environment },
                      pointLights = { position = Vec3.zero(), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 } :: Nil | base };
        let (_, r, _, _) = pixel(render(scene), 4, 4);
        Assert.assertTrue(r > 100)

    // ════════════════════════════════════════════════════════
    // 空
    // ════════════════════════════════════════════════════════

    /// 天頂が青・地平が緑・地面が赤の空。
    def rgbSky(): Scene3d.Sky3d = Scene3d.gradientSky(blue(), green(), red())

    // 見下ろし atan(0.5): 地平は NDC の y = 0.5（行 1 と行 2 の境）。行 1 は空の側（赤 0・青 > 0）・行 2 は地面の側（赤 > 0・青 0）。
    @Test
    def testSkyHorizonRowFollowsPitch(): Unit \ {Assert, IO} =
        let scene = { sky = Some(rgbSky()) | Scene3d.scene(cameraPitched(Num.atan2(0.5, 1.0)), { x = 8.0, y = 8.0 }) };
        let img = render(scene);
        let (_, r1, _, b1) = pixel(img, 4, 1);
        let (_, r2, _, b2) = pixel(img, 4, 2);
        Assert.assertTrue(r1 == 0 and b1 > 0 and r2 > 0 and b2 == 0)

    // sky があれば background（赤）は使わない: 真上を向いた真ん中は青に近い。
    @Test
    def testSkyReplacesBackground(): Unit \ {Assert, IO} =
        let base = Scene3d.scene(cameraPitched(0.0 - 1.4), { x = 8.0, y = 8.0 });
        let scene = { sky = Some(rgbSky()), environment = { background = Some(red()) | base#environment } | base };
        let (_, r, _, b) = pixel(render(scene), 4, 4);
        Assert.assertTrue(r == 0 and b > 200)

    // Output.Depth では空は白（一番奥）。
    @Test
    def testSkyIsWhiteInDepthOutput(): Unit \ {Assert, IO} =
        let scene = { sky = Some(rgbSky()), output = Scene3d.Output.Depth({ near = 0.0, range = 8.0 })
                      | Scene3d.scene(cameraPitched(0.0), { x = 8.0, y = 8.0 }) };
        Assert.assertEq(expected = (255, 255, 255, 255), pixel(render(scene), 4, 4))

    // ════════════════════════════════════════════════════════
    // 使わない場面
    // ════════════════════════════════════════════════════════

    // 半透明も両面も空も使わない場面（不透明の材質の板・cutout の板・頂点の色の板・点光源）の 8×8 の画素を畳んだ値は固定
    @Test
    def testSceneWithoutNewLooksIsPinned(): Unit \ {Assert, IO} =
        let opaque = solid(quad(red(), 3.0, 1.5, true) :: Nil) |> Scene3d.withMaterial(tinted(green(), 1.0));
        let cut = solid(quad(red(), 2.0, 0.6, true) :: Nil) |> Scene3d.withMaterial(tinted(blue(), 0.3) |> Scene3d.withCutout(true));
        let plain = solid(quad(red(), 5.0, 4.0, true) :: Nil);
        let base = sceneOf(cut :: opaque :: plain :: Nil);
        let scene = { environment = { ambient = { r = 0.3, g = 0.3, b = 0.3 } | base#environment },
                      pointLights = { position = Vec3.v3(1.0, 1.0, 0.0), color = { r = 1.0, g = 0.9, b = 0.8 }, intensity = 1.0, range = 9.0 } :: Nil | base };
        let img = TestSoftRaster3dSupport.renderOn(8, scene);
        let folded = List.range(0, 64) |> List.foldLeft((acc, k) -> acc * 31i64 + Int32.toInt64(img.getRGB(Int32.remainder(k, 8), k / 8)), 7i64);
        Assert.assertEq(expected = -189061523360340985i64, folded)
}
