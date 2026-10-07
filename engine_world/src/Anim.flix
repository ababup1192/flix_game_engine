// Anim — スプライトシートのコマ送りを「時刻の純関数」で導く。
// 再生ヘッドの状態を持たない: ループは通し時刻から、単発は開始からの経過秒から、
// いま何コマ目かを式で求めるだけ。だから巻き戻し・リプレイ・テストがそのまま効く。
// 利用例: Render.sprite の regionRect に regionAt(...) を渡す。

pub mod Anim {

    /// クリップ: シート上の 1 行ぶんの連続コマと再生のしかた（純データ）。
    pub type alias Clip = {
        row = Int32,        // シート上の行（0 始まり・上から）
        frames = Int32,     // コマ数
        fps = Float64,      // 再生速度（コマ/秒）
        looping = Bool      // true = 循環 / false = 最終コマで止まる（単発ポーズ）
    }

    /// 時刻 t（ループは通し秒・単発は開始からの経過秒）でのコマ番号。
    /// 負の t とコマ数 0 は 0 にする（安全側）。
    pub def frameAt(clip: Clip, t: Float64): Int32 =
        if (clip#frames <= 0) 0
        else if (t < 0.0) 0
        else {
            let raw = Num.floorInt(t * clip#fps);
            if (clip#looping) Int32.modulo(raw, clip#frames)
            else Int32.min(raw, clip#frames - 1)
        }

    /// コマ番号からシート上の矩形を導く（コマ寸法は呼び手が渡す）。Render.sprite の regionRect 用。
    pub def regionOf(frameW: Float64, frameH: Float64, clip: Clip, frame: Int32): Rect2.Rect2 =
        {position = {x = Int32.toFloat64(frame) * frameW, y = Int32.toFloat64(clip#row) * frameH},
         size     = {x = frameW, y = frameH}}

    /// frameAt と regionOf をまとめた近道。
    pub def regionAt(frameW: Float64, frameH: Float64, clip: Clip, t: Float64): Rect2.Rect2 =
        regionOf(frameW, frameH, clip, frameAt(clip, t))
}
