// ViewText — 読んでいる間の文字の層（純粋）: メッセージ枠の型（novel.theme.json の windows）ごとの NVL の頁・ADV の枠・縦の画面の頁と、
// 本文の 1 行の置き方・送りの印。字の置き場・大きさ・揃えは Stage の text.* の値（<<text>>）。
mod ViewText {
    use fge::{Color, DrawCmd, FontAtlas, Num, RawDraw, Rect2, Render, RichText, TextDraw, Vec2}
    use View.Env

    /// 横の画面の文字の層。メッセージ枠の型の出し方（NVL・ADV）で描き分ける。
    pub def textLayer(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let window = snd(Stage.windowOf(env#res#theme, r#stage));
        match window#kind {
            case ThemeDoc.WindowKind.Nvl => nvl(atlas, env, window, r)
            case ThemeDoc.WindowKind.Adv => adv(atlas, env, window, r)
        }

    /// 本文の置き方: outline = 1 つの影でなく周りの縁取りで字を立たせる（地を敷かない型）、
    /// centered = 改行（\n）で区切った行ごとに、1 行に収まる物を幅の中央にそろえる。
    pub type alias Style = { outline = Bool, centered = Bool }

    /// 今の舞台の本文の置き方（縁取りはメッセージ枠の型の frame、揃えは <<text align=>>）。
    // WhyNot: 幅で折り返す行は中央にそろえない — 描く RichText に揃えの API が無く、折り目ごとに分けるには折り目の位置を RichText の外で引き直すことになる。
    //   折り返す行は幅いっぱいなので動かす量もほぼ無い。改行の切れ目は字で分かるので、そこでだけ分けて置く。
    def styleOf(window: ThemeDoc.Window, stage: Stage.Stage): Style =
        { outline = window#frame == ThemeDoc.WindowFrame.Outline,
          centered = PropertyTween.nameEnd(Stage.textAlignKey(), stage#props) == Some("center") }

    /// sizes に今の舞台の字の大きさの倍率（<<text size=>>）を掛けた物。
    def scaled(env: Env, stage: Stage.Stage, sizes: { body = Float64, ruby = Float64 }): { body = Float64, ruby = Float64 } =
        let s = Stage.textScaleOf(env#res#kind, stage);
        { body = sizes#body * s, ruby = sizes#ruby * s }

    /// 縁取りの影を置くずれ（周り 8 方向）。
    def outlineOffsets(): List[(Float64, Float64)] =
        (-1.5, -1.5) :: (0.0, -1.5) :: (1.5, -1.5) :: (-1.5, 0.0) :: (1.5, 0.0) :: (-1.5, 1.5) :: (0.0, 1.5) :: (1.5, 1.5) :: Nil

    /// 1 行を置く（字の下に 1px ずらした影を敷き、写真の明るい所でも字の縁が立つようにする。縁取りの型は周り 8 方向に影）。
    /// sizes = 本文とルビの字の大きさ（行の間は本文の字に比べて novel.kind.json の lineGap の割合）。
    /// 中央にそろえる時は改行（\n）で区切った行ごとに分けて置き（rowsOf の行の数で下へ送る）、文字送りの数とルビの位置は行の頭の字の位置だけずらす。
    def placeLine(atlas: FontAtlas, pos: Vec2.Vec2, width: Float64, sizes: { body = Float64, ruby = Float64 }, ink: Color, visible: Int32,
                  line: Page.Line, style: Style, env: Env): List[Render.PlacedItem] =
        let k = View.kindOf(env);
        let rowStep = sizes#body + k#lineGap * sizes#body / k#bodySize;
        let segments = if (style#centered) segmentsOf(line) else (0, line) :: Nil;
        let (items, _) = segments |> List.foldLeft((acc, seg) -> {
            let (done, y) = acc;
            let (start, part) = seg;
            let placed = placeSegment(atlas, { x = pos#x, y = y }, width, sizes, ink, visible - start, part, style, env);
            (placed :: done, y + Int32.toFloat64(Page.rowsOf(sizes#body, sizes#ruby, width, part)) * rowStep)
        }, (Nil, pos#y));
        List.flatten(List.reverse(items))

    /// 改行で区切った行と、その行の頭の字が元の行の何字目か（ルビはその行の中に収まる物だけ、行の頭からの位置へずらす）。
    def segmentsOf(line: Page.Line): List[(Int32, Page.Line)] =
        let parts = String.splitOn(substr = "\n", line#text);
        let (segments, _) = parts |> List.foldLeft((acc, text) -> {
            let (done, start) = acc;
            let len = String.length(text);
            let rubies = line#rubies |> List.filter(r -> r#start >= start and r#start + r#length <= start + len)
                                     |> List.map(r -> { start = r#start - start | r });
            ((start, { text = text, rubies = rubies | line }) :: done, start + len + 1)
        }, (Nil, 0));
        List.reverse(segments)

    /// 改行を含まない 1 行（か中央にそろえない行全体）を置く。1 行に収まり、そろえる時は幅の中央へ。
    def placeSegment(atlas: FontAtlas, pos: Vec2.Vec2, width: Float64, sizes: { body = Float64, ruby = Float64 }, ink: Color, visible: Int32,
                     line: Page.Line, style: Style, env: Env): List[Render.PlacedItem] =
        let k = View.kindOf(env);
        let place = (tint, p, z) -> RichText.placeRuby(
            { atlas = atlas, size = sizes#body, baseTint = tint, z = z, pos = p, maxWidth = width, lineGap = k#lineGap * sizes#body / k#bodySize },
            sizes#ruby, line#rubies, visible, RichText.plain(line#text) :: Nil);
        let oneRow = Page.rowsOf(sizes#body, sizes#ruby, width, line) <= 1;
        let offset = if (style#centered and oneRow) Float64.max(0.0, (width - TextDraw.width(line#text, atlas, sizes#body)) / 2.0) else 0.0;
        let at = { x = pos#x + offset, y = pos#y };
        let (shadows, shade) = if (style#outline) (outlineOffsets(), 0.8) else ((1.0, 1.5) :: Nil, 0.55);
        let under = shadows |> List.flatMap(match (dx, dy) -> place({ r = 0.0, g = 0.0, b = 0.0 }, { x = at#x + dx, y = at#y + dy }, View.zText()) |> List.map(fadeTo(shade)));
        List.append(under, place(ink, at, View.zText() + 1))

    def fadeTo(alpha: Float64): Render.PlacedItem -> Render.PlacedItem = placed -> Render.overItem(item -> Render.fade(alpha, item), placed)

    /// 今の行を既に読んでいれば既読の色、まだなら話し手の本文の色。
    def inkOf(line: Page.Line, env: Env, r: World.Read): Color =
        let isCurrent = Option.exists(c -> c#source == line#source, r#page#current);
        if (isCurrent and Saves.isSeen(line#source, env#saves)) View.theme(env)#inkSeen else speakerOf(line, env)#ink

    /// 行の話し手の色（novel.theme.json の speakers。地の文は空の id）。id は行の speakerId で、それを書く前のセーブの行だけ呼び名から引く。
    pub def speakerOf(line: Page.Line, env: Env): ThemeDoc.Speaker =
        let id = if (not String.isEmpty(line#speakerId) or String.isEmpty(line#speaker)) line#speakerId else StoryDoc.idOfName(line#speaker, env#res#story);
        ThemeDoc.speakerOf(id, env#res#theme)

    /// 1 行が頁に占める高さ（行の数 × (字 + 行の間)）。行の間は本文の字に比べて novel.kind.json の lineGap の割合（placeLine と同じ）。
    def lineHeight(env: Env, sizes: { body = Float64, ruby = Float64 }, width: Float64, line: Page.Line): Float64 =
        let k = View.kindOf(env);
        Int32.toFloat64(Page.rowsOf(sizes#body, sizes#ruby, width, line)) * (sizes#body + k#lineGap * sizes#body / k#bodySize)

    /// NVL: 画面いっぱいに幕を敷き（縁取りの型は敷かない）、頁に積んだ行と今の行を並べる（行の間に少し空きを入れて段落にする）。
    /// ブロックは <<text at=>> で頁の上（既定）・真ん中・下に置く。頁の下は上の余白と同じだけ画面の下から上。
    def nvl(atlas: FontAtlas, env: Env, window: ThemeDoc.Window, r: World.Read): List[Render.PlacedItem] =
        let t = View.theme(env);
        let k = View.kindOf(env);
        let area = Layout.nvlText();
        let style = styleOf(window, r#stage);
        let sizes = scaled(env, r#stage, { body = k#bodySize, ruby = k#rubySize });
        let veil = if (style#outline) Nil
                   else View.at(0.0, 0.0, RawDraw.box(Layout.size(env#fit), t#panel, View.zVeil()) |> Render.fade(Float64.min(0.95, View.windowAlpha(env) * t#veil))) :: Nil;
        let current = r#page#current |> Option.map(line -> (line, Page.visibleCount(r#page)) :: Nil) |> Option.getWithDefault(Nil);
        let rows = List.append(r#page#lines |> List.map(line -> (line, String.length(line#text))), current);
        let gap = 6.0;
        let blockHeight = rows |> List.foldLeft((sum, row) -> sum + lineHeight(env, sizes, area#width, fst(row)) + gap, 0.0);
        let room = Layout.height(env#fit) - 2.0 * area#y;
        let top = match PropertyTween.nameEnd(Stage.textAtKey(), r#stage#props) {
            case Some("center") => area#y + Float64.max(0.0, room - blockHeight) / 2.0
            case Some("bottom") => area#y + Float64.max(0.0, room - blockHeight)
            case _              => area#y
        };
        let (items, endY) = rows |> List.foldLeft((acc, row) -> {
            let (done, y) = acc;
            let (line, visible) = row;
            let placed = placeLine(atlas, { x = area#x, y = y }, area#width, sizes, inkOf(line, env, r), visible, line, style, env);
            (placed :: done, y + lineHeight(env, sizes, area#width, line) + gap)
        }, (Nil, top));
        List.flatten(veil :: List.flatten(List.reverse(items)) :: waitMark(atlas, { x = area#x + area#width - 10.0, y = endY - 4.0 }, env, r) :: Nil)

    /// ADV: 枠（上から下へ濃くなる地と、金の細い縁。縁取りの型は地も縁も敷かない）に、名前（型の showName）と今の 1 行。
    /// 枠は型の place で画面の下（既定）か真ん中。
    def adv(atlas: FontAtlas, env: Env, window: ThemeDoc.Window, r: World.Read): List[Render.PlacedItem] =
        let t = View.theme(env);
        let sizes = Layout.advTextSizes(env#fit, View.kindOf(env));
        let base = Layout.advPanel(env#fit);
        let p = Layout.advPanelAt(env#fit, window#place);
        let dy = p#position#y - base#position#y;
        let style = styleOf(window, r#stage);
        let ground = if (style#outline) Nil
                     else { at = p#position, item = Render.vgrad(p#size, { top = t#panel, bottom = Color.darken(t#panel, 0.3) }, View.zVeil()) |> Render.fade(View.windowAlpha(env)) } ::
                          { at = p#position, item = RawDraw.box({ x = p#size#x, y = 1.0 }, t#accent, View.zVeil() + 1) |> Render.fade(0.45) } :: Nil;
        let text = Layout.advText(env#fit);
        let namePos = Layout.advName(env#fit);
        match r#page#current {
            case None => ground
            case Some(line) =>
                let nameAt = { x = namePos#x, y = namePos#y + dy };
                let nameShade = if (style#outline) outlineOffsets() |> List.map(match (ox, oy) -> { at = { x = nameAt#x + ox, y = nameAt#y + oy },
                                    item = Render.textTinted(line#speaker, atlas, sizes#name, { r = 0.0, g = 0.0, b = 0.0 }, View.zText()) |> Render.fade(0.8) }) else Nil;
                let name = if (String.isEmpty(line#speaker) or not window#showName) Nil
                    else List.append(nameShade, { at = nameAt, item = Render.textTinted(line#speaker, atlas, sizes#name, speakerOf(line, env)#color, View.zText() + 1) } :: Nil);
                let body = placeLine(atlas, { x = text#x, y = text#y + dy }, text#width, scaled(env, r#stage, { body = sizes#body, ruby = sizes#ruby }), inkOf(line, env, r),
                                     Page.visibleCount(r#page), line, style, env);
                List.flatten(ground :: name :: body ::
                    waitMark(atlas, { x = p#position#x + p#size#x - 30.0, y = p#position#y + p#size#y - 30.0 }, env, r) :: Nil)
        }

    /// 送りの印（行を出し終えて、送れる時だけ明滅する。コマンドが出した待ちの間とゲートの頁は送れないので出さない）。オートの間は点けたまま（押さなくても進むと分かる）。
    def waitMark(atlas: FontAtlas, pos: Vec2.Vec2, env: Env, r: World.Read): List[Render.PlacedItem] =
        if (not Page.isDone(r#page) or not List.isEmpty(r#choices) or Option.isEmpty(r#page#current) or NovelBeat.isHolding(r#beat#waiting) or Option.nonEmpty(WorldRead.gateOf(r))) Nil
        else {
            let alpha = if (r#playback == World.Playback.Auto) 0.9 else 0.35 + 0.55 * (0.5 + 0.5 * Num.sin(View.realSeconds(env) * 4.0));
            { at = pos, item = Render.textTinted("▼", atlas, 14.0, View.theme(env)#accent, View.zText() + 2) |> Render.fade(alpha) } :: Nil
        }

    // ── 縦の画面の頁 ──

    /// 縦の画面: 写真を上から下へ濃くなる覆いで沈め（縁取りの型は沈めない）、画面いっぱいの頁に文を上から積む（NVL も ADV も同じ頁）。前の行は少し薄く、今の行ははっきり。
    /// 頁の切れ目は World のまま（NVL の <<window clear>> と行の数・ADV の場面の切れ目）。縦の頁に入り切らない時は、古い行から行ごと上へ流して今の行を必ず見せる。
    /// 名前は型の showName が真の時だけ添える。
    pub def portraitPage(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let window = snd(Stage.windowOf(env#res#theme, r#stage));
        match window#portrait {
            case ThemeDoc.PortraitText.Band(h)       => portraitBand(atlas, env, r, window, h)
            case ThemeDoc.PortraitText.Page          => portraitStack(atlas, env, r, window)
            case ThemeDoc.PortraitText.Frame(center) => portraitFrame(atlas, env, r, window, center)
        }

    /// 縦の画面の真ん中のメッセージ枠の矩形（型の portrait が frame で、縦の画面の時だけ）。GameView が枠のそばに物を置く時と、
    /// 移行の記録の画面の物が読む。
    pub def messageFrameOf(fit: Layout.Fit, res: Res.Res, r: World.Read): Option[Rect2.Rect2] =
        match snd(Stage.windowOf(res#theme, r#stage))#portrait {
            case ThemeDoc.PortraitText.Frame(center) if Layout.isPortrait(fit) => Some(frameRectOf(fit, res, r, center))
            case _ => None
        }

    /// 今の行の行の数で決めた枠（行の無い時は 1 行）。
    def frameRectOf(fit: Layout.Fit, res: Res.Res, r: World.Read, center: Float64): Rect2.Rect2 =
        let sizes = Layout.advTextSizes(fit, KindDoc.rec(res#kind));
        let width = Layout.width(fit) - 2.0 * 14.0 - 2.0 * Layout.frameInset();
        let rows = r#page#current |> Option.map(line -> Page.rowsOf(sizes#body, sizes#ruby, width, line)) |> Option.getWithDefault(1);
        Layout.portraitFrame(fit, center, sizes#body, rows)

    /// 縦の画面の真ん中の枠: 半透明の暗い角丸の地と外へぼける影を敷き、枠の中に今の行だけを出す（前の行は出さない）。
    def portraitFrame(atlas: FontAtlas, env: Env, r: World.Read, window: ThemeDoc.Window, center: Float64): List[Render.PlacedItem] =
        let t = View.theme(env);
        let style = styleOf(window, r#stage);
        let base = Layout.advTextSizes(env#fit, View.kindOf(env));
        let sizes = { body = base#body, ruby = base#ruby, name = base#name };
        let frame = frameRectOf(env#fit, env#res, r, center);
        let area = Layout.frameText(frame);
        let a = Float64.min(0.9, View.windowAlpha(env) * 0.8);
        let mid = { x = frame#position#x + frame#size#x / 2.0, y = frame#position#y + frame#size#y / 2.0 };
        let halo = Render.glowAt(mid, frame#size#y * 0.5 + 120.0, Color.darken(t#panel, 0.4), { alpha = 0.3, blend = DrawCmd.BlendMode.Normal }, View.zVeil());
        let ground = View.at(frame#position#x, frame#position#y,
                             RawDraw.box(frame#size, t#panel, View.zVeil() + 1) |> Render.fade(a)
                                 |> Render.outlineA({ color = t#accent, alpha = 0.25, width = 1.0 }) |> Render.rounded(16.0));
        let text = r#page#current |> Option.map(line -> {
            let speaker = speakerOf(line, env);
            let placed = portraitBlock(atlas, sizes, area#position, area#size#x, { body = inkOf(line, env, r), name = speaker#color },
                                       Page.visibleCount(r#page), line, window#showName, style, env);
            List.append(placed, waitMark(atlas, { x = frame#position#x + frame#size#x - Layout.frameInset(), y = frame#position#y + frame#size#y - 12.0 }, env, r))
        }) |> Option.getWithDefault(Nil);
        List.flatten(halo :: (ground :: Nil) :: text :: Nil)

    /// 縦の画面の下の帯: 帯の上にだけ下へ濃くなる覆いを敷き、帯の上端から今の行だけを出す（前の行は出さない）。
    def portraitBand(atlas: FontAtlas, env: Env, r: World.Read, window: ThemeDoc.Window, bandHeight: Float64): List[Render.PlacedItem] =
        let style = styleOf(window, r#stage);
        let base = Layout.advTextSizes(env#fit, View.kindOf(env));
        let body = scaled(env, r#stage, { body = base#body, ruby = base#ruby });
        let sizes = { body = body#body, ruby = body#ruby, name = base#name };
        let area = Layout.portraitBand(env#fit, bandHeight, if (Option.nonEmpty(WorldRead.gateOf(r))) 0 else List.length(r#choices));
        let text = r#page#current |> Option.map(line -> {
            let speaker = speakerOf(line, env);
            let placed = portraitBlock(atlas, sizes, area#position, area#size#x, { body = inkOf(line, env, r), name = speaker#color },
                                       Page.visibleCount(r#page), line, window#showName, style, env);
            let endY = area#position#y + blockHeight(env, sizes, window#showName, area#size#x, line);
            List.append(placed, waitMark(atlas, { x = area#position#x + area#size#x - 12.0, y = endY - 4.0 }, env, r))
        }) |> Option.getWithDefault(Nil);
        let veil = if (style#outline) Nil else bandVeil(env, area#position#y);
        List.append(veil, text)

    /// 帯の覆いが帯の上端より上で薄く始まる高さ（px）。
    def bandFadeHeight(): Float64 = 150.0

    /// 帯の覆い: 帯の上端の bandFadeHeight 上から上端まで薄く始まり、上端から画面の下端まで濃くなる（帯より上は沈めない）。
    def bandVeil(env: Env, top: Float64): List[Render.PlacedItem] =
        let t = View.theme(env);
        let a = View.windowAlpha(env);
        let size = Layout.size(env#fit);
        let fade = Float64.max(0.0, top - bandFadeHeight());
        let band = (y0, y1, a0, a1) -> View.at(0.0, y0, Render.gradPolygon(
            { pos = { x = 0.0, y = 0.0 },     color = t#panel, alpha = a0 } ::
            { pos = { x = size#x, y = 0.0 },  color = t#panel, alpha = a0 } ::
            { pos = { x = size#x, y = y1 - y0 }, color = Color.darken(t#panel, 0.2), alpha = a1 } ::
            { pos = { x = 0.0, y = y1 - y0 },    color = Color.darken(t#panel, 0.2), alpha = a1 } :: Nil,
            View.zVeil()));
        band(fade, top, 0.0, Float64.min(0.95, 0.7 * a)) :: band(top, size#y, Float64.min(0.95, 0.7 * a), Float64.min(0.97, 1.05 * a)) :: Nil

    /// 縦の画面の頁: 行を上から積む（portraitPage の Page）。
    def portraitStack(atlas: FontAtlas, env: Env, r: World.Read, window: ThemeDoc.Window): List[Render.PlacedItem] =
        let t = View.theme(env);
        let style = styleOf(window, r#stage);
        let base = Layout.advTextSizes(env#fit, View.kindOf(env));
        let body = scaled(env, r#stage, { body = base#body, ruby = base#ruby });
        let sizes = { body = body#body, ruby = body#ruby, name = base#name };
        let area = Layout.page(env#fit, if (Option.nonEmpty(WorldRead.gateOf(r))) 0 else List.length(r#choices));
        let blockOf = (line, visible, isCurrent) ->
            { line = line, visible = visible, isCurrent = isCurrent, height = blockHeight(env, sizes, window#showName, area#size#x, line) };
        let older = r#page#lines |> List.map(line -> blockOf(line, String.length(line#text), false));
        let current = r#page#current |> Option.map(line -> blockOf(line, Page.visibleCount(r#page), true)) |> Option.toList;
        let shown = keepLatest(area#size#y, List.append(older, current));
        let (items, endY) = shown |> List.foldLeft((acc, b) -> {
            let (done, y) = acc;
            let speaker = speakerOf(b#line, env);
            let ink = if (b#isCurrent) inkOf(b#line, env, r) else Color.mix(speaker#ink, t#panel, 0.12);
            let nameInk = if (b#isCurrent) speaker#color else Color.mix(speaker#color, t#panel, 0.45);
            (portraitBlock(atlas, sizes, { x = area#position#x, y = y }, area#size#x, { body = ink, name = nameInk }, b#visible, b#line, window#showName, style, env) :: done,
             y + b#height + Layout.paragraphGap())
        }, (Nil, area#position#y));
        let mark = waitMark(atlas, { x = area#position#x + area#size#x - 12.0, y = endY - Layout.paragraphGap() - 4.0 }, env, r);
        let veil = if (style#outline) Nil else portraitVeil(env, r#stage);
        List.flatten(veil :: List.flatten(List.reverse(items)) :: mark :: Nil)

    /// 縦の頁の覆い（上から下へ濃くなる）。濃さは設定の「ウィンドウの濃さ」に比べ、人物が出ている間は novel.cast.json の
    /// portraitVeilWithCast を、人物の出入りの進みに合わせて掛ける（出ると薄く、消えると戻る）。
    def portraitVeil(env: Env, stage: Stage.Stage): List[Render.PlacedItem] =
        let t = View.theme(env);
        let withCast = CastDoc.rec(env#res#cast)#portraitVeilWithCast;
        let presence = Cast.presenceOf(env#storyNow, env#res#cast, stage#cast);
        let a = View.windowAlpha(env) * (1.0 + (withCast - 1.0) * presence);
        let stops = (0.0, 0.6 * a) :: (0.3, 1.1 * a) :: (1.0, 1.2 * a) :: Nil;
        let size = Layout.size(env#fit);
        List.zip(stops, List.drop(1, stops)) |> List.map(match ((y0, a0), (y1, a1)) -> {
            let top = size#y * y0;
            let bottom = size#y * y1;
            let alpha0 = Float64.min(0.95, a0);
            let alpha1 = Float64.min(0.95, a1);
            View.at(0.0, top, Render.gradPolygon(
                { pos = { x = 0.0, y = 0.0 },              color = t#panel, alpha = alpha0 } ::
                { pos = { x = size#x, y = 0.0 },           color = t#panel, alpha = alpha0 } ::
                { pos = { x = size#x, y = bottom - top },  color = Color.darken(t#panel, 0.2), alpha = alpha1 } ::
                { pos = { x = 0.0, y = bottom - top },     color = Color.darken(t#panel, 0.2), alpha = alpha1 } :: Nil,
                View.zVeil()))
        })

    /// 縦の頁の 1 行が占める高さ（台詞で名前を添えるなら上に名前の行 + 本文の行の数 × (字 + 行の間)）。
    def blockHeight(env: Env, sizes: { body = Float64, ruby = Float64, name = Float64 }, showName: Bool, width: Float64, line: Page.Line): Float64 =
        nameRowOf(sizes, showName, line) + lineHeight(env, { body = sizes#body, ruby = sizes#ruby }, width, line)

    // WhyNot: 名前の行を名前の字の高さだけにしない — 本文の 1 行目のルビが名前の行の下へはみ出して重なる。
    def nameRowOf(sizes: { body = Float64, ruby = Float64, name = Float64 }, showName: Bool, line: Page.Line): Float64 =
        if (String.isEmpty(line#speaker) or not showName) 0.0 else sizes#name + 8.0 + sizes#ruby * 0.5

    /// 縦の頁に置く 1 行: 行・見えている字の数・今の行か・占める高さ。
    pub type alias Block = { line = Page.Line, visible = Int32, isCurrent = Bool, height = Float64 }

    /// 新しい方から、高さ room に入るだけの行（古い順に戻して返す）。行の途中では切らず行ごと落とす。今の行（最後）は入らなくても必ず残す。
    pub def keepLatest(room: Float64, blocks: List[Block]): List[Block] =
        let (kept, _, _) = List.reverse(blocks) |> List.foldLeft((acc, b) -> {
            let (taken, used, open) = acc;
            let next = used + b#height + (if (List.isEmpty(taken)) 0.0 else Layout.paragraphGap());
            if (open and (List.isEmpty(taken) or next <= room)) (b :: taken, next, true) else (taken, used, false)
        }, (Nil, 0.0, true));
        kept

    /// 縦の頁の 1 行（台詞は台詞の頭に名前を小さく添える）。ink = 本文と名前の色（前の行は薄く）。
    def portraitBlock(atlas: FontAtlas, sizes: { body = Float64, ruby = Float64, name = Float64 }, pos: Vec2.Vec2, width: Float64,
                      ink: { body = Color, name = Color }, visible: Int32, line: Page.Line, showName: Bool, style: Style, env: Env): List[Render.PlacedItem] =
        let nameRow = nameRowOf(sizes, showName, line);
        let name = if (nameRow > 0.0) View.textAt(pos#x, pos#y, line#speaker, atlas, sizes#name, ink#name, View.zText() + 1) :: Nil else Nil;
        let body = placeLine(atlas, { x = pos#x, y = pos#y + nameRow }, width,
                             { body = sizes#body, ruby = sizes#ruby }, ink#body, visible, line, style, env);
        List.append(name, body)
}
