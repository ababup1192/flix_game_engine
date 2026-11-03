// TestScene3dLook — 3D の場面の見た目の口（空のグラデーション・半透明の描く順・材質の半透明と両面）の純粋な部品。
// GL と CPU の描き手が同じこの式と並びを使うので、ここで値を固める。

/// 真上が青・地平が白・真下が茶の空。
def threeColorSky(): Scene3d.Sky3d =
    Scene3d.gradientSky(Color.rgb(0.0, 0.0, 1.0), Color.rgb(1.0, 1.0, 1.0), Color.rgb(0.5, 0.25, 0.0))

/// 色を (r, g, b) にする（比べやすく）。
def rgbOf(c: Color): (Float64, Float64, Float64) = (c#r, c#g, c#b)

/// 原点の 1 辺 2 の四角を at に置いた物（材質は spec だけ）。
def quadAt(at: Vec3.Vec3, name: String): Scene3d.Instance3d =
    let quad = { points = Vec3.v3(-1.0, -1.0, 0.0) :: Vec3.v3(-1.0, 1.0, 0.0) :: Vec3.v3(1.0, 1.0, 0.0) :: Vec3.v3(1.0, -1.0, 0.0) :: Nil,
                 color = Color.rgb(1.0, 1.0, 1.0) };
    let spec: ShaderDoc.Spec = { name = name, cycleRate = 0.0, bindings = Nil,
                                 out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(Color.rgb(1.0, 0.0, 0.0)), alpha = ShaderDoc.Field.Const(0.5) }) };
    Scene3d.meshInstance(Mesh3d.fromPolygons(quad :: Nil), Mat4.translate(at))
        |> Scene3d.withMaterial(Scene3d.material(spec) |> Scene3d.withAlphaBlend(true))

/// 置いた物の材質の spec の名前。
def nameOf(i: Scene3d.Instance3d): String =
    Scene3d.instanceFieldsOf(i)#material |> Option.map(m -> Scene3d.materialFieldsOf(m)#spec#name) |> Option.getWithDefault("")

// ════════════════════════════════════════════════════════════════════
// 空
// ════════════════════════════════════════════════════════════════════

/// 真上を向くと zenith の色。
@Test
def testSkyStraightUpIsZenith(): Unit \ Assert =
    Assert.assertEq(expected = (0.0, 0.0, 1.0), rgbOf(Scene3d.skyColorOf(threeColorSky(), Vec3.v3(0.0, 1.0, 0.0))))

/// 真横を向くと horizon の色。
@Test
def testSkyHorizontalIsHorizon(): Unit \ Assert =
    Assert.assertEq(expected = (1.0, 1.0, 1.0), rgbOf(Scene3d.skyColorOf(threeColorSky(), Vec3.v3(0.0, 0.0, 1.0))))

/// 真下を向くと ground の色。
@Test
def testSkyStraightDownIsGround(): Unit \ Assert =
    Assert.assertEq(expected = (0.5, 0.25, 0.0), rgbOf(Scene3d.skyColorOf(threeColorSky(), Vec3.v3(0.0, -1.0, 0.0))))

/// 曲がり 2 で上へ 30°（d.y = 0.5）は、地平と天頂の間を 0.5² = 0.25 だけ寄せた色（白から青へ 1/4）。
@Test
def testSkyCurveTwoAtThirtyDegrees(): Unit \ Assert =
    let sky = Scene3d.withSkyCurve(2.0, threeColorSky());
    Assert.assertEq(expected = (0.75, 0.75, 1.0), rgbOf(Scene3d.skyColorOf(sky, Vec3.v3(0.0, 0.5, Num.sqrt(0.75)))))

/// 0 以下・NaN の曲がりは 1 として描く。
@Test
def testSkyCurveFallsBackToOne(): Unit \ Assert =
    let curveOf = (c: Float64) -> Scene3d.skyCurveOf(Scene3d.withSkyCurve(c, threeColorSky()));
    Assert.assertEq(expected = (1.0, 1.0, 1.0), (curveOf(0.0), curveOf(-2.0), curveOf(Float64.nan())))

/// 画面の真ん中（NDC の 0, 0）の向きは見ている向き。
@Test
def testSkyDirectionAtCenterIsForward(): Unit \ Assert =
    let camera = { eye = Vec3.zero(), yaw = 0.3, pitch = 0.4, fovY = 1.0, near = 0.1, far = 100.0 };
    let basis = Scene3d.skyBasisOf(Scene3d.scene(camera, { x = 320.0, y = 180.0 }));
    Assert.assertTrue(Vec3.distanceSquared(Scene3d.skyDirectionOf(basis, { x = 0.0, y = 0.0 }), Camera3d.forward(camera)) < 1.0e-12)

