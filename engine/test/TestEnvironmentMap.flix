// 環境マップの約束（向き → 絵の座標・段・Scene3d の口）。座標の約束: X = 東・Y = 上・Z = 北。
mod TestEnvironmentMap {

    def near(expected: Float64, actual: Float64): Bool = Float64.abs(expected - actual) < 1.0e-9

    def uvNear(expected: (Float64, Float64), d: Vec3.Vec3): Bool =
        let (u, v) = LightModel3d.environmentUvOf(d);
        near(fst(expected), u) and near(snd(expected), v)

    /// 絵の真ん中（0.5, 0.5）が −Z（南）。
    @Test
    def testUvOfMinusZIsTheCenter(): Unit \ Assert =
        Assert.assertTrue(uvNear((0.5, 0.5), Vec3.v3(0.0, 0.0, -1.0)))

    /// u = 0.75 が +X（東）・u = 0.25 が −X（西）。
    @Test
    def testUvOfEastAndWest(): Unit \ Assert =
        Assert.assertTrue(uvNear((0.75, 0.5), Vec3.v3(1.0, 0.0, 0.0)) and uvNear((0.25, 0.5), Vec3.v3(-1.0, 0.0, 0.0)))

    /// v = 0 が真上・v = 1 が真下（絵の上の行が空）。極の u は 0.5。
    @Test
    def testUvOfUpAndDown(): Unit \ Assert =
        Assert.assertTrue(uvNear((0.5, 0.0), Vec3.v3(0.0, 1.0, 0.0)) and uvNear((0.5, 1.0), Vec3.v3(0.0, -1.0, 0.0)))

    /// 継ぎ目は +Z（北）で、東寄りの向きは u が 1 の少し手前・西寄りは 0 の少し先（値は 1 を挟んで連続する）。
    @Test
    def testUvSeamIsContinuousAcrossPlusZ(): Unit \ Assert =
        let (ue, _) = LightModel3d.environmentUvOf(Vec3.v3(0.001, 0.0, 1.0));
        let (uw, _) = LightModel3d.environmentUvOf(Vec3.v3(-0.001, 0.0, 1.0));
        Assert.assertTrue(near(1.0 - 0.001 / (2.0 * 3.141592653589793), ue) and near(0.001 / (2.0 * 3.141592653589793), uw))

    /// 段は roughness × 最後の段（段が 1 つなら 0）。
    @Test
    def testLodScalesWithRoughnessToTheLastLevel(): Unit \ Assert =
        Assert.assertTrue(near(0.0, LightModel3d.environmentLodOf(0.0, 12)) and near(5.5, LightModel3d.environmentLodOf(0.5, 12))
                          and near(11.0, LightModel3d.environmentLodOf(1.0, 12)) and near(0.0, LightModel3d.environmentLodOf(1.0, 1)))

    def sample(): Texture3d.Texture3d =
        match Texture3d.fromArgb(2, 1, Vector#{ Int32.bitwiseOr(-16777216, 0x804020), Int32.bitwiseOr(-16777216, 0x204080) }) {
            case Ok(t)  => t
            case Err(_) => bug!("TestEnvironmentMap: 絵が作れない")
        }

    /// 既定は強さ 1・箱なし・背景には描かない。環境マップの無い場面は None。
    @Test
    def testDefaults(): Unit \ Assert =
        let f = Scene3d.environmentMapFieldsOf(Scene3d.environmentMap(sample()));
        let scene = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }, Vec2.zero());
        Assert.assertTrue(f#intensity == 1.0 and Option.isEmpty(f#box) and not f#asBackground and f#texture == Texture3d.name(sample()) and Option.isEmpty(scene#environmentMap))

    /// 強さの負・NaN・無限は 0 として描く。
    @Test
    def testIntensityOfBadValuesIsZero(): Unit \ Assert =
        let of = (k: Float64) -> Scene3d.environmentIntensityOf(Scene3d.environmentMap(sample()) |> Scene3d.withEnvironmentIntensity(k));
        Assert.assertTrue(of(-1.0) == 0.0 and of(Float64.nan()) == 0.0 and of(1.0 / 0.0) == 0.0 and of(0.5) == 0.5)

    /// 箱の min と max は軸ごとに小さい方を min にそろえる。
    @Test
    def testBoxIsSortedPerAxis(): Unit \ Assert =
        let b = Scene3d.environmentBoxOf({ min = Vec3.v3(4.0, 0.0, -4.0), max = Vec3.v3(-4.0, 4.0, 4.0), center = Vec3.v3(0.0, 1.5, 0.0) });
        Assert.assertEq(expected = (-4.0, 0.0, -4.0, 4.0, 4.0, 4.0), (b#min#x, b#min#y, b#min#z, b#max#x, b#max#y, b#max#z))

    /// 景色を背景に描くのは asBackground が真で sky が無い時だけ（sky があれば sky が勝つ）。
    @Test
    def testBackgroundIsUsedOnlyWithoutSky(): Unit \ Assert =
        let scene = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }, Vec2.zero());
        let on = Scene3d.environmentMap(sample()) |> Scene3d.withEnvironmentAsBackground(true);
        let sky = Scene3d.gradientSky(Color.rgb(0.0, 0.0, 1.0), Color.rgb(1.0, 1.0, 1.0), Color.rgb(0.0, 0.0, 0.0));
        let a = { environmentMap = Some(on) | scene };
        let b = { sky = Some(sky) | a };
        let c = { environmentMap = Some(Scene3d.environmentMap(sample())) | scene };
        Assert.assertTrue(Option.nonEmpty(Scene3d.backgroundEnvironmentOf(a)) and Option.nonEmpty(Scene3d.drawnSkyOf(a))
                          and Option.isEmpty(Scene3d.backgroundEnvironmentOf(b)) and Option.nonEmpty(Scene3d.drawnSkyOf(b))
                          and Option.isEmpty(Scene3d.backgroundEnvironmentOf(c)) and Option.isEmpty(Scene3d.drawnSkyOf(c)))

    /// 環境マップの絵の名前は読む絵の名前に数える。
    @Test
    def testTextureNamesIncludeTheEnvironmentMap(): Unit \ Assert =
        let scene = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }, Vec2.zero());
        let withMap = { environmentMap = Some(Scene3d.environmentMap(sample())) | scene };
        Assert.assertTrue(Scene3d.environmentTextureNamesOf(scene) == Nil and Scene3d.environmentTextureNamesOf(withMap) == (Texture3d.name(sample()) :: Nil))
}
