/// Text — テキストを 1 文字ずつグリフに分けて描画する描画物。
/// 文字描画を一箇所にまとめるので、HUD やメニューのどこでも同じ字体で文字を出せる。
/// 利用例: スコア表示、セリフ、メニューの項目名。
/// 注意: アライメントの Fill は Left/Top と同じ扱い（両端揃えは未対応）。

/// 横方向アライメント
pub enum HorizontalAlignment with Eq, Order, ToString {
    case Left
    case Center
    case Right
    case Fill
}

/// 縦方向アライメント
pub enum VerticalAlignment with Eq, Order, ToString {
    case Top
    case Center
    case Bottom
    case Fill
}

pub enum Text {
    case Text({
        text = String,
        fontAtlas = FontAtlas,
        fontSize = Float64,
        horizontalAlignment = HorizontalAlignment,
        verticalAlignment = VerticalAlignment,
        wrapWidth = Option[Float64],
        transform = Transform,
        visual = Visual
    })
}

pub mod Text {
    /// テキストとフォントアトラスから Text を生成する。
    /// 既定は horizontalAlignment = Left, verticalAlignment = Top, 折り返しなし。
    pub def make(text: String, fontAtlas: FontAtlas, fontSize: Float64): Text =
        Text.Text({
            text = text,
            fontAtlas = fontAtlas,
            fontSize = fontSize,
            horizontalAlignment = HorizontalAlignment.Left,
            verticalAlignment = VerticalAlignment.Top,
            wrapWidth = None,
            transform = Transform.identity(),
            visual = Visual.default()
        })

    /// 折り返し幅（表示 px）を設定する。この幅を超える字は次の行へ送られる。
    /// None は折り返さない（既定）— measure・描画とも折り返し無しの従来どおりの結果になる。
    pub def setWrapWidth(wrapWidth: Option[Float64], label: Text): Text =
        let Text.Text(r) = label;
        Text.Text({ wrapWidth = wrapWidth | r })

    /// 埋め込んだ Transform 部品を取り出す
    pub def transform(label: Text): Transform =
        let Text.Text(r) = label;
        r#transform

