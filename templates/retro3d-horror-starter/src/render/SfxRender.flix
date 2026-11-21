// SfxRender — 夜の校舎の効果音を全部合成して assets/sfx/ へ書く（make sfx）。番号だけで決まる計算なので、何度書き出しても同じ WAV になる。
// 足音・戸・時計・空気・風・拾う・紙。どれも足音より控えめに置く（大きさの比は sound.kind.json のバスが決め、ここは素の大きさを揃えるだけ）。
// WhyNot: SfxSynth の矩形波だけで組まない — 矩形波の足音や戸は電子音に聞こえて校舎の音にならない。雑音を帯の形に削る・低い正弦の胴鳴り・
// 短い反響を足す所までこのファイルで書き、WAV にするのは engine の SfxSynth に任せる。
mod SfxRender {
    use fge::{App, Hash01, Num, SfxSynth}

    def rate(): Int32 = 22050

    def cfg(): SfxSynth.Config = { sampleRate = rate() }

    // ── 下ごしらえ（波・包み・フィルタ・重ね） ──

    def framesOf(sec: Float64): Int32 = Num.roundInt(sec * Int32.toFloat64(rate()))

    def timeOf(i: Int32): Float64 = Int32.toFloat64(i) / Int32.toFloat64(rate())

    def expo(x: Float64): Float64 = Float64.pow(base = 2.718281828459045, x)

    def silence(sec: Float64): List[Float64] = List.repeat(framesOf(sec), 0.0)

    /// 白い雑音（種 seed と番号から決まる・-1〜1）。
    def white(seed: Int32, sec: Float64): List[Float64] =
        List.range(0, framesOf(sec)) |> List.map(i -> Hash01.at(i, seed) * 2.0 - 1.0)

    /// 正弦: 高さが startHz から endHz（Hz）へ glide 秒ほどで落ちる（叩いた瞬間だけ高い胴鳴り）。
    def sineGlide(startHz: Float64, endHz: Float64, glide: Float64, sec: Float64): List[Float64] =
        let phase = t -> Num.tau() * (endHz * t + (startHz - endHz) * glide * (1.0 - expo(0.0 - t / glide)));
        List.range(0, framesOf(sec)) |> List.map(i -> Num.sin(phase(timeOf(i))))

    /// 先頭から attack 秒で立ち上がり、tau 秒ごとに約 1/3 へ落ちる包み。
    def hit(attack: Float64, tau: Float64, xs: List[Float64]): List[Float64] =
        shape(t -> Num.clamp01(t / Float64.max(attack, 0.0001)) * expo(0.0 - t / tau), xs)

    /// 番号ごとの倍率を掛ける。
    def shape(f: Float64 -> Float64, xs: List[Float64]): List[Float64] =
        xs |> List.mapWithIndex((i, x) -> x * f(timeOf(i)))

    def gain(g: Float64, xs: List[Float64]): List[Float64] = List.map(x -> x * g, xs)

    /// 低い所だけを通す（1 段）。cut = 時刻ごとの境の高さ（Hz）。
    def lowpass(cut: Float64 -> Float64, xs: List[Float64]): List[Float64] =
        let (_, _, out) = List.foldLeft(lowpassStep(cut), (0, 0.0, Nil), xs);
        List.reverse(out)

    def lowpassStep(cut: Float64 -> Float64, acc: (Int32, Float64, List[Float64]), x: Float64): (Int32, Float64, List[Float64]) =
        let (i, y, out) = acc;
        let a = 1.0 - expo(0.0 - Num.tau() * cut(timeOf(i)) / Int32.toFloat64(rate()));
        let y1 = y + a * (x - y);
        (i + 1, y1, y1 :: out)

    /// 高い所だけを通す（元から低い所を引く）。
    def highpass(cut: Float64, xs: List[Float64]): List[Float64] =
        List.zipWith((x, l) -> x - l, xs, lowpass(_ -> cut, xs))

    /// 帯だけを通す（2 つの値を持つフィルタ）。center = 時刻ごとの中心の高さ（Hz）・damp = 帯の広さ（小さいほど鈴のように鳴る）。
    def bandpass(center: Float64 -> Float64, damp: Float64, xs: List[Float64]): List[Float64] =
        let (_, _, _, out) = List.foldLeft(bandpassStep(center, damp), (0, 0.0, 0.0, Nil), xs);
        List.reverse(out)

