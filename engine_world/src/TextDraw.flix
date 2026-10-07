// TextDraw — 文字列を、左端ではなく「中心をここに置きたい」で配置する。
// 幅を測って半分だけ左へずらす手間を一度だけ名付けるので、文字を中央に揃えるたびに
// 同じ計算を書かずに済む。
// 利用例: 盤の上のタイトル / アイコンの下のラベル / 画面中央の見出し。

pub mod TextDraw {

    /// `centered` の引数一式。並べると順序を誤りやすい値を名前で束ねるための入れ物
    /// （centerX に中心を合わせ、y を一行の上端にする）。
    pub type alias Centered = { text = String, atlas = FontAtlas, size = Float64,
                                color = Color, z = Int32, centerX = Float64, y = Float64 }

    /// 与えた atlas 上で `text` を `size` で描いたときの横幅（ピクセル）。プロポーショナル
    /// フォントも字ごとの送り幅で正しく測る。描画までは要らず幅だけ欲しい配置計算に使う。
    pub def width(text: String, atlas: FontAtlas, size: Float64): Float64 =
        Text.measure(Text.make(text, atlas, size))#x

    /// 与えた atlas 上で `text` を `size` で描いたときの幅と高さ（ピクセル、Vec2）。
    /// `width` が横だけ返すのに対し、縦の位置合わせ（中央そろえ・下端そろえ）に要る高さも
    /// まとめて返す。描画までは要らず寸法だけ欲しい配置計算に使う。
    pub def size(text: String, atlas: FontAtlas, size: Float64): Vec2.Vec2 =
        Text.measure(Text.make(text, atlas, size))

    /// `text` を `centerX` に水平中央で揃えたときの左端 x。中央寄せは「幅の半分だけ左へ
    /// ずらす」だけなので、それを名付けて返す。描画アイテムを作らず座標だけ欲しい宣言 UI
    /// （setAbs 系で位置を渡す）から呼べる。
    pub def centerLeft(text: String, atlas: FontAtlas, size: Float64, centerX: Float64): Float64 =
        centerX - width(text, atlas, size) / 2.0

    /// 一行が `centerX` に水平中央で揃い、上端が `y` になるよう配置したテキスト描画
    /// アイテム。左上の描画位置と tint 済みテキストアイテムの組を返し、そのまま描画
    /// リストへ追加できる。左端 x は `centerLeft`、幅は `width` に一致する。
    pub def centered(a: Centered): Render.PlacedItem =
        { at = { x = centerLeft(a#text, a#atlas, a#size, a#centerX), y = a#y },
          item = Render.textTinted(a#text, a#atlas, a#size, a#color, a#z) }

    /// `centeredAt` の引数一式。`Centered` の centerX/y の代わりに、縦横とも
    /// 中央に置きたい 1 点 `center` を渡す。
    pub type alias CenteredAt = { text = String, atlas = FontAtlas, size = Float64,
                                  color = Color, z = Int32, center = Vec2.Vec2 }

    /// 一行を点 `center` のまわりのど真ん中に置いたテキスト描画アイテム。画面中央の
    /// 見出しやアイコン上のラベルが1呼びで済む。寸法を測って center から半分ずらすだけ。
    pub def centeredAt(a: CenteredAt): Render.PlacedItem =
        let s = size(a#text, a#atlas, a#size);
        { at = { x = a#center#x - s#x / 2.0, y = a#center#y - s#y / 2.0 },
          item = Render.textTinted(a#text, a#atlas, a#size, a#color, a#z) }

    /// リロード失敗などのエラー文を画面左上に赤字で出す（None なら何も出さない）。
    /// 長文は 64 字で折り返し、4 行を超えた分は末尾を "..." に丸める。
    pub def errorBanner(atlas: FontAtlas, error: Option[String]): List[Render.PlacedItem] =
        match error {
            case None      => Nil
            case Some(msg) =>
                wrapChunks(msg, 64, 4) |> List.zipWithIndex |> List.map(pair -> {
                    let (i, line) = pair;
                    { at = { x = 8.0, y = 8.0 + Int32.toFloat64(i) * 11.0 },
                      item = Render.textTinted(line, atlas, 8.0,
                                               { r = 1.0, g = 0.4, b = 0.4 }, 200) }
                })
        }

    /// 文字数 width ごとに切り、maxLines 行に収まらない分は末尾を "..." に丸める。
    def wrapChunks(s: String, width: Int32, maxLines: Int32): List[String] =
        if (maxLines <= 0 or s == "") Nil
        else if (String.length(s) <= width) s :: Nil
        else if (maxLines == 1) "${String.take(Int32.max(1, width - 3), s)}..." :: Nil
        else String.take(width, s) :: wrapChunks(String.drop(width, s), width, maxLines - 1)
}
