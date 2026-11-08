// TestLwjglLoad — デスクトップの LoadProgress の handler（スレッドの pool・javax.imageio のデコーダー）。
// 知らせの並び・50 ms ごとの知らせ・例外で抜ける決まりは LoadProgress.Conformance（engine）が持ち、ここは handler を渡すだけ。
mod TestLwjglLoad {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayOutputStream
    import java.lang.{RuntimeException, System, Thread}
    import java.util.concurrent.atomic.AtomicBoolean
    import javax.imageio.ImageIO

    /// 試す handler で program を流し、届いた知らせを集める。
    def collecting(program: Unit -> List[Int32] \ IO + LoadProgress): (List[Int32], List[(String, Int32, Int32)]) \ IO =
        region rc {
            let seen = MutList.empty(rc);
            let ys = LwjglLoad.handleWith((phase, done, total) -> MutList.push((phase, done, total), seen), program);
            (ys, MutList.toList(seen))
        }

    def harness(): LoadProgress.Conformance.Harness = {
        handle = collecting,
        sleepMs = ms -> Thread.sleep(ms),
        fail = message -> throw new RuntimeException(message),
        nowMs = () -> System.currentTimeMillis(),
        newFlag = () -> {
            let flag = new AtomicBoolean(false);
            { raise = () -> flag.set(true), isRaised = () -> flag.get() }
        }
    }

    @Test
    def testKeepsTheOrderRules(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, LoadProgress.Conformance.orderViolations(harness()))

    @Test
    def testReportsWhileNothingFinishes(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, LoadProgress.Conformance.pollingViolations(harness()))

    @Test
    def testEndsOnTheFirstException(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, LoadProgress.Conformance.failureViolations(harness()))

    /// 赤 1 × 2 の PNG のバイト。
    def redPng(): Vector[Int8] \ IO =
        let image = new BufferedImage(1, 2, BufferedImage.TYPE_INT_ARGB);
        image.setRGB(0, 0, -65536);
        image.setRGB(0, 1, -65536);
        let out = new ByteArrayOutputStream();
        discard ImageIO.write(image, "png", out);
        Array.toVector(out.toByteArray())

    @Test
    def testDecoderReadsPng(): Unit \ {Assert, IO} =
        let decoded = LwjglLoad.handleWith((_, _, _) -> (), () -> (LoadProgress.imageDecoder()#decode)(redPng()));
        Assert.assertEq(expected = Ok((1, 2, Vector#{-65536, -65536})), Result.map(img -> (img#width, img#height, img#argb), decoded))

    @Test
    def testDecoderRejectsGarbage(): Unit \ {Assert, IO} =
        let decoded = LwjglLoad.handleWith((_, _, _) -> (), () -> (LoadProgress.imageDecoder()#decode)(Vector#{1i8, 2i8, 3i8}));
        Assert.assertTrue(Result.isErr(decoded))

    @Test
    def testDownloadsHasNothingLeftToFetch(): Unit \ {Assert, IO} =
        let missing = LwjglLoad.handleWith((_, _, _) -> (), () -> (LoadProgress.downloads()#missing)());
        Assert.assertEq(expected = Set.empty(), missing)
}