    def bandpassStep(center: Float64 -> Float64, damp: Float64, acc: (Int32, Float64, Float64, List[Float64]), x: Float64): (Int32, Float64, Float64, List[Float64]) =
        let (i, low, band, out) = acc;
        let f = 2.0 * Num.sin(Num.pi() * Float64.min(center(timeOf(i)), 3600.0) / Int32.toFloat64(rate()));
        let low1 = low + f * band;
        let high = x - low1 - damp * band;
        let band1 = band + f * high;
        (i + 1, low1, band1, band1 :: out)

    /// 2 本を足す（長い方の長さになる）。
    def plus(a: List[Float64], b: List[Float64]): List[Float64] =
        let n = Int32.max(List.length(a), List.length(b));
        let pad = xs -> List.append(xs, List.repeat(n - List.length(xs), 0.0));
        List.zipWith((x, y) -> x + y, pad(a), pad(b))

    /// at 秒の所から voice を重ねる。
    def at(sec: Float64, voice: List[Float64], base: List[Float64]): List[Float64] =
        plus(base, List.append(List.repeat(framesOf(sec), 0.0), voice))

    /// 全長 sec の中へ (時刻, 音) を全部重ねる。
    def layout(sec: Float64, voices: List[(Float64, List[Float64])]): List[Float64] =
        let base = silence(sec);
        List.foldLeft((acc, v) -> at(fst(v), snd(v), acc), base, voices) |> List.take(framesOf(sec))

    /// 夜の廊下の短い反響: 少し遅れて籠もった写しを何度か足す（板張りの廊下で音が後ろへ抜ける感じ）。
    def corridor(wet: Float64, xs: List[Float64]): List[Float64] =
        let dull = lowpass(_ -> 1800.0, xs);
        let taps = (0.031, 0.42) :: (0.047, 0.30) :: (0.069, 0.22) :: (0.097, 0.14) :: (0.131, 0.09) :: Nil;
        let len = List.length(xs);
        List.foldLeft((acc, tap) -> at(fst(tap), gain(snd(tap) * wet, dull), acc), xs, taps) |> List.take(len)

    /// 頭と尻をつないで、輪で回しても継ぎ目が鳴らないようにする（尻の fade 秒を頭へ重ねて折り返す）。
    def seamless(fade: Float64, xs: List[Float64]): List[Float64] =
        let k = framesOf(fade);
        let body = List.length(xs) - k;
        let head = List.take(k, xs);
        let tail = List.drop(body, xs);
        let w = i -> Int32.toFloat64(i) / Int32.toFloat64(k);
        let joined = List.zipWith((h, t) -> (h, t), head, tail)
            |> List.mapWithIndex((i, ht) -> fst(ht) * Num.sqrt(w(i)) + snd(ht) * Num.sqrt(1.0 - w(i)));
        List.append(joined, List.take(body - k, List.drop(k, xs)))

    /// 大きさを揃える: 平均の大きさ rmsDb（dB）を狙い、山が peak を超える時は山の方で抑える。
    def level(rmsDb: Float64, peak: Float64, xs: List[Float64]): List[Float64] =
        let n = Int32.toFloat64(Int32.max(1, List.length(xs)));
        let rms = Num.sqrt(List.foldLeft((acc, x) -> acc + x * x, 0.0, xs) / n);
        let top = List.foldLeft((acc, x) -> Float64.max(acc, Float64.abs(x)), 0.0, xs);
        let want = Float64.pow(base = 10.0, rmsDb / 20.0);
        let g = Float64.min(want / Float64.max(rms, 0.000001), peak / Float64.max(top, 0.000001));
        gain(g, xs)

    // ── 足音（主役） ──

    /// 上履きで板張りの廊下を 1 歩: かかとの低い胴鳴り・板の鳴り・爪先の小さな当たり・廊下の反響。k ごとに高さと間を少しずつ替える。
    def step(k: Int32): List[Float64] =
        let h = c -> Hash01.at(k, c);
        let len = 0.26;
        let heel = sineGlide(150.0 + 40.0 * h(1), 78.0 + 22.0 * h(2), 0.012, len) |> hit(0.002, 0.028) |> gain(0.9);
        let board = white(200 + k, len) |> bandpass(_ -> 420.0 + 260.0 * h(3), 0.55) |> hit(0.001, 0.022) |> gain(1.4);
        let tap = white(300 + k, len) |> highpass(2600.0) |> hit(0.0005, 0.004) |> gain(0.22);
        let scuff = white(400 + k, len) |> bandpass(_ -> 1500.0 + 500.0 * h(4), 1.3)
            |> shape(t -> Num.clamp01((t - 0.015) / 0.03) * expo(0.0 - Float64.max(0.0, t - 0.045) / 0.035)) |> gain(0.10);
        let toe = plus(sineGlide(190.0, 110.0, 0.01, len) |> hit(0.002, 0.02) |> gain(0.35),
                       white(500 + k, len) |> bandpass(_ -> 650.0 + 200.0 * h(5), 0.6) |> hit(0.001, 0.015) |> gain(0.6));
        let dry = layout(len, (0.004, heel) :: (0.004, board) :: (0.004, tap) :: (0.0, scuff) :: (0.055 + 0.025 * h(6), toe) :: Nil);
        dry |> corridor(0.8) |> level(-29.0 + 3.0 * (h(7) - 0.5), 0.6)

