// SoftRaster3d（RasterReq#scenes の 3D の場面）を具体値で固定する。
//   深度で手前が勝つ・カメラの後ろは塗らない・near で切った手前側は塗る・裏の面は捨てる・
//   点光源に近いほど明るい・地の色 None は下地が見える・Output.Depth は手前ほど暗い・ビルボードの α の抜き・
//   材質（world で色が変わる・頂点の色を掛けない・emission・cutout の抜き・材質の無い物は今のまま）・
//   影（板の真下が暗い・板が無ければ影の無い光と同じ・strength 0 で消える・光の外は変わらない・影の無い光は lightAt のまま）
//   ジョイント（回すと重みの頂点の画素が動く・影も動く・pose が無い / ジョイントが足りない時はバインドポーズ）
// 場面はどれも 8×8（design・倍率 1）。カメラは原点で +Z を向き、縦の画角 90 度（焦点 1）なので、
// 奥行き z の点 (x, y) は画面の x = (x / z + 1) × 4・y = (1 − y / z) × 4 に写る。
mod TestSoftRaster3d {
    import java.awt.image.BufferedImage

    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    def red(): Color = { r = 1.0, g = 0.0, b = 0.0 }
    def blue(): Color = { r = 0.0, g = 0.0, b = 1.0 }
    def white(): Color = { r = 1.0, g = 1.0, b = 1.0 }
    def black(): Color = { r = 0.0, g = 0.0, b = 0.0 }
    def green(): Color = { r = 0.0, g = 1.0, b = 0.0 }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 }

    /// 奥行き z に立つ板（x は left..right・y は bottom..top）。カメラから見て時計回り（表がカメラを向く）。
    def plate(color: Color, z: Float64, left: Float64, right: Float64, bottom: Float64, top: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(left, top, z) :: Vec3.v3(right, top, z) :: Vec3.v3(right, bottom, z) :: Vec3.v3(left, bottom, z) :: Nil,
              color = color } :: Nil), Mat4.identity())

    /// plate と同じ板を反時計回りで（裏がカメラを向く）。
    def backPlate(color: Color, z: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-1.0, -1.0, z) :: Vec3.v3(1.0, -1.0, z) :: Vec3.v3(1.0, 1.0, z) :: Vec3.v3(-1.0, 1.0, z) :: Nil,
              color = color } :: Nil), Mat4.identity())

    /// y = −1 の床（z は −5..5。カメラの後ろまで伸びる）。上から見て時計回り（表が上を向く）。
    def floor(color: Color): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-5.0, -1.0, -5.0) :: Vec3.v3(-5.0, -1.0, 5.0) :: Vec3.v3(5.0, -1.0, 5.0) :: Vec3.v3(5.0, -1.0, -5.0) :: Nil,
              color = color } :: Nil), Mat4.identity())

    def sceneOf(instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        { instances = instances | Scene3d.scene(camera(), { x = 8.0, y = 8.0 }) }

    def cmdOf(scene: Scene3d.Scene3dCmd): Scene3d.RenderCmd = { at = Vec2.zero(), clip = None, scene = scene }

    /// 下地 base の 8×8 に場面を 1 つ描く。images はビルボードが引く絵。
    def renderWith(base: Color, images: Map[String, BufferedImage], scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let req: SoftRaster.RasterReq =
            { drawables = Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1, background = base,
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true,
              scenes = cmdOf(scene) :: Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), images)

    def render(scene: Scene3d.Scene3dCmd): BufferedImage \ IO = renderWith(black(), Map.empty(), scene)

    def pixel(img: BufferedImage, x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO = channels(img.getRGB(x, y))

    // ════════════════════════════════════════════════════════
    // 深度
    // ════════════════════════════════════════════════════════

    // z = 2 の赤い板は z = 4 の青い板より手前。渡す順を入れ替えても真ん中の画素は赤（環境光が白なので色そのまま）。
    @Test
    def testNearRedPlateWinsOverFarBluePlateInEitherOrder(): Unit \ {Assert, IO} =
        let near = plate(red(), 2.0, -1.0, 1.0, -1.0, 1.0);
        let far = plate(blue(), 4.0, -2.0, 2.0, -2.0, 2.0);
        let farFirst = render(sceneOf(far :: near :: Nil));
        let nearFirst = render(sceneOf(near :: far :: Nil));
        Assert.assertEq(expected = ((255, 255, 0, 0), (255, 255, 0, 0)), (pixel(farFirst, 4, 4), pixel(nearFirst, 4, 4)))

    // z = −2（カメラの後ろ）の板は、表と裏のどちらを向けても塗られず、下地の黒のまま。
    @Test
    def testPlateBehindCameraIsNotDrawn(): Unit \ {Assert, IO} =
        let img = render(sceneOf(plate(red(), -2.0, -1.0, 1.0, -1.0, 1.0) :: backPlate(red(), -2.0) :: Nil));
        Assert.assertEq(expected = (255, 0, 0, 0), pixel(img, 4, 4))

    // カメラの後ろまで伸びる床は near の平面で切られ、手前側（画面の下の行・z ≈ 1.14 の所）は塗られる。
    @Test
    def testFloorCrossingNearPlaneKeepsFrontPart(): Unit \ {Assert, IO} =
        let img = render(sceneOf(floor(red()) :: Nil));
        Assert.assertEq(expected = (255, 255, 0, 0), pixel(img, 4, 7))

    // ════════════════════════════════════════════════════════
    // 表と裏
    // ════════════════════════════════════════════════════════

    // fromPolygons の表（カメラから見て時計回り）は描かれ、同じ板を裏返した物は捨てられる。
    @Test
    def testFrontFaceIsDrawnAndBackFaceIsCulled(): Unit \ {Assert, IO} =
        let front = render(sceneOf(plate(red(), 2.0, -1.0, 1.0, -1.0, 1.0) :: Nil));
        let back = render(sceneOf(backPlate(red(), 2.0) :: Nil));
        Assert.assertEq(expected = ((255, 255, 0, 0), (255, 0, 0, 0)), (pixel(front, 4, 4), pixel(back, 4, 4)))

    // ════════════════════════════════════════════════════════
    // 光
    // ════════════════════════════════════════════════════════

    // 環境光を黒にして点光源を板の左の手前（x = −1.5・z = 1.5）に置くと、左端の画素は右端の画素より明るい。
    @Test
    def testPointLightLitsNearPixelBrighterThanFarPixel(): Unit \ {Assert, IO} =
        let base = sceneOf(plate(white(), 2.0, -2.0, 2.0, -2.0, 2.0) :: Nil);
        let lit = { environment = { ambient = black() | base#environment },
                    pointLights = { position = Vec3.v3(-1.5, 0.0, 1.5), color = white(), intensity = 1.0, range = 4.0 } :: Nil | base };
        let img = render(lit);
        let (_, nearRed, _, _) = pixel(img, 0, 4);
        let (_, farRed, _, _) = pixel(img, 7, 4);
        Assert.assertTrue(nearRed > farRed)

    // ════════════════════════════════════════════════════════
    // 地の色と書き出す物
    // ════════════════════════════════════════════════════════

    // background が None の場面の何も描かれない画素は透明で、下地の緑が見える。
    @Test
    def testEmptyPixelWithoutBackgroundShowsUnderlay(): Unit \ {Assert, IO} =
        let img = renderWith(green(), Map.empty(), sceneOf(Nil));
        Assert.assertEq(expected = (255, 0, 255, 0), pixel(img, 4, 4))

    // background が Some なら何も描かれない画素はその色で塗られる（下地の緑は隠れる）。
    @Test
    def testEmptyPixelWithBackgroundIsFilled(): Unit \ {Assert, IO} =
        let base = sceneOf(Nil);
        let img = renderWith(green(), Map.empty(), { environment = { background = Some(blue()) | base#environment } | base });
        Assert.assertEq(expected = (255, 0, 0, 255), pixel(img, 4, 4))

    // Output.Depth（near 0・range 8）: 左の z = 2 の板（灰 2 / 8）は右の z = 4 の板（灰 4 / 8）より暗い。
    @Test
    def testDepthOutputIsDarkerForNearerPlate(): Unit \ {Assert, IO} =
        let base = sceneOf(plate(white(), 2.0, -2.0, 0.0, -2.0, 2.0) :: plate(white(), 4.0, 0.0, 4.0, -4.0, 4.0) :: Nil);
        let img = render({ output = Scene3d.Output.Depth({ near = 0.0, range = 8.0 }) | base });
        let (_, nearGray, _, _) = pixel(img, 1, 4);
        let (_, farGray, _, _) = pixel(img, 6, 4);
        Assert.assertTrue(nearGray < farGray)

    // ════════════════════════════════════════════════════════
    // ビルボード
    // ════════════════════════════════════════════════════════

    /// 2×1 の絵: 左の画素は不透明な赤・右の画素は透明。
    def halfRedImage(): BufferedImage \ IO =
        let img = new BufferedImage(2, 1, 2);
        // 0xFFFF0000（不透明の赤）の signed Int32 表現。
        img.setRGB(0, 0, -65536);
        img.setRGB(1, 0, 0);
        img

    // z = 2 に幅 2・高さ 2 のビルボードを足元の真ん中を (0, −1, 2) にして立てる（画面の x 2..6・y 2..6 を覆う）。
    // 絵の左半分（不透明）は赤で塗られ、右半分（α 0）は捨てられて下地の緑が見える。光を当てないので色はそのまま。
    @Test
    def testBillboardDropsTransparentTexels(): Unit \ {Assert, IO} =
        let board = Scene3d.unlit(Scene3d.billboard("sign", { position = Vec2.zero(), size = { x = 2.0, y = 1.0 } },
                                                    Vec3.v3(0.0, -1.0, 2.0), { x = 2.0, y = 2.0 }));
        let img = renderWith(green(), Map#{ "sign" => halfRedImage() }, { billboards = board :: Nil | sceneOf(Nil) });
        Assert.assertEq(expected = ((255, 255, 0, 0), (255, 0, 255, 0)), (pixel(img, 3, 4), pixel(img, 5, 4)))

    // ════════════════════════════════════════════════════════
    // 材質
    // ════════════════════════════════════════════════════════

    /// 色 shade・α alpha の材質の Spec（Param なし・emission なし・cutout なし）。
    def materialOf(shade: ShaderDoc.Shade, alpha: ShaderDoc.Field): Scene3d.Material3d =
        { spec = { name = "test", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = shade, alpha = alpha }) },
          params = Map.empty(), cutout = false, emission = None }

    def solid(c: Color): Scene3d.Material3d = materialOf(ShaderDoc.Shade.Solid(c), ShaderDoc.Field.Const(1.0))

    def worldX(): ShaderDoc.Field = ShaderDoc.Field.World({ axis = ShaderDoc.Axis3.X })

    // 赤の成分 = world の x の材質を、x −2..2 の板（z = 2。画面の幅いっぱい）に塗る。
    // 左の画素（x ≈ −1.25）は赤 0 に、右の画素（x ≈ 1.25）は赤 1 に切り詰められる。
    @Test
    def testWorldXMaterialColorsLeftAndRightDifferently(): Unit \ {Assert, IO} =
        let red = materialOf(ShaderDoc.Shade.Rgb({ r = worldX(), g = ShaderDoc.Field.Const(0.0), b = ShaderDoc.Field.Const(0.0) }),
                             ShaderDoc.Field.Const(1.0));
        let img = render(sceneOf(Scene3d.withMaterial(red, plate(white(), 2.0, -2.0, 2.0, -2.0, 2.0)) :: Nil));
        Assert.assertEq(expected = ((255, 0, 0, 0), (255, 255, 0, 0)), (pixel(img, 1, 4), pixel(img, 6, 4)))

    // 材質の色は頂点の色を掛けず tint を掛ける: 赤い頂点の板に白の材質・tint 青 → 青（頂点の色を掛けると黒になる）。
    @Test
    def testMaterialIgnoresVertexColorButKeepsTint(): Unit \ {Assert, IO} =
        let board = plate(red(), 2.0, -1.0, 1.0, -1.0, 1.0) |> Scene3d.withMaterial(solid(white())) |> Scene3d.withTint(blue());
        let img = render(sceneOf(board :: Nil));
        Assert.assertEq(expected = (255, 0, 0, 255), pixel(img, 4, 4))

    // 環境光を黒にし光も置かない場面で、黒の材質に emission の緑を付けた板は緑に光る（光の後に足すので光が 0 でも出る）。
    @Test
    def testEmissionMaterialShowsWithoutLight(): Unit \ {Assert, IO} =
        let glowing = { emission = Some(ShaderDoc.Shade.Solid(green())) | solid(black()) };
        let base = sceneOf(Scene3d.withMaterial(glowing, plate(white(), 2.0, -1.0, 1.0, -1.0, 1.0)) :: Nil);
        let img = render({ environment = { ambient = black() | base#environment } | base });
        Assert.assertEq(expected = (255, 0, 255, 0), pixel(img, 4, 4))

    // 手前の板（z = 2）の材質は α 0 の赤。cutout なら抜けて深度も書かず奥の青い板（z = 4）が見え、
    // cutout でなければ α を見ずに赤で塗る。
    @Test
    def testCutoutMaterialShowsFarPlateThroughTransparentPixels(): Unit \ {Assert, IO} =
        let clear = materialOf(ShaderDoc.Shade.Solid(red()), ShaderDoc.Field.Const(0.0));
        let far = plate(blue(), 4.0, -2.0, 2.0, -2.0, 2.0);
        let near = (cutout: Bool) -> Scene3d.withMaterial({ cutout = cutout | clear }, plate(white(), 2.0, -1.0, 1.0, -1.0, 1.0));
        let cut = render(sceneOf(near(true) :: far :: Nil));
        let kept = render(sceneOf(near(false) :: far :: Nil));
        Assert.assertEq(expected = ((255, 0, 0, 255), (255, 255, 0, 0)), (pixel(cut, 4, 4), pixel(kept, 4, 4)))

    // Output.Depth でも cutout で抜いた画素は深度に出ない: 手前の抜けた板があっても、奥の板だけの場面と同じ灰色。
    @Test
    def testCutoutMaterialIsSkippedInDepthOutput(): Unit \ {Assert, IO} =
        let clear = { cutout = true | materialOf(ShaderDoc.Shade.Solid(red()), ShaderDoc.Field.Const(0.0)) };
        let far = plate(white(), 4.0, -2.0, 2.0, -2.0, 2.0);
        let depthOf = (instances: List[Scene3d.Instance3d]) ->
            render({ output = Scene3d.Output.Depth({ near = 0.0, range = 8.0 }) | sceneOf(instances) });
        let farOnly = depthOf(far :: Nil);
        let withCut = depthOf(Scene3d.withMaterial(clear, plate(white(), 2.0, -1.0, 1.0, -1.0, 1.0)) :: far :: Nil);
        Assert.assertEq(expected = pixel(farOnly, 4, 4), pixel(withCut, 4, 4))

    // 材質のある板を隣に置いても、材質の無い板の画素は材質の板が無い時と同じ（頂点の色の道は変わらない）。
    @Test
    def testInstanceWithoutMaterialKeepsVertexColorNextToMaterial(): Unit \ {Assert, IO} =
        let plain = plate(red(), 2.0, -2.0, 0.0, -2.0, 2.0);
        let painted = Scene3d.withMaterial(solid(green()), plate(white(), 2.0, 0.0, 2.0, -2.0, 2.0));
        let alone = render(sceneOf(plain :: Nil));
        let together = render(sceneOf(painted :: plain :: Nil));
        Assert.assertEq(expected = pixel(alone, 1, 4), pixel(together, 1, 4))

    // ════════════════════════════════════════════════════════
    // 影
    // ════════════════════════════════════════════════════════

    /// 高さ y に寝かせた板（x −1..1・z lo..hi）。上から見て時計回り（表が上を向く。下のカメラからは裏）。
    def board(y: Float64, lo: Float64, hi: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-1.0, y, lo) :: Vec3.v3(-1.0, y, hi) :: Vec3.v3(1.0, y, hi) :: Vec3.v3(1.0, y, lo) :: Nil,
              color = white() } :: Nil), Mat4.identity())

    /// (0, 3, 2.5) から真下を向く白いスポット（縦の画角 90 度・range 8）。shadow は呼ぶ側が入れる。
    def overheadSpot(shadow: Option[Scene3d.ShadowMap]): Scene3d.SpotLight =
        { position = Vec3.v3(0.0, 3.0, 2.5), target = Vec3.v3(0.0, -1.0, 2.5), fovY = 1.5707963267948966,
          color = white(), intensity = 1.0, range = 8.0, shadow = shadow }

    def shadowMap(strength: Float64): Scene3d.ShadowMap = { mapSize = 64, bias = 0.005, pcfRadius = 1, strength = strength }

    /// 環境光を黒にし、スポット spot だけで照らす場面。
    def spotLit(spot: Scene3d.SpotLight, instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        let base = sceneOf(instances);
        { environment = { ambient = black() | base#environment }, spotLights = spot :: Nil | base }

    // 画素 (4, 5) は床の (1/3, −1, 8/3)。真上の光（y = 3）と床の間の y = 1 に板（z 1.5..3.5）を置くと、板の影は床の
    // x −2..2・z 0.5..4.5 に落ちる（光から 2 の板が 4 の床で 2 倍に広がる）。strength 1 で全部遮られ、環境光が黒なので黒。
    // 板は下のカメラへ裏を向けている（画面には出ない）ので、表も裏も地図に描くことも確かめる。
    @Test
    def testBoardBetweenSpotAndFloorDarkensFloorBelow(): Unit \ {Assert, IO} =
        let img = render(spotLit(overheadSpot(Some(shadowMap(1.0))), floor(white()) :: board(1.0, 1.5, 3.5) :: Nil));
        Assert.assertEq(expected = (255, 0, 0, 0), pixel(img, 4, 5))

    // 板を外すと、影を落とすスポットの床の画素は、shadow の無い同じスポットの画素と同じ（床は自分に影を落とさない）。
    @Test
    def testFloorWithoutBoardIsLitLikeSpotWithoutShadow(): Unit \ {Assert, IO} =
        let shadowed = render(spotLit(overheadSpot(Some(shadowMap(1.0))), floor(white()) :: Nil));
        let plain = render(spotLit(overheadSpot(None), floor(white()) :: Nil));
        Assert.assertEq(expected = pixel(plain, 4, 5), pixel(shadowed, 4, 5))

    // strength 0 なら板があっても影は出ず、shadow の無いスポットの画素と同じ。
    @Test
    def testZeroStrengthShadowLeavesFloorLit(): Unit \ {Assert, IO} =
        let instances = floor(white()) :: board(1.0, 1.5, 3.5) :: Nil;
        let faint = render(spotLit(overheadSpot(Some(shadowMap(0.0))), instances));
        let plain = render(spotLit(overheadSpot(None), instances));
        Assert.assertEq(expected = pixel(plain, 4, 5), pixel(faint, 4, 5))

    // 縦の画角 0.5 のスポットでは、画素 (4, 7) の床（≈ (0.14, −1, 1.14)。真下から約 19 度）は光の地図の NDC の外。
    // 板があっても、環境光 0.5 の灰色だけの shadow の無い場面と同じ画素になる。
    @Test
    def testFloorOutsideShadowFrustumIsNotDarkened(): Unit \ {Assert, IO} =
        let narrow = (shadow: Option[Scene3d.ShadowMap]) -> { fovY = 0.5 | overheadSpot(shadow) };
        let gray = { r = 0.5, g = 0.5, b = 0.5 };
        let litBy = (shadow: Option[Scene3d.ShadowMap]) -> {
            let s = spotLit(narrow(shadow), floor(white()) :: board(1.0, 1.5, 3.5) :: Nil);
            render({ environment = { ambient = gray | s#environment } | s })
        };
        Assert.assertEq(expected = pixel(litBy(None), 4, 7), pixel(litBy(Some(shadowMap(1.0))), 4, 7))

    // 影の無い場面は光の式のまま: 目の所から +Z を向くスポットで z = 2 の白い板を照らすと、画素 (4, 4) の色は
    // その画素の world の点 (0.25, −0.25, 2)・法線 (0, 0, −1) での lightAt と同じ。
    @Test
    def testSceneWithoutShadowMatchesLightAt(): Unit \ {Assert, IO} =
        let spot = { position = Vec3.zero(), target = Vec3.v3(0.0, 0.0, 2.0), fovY = 1.5707963267948966,
                     color = white(), intensity = 1.0, range = 4.0, shadow = None };
        let scene = spotLit(spot, plate(white(), 2.0, -2.0, 2.0, -2.0, 2.0) :: Nil);
        let light = SoftRaster3d.lightAt(scene#environment, Nil, spot :: Nil, Vec3.v3(0.25, -0.25, 2.0), Vec3.v3(0.0, 0.0, -1.0));
        Assert.assertEq(expected = channels(SoftRaster.argbOfRgba(light#r, light#g, light#b, 1.0)), pixel(render(scene), 4, 4))

    // ════════════════════════════════════════════════════════
    // ジョイント
    // ════════════════════════════════════════════════════════

    def okOf(r: Result[String, a]): a = match r {
        case Ok(v)  => v
        case Err(e) => bug!(e)
    }

    /// 頂点 1 つ分の v を 4 頂点分に並べる。
    def eachOfFour(v: Vector[a]): Vector[a] = Vector.range(0, 4) |> Vector.flatMap(_ -> v)

    /// 頂点 4 つの四角（positions は頂点ごとに 3 つ・巡りは 0, 1, 2 と 0, 2, 3）。法線は全部 normal・色は白。
    /// joint が Some なら、4 頂点ともそのジョイントに重み 1 を付ける。
    def quad(positions: Vector[Float64], normal: Vec3.Vec3, joint: Option[Int32]): Mesh3d.Mesh3d =
        okOf(Mesh3d.fromArrays({
            positions = positions, normals = eachOfFour(Vector#{ normal#x, normal#y, normal#z }), colors = eachOfFour(Vector#{ 1.0, 1.0, 1.0 }),
            indices = Vector#{ 0, 1, 2, 0, 2, 3 },
            skin = Option.map(j -> { joints = eachOfFour(Vector#{ j, 0, 0, 0 }), weights = eachOfFour(Vector#{ 1.0, 0.0, 0.0, 0.0 }) }, joint)
        }))

    /// z = 2 に立つ横長の棒（x 0..1.5・y −0.5..0.5）。カメラから見て時計回り。左端の真ん中 (0, 0, 2) がジョイントの位置。
    def bar(joint: Option[Int32]): Mesh3d.Mesh3d =
        quad(Vector#{ 0.0, 0.5, 2.0, 1.5, 0.5, 2.0, 1.5, -0.5, 2.0, 0.0, -0.5, 2.0 }, Vec3.v3(0.0, 0.0, -1.0), joint)

    /// pivot に立つジョイント 1 本だけのスキン（レストポーズの joint 行列が単位行列）。
    def oneJointSkin(pivot: Vec3.Vec3): Skin3d.Skin3d =
        okOf(Skin3d.make({ names = Vector#{ "pivot" }, parents = Vector#{ -1 },
                           rest = Vector#{ { translation = pivot, rotation = Quat.identity(), scale = Vec3.one() } },
                           inverseBinds = None, rootTransform = Mat4.identity() }))

    /// oneJointSkin(pivot) のジョイントを rotation へ回した Pose。
    def turned(pivot: Vec3.Vec3, rotation: Quat.Quat): Pose3d.Pose3d =
        Pose3d.compute(oneJointSkin(pivot), Vector#{ { translation = pivot, rotation = rotation, scale = Vec3.one() } })

    /// Z 軸まわりに +90 度（x → y の向き）。
    def quarterTurnZ(): Quat.Quat = Quat.normalized({ x = 0.0, y = 0.0, z = 1.0, w = 1.0 })

    def posed(pose: Pose3d.Pose3d, mesh: Mesh3d.Mesh3d): Scene3d.Instance3d =
        Scene3d.withPose(pose, Scene3d.meshInstance(mesh, Mat4.identity()))

    def pixels(img: BufferedImage): List[Int32] \ IO = List.range(0, 64) |> List.map(k -> img.getRGB(Int32.remainder(k, 8), k / 8))

    // 棒のジョイント (0, 0, 2) を Z 軸まわりに 90 度回すと、棒は x −0.5..0.5・y 0..1.5 の縦に立つ。
    // 画素 (6, 4) は z = 2 の (1.25, −0.25)（回す前の棒の中・回した後の外）、画素 (4, 1) は (0.25, 1.25)（その逆）。
    // 環境光が白なので棒の画素は白・外は下地の黒。
    @Test
    def testTurningJointNinetyDegreesMovesWeightedVertices(): Unit \ {Assert, IO} =
        let pivot = Vec3.v3(0.0, 0.0, 2.0);
        let rest = render(sceneOf(posed(turned(pivot, Quat.identity()), bar(Some(0))) :: Nil));
        let quarter = render(sceneOf(posed(turned(pivot, quarterTurnZ()), bar(Some(0))) :: Nil));
        let white8 = (255, 255, 255, 255);
        let black8 = (255, 0, 0, 0);
        Assert.assertEq(expected = ((white8, black8), (black8, white8)),
                        ((pixel(rest, 6, 4), pixel(rest, 4, 1)), (pixel(quarter, 6, 4), pixel(quarter, 4, 1))))

    /// y = 1 に寝かせた板（x 0..1・z 2.25..3.25）。上から見て時計回り。手前の辺の左端 (0, 1, 2.25) がジョイントの位置。
    def skinnedBoard(): Mesh3d.Mesh3d =
        quad(Vector#{ 0.0, 1.0, 2.25, 0.0, 1.0, 3.25, 1.0, 1.0, 3.25, 1.0, 1.0, 2.25 }, Vec3.v3(0.0, 1.0, 0.0), Some(0))

    // 真上の光（y = 3）から 2 の板の影は、4 の床で 2 倍に広がる。回す前の板の影は床の x 0..2・z 2..4 で、画素 (4, 5) の床の点
    // (1/3, −1, 8/3) を覆う。ジョイントを Y 軸まわりに 180 度回すと板は x −1..0・z 1.25..2.25 へ移り、影は x −2..0・z 0..2 で、
    // その点は板の無い床と同じ明るさに戻る。
    @Test
    def testShadowMapFollowsPose(): Unit \ {Assert, IO} =
        let pivot = Vec3.v3(0.0, 1.0, 2.25);
        let litWith = (instances: List[Scene3d.Instance3d]) -> pixel(render(spotLit(overheadSpot(Some(shadowMap(1.0))), instances)), 4, 5);
        let rest = litWith(floor(white()) :: posed(turned(pivot, Quat.identity()), skinnedBoard()) :: Nil);
        let halfTurn = litWith(floor(white()) :: posed(turned(pivot, { x = 0.0, y = 1.0, z = 0.0, w = 0.0 }), skinnedBoard()) :: Nil);
        Assert.assertEq(expected = ((255, 0, 0, 0), litWith(floor(white()) :: Nil)), (rest, halfTurn))

    // pose の無いジョイントの重みつきの棒は、重みの無い同じ棒と画素が全部同じ（曲げずにバインドポーズで描く）。
    @Test
    def testSkinnedMeshWithoutPoseMatchesPlainMesh(): Unit \ {Assert, IO} =
        let plain = render(sceneOf(Scene3d.meshInstance(bar(None), Mat4.identity()) :: Nil));
        let skinned = render(sceneOf(Scene3d.meshInstance(bar(Some(0)), Mat4.identity()) :: Nil));
        Assert.assertEq(expected = pixels(plain), pixels(skinned))

    // 棒がジョイント 1 番を指すのに Pose のジョイントが 1 本だけだと、skinningOf が None になり、回した Pose でも落ちずに
    // 重みの無い同じ棒と同じ画素で描く。
    @Test
    def testPoseWithTooFewJointsDrawsBindPose(): Unit \ {Assert, IO} =
        let plain = render(sceneOf(Scene3d.meshInstance(bar(None), Mat4.identity()) :: Nil));
        let short = render(sceneOf(posed(turned(Vec3.v3(0.0, 0.0, 2.0), quarterTurnZ()), bar(Some(1))) :: Nil));
        Assert.assertEq(expected = pixels(plain), pixels(short))
}
