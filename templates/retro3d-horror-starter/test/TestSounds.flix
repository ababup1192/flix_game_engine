// 音の大きさの決まり: 距離での聞こえ方（Sounds.gainAt）と、バスの大きさ（Sounds.mixer）。期待値は sound.kind.json の既定（SoundDoc.defaults）から導く。
mod TestSounds {
    use fge::{AudioMixer, Vec2, Vec3, Yarn}

    /// 1 階の床だけの表と、engine の (0, 1, 0) の窓の月明かり 1 つ（glTF の座標なので x は反転しても 0）。
    def layout(): Layout.Layout =
        Layout.fromJson("{\"floors\":[{\"index\":1,\"y\":0,\"colliders\":[{\"min\":[-30,-0.2,-30],\"max\":[30,0,30]}]}]," +
                        "\"lights\":[{\"type\":\"moon\",\"floor\":1,\"pos\":[0,1,0]}],\"spawn\":{\"pos\":[0,0,0],\"yaw\":0}}")
            |> Result.getWithDefault(Layout.empty())

    def res(): Res.Res =
        Res.build({ walk = WalkDoc.defaults(), keys = KeysDoc.defaults(), look = LookDoc.defaults(), sound = SoundDoc.defaults(), layout = layout(),
                    assets = { floors = Map.empty(), props = Map.empty(), surfaces = Map.empty() }, items = ItemsDoc.defaults(),
                    cast = CastDoc.defaults(), people = Map.empty(), dialogue = Yarn.empty(), bundles = Nil, bundlePending = Res.nothingPending(), modelPending = Res.nothingPending() })

    def doc(): SoundDoc.Rec = SoundDoc.rec(SoundDoc.defaults())

    /// 足元 (x, 0, z) に立ち、最後に鳴らした戸口が door の World。
    def standing(x: Float64, z: Float64, door: Option[Vec3.Vec3]): World.World =
        let r = res();
        { doorAt = door | World.placeAt(r, Vec3.v3(x, 0.0, z), 0.0, World.initial(r)) }

    def busVolume(name: String, w: World.World): Float64 = AudioMixer.getBus(Sounds.mixer(res(), w), name)#volume

    def round3(v: Float64): Float64 = Float64.round(v * 1000.0) / 1000.0

    @Test
    def testFullVolumeWithinNear(): Unit \ Assert =
        let f = doc()#clockFalloff;
        Assert.assertEq(expected = 1.0, Sounds.gainAt(f, f#near))

    @Test
    def testSilentAtFar(): Unit \ Assert =
        let f = doc()#clockFalloff;
        Assert.assertEq(expected = 0.0, Sounds.gainAt(f, f#far))

    @Test
    def testHalfwayFollowsTheCurve(): Unit \ Assert =
        let f = doc()#doorFalloff;
        let half = (f#near + f#far) / 2.0;
        Assert.assertEq(expected = round3(Float64.pow(base = 0.5, f#curve)), round3(Sounds.gainAt(f, half)))

    @Test
    def testFootstepsAreTheLoudest(): Unit \ Assert =
        let d = doc();
        Assert.assertTrue(List.forAll(v -> v < d#step, d#ambience :: d#wind :: d#door :: d#clock :: d#paper :: Nil))

    @Test
    def testStepBusUsesTheDocVolume(): Unit \ Assert =
        Assert.assertEq(expected = doc()#step, busVolume("step", standing(5.0, 5.0, None)))

    def walkDoc(): WalkDoc.Rec = WalkDoc.rec(WalkDoc.defaults())

    /// 開けた床の (0, 0, 0) から走るキーを押したまま 1 秒（0.1 秒 × 10 コマ）前へ進んだ World。
    def dashedOneSecond(): World.World =
        let r = res();
        let input = { forward = 1.0, strafe = 0.0, turn = 0.0, pitch = 0.0, look = Vec2.zero(), dash = true, active = true };
        let start = World.placeAt(r, Vec3.v3(0.0, 0.0, 0.0), 0.0, World.initial(r));
        World.step(r, input, 0.1, World.step(r, input, 0.1, World.step(r, input, 0.1, World.step(r, input, 0.1, World.step(r, input, 0.1,
            World.step(r, input, 0.1, World.step(r, input, 0.1, World.step(r, input, 0.1, World.step(r, input, 0.1, World.step(r, input, 0.1, start))))))))))

    @Test
    def testStepBusIsLouderWhileDashing(): Unit \ Assert =
        // 走っている間の足音のバスは Doc の dashStep。
        Assert.assertEq(expected = doc()#dashStep, busVolume("step", dashedOneSecond()))

    @Test
    def testDashingStepsComeEveryDashStride(): Unit \ Assert =
        // 1 秒走ると dashSpeed m 進み、足音は dashStride m ごとなので dashSpeed ÷ dashStride 歩を踏む。
        Assert.assertEq(expected = round3(walkDoc()#dashSpeed / walkDoc()#dashStride), round3(World.stepsOf(dashedOneSecond())))

    @Test
    def testDoorIsFullAtTheDoorway(): Unit \ Assert =
        Assert.assertEq(expected = doc()#door, busVolume("door", standing(5.0, 5.0, Some(Vec3.v3(5.0, 0.0, 5.0)))))

    @Test
    def testDoorFadesAwayFromTheDoorway(): Unit \ Assert =
        let far = doc()#doorFalloff#far;
        Assert.assertEq(expected = 0.0, busVolume("door", standing(far + 1.0, 0.0, Some(Vec3.v3(0.0, 0.0, 0.0)))))

    @Test
    def testWindIsFullNextToTheWindow(): Unit \ Assert =
        Assert.assertEq(expected = doc()#wind, busVolume("wind", standing(0.5, 0.0, None)))

    @Test
    def testWindIsSilentFarFromWindows(): Unit \ Assert =
        Assert.assertEq(expected = 0.0, busVolume("wind", standing(doc()#windFalloff#far + 1.0, 0.0, None)))

    @Test
    def testSynthesizedSoundsNeverClip(): Unit \ Assert =
        Assert.assertTrue(SfxRender.loudestPeak() < 1.0)

    @Test
    def testSynthesizesEverySoundTheGamePlays(): Unit \ Assert =
        Assert.assertEq(expected = Set#{"step_0", "step_1", "step_2", "step_3", "step_4", "step_5", "door_classroom", "door_old", "door_rattle",
                                        "door_unlock", "clock", "amb_quiet", "wind", "pickup", "paper"}, SfxRender.names())
}
