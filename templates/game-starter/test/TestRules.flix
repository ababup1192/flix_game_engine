// ルールだけをテストする（方針どおり）。座標の写経や描画はテストしない。
// 期待値はリテラルでなく Doc の既定値（SampleDoc.defaults）や絵から導く。
mod TestRules {

    def d(): SampleDoc.Doc = SampleDoc.defaults()

    def w0(): World.World =
        World.initial(d(), KeysDoc.defaults(), ThemeDoc.defaults(), PxSpriteDoc.empty(),
            ShaderDoc.demoSurface())

    /// 4×6 マスの絵を 1 体だけ持つ Doc（大きさが絵に追随することを見るため）。
    def spritesOf(): PxSpriteDoc.Doc =
        PxSpriteDoc.fromJson("{\"version\":1,\"legend\":{\"a\":\"accent\"},\"sprites\":"
            + "{\"hero\":{\"frames\":{\"idle\":[\"aaaa\",\"aaaa\",\"aaaa\","
            + "\"aaaa\",\"aaaa\",\"aaaa\"]}}}}")
            |> Option.getWithDefault(PxSpriteDoc.empty())

    @Test
    def testStepMovesBySpeedFromDoc(): Unit \ Assert =
        // 1 秒右に押し続けると Doc の speed ぶんだけ進む（端に届かない範囲で）。
        let dt = 0.1;
        let w = World.step({ x = 1.0, y = 0.0 }, dt, w0());
        Assert.assertEq(expected = World.width() / 2.0 + SampleDoc.rec(d())#speed * dt, w#x)

    @Test
    def testHeroClampedInsideScreen(): Unit \ Assert =
        // 端で止まるのはルール。左上へどれだけ押しても主人公全体が画面内に残る。
        let w = World.step({ x = -1.0, y = -1.0 }, 1000.0, w0());
        let box = World.heroBox(w);
        Assert.assertEq(expected = (box#x / 2.0, box#y / 2.0), (w#x, w#y))

    @Test
    def testHeroBoxFollowsTheSprite(): Unit \ Assert =
        // 当たりの大きさは絵から導く（絵を描き替えたら可動域もついてくる）。
        // 縦横は別に測る — 正方形とは限らない。
        let w = World.withSprites(spritesOf(), w0());
        let scale = Int32.toFloat64(World.spriteScale());
        Assert.assertEq(expected = (4.0 * scale, 6.0 * scale),
            (World.heroBox(w)#x, World.heroBox(w)#y))
}
