// TestScene3d — 3D の場面の純粋な部品（Mat4・Transform3d・Camera3d・Mesh3d・Scene3d.pickLights）。
// 座標の約束（左手系・yaw 0 で +Z・+X が画面の右・表の面は外から見て時計回り）が崩れていないかを、
// 鏡写しや巻き方の裏返しで値が変わる問いで確かめる。

// ════════════════════════════════════════════════════════════════════
// 共通
// ════════════════════════════════════════════════════════════════════

/// 縦の画角 1 ラジアン・near 0.1・far 100 のカメラ。
def cameraAt(eye: Vec3.Vec3, yaw: Float64): Camera3d.Camera3d =
    { eye = eye, yaw = yaw, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }

/// 色と強さを固定した点光源。
def pointLightAt(x: Float64): Scene3d.PointLight =
    { position = Vec3.v3(x, 0.0, 0.0), color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = 10.0 }

/// 回す・倍率・pivot をどれも 0 / 1 でない値にした置き場所。
def leaningTransform(): Transform3d.Transform3d =
    { at = Vec3.v3(10.0, 0.0, 0.0), yaw = 1.0, pitch = 0.5, roll = 0.25, pivot = Vec3.v3(1.0, 2.0, 3.0), scale = Vec3.v3(2.0, 2.0, 2.0) }

/// z = 5 の平面に立つ 1 辺 2 の四角（原点から +Z を見て時計回り = 原点の側が表）。
def facingQuad(): Mesh3d.Polygon =
    { points = Vec3.v3(-1.0, -1.0, 5.0) :: Vec3.v3(-1.0, 1.0, 5.0) :: Vec3.v3(1.0, 1.0, 5.0) :: Vec3.v3(1.0, -1.0, 5.0) :: Nil,
      color = Color.rgb(1.0, 0.0, 0.0) }

// ════════════════════════════════════════════════════════════════════
// Mat4
// ════════════════════════════════════════════════════════════════════

/// identity は左から掛けても右から掛けても行列を変えない。
@Test
def testMat4IdentityLeavesMatrixUnchanged(): Unit \ Assert =
    let m = Mat4.mul(Mat4.translate(Vec3.v3(1.0, 2.0, 3.0)), Mat4.scale(Vec3.v3(2.0, 3.0, 4.0)));
    Assert.assertEq(expected = (Mat4.toColumns(m), Mat4.toColumns(m)),
                    (Mat4.toColumns(Mat4.mul(Mat4.identity(), m)), Mat4.toColumns(Mat4.mul(m, Mat4.identity()))))

/// Y 軸に 90 度回すと +Z が +X へ行く（yaw が増えると北から東へ回る約束）。
@Test
def testMat4RotateYQuarterTurnsPlusZToPlusX(): Unit \ Assert =
    let moved = Mat4.apply(Mat4.rotateY(Num.pi() / 2.0), Vec3.v3(0.0, 0.0, 1.0));
    Assert.assertTrue(Vec3.distanceSquared(moved, Vec3.v3(1.0, 0.0, 0.0)) < 1.0e-6)

/// 倍率 (2, 1, 1) の後、斜めの面の接線 (1, 1, 0) と法線 (1, −1, 0) を写しても直交のまま。
/// 写した接線 (2, 1, 0)・写した法線 (0.5, −1, 0) で内積 2 × 0.5 − 1 = 0。
@Test
def testMat4NormalMatrixKeepsNormalPerpendicularAfterScale(): Unit \ Assert =
    let m = Mat4.scale(Vec3.v3(2.0, 1.0, 1.0));
    let tangent = Mat4.applyDir(m, Vec3.v3(1.0, 1.0, 0.0));
    let normal = Mat4.applyDir(Mat4.normalMatrix(m), Vec3.v3(1.0, -1.0, 0.0));
    Assert.assertEq(expected = 0.0, Vec3.dot(tangent, normal))

