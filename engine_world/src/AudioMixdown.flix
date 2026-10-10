// AudioMixdown — 実機の音（App.withAudio / withSustained / withMixer）を、ウィンドウ無しで
// 1 本の波形へ書き出す（動画に音を乗せる・書き換え前後を聞き比べる・波形で確かめる）。
// 中身は App と同じ AudioMixer.step を 1 コマずつ呼ぶだけなので、実機と同じ規則で混ざる:
//
// - 一発の音は 1 つの名前につき同時に 1 本（鳴り直すと頭から = OpenAL の 1 音源と同じ）。
// - 鳴り続ける音は宣言が続く間ループし、高さ（pitch）はテープの速さとして読み進める。
// - バスの音量・ダッキングはコマの間をなめらかにつなぐ。ローパスはバスごとに掛ける
//   （OpenAL の EFX の lowpass と同じ「5000Hz より上を gainHF 倍にする」棚の形）。
//
// 使い方: コマごとに { plays = その拍の withAudio の結果, sustained = withSustained の結果,
// mixer = withMixer の結果 } を並べ、音の名前 → サンプル列（loadWav）の表と一緒に渡す。
// 返るのは sampleRate の -1〜1 のサンプル列（WAV へは SfxSynth.wavBytes で書く）。
pub mod AudioMixdown {
    import java.lang.Math
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.file.Files
    import java.nio.file.Paths

    /// 1 コマぶんの音の宣言。
    pub type alias Frame = { plays = List[String], sustained = List[App.Sustain], mixer = AudioMixer.Mixer }

