// SfxSynth — 短い効果音を、波形の足し算だけで一から作る。録音もサンプル素材も要らず、
// 矩形波・雑音・減衰・重ね・連結という最小の語彙で「歩く音」「押す音」を組み立て、
// そのまま 16bit モノラル PCM の WAV バイト列にする（左右 2 本ならステレオ: wavBytesStereo）。
// 利用例: ゲームの効果音をテストで描き出してアセットに置く / 値を変えて即座に鳴らし比べる。
// 注意: 各サンプルは番号の純粋な関数で決定論的（毎回同じ音）。周波数や長さといった音の
//   デザインはすべて呼び側が渡す値で、ここは合成の仕組みだけを持つ。バイト列を作る純粋部と、
//   それをファイルへ書く関数を分けてある。

pub mod SfxSynth {
    import java.io.BufferedOutputStream
    import java.io.File
    import java.io.FileOutputStream

    /// 合成の共通設定。`sampleRate` = 1 秒あたりのサンプル数。
    pub type alias Config = { sampleRate = Int32 }

    /// WAV のバイト列。各要素は 1 バイト（0..255）。
    pub type alias Bytes = List[Int32]

    /// `ms` ミリ秒ぶんのサンプル数。
    pub def frames(cfg: Config, ms: Int32): Int32 = cfg#sampleRate * ms / 1000

