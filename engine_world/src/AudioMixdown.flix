// AudioMixdown — 実機の音（App.withAudio / withSustained / withMixer）を、ウィンドウ無しで
// 1 本の波形へ書き出す（動画に音を乗せる・書き換え前後を聞き比べる・波形で確かめる）。
// 中身は App と同じ AudioMixer.step を 1 コマずつ呼ぶだけなので、実機と同じ規則で混ざる:
//
// - 一発の音は 1 つの名前につき同時に 1 本（鳴り直すと頭から = OpenAL の 1 音源と同じ）。
// - 鳴り続ける音は宣言が続く間ループし、高さ（pitch）はテープの速さとして読み進める。WAV にループ点
//   （smpl チャンク）があれば mixdownLooped で頭のイントロを 1 回だけ鳴らし、後ろの輪だけを回す。
// - バスの音量・ダッキングはコマの間をなめらかにつなぐ。ローパスはバスごとに掛ける
//   （OpenAL の EFX の lowpass と同じ「5000Hz より上を gainHF 倍にする」棚の形）。
//
// 使い方: コマごとに { plays = その拍の withAudio の結果, sustained = withSustained の結果,
// mixer = withMixer の結果 } を並べ、音の名前 → サンプル列（loadWav）の表と一緒に渡す。
// 返るのは sampleRate の -1〜1 のサンプル列（WAV へは SfxSynth.wavBytes で書く）。
//
// ステレオ: mixdownStereo に loadWavStereo の表を渡すと左右 2 本のまま混ぜる（WAV へは SfxSynth.wavBytesStereo）。
// モノラルの素材は左右に同じ音で入る。ループの頭・鳴り直し・バスの倍率・ローパスは左右で同じ所に効く
// （左右で継ぎ目がずれない）。mixdown / loadWav は今までどおりモノラル（ステレオの素材は左右の平均）。
pub mod AudioMixdown {
    import java.lang.Math
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.file.Files
    import java.nio.file.Paths

    /// 1 コマぶんの音の宣言。
    pub type alias MixFrame = { plays = List[String], sustained = List[App.Sustain], mixer = AudioMixer.Mixer }

    /// コマの並びを sampleRate の波形へ書き出す。sounds に無い名前は鳴らない（実機と同じ）。
    pub def mixdown(sampleRate: Int32, fps: Float64, sounds: Map[String, Vector[Float64]],
                    frames: List[MixFrame]): Vector[Float64] =
        mixdownLooped(sampleRate, fps, sounds, Map.empty(), frames)

