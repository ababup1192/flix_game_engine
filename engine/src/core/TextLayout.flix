// TextLayout — 文字列の一文字ずつを、どこに置くか（改行・折り返し・中央寄せ）を計算する。
// 文字の送り幅から各文字のペン位置を出す計算を一箇所にまとめるので、描画側は座標を気にせず置くだけでよい。
// 利用例: ラベルを中央に揃える / 決まった幅で自動改行する / 何行になるか見積もる。
// 注意: 位置の計算だけで、実際の描画やフォントの読み込みは扱わない純粋な計算。

pub mod TextLayout {

    /// 文字を 0 以上の Unicode 番号に直す。
    /// 標準の変換は U+8000 以上で負値になるため、16bit の符号なしに丸める。
    pub def charToCodePoint(ch: Char): Int32 =
        Int32.bitwiseAnd(Char.toBmpCodePoint(ch), 0xFFFF)

    /// 行の高さ（文字サイズの 1.2 倍。詰め気味の標準的な行間）。
    pub def lineHeightMultiplier(): Float64 = 1.2

    /// 1 行のテキストを中央に置くための、横方向のずらし量。
    pub def centerOffset(totalAdvance: Float64, scale: Float64): Float64 =
        -1.0 * totalAdvance * scale / 2.0

    /// 各文字の送り幅の合計（＝テキスト全体の幅。ベイク基準の単位）。
    pub def totalAdvance(advances: List[Float64]): Float64 =
        List.foldLeft((acc, a) -> acc + a, 0.0, advances)

    /// 改行文字でテキストを行に分ける。
    /// 蓄積はタプルで持つ（レコードは 1 フィールド 1 オブジェクトで、文字ごとに作り直す
    /// 蓄積では確保が文字数ぶん積み上がる — layoutPositions も同じ）。
    pub def splitLines(text: String): List[List[Char]] =
        let chars = String.toList(text);
        let result = List.foldLeft((acc, ch) -> {
            let (lines, current) = acc;
            if (Char.toBmpCodePoint(ch) == 10)
                (List.reverse(current) :: lines, (Nil: List[Char]))
            else
                (lines, ch :: current)
        }, ((Nil: List[List[Char]]), (Nil: List[Char])), chars);
        let (lines, current) = result;
        List.reverse(List.reverse(current) :: lines)

    /// 各文字を置くペン位置。折り返し幅を超えたら次の行へ送る。
    pub def layoutPositions(advances: List[Float64], wrapWidth: Float64,
                            scale: Float64, lineHeight: Float64): List[(Float64, Float64)] =
        if (wrapWidth <= 0.0) {
            let result = List.foldLeft((acc, adv) -> {
                let (positions, penX) = acc;
                ((penX, 0.0) :: positions, penX + adv)
            }, ((Nil: List[(Float64, Float64)]), 0.0), advances);
            List.reverse(fst(result))
        } else {
            let result = List.foldLeft((acc, adv) -> {
                let (positions, penX, penY) = acc;
                let nextX = penX + adv;
                let px = if (penX > 0.0 and nextX * scale > wrapWidth) 0.0 else penX;
                let py = if (penX > 0.0 and nextX * scale > wrapWidth) penY + lineHeight else penY;
                ((px, py) :: positions, px + adv, py)
            }, ((Nil: List[(Float64, Float64)]), 0.0, 0.0), advances);
            let (positions, _, _) = result;
            List.reverse(positions)
        }

    /// 1 文字ぶんの寸法と、アトラス上の切り出し位置。
    pub type alias GlyphMetrics = {
        xOff = Float64, yOff = Float64,
        glyphW = Float64, glyphH = Float64,
        advance = Float64,
        s0 = Float64, t0 = Float64, s1 = Float64, t1 = Float64
    }

    /// 1 文字を画面上で囲む四角の範囲（左上と右下）。
    pub type alias QuadBounds = {
        x0 = Float64, y0 = Float64, x1 = Float64, y1 = Float64
    }

    /// ペン位置に置いた 1 文字が、画面上で占める四角の範囲を求める。
    /// penPos は layoutPositions が出したペン位置、basePos はラベルの画面位置、
    /// offsetX は中央寄せのずらし量（寄せないなら 0）。
    pub def glyphQuadBounds(penPos: (Float64, Float64), glyph: GlyphMetrics,
                            scale: Float64, basePos: Vec2.Vec2,
                            offsetX: Float64): QuadBounds =
        let (penX, penY) = penPos;
        let x0 = (penX + glyph#xOff) * scale + basePos#x + offsetX;
        let y0 = (penY + glyph#yOff) * scale + basePos#y;
        let x1 = x0 + glyph#glyphW * scale;
        let y1 = y0 + glyph#glyphH * scale;
        {x0 = x0, y0 = y0, x1 = x1, y1 = y1}

    /// 折り返した結果、何行になるかを数える。
    pub def lineCount(advances: List[Float64], wrapWidth: Float64,
                      scale: Float64, lineHeight: Float64): Int32 =
        let positions = layoutPositions(advances, wrapWidth, scale, lineHeight);
        match positions {
            case Nil => 0
            case _ =>
                let ys = List.map(p -> snd(p), positions);
                let result = List.foldLeft((acc, y) -> {
                    let count = fst(acc);
                    let prevY = snd(acc);
                    if (Float64.abs(y - prevY) > 0.001) (count + 1, y) else (count, prevY)
                }, (1, 0.0), ys);
                fst(result)
        }
}
