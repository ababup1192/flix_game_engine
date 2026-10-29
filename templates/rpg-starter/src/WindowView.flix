// WindowView — FC の王道 RPG のウィンドウ（墨の地・白い縁・丸い角）と、ウィンドウの中の文字・カーソル ▶・続き ▼。
// ウィンドウは 8px の升目に乗せる（角と辺の部品が 8×8 なので、升目の外の大きさは作れない）。
mod WindowView {
    use fge::{FontAtlas, Rect2, Render, RawDraw, TextDraw, Vec2}
    use Sheet.SheetId

    /// ウィンドウと文字を描くのに要る物: 描く元・字のアトラス・時刻（点滅と揺れのコマを選ぶ）。
    pub type alias Env = { res = Res.Res, font = FontAtlas, t = Float64 }

    /// 升目 1 つの大きさ（px）。
    pub def cell(): Float64 = 8.0

    /// 字の大きさ。PixelMplus10 の設計の大きさそのもの（他の大きさにすると点が割れてにじむ）。
    def fontSize(): Float64 = 10.0

    /// ウィンドウの中の 1 行の高さ。
    def lineHeight(): Float64 = 14.0

    /// ウィンドウの縁から 1 行目の字の左上までの間（左・上）。左はカーソル ▶ の 1 升ぶんを含む。
    pub def padLeft(): Float64 = 16.0
    def padTop(): Float64 = 9.0

    // ウィンドウの中の重なり順（場面の絵より手前に置く物の、ウィンドウの中での順）。
    def zFrame(): Int32 = 0
    def zText(): Int32 = 1
    def zCursor(): Int32 = 2

