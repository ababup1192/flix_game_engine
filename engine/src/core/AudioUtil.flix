// AudioUtil — 音声ファイル（WAV）の中身を読み解くための小さな計算。
// 音の形式（モノラル/ステレオ・ビット数）の判別や、波形データの在り処探しを一箇所にまとめる。
// 利用例: 効果音を鳴らす前に再生形式を決める / WAV から実際の音データの位置を突き止める。
// 注意: バイト列の解釈だけで、実際のファイル読み込みや再生は扱わない純粋な計算。

pub mod AudioUtil {

    // ========================================================================
    // OpenAL format constants
    // ========================================================================

    pub def alFormatMono8(): Int32 = 0x1100
    pub def alFormatMono16(): Int32 = 0x1101
    pub def alFormatStereo8(): Int32 = 0x1102
    pub def alFormatStereo16(): Int32 = 0x1103

    /// チャンネル数（1=モノラル/2=ステレオ）とビット数から、再生に使う音声形式を選ぶ。
    pub def alFormat(channels: Int32, bitsPerSample: Int32): Int32 =
        if (channels == 1) {
            if (bitsPerSample == 8) alFormatMono8() else alFormatMono16()
        } else {
            if (bitsPerSample == 8) alFormatStereo8() else alFormatStereo16()
        }

    // ========================================================================
    // WAV chunk parsing
    // ========================================================================

    /// Find the byte offset of the "data" chunk in WAV byte data.
    /// Searches from `offset`, skipping unknown chunks using their size fields.
    /// `getByte(i)` reads one byte at index i.
    /// `getInt32LE(i)` reads a little-endian Int32 at index i.
    /// Returns None if the data chunk is not found before `limit`.
    pub def findDataChunkOffset(getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef, limit: Int32, offset: Int32): Option[Int32] \ ef =
        if (offset >= limit - 8) None
        else if (getByte(offset) == 100i8 and      // 'd'
                 getByte(offset + 1) == 97i8 and   // 'a'
                 getByte(offset + 2) == 116i8 and  // 't'
                 getByte(offset + 3) == 97i8)      // 'a'
            Some(offset)
        else {
            let chunkSize = getInt32LE(offset + 4);
            findDataChunkOffset(getByte, getInt32LE, limit, offset + 8 + chunkSize)
        }

    /// WAV の中の名前 a b c d（4 文字の ASCII。"smpl" なら 115 109 112 108）のチャンクの位置を探す。
    /// 探し方は findDataChunkOffset と同じ（offset から、知らないチャンクは長さの欄で飛ばす）。
    /// チャンクの長さが奇数のときは、RIFF の決まりどおり 1 バイトの詰め物も飛ばす。
    pub def findChunkOffset(a: Int8, b: Int8, c: Int8, d: Int8,
                            getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef,
                            limit: Int32, offset: Int32): Option[Int32] \ ef =
        if (offset >= limit - 8) None
        else if (getByte(offset) == a and getByte(offset + 1) == b and getByte(offset + 2) == c and getByte(offset + 3) == d)
            Some(offset)
        else {
            let chunkSize = getInt32LE(offset + 4);
            if (chunkSize < 0) None
            else findChunkOffset(a, b, c, d, getByte, getInt32LE, limit, offset + 8 + chunkSize + Int32.remainder(chunkSize, 2))
        }

    /// WAV のループ点（"smpl" チャンクの最初のループ）。返すのは (頭, 終わり) のサンプル番号で、
    /// 終わりは含まない（[頭, 終わり) を繰り返す。smpl の end は最後のサンプルを含む書き方なので 1 足す）。
    /// 曲の頭（イントロ）を 1 回だけ鳴らし、後ろの輪だけを繰り返す音に使う（Godot の WAV の取り込みと同じ読み方）。
    /// smpl が無い・ループが 0 本・頭と終わりの順が逆なら None（頭から終わりまで全部を繰り返す）。
    pub def loopPointsOf(getByte: Int32 -> Int8 \ ef, getInt32LE: Int32 -> Int32 \ ef, limit: Int32): Option[(Int32, Int32)] \ ef =
        match findChunkOffset(115i8, 109i8, 112i8, 108i8, getByte, getInt32LE, limit, 12) {
            case None      => None
            case Some(off) =>
                let body = off + 8;
                let size = getInt32LE(off + 4);
                if (size < 60 or body + 60 > limit) None
                else {
                    let loops = getInt32LE(body + 28);
                    let start = getInt32LE(body + 36 + 8);
                    let last = getInt32LE(body + 36 + 12);
                    if (loops < 1 or start < 0 or last < start) None else Some((start, last + 1))
                }
        }

}
