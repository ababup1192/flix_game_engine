// TestScene3dSun — 太陽の光（平行光源）の純粋な部品（Scene3d.directionalLightOf・directionalShadowOf）。
// 描き手が読む値の約束（使える太陽の決め方・影の地図の箱の決め方と丸め）を、GL と CPU の描き手に依らずに確かめる。

def sunCamera(eye: Vec3.Vec3, yaw: Float64, pitch: Float64): Camera3d.Camera3d =
    { eye = eye, yaw = yaw, pitch = pitch, fovY = 1.0, near = 0.5, far = 100.0 }

def sunShadowSettings(): Scene3d.DirectionalShadow =
    { mapSize = 256, bias = 0.05, normalBias = 1.0, pcfRadius = 1, strength = 0.8, distance = 40.0, casterReach = 20.0 }

def sunLightOf(shadow: Option[Scene3d.DirectionalShadow]): Scene3d.DirectionalLight =
    { shadow = shadow | Scene3d.directionalLight(Vec3.v3(0.3, -1.0, 0.4)) }

def sunTriangle(): Scene3d.Instance3d =
    Scene3d.meshInstance(Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 1.0) :: Vec3.v3(1.0, 0.0, 1.0) :: Vec3.v3(0.0, 1.0, 1.0) :: Nil,
                                               color = Color.rgb(1.0, 1.0, 1.0) } :: Nil), Mat4.identity())

def sunSceneWith(camera: Camera3d.Camera3d, light: Option[Scene3d.DirectionalLight]): Scene3d.Scene3dCmd =
    { instances = sunTriangle() :: Nil, directionalLight = light | Scene3d.scene(camera, { x = 160.0, y = 90.0 }) }

def sunSetupOf(scene: Scene3d.Scene3dCmd): Scene3d.SunShadowSetup =
    match Scene3d.directionalShadowOf(scene) {
        case Some(s) => s
        case None    => bug!("TestScene3dSun: 影の設定が作れない")
    }

def sunShadowScene(camera: Camera3d.Camera3d): Scene3d.Scene3dCmd =
    sunSceneWith(camera, Some(sunLightOf(Some(sunShadowSettings()))))