    /// 升目で書いたウィンドウの場所（col・row が左上・cols × rows が大きさ）を px の矩形へ。
    pub def grid(cells: { col = Int32, row = Int32, cols = Int32, rows = Int32 }): Rect2.Rect2 =
        let c = cell();
        { position = { x = Int32.toFloat64(cells#col) * c, y = Int32.toFloat64(cells#row) * c },
          size = { x = Int32.toFloat64(cells#cols) * c, y = Int32.toFloat64(cells#rows) * c } }

    def uiPart(sprite: String, frame: String): Sheet.Part =
        Sheet.part(SheetId.Ui, sprite, frame, "ink", { x = cell(), y = cell() })

    /// ウィンドウの枠と墨の地。中は墨の板 1 枚（升目ごとに部品を並べない）。
    pub def frame(env: Env, rect: Rect2.Rect2, z: Int32): List[Render.PlacedItem] =
        let c = cell();
        let cols = Float64.round(rect#size#x / c) |> Float64.tryToInt32 |> Option.getWithDefault(2);
        let rows = Float64.round(rect#size#y / c) |> Float64.tryToInt32 |> Option.getWithDefault(2);
        let at = (col, row) -> ({ x = rect#position#x + Int32.toFloat64(col) * c,
                                  y = rect#position#y + Int32.toFloat64(row) * c }: Vec2.Vec2);
        let edgeName = (col, row) -> {
            let h = if (col == 0) "l" else if (col == cols - 1) "r" else "";
            let v = if (row == 0) "t" else if (row == rows - 1) "b" else "";
            v + h
        };
        let edges = List.range(0, rows) |> List.flatMap(row ->
            List.range(0, cols)
                |> List.filter(col -> row == 0 or row == rows - 1 or col == 0 or col == cols - 1)
                |> List.flatMap(col ->
                    Sheet.draw(env#res#sheets, env#res#palette, env#t,
                               { part = uiPart("window", edgeName(col, row)), at = at(col, row), z = z + zFrame() })));
        let inner = RawDraw.box({ x = rect#size#x - 2.0 * c, y = rect#size#y - 2.0 * c },
                                Palette.resolve(env#res#palette, "ink"), z + zFrame());
        Render.at(at(1, 1), inner) :: edges

    /// 白い字 1 行（左上 at）。
    pub def label(env: Env, text: String, at: Vec2.Vec2, z: Int32): Render.PlacedItem =
        labelIn(env, "fc30", text, at, z)

    /// 色を選んだ字 1 行（使えない項目の灰・数字の強調）。
    pub def labelIn(env: Env, colorKey: String, text: String, at: Vec2.Vec2, z: Int32): Render.PlacedItem =
        Render.at(at, Render.textTinted(text, env#font, fontSize(), Palette.resolve(env#res#palette, colorKey), z + zText()))

    /// ウィンドウの中の i 行目の字の左上（ウィンドウの左上からの位置）。
    pub def lineAt(rect: Rect2.Rect2, i: Int32): Vec2.Vec2 =
        { x = rect#position#x + padLeft(), y = rect#position#y + padTop() + Int32.toFloat64(i) * lineHeight() }

    /// ウィンドウの中に行を上から並べる。
    def lines(env: Env, rect: Rect2.Rect2, texts: List[String], z: Int32): List[Render.PlacedItem] =
        texts |> List.zipWithIndex |> List.map(entry -> {
            let (i, text) = entry;
            label(env, text, lineAt(rect, i), z)
        })

    /// 選んでいる行の ▶（字の左の 1 升に置く）。点滅は時刻 t のコマで決まる。
    pub def cursor(env: Env, textAt: Vec2.Vec2, z: Int32): List[Render.PlacedItem] =
        let at = { x = textAt#x - 10.0, y = textAt#y + 2.0 };
        Sheet.draw(env#res#sheets, env#res#palette, env#t,
                   { part = Sheet.cycling(SheetId.Ui, "cursor", 2.0, "fc30", { x = 8.0, y = 8.0 }),
                     at = at, z = z + zCursor() })

    /// 止まった ▶（下の段のウィンドウを開いている間、上の段のウィンドウで選んだ行に残す印。点滅させない）。
    pub def cursorStill(env: Env, textAt: Vec2.Vec2, z: Int32): List[Render.PlacedItem] =
        let at = { x = textAt#x - 10.0, y = textAt#y + 2.0 };
        Sheet.draw(env#res#sheets, env#res#palette, env#t,
                   { part = Sheet.part(SheetId.Ui, "cursor", "blink_0", "fc30", { x = 8.0, y = 8.0 }),
                     at = at, z = z + zCursor() })

    /// 文の続きがある時の ▼（ウィンドウの下の縁の真ん中）。
    def more(env: Env, rect: Rect2.Rect2, z: Int32): List[Render.PlacedItem] =
        let at = { x = rect#position#x + rect#size#x / 2.0 - 4.0, y = rect#position#y + rect#size#y - 12.0 };
        Sheet.draw(env#res#sheets, env#res#palette, env#t,
                   { part = Sheet.cycling(SheetId.Ui, "more", 2.0, "fc30", { x = 8.0, y = 8.0 }),
                     at = at, z = z + zCursor() })

    /// ウィンドウの上の縁に載せる名前（呪文を唱える人・持ち主）。縁の白線を墨で切り、字の後ろに墨の札を敷いて置く。
    /// WhyNot: 札を縁の帯の中だけにしない — 字の上半分が縁より上の地面に白く浮き、切れた字に見える。
    /// 字を縁の中へ下げない — 1 行目の字とぶつかる（どのウィンドウも 1 行目の場所は名前の有無で変えない）。
    pub def title(env: Env, rect: Rect2.Rect2, text: String, z: Int32): List[Render.PlacedItem] =
        let width = Float64.ceil(TextDraw.width(text, env#font, fontSize())) + 4.0;
        let x = rect#position#x + 12.0;
        let top = rect#position#y - titleRise();
        let plate = RawDraw.box({ x = width, y = titleRise() + 6.0 }, Palette.resolve(env#res#palette, "ink"), z + zText());
        Render.at({ x = x, y = top }, plate)
            :: label(env, text, { x = x + 2.0, y = top }, z) :: Nil

    /// 名前の字の頭が、ウィンドウの上の縁から上へ出る高さ（px）。
    def titleRise(): Float64 = 5.0

    /// 会話のウィンドウ: 枠・行・（続きがあれば）▼。
    pub def message(env: Env, rect: Rect2.Rect2, texts: List[String], hasMore: Bool, z: Int32): List[Render.PlacedItem] =
        List.flatten(frame(env, rect, z) :: lines(env, rect, texts, z) :: (if (hasMore) more(env, rect, z) else Nil) :: Nil)

    /// 選ぶウィンドウ（1 列）。open が偽の項目は灰色の字（選べない）。
    pub def choices(env: Env, spec: { rect = Rect2.Rect2, entries = List[(String, Bool)], selected = Int32 }, z: Int32): List[Render.PlacedItem] =
        let texts = spec#entries |> List.zipWithIndex |> List.map(entry -> {
            let (i, (text, open)) = entry;
            labelIn(env, if (open) "fc30" else "fc00", text, lineAt(spec#rect, i), z)
        });
        List.flatten(frame(env, spec#rect, z) :: texts :: cursor(env, lineAt(spec#rect, spec#selected), z) :: Nil)

    // ── 一覧のウィンドウ（メニュー・店） ──

    /// 一覧の 1 行: 左の字・右に寄せる字（個数・値段・付けている物。空なら出さない）・選べるか（偽は灰色）。
    pub type alias Row = { text = String, right = String, open = Bool }

    /// 一覧のウィンドウ: 上の縁の名前（空なら出さない）・行・カーソルの行・カーソルが動く所か（偽なら止まった ▶）。
    pub type alias ListBox = { title = String, rows = List[Row], cursor = Int32, active = Bool }

    /// n 行を並べるウィンドウの高さ（升目の数。1 行より少なくしない）。
    pub def rowsFor(n: Int32): Int32 = (Float64.ceil((2.0 * padTop() + lineHeight() * Int32.toFloat64(Int32.max(1, n))) / cell())
        |> Float64.tryToInt32 |> Option.getWithDefault(3))

    /// 右の端 right（px）に字の右端を合わせた 1 行（数字・値段の右寄せ）。
    pub def labelRight(env: Env, colorKey: String, text: String, right: Float64, y: Float64, z: Int32): Render.PlacedItem =
        labelIn(env, colorKey, text, { x = right - Float64.ceil(textWidth(env, text)), y = y }, z)

    /// 一覧のウィンドウ: 枠・名前・行（右の字は右寄せ）・▶。行が無ければ ▶ を出さない。
    pub def listWindow(env: Env, rect: Rect2.Rect2, box: ListBox, z: Int32): List[Render.PlacedItem] =
        let right = rect#position#x + rect#size#x - cell() - 2.0;
        let rows = box#rows |> List.zipWithIndex |> List.flatMap(match (i, row) -> {
            let at = lineAt(rect, i);
            let color = if (row#open) "fc30" else "fc00";
            labelIn(env, color, row#text, at, z) ::
            (if (String.isEmpty(row#right)) Nil else labelRight(env, color, row#right, right, at#y, z) :: Nil)
        });
        let title = if (String.isEmpty(box#title)) Nil else title(env, rect, box#title, z);
        let pointer = if (List.isEmpty(box#rows)) Nil
                      else if (box#active) cursor(env, lineAt(rect, box#cursor), z)
                      else cursorStill(env, lineAt(rect, box#cursor), z);
        List.flatten(frame(env, rect, z) :: title :: rows :: pointer :: Nil)

    // ── 会話のウィンドウの字 ──

    /// 会話のウィンドウに出す行。speaker が空でなければ 1 行目の頭に「呼び名「」、2 行目からは全角の空白で字下げし、
    /// 出し切ったら最後に「」」を付ける。text の \n で行を替え、width（px）を超える行は折る。
    /// shown = 文字送りで見えている字数（text の字数で数える。\n も 1 字）。まだ 1 字も見えていない行は出さない。
    pub def talkLines(env: Env, speaker: String, text: String, shown: Int32, width: Float64): List[String] =
        let (head, indent) = if (String.isEmpty(speaker)) ("", "") else ("${speaker}「", "　");
        let closing = if (String.isEmpty(speaker) or shown < String.length(text)) "" else "」";
        bodiesOf(text) |> List.flatMap(match (i, at, body) -> {
            let lead = if (i == 0) head else indent;
            wrapped(env, width - textWidth(env, lead), body) |> startsFrom(at) |> List.zipWithIndex
                |> List.map(match (j, (start, part)) -> (if (j == 0) lead else indent, start, part))
        })
            |> List.filterMap(match (lead, start, part) ->
                if (start > 0 and start >= shown) None else Some(lead + String.takeLeft(shown - start, part)))
            |> withLastSuffix(closing)

    def textWidth(env: Env, text: String): Float64 = TextDraw.width(text, env#font, fontSize())

    /// \n で分けた行と、その行の頭の字の位置（\n も 1 字に数える）。
    def bodiesOf(text: String): List[(Int32, Int32, String)] =
        let (_, _, out) = String.splitOn(substr = "\n", text) |> List.foldLeft((acc, body) -> {
            let (i, at, rows) = acc;
            (i + 1, at + String.length(body) + 1, (i, at, body) :: rows)
        }, (0, 0, Nil));
        List.reverse(out)

    /// 切れの列に、at から数えた頭の字の位置を付ける。
    def startsFrom(at: Int32, parts: List[String]): List[(Int32, String)] =
        let (_, out) = parts |> List.foldLeft((acc, part) -> {
            let (start, rows) = acc;
            (start + String.length(part), (start, part) :: rows)
        }, (at, Nil));
        List.reverse(out)

    /// body を width に収まる切れに折る（字の幅を 1 字ずつ足し、超える手前で切る）。空の body は空の 1 切れ。
    def wrapped(env: Env, width: Float64, body: String): List[String] =
        let (done, current, _) = String.toList(body) |> List.foldLeft((acc, ch) -> {
            let (segs, cur, used) = acc;
            let w = textWidth(env, Char.toString(ch));
            if (used + w > width and not List.isEmpty(cur)) (cur :: segs, ch :: Nil, w)
            else (segs, ch :: cur, used + w)
        }, (Nil, Nil, 0.0));
        (current :: done) |> List.reverse |> List.map(rev -> List.join("", List.reverse(rev)))

    def withLastSuffix(suffix: String, lines: List[String]): List[String] =
        if (String.isEmpty(suffix)) lines
        else lastWith(suffix, List.reverse(lines))

    def lastWith(suffix: String, reversed: List[String]): List[String] = match reversed {
        case last :: rest => List.reverse((last + suffix) :: rest)
        case Nil          => Nil
    }

    /// 画面の大きさ（project.json の designWidth / designHeight）。
    pub def design(): Vec2.Vec2 = { x = 256.0, y = 240.0 }
}
