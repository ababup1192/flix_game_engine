// RichText — 一部だけ色や太さの違う文章を「スパンの列」として持ち、描画アイテムへ組む。
// 会話文の中で名前だけ色を変える・強調語だけ太くする、が UI の種類を問わずできる。
// 利用例: spans を組み、place に左上位置と最大幅を渡すと折返し済みの PlacedItem 列が返る。
// 文字送り（タイプライター）とは take で繋がる: 先頭 n 文字だけ残して place に渡す。
pub mod RichText {

    /// 1 スパン。tint = None は呼び側の基本色で描く。bold は同じ字を半ピクセルずらして
    /// 二度描く疑似太字（フォント 1 本で済む）。
    pub type alias Span = { text = String, tint = Option[Color], bold = Bool }

    pub def plain(text: String): Span = { text = text, tint = None, bold = false }

    pub def colored(text: String, tint: Color): Span = { text = text, tint = Some(tint), bold = false }

    pub def strong(text: String): Span = { text = text, tint = None, bold = true }

    /// 見た目を除いた素の文章（文字送りの長さ勘定・テストの pin に使う）。
    pub def plainText(spans: List[Span]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(span -> StringBuilder.append(span#text, sb), spans);
            StringBuilder.toString(sb)
        }

    /// 字の列を 1 本の String へ組む。
    def charsToString(chars: List[Char]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(ch -> StringBuilder.append(ch, sb), chars);
            StringBuilder.toString(sb)
        }

    /// 全スパンの合計文字数。
    pub def length(spans: List[Span]): Int32 =
        spans |> List.foldLeft((acc, span) -> acc + String.length(span#text), 0)

    /// 先頭 n 文字ぶんだけ残す（タイプライター表示用）。スパンの途中でも切れる。
    pub def take(n: Int32, spans: List[Span]): List[Span] =
        match spans {
            case Nil => Nil
            case span :: rest => {
                let len = String.length(span#text);
                if (n <= 0)
                    Nil
                else if (n >= len)
                    span :: take(n - len, rest)
                else {
                    let cut = String.toList(span#text) |> List.take(n) |> charsToString;
                    { text = cut | span } :: Nil
                }
            }
        }

    /// place の引数一式。pos = 左上、maxWidth = 折返し幅（pos#x からの幅）、
    /// baseTint = tint 無指定スパンの色、lineGap = 行間（px）。
    pub type alias Placement = {
        atlas = FontAtlas,
        size = Float64,
        baseTint = Color,
        z = Int32,
        pos = Vec2.Vec2,
        maxWidth = Float64,
        lineGap = Float64
    }

    /// スパン列を最大幅で行の列へ折る。折る規則は描画(place)と同一 — 字単位で、収まらない
    /// 字は次の行へ、'\n' でも改行。スパンの属性(tint / bold)は行をまたいでも保たれる。
    /// 字幅は charWidth で外から与える: place は atlas の実測を渡すが、描画の前に行数だけ
    /// 知りたい呼び側(スクロールの勘定・ページ割りなど)は「全角 2・半角 1」のような純粋な
    /// 近似を渡してよい。同じ charWidth を通す限り、勘定と描画の行割りはずれない。
    /// 行数の規約: 空の入力も「空行 1 つ」(結果が Nil になることはない)、末尾の '\n' は
    /// 末尾に空行を残す — 行数を高さの予約に使う呼び側が空文字で 0 行にならないため。
    pub def wrapLinesBy(charWidth: Char -> Float64, maxWidth: Float64, spans: List[Span]): List[List[Span]] =
        // 行の組み立て中は lines(確定行・逆順)/ line(組み立て中の行のスパン・逆順)/
        // chunk(いま処理中のスパンから今の行に積んだ文字・逆順)/ x(行の使用幅)を持ち回る。
        let final = spans |> List.foldLeft((acc, span) -> {
            let s = String.toList(span#text) |> List.foldLeft((st, ch) -> {
                if (ch == '\n')
                    { lines = closeLine(st#chunk, span, st#line) :: st#lines, line = Nil,
                      chunk = (Nil: List[Char]), x = 0.0 }
                else {
                    let w = charWidth(ch);
                    // 行頭(x = 0)では折らない — maxWidth より広い字でも 1 字は必ず置く(無限ループを作らない)。
                    let st1 = if (st#x + w > maxWidth and st#x > 0.0)
                        { lines = closeLine(st#chunk, span, st#line) :: st#lines, line = Nil,
                          chunk = (Nil: List[Char]), x = 0.0 }
                        else st;
                    { chunk = ch :: st1#chunk, x = st1#x + w | st1 }
                }
            }, { lines = acc#lines, line = acc#line, chunk = (Nil: List[Char]), x = acc#x });
            { lines = s#lines, line = pushChunk(s#chunk, span, s#line), x = s#x }
        }, { lines = (Nil: List[List[Span]]), line = (Nil: List[Span]), x = 0.0 });
        List.reverse(List.reverse(final#line) :: final#lines)

    /// 組み立て中のスパン片(逆順の字)を行へ積む(空なら何も足さない)。属性は元スパンから引き継ぐ。
    def pushChunk(chunk: List[Char], span: Span, line: List[Span]): List[Span] =
        if (List.isEmpty(chunk)) line
        else ({ text = charsToString(List.reverse(chunk)) | span }) :: line

    /// 組み立て中の行を確定する(逆順を戻す)。
    def closeLine(chunk: List[Char], span: Span, line: List[Span]): List[Span] =
        List.reverse(pushChunk(chunk, span, line))

    /// スパン列を左上 pos から 1 文字ずつ置いていく。行割りは wrapLinesBy(atlas の実測幅)で、
    /// 太字スパンは半ピクセル右にずらしてもう一度描くことで線を太らせる。
    /// 最小の呼び出し例:
    ///   RichText.place({ atlas = atlas, size = 10.0, baseTint = ink, z = 40,
    ///                    pos = { x = 16.0, y = 180.0 }, maxWidth = 288.0, lineGap = 3.0 },
    ///                  RichText.plain("こんにちは") :: Nil)
    pub def place(p: Placement, spans: List[Span]): List[Render.PlacedItem] =
        wrapLinesBy(ch -> TextDraw.width(Char.toString(ch), p#atlas, p#size), p#maxWidth, spans)
            |> List.zipWithIndex
            |> List.flatMap(pair -> {
                let (i, line) = pair;
                placeLine(p, Int32.toFloat64(i) * (p#size + p#lineGap), line)
            })

    /// 折返し済みの 1 行を y の高さに置く。
    def placeLine(p: Placement, y: Float64, line: List[Span]): List[Render.PlacedItem] =
        // 蓄積は逆順で持つ。reverse を掛けるのはスパンと字の 2 重 fold を抜けた最後の 1 回だけで、
        // 内側の fold ごとに戻すとスパン単位で順序が壊れる。太字の 2 枚目も逆順のまま積むので、
        // 素の字を先に積んでからずらした複製を積む。
        let (rev, _) = line |> List.foldLeft((acc, span) -> {
            let tint = Option.getWithDefault(p#baseTint, span#tint);
            String.toList(span#text) |> List.foldLeft((acc2, ch) -> {
                let (done, x) = acc2;
                let text = Char.toString(ch);
                let at = { x = p#pos#x + x, y = p#pos#y + y };
                let withGlyph = { at = at, item = Render.textTinted(text, p#atlas, p#size, tint, p#z) } :: done;
                let withBold = if (span#bold)
                    { at = { x = at#x + 0.5, y = at#y },
                      item = Render.textTinted(text, p#atlas, p#size, tint, p#z) } :: withGlyph
                else
                    withGlyph;
                (withBold, x + TextDraw.width(text, p#atlas, p#size))
            }, acc)
        }, (Nil, 0.0));
        List.reverse(rev)
}