    /// Transform 部品に関数を適用して差し替える
    pub def mapTransform(f: Transform -> Transform \ ef, label: Text): Text \ ef =
        let Text.Text(r) = label;
        Text.Text({transform = f(r#transform) | r})

    /// 埋め込んだ Visual 部品を取り出す
    pub def visual(label: Text): Visual =
        let Text.Text(r) = label;
        r#visual

    /// Visual 部品に関数を適用して差し替える
    pub def mapVisual(f: Visual -> Visual \ ef, label: Text): Text \ ef =
        let Text.Text(r) = label;
        Text.Text({visual = f(r#visual) | r})

    /// テキストを設定する
    pub def setText(text: String, label: Text): Text =
        let Text.Text(r) = label;
        Text.Text({ text = text | r })

    /// 横方向アライメントを設定する
    pub def setHorizontalAlignment(alignment: HorizontalAlignment, label: Text): Text =
        let Text.Text(r) = label;
        Text.Text({ horizontalAlignment = alignment | r })

    /// 縦方向アライメントを設定する
    pub def setVerticalAlignment(alignment: VerticalAlignment, label: Text): Text =
        let Text.Text(r) = label;
        Text.Text({ verticalAlignment = alignment | r })

    /// テキストを描画したときに占める表示サイズを返す。
    /// width  = 見た目の行の中で最も幅広い行の advance 合計 (× scale)
    /// height = 見た目の行数 × lineHeight (= (ascent + descent + lineGap) × scale)
    /// wrapWidth があれば折り返し後の行で数える（描画とぴったり同じ寸法になる）。
    /// Layout モジュールが描画物の自然サイズを問い合わせるために使う。
    pub def measure(label: Text): Vec2.Vec2 =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let scale = r#fontSize / atlas#fontSize;
        let lineHeight = (atlas#ascent + atlas#descent + atlas#lineGap) * scale;
        let rows = visualRows(label);
        let totalHeight = lineHeight * Int32.toFloat64(Int32.max(1, List.length(rows)));
        let maxRowWidth = List.foldLeft((acc, row) ->
            Float64.max(acc, TextLayout.totalAdvance(List.map(snd, row)) * scale), 0.0, rows);
        {x = maxRowWidth, y = totalHeight}

    /// 描画に使う「見た目の行」の列。要素は (文字, 送り幅)。
    /// 改行 (\n) で行を分けたうえで、wrapWidth があれば各行をさらに折り返しで分ける。
    /// 折る位置の判定は TextLayout.layoutPositions の折り返し規則に委譲する —
    /// 判定式をここへ写すと 2 実装になり、片方だけ直る事故を作るため。
    def visualRows(label: Text): List[List[(Char, Float64)]] =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let scale = r#fontSize / atlas#fontSize;
        let wrapWidth = Option.getWithDefault(0.0, r#wrapWidth);
        TextLayout.splitLines(r#text)
            |> List.flatMap(lineChars -> lineRows(atlas, scale, wrapWidth, lineChars))

    /// 改行区切りの 1 行を、折り返しで見た目の行へ分ける。空行は空の 1 行として残す
    /// （行数が減ると空行の高さが消えるため）。
    def lineRows(atlas: FontAtlas, scale: Float64, wrapWidth: Float64,
                 lineChars: List[Char]): List[List[(Char, Float64)]] =
        if (List.isEmpty(lineChars))
            (Nil: List[(Char, Float64)]) :: Nil
        // 折り返さない行は 1 行のままなので、ペン位置の列と 2 度の zip を毎コマ作らない。
        else if (wrapWidth <= 0.0)
            List.map(ch -> (ch, advanceOf(atlas, ch)), lineChars) :: Nil
        else {
            let advances = advancesOf(atlas, lineChars);
            // lineHeight に 1.0 を渡すのは、y を「何行目か」の番号としてだけ使うため。
            // 実寸の行送りをここで混ぜると、描画側の行送り計算と二重になる。
            let positions = TextLayout.layoutPositions(advances, wrapWidth, scale, 1.0);
            groupRows(List.zip(List.zip(lineChars, advances), List.map(snd, positions)))
        }

    /// 各文字の送り幅（グリフ表に無い文字は 0）。
    def advancesOf(atlas: FontAtlas, chars: List[Char]): List[Float64] =
        List.map(ch -> advanceOf(atlas, ch), chars)

    def advanceOf(atlas: FontAtlas, ch: Char): Float64 =
        match Map.get(TextLayout.charToCodePoint(ch), atlas#glyphs) {
            case Some(gm) => gm#advance
            case None     => 0.0
        }

    /// (文字, 送り幅) と行番号 y の並びを、y が変わる所で行に区切る。
    /// 蓄積はタプルで持つ — レコードは 1 フィールド 1 オブジェクトで、文字ごとに
    /// 作り直す蓄積では確保が文字数ぶん積み上がるため。
    def groupRows(entries: List[((Char, Float64), Float64)]): List[List[(Char, Float64)]] =
        let folded = List.foldLeft((acc, entry) -> {
            let (accRows, current, rowY) = acc;
            let (charAdv, y) = entry;
            if (Float64.abs(y - rowY) < 0.001)
                (accRows, charAdv :: current, rowY)
            else
                (List.reverse(current) :: accRows, charAdv :: Nil, y)
        }, ((Nil: List[List[(Char, Float64)]]),
            (Nil: List[(Char, Float64)]), 0.0), entries);
        let (accRows, current, _) = folded;
        List.reverse(List.reverse(current) :: accRows)

    /// 行内テキスト幅 (lineWidth) と horizontalAlignment から、グリフ列に適用する
    /// 横方向オフセットを返す。Fill は本実装では Left と同じ扱い（justify は未対応）。
    pub def horizontalOffsetFor(alignment: HorizontalAlignment, lineWidth: Float64): Float64 =
        match alignment {
            case HorizontalAlignment.Left   => 0.0
            case HorizontalAlignment.Center => -lineWidth / 2.0
            case HorizontalAlignment.Right  => -lineWidth
            case HorizontalAlignment.Fill   => 0.0
        }

    /// 全行の合計高さ (totalHeight) と verticalAlignment から、テキストブロック全体に
    /// 適用する縦方向オフセットを返す。Fill は本実装では Top と同じ扱い。
    pub def verticalOffsetFor(alignment: VerticalAlignment, totalHeight: Float64): Float64 =
        match alignment {
            case VerticalAlignment.Top    => 0.0
            case VerticalAlignment.Center => -totalHeight / 2.0
            case VerticalAlignment.Bottom => -totalHeight
            case VerticalAlignment.Fill   => 0.0
        }

    /// テキストから Drawable のリストを生成する。
    /// 各グリフに対して 1 つの Drawable を生成する。テキスト中の改行 (\n) と、
    /// wrapWidth の折り返しとで複数行に分割される。
    /// horizontalAlignment は見た目の行ごとに、verticalAlignment はテキストブロック全体に適用される。
    pub def toDrawables(label: Text, globalPos: Vec2.Vec2): List[GameEngine.Drawable] =
        toDrawablesUncached(label, globalPos)

    // ---- スパイク: 字の組みをコマをまたいで控える（案 1）。控えの置き場は engine_world の側 ----

    pub type alias LayoutGlyph = { ax = Float64, ay = Float64, gw = Float64, gh = Float64,
                               s0 = Float64, t0 = Float64, su = Float64, tv = Float64 }
    pub type alias LayoutRow = { yOff = Float64, offsetX = Float64, glyphs = List[LayoutGlyph] }
    pub type alias Layout = { textureName = String, fontSize = Float64, wrapWidth = Option[Float64],
                          h = HorizontalAlignment, v = VerticalAlignment, asc = Float64,
                          rows = List[LayoutRow], flatRev = List[FlatGlyph] }
    pub type alias FlatGlyph = { ax = Float64, ay = Float64, gw = Float64, gh = Float64,
                                 s0 = Float64, t0 = Float64, su = Float64, tv = Float64,
                                 yOff = Float64, offsetX = Float64 }

    pub def layoutToDrawablesV1(label: Text, lay: Layout, globalPos: Vec2.Vec2): List[GameEngine.Drawable] =
        List.reverse(layoutRowsRev(label, lay, globalPos#x, globalPos#y, lay#rows, Nil))

    // 案 2: 逆順に持った字の列を頭から積むと正順になる（並べ直しの列を作らない）。Vec2 のレコードを挟まず Drawable を直に組む。
    pub def layoutToDrawables(label: Text, lay: Layout, globalPos: Vec2.Vec2): List[GameEngine.Drawable] =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let c = r#visual#color;
        flatOnto(atlas#textureName, atlas#textureSize, c#r, c#g, c#b, r#visual#zIndex, lay#asc,
                 globalPos#x, globalPos#y, lay#flatRev, Nil)

    def flatOnto(tex: String, texSize: Float64, cr: Float64, cg: Float64, cb: Float64, z: Int32, asc: Float64,
                 gx: Float64, gy: Float64, glyphs: List[FlatGlyph], acc: List[GameEngine.Drawable]): List[GameEngine.Drawable] =
        match glyphs {
            case Nil => acc
            case g :: rest =>
                let baseY = gy + g#yOff + asc;
                let x0 = g#ax + gx + g#offsetX;
                let y0 = g#ay + baseY;
                let w = (x0 + g#gw) - x0;
                let h = (y0 + g#gh) - y0;
                let acc1 =
                    if (w <= 0.0 or h <= 0.0) acc
                    else DrawCmd.Drawable.Drawable(tex, x0, y0, w / texSize, h / texSize, 0.0,
                        cr, cg, cb, 1.0, false, g#s0, g#t0, g#su, g#tv, z,
                        None, None, DrawCmd.BlendMode.Normal, Nil, 1.0) :: acc;
                flatOnto(tex, texSize, cr, cg, cb, z, asc, gx, gy, rest, acc1)
        }

    pub def sameLayoutInputs(label: Text, lay: Layout): Bool =
        let Text.Text(r) = label;
        lay#textureName == r#fontAtlas#textureName and lay#fontSize == r#fontSize
            and lay#wrapWidth == r#wrapWidth and lay#h == r#horizontalAlignment
            and lay#v == r#verticalAlignment

    pub def buildLayout(label: Text): Layout =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let scale = r#fontSize / atlas#fontSize;
        let lineHeight = (atlas#ascent + atlas#descent + atlas#lineGap) * scale;
        let rows = visualRows(label);
        let totalHeight = lineHeight * Int32.toFloat64(Int32.max(1, List.length(rows)));
        let blockYOffset = verticalOffsetFor(r#verticalAlignment, totalHeight);
        let built = List.mapWithIndex((i, row) -> {
            let lineWidth = advanceSum(row, 0.0) * scale;
            { yOff = Int32.toFloat64(i) * lineHeight + blockYOffset,
              offsetX = horizontalOffsetFor(r#horizontalAlignment, lineWidth),
              glyphs = List.reverse(layoutGlyphsRev(atlas, scale, row, 0.0, Nil)) }
        }, rows);
        { textureName = atlas#textureName, fontSize = r#fontSize, wrapWidth = r#wrapWidth,
          h = r#horizontalAlignment, v = r#verticalAlignment, asc = atlas#ascent * scale, rows = built,
          flatRev = List.foldLeft((acc, row) -> List.foldLeft((a, g) ->
              { ax = g#ax, ay = g#ay, gw = g#gw, gh = g#gh, s0 = g#s0, t0 = g#t0, su = g#su, tv = g#tv,
                yOff = row#yOff, offsetX = row#offsetX } :: a, acc, row#glyphs), Nil, built) }

    def layoutGlyphsRev(atlas: FontAtlas, scale: Float64, row: List[(Char, Float64)], penX: Float64,
                        acc: List[LayoutGlyph]): List[LayoutGlyph] = match row {
        case Nil => acc
        case (ch, adv) :: rest =>
            let acc1 = match Map.get(TextLayout.charToCodePoint(ch), atlas#glyphs) {
                case None => acc
                case Some(gm) =>
                    { ax = (penX + gm#xOff) * scale, ay = (0.0 + gm#yOff) * scale,
                      gw = gm#glyphW * scale, gh = gm#glyphH * scale,
                      s0 = gm#s0, t0 = gm#t0, su = gm#s1 - gm#s0, tv = gm#t1 - gm#t0 } :: acc
            };
            layoutGlyphsRev(atlas, scale, rest, penX + adv, acc1)
    }

    def layoutRowsRev(label: Text, lay: Layout, gx: Float64, gy: Float64, rows: List[LayoutRow],
                      acc: List[GameEngine.Drawable]): List[GameEngine.Drawable] = match rows {
        case Nil => acc
        case row :: rest =>
            let baseY = gy + row#yOff + lay#asc;
            let acc1 = layoutGlyphDrawablesRev(label, gx, baseY, row#offsetX, row#glyphs, acc);
            layoutRowsRev(label, lay, gx, gy, rest, acc1)
    }

    def layoutGlyphDrawablesRev(label: Text, gx: Float64, baseY: Float64, offsetX: Float64,
                                glyphs: List[LayoutGlyph],
                                acc: List[GameEngine.Drawable]): List[GameEngine.Drawable] = match glyphs {
        case Nil => acc
        case g :: rest =>
            let Text.Text(r) = label;
            let atlas = r#fontAtlas;
            let x0 = g#ax + gx + offsetX;
            let y0 = g#ay + baseY;
            let w = (x0 + g#gw) - x0;
            let h = (y0 + g#gh) - y0;
            let acc1 =
                if (w <= 0.0 or h <= 0.0) acc
                else DrawCmd.fromParts(
                    atlas#textureName,
                    {x = x0, y = y0},
                    {x = w / atlas#textureSize, y = h / atlas#textureSize},
                    0.0,
                    r#visual#color,
                    1.0,
                    false,
                    {x = g#s0, y = g#t0},
                    {x = g#su, y = g#tv},
                    r#visual#zIndex,
                    None,
                    None,
                    DrawCmd.BlendMode.Normal,
                    Nil) :: acc;
            layoutGlyphDrawablesRev(label, gx, baseY, offsetX, rest, acc1)
    }

    pub def toDrawablesUncached(label: Text, globalPos: Vec2.Vec2): List[GameEngine.Drawable] =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let scale = r#fontSize / atlas#fontSize;
        let lineHeight = (atlas#ascent + atlas#descent + atlas#lineGap) * scale;
        let rows = visualRows(label);
        let totalHeight = lineHeight * Int32.toFloat64(Int32.max(1, List.length(rows)));
        let blockYOffset = verticalOffsetFor(r#verticalAlignment, totalHeight);
        List.reverse(rowsDrawablesRev(label, globalPos, lineHeight, blockYOffset, rows, 0, Nil))

    // 蓄積をタプルで持つ foldLeft にしない — 文字ごとにタプルと箱に入れた Float64 を作り、
    // ブラウザ版では名札の多い場面の GC の大半になる。全行を 1 本の逆順の列へ積み、最後に 1 回だけ並べ直す。
    def rowsDrawablesRev(label: Text, globalPos: Vec2.Vec2, lineHeight: Float64, blockYOffset: Float64,
                         rows: List[List[(Char, Float64)]], lineIdx: Int32,
                         acc: List[GameEngine.Drawable]): List[GameEngine.Drawable] = match rows {
        case Nil => acc
        case row :: rest =>
            let Text.Text(r) = label;
            let atlas = r#fontAtlas;
            let scale = r#fontSize / atlas#fontSize;
            let lineWidth = advanceSum(row, 0.0) * scale;
            let offsetX = horizontalOffsetFor(r#horizontalAlignment, lineWidth);
            let yOff = Int32.toFloat64(lineIdx) * lineHeight + blockYOffset;
            let baseY = globalPos#y + yOff + atlas#ascent * scale;
            let acc1 = glyphsDrawablesRev(label, globalPos#x, baseY, offsetX, row, 0.0, acc);
            rowsDrawablesRev(label, globalPos, lineHeight, blockYOffset, rest, lineIdx + 1, acc1)
    }

    def advanceSum(row: List[(Char, Float64)], sum: Float64): Float64 = match row {
        case Nil => sum
        case (_, adv) :: rest => advanceSum(rest, sum + adv)
    }

    def glyphsDrawablesRev(label: Text, baseX: Float64, baseY: Float64, offsetX: Float64,
                           row: List[(Char, Float64)], penX: Float64,
                           acc: List[GameEngine.Drawable]): List[GameEngine.Drawable] = match row {
        case Nil => acc
        case (ch, adv) :: rest =>
            let acc1 = glyphDrawableOnto(label, baseX, baseY, offsetX, ch, penX, acc);
            glyphsDrawablesRev(label, baseX, baseY, offsetX, rest, penX + adv, acc1)
    }

    // TextLayout.glyphQuadBounds を呼ばない — 文字ごとに四角のレコードとペン位置のタプルを作るため。
    // 式（足す順まで）は glyphQuadBounds と同じに保ち、画素を変えない。
    def glyphDrawableOnto(label: Text, baseX: Float64, baseY: Float64, offsetX: Float64,
                          ch: Char, penX: Float64,
                          acc: List[GameEngine.Drawable]): List[GameEngine.Drawable] =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let scale = r#fontSize / atlas#fontSize;
        match Map.get(TextLayout.charToCodePoint(ch), atlas#glyphs) {
            case None => acc
            case Some(gm) =>
                let x0 = (penX + gm#xOff) * scale + baseX + offsetX;
                let y0 = (0.0 + gm#yOff) * scale + baseY;
                let w = (x0 + gm#glyphW * scale) - x0;
                let h = (y0 + gm#glyphH * scale) - y0;
                if (w <= 0.0 or h <= 0.0) acc
                else DrawCmd.fromParts(
                    atlas#textureName,
                    {x = x0, y = y0},
                    {x = w / atlas#textureSize, y = h / atlas#textureSize},
                    0.0,
                    r#visual#color,
                    1.0,
                    false,
                    {x = gm#s0, y = gm#t0},
                    {x = gm#s1 - gm#s0, y = gm#t1 - gm#t0},
                    r#visual#zIndex,
                    None,
                    None,
                    DrawCmd.BlendMode.Normal,
                    Nil) :: acc
        }

}

// -- Renderable 実装 --

instance GameEngine.Renderable[Text] {
    pub def toDrawables(label: Text, globalPos: Vec2.Vec2):
                         List[GameEngine.Drawable] \ Platform.GpuResources =
        // 本体は純粋だが trait 側が Platform.GpuResources を要求するため checked_ecast で持ち上げる。
        checked_ecast(Text.toDrawables(label, globalPos))
}

