// SoundLength — 効果音の長さ（秒）。<<audio se 音 wait=true>> が待つ秒（Res#soundSeconds）。
// 実機（デスクトップ・ブラウザ）は機種に聞き（GameEngine.Audio.audioSeconds）、ウィンドウなし（テスト・描き出し・flow）は WAV の頭から読む。
// 鳴り続ける音（looping）は入れない。長さが分からない音は表に入れない（その音の wait=true は待たない）。
mod SoundLength {
    use fge::{GameEngine, ProjectLoader}

    /// project.json の sounds のうち鳴り続けない音の、名前 → 長さ（秒。機種が読み込んだ音の長さ）。project.json が読めなければ空。
    // WhyNot: 実機でも WAV を Fs.FileRead で読まない — ブラウザ版の音は WebAudio へ直に渡り、Fs の表に無いので必ず読めない。
    pub def load(): Map[String, Float64] \ {Fs.FileRead, GameEngine.Audio} =
        unloopedIn(".")
            |> List.filterMap(s -> Some((s#name, GameEngine.Audio.audioSeconds(s#name))) |> Option.filter(p -> snd(p) > 0.0))
            |> List.toMap

    /// dir の project.json の sounds の長さを WAV の頭から読む（ウィンドウなし用。WAV の場所は dir から）。project.json が無ければ空。
    pub def loadIn(dir: String): Map[String, Float64] \ Fs.FileRead =
        unloopedIn(dir)
            |> List.filterMap(s -> Fs.FileRead.readBytes(s#path) |> Result.toOption |> Option.flatMap(wavSeconds) |> Option.map(v -> (s#name, v)))
            |> List.toMap

    /// dir の project.json の sounds のうち鳴り続けない物。
    def unloopedIn(dir: String): List[GameEngine.AudioEntry] \ Fs.FileRead =
        match ProjectLoader.loadProject(dir) {
            case Ok(p)  => p#config#soundManifest |> List.filter(s -> not s#looping)
            case Err(_) => Nil
        }

    /// チャンク 1 つ: tagAt = 名前の頭、body = 中身の頭、size = 中身の大きさ。
    type alias Chunk = { tagAt = Int32, body = Int32, size = Int64 }

    /// WAV（RIFF）の長さ（秒）: data の大きさ ÷ 1 秒の大きさ（fmt の byteRate）。RIFF でない・欄が無ければ None。
    pub def wavSeconds(bytes: Vector[Int8]): Option[Float64] =
        if (Vector.length(bytes) < 12 or not isTag("RIFF", 0, bytes) or not isTag("WAVE", 8, bytes)) None
        else {
            let chunks = chunksFrom(12, bytes, Nil);
            forM (fmt <- List.find(c -> isTag("fmt ", c#tagAt, bytes), chunks) |> Option.filter(c -> c#body + 12 <= Vector.length(bytes));
                  data <- List.find(c -> isTag("data", c#tagAt, bytes), chunks);
                  rate <- Some(u32At(fmt#body + 8, bytes)) |> Option.filter(r -> r > 0i64))
            yield Int64.toFloat64(data#size) / Int64.toFloat64(rate)
        }

    /// at から並ぶチャンク（大きさが奇数なら 1 つ詰め物がある）。
    def chunksFrom(at: Int32, bytes: Vector[Int8], acc: List[Chunk]): List[Chunk] =
        if (at + 8 > Vector.length(bytes)) List.reverse(acc)
        else {
            let size = u32At(at + 4, bytes);
            let next = Int64.tryToInt32(Int32.toInt64(at) + 8i64 + size + Int64.modulo(size, 2i64)) |> Option.getWithDefault(Vector.length(bytes));
            chunksFrom(next, bytes, { tagAt = at, body = at + 8, size = size } :: acc)
        }

    def byteAt(i: Int32, bytes: Vector[Int8]): Int64 =
        let b = Int8.toInt64(Vector.get(i, bytes));
        if (b < 0i64) b + 256i64 else b

    def u32At(i: Int32, bytes: Vector[Int8]): Int64 =
        byteAt(i, bytes) + byteAt(i + 1, bytes) * 256i64 + byteAt(i + 2, bytes) * 65536i64 + byteAt(i + 3, bytes) * 16777216i64

    /// i から 4 バイトが tag（ASCII 4 字）か。
    def isTag(tag: String, i: Int32, bytes: Vector[Int8]): Bool =
        i + 4 <= Vector.length(bytes) and
            (String.toList(tag) |> List.zipWithIndex |> List.forAll(match (k, c) -> Int32.toInt64(Char.toBmpCodePoint(c)) == byteAt(i + k, bytes)))
}