/// 見下ろし 20° の場面で、地平（向きの y が 0）は画面の真ん中より上の NDC の y = tan(20°) / tan(fovY / 2) に来る。
@Test
def testSkyHorizonRowFollowsPitch(): Unit \ Assert =
    let pitch = 20.0 * Num.pi() / 180.0;
    let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = pitch, fovY = 1.0, near = 0.1, far = 100.0 };
    let basis = Scene3d.skyBasisOf(Scene3d.scene(camera, { x = 320.0, y = 180.0 }));
    let ndcY = (Num.sin(pitch) / Num.cos(pitch)) / (Num.sin(0.5) / Num.cos(0.5));
    Assert.assertTrue(Float64.abs(Scene3d.skyDirectionOf(basis, { x = 0.0, y = ndcY })#y) < 1.0e-9)

/// 空なしの場面は scene の既定。
@Test
def testSceneHasNoSkyByDefault(): Unit \ Assert =
    Assert.assertTrue(Option.isEmpty(Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 },
                                                   { x = 10.0, y = 10.0 })#sky))

/// sky と background が両方ある時だけ知らせる。
@Test
def testSkyWarningOnlyWhenBothAreSet(): Unit \ Assert =
    let base = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }, { x = 10.0, y = 10.0 });
    let withSky = { sky = Some(threeColorSky()) | base };
    let both = { environment = { background = Some(Color.rgb(0.0, 0.0, 0.0)) | withSky#environment } | withSky };
    Assert.assertEq(expected = (false, true), (Option.nonEmpty(Scene3d.skyWarning(withSky)), Option.nonEmpty(Scene3d.skyWarning(both))))

// ════════════════════════════════════════════════════════════════════
// 半透明と両面の材質
// ════════════════════════════════════════════════════════════════════

/// material の既定は不透明・表だけ。withAlphaBlend と withDoubleSided はそれぞれの欄だけを替える。
@Test
def testMaterialBlendAndSidesFlags(): Unit \ Assert =
    let spec: ShaderDoc.Spec = { name = "m", cycleRate = 0.0, bindings = Nil,
                                 out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(Color.rgb(1.0, 1.0, 1.0)), alpha = ShaderDoc.Field.Const(1.0) }) };
    let flags = (m: Scene3d.Material3d) -> { let f = Scene3d.materialFieldsOf(m); (f#blend, f#doubleSided) };
    Assert.assertEq(expected = ((false, false), (true, false), (false, true)),
        (flags(Scene3d.material(spec)), flags(Scene3d.material(spec) |> Scene3d.withAlphaBlend(true)),
         flags(Scene3d.material(spec) |> Scene3d.withDoubleSided(true))))

/// 半透明の物は目から遠い順に並ぶ（近い・遠い・真ん中 → 遠い・真ん中・近い）。
@Test
def testBlendOrderIsFarToNear(): Unit \ Assert =
    let xs = quadAt(Vec3.v3(0.0, 0.0, 2.0), "near") :: quadAt(Vec3.v3(0.0, 0.0, 9.0), "far") :: quadAt(Vec3.v3(0.0, 0.0, 5.0), "mid") :: Nil;
    Assert.assertEq(expected = "far" :: "mid" :: "near" :: Nil,
        Scene3d.blendOrderOf(Vec3.zero(), Scene3d.instanceFieldsOf, xs) |> List.map(nameOf))

/// 同じ距離の物は並びの前が先（左右に同じ距離で 3 枚。並びの順のまま）。
@Test
def testBlendOrderKeepsListOrderOnTies(): Unit \ Assert =
    let xs = quadAt(Vec3.v3(3.0, 0.0, 4.0), "a") :: quadAt(Vec3.v3(-3.0, 0.0, 4.0), "b") :: quadAt(Vec3.v3(4.0, 0.0, 3.0), "c") :: Nil;
    Assert.assertEq(expected = "a" :: "b" :: "c" :: Nil,
        Scene3d.blendOrderOf(Vec3.zero(), Scene3d.instanceFieldsOf, xs) |> List.map(nameOf))

/// 描く順を決める点は world の境界の真ん中（四角を (2, 3, 4) に置けば (2, 3, 4)）。
@Test
def testDrawCenterIsWorldBoundsCenter(): Unit \ Assert =
    let c = Scene3d.drawCenterOf(Scene3d.instanceFieldsOf(quadAt(Vec3.v3(2.0, 3.0, 4.0), "q")));
    Assert.assertTrue(Vec3.distanceSquared(c, Vec3.v3(2.0, 3.0, 4.0)) < 1.0e-12)