    /// mixdown に、鳴り続ける音のループ点を足した物。loopStarts = 名前 → 繰り返しの頭のサンプル番号
    /// （loadLoopStart で WAV の smpl チャンクから読む）。頭より前（曲のイントロ）は 1 回だけ鳴り、
    /// 終わりまで読んだら頭へ戻る —— 実機の OpenAL（AL_SOFT_loop_points）と同じ回り方。表に無い名前は全部を繰り返す。
    pub def mixdownLooped(sampleRate: Int32, fps: Float64, sounds: Map[String, Vector[Float64]],
                          loopStarts: Map[String, Int32], frames: List[MixFrame]): Vector[Float64] =
        let out = mixChannels(1, sampleRate, fps, Map.map(v -> Vector#{v}, sounds), loopStarts, frames);
        Vector.head(out) |> Option.getWithDefault(Vector.empty())

    /// 左右 2 本の波形（同じ長さ）。モノラルの素材は左右に同じ列を置く（loadWavStereo がそう読む）。
    pub type alias Stereo = { left = Vector[Float64], right = Vector[Float64] }

    /// mixdownLooped の左右 2 本版（動画の音をステレオで書き出す）。混ぜ方の規則は mixdownLooped と同じで、
    /// 左右それぞれに同じ読み位置・同じ倍率・同じローパスを掛ける —— ループの頭へ戻るサンプルも左右で同じ。
    pub def mixdownStereo(sampleRate: Int32, fps: Float64, sounds: Map[String, Stereo],
                          loopStarts: Map[String, Int32], frames: List[MixFrame]): Stereo =
        let out = mixChannels(2, sampleRate, fps, Map.map(st -> Vector#{st#left, st#right}, sounds), loopStarts, frames);
        let channel = c -> if (c < Vector.length(out)) Vector.get(c, out) else Vector.empty();
        { left = channel(0), right = channel(1) }

    /// 混ぜる芯。sounds = 名前 → チャンネルごとの列（chans 本より少なければ最後の列を使い回す = モノラルは左右に同じ）。
    /// 返すのは chans 本の列。
    def mixChannels(chans: Int32, sampleRate: Int32, fps: Float64, sounds: Map[String, Vector[Vector[Float64]]],
                    loopStarts: Map[String, Int32], frames: List[MixFrame]): Vector[Vector[Float64]] = region rc {
        let rate = Int32.toFloat64(sampleRate);
        let count = List.length(frames);
        let total = Float64.tryToInt32(Float64.ceil(Int32.toFloat64(count) / fps * rate)) |> Option.getWithDefault(0);
        let outs = Vector.map(_ -> Array.repeat(rc, Int32.max(1, total), 0.0), Vector.range(0, chans));
        let channelOf = (v, c) -> {
            let n = Vector.length(v);
            if (n == 0) Vector.empty() else Vector.get(Int32.min(c, n - 1), v)
        };
        let samplesOf = v -> Vector.length(channelOf(v, 0));
        let lengthOf = name -> match Map.get(name, sounds) {
            case Some(v) => Int32.toFloat64(samplesOf(v)) / rate
            case None    => 0.0
        };
        let dt = 1.0 / fps;
        // 持ち回す物: ミキサーの状態・一発の音（名前 → 読み位置）・続く音（名前 → 読み位置）・
        // 前のコマのバスごとの倍率（なめらかにつなぐ起点）・(バス, チャンネル) ごとのローパスの状態。
        let init = { mix = AudioMixer.initial(), shots = (Map.empty(): Map[String, Int32]),
                     loops = (Map.empty(): Map[String, Float64]),
                     levels = (Map.empty(): Map[String, Float64]),
                     filters = (Map.empty(): Map[(String, Int32), Shelf]) };
        let stepFrame = (st, pair) -> {
            let (i, f) = pair;
            let first = Float64.tryToInt32(Int32.toFloat64(i) * dt * rate) |> Option.getWithDefault(0);
            let last = Int32.min(total, Float64.tryToInt32(Int32.toFloat64(i + 1) * dt * rate) |> Option.getWithDefault(0));
            let living = f#sustained |> List.map(h -> h#name) |> List.distinct;
            let (allowed, mix) = AudioMixer.step(f#mixer, lengthOf, dt, f#plays, living, st#mix);
            // 鳴り直す一発の音は頭から（OpenAL の 1 音源と同じ）。宣言の消えた続く音は止めて頭へ戻す。
            let shots = allowed |> List.foldLeft((acc, name) -> Map.insert(name, 0, acc), st#shots);
            let loops = Map.filterWithKey((name, _) -> List.memberOf(name, living), st#loops);
            let declared = f#sustained |> List.foldLeft((acc, h) -> if (Map.memberOf(h#name, acc)) acc else Map.insert(h#name, h, acc), Map.empty());
            let buses = List.append(Map.keysOf(shots) |> Set.toList, living)
                |> List.map(name -> AudioMixer.busOf(f#mixer, name)) |> List.distinct;
            let span = Int32.max(1, last - first);
            let channels = List.range(0, chans);
            // バスごとに: このコマのサンプルを足し上げ → ローパス → 倍率をなめらかにつないで out へ（チャンネルごとに同じ手順）。
            let mixBus = (acc, bus) -> {
                let (lv, fl) = acc;
                let bufs = Vector.map(_ -> Array.repeat(rc, span, 0.0), Vector.range(0, chans));
                Map.forEach((name, pos) ->
                    if (AudioMixer.busOf(f#mixer, name) != bus) ()
                    else match Map.get(name, sounds) {
                        case Some(v) => channels |> List.forEach(c -> addShot(channelOf(v, c), pos, span, Vector.get(c, bufs)))
                        case None    => ()
                    }, shots);
                Map.forEach((name, h) ->
                    if (AudioMixer.busOf(f#mixer, name) != bus) ()
                    else match Map.get(name, sounds) {
                        case Some(v) =>
                            let pos = Map.get(name, loops) |> Option.getWithDefault(0.0);
                            let head = Map.get(name, loopStarts) |> Option.getWithDefault(0);
                            channels |> List.forEach(c -> addLoop(channelOf(v, c), head, pos, h#pitch, h#volume, span, Vector.get(c, bufs)))
                        case None => ()
                    }, declared);
                // バスの値は実機（App.applyMixed）と同じ AudioMixer の読み出しで決める。
                let target = AudioMixer.busGainOf(f#mixer, mix, bus);
                let lowpass = AudioMixer.busLowpassGainHFOf(f#mixer, mix, bus);
                let start = Map.get(bus, lv) |> Option.getWithDefault(target);
                let nextFl = channels |> List.foldLeft((m, c) -> {
                    let buf = Vector.get(c, bufs);
                    let out = Vector.get(c, outs);
                    let shelf0 = Map.get((bus, c), m) |> Option.getWithDefault(shelfOf(1.0, rate));
                    let shelf = filterInPlace({ coeffs = coeffsOf(lowpass, rate) | shelf0 }, buf);
                    List.range(0, span) |> List.forEach(k -> {
                        let at = first + k;
                        if (at < total) {
                            let g = start + (target - start) * Int32.toFloat64(k) / Int32.toFloat64(span);
                            Array.put(Array.get(at, out) + Array.get(k, buf) * g, at, out)
                        } else ()
                    });
                    Map.insert((bus, c), shelf, m)
                }, fl);
                (Map.insert(bus, target, lv), nextFl)
            };
            let (mixed, filters) = List.foldLeft(mixBus, (st#levels, st#filters), buses);
            // このコマで鳴らなかったバスの倍率は捨てる（次に鳴ったとき古い値から寄ってこないように）。
            let levels = Map.filterWithKey((bus, _) -> List.memberOf(bus, buses), mixed);
            // 読み位置を進める。一発の音は鳴り終わったら外す。
            let nextShots = shots
                |> Map.map(pos -> pos + span)
                |> Map.filterWithKey((name, pos) -> match Map.get(name, sounds) {
                    case Some(v) => pos < samplesOf(v)
                    case None    => false
                });
            let nextLoops = declared |> Map.mapWithKey((name, h) ->
                (Map.get(name, loops) |> Option.getWithDefault(0.0)) + Float64.max(0.01, h#pitch) * Int32.toFloat64(span));
            { mix = mix, shots = nextShots, loops = nextLoops, levels = levels, filters = filters }
        };
        let _final = List.foldLeft(stepFrame, init, List.zip(List.range(0, count), frames));
        Vector.map(Array.toVector, outs)
    }

    /// 一発の音を pos から span サンプルぶん足す。
    def addShot(v: Vector[Float64], pos: Int32, span: Int32, buf: Array[Float64, r]): Unit \ r =
        let n = Vector.length(v);
        List.range(0, span) |> List.forEach(k ->
            if (pos + k < n) Array.put(Array.get(k, buf) + Vector.get(pos + k, v), k, buf) else ())

    /// 続く音を読み位置 pos から高さ pitch の速さで読み、音量 volume で足す（端はループの頭 head へ回る）。
    def addLoop(v: Vector[Float64], head: Int32, pos: Float64, pitch: Float64, volume: Float64, span: Int32, buf: Array[Float64, r]): Unit \ r =
        let n = Vector.length(v);
        let first = if (head > 0 and head < n) head else 0;
        let wrap = i -> if (i < n) i else first + Int32.modulo(i - first, n - first);
        if (n == 0) ()
        else List.range(0, span) |> List.forEach(k -> {
            let p = pos + Float64.max(0.01, pitch) * Int32.toFloat64(k);
            let i = Float64.tryToInt32(floorF(p)) |> Option.getWithDefault(0);
            let frac = p - floorF(p);
            let a = Vector.get(wrap(i), v);
            let b = Vector.get(wrap(i + 1), v);
            Array.put(Array.get(k, buf) + (a + (b - a) * frac) * volume, k, buf)
        })

    // ── ローパス（OpenAL の EFX の lowpass と同じ形: 5000Hz を境に上を gainHF 倍にする高い棚）──

    /// 棚の係数（b0 b1 b2 a1 a2。a0 で割ってある）と、直前の 2 サンプルずつの入出力。
    type alias Shelf = { coeffs = (Float64, Float64, Float64, Float64, Float64),
                         x1 = Float64, x2 = Float64, y1 = Float64, y2 = Float64 }

    def shelfOf(gainHF: Float64, rate: Float64): Shelf =
        { coeffs = coeffsOf(gainHF, rate), x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0 }

    /// RBJ の high-shelf（傾き 1）。gainHF = 1 なら素通し（b0 = 1・ほかは 0）。
    def coeffsOf(gainHF: Float64, rate: Float64): (Float64, Float64, Float64, Float64, Float64) =
        let g = Float64.max(0.001, Float64.min(1.0, gainHF));
        if (g >= 0.999) (1.0, 0.0, 0.0, 0.0, 0.0)
        else {
            let a = sqrtF(g);
            let w0 = 2.0 * 3.141592653589793 * Float64.min(0.49, 5000.0 / rate);
            let cosW = cosF(w0);
            let alpha = sinF(w0) / 2.0 * sqrtF(2.0);
            let sq = 2.0 * sqrtF(a) * alpha;
            let b0 = a * ((a + 1.0) + (a - 1.0) * cosW + sq);
            let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW);
            let b2 = a * ((a + 1.0) + (a - 1.0) * cosW - sq);
            let a0 = (a + 1.0) - (a - 1.0) * cosW + sq;
            let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW);
            let a2 = (a + 1.0) - (a - 1.0) * cosW - sq;
            (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        }

    /// buf をその場で棚に通し、次のコマへ渡す直前のサンプルを返す。
    def filterInPlace(shelf: Shelf, buf: Array[Float64, r]): Shelf \ r =
        let (b0, b1, b2, a1, a2) = shelf#coeffs;
        let n = Array.length(buf);
        List.range(0, n) |> List.foldLeft((s, k) -> {
            let x = Array.get(k, buf);
            let y = b0 * x + b1 * s#x1 + b2 * s#x2 - a1 * s#y1 - a2 * s#y2;
            Array.put(y, k, buf);
            { x1 = x, x2 = s#x1, y1 = y, y2 = s#y1 | s }
        }, shelf)

    // java.lang.Math は純粋な計算だが IO として見えるので、ここで外す（Dsp と同じ）。
    def floorF(x: Float64): Float64 = Math.floor(x)
    def sqrtF(x: Float64): Float64 = unchecked_cast(Math.sqrt(x) as _ \ {})
    def cosF(x: Float64): Float64 = unchecked_cast(Math.cos(x) as _ \ {})
    def sinF(x: Float64): Float64 = unchecked_cast(Math.sin(x) as _ \ {})

    // ── 読み込み ──

    /// WAV（PCM 16bit。モノラル・ステレオ）を sampleRate のモノラル -1〜1 へ読む。
    /// 読めなければ空。ステレオは左右を平均し、違うサンプルレートは近い方の点で読み直す。
    pub def loadWav(sampleRate: Int32, path: String): Vector[Float64] \ IO =
        match loadPcm(path) {
            case None => Vector.empty()
            case Some(pcm) =>
                let average = k -> List.range(0, pcm#channels)
                    |> List.foldLeft((acc, c) -> acc + pcm#sampleAt(c, k), 0.0)
                    |> (sum -> sum / Int32.toFloat64(pcm#channels));
                resample(pcm#rate, sampleRate, pcm#frames, average)
        }

    /// WAV（PCM 16bit）を sampleRate の左右 2 本へ読む（mixdownStereo へ渡す）。モノラルは左右に同じ列。
    /// 3 チャンネル以上は頭の 2 本（左・右）だけを使う。読めなければ左右とも空。
    /// サンプルレートの読み直しは loadWav と同じで、左右を同じ位置で読むので長さもループの頭もそろう。
    pub def loadWavStereo(sampleRate: Int32, path: String): Stereo \ IO =
        match loadPcm(path) {
            case None => { left = Vector.empty(), right = Vector.empty() }
            case Some(pcm) =>
                let left = resample(pcm#rate, sampleRate, pcm#frames, k -> pcm#sampleAt(0, k));
                let right = if (pcm#channels < 2) left else resample(pcm#rate, sampleRate, pcm#frames, k -> pcm#sampleAt(1, k));
                { left = left, right = right }
        }

    /// WAV の中身: チャンネル数・サンプルレート・組の数と、(チャンネル, 組の番号) → -1〜1 のサンプル。
    /// 16bit の PCM だけを読む（ほかは None）。形式は fmt チャンクから（AudioUtil.formatOf）。
    def loadPcm(path: String): Option[{ channels = Int32, rate = Int32, frames = Int32, sampleAt = (Int32, Int32) -> Float64 \ IO }] \ IO =
        let bytes = Files.readAllBytes(Paths.get(path));
        let hdr = ByteBuffer.wrap(bytes);
        discard hdr.order(ByteOrder.LITTLE_ENDIAN);
        if (hdr.limit() < 44) None
        else {
            let (channels0, rate, bits) = AudioUtil.formatOf(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit())
                |> Option.getWithDefault((Int16.toInt32(hdr.getShort(22)), hdr.getInt(24), 16));
            let channels = Int32.max(1, channels0);
            match AudioUtil.findDataChunkOffset(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit(), 12) {
                case Some(off) if bits == 16 and rate > 0 =>
                    let size = Int32.min(hdr.getInt(off + 4), hdr.limit() - off - 8);
                    let sampleAt = (c, k) -> Int16.toFloat64(hdr.getShort(off + 8 + (k * channels + c) * 2)) / 32768.0;
                    Some({ channels = channels, rate = rate, frames = AudioUtil.framesOf(size, channels, 16), sampleAt = sampleAt })
                case _ => None
            }
        }

    /// rate の frames 個の列（at(k) で k 番目）を sampleRate で読み直す（隣り合う 2 点の間をなめらかにつなぐ）。
    def resample(rate: Int32, sampleRate: Int32, frames: Int32, at: Int32 -> Float64 \ IO): Vector[Float64] \ IO =
        let ratio = Int32.toFloat64(rate) / Int32.toFloat64(sampleRate);
        let n = Float64.tryToInt32(Int32.toFloat64(frames) / ratio) |> Option.getWithDefault(0);
        Vector.range(0, n) |> Vector.map(i -> {
            let p = Int32.toFloat64(i) * ratio;
            let k = Int32.min(frames - 1, Float64.tryToInt32(floorF(p)) |> Option.getWithDefault(0));
            let a = at(k);
            a + (at(Int32.min(frames - 1, k + 1)) - a) * (p - floorF(p))
        })

    /// WAV のループ点の頭（smpl チャンク。AudioUtil.loopPointsOf）を、sampleRate で読み直したときの
    /// サンプル番号で返す（loadWav と同じ読み直し）。ステレオでも組の番号なので、左右 2 本に同じ頭が効く。
    /// ループ点の無い WAV・読めないファイルは None。
    pub def loadLoopStart(sampleRate: Int32, path: String): Option[Int32] \ IO =
        let bytes = Files.readAllBytes(Paths.get(path));
        let hdr = ByteBuffer.wrap(bytes);
        discard hdr.order(ByteOrder.LITTLE_ENDIAN);
        if (hdr.limit() < 44) None
        else {
            let rate = match AudioUtil.formatOf(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit()) {
                case Some((_, r, _)) => r
                case None            => hdr.getInt(24)
            };
            let ratio = Int32.toFloat64(rate) / Int32.toFloat64(Int32.max(1, sampleRate));
            AudioUtil.loopPointsOf(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit())
                |> Option.flatMap(points -> { let (start, _) = points; Float64.tryToInt32(Float64.round(Int32.toFloat64(start) / ratio)) })
        }

    /// 波形のいちばん大きな振れ幅（0〜）。割れの確かめと、書き出す前の音量合わせに使う。
    pub def peakOf(samples: Vector[Float64]): Float64 =
        Vector.foldLeft((acc, x) -> Float64.max(acc, Float64.abs(x)), 0.0, samples)
}
