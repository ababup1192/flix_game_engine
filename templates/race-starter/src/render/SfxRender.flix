// SfxRender — 効果音 13 本を素材ファイル無しで生成する（SceneRender.all / Studio の「生成して」から呼ぶ）。
// 出来上がりは assets/sfx/*.wav で、project.json の sounds がその名前で読み込む。
// 合成と WAV への書き出しは engine_tools の SfxSynth が持つので、ここは「どんな波を重ねるか」
// だけを書く。音量・高さ・長さの倍率は race.sfxtune.json（SfxTuneDoc）から掛かる。
//
// この画風にそろえた音づくり: 路面と車体はノイズの擦れ（rasp）、勝ち負けと合図は矩形波の
// 音階。乗り物の音と合図の音を質感で分けて、走っている最中に何が起きたかを耳だけで拾えるようにする。
mod SfxRender {
    use SfxTuneDoc.Knobs

    /// 22050Hz モノラル: 短いブリップにはこれで足り、ファイルも小さい。
    def cfg(): SfxSynth.Config = { sampleRate = 22050 }

    // ── つまみを掛けた素の声（音のデザインはこの 2 つだけを使って組む） ──

    /// 矩形波。freq は pitch 倍、amp は volume 倍、長さは speed で割る（速いほど短い）。
    def tone(k: Knobs, freq: Float64, amp: Float64, ms: Int32): List[Float64] =
        SfxSynth.tone(cfg(), freq * k#pitch, amp * k#volume, msOf(k, ms))

    /// 雑音。長さの扱いは tone と同じ（高さは持たない）。
    def noise(k: Knobs, amp: Float64, ms: Int32): List[Float64] =
        SfxSynth.noise(cfg(), amp * k#volume, msOf(k, ms))

    def msOf(k: Knobs, ms: Int32): Int32 =
        Float64.tryToInt32(Int32.toFloat64(ms) / k#speed) |> Option.getWithDefault(ms)

    def fade(samples: List[Float64]): List[Float64] = SfxSynth.fade(samples)

    // ── 続く音（輪にして鳴らしっぱなしにする 3 本） ──

    /// 輪にする音の長さ。22050Hz の 500ms = 11025 サンプルで、偶数 Hz の矩形波はちょうど
    /// 整数回ぶん収まる（端と端が揃うので、繰り返しても継ぎ目でプツッと鳴らない）。
    def loopMs(): Int32 = 500

    /// 輪にする音は fade も speed も掛けない（先細らせると輪の継ぎ目で音が消え、
    /// 長さを変えると矩形波の端が揃わなくなる）。掛けてよいのは音量だけ。
    def loopTone(k: Knobs, freq: Float64, amp: Float64): List[Float64] =
        SfxSynth.tone(cfg(), freq, amp * k#volume, loopMs())

    def loopNoise(k: Knobs, amp: Float64): List[Float64] =
        SfxSynth.noise(cfg(), amp * k#volume, loopMs())

    /// エンジンの唸り: 低い矩形波 2 本（基音と 5 度上）に薄い雑音を混ぜた輪。
    /// 高さは鳴らしながら pitch で変えるので、ここでは「止まっているときの音」を生成する。
    def engineHum(k: Knobs): List[Float64] =
        SfxSynth.blend(
            SfxSynth.blend(loopTone(k, 62.0, 0.30), loopTone(k, 94.0, 0.13)),
            SfxSynth.rasp(loopNoise(k, 0.20)))

    /// 擦れ: 高い方だけ残した雑音に低いうなりを重ねた輪。ドリフト中これが鳴り続ける。
    def skidScrub(k: Knobs): List[Float64] =
        SfxSynth.blend(
            SfxSynth.rasp(loopNoise(k, 0.5)),
            loopTone(k, 96.0, 0.06))

    /// 壁ずり: 擦れの中でも一番細い金属音。高い雑音を薄く残し、細い矩形波を 2 本重ねて
    /// 「板を引きずっている」高さを出す。タイヤの擦れ（skid）とは太さで聞き分けられる。
    def railScrape(k: Knobs): List[Float64] =
        SfxSynth.blend(
            SfxSynth.rasp(SfxSynth.rasp(loopNoise(k, 0.85))),
            SfxSynth.blend(loopTone(k, 214.0, 0.05), loopTone(k, 642.0, 0.03)))

    // ── 一発で鳴り切る 10 本のデザイン ──

    /// 食いつき: 短く下がる 2 音。滑りが終わってタイヤが路面をつかんだ。
    def gripSettle(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            fade(tone(k, 300.0, 0.4, 45)) ::
            fade(tone(k, 190.0, 0.5, 70)) :: Nil)

    /// ニトロ: 4 段階で駆け上がる矩形波に噴射の雑音を重ねた、一番強い音。
    def nitroSurge(k: Knobs): List[Float64] =
        SfxSynth.blend(
            SfxSynth.sequence(
                tone(k, 180.0, 0.3, 100) ::
                tone(k, 260.0, 0.3, 100) ::
                tone(k, 380.0, 0.3, 100) ::
                fade(tone(k, 540.0, 0.34, 180)) :: Nil),
            fade(noise(k, 0.2, 480)))

    /// クラッシュ: 潰れた低音と雑音の直撃のあとに、砕けた破片が散る余韻。
    def crashSmash(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            SfxSynth.blend(noise(k, 0.28, 110), tone(k, 68.0, 0.22, 110)) ::
            fade(fade(SfxSynth.rasp(noise(k, 0.25, 260)))) :: Nil)

    /// 押し合い: クラッシュと同じ質感のまま、短く弱く。車体どうしが触れただけ。
    def bumpKnock(k: Knobs): List[Float64] =
        SfxSynth.blend(
            fade(tone(k, 160.0, 0.28, 80)),
            fade(fade(noise(k, 0.2, 80))))

    /// アイテム: 明るく上がる 2 音。手に入れた合図。
    def itemChime(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            fade(tone(k, 880.0, 0.38, 50)) ::
            fade(tone(k, 1318.5, 0.43, 80)) :: Nil)

    /// 追い抜き: すれ違いの風。擦れた雑音に低い音を薄く敷いて、横を過ぎた感じにする。
    def overtakeWhoosh(k: Knobs): List[Float64] =
        SfxSynth.blend(
            fade(SfxSynth.rasp(noise(k, 0.42, 150))),
            fade(tone(k, 520.0, 0.07, 150)))

    /// 周回: 上がる 2 音の短いジングル。「1 周した」の刻印。
    def lapChime(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            fade(tone(k, 587.33, 0.33, 60)) ::
            fade(tone(k, 880.0, 0.43, 110)) :: Nil)

    /// 勝ち: 駆け上がる 4 音のファンファーレ（C5・E5・G5・C6）。
    def winFanfare(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            fade(tone(k, 523.25, 0.35, 90)) ::
            fade(tone(k, 659.25, 0.35, 90)) ::
            fade(tone(k, 783.99, 0.35, 90)) ::
            fade(tone(k, 1046.5, 0.44, 240)) :: Nil)

    /// 負け: 下がる 3 音（G4・E♭4・C4）。息切れして終わった。
    def loseFall(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            fade(tone(k, 392.0, 0.35, 90)) ::
            fade(tone(k, 311.13, 0.35, 90)) ::
            fade(tone(k, 261.63, 0.44, 220)) :: Nil)

    /// 決定: 短い 2 音のブリップ。押した手応えだけを返す。
    def startBlip(k: Knobs): List[Float64] =
        SfxSynth.sequence(
            fade(tone(k, 523.25, 0.31, 40)) ::
            fade(tone(k, 784.0, 0.37, 60)) :: Nil)

    /// 13 本を assets/sfx/ へ書き出す。つまみは Doc から読む（読めなければ既定のつまみ）。
    pub def renderAll(): Unit \ IO + Fs.FileRead =
        renderWith(SfxTuneDoc.load(SfxTuneDoc.path()))

    /// つまみを渡して生成する（名前は project.json の sounds と 1 対 1）。
    pub def renderWith(tune: SfxTuneDoc.Doc): Unit \ IO =
        SfxSynth.renderSet(cfg(), "assets/sfx",
            ("engine", engineHum(SfxTuneDoc.rec(tune)#engine)) ::
            ("skid", skidScrub(SfxTuneDoc.rec(tune)#skid)) ::
            ("scrape", railScrape(SfxTuneDoc.rec(tune)#scrape)) ::
            ("grip", gripSettle(SfxTuneDoc.rec(tune)#grip)) ::
            ("nitro", nitroSurge(SfxTuneDoc.rec(tune)#nitro)) ::
            ("crash", crashSmash(SfxTuneDoc.rec(tune)#crash)) ::
            ("bump", bumpKnock(SfxTuneDoc.rec(tune)#bump)) ::
            ("item", itemChime(SfxTuneDoc.rec(tune)#item)) ::
            ("overtake", overtakeWhoosh(SfxTuneDoc.rec(tune)#overtake)) ::
            ("lap", lapChime(SfxTuneDoc.rec(tune)#lap)) ::
            ("win", winFanfare(SfxTuneDoc.rec(tune)#win)) ::
            ("lose", loseFall(SfxTuneDoc.rec(tune)#lose)) ::
            ("start", startBlip(SfxTuneDoc.rec(tune)#start)) :: Nil)
}
