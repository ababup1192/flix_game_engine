// SfxSynth — 短い効果音を、波形の足し算だけで一から作る。録音もサンプル素材も要らず、
// 矩形波・雑音・減衰・重ね・連結という最小の語彙で「歩く音」「押す音」を組み立て、
// そのまま 16bit モノラル PCM の WAV バイト列にする。
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
    pub def wavBytes(cfg: Config, samples: List[Float64]): Bytes =
        let dataSize = List.length(samples) * 2;
        let sr = cfg#sampleRate;
        let header = List.flatten(
            tag(82, 73, 70, 70) ::         // "RIFF"
            le32(36 + dataSize) ::
            tag(87, 65, 86, 69) ::         // "WAVE"
            tag(102, 109, 116, 32) ::      // "fmt "
            le32(16) ::                    // PCM ブロックサイズ
            le16(1) ::                     // format 1 = PCM
            le16(1) ::                     // モノラル
            le32(sr) ::
            le32(sr * 2) ::                // バイトレート（16bit モノラル）
            le16(2) ::                     // ブロックアライン
            le16(16) ::                    // ビット深度
            tag(100, 97, 116, 97) ::       // "data"
            le32(dataSize) :: Nil);
        List.append(header, List.flatMap(s -> le16(clip16(s)), samples))

    /// バイト列をそのままファイルへ書き出す（副作用はここだけ）。
    pub def writeBytes(path: String, bytes: Bytes): Unit \ IO =
        let out = new BufferedOutputStream(new FileOutputStream(path));
        List.forEach(b -> out.write(b), bytes);
        out.close()

    /// 音のセットをまとめて `dir` へ描き出す。`(名前, サンプル列)` ごとに `dir/名前.wav` を書き出す
    /// （ディレクトリは無ければ作る）。ゲームの描き出し入口はデザイン（音の中身）だけ持てばよい。
    pub def renderSet(cfg: Config, dir: String, sounds: List[(String, List[Float64])]): Unit \ IO =
        discard (new File(dir)).mkdirs();
        List.forEach(sound -> {
            let (name, samples) = sound;
            writeBytes("${dir}/${name}.wav", wavBytes(cfg, samples))
        }, sounds)
}