    // ── 戸 ──

    /// 教室の引き戸を開ける: 掛け金の小さな音 → 戸車が敷居を転がるゴロゴロ（ガラスが細かく震える）→ 戸袋に当たるトン → 震えの余韻。
    def doorClassroom(): List[Float64] =
        let len = 2.44;
        let rollEnv = t -> Num.clamp01((t - 0.12) / 0.2) * Num.clamp01((1.55 - t) / 0.12) * (0.7 + 0.3 * Num.sin(Num.tau() * 1.3 * t));
        let bumps = t -> 0.55 + 0.45 * Float64.abs(Num.sin(Num.tau() * 7.5 * t + 2.0 * Num.sin(Num.tau() * 1.7 * t)));
        let roll = white(601, len) |> lowpass(_ -> 260.0) |> shape(t -> rollEnv(t) * bumps(t)) |> gain(3.2);
        let rumble = white(602, len) |> bandpass(_ -> 170.0, 0.35) |> shape(rollEnv) |> gain(0.5);
        let glassEnv = t -> rollEnv(t) * Float64.max(0.0, Num.sin(Num.tau() * 5.1 * t) * Num.sin(Num.tau() * 3.3 * t + 1.0));
        let glass = white(603, len) |> bandpass(_ -> 1250.0, 0.12) |> shape(glassEnv) |> gain(0.10);
        let latch = white(604, 0.1) |> bandpass(_ -> 1900.0, 0.2) |> hit(0.0005, 0.008) |> gain(0.35);
        let thud = plus(sineGlide(130.0, 72.0, 0.02, 0.6) |> hit(0.002, 0.07),
                        white(605, 0.6) |> bandpass(_ -> 340.0, 0.5) |> hit(0.001, 0.04) |> gain(1.2));
        let shiver = white(606, 0.9) |> bandpass(_ -> 1700.0, 0.06) |> hit(0.002, 0.18) |> gain(0.12);
        layout(len, (0.0, latch) :: (0.0, roll) :: (0.0, rumble) :: (0.0, glass) :: (1.56, thud) :: (1.57, shiver) :: Nil)
            |> corridor(0.7) |> level(-26.0, 0.30)

    /// 古い戸を開ける: 歪んだ戸が敷居に引っかかりながら擦れる（ギッ・ギギ…と高さの揺れる軋み）→ 重い当たり。
    def doorOld(): List[Float64] =
        let len = 2.04;
        let moving = t -> Num.clamp01((t - 0.05) / 0.15) * Num.clamp01((1.62 - t) / 0.1);
        let stick = t -> Num.clamp01(Num.sin(Num.tau() * (19.0 + 9.0 * Num.sin(Num.tau() * 0.9 * t)) * t) * 3.0 - 1.6);
        let grind = white(701, len) |> lowpass(_ -> 520.0) |> shape(t -> moving(t) * (0.5 + 0.5 * stick(t))) |> gain(2.2);
        let creak = white(702, len) |> bandpass(t -> 760.0 + 260.0 * Num.sin(Num.tau() * 0.7 * t + 0.4) + 90.0 * Num.sin(Num.tau() * 3.1 * t), 0.05)
            |> shape(t -> moving(t) * stick(t) * (0.4 + 0.6 * Num.clamp01(Num.sin(Num.tau() * 0.55 * t + 0.3)))) |> gain(0.16);
        let thud = plus(sineGlide(110.0, 60.0, 0.03, 0.42) |> hit(0.003, 0.08),
                        white(703, 0.42) |> bandpass(_ -> 260.0, 0.6) |> hit(0.002, 0.05) |> gain(1.0));
        layout(len, (0.0, grind) :: (0.0, creak) :: (1.64, thud) :: Nil) |> corridor(0.75) |> level(-32.5, 0.32)

