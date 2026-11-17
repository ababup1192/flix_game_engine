// TestScene3dStaticGroup — 動かない物の集まり（Scene3d.staticGroup）が描く物の並び。
// 描き手が持ち越さない所（CPU の描き手・鍵・注釈）は instancesOf を描くので、外した鍵・tint・並びの順がここで決まる。

/// 名前 name を付けた、x に置いた 1 辺 1 の四角。
def placedAt(name: String, x: Float64): Scene3d.Instance3d =
    let quad = { points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(1.0, 1.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Nil,
                 color = Color.rgb(1.0, 1.0, 1.0) };
    Scene3d.meshInstance(Mesh3d.fromPolygons(quad :: Nil), Mat4.translate(Vec3.v3(x, 0.0, 0.0))) |> Scene3d.withName(name)

def town(): Scene3d.StaticGroup =
    Scene3d.staticGroup("town", ("a", placedAt("a", 0.0)) :: ("b", placedAt("b", 1.0)) :: ("c", placedAt("c", 2.0)) :: Nil)

def groupScene(): Scene3d.Scene3dCmd =
    Scene3d.scene({ eye = Vec3.v3(0.0, 0.0, -5.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() }, { x = 64.0, y = 64.0 })

/// 集まりの物は instances の後ろに、集まりの中の来た順で並ぶ。
@Test
def testInstancesOfPutsGroupItemsAfterInstances(): Unit \ Assert =
    let scene = { instances = placedAt("walker", 5.0) :: Nil, groups = town() :: Nil | groupScene() };
    Assert.assertEq(expected = "walker" :: "a" :: "b" :: "c" :: Nil, Scene3d.instancesOf(scene) |> List.map(Scene3d.nameOf))

/// withoutItems で外した鍵の物は描かない。
@Test
def testWithoutItemsDropsRemovedKeys(): Unit \ Assert =
    let g = town() |> Scene3d.withoutItems(Set#{"b"});
    Assert.assertEq(expected = "a" :: "c" :: Nil, Scene3d.groupInstancesOf(g) |> List.map(Scene3d.nameOf))

/// withoutItems を重ねると、前に外した鍵も外れたまま。
@Test
def testWithoutItemsAddsToEarlierKeys(): Unit \ Assert =
    let g = town() |> Scene3d.withoutItems(Set#{"a"}) |> Scene3d.withoutItems(Set#{"c"});
    Assert.assertEq(expected = "b" :: Nil, Scene3d.groupInstancesOf(g) |> List.map(Scene3d.nameOf))

/// withGroupTint の色は中の物の tint に掛かる。
@Test
def testWithGroupTintMultipliesItemTint(): Unit \ Assert =
    let g = Scene3d.staticGroup("lamps", ("a", placedAt("a", 0.0) |> Scene3d.withTint(Color.rgb(0.5, 1.0, 1.0))) :: Nil)
        |> Scene3d.withGroupTint(Color.rgb(0.5, 0.25, 1.0));
    let tints = Scene3d.groupInstancesOf(g) |> List.map(i -> { let t = Scene3d.instanceFieldsOf(i)#tint; (t#r, t#g, t#b) });
    Assert.assertEq(expected = (0.25, 0.25, 1.0) :: Nil, tints)

/// 集まりの物だけの場面も、太陽の影を落とす物がある場面として数える。
@Test
def testGroupOnlySceneCastsSunShadow(): Unit \ Assert =
    let sun = { shadow = Some(Scene3d.directionalShadow()) | Scene3d.directionalLight(Vec3.v3(-0.4, -1.0, 0.3)) };
    let scene = { groups = town() :: Nil, directionalLight = Some(sun) | groupScene() };
    Assert.assertTrue(Option.nonEmpty(Scene3d.directionalShadowOf(scene)))
