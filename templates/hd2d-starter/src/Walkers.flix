// Walkers — 隊列の 1 人の絵の帯（向きごとのコマを横に並べた PNG）から、向きとコマで 1 コマを切り出す。
// 帯は dirs の字の順に向きを並べ（"nes" = 背中・右・正面）、向きごとに perDir コマ。dirs に w が無ければ左は右の反転。
mod Walkers {
    use fge::{Num, Rect2}

    /// 隊列の 1 人。strip = 歩きの帯（向きごとに 4 コマ）・idleStrip = 待機モーションの帯（向きごとに 吸った・吐いた の 2 コマ）・
    /// dirs = 帯に並ぶ向きの字の順。
    pub type alias Walker = { strip = String, idleStrip = String, dirs = String }

    /// 帯の中の 1 コマ。dirs = 帯に並ぶ向きの数・row = 何番目の向きか・perDir = 向きごとのコマ数・frame = 向きの中の何コマ目か。
    pub type alias Cell = { dirs = Int32, row = Int32, perDir = Int32, frame = Int32 }

    /// 歩きの帯の向きごとのコマ数。
    pub def walkFrames(): Int32 = 4

    /// 待機モーションの帯の向きごとのコマ数。
    pub def idleFrames(): Int32 = 2

    /// 向き d → 帯の中の段（dirs の字の順）と左右反転（dirs に w が無ければ左は右の反転）。
    pub def rowOf(dirs: String, d: Facing.Dir): (Int32, Bool) =
        let flip = d == Facing.Dir.West and not String.contains(substr = "w", dirs);
        (String.indexOf(substr = if (flip) "e" else Facing.letterOf(d), dirs) |> Option.getWithDefault(0), flip)

    /// 1 人の向き d・帯のコマ数 perDir・コマ frame の Cell と左右反転。
    pub def cellOf(w: Walker, d: Facing.Dir, perDir: Int32, frame: Int32): (Cell, Bool) =
        let (row, flip) = rowOf(w#dirs, d);
        ({ dirs = Int32.max(1, String.length(w#dirs)), row = row, perDir = Int32.max(1, perDir), frame = Num.clampInt(0, perDir - 1, frame) }, flip)

    /// 帯 l の中の Cell の矩形（画素）。
    pub def sourceOf(l: Images.Loaded, c: Cell): Rect2.Rect2 =
        let cellW = l#width / (c#dirs * c#perDir);
        { position = { x = Int32.toFloat64(cellW * (c#row * c#perDir + c#frame)), y = 0.0 },
          size = { x = Int32.toFloat64(cellW), y = Int32.toFloat64(l#height) } }

    /// 歩きの帯 l の 1 コマの横幅（m）。
    pub def walkWidthOf(l: Images.Loaded, dirs: String): Float64 =
        Int32.toFloat64(l#width / (Int32.max(1, String.length(dirs)) * walkFrames())) / Images.texelsPerMeter()

    /// 歩いた時間 clock のコマ（frameSec 秒ごとに替える）。
    pub def walkFrameAt(clock: Float64, frameSec: Float64): Int32 =
        Int32.modulo(Float64.floor(clock / Float64.max(0.01, frameSec)) |> Float64.tryToInt32 |> Option.getWithDefault(0), walkFrames())

    /// i 番目の人の、時刻 t の待機モーションのコマ（frameSec 秒ごとに替え、1 人ごとに phaseSec ずらす）。
    pub def idleFrameAt(t: Float64, i: Int32, frameSec: Float64, phaseSec: Float64): Int32 =
        let k = Float64.floor((t + Int32.toFloat64(i) * phaseSec) / Float64.max(0.01, frameSec)) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        Int32.modulo(k, idleFrames())
}