/// 向きの長さは問わず、使える太陽は長さ 1 の向きで返る。
@Test
def testSunDirectionIsNormalized(): Unit \ Assert =
    let scene = sunSceneWith(sunCamera(Vec3.zero(), 0.0, 0.0), Some({ direction = Vec3.v3(0.0, -3.0, 0.0) | sunLightOf(None) }));
    Assert.assertEq(expected = Some((0.0, -1.0, 0.0)), Scene3d.directionalLightOf(scene) |> Option.map(l -> (l#direction#x, l#direction#y, l#direction#z)))

/// 向きの長さが 0・NaN・有限でない物は太陽なし。
@Test
def testSunWithoutDirectionIsNone(): Unit \ Assert =
    let at = (d: Vec3.Vec3) -> Option.isEmpty(Scene3d.directionalLightOf(sunSceneWith(sunCamera(Vec3.zero(), 0.0, 0.0), Some({ direction = d | sunLightOf(None) }))));
    Assert.assertTrue(at(Vec3.zero()) and at(Vec3.v3(Float64.nan(), -1.0, 0.0)) and at(Vec3.v3(Float64.positiveInfinity(), -1.0, 0.0)))

/// intensity が 0 以下・NaN の太陽と、黒い太陽は太陽なし。
@Test
def testSunWithoutLightIsNone(): Unit \ Assert =
    let at = (l: Scene3d.DirectionalLight) -> Option.isEmpty(Scene3d.directionalLightOf(sunSceneWith(sunCamera(Vec3.zero(), 0.0, 0.0), Some(l))));
    Assert.assertTrue(at({ intensity = 0.0 | sunLightOf(None) }) and at({ intensity = -1.0 | sunLightOf(None) })
                      and at({ intensity = Float64.nan() | sunLightOf(None) }) and at({ color = Color.rgb(0.0, 0.0, 0.0) | sunLightOf(None) }))

/// 使わない太陽は理由を 1 行返し、使える太陽と太陽の無い場面は返さない。
@Test
def testSunWarningNamesWhyUnused(): Unit \ Assert =
    let warn = (l: Option[Scene3d.DirectionalLight]) -> Scene3d.directionalLightWarning(sunSceneWith(sunCamera(Vec3.zero(), 0.0, 0.0), l));
    Assert.assertTrue(Option.nonEmpty(warn(Some({ intensity = 0.0 | sunLightOf(None) }))) and Option.nonEmpty(warn(Some({ direction = Vec3.zero() | sunLightOf(None) })))
                      and Option.isEmpty(warn(Some(sunLightOf(None)))) and Option.isEmpty(warn(None)))

/// 影の地図は、Output.Depth・置いた物の無い場面・mapSize 0 以下・太陽なし・distance が near 以下では作らない。
@Test
def testNoShadowMapWhenUnused(): Unit \ Assert =
    let camera = sunCamera(Vec3.zero(), 0.0, 0.0);
    let base = sunShadowScene(camera);
    let none = (s: Scene3d.Scene3dCmd) -> Option.isEmpty(Scene3d.directionalShadowOf(s));
    Assert.assertTrue(none({ output = Scene3d.Output.Depth({ near = 0.0, range = 10.0 }) | base }) and none({ instances = Nil | base })
                      and none(sunSceneWith(camera, Some(sunLightOf(Some({ mapSize = 0 | sunShadowSettings() })))))
                      and none(sunSceneWith(camera, None)) and none(sunSceneWith(camera, Some(sunLightOf(None))))
                      and none(sunSceneWith(camera, Some(sunLightOf(Some({ distance = 0.5 | sunShadowSettings() })))))
                      and Option.nonEmpty(Scene3d.directionalShadowOf(base)))

/// distance はカメラの far で頭打ち（min(distance, far)）になり、薄める幅はその 1 割。
@Test
def testShadowDistanceIsCappedByFar(): Unit \ Assert =
    let at = (d: Float64) -> sunSetupOf(sunSceneWith(sunCamera(Vec3.zero(), 0.0, 0.0), Some(sunLightOf(Some({ distance = d | sunShadowSettings() })))));
    Assert.assertEq(expected = (100.0, 10.0, 30.0, 3.0), (at(500.0)#distance, at(500.0)#fadeWidth, at(30.0)#distance, at(30.0)#fadeWidth))

/// 箱は、カメラの視錐台の near..distance の部分の 8 つの角を全部入れる（x・y・z とも NDC の −1..1 の中）。向き・位置を替えても同じ。
@Test
def testShadowBoxHoldsTheFrustumSlice(): Unit \ Assert =
    let holds = (camera: Camera3d.Camera3d) -> {
        let scene = sunShadowScene(camera);
        let setup = sunSetupOf(scene);
        let tanHalf = Num.sin(camera#fovY / 2.0) / Num.cos(camera#fovY / 2.0);
        let aspect = Scene3d.aspectOf(scene);
        let corners = (camera#near :: setup#distance :: Nil) |> List.flatMap(d -> {
            let center = Vec3.add(camera#eye, Vec3.mul(Camera3d.forward(camera), d));
            let right = Vec3.mul(Camera3d.right(camera), d * tanHalf * aspect);
            let upward = Vec3.mul(Camera3d.up(camera), d * tanHalf);
            (1.0 :: -1.0 :: Nil) |> List.flatMap(sx -> (1.0 :: -1.0 :: Nil) |> List.map(sy -> Vec3.add(center, Vec3.add(Vec3.mul(right, sx), Vec3.mul(upward, sy)))))
        });
        corners |> List.forAll(c -> {
            let p = Mat4.apply(setup#matrix, c);
            Float64.abs(p#x) <= 1.0 + 1.0e-9 and Float64.abs(p#y) <= 1.0 + 1.0e-9 and Float64.abs(p#z) <= 1.0 + 1.0e-9
        })
    };
    Assert.assertTrue(holds(sunCamera(Vec3.v3(3.0, 2.0, -5.0), 0.0, 0.0)) and holds(sunCamera(Vec3.v3(-40.0, 8.0, 12.0), 2.1, 0.6))
                      and holds(sunCamera(Vec3.v3(0.0, 30.0, 0.0), -1.3, -0.4)))

/// 箱の横の半径 r は、カメラを回しても動かしても変わらない（地図の 1 画素の幅が一定）。
@Test
def testShadowRadiusIsIndependentOfCameraPose(): Unit \ Assert =
    let radiusOf = (camera: Camera3d.Camera3d) -> sunSetupOf(sunShadowScene(camera))#radius;
    let a = radiusOf(sunCamera(Vec3.zero(), 0.0, 0.0));
    Assert.assertTrue(Float64.abs(a - radiusOf(sunCamera(Vec3.v3(5.0, 9.0, -3.0), 1.9, 0.5))) < 1.0e-9
                      and Float64.abs(a - radiusOf(sunCamera(Vec3.v3(-20.0, 1.0, 7.0), -2.8, -0.7))) < 1.0e-9 and a > 0.0)

/// カメラを平行移動しても、world の 1 点の地図の座標 × mapSize の小数部分が変わらない（地図の画素の格子に丸めてあるのでちらつかない）。
@Test
def testShadowMapSnapsToTexelGrid(): Unit \ Assert =
    let fractionOf = (camera: Camera3d.Camera3d) -> {
        let setup = sunSetupOf(sunShadowScene(camera));
        let p = Mat4.apply(setup#matrix, Vec3.v3(3.1, 0.7, 4.2));
        let size = Int32.toFloat64(setup#mapSize);
        let u = (p#x * 0.5 + 0.5) * size;
        let v = (p#y * 0.5 + 0.5) * size;
        (u - Float64.floor(u), v - Float64.floor(v))
    };
    let (u0, v0) = fractionOf(sunCamera(Vec3.v3(0.0, 2.0, 0.0), 0.4, 0.2));
    let (u1, v1) = fractionOf(sunCamera(Vec3.v3(0.37, 2.11, 0.53), 0.4, 0.2));
    let (u2, v2) = fractionOf(sunCamera(Vec3.v3(7.9, 1.3, -4.6), 0.4, 0.2));
    let same = (a: Float64, b: Float64) -> Float64.abs(a - b) < 1.0e-6 or Float64.abs(Float64.abs(a - b) - 1.0) < 1.0e-6;
    Assert.assertTrue(same(u0, u1) and same(v0, v1) and same(u0, u2) and same(v0, v2))

/// bias と normalBias は world の長さ: depthBias = bias / 奥行きの幅（casterReach + 2r）・normalShift = normalBias × 地図の 1 画素の幅（2r / mapSize）。
@Test
def testShadowBiasesAreWorldLengths(): Unit \ Assert =
    let setup = sunSetupOf(sunShadowScene(sunCamera(Vec3.zero(), 0.0, 0.0)));
    let settings = sunShadowSettings();
    let span = settings#casterReach + 2.0 * setup#radius;
    let texel = 2.0 * setup#radius / Int32.toFloat64(setup#mapSize);
    Assert.assertTrue(Float64.abs(setup#depthBias * span - settings#bias) < 1.0e-12 and Float64.abs(setup#normalShift - settings#normalBias * texel) < 1.0e-12)

/// mapSize と pcfRadius は上限で頭打ちになる。
@Test
def testShadowSettingsAreClamped(): Unit \ Assert =
    let big = { mapSize = 100000, pcfRadius = 100 | sunShadowSettings() };
    let setup = sunSetupOf(sunSceneWith(sunCamera(Vec3.zero(), 0.0, 0.0), Some(sunLightOf(Some(big)))));
    Assert.assertEq(expected = (Scene3d.maxShadowMapSize(), Scene3d.maxShadowPcfRadius()), (setup#mapSize, setup#pcfRadius))
