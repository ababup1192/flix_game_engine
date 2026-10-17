// TestSfxLoop — 型で鳴らす音（Sfx[s] / Loop[s]）を、App に渡す名前の列へ写す規約を固定する。
// 確かめるのは: 鳴らした順に並ぶ・同じ一発の音は 1 つにまとまる・鳴り続ける音は音量と高さを運ぶ。
mod TestSfxLoop {

    enum Shot with Eq {
        case Coin
        case Crash
    }

    enum Hum with Eq {
        case Engine
    }

    def shotName(s: Shot): String = match s {
        case Shot.Coin  => "coin"
        case Shot.Crash => "crash"
    }

    def humName(h: Hum): String = match h {
        case Hum.Engine => "engine"
    }

    /// 鳴らした順に並び、同じ音は先の 1 つだけ残る（App.withAudio の 1 フレーム 1 回と同じ）。
    @Test
    def testCollectKeepsOrderAndDropsRepeats(): Unit \ Assert =
        Assert.assertEq(expected = "coin" :: "crash" :: Nil,
            Sfx.collect(shotName, () -> {
                Sfx.play(Shot.Coin);
                Sfx.play(Shot.Crash);
                Sfx.play(Shot.Coin)
            }))

    /// 何も鳴らさなければ空。
    @Test
    def testCollectWithoutPlayIsEmpty(): Unit \ Assert =
        Assert.assertEq(expected = (Nil: List[String]), Sfx.collect(shotName, () -> ()))

    /// 鳴り続ける音は名前・音量・高さを App.Sustain へ運ぶ。
    @Test
    def testLoopCollectCarriesMix(): Unit \ Assert =
        let got = Loop.collect(humName, () -> Loop.hold(Hum.Engine, { volume = 0.5, pitch = 1.5 }));
        Assert.assertEq(expected = ("engine" :: Nil, 0.5 :: Nil, 1.5 :: Nil),
            (List.map(s -> s#name, got), List.map(s -> s#volume, got), List.map(s -> s#pitch, got)))
}