    /// 矩形波: `freq` Hz・振幅 `amp` を `ms` ミリ秒ぶん。減衰は持たない生の波（先細りは fade で足す）。
    pub def tone(cfg: Config, freq: Float64, amp: Float64, ms: Int32): List[Float64] =
        let sr = Int32.toFloat64(cfg#sampleRate);
        List.map(n -> {
            let t = Int32.toFloat64(n) / sr;
            if (Num.fract(t * freq) < 0.5) amp else -amp
        }, List.range(0, frames(cfg, ms)))

    /// 雑音: 番号をハッシュした擬似乱数を振幅 `amp` で `ms` ミリ秒ぶん。生の波。
    pub def noise(cfg: Config, amp: Float64, ms: Int32): List[Float64] =
        List.map(n -> {
            let h = n * 374761393 + 668265263;
            let r = Int32.toFloat64(Int32.modulo(h * (h + 30011), 20001) - 10000) / 10000.0;
            amp * r
        }, List.range(0, frames(cfg, ms)))

    /// 線形の減衰: 先頭を 1 倍・末尾を 0 倍へ落として音を先細らせる。二度重ねれば急な減衰になる。
    pub def fade(samples: List[Float64]): List[Float64] =
        let len = Int32.toFloat64(List.length(samples));
        List.zipWith((n, s) -> s * (1.0 - Int32.toFloat64(n) / len),
                     List.range(0, List.length(samples)), samples)

    /// 二つの声を重ねる（同じ位置のサンプルを足す。短い方の長さに揃う）。
    pub def blend(a: List[Float64], b: List[Float64]): List[Float64] =
        List.zipWith((x, y) -> x + y, a, b)

    /// 隣り合うサンプルの差分を取り、低い成分を落として「シャッ」というかすれた質感にする
    /// （紙を走るペン・布ずれのような高い擦過音向け。ノイズにかけると太い「ドッ」が消える）。
    /// 差分で振幅が増えるぶんは 0.7 倍に均しておく。
    pub def rasp(samples: List[Float64]): List[Float64] =
        List.zipWith((current, prev) -> (current - prev) * 0.7,
                     samples, 0.0 :: samples)

    /// 声を順に繋いで一続きにする。
    pub def sequence(voices: List[List[Float64]]): List[Float64] =
        List.flatten(voices)

    // ── WAV: 44 バイトのヘッダ + リトルエンディアン 16bit サンプル ──

    def clip16(x: Float64): Int32 =
        let v = Float64.tryToInt32(x * 32767.0) |> Option.getWithDefault(0);
        Int32.max(-32768, Int32.min(32767, v))

    def le16(v: Int32): Bytes =
        let u = if (v < 0) v + 65536 else v;
        Int32.modulo(u, 256) :: u / 256 :: Nil

    def le32(v: Int32): Bytes =
        List.append(le16(Int32.modulo(v, 65536)), le16(v / 65536))

    def tag(a: Int32, b: Int32, c: Int32, d: Int32): Bytes = a :: b :: c :: d :: Nil

    /// 一本のモノラル 16bit PCM WAV の全バイト。ヘッダがそのままファイル書式（RIFF サイズ・
    /// PCM を表す "fmt " ブロック・"data" ブロック）。
    pub def wavBytes(cfg: Config, samples: List[Float64]): Bytes = pcmBytes(cfg, 1, samples)

    /// 左右 2 本のステレオ 16bit PCM WAV の全バイト。data には左・右の順に 1 サンプルずつ交互に並べる。
    /// 長さは短い方にそろえる（左右の組が欠けないように）。
    pub def wavBytesStereo(cfg: Config, left: List[Float64], right: List[Float64]): Bytes =
        pcmBytes(cfg, 2, interleave(left, right))

    def interleave(left: List[Float64], right: List[Float64]): List[Float64] =
        List.zipWith((l, r) -> l :: r :: Nil, left, right) |> List.flatten

    /// channels 本のサンプルを交互に並べた列（interleaved）から WAV の全バイトを作る。
    def pcmBytes(cfg: Config, channels: Int32, interleaved: List[Float64]): Bytes =
        let dataSize = List.length(interleaved) * 2;
        let sr = cfg#sampleRate;
        let header = List.flatten(
            tag(82, 73, 70, 70) ::         // "RIFF"
            le32(36 + dataSize) ::
            tag(87, 65, 86, 69) ::         // "WAVE"
            tag(102, 109, 116, 32) ::      // "fmt "
            le32(16) ::                    // PCM ブロックサイズ
            le16(1) ::                     // format 1 = PCM
            le16(channels) ::              // 1 = モノラル・2 = ステレオ
            le32(sr) ::
            le32(sr * 2 * channels) ::     // バイトレート（16bit × チャンネル数）
            le16(2 * channels) ::          // ブロックアライン（1 組のバイト数）
            le16(16) ::                    // ビット深度
            tag(100, 97, 116, 97) ::       // "data"
            le32(dataSize) :: Nil);
        List.append(header, List.flatMap(s -> le16(clip16(s)), interleaved))

    /// バイト列をそのままファイルへ書き出す（副作用はここだけ）。
    /// 書き終えてから path へ置き換える — 書き先は元のアセット（assets/sfx/）なので、途中で止まって
    /// 壊れた WAV が残ると次の起動で鳴らない。
    pub def writeBytes(path: String, bytes: Bytes): Unit \ IO =
        AtomicFile.write(path, file -> {
            let out = new BufferedOutputStream(new FileOutputStream(file));
            List.forEach(b -> out.write(b), bytes);
            out.close()
        })

    /// ループ点つきの WAV の全バイト。wavBytes の後ろに "smpl" チャンク（ループ 1 本）を足す。
    /// loopStart サンプル目から終わりまでを繰り返す — 曲の頭（イントロ）を 1 回だけ鳴らして、
    /// 後ろの輪だけを回す曲を 1 本の音で持てる（頭と輪を 2 本に割って、切り替える時刻をゲームが
    /// 別に持たなくてよい）。読む側は AudioUtil.loopPointsOf（実機の OpenAL と AudioMixdown が読む）。
    /// loopStart が 0 未満・長さ以上なら smpl を付けない（頭から全部を繰り返す、ふつうの WAV）。
    pub def wavBytesLooped(cfg: Config, samples: List[Float64], loopStart: Int32): Bytes =
        loopedBytes(cfg, 1, List.length(samples), wavBytes(cfg, samples), loopStart)

    /// wavBytesLooped のステレオ版（wavBytesStereo の後ろに smpl）。ループ点は左右の組の番号で書くので、
    /// 鳴らす側（OpenAL・AudioMixdown）は左右とも同じサンプルで頭へ戻る。
    pub def wavBytesStereoLooped(cfg: Config, left: List[Float64], right: List[Float64], loopStart: Int32): Bytes =
        let n = Int32.min(List.length(left), List.length(right));
        loopedBytes(cfg, 2, n, wavBytesStereo(cfg, left, right), loopStart)

    /// plain（n 組・channels 本の WAV）に smpl チャンクを足す。範囲外の頭なら plain のまま。
    def loopedBytes(cfg: Config, channels: Int32, n: Int32, plain: Bytes, loopStart: Int32): Bytes =
        if (loopStart < 0 or loopStart >= n) plain
        else {
            let smpl = List.flatten(
                tag(115, 109, 112, 108) ::     // "smpl"
                le32(60) ::                    // 36 + ループ 1 本 24
                le32(0) :: le32(0) ::          // 作り手・製品（無し）
                le32(1000000000 / Int32.max(1, cfg#sampleRate)) :: // 1 サンプルの長さ（ナノ秒）
                le32(60) :: le32(0) ::         // 元の音の高さ（MIDI の 60 = 真ん中の C）・その端数
                le32(0) :: le32(0) ::          // SMPTE（使わない）
                le32(1) ::                     // ループの本数
                le32(0) ::                     // 後ろに付ける独自のデータ（無し）
                le32(0) ::                     // ループの番号
                le32(0) ::                     // 前へ進むループ
                le32(loopStart) ::             // 頭（この組を含む）
                le32(n - 1) ::                 // 終わり（この組を含む）
                le32(0) ::                     // 端数
                le32(0) :: Nil);               // 回数（0 = ずっと）
            // RIFF の長さの欄（4 バイト目から）だけ smpl の分を足し直す。
            let riff = le32(36 + n * 2 * channels + List.length(smpl));
            List.flatten(List.take(4, plain) :: riff :: List.drop(8, plain) :: smpl :: Nil)
        }

    /// 音のセットをまとめて `dir` へ描き出す。`(名前, サンプル列)` ごとに `dir/名前.wav` を書き出す
    /// （ディレクトリは無ければ作る）。ゲームの描き出し入口はデザイン（音の中身）だけ持てばよい。
    pub def renderSet(cfg: Config, dir: String, sounds: List[(String, List[Float64])]): Unit \ IO =
        discard (new File(dir)).mkdirs();
        List.forEach(sound -> {
            let (name, samples) = sound;
            writeBytes("${dir}/${name}.wav", wavBytes(cfg, samples))
        }, sounds)

    /// renderSet と同じ一式を書くが、同じ `inputs`・同じプログラムで前に書いた一式が `dir` にそのままの
    /// バイト列で残っていれば、`build` を呼ばずに（合成せずに）返す（RenderCache.writtenFilesKept）。
    /// `inputs` には音の中身を決める値を全部入れる（ゲームなら読んだ Doc のバイト列）。コードの違いは
    /// RenderCache が動いている jar の指紋で見るので入れなくてよい。合成したか・しなかったかを 1 行出す。
    pub def renderSetOnce(cfg: Config, dir: String, inputs: String,
                          build: Unit -> List[(String, List[Float64])]): Unit \ IO =
        let key = "sfx-set;rate=${Int32.toString(cfg#sampleRate)};dir=${dir};${inputs}";
        if (RenderCache.writtenFilesKept(key))
            println("[sfx] ${dir} は前に同じ入力で書いた一式のまま — 合成しない")
        else {
            let sounds = build();
            renderSet(cfg, dir, sounds);
            RenderCache.noteWrittenFiles(key, sounds |> List.map(sound -> "${dir}/${fst(sound)}.wav"));
            println("[sfx] ${dir} へ ${Int32.toString(List.length(sounds))} 本を合成して書いた")
        }

    /// ループ点つきの曲を `dir/名前.wav` へ書き出す（wavBytesLooped。ディレクトリは無ければ作る）。
    pub def renderLooped(cfg: Config, dir: String, name: String, samples: List[Float64], loopStart: Int32): Unit \ IO =
        discard (new File(dir)).mkdirs();
        writeBytes("${dir}/${name}.wav", wavBytesLooped(cfg, samples, loopStart))

    /// ループ点つきのステレオの曲を `dir/名前.wav` へ書き出す（wavBytesStereoLooped。ディレクトリは無ければ作る）。
    pub def renderLoopedStereo(cfg: Config, dir: String, name: String, left: List[Float64], right: List[Float64], loopStart: Int32): Unit \ IO =
        discard (new File(dir)).mkdirs();
        writeBytes("${dir}/${name}.wav", wavBytesStereoLooped(cfg, left, right, loopStart))
}