    /// コマの並びを sampleRate の波形へ書き出す。sounds に無い名前は鳴らない（実機と同じ）。
    pub def mixdown(sampleRate: Int32, fps: Float64, sounds: Map[String, Vector[Float64]],
                    frames: List[Frame]): Vector[Float64] = region rc {
        let rate = Int32.toFloat64(sampleRate);
        let count = List.length(frames);
        let total = Float64.tryToInt32(Float64.ceil(Int32.toFloat64(count) / fps * rate)) |> Option.getWithDefault(0);
        let out = Array.repeat(rc, Int32.max(1, total), 0.0);
        let lengthOf = name -> match Map.get(name, sounds) {
            case Some(v) => Int32.toFloat64(Vector.length(v)) / rate
            case None    => 0.0
        };
        let dt = 1.0 / fps;
        // 持ち回す物: ミキサーの状態・一発の音（名前 → 読み位置）・続く音（名前 → 読み位置）・
        // 前のコマのバスごとの倍率（なめらかにつなぐ起点）・バスごとのローパスの状態。
        let init = { mix = AudioMixer.initial(), shots = (Map.empty(): Map[String, Int32]),
                     loops = (Map.empty(): Map[String, Float64]),
                     levels = (Map.empty(): Map[String, Float64]),
                     filters = (Map.empty(): Map[String, Shelf]) };
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
            // バスごとに: このコマのサンプルを足し上げ → ローパス → 倍率をなめらかにつないで out へ。
            let mixBus = (acc, bus) -> {
                let (lv, fl) = acc;
                let buf = Array.repeat(rc, span, 0.0);
                Map.forEach((name, pos) ->
                    if (AudioMixer.busOf(f#mixer, name) != bus) ()
                    else match Map.get(name, sounds) {
                        case Some(v) => addShot(v, pos, span, buf)
                        case None    => ()
                    }, shots);
                Map.forEach((name, h) ->
                    if (AudioMixer.busOf(f#mixer, name) != bus) ()
                    else match Map.get(name, sounds) {
                        case Some(v) =>
                            let pos = Map.get(name, loops) |> Option.getWithDefault(0.0);
                            addLoop(v, pos, h#pitch, h#volume, span, buf)
                        case None => ()
                    }, declared);
                let shelf0 = Map.get(bus, fl) |> Option.getWithDefault(shelfOf(1.0, rate));
                // バスの値は実機（App.applyMixed）と同じ AudioMixer の読み出しで決める。
                let target = AudioMixer.busGainOf(f#mixer, mix, bus);
                let lowpass = AudioMixer.busLowpassGainHFOf(f#mixer, mix, bus);
                let shelf = filterInPlace({ coeffs = coeffsOf(lowpass, rate) | shelf0 }, buf);
                let start = Map.get(bus, lv) |> Option.getWithDefault(target);
                List.range(0, span) |> List.forEach(k -> {
                    let at = first + k;
                    if (at < total) {
                        let g = start + (target - start) * Int32.toFloat64(k) / Int32.toFloat64(span);
                        Array.put(Array.get(at, out) + Array.get(k, buf) * g, at, out)
                    } else ()
                });
                (Map.insert(bus, target, lv), Map.insert(bus, shelf, fl))
            };
            let (mixed, filters) = List.foldLeft(mixBus, (st#levels, st#filters), buses);
            // このコマで鳴らなかったバスの倍率は捨てる（次に鳴ったとき古い値から寄ってこないように）。
            let levels = Map.filterWithKey((bus, _) -> List.memberOf(bus, buses), mixed);
            // 読み位置を進める。一発の音は鳴り終わったら外す。
            let nextShots = shots
                |> Map.map(pos -> pos + span)
                |> Map.filterWithKey((name, pos) -> match Map.get(name, sounds) {
                    case Some(v) => pos < Vector.length(v)
                    case None    => false
                });
            let nextLoops = declared |> Map.mapWithKey((name, h) ->
                (Map.get(name, loops) |> Option.getWithDefault(0.0)) + Float64.max(0.01, h#pitch) * Int32.toFloat64(span));
            { mix = mix, shots = nextShots, loops = nextLoops, levels = levels, filters = filters }
        };
        let _final = List.foldLeft(stepFrame, init, List.zip(List.range(0, count), frames));
        Array.toVector(out)
    }

    /// 一発の音を pos から span サンプルぶん足す。
    def addShot(v: Vector[Float64], pos: Int32, span: Int32, buf: Array[Float64, r]): Unit \ r =
        let n = Vector.length(v);
        List.range(0, span) |> List.forEach(k ->
            if (pos + k < n) Array.put(Array.get(k, buf) + Vector.get(pos + k, v), k, buf) else ())

    /// 続く音を読み位置 pos から高さ pitch の速さで読み、音量 volume で足す（端は頭へ回る）。
    def addLoop(v: Vector[Float64], pos: Float64, pitch: Float64, volume: Float64, span: Int32, buf: Array[Float64, r]): Unit \ r =
        let n = Vector.length(v);
        if (n == 0) ()
        else List.range(0, span) |> List.forEach(k -> {
            let p = pos + Float64.max(0.01, pitch) * Int32.toFloat64(k);
            let i = Float64.tryToInt32(floorF(p)) |> Option.getWithDefault(0);
            let frac = p - floorF(p);
            let a = Vector.get(Int32.modulo(i, n), v);
            let b = Vector.get(Int32.modulo(i + 1, n), v);
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
        let bytes = Files.readAllBytes(Paths.get(path));
        let hdr = ByteBuffer.wrap(bytes);
        discard hdr.order(ByteOrder.LITTLE_ENDIAN);
        if (hdr.limit() < 44) Vector.empty()
        else {
            let channels = Int32.max(1, Int16.toInt32(hdr.getShort(22)));
            let rate = hdr.getInt(24);
            match AudioUtil.findDataChunkOffset(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit(), 12) {
                case None      => Vector.empty()
                case Some(off) =>
                    let size = Int32.min(hdr.getInt(off + 4), hdr.limit() - off - 8);
                    let frames = size / (2 * channels);
                    let at = k -> {
                        let base = off + 8 + k * 2 * channels;
                        let sum = List.range(0, channels) |> List.foldLeft((acc, c) ->
                            acc + Int16.toFloat64(hdr.getShort(base + c * 2)), 0.0);
                        sum / Int32.toFloat64(channels) / 32768.0
                    };
                    // 違うサンプルレートは隣り合う 2 点の間をなめらかにつないで読み直す。
                    let ratio = Int32.toFloat64(rate) / Int32.toFloat64(sampleRate);
                    let n = Float64.tryToInt32(Int32.toFloat64(frames) / ratio) |> Option.getWithDefault(0);
                    Vector.range(0, n) |> Vector.map(i -> {
                        let p = Int32.toFloat64(i) * ratio;
                        let k = Int32.min(frames - 1, Float64.tryToInt32(floorF(p)) |> Option.getWithDefault(0));
                        let a = at(k);
                        a + (at(Int32.min(frames - 1, k + 1)) - a) * (p - floorF(p))
                    })
            }
        }

    /// 波形のいちばん大きな振れ幅（0〜）。割れの確かめと、書き出す前の音量合わせに使う。
    pub def peakOf(samples: Vector[Float64]): Float64 =
        Vector.foldLeft((acc, x) -> Float64.max(acc, Float64.abs(x)), 0.0, samples)
}