    /// 開かない戸を揺らす: 錠に止められてガタ・ガタッと 5 回（戸の板の鳴りとガラスの震え）。
    def doorRattle(): List[Float64] =
        let len = 1.1;
        let jolt = (k: Int32, g: Float64) ->
            plus(plus(sineGlide(120.0, 85.0, 0.01, 0.3) |> hit(0.002, 0.035) |> gain(0.7),
                      white(800 + k, 0.3) |> bandpass(_ -> 250.0 + 60.0 * Hash01.at(k, 9), 0.45) |> hit(0.001, 0.03) |> gain(1.2)),
                 white(810 + k, 0.3) |> bandpass(_ -> 950.0, 0.1) |> hit(0.002, 0.06) |> gain(0.25)) |> gain(g);
        layout(len, (0.02, jolt(0, 1.0)) :: (0.19, jolt(1, 0.8)) :: (0.37, jolt(2, 0.95)) :: (0.57, jolt(3, 0.7)) :: (0.74, jolt(4, 0.55)) :: Nil)
            |> corridor(0.7) |> level(-26.7, 0.31)

    /// 鍵を開ける: 鍵が鍵穴へ入るかすかな擦れ → 回してカチッ → 閂が引っ込む低いコトッ。
    def doorUnlock(): List[Float64] =
        let len = 0.4;
        let insert = white(901, 0.09) |> highpass(2200.0) |> bandpass(_ -> 3200.0, 0.4) |> shape(t -> Num.clamp01(t / 0.06) * Num.clamp01((0.09 - t) / 0.02)) |> gain(0.4);
        let click = plus(white(902, 0.12) |> bandpass(_ -> 2500.0, 0.05) |> hit(0.0003, 0.012) |> gain(0.6),
                         sineGlide(1900.0, 1750.0, 0.01, 0.12) |> hit(0.0005, 0.02) |> gain(0.25));
        let bolt = plus(white(903, 0.15) |> bandpass(_ -> 900.0, 0.15) |> hit(0.0005, 0.02) |> gain(0.6),
                        sineGlide(260.0, 180.0, 0.01, 0.15) |> hit(0.001, 0.03) |> gain(0.4));
        layout(len, (0.0, insert) :: (0.17, click) :: (0.25, bolt) :: Nil) |> corridor(0.6) |> level(-28.7, 0.35)

    // ── 時計（輪） ──

    /// 壁の振り子時計: チッ・コッを交互に 8 回（4 秒弱の輪。間をぴったり揃えて、回しても拍が乱れない）。
    def clock(): List[Float64] =
        let len = 3.971;
        let beat = len / 8.0;
        let tick = (k: Int32, hi: Float64, body: Float64) ->
            plus(plus(white(1000 + k, 0.2) |> bandpass(_ -> hi, 0.07) |> hit(0.0003, 0.007) |> gain(0.8),
                      white(1020 + k, 0.2) |> bandpass(_ -> body, 0.2) |> hit(0.0005, 0.03) |> gain(0.7)),
                 sineGlide(hi * 0.62, hi * 0.6, 0.01, 0.2) |> hit(0.0005, 0.015) |> gain(0.12));
        let beats = List.range(0, 8) |> List.map(k ->
            if (Int32.remainder(k, 2) == 0) (0.04 + beat * Int32.toFloat64(k), tick(k, 2300.0, 720.0))
            else (0.04 + beat * Int32.toFloat64(k), tick(k, 1750.0, 560.0) |> gain(0.85)));
        layout(len, beats) |> corridor(0.9) |> level(-36.8, 0.31)

    // ── 空気（輪）と風 ──

    /// 静まり返った夜の教室: 籠もった低いざわめきに、ごく薄い高いさらさらと、遠くで家鳴りが 2 回（21 秒の輪）。
    def ambQuiet(): List[Float64] =
        let len = 21.162;
        let fade = 0.8;
        let full = len + fade;
        let swell = t -> 0.8 + 0.2 * Num.sin(Num.tau() * t / (len / 3.0));
        let low = white(1101, full) |> lowpass(_ -> 140.0) |> lowpass(_ -> 220.0) |> shape(swell) |> gain(6.0);
        let air = white(1102, full) |> lowpass(_ -> 2400.0) |> highpass(500.0) |> gain(0.05);
        let creak = (k: Int32) -> white(1110 + k, 0.5) |> bandpass(t -> 540.0 + 120.0 * t, 0.04) |> hit(0.02, 0.09) |> gain(0.5);
        layout(full, (0.0, low) :: (0.0, air) :: (6.3, creak(0)) :: (14.8, creak(1) |> gain(0.7)) :: Nil)
            |> seamless(fade) |> level(-46.7, 0.12)

