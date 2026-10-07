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
        else {
            let advances = advancesOf(atlas, lineChars);
            // lineHeight に 1.0 を渡すのは、y を「何行目か」の番号としてだけ使うため。
            // 実寸の行送りをここで混ぜると、描画側の行送り計算と二重になる。
            let positions = TextLayout.layoutPositions(advances, wrapWidth, scale, 1.0);
            groupRows(List.zip(List.zip(lineChars, advances), List.map(snd, positions)))
        }

    /// 各文字の送り幅（グリフ表に無い文字は 0）。
    def advancesOf(atlas: FontAtlas, chars: List[Char]): List[Float64] =
        List.map(ch -> {
            let cp = TextLayout.charToCodePoint(ch);
            match Map.get(cp, atlas#glyphs) {
                case Some(gm) => gm#advance
                case None     => 0.0
            }
        }, chars)

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
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        let scale = r#fontSize / atlas#fontSize;
        let lineHeight = (atlas#ascent + atlas#descent + atlas#lineGap) * scale;
        let rows = visualRows(label);
        let totalHeight = lineHeight * Int32.toFloat64(Int32.max(1, List.length(rows)));
        let blockYOffset = verticalOffsetFor(r#verticalAlignment, totalHeight);
        let result = List.foldLeft((acc, row) -> {
            let (accRows, lineIdx) = acc;
            // 行幅と horizontalAlignment から横オフセット計算（足す順は totalAdvance と同じ左から）
            let lineWidth = List.foldLeft((a, entry) -> a + snd(entry), 0.0, row) * scale;
            let offsetX = horizontalOffsetFor(r#horizontalAlignment, lineWidth);
            let yOff = Int32.toFloat64(lineIdx) * lineHeight + blockYOffset;
            let ascentOffset = atlas#ascent * scale;
            let lineGlobalPos = {x = globalPos#x, y = globalPos#y + yOff + ascentOffset};
            // グリフごとに Drawable を生成。ペン位置は行頭 0 から送り幅を足し込むだけ —
            // layoutPositions をもう一度呼ぶと、文字数ぶんのペン位置リストと文字との zip を
            // 毎フレーム組み直すことになる（行の割りは visualRows が済ませている）。
            let folded = List.foldLeft((acc2, entry) -> {
                let (dsRev, penX) = acc2;
                let (ch, adv) = entry;
                let cp = TextLayout.charToCodePoint(ch);
                match Map.get(cp, atlas#glyphs) {
                    case Some(gm) =>
                        let qb = TextLayout.glyphQuadBounds((penX, 0.0), gm, scale, lineGlobalPos, offsetX);
                        let w = qb#x1 - qb#x0;
                        let h = qb#y1 - qb#y0;
                        if (w <= 0.0 or h <= 0.0) (dsRev, penX + adv)
                        else (DrawCmd.fromParts(
                            atlas#textureName,
                            {x = qb#x0, y = qb#y0},
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
                            Nil) :: dsRev, penX + adv)
                    case None => (dsRev, penX + adv)
                }
            }, ((Nil: List[GameEngine.Drawable]), 0.0), row);
            // 行ごとの列を先頭へ積んで最後に並べ直す。acc へ append すると行数の二乗で割り当てる。
            (List.reverse(fst(folded)) :: accRows, lineIdx + 1)
        }, ((Nil: List[List[GameEngine.Drawable]]), 0), rows);
        List.flatten(List.reverse(fst(result)))

}

// -- Renderable 実装 --

instance GameEngine.Renderable[Text] {
    pub def toDrawables(label: Text, globalPos: Vec2.Vec2):
                         List[GameEngine.Drawable] \ GameEngine.Game =
        // 本体は純粋だが trait 側が Game eff を要求するため checked_ecast で持ち上げる。
        checked_ecast(Text.toDrawables(label, globalPos))
}

