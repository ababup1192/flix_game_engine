// TestScene3dBillboardShadow — ビルボードの太陽の影の純粋な部品（withCastShadows・withReceiveShadows・billboardShadowRightOf・
// billboardShadowPointOf・shadowCastingBillboardsOf）。GL・WebGPU・CPU の描き手が同じ値を読む約束を、描き手に依らずに確かめる。

def shadowBoard(): Scene3d.Billboard3d =
    Scene3d.billboard("chars", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 24.0 } }, Vec3.v3(2.0, 0.0, 5.0), { x = 1.0, y = 1.5 })

/// 足したての板は影を落とさず、受けもしない（今までの絵のまま）。
@Test
def testNewBillboardNeitherCastsNorReceives(): Unit \ Assert =
    let f = Scene3d.billboardFieldsOf(shadowBoard());
    Assert.assertEq(expected = (false, false), (f#castShadows, f#receiveShadows))

/// withCastShadows と withReceiveShadows はそれぞれの欄だけを替える。
@Test
def testShadowSettersChangeOnlyTheirField(): Unit \ Assert =
    let f = Scene3d.billboardFieldsOf(shadowBoard() |> Scene3d.withReceiveShadows(true));
    Assert.assertEq(expected = (false, true), (f#castShadows, f#receiveShadows))

/// 太陽がカメラの後ろ（点から太陽への向きが −z）なら、影の地図の板の横はカメラの right（+x）と同じ向き。
@Test
def testShadowRightFollowsCameraRightWhenSunIsBehind(): Unit \ Assert =
    let r = Scene3d.billboardShadowRightOf(Vec3.v3(0.0, 0.8, -0.6), Vec3.v3(0.0, 0.0, 1.0));
    Assert.assertEq(expected = (1.0, 0.0, 0.0), (r#x, r#y, r#z))

/// 太陽が横（点から太陽への向きが −x）なら、板の横は z の向き（太陽へ全面を向ける）。
@Test
def testShadowRightFacesASideSun(): Unit \ Assert =
    let r = Scene3d.billboardShadowRightOf(Vec3.v3(-0.6, 0.8, 0.0), Vec3.v3(1.0, 0.0, 0.0));
    Assert.assertEq(expected = (0.0, 0.0, -1.0), (r#x, r#y, r#z))

/// 太陽が真上なら、板の横は渡した向き（カメラの right）のまま。
@Test
def testShadowRightFallsBackWhenSunIsOverhead(): Unit \ Assert =
    let r = Scene3d.billboardShadowRightOf(Vec3.v3(0.0, 1.0, 0.0), Vec3.v3(0.0, 0.0, 1.0));
    Assert.assertEq(expected = (0.0, 0.0, 1.0), (r#x, r#y, r#z))

/// 影を受ける点: 絵の下の端（v = 1）は足元の高さ、太陽の方へ板の幅の半分だけ進んだ点。
@Test
def testShadowPointAtTheFeetLeadsTowardTheSun(): Unit \ Assert =
    let f = Scene3d.billboardFieldsOf(shadowBoard());
    let p = Scene3d.billboardShadowPointOf(f, Vec3.v3(0.0, 0.0, -1.0), 1.0);
    Assert.assertEq(expected = (2.0, 0.0, 4.5), (p#x, p#y, p#z))

/// 影を受ける点: 絵の上の端（v = 0）は板の高さ 1.5 に、45° の太陽の方へ板から水平に幅の半分 0.5 離れるまで進めた分の高さ 0.5 を足した高さ。
@Test
def testShadowPointAtTheTopIsTheBoardHeight(): Unit \ Assert =
    let f = Scene3d.billboardFieldsOf(shadowBoard());
    let p = Scene3d.billboardShadowPointOf(f, Vec3.v3(0.0, 0.5, -0.5), 0.0);
    Assert.assertEq(expected = 2.0, p#y)

/// 影の地図に描くのは castShadows の板だけ（来た順）。
@Test
def testOnlyCastingBillboardsAreShadowCasters(): Unit \ Assert =
    let camera = { eye = Vec3.v3(0.0, 2.0, -5.0), yaw = 0.0, pitch = 0.2, fovY = 1.0, near = 0.5, far = 100.0 };
    let caster = shadowBoard() |> Scene3d.withCastShadows(true) |> Scene3d.withBillboardTint(Color.rgb(1.0, 0.0, 0.0));
    let scene = { billboards = shadowBoard() :: caster :: Nil | Scene3d.scene(camera, { x = 160.0, y = 90.0 }) };
    let found = Scene3d.shadowCastingBillboardsOf(Scene3d.frustumOf(scene), scene);
    Assert.assertEq(expected = 1.0 :: Nil, found |> List.map(f -> f#tint#r))
