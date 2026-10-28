// ルールだけをテストする（方針どおり）。座標の写経や描画はテストしない。
// 期待値はリテラルでなく Doc の既定値（SampleDoc.defaults）や絵から導く。
mod TestRules {

    use fge::{PxSpriteDoc, ShaderDoc, SortingLayer}

    def d(): SampleDoc.Doc = SampleDoc.defaults()

    def res(): Res.Res =
        Res.build({ sample = d(), keys = KeysDoc.defaults(), theme = ThemeDoc.defaults(),
                    sprites = PxSpriteDoc.empty(), shader = ShaderDoc.demoSurface() })

    def w0(): World.World = World.initial()

    def heroX(w: World.World): Option[Float64] = World.heroAt(w) |> Option.map(p -> p#x)

    /// 4×6 マスの絵を 1 体だけ持つ Doc（大きさが絵に追随することを見るため）。
    def spritesOf(): Option[PxSpriteDoc.Doc] =
        PxSpriteDoc.fromJson("{\"version\":1,\"legend\":{\"a\":\"accent\"},\"sprites\":"
            + "{\"hero\":{\"frames\":{\"idle\":[\"aaaa\",\"aaaa\",\"aaaa\","
            + "\"aaaa\",\"aaaa\",\"aaaa\"]}}}}")

    @Test
    def testStepMovesBySpeedFromDoc(): Unit \ Assert =
        // 1 秒右に押し続けると Doc の speed ぶんだけ進む（端に届かない範囲で）。
        let dt = 0.1;
        let w = World.step(res(), { x = 1.0, y = 0.0 }, dt, w0());
        Assert.assertEq(expected = Some(World.width() / 2.0 + SampleDoc.rec(d())#speed * dt), heroX(w))

    @Test
    def testHeroClampedInsideScreen(): Unit \ Assert =
        // 端で止まるのはルール。左上へどれだけ押しても主人公全体が画面内に残る。
        let w = World.step(res(), { x = -1.0, y = -1.0 }, 1000.0, w0());
        let box = World.heroBox(res());
        Assert.assertEq(expected = Some((box#x / 2.0, box#y / 2.0)), World.heroAt(w) |> Option.map(p -> (p#x, p#y)))

    @Test
    def testHeroBoxFollowsTheSprite(): Unit \ Assert =
        // 当たりの大きさは絵から導く（絵を描き替えたら可動域もついてくる）。
        // 縦横は別に測る — 正方形とは限らない。
        let scale = Int32.toFloat64(World.spriteScale());
        Assert.assertEq(expected = Some((4.0 * scale, 6.0 * scale)),
            spritesOf() |> Option.map(sprites -> World.heroBox(Res.withSprites(sprites, res())))
                        |> Option.map(box -> (box#x, box#y)))

    @Test
    def testQuitAskedThenNoReturnsToPlay(): Unit \ Assert =
        // Esc・閉じるボタンで確認へ、いいえで遊びへ戻る（すぐには終わらない）。
        let asked = World.askQuit(w0());
        Assert.assertEq(expected = (true, false, false),
            (World.isAskingQuit(asked), World.isQuitting(asked), World.isAskingQuit(World.answerQuit(false, asked))))

    @Test
    def testQuitConfirmedOnlyAfterYes(): Unit \ Assert =
        Assert.assertEq(expected = true, World.isQuitting(World.answerQuit(true, World.askQuit(w0()))))

    @Test
    def testHeroStaysWhileAskingQuit(): Unit \ Assert =
        // 確認の窓が出ている間は押しても動かない。
        let asked = World.askQuit(w0());
        Assert.assertEq(expected = heroX(asked), heroX(World.step(res(), { x = 1.0, y = 0.0 }, 0.1, asked)))

    @Test
    def testClickInsideQuitWindowQuits(): Unit \ Assert =
        // 確認の窓の真ん中を押すと Enter と同じ（はい）。
        let asked = World.askQuit(w0());
        Assert.assertEq(expected = true,
            World.isQuitting(Controls.tapAt(res(), { x = World.width() / 2.0, y = World.height() / 2.0 }, asked)))

    @Test
    def testClickOutsideQuitWindowReturnsToPlay(): Unit \ Assert =
        // 窓の外（奥の場面の上）を押すと Esc と同じ（いいえ）。奥の場面には届かない。
        let asked = World.askQuit(w0());
        Assert.assertEq(expected = (false, false),
            (World.isAskingQuit(Controls.tapAt(res(), { x = 1.0, y = 1.0 }, asked)), World.isQuitting(Controls.tapAt(res(), { x = 1.0, y = 1.0 }, asked))))

    @Test
    def testLayersAreStackedBackToFront(): Unit \ Assert =
        // 層の表が奥から手前へ交ざらずに並ぶ（範囲を書き換えたときの取り違えを止める）。
        Assert.assertEq(expected = true, SortingLayer.isStacked(ZOrder.layers()))
}
