// TitleView — 題名の画面と、全面クリアの終わりの画面の文字（盤の絵を背景に敷いた上に置く）。
// 字の後ろだけを影の色の帯で沈め、字は紙の色で抜く（字そのものを光らせない — 白飛びさせない画風のため）。
mod TitleView {

    use fge::{Color, DrawCmd, FontAtlas, Render, Sway, TextDraw, Vec2}

    /// level は選んでいる面、canSelect は ←→ の先に開いた面があるか、best はクリアした面の貝殻の数。
    pub type alias In = {
        t = Float64,
        level = Int32,
        name = String,
        canSelect = (Bool, Bool),
        best = Map[Int32, Int32],
        stageCount = Int32,
        theme = ThemeDoc.Doc
    }

    def paper(w: In): Color = Color.mix(ThemeDoc.rec(w#theme)#panel, ThemeDoc.rec(w#theme)#light, 0.3)

    def lineAt(atlas: FontAtlas, s: String, size: Float64, center: Vec2.Vec2, color: Color, alpha: Float64): Render.PlacedItem =
        { at = { x = TextDraw.centerLeft(s, atlas, size, center#x), y = center#y },
          item = Render.textTinted(s, atlas, size, color, 0) |> Render.fade(alpha) }

    /// 字の後ろに敷く影の色の帯。上下の端で濃さ 0 に溶け、間（middle）は一様に濃い（丸い翳りだと砂の上で濁って見えた）。
    def hush(w: In, top: Float64, middle: (Float64, Float64), bottom: Float64, alpha: Float64): List[Render.PlacedItem] =
        let shadow = ThemeDoc.rec(w#theme)#shadow;
        let band = (y0: Float64, y1: Float64, a0: Float64, a1: Float64) ->
            { at = Vec2.zero(), item = Render.gradPolygon(
                { pos = { x = 0.0, y = y0 }, color = shadow, alpha = a0 } :: { pos = { x = 640.0, y = y0 }, color = shadow, alpha = a0 }
                    :: { pos = { x = 640.0, y = y1 }, color = shadow, alpha = a1 } :: { pos = { x = 0.0, y = y1 }, color = shadow, alpha = a1 } :: Nil, 0) };
        band(top, fst(middle), 0.0, alpha) :: band(fst(middle), snd(middle), alpha, alpha) :: band(snd(middle), bottom, alpha, 0.0) :: Nil

    /// 大きな題字（影の色の落ち影つき）。
    def logo(atlas: FontAtlas, w: In, s: String, size: Float64, y: Float64): List[Render.PlacedItem] =
        (lineAt(atlas, s, size, { x = 323.0, y = y + 4.0 }, ThemeDoc.rec(w#theme)#shadow, 0.55)
            |> Render.overItem(item -> item |> Render.blended(DrawCmd.BlendMode.Multiply)))
            :: lineAt(atlas, s, size, { x = 320.0, y = y }, paper(w), 1.0) :: Nil

    def breathe(w: In): Float64 = 0.55 + 0.45 * Float64.abs(Sway.wave(w#t, 0.0, 0.8))

    /// 題名: 題字・一言・面選び（←→ は選べる向きだけ濃い）・選んだ面の貝殻・はじめ方。
    pub def title(atlas: FontAtlas, w: In): List[List[Render.PlacedItem]] =
        let (canLeft, canRight) = w#canSelect;
        let dim = on -> if (on) 0.95 else 0.25;
        let shells = Map.get(w#level, w#best) |> Option.map(n -> "貝殻 ${n} / 3") |> Option.getWithDefault("まだ解いていない面");
        hush(w, 60.0, (150.0, 296.0), 336.0, 0.58)
            :: (logo(atlas, w, "潮だまり", 72.0, 78.0)
            ::: lineAt(atlas, "T I D E P O O L", 13.0, { x = 320.0, y = 164.0 }, paper(w), 0.75)
            :: lineAt(atlas, "ひと手ごとに満ちて引く磯で、ヤドカリのお引っ越し", 13.0, { x = 320.0, y = 188.0 }, paper(w), 0.9)
            :: lineAt(atlas, "←", 18.0, { x = 168.0, y = 226.0 }, paper(w), dim(canLeft))
            :: lineAt(atlas, "面 ${w#level + 1} ・ ${w#name}", 17.0, { x = 320.0, y = 226.0 }, paper(w), 1.0)
            :: lineAt(atlas, "→", 18.0, { x = 472.0, y = 226.0 }, paper(w), dim(canRight))
            :: lineAt(atlas, shells, 11.0, { x = 320.0, y = 252.0 }, paper(w), 0.7)
            :: lineAt(atlas, "Enter ではじめる", 14.0, { x = 320.0, y = 280.0 }, paper(w), breathe(w))
            :: Nil) :: Nil

    /// 全面クリア: 題字・集めた貝殻の数・題名へ戻る案内。
    pub def ending(atlas: FontAtlas, w: In): List[List[Render.PlacedItem]] =
        let total = Map.foldLeft((acc, n) -> acc + n, 0, w#best);
        hush(w, 70.0, (140.0, 262.0), 320.0, 0.6)
            :: (logo(atlas, w, "全面クリア", 56.0, 96.0)
            ::: lineAt(atlas, "ヤドカリは新しい巻き貝で、潮だまりに落ち着いた", 13.0, { x = 320.0, y = 178.0 }, paper(w), 0.9)
            :: lineAt(atlas, "集めた貝殻 ${total} / ${w#stageCount * 3}", 17.0, { x = 320.0, y = 210.0 }, paper(w), 1.0)
            :: lineAt(atlas, "Enter で題名へ", 14.0, { x = 320.0, y = 256.0 }, paper(w), breathe(w))
            :: Nil) :: Nil
}
