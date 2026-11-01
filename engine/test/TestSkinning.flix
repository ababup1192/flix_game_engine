// TestSkinning — ジョイントのアニメーションの純粋な部品（Quat・Mat4.inverse / ofColumns・AnimationClip3d・Pose3d・
// Mesh3d.fromArrays の重み・Scene3d.skinningOf）。キーフレームの間の値・ループの回し方・親から子への重なりを確かめる。

// ════════════════════════════════════════════════════════════════════
// 共通
// ════════════════════════════════════════════════════════════════════

/// 2 つの四元数の成分の差の合計が小さい。
def quatNear(a: Quat.Quat, b: Quat.Quat): Bool =
    Float64.abs(a#x - b#x) + Float64.abs(a#y - b#y) + Float64.abs(a#z - b#z) + Float64.abs(a#w - b#w) < 1.0e-9

/// 2 つの行列の成分の差の合計が小さい。
def matNear(a: Mat4.Mat4, b: Mat4.Mat4): Bool =
    Vector.zip(Mat4.toColumns(a), Mat4.toColumns(b)) |> Vector.foldLeft((acc, pair) -> acc + Float64.abs(fst(pair) - snd(pair)), 0.0) < 1.0e-9

def vecNear(a: Vec3.Vec3, b: Vec3.Vec3): Bool = Vec3.distanceSquared(a, b) < 1.0e-12

/// 平行移動だけの姿勢。
def poseAt(t: Vec3.Vec3): Skin3d.JointPose = { translation = t, rotation = Quat.identity(), scale = Vec3.one() }

/// Y 軸まわりに 90 度回す四元数（+Z が +X へ回る）。
def quarterTurnY(): Quat.Quat = { x = 0.0, y = Vec2.sqrt(0.5), z = 0.0, w = Vec2.sqrt(0.5) }

def okOrBug(r: Result[String, a]): a = match r {
    case Ok(v) => v
    case Err(e) => bug!(e)
}

/// ジョイント 1 本（原点・回さない）のスキン。
def oneJointSkin(): Skin3d.Skin3d =
    okOrBug(Skin3d.make({ names = Vector#{ "root" }, parents = Vector#{ -1 }, rest = Vector#{ poseAt(Vec3.zero()) },
                          inverseBinds = None, rootTransform = Mat4.identity() }))

/// 根（(0, 1, 0)）と、根から +Z へ 1 の子のスキン（逆バインド行列はレストポーズから）。
def twoJointSkin(): Skin3d.Skin3d =
    okOrBug(Skin3d.make({ names = Vector#{ "root", "child" }, parents = Vector#{ -1, 0 },
                          rest = Vector#{ poseAt(Vec3.v3(0.0, 1.0, 0.0)), poseAt(Vec3.v3(0.0, 0.0, 1.0)) },
                          inverseBinds = None, rootTransform = Mat4.identity() }))

/// ジョイント 0 の平行移動の欄（Linear）。
def moveChannel(times: Vector[Float64], xs: Vector[Float64]): AnimationClip3d.Channel =
    { joint = 0, path = AnimationClip3d.Path.Translation, times = times,
      values = Vector.flatMap(x -> Vector#{ x, 0.0, 0.0 }, xs), interpolation = AnimationClip3d.Interpolation.Linear }

/// 時刻 0・1・2 で x が 0・10・30 へ動くクリップ。
def moveClip(): AnimationClip3d.AnimationClip3d =
    okOrBug(AnimationClip3d.make("move", moveChannel(Vector#{ 0.0, 1.0, 2.0 }, Vector#{ 0.0, 10.0, 30.0 }) :: Nil))

/// ジョイント 0 の x を、時刻 t で読む。
def sampledX(clip: AnimationClip3d.AnimationClip3d, t: Float64, loop: Bool): Float64 =
    Vector.get(0, AnimationClip3d.sample(oneJointSkin(), clip, t, loop))#translation#x

/// 三角 1 枚の形（頂点 3 つ）に重みを付ける。
def skinnedTriangle(joints: Vector[Int32], weights: Vector[Float64]): Result[String, Mesh3d.Mesh3d] =
    Mesh3d.fromArrays({ positions = Vector#{ 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0 },
                        normals = Vector#{ 0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, -1.0 },
                        colors = Vector#{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 },
                        indices = Vector#{ 0, 1, 2 },
                        skin = Some({ joints = joints, weights = weights }) })

/// 3 頂点とも同じジョイントに重み 1 の三角。
def triangleOnJoint(j: Int32): Mesh3d.Mesh3d =
    okOrBug(skinnedTriangle(Vector#{ j, 0, 0, 0, j, 0, 0, 0, j, 0, 0, 0 },
                            Vector#{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 }))

/// skinningOf が返した Pose のジョイントの数（None なら None）。
def skinningJointCount(i: Scene3d.Instance3d): Option[Int32] = Scene3d.skinningOf(i) |> Option.map(Pose3d.jointCount)

// ════════════════════════════════════════════════════════════════════
// Quat
// ════════════════════════════════════════════════════════════════════

/// slerp の t = 0 は a そのもの。
@Test
def testQuatSlerpAtZeroIsStart(): Unit \ Assert =
    Assert.assertTrue(quatNear(Quat.slerp(Quat.identity(), quarterTurnY(), 0.0), Quat.identity()))

/// slerp の t = 1 は b そのもの。
@Test
def testQuatSlerpAtOneIsEnd(): Unit \ Assert =
    Assert.assertTrue(quatNear(Quat.slerp(Quat.identity(), quarterTurnY(), 1.0), quarterTurnY()))

/// b を符号ごと反転（同じ 90 度の回転）しても、真ん中は短い側の 45 度。+Z は (sin 45°, 0, cos 45°) へ行く
/// （長い側を通ると 135 度回って z が負になる）。
@Test
def testQuatSlerpTakesShortArcWhenDotIsNegative(): Unit \ Assert =
    let q = quarterTurnY();
    let flipped = { x = 0.0 - q#x, y = 0.0 - q#y, z = 0.0 - q#z, w = 0.0 - q#w };
    let moved = Mat4.apply(Quat.toMat4(Quat.slerp(Quat.identity(), flipped, 0.5)), Vec3.v3(0.0, 0.0, 1.0));
    Assert.assertTrue(vecNear(moved, Vec3.v3(Vec2.sqrt(0.5), 0.0, Vec2.sqrt(0.5))))

/// Y 軸まわり 90 度の四元数の行列は Mat4.rotateY(π/2) と同じ（+Z が +X へ回る約束）。
@Test
def testQuatToMat4MatchesRotateY(): Unit \ Assert =
    Assert.assertTrue(matNear(Quat.toMat4(quarterTurnY()), Mat4.rotateY(Vec2.pi() / 2.0)))

// ════════════════════════════════════════════════════════════════════
// Mat4.inverse・ofColumns
// ════════════════════════════════════════════════════════════════════

/// 平行移動・回転・倍率を重ねた行列に逆行列を掛けると単位行列。
@Test
def testMat4InverseTimesMatrixIsIdentity(): Unit \ Assert =
    let m = Mat4.mul(Mat4.translate(Vec3.v3(1.0, 2.0, 3.0)), Mat4.mul(Mat4.rotateY(0.5), Mat4.scale(Vec3.v3(2.0, 3.0, 4.0))));
    let product = Mat4.inverse(m) |> Option.map(inv -> Mat4.mul(m, inv));
    Assert.assertTrue(Option.exists(p -> matNear(p, Mat4.identity()), product))

/// 1 軸を 0 に潰した行列には逆行列が無い。
@Test
def testMat4InverseOfFlattenedMatrixIsNone(): Unit \ Assert =
    Assert.assertTrue(Option.isEmpty(Mat4.inverse(Mat4.scale(Vec3.v3(1.0, 0.0, 1.0)))))

/// ofColumns は toColumns の逆（列優先の並びを取り違えると平行移動が下の行へ行く）。
@Test
def testMat4OfColumnsRoundTripsToColumns(): Unit \ Assert =
    let m = Mat4.translate(Vec3.v3(1.0, 2.0, 3.0));
    Assert.assertEq(expected = Ok(Mat4.toColumns(m)), Mat4.ofColumns(Mat4.toColumns(m)) |> Result.map(Mat4.toColumns))

/// 数が 16 でなければ Err。
@Test
def testMat4OfColumnsRejectsWrongLength(): Unit \ Assert =
    Assert.assertTrue(Result.isErr(Mat4.ofColumns(Vector.range(0, 15) |> Vector.map(Int32.toFloat64))))

// ════════════════════════════════════════════════════════════════════
// AnimationClip3d
// ════════════════════════════════════════════════════════════════════

/// キーフレームの時刻ちょうど（1 秒）はその値（10）。
@Test
def testClipSampleAtKeyTimeIsKeyValue(): Unit \ Assert =
    Assert.assertEq(expected = 10.0, sampledX(moveClip(), 1.0, false))

/// 0 秒（0）と 1 秒（10）の真ん中は 5。
@Test
def testClipSampleBetweenKeysIsMidway(): Unit \ Assert =
    Assert.assertEq(expected = 5.0, sampledX(moveClip(), 0.5, false))

/// loop なら 2.5 秒は長さ 2 で回って 0.5 秒（5）。
@Test
def testClipSampleLoopWrapsByDuration(): Unit \ Assert =
    Assert.assertEq(expected = 5.0, sampledX(moveClip(), 2.5, true))

/// loop でなければ最後のキーフレーム（30）で止まる。
@Test
def testClipSampleWithoutLoopHoldsLastKey(): Unit \ Assert =
    Assert.assertEq(expected = 30.0, sampledX(moveClip(), 2.5, false))

/// 最初のキーフレーム（1 秒で 10）より前は最初の値。
@Test
def testClipSampleBeforeFirstKeyIsFirstValue(): Unit \ Assert =
    let clip = okOrBug(AnimationClip3d.make("late", moveChannel(Vector#{ 1.0, 2.0 }, Vector#{ 10.0, 20.0 }) :: Nil));
    Assert.assertEq(expected = 10.0, sampledX(clip, 0.0, false))

/// キーフレームが 1 つ（1 秒で 7）の欄は、いつでもその値。
@Test
def testClipSampleSingleKeyIsConstant(): Unit \ Assert =
    let clip = okOrBug(AnimationClip3d.make("one", moveChannel(Vector#{ 1.0 }, Vector#{ 7.0 }) :: Nil));
    Assert.assertEq(expected = 7.0, sampledX(clip, 5.0, false))

/// 長さ 0 のクリップを loop で読んでも 0 秒の値（0 で割らない）。
@Test
def testClipSampleLoopWithZeroDurationReadsTimeZero(): Unit \ Assert =
    let clip = okOrBug(AnimationClip3d.make("still", moveChannel(Vector#{ 0.0 }, Vector#{ 7.0 }) :: Nil));
    Assert.assertEq(expected = 7.0, sampledX(clip, 3.0, true))

/// Step は次のキーフレームまで前の値のまま（0.5 秒でも 0）。
@Test
def testClipSampleStepHoldsPreviousKey(): Unit \ Assert =
    let ch = { interpolation = AnimationClip3d.Interpolation.Step | moveChannel(Vector#{ 0.0, 1.0 }, Vector#{ 0.0, 10.0 }) };
    let clip = okOrBug(AnimationClip3d.make("step", ch :: Nil));
    Assert.assertEq(expected = 0.0, sampledX(clip, 0.5, false))

/// 回転の欄だけのクリップでは、平行移動はレストポーズ（根が (0, 1, 0)）のまま。
@Test
def testClipSampleKeepsRestPoseForUnkeyedPath(): Unit \ Assert =
    let q = quarterTurnY();
    let ch = { joint = 0, path = AnimationClip3d.Path.Rotation, times = Vector#{ 0.0 }, values = Vector#{ q#x, q#y, q#z, q#w },
               interpolation = AnimationClip3d.Interpolation.Linear };
    let clip = okOrBug(AnimationClip3d.make("turn", ch :: Nil));
    let t = Vector.get(0, AnimationClip3d.sample(twoJointSkin(), clip, 0.0, false))#translation;
    Assert.assertEq(expected = (0.0, 1.0, 0.0), (t#x, t#y, t#z))

/// スキンの数（1 本）を超えるジョイントの欄は捨てられ、ジョイントの数だけの姿勢が返る。
@Test
def testClipSampleDropsChannelBeyondSkin(): Unit \ Assert =
    let clip = okOrBug(AnimationClip3d.make("far", { joint = 5 | moveChannel(Vector#{ 0.0 }, Vector#{ 7.0 }) } :: Nil));
    let poses = AnimationClip3d.sample(oneJointSkin(), clip, 0.0, false);
    Assert.assertEq(expected = (1, 0.0), (Vector.length(poses), Vector.get(0, poses)#translation#x))

/// duration は全部の欄の最後のキーフレームの時刻の最大（2 秒の欄と 3 秒の欄で 3）。
@Test
def testClipDurationIsLatestKeyOfAllChannels(): Unit \ Assert =
    let clip = okOrBug(AnimationClip3d.make("two", moveChannel(Vector#{ 0.0, 2.0 }, Vector#{ 0.0, 1.0 }) ::
                                                   moveChannel(Vector#{ 1.0, 3.0 }, Vector#{ 0.0, 1.0 }) :: Nil));
    Assert.assertEq(expected = 3.0, AnimationClip3d.duration(clip))

/// times が増える順でない欄は Err。
@Test
def testClipMakeRejectsDecreasingTimes(): Unit \ Assert =
    Assert.assertTrue(Result.isErr(AnimationClip3d.make("bad", moveChannel(Vector#{ 1.0, 0.0 }, Vector#{ 0.0, 1.0 }) :: Nil)))

// ════════════════════════════════════════════════════════════════════
// Skin3d・Pose3d
// ════════════════════════════════════════════════════════════════════

/// 親が子より後ろの並びは Err。
@Test
def testSkinMakeRejectsParentAfterChild(): Unit \ Assert =
    let r = Skin3d.make({ names = Vector#{ "child", "root" }, parents = Vector#{ 1, -1 },
                          rest = Vector#{ poseAt(Vec3.zero()), poseAt(Vec3.zero()) }, inverseBinds = None, rootTransform = Mat4.identity() });
    Assert.assertTrue(Result.isErr(r))

/// レストポーズのままなら joint 行列は全部単位行列（逆バインド行列をレストポーズから求めたスキン）。
@Test
def testPoseRestPoseJointMatricesAreIdentity(): Unit \ Assert =
    let skin = twoJointSkin();
    let mats = Pose3d.jointMatrices(Pose3d.compute(skin, Skin3d.restPose(skin)));
    Assert.assertTrue(Vector.forAll(m -> matNear(m, Mat4.identity()), mats))

/// 根を Y 軸まわりに 90 度回すと、根から +Z へ 1 の子は +X へ 1 の所（根 (0, 1, 0) から (1, 1, 0)）へ来る。
@Test
def testPoseRotatingParentMovesChild(): Unit \ Assert =
    let skin = twoJointSkin();
    let local = Vector#{ { rotation = quarterTurnY() | poseAt(Vec3.v3(0.0, 1.0, 0.0)) }, poseAt(Vec3.v3(0.0, 0.0, 1.0)) };
    let childAt = Mat4.apply(Pose3d.jointTransform(Pose3d.compute(skin, local), 1), Vec3.zero());
    Assert.assertTrue(vecNear(childAt, Vec3.v3(1.0, 1.0, 0.0)))

/// blend の t = 0 は a の姿勢（x = 0）。
@Test
def testPoseBlendAtZeroIsFirst(): Unit \ Assert =
    let mixed = Pose3d.blend(Vector#{ poseAt(Vec3.v3(0.0, 0.0, 0.0)) }, Vector#{ poseAt(Vec3.v3(10.0, 0.0, 0.0)) }, 0.0);
    Assert.assertEq(expected = 0.0, Vector.get(0, mixed)#translation#x)

/// blend の t = 1 は b の姿勢（x = 10）。
@Test
def testPoseBlendAtOneIsSecond(): Unit \ Assert =
    let mixed = Pose3d.blend(Vector#{ poseAt(Vec3.v3(0.0, 0.0, 0.0)) }, Vector#{ poseAt(Vec3.v3(10.0, 0.0, 0.0)) }, 1.0);
    Assert.assertEq(expected = 10.0, Vector.get(0, mixed)#translation#x)

// ════════════════════════════════════════════════════════════════════
// Mesh3d.fromArrays
// ════════════════════════════════════════════════════════════════════

/// 重みは足して 1 に直る（1・1 → 0.5・0.5）。
@Test
def testMeshFromArraysNormalizesWeights(): Unit \ Assert =
    let mesh = skinnedTriangle(Vector#{ 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0 },
                               Vector#{ 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0 });
    Assert.assertEq(expected = Ok(Some(Vector#{ 0.5, 0.5, 0.0, 0.0, 0.5, 0.5, 0.0, 0.0, 0.5, 0.5, 0.0, 0.0 })),
                    Result.map(Mesh3d.skinWeights, mesh))

/// 重みの合計が 0 の頂点があれば Err。
@Test
def testMeshFromArraysRejectsZeroWeights(): Unit \ Assert =
    let mesh = skinnedTriangle(Vector#{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                               Vector#{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 });
    Assert.assertTrue(Result.isErr(mesh))

/// ジョイントの番号が上限（64 本 → 0〜63）の外なら Err。
@Test
def testMeshFromArraysRejectsJointBeyondLimit(): Unit \ Assert =
    let mesh = skinnedTriangle(Vector#{ Skin3d.maxJoints(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                               Vector#{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 });
    Assert.assertTrue(Result.isErr(mesh))

/// 法線だけが違う形は contentHash も違う（GL が頂点バッファを取り違えない）。
@Test
def testMeshFromArraysHashSeesNormals(): Unit \ Assert =
    let flat = (n: Float64) -> Mesh3d.fromArrays({
        positions = Vector#{ 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0 },
        normals = Vector#{ 0.0, 0.0, n, 0.0, 0.0, n, 0.0, 0.0, n },
        colors = Vector#{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 },
        indices = Vector#{ 0, 1, 2 }, skin = None }) |> Result.map(Mesh3d.contentHash);
    Assert.assertTrue(flat(1.0) != flat(-1.0))

// ════════════════════════════════════════════════════════════════════
// Scene3d.skinningOf
// ════════════════════════════════════════════════════════════════════

/// pose を渡していなければ曲げない。
@Test
def testSkinningOfWithoutPoseIsNone(): Unit \ Assert =
    Assert.assertEq(expected = None, skinningJointCount(Scene3d.meshInstance(triangleOnJoint(1), Mat4.identity())))

/// ジョイントの重みの無い形は pose を無視する。
@Test
def testSkinningOfIgnoresPoseOnUnskinnedMesh(): Unit \ Assert =
    let skin = twoJointSkin();
    let plain = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Nil,
                                      color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
    let i = Scene3d.meshInstance(plain, Mat4.identity()) |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin)));
    Assert.assertEq(expected = None, skinningJointCount(i))

/// 形のジョイントの番号（1）が Pose の数（2 本）に収まれば、その Pose で曲げる。
@Test
def testSkinningOfUsesPoseWhenJointsFit(): Unit \ Assert =
    let skin = twoJointSkin();
    let i = Scene3d.meshInstance(triangleOnJoint(1), Mat4.identity()) |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin)));
    Assert.assertEq(expected = Some(2), skinningJointCount(i))

/// 形のジョイントの番号（2）が Pose の数（2 本）以上なら、曲げずに知らせる文を返す。
@Test
def testSkinningOfFallsBackWhenJointsExceedPose(): Unit \ Assert =
    let skin = twoJointSkin();
    let i = Scene3d.meshInstance(triangleOnJoint(2), Mat4.identity()) |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin)));
    Assert.assertEq(expected = (None, true), (skinningJointCount(i), Option.nonEmpty(Scene3d.skinningWarning(i))))