// ════════════════════════════════════════════════════════════════════
// Transform3d
// ════════════════════════════════════════════════════════════════════

/// 回して倍率を変えても、pivot の点は at + pivot = (11, 2, 3) に留まる。
@Test
def testTransform3dPivotStaysPutWhenRotated(): Unit \ Assert =
    let t = leaningTransform();
    let moved = Mat4.apply(Transform3d.toMat4(t), t#pivot);
    Assert.assertTrue(Vec3.distanceSquared(moved, Vec3.v3(11.0, 2.0, 3.0)) < 1.0e-6)

/// toWorld を 2 段重ねた行列は、親の行列 × 子の行列と同じ。
@Test
def testTransform3dToWorldChainsParentTimesChild(): Unit \ Assert =
    let parent = leaningTransform();
    let child = { yaw = 0.5, pivot = Vec3.v3(0.0, 1.0, 0.0) | Transform3d.of(Vec3.v3(0.0, 3.0, 1.0)) };
    let chained = Transform3d.toWorld(Transform3d.toWorld(Mat4.identity(), parent), child);
    Assert.assertEq(expected = Mat4.toColumns(Mat4.mul(Transform3d.toMat4(parent), Transform3d.toMat4(child))),
                    Mat4.toColumns(chained))

// ════════════════════════════════════════════════════════════════════
// Camera3d
// ════════════════════════════════════════════════════════════════════

/// yaw 0・pitch 0 の目の真っ直ぐ前（+Z）の点は、200 × 100 の描き物の真ん中 (100, 50) に写る。
@Test
def testCamera3dPointStraightAheadMapsToCenter(): Unit \ Assert =
    let camera = cameraAt(Vec3.v3(0.0, 1.5, 0.0), 0.0);
    match Camera3d.worldToScreen(camera, { x = 200.0, y = 100.0 }, Vec3.v3(0.0, 1.5, 10.0)) {
        case Some(p) => Assert.assertTrue(Float64.abs(p#x - 100.0) < 0.001 and Float64.abs(p#y - 50.0) < 0.001)
        case None    => bug!("the point in front of the camera was not projected")
    }

/// yaw 0 で +X（東）にある点は、画面の右半分（x > 100）に写る。鏡写しになると左へ出る。
@Test
def testCamera3dPlusXAppearsOnRightAtYawZero(): Unit \ Assert =
    let camera = cameraAt(Vec3.zero(), 0.0);
    match Camera3d.worldToScreen(camera, { x = 200.0, y = 100.0 }, Vec3.v3(5.0, 0.0, 10.0)) {
        case Some(p) => Assert.assertTrue(p#x > 100.0)
        case None    => bug!("the point in front of the camera was not projected")
    }

/// yaw 90 度では +X（東）を向くので、東の点が真ん中 (100, 50) に写る。
@Test
def testCamera3dYawQuarterLooksEast(): Unit \ Assert =
    let camera = cameraAt(Vec3.zero(), Num.pi() / 2.0);
    match Camera3d.worldToScreen(camera, { x = 200.0, y = 100.0 }, Vec3.v3(10.0, 0.0, 0.0)) {
        case Some(p) => Assert.assertTrue(Float64.abs(p#x - 100.0) < 0.001 and Float64.abs(p#y - 50.0) < 0.001)
        case None    => bug!("the point east of the camera was not projected")
    }

/// 目の後ろの点は写らない。
@Test
def testCamera3dPointBehindIsNone(): Unit \ Assert =
    let camera = cameraAt(Vec3.zero(), 0.0);
    Assert.assertTrue(Option.isEmpty(Camera3d.worldToScreen(camera, { x = 200.0, y = 100.0 }, Vec3.v3(0.0, 0.0, -10.0))))

// ════════════════════════════════════════════════════════════════════
// Mesh3d
// ════════════════════════════════════════════════════════════════════

/// 別々に作った同じ中身のメッシュは、contentHash が同じ。
@Test
def testMesh3dSameContentSameHash(): Unit \ Assert =
    Assert.assertEq(expected = Mesh3d.contentHash(Mesh3d.fromPolygons(facingQuad() :: Nil)),
                    Mesh3d.contentHash(Mesh3d.fromPolygons(facingQuad() :: Nil)))

/// 頂点が 1 つだけ違えば contentHash が違う。
@Test
def testMesh3dOneVertexDiffersChangesHash(): Unit \ Assert =
    let moved = { points = Vec3.v3(-1.0, -1.0, 5.5) :: List.drop(1, facingQuad()#points) | facingQuad() };
    Assert.assertTrue(Mesh3d.contentHash(Mesh3d.fromPolygons(facingQuad() :: Nil)) !=
                      Mesh3d.contentHash(Mesh3d.fromPolygons(moved :: Nil)))

/// 四角 1 枚の OBJ は扇に割られて三角 2 枚になる。
@Test
def testMesh3dObjQuadBecomesTwoTriangles(): Unit \ Assert =
    let obj = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n";
    Assert.assertEq(expected = Ok(2), Mesh3d.fromObj(obj, "") |> Result.map(Mesh3d.triangleCount))

/// 範囲の外の番号・数で読めない v・面の無い字は、どれも Err。
@Test
def testMesh3dBrokenObjIsErr(): Unit \ Assert =
    let outOfRange = "v 0 0 0\nv 1 0 0\nv 1 1 0\nf 1 2 9\n";
    let badNumber = "v 0 zero 0\nv 1 0 0\nv 1 1 0\nf 1 2 3\n";
    let noFace = "v 0 0 0\nv 1 0 0\nv 1 1 0\n";
    Assert.assertEq(expected = (true, true, true),
                    (Result.isErr(Mesh3d.fromObj(outOfRange, "")), Result.isErr(Mesh3d.fromObj(badNumber, "")),
                     Result.isErr(Mesh3d.fromObj(noFace, ""))))

/// 外（原点の側）から見て時計回りの四角は、巻き方のまま扇に割られ（0,1,2 と 0,2,3）、法線が外（−Z）を向く。
@Test
def testMesh3dFromPolygonsKeepsClockwiseWindingFacingOut(): Unit \ Assert =
    let mesh = Mesh3d.fromPolygons(facingQuad() :: Nil);
    let firstNormal = Mesh3d.normals(mesh) |> Vector.take(3) |> Vector.toList;
    Assert.assertEq(expected = (0 :: 1 :: 2 :: 0 :: 2 :: 3 :: Nil, 0.0 :: 0.0 :: -1.0 :: Nil),
                    (Vector.toList(Mesh3d.indices(mesh)), firstNormal))

// ════════════════════════════════════════════════════════════════════
// Scene3d.pickLights
// ════════════════════════════════════════════════════════════════════

/// 点光源 9 本（目からの距離 9・1・2…8）から、目に近い 8 本（距離 1〜8）が元の並びの順で残る。
@Test
def testScene3dPickLightsKeepsEightNearest(): Unit \ Assert =
    let lights = pointLightAt(9.0) :: pointLightAt(1.0) :: pointLightAt(2.0) :: pointLightAt(3.0) :: pointLightAt(4.0) ::
                 pointLightAt(5.0) :: pointLightAt(6.0) :: pointLightAt(7.0) :: pointLightAt(8.0) :: Nil;
    let cmd = { pointLights = lights | Scene3d.scene(cameraAt(Vec3.zero(), 0.0), { x = 200.0, y = 100.0 }) };
    Assert.assertEq(expected = List.drop(1, lights) |> List.map(l -> Vec3.length(l#position)),
                    Scene3d.pickLights(Vec3.zero(), cmd)#pointLights |> List.map(l -> Vec3.length(l#position)))

/// 点光源 9 本・スポット 1 本の場面は、点光源を 1 本落とし（上限 8）、スポットは落とさない。知らせは点光源の 1 行だけ。
@Test
def testDroppedLightsCountsOnlyOverTheLimit(): Unit \ Assert =
    let lights = List.range(1, 10) |> List.map(i -> pointLightAt(Int32.toFloat64(i)));
    let cmd = { pointLights = lights, spotLights = Scene3d.spotLight(Vec3.zero(), { x = 0.0, y = 0.0, z = 1.0 }, 1.0) :: Nil
                | Scene3d.scene(cameraAt(Vec3.zero(), 0.0), { x = 200.0, y = 100.0 }) };
    let d = Scene3d.droppedLightsOf(cmd);
    Assert.assertEq(expected = (1, 0, "@lights:point" :: Nil), (d#points, d#spots, Scene3d.droppedLightsWarnings(cmd) |> List.map(fst)))

/// 点光源 10 本の場面と、スポットを上限より 2 本多く持つ場面の列: 落とす数の合計は点 2・スポット 2 で、
/// pickLights が実際に外した本数（描き手が描かない光）と同じ。
@Test
def testDroppedLightsOfScenesSumsWhatPickLightsDrops(): Unit \ Assert =
    let base = Scene3d.scene(cameraAt(Vec3.zero(), 0.0), { x = 200.0, y = 100.0 });
    let spot = Scene3d.spotLight(Vec3.zero(), { x = 0.0, y = 0.0, z = 1.0 }, 1.0);
    let points = { pointLights = List.range(1, 11) |> List.map(i -> pointLightAt(Int32.toFloat64(i))) | base };
    let spots = { spotLights = List.repeat(Scene3d.maxSpotLights() + 2, spot) | base };
    let cmds = (points :: spots :: Nil) |> List.map(c -> { at = Vec2.zero(), clip = None, scene = c });
    let removed = (pick: Scene3d.Scene3dCmd -> Int32) -> cmds |> List.foldLeft((acc, c) -> acc + pick(c#scene), 0);
    let removedPoints = removed(c -> List.length(c#pointLights) - List.length(Scene3d.pickLights(Vec3.zero(), c)#pointLights));
    let removedSpots = removed(c -> List.length(c#spotLights) - List.length(Scene3d.pickLights(Vec3.zero(), c)#spotLights));
    let d = Scene3d.droppedLightsOfScenes(cmds);
    Assert.assertEq(expected = ((2, 2), (2, 2)), ((d#points, d#spots), (removedPoints, removedSpots)))

// ════════════════════════════════════════════════════════════════════
// Scene3d.Material3d の中身の鍵（shaderHash）
// ════════════════════════════════════════════════════════════════════

def keyOf(m: Scene3d.Material3d): Int64 = force Scene3d.materialFieldsOf(m)#shaderHash

def glowShade(r: Float64): ShaderDoc.Shade = ShaderDoc.Shade.Solid(Color.rgb(r, 0.0, 0.0))

/// 同じ名前の材質でも emission の木が違えば鍵が違う（ゲームは名前を分けなくてよい）。
@Test
def testMaterialKeyFollowsEmissionTree(): Unit \ Assert =
    let base = Scene3d.material(ShaderDoc.demoSurface());
    Assert.assertEq(expected = false, keyOf(Scene3d.withEmission(glowShade(0.5), base)) == keyOf(Scene3d.withEmission(glowShade(0.9), base)))

/// emission を外す・名前を替えると鍵を求め直す（外した物は emission を付ける前と同じ鍵）。
@Test
def testMaterialKeyRecomputedOnEmissionAndName(): Unit \ Assert =
    let base = Scene3d.material(ShaderDoc.demoSurface());
    Assert.assertEq(expected = (true, false),
                    (keyOf(Scene3d.withoutEmission(Scene3d.withEmission(glowShade(0.5), base))) == keyOf(base),
                     keyOf(Scene3d.withSpecName("other", base)) == keyOf(base)))

/// params・cutout・wrap・blend・両面・法線マップは uniform か kind の側で渡すので、鍵は変わらない。
@Test
def testMaterialKeyIgnoresFieldsOutsideTheTree(): Unit \ Assert =
    let base = Scene3d.material(ShaderDoc.demoSurface());
    let changed = base |> Scene3d.withParams(Map#{"k" => 1.0}) |> Scene3d.withCutout(true) |> Scene3d.withWrap(Scene3d.Wrap.Clamp)
        |> Scene3d.withAlphaBlend(true) |> Scene3d.withDoubleSided(true) |> Scene3d.withNormalMap({ texture = "n", strength = 1.0 });
    Assert.assertEq(expected = keyOf(base), keyOf(changed))

// ════════════════════════════════════════════════════════════════════
// Scene3d.shadowMatrix
// ════════════════════════════════════════════════════════════════════

/// スポットライトの影の行列は、target の点を光の NDC の真ん中（x・y が 0）へ写す。
@Test
def testShadowMatrixCentersTarget(): Unit \ Assert =
    let spot = { range = 200.0 | Scene3d.spotLight({ x = 3.0, y = 40.0, z = -7.0 }, { x = 10.0, y = 0.0, z = 5.0 }, 1.2) };
    let ndc = Mat4.applyPerspective(Scene3d.shadowMatrix(spot), spot#target);
    Assert.assertTrue(ndc |> Option.exists(q -> Float64.abs(q#x) < 0.000001 and Float64.abs(q#y) < 0.000001))

// ════════════════════════════════════════════════════════════════════
// Scene3d.spotConeOf
// ════════════════════════════════════════════════════════════════════

/// 縦の画角 1.0 のスポットの、innerFovY ごとの円錐の縁の cos。
def coneWith(innerFovY: Option[Float64]): (Float64, Float64) =
    let edge = Scene3d.spotConeOf({ innerFovY = innerFovY | Scene3d.spotLight(Vec3.zero(), Vec3.v3(0.0, 0.0, 1.0), 1.0) });
    (edge#outerCos, edge#innerCos)

/// None は fovY × 0.8（半角 0.4）・Some(0.6) は半角 0.3。外側はどちらも半角 0.5。
@Test
def testSpotConeOfNoneAndSome(): Unit \ Assert =
    Assert.assertEq(expected = ((Num.cos(0.5), Num.cos(0.4)), (Num.cos(0.5), Num.cos(0.3))),
                    (coneWith(None), coneWith(Some(0.6))))

/// fovY を超える角は fovY に直り、内と外が同じ cos になるので内側に 1e-6 を足す（smoothstep の両端を分ける）。
@Test
def testSpotConeOfClampsWiderInnerToFovY(): Unit \ Assert =
    Assert.assertEq(expected = (Num.cos(0.5), Num.cos(0.5) + 0.000001), coneWith(Some(2.0)))

/// 負と NaN は 0 に直る（内側の cos = cos 0 = 1。縁は円錐の真ん中から外まで続く）。
@Test
def testSpotConeOfNegativeAndNanBecomeZero(): Unit \ Assert =
    Assert.assertEq(expected = (1.0, 1.0), (snd(coneWith(Some(-1.0))), snd(coneWith(Some(Float64.nan())))))

// ════════════════════════════════════════════════════════════════════
// metallic と roughness（Scene3d.withMetallicRoughness）
// ════════════════════════════════════════════════════════════════════

def plainMaterial(): Scene3d.Material3d = Scene3d.material(ShaderDoc.demoSurface())

/// 値は 0..1 に丸める（NaN は 0）。
@Test
def testMetallicRoughnessIsClampedToUnit(): Unit \ Assert =
    let read = (m: Float64, r: Float64) -> Scene3d.metallicRoughnessOf(Scene3d.withMetallicRoughness(m, r, plainMaterial()))
        |> Option.map(mr -> (mr#metallic, mr#roughness));
    Assert.assertEq(expected = (Some((1.0, 0.0)), Some((0.0, 1.0)), Some((0.25, 0.5))),
                    (read(1.5, -0.2), read(Float64.nan(), 7.0), read(0.25, 0.5)))

/// 付けていない材質は None。
@Test
def testPlainMaterialHasNoMetallicRoughness(): Unit \ Assert =
    Assert.assertEq(expected = false, Option.nonEmpty(Scene3d.metallicRoughnessOf(plainMaterial())))

/// 付ける・外すで鍵が変わる。外した物は付ける前と同じ鍵（持たない材質の鍵は今と同じ）。
@Test
def testMaterialKeyFollowsMetallicRoughness(): Unit \ Assert =
    let base = plainMaterial();
    let glossy = Scene3d.withMetallicRoughness(1.0, 0.25, base);
    Assert.assertEq(expected = (false, true),
                    (keyOf(base) == keyOf(glossy), keyOf(Scene3d.withoutMetallicRoughness(glossy)) == keyOf(base)))

/// metallic と roughness の値は params の側で渡すので、値だけ違う材質は同じ鍵（同じプログラム）。絵を足すと鍵が変わる。
@Test
def testMaterialKeyIgnoresMetallicRoughnessValues(): Unit \ Assert =
    let base = plainMaterial();
    let a = Scene3d.withMetallicRoughness(0.1, 0.2, base);
    let b = Scene3d.withMetallicRoughness(0.9, 0.8, base);
    Assert.assertEq(expected = (true, false),
                    (keyOf(a) == keyOf(b), keyOf(a) == keyOf(Scene3d.withMetallicRoughnessTexture("tex3d:orm", a))))

/// 値は params に入り、withParams で params を替えても残る。外すと params からも消える。
@Test
def testMetallicRoughnessSurvivesWithParams(): Unit \ Assert =
    let glossy = Scene3d.withMetallicRoughness(0.5, 0.25, plainMaterial()) |> Scene3d.withParams(Map#{"k" => 1.0});
    let params = Scene3d.materialFieldsOf(glossy)#params;
    let dropped = Scene3d.materialFieldsOf(Scene3d.withoutMetallicRoughness(glossy))#params;
    Assert.assertEq(expected = (Some(0.5), Some(0.25), Some(1.0), None),
                    (Map.get(Scene3d.pbrParamMetallic(), params), Map.get(Scene3d.pbrParamRoughness(), params), Map.get("k", params),
                     Map.get(Scene3d.pbrParamMetallic(), dropped)))

/// 値を後から替えても絵は残る。絵だけ付けると係数は 1・1。
@Test
def testTextureKeepsFactors(): Unit \ Assert =
    let textured = Scene3d.withMetallicRoughnessTexture("tex3d:orm", plainMaterial());
    let rewritten = Scene3d.withMetallicRoughness(0.3, 0.6, textured);
    Assert.assertEq(expected = (Some((1.0, 1.0, Some("tex3d:orm"))), Some((0.3, 0.6, Some("tex3d:orm")))),
                    (Scene3d.metallicRoughnessOf(textured) |> Option.map(mr -> (mr#metallic, mr#roughness, mr#texture)),
                     Scene3d.metallicRoughnessOf(rewritten) |> Option.map(mr -> (mr#metallic, mr#roughness, mr#texture))))

/// 絵は Scene3d.textureNamesOf に入る（描き出しの鍵が絵の中身を読む）。
@Test
def testTextureNamesIncludeTheMetallicRoughnessTexture(): Unit \ Assert =
    let m = Scene3d.withMetallicRoughnessTexture("tex3d:orm", plainMaterial());
    Assert.assertEq(expected = true, List.memberOf("tex3d:orm", Scene3d.textureNamesOf(Scene3d.meshInstance(Mesh3d.fromPolygons(Nil), Mat4.identity()) |> Scene3d.withMaterial(m))))