    /// 窓の外を抜ける風: 低いうなりがゆっくり膨らんで引き、帯の高さが揺れてヒューと細く鳴る所が 2 度ある（20 秒・1 回きり）。
    def wind(): List[Float64] =
        let len = 19.941;
        let env = t -> Num.clamp01(t / 3.0) * Num.clamp01((len - t) / 4.0) * (0.55 + 0.45 * Num.sin(Num.tau() * t / 7.5 - 1.2));
        let body = white(1201, len) |> bandpass(t -> 380.0 + 220.0 * Num.sin(Num.tau() * t / 6.1) + 80.0 * Num.sin(Num.tau() * t / 1.7), 0.35)
            |> shape(env) |> gain(1.0);
        let rumble = white(1202, len) |> lowpass(_ -> 180.0) |> shape(env) |> gain(1.8);
        let whistleEnv = t -> env(t) * Num.clamp01(Num.sin(Num.tau() * t / 9.0 - 0.6) * 2.0 - 0.6);
        let whistle = white(1203, len) |> bandpass(t -> 1150.0 + 180.0 * Num.sin(Num.tau() * t / 2.3), 0.015) |> shape(whistleEnv) |> gain(0.08);
        plus(plus(body, rumble), whistle) |> level(-34.2, 0.16)

    // ── 拾う・紙 ──

    /// 物を拾う: 小さな金物が手の中でチャリ・チャリと触れ合う（音の高さの揃わない短い鈴鳴り）と、袖の擦れ。
    def pickup(): List[Float64] =
        let len = 0.46;
        let tink = k -> tinkAt(k, 2100.0 + 1300.0 * Hash01.at(k, 21));
        let rustle = white(1301, len) |> bandpass(_ -> 1700.0, 1.0) |> shape(t -> Num.clamp01(t / 0.05) * expo(0.0 - t / 0.12)) |> gain(0.25);
        layout(len, (0.0, rustle) :: (0.01, tink(0)) :: (0.06, tink(1)) :: (0.12, tink(2)) :: (0.17, tink(3)) :: (0.26, tink(4)) :: (0.33, tink(5)) :: Nil)
            |> corridor(0.5) |> level(-33.8, 0.23)

    /// 小さな金物の 1 回の触れ合い: f Hz と、揃わない 1.37 倍の高さを重ねる。
    def tinkAt(k: Int32, f: Float64): List[Float64] =
        plus(sineGlide(f, f, 1.0, 0.12) |> hit(0.0004, 0.03 + 0.03 * Hash01.at(k, 22)),
             sineGlide(f * 1.37, f * 1.37, 1.0, 0.12) |> hit(0.0004, 0.018) |> gain(0.5)) |> gain(0.5 + 0.5 * Hash01.at(k, 23))

    /// 紙を広げる音: 擦れた雑音の短い山を 3 つ、だんだん弱く（乾いた紙のカサッ・カサ・サッ）。
    def paper(): List[Float64] =
        let crinkle = (amp: Float64, ms: Int32) -> SfxSynth.fade(SfxSynth.rasp(SfxSynth.noise(cfg(), amp, ms)));
        let hush = (ms: Int32) -> SfxSynth.tone(cfg(), 1.0, 0.0, ms);
        SfxSynth.sequence(crinkle(0.22, 70) :: hush(25) :: crinkle(0.14, 55) :: hush(35) :: SfxSynth.fade(crinkle(0.09, 120)) :: Nil)

    /// 書き出す音の一式（名前は project.json の sounds と同じ）。
    def sounds(): List[(String, List[Float64])] =
        let steps = List.range(0, 6) |> List.map(k -> ("step_${Int32.toString(k)}", step(k)));
        List.append(steps,
            ("door_classroom", doorClassroom()) :: ("door_old", doorOld()) :: ("door_rattle", doorRattle()) :: ("door_unlock", doorUnlock()) ::
            ("clock", clock()) :: ("amb_quiet", ambQuiet()) :: ("wind", wind()) :: ("pickup", pickup()) :: ("paper", paper()) :: Nil)

    /// 書き出す音の名前の集まり。
    pub def names(): Set[String] = sounds() |> List.map(fst) |> List.toSet

    /// 書き出す音の全部の中でいちばん大きい山（1 以上なら WAV で割れる）。
    pub def loudestPeak(): Float64 =
        sounds() |> List.foldLeft((acc, s) -> List.foldLeft((m, x) -> Float64.max(m, Float64.abs(x)), acc, snd(s)), 0.0)

    pub def write(): Unit \ IO = App.Headless.exitWith(writeJob())

    def writeJob(): Int32 \ IO =
        SfxSynth.renderSet(cfg(), "assets/sfx", sounds());
        println("[sfx] assets/sfx/ に効果音を書いた（足音 6・戸 4・時計・空気・風・拾う・紙）");
        0
}
