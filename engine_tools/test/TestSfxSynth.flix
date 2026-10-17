// SfxSynth のテスト。合成語彙（tone / noise / fade / blend / sequence）の値と、
// WAV バイト列のヘッダ構造・長さ・決定論を、小さな設定で固定する。

mod TestSfxSynth {

    def cfg(): SfxSynth.Config = { sampleRate = 8 }

    /// frames: ミリ秒 → サンプル数。1000ms はちょうど sampleRate ぶん。
    @Test
    def testFrames(): Unit \ Assert =
        Assert.assertEq(expected = (8, 4), (SfxSynth.frames(cfg(), 1000), SfxSynth.frames(cfg(), 500)))

    /// tone: 生の矩形波は ±amp のみ。sr=4・freq=1 なら前半 +・後半 −。
    @Test
    def testToneIsSquare(): Unit \ Assert =
        let out = SfxSynth.tone({ sampleRate = 4 }, 1.0, 0.5, 1000);
        Assert.assertEq(expected = 0.5 :: 0.5 :: -0.5 :: -0.5 :: Nil, out)

    /// fade: 先頭は 1 倍・末尾へ向けて線形に 0 へ。
    @Test
    def testFadeLinear(): Unit \ Assert =
        let out = SfxSynth.fade(1.0 :: 1.0 :: 1.0 :: 1.0 :: Nil);
        Assert.assertEq(expected = 1.0 :: 0.75 :: 0.5 :: 0.25 :: Nil, out)

    /// blend: 同じ位置を足し、sequence: 順に繋ぐ。
    @Test
    def testBlendAndSequence(): Unit \ Assert =
        Assert.assertEq(
            expected = (11.0 :: 22.0 :: 33.0 :: Nil, 1.0 :: 2.0 :: 3.0 :: Nil),
            (SfxSynth.blend(1.0 :: 2.0 :: 3.0 :: Nil, 10.0 :: 20.0 :: 30.0 :: Nil),
             SfxSynth.sequence((1.0 :: 2.0 :: Nil) :: (3.0 :: Nil) :: Nil)))

    /// noise: 決定論的（同じ設定は毎回同じ列）。
    @Test
    def testNoiseDeterministic(): Unit \ Assert =
        Assert.assertEq(expected = SfxSynth.noise(cfg(), 0.3, 20), SfxSynth.noise(cfg(), 0.3, 20))

    /// WAV 長さ: 44 バイトのヘッダ + サンプルあたり 2 バイト。
    @Test
    def testWavLength(): Unit \ Assert =
        let bytes = SfxSynth.wavBytes(cfg(), 0.0 :: 0.0 :: Nil);
        Assert.assertEq(expected = 48, List.length(bytes))

    /// WAV ヘッダ構造: "RIFF" で始まり、8 バイト目から "WAVE"、24 バイト目に sampleRate。
    @Test
    def testWavHeader(): Unit \ Assert =
        let bytes = SfxSynth.wavBytes(cfg(), 0.0 :: 0.0 :: Nil);
        let riff = List.take(4, bytes);
        let wave = List.take(4, List.drop(8, bytes));
        let rate = List.take(4, List.drop(24, bytes));      // le32(sampleRate = 8)
        let data = List.take(4, List.drop(36, bytes));       // "data" ブロックタグ
        Assert.assertEq(
            expected = (82 :: 73 :: 70 :: 70 :: Nil, 87 :: 65 :: 86 :: 69 :: Nil,
                        8 :: 0 :: 0 :: 0 :: Nil, 100 :: 97 :: 116 :: 97 :: Nil),
            (riff, wave, rate, data))

    /// WAV バイト列は決定論的。
    @Test
    def testWavDeterministic(): Unit \ Assert =
        let voice = SfxSynth.fade(SfxSynth.tone(cfg(), 2.0, 0.4, 20));
        Assert.assertEq(expected = SfxSynth.wavBytes(cfg(), voice), SfxSynth.wavBytes(cfg(), voice))

    /// ループ点つきの WAV: smpl から [頭, 終わり) が読め、RIFF の長さの欄がファイルの長さと合う。
    /// 頭が範囲外なら smpl を付けない（ふつうの WAV と同じバイト）。
    @Test
    def testLoopedWavCarriesItsLoopPoints(): Unit \ Assert =
        let samples = List.repeat(10, 0.0);
        let looped = SfxSynth.wavBytesLooped(cfg(), samples, 4);
        let read = bytes -> {
            let v = List.toVector(bytes);
            let at = i -> Vector.get(i, v);
            AudioUtil.loopPointsOf(i -> Int32.truncateToInt8(at(i)),
                                   i -> at(i) + at(i + 1) * 256 + at(i + 2) * 65536 + at(i + 3) * 16777216,
                                   Vector.length(v))
        };
        let riff = List.drop(4, looped) |> List.take(4);
        Assert.assertEq(expected = (Some((4, 10)), None, true, le32Of(List.length(looped) - 8)),
            (read(looped), read(SfxSynth.wavBytes(cfg(), samples)),
             SfxSynth.wavBytesLooped(cfg(), samples, 10) == SfxSynth.wavBytes(cfg(), samples), riff))

    /// ステレオの WAV: fmt のチャンネル数 2・ブロックアライン 4 で、data は左・右の順に交互（短い方の長さにそろう）。
    @Test
    def testStereoWavInterleavesLeftAndRight(): Unit \ Assert =
        let bytes = SfxSynth.wavBytesStereo(cfg(), 1.0 :: 0.0 :: 1.0 :: Nil, 0.0 :: -1.0 :: Nil);
        let channels = List.drop(22, bytes) |> List.take(2);
        let align = List.drop(32, bytes) |> List.take(2);
        let data = List.drop(44, bytes);
        Assert.assertEq(expected = (2 :: 0 :: Nil, 4 :: 0 :: Nil, 255 :: 127 :: 0 :: 0 :: 0 :: 0 :: 1 :: 128 :: Nil),
            (channels, align, data))

    /// ループ点つきのステレオの WAV: smpl の頭と終わりは左右の組の番号（バイトやサンプル数の倍ではない）で、
    /// RIFF の長さの欄がファイルの長さと合う。
    @Test
    def testStereoLoopedWavCountsPairs(): Unit \ Assert =
        let looped = SfxSynth.wavBytesStereoLooped(cfg(), List.repeat(10, 0.0), List.repeat(10, 0.0), 4);
        let v = List.toVector(looped);
        let at = i -> Vector.get(i, v);
        let points = AudioUtil.loopPointsOf(i -> Int32.truncateToInt8(at(i)),
                                            i -> at(i) + at(i + 1) * 256 + at(i + 2) * 65536 + at(i + 3) * 16777216,
                                            Vector.length(v));
        Assert.assertEq(expected = (Some((4, 10)), le32Of(List.length(looped) - 8)),
            (points, List.drop(4, looped) |> List.take(4)))

    def le32Of(v: Int32): List[Int32] =
        Int32.remainder(v, 256) :: Int32.remainder(v / 256, 256) :: Int32.remainder(v / 65536, 256) :: v / 16777216 :: Nil
}
