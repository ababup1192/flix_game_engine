// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「夏の田舎の、記憶の中の写真」。背景は実写をぼかして時間帯の色に染め（Backdrop）、その上に明朝の字を置く。
//   主役は文章。写真はぼかして奥へ下げ、字の下には必ず暗い地（ADV の窓・NVL の幕）を敷いて読ませる。
//   色は 3 つ: 写真の時間帯の色 / 紙のような白い字 / 夕陽の金（選んでいる物・名前）。
//   やらないこと: 写真をぼかさずに出さない（字と喧嘩する）。字を写真の上に地無しで置かない。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「写真を奥へ下げて文章を主役にする」層の分け方。
//
// ── 画面の層（奥から手前へ）──
//   world: 前の背景（重ねている間だけ）→ 今の背景（進みで現れる）→ 粒の演出（蛍）        … 揺れはこの層だけに掛かる
//   hud:   NVL の幕 / ADV の窓 → 本文（ルビつき）・名前 → 送りの印 → 選択肢 → ボタンの帯 → 窓（ログ・栞・設定）→ 知らせ
//          表紙とクレジットも hud（写真の上に字だけを置く画面）
//
// ── 時計 ── 背景の重ね・揺れは物語の時計（窓を開くと止まる）、蛍・送りの印の明滅・クレジットは実時間（w#realNow）。
mod View {
    use fge::{App, Clock, Color, DrawCmd, FontAtlas, Fx, RawDraw, Rect2, Render, RichText, ShaderDoc, TextDraw, Vec2}

    // ── hud の中の z（小さいほど奥） ──
    def zVeil(): Int32 = 10
    def zText(): Int32 = 20
    def zChoice(): Int32 = 30
    def zButtons(): Int32 = 40
    def zPanel(): Int32 = 50
    def zPanelText(): Int32 = 52
    def zToast(): Int32 = 60

    pub def frame(_ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let now = Clock.nowOf(w#storyClock);
        let k = KindDoc.rec(w#kind);
        let (dx, dy) = Stage.shakeOffset(now, k#shakeSeconds, k#shakePx, w#stage);
        List.append(backdrops(w), particles(w))
            |> List.map(placed -> { at = { x = placed#at#x + dx, y = placed#at#y + dy } | placed })

    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let atlas = ctx#atlas;
        // 窓（ログ・栞・設定）の間は下の画面を描かない（窓の幕越しに字が二重に透けて読みにくい）。背景の写真は frame が描き続ける。
        let covered = match w#panel {
            case World.Panel.Closed => false
            case World.Panel.Hidden => false
            case _                  => true
        };
        let screen = if (covered) Nil else match w#phase {
            case World.Phase.Title   => title(atlas, w)
            case World.Phase.Credits => credits(atlas, w)
            case World.Phase.Reading =>
                if (w#panel == World.Panel.Hidden) Nil
                else List.flatten(textLayer(atlas, w) :: choices(atlas, w) :: buttons(atlas, w) :: Nil)
        };
        List.flatten(screen :: panel(atlas, w) :: toast(atlas, w) :: Nil)

    def realSeconds(w: World.World): Float64 = Clock.secondsOf(w#realNow)

    def theme(w: World.World): ThemeDoc.Rec = ThemeDoc.rec(w#theme)

    def label(l: StoryDoc.Label, w: World.World): String = StoryDoc.labelOf(l, w#story)

    // ── 背景（写真をぼかして時間帯の色に） ──

    /// 揺れても画面の端が覗かないよう、背景は画面より一回り大きく敷く。
    def backdropRect(): Rect2.Rect2 = { position = { x = -12.0, y = -12.0 }, size = { x = World.width() + 24.0, y = World.height() + 24.0 } }

    def backdrops(w: World.World): List[Render.PlacedItem] =
        let now = Clock.nowOf(w#storyClock);
        let ground = { at = { x = -12.0, y = -12.0 },
                       item = RawDraw.box(backdropRect()#size, Backdrop.groundColor(), 0) };
        let layer = (shot: Stage.Shot, progress, z) -> specOf(shot, w)
            |> Option.map(spec -> Backdrop.surface(spec, backdropRect(), progress, z) :: Nil)
            |> Option.getWithDefault(Nil);
        let under = w#stage#under |> Option.map(shot -> layer(shot, 1.0, 1)) |> Option.getWithDefault(Nil);
        let top = w#stage#shot |> Option.map(shot -> layer(shot, Stage.fadeProgress(now, w#stage), 2)) |> Option.getWithDefault(Nil);
        ground :: List.append(under, top)

    def specOf(shot: Stage.Shot, w: World.World): Option[ShaderDoc.Spec] =
        forM (photo <- BackdropDoc.photoOf(shot#photo, w#backdrops);
              grade <- BackdropDoc.gradeOf(shot#grade, w#backdrops))
        yield Backdrop.specOf(photo, grade)

    // ── 粒の演出（蛍） ──

    /// 蛍: 番号と実時間だけから位置と明滅を導く（どこにも保存しない = 巻き戻しても同じ絵）。
    /// 草むらの高さ（画面の下 6 割）をゆっくり漂い、息をするように明滅する。
    def particles(w: World.World): List[Render.PlacedItem] =
        match w#stage#particles {
            case Some("fireflies") =>
                let color = theme(w)#firefly;
                Fx.derive(KindDoc.rec(w#kind)#fireflies, realSeconds(w), (_i, rand, t) -> {
                    let x = rand(0) * World.width() + Vec2.sin(t * (0.15 + rand(2) * 0.2) + rand(3) * 6.28) * 40.0;
                    let y = World.height() * (0.42 + rand(1) * 0.5) + Vec2.sin(t * (0.3 + rand(4) * 0.3) + rand(5) * 6.28) * 18.0;
                    let pulse = 0.5 + 0.5 * Vec2.sin(t * (1.2 + rand(6) * 1.6) + rand(7) * 6.28);
                    let a = pulse * pulse;
                    { x = x, y = y, a = a, r = 2.0 + rand(8) * 1.6 }
                }) |> List.flatMap(fly ->
                    if (fly#a < 0.05) Nil
                    else RawDraw.circleAt({ x = fly#x, y = fly#y }, fly#r * 0.5, Color.lighten(color, 0.5), 4)
                             |> Render.overItem(item -> item |> Render.fade(fly#a) |> Render.blended(DrawCmd.BlendMode.Add))
                         :: Render.glowAt({ x = fly#x, y = fly#y }, fly#r * 5.0, color,
                                          { alpha = 0.55 * fly#a, blend = DrawCmd.BlendMode.Add }, 3))
            case _ => Nil
        }

    // ── 本文（NVL の頁・ADV の窓） ──

    def textLayer(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#stage#mode {
            case Stage.Mode.Nvl => nvl(atlas, w)
            case Stage.Mode.Adv => adv(atlas, w)
        }

    /// 1 行を置く（字の下に 1px ずらした影を敷き、写真の明るい所でも字の縁が立つようにする）。
    def placeLine(atlas: FontAtlas, at: Vec2.Vec2, width: Float64, size: Float64, ink: Color, visible: Int32,
                  line: Page.Line, w: World.World): List[Render.PlacedItem] =
        let k = KindDoc.rec(w#kind);
        let place = (tint, pos, z) -> RichText.placeRuby(
            { atlas = atlas, size = size, baseTint = tint, z = z, pos = pos, maxWidth = width, lineGap = k#lineGap },
            k#rubySize * size / k#bodySize, line#rubies, visible, RichText.plain(line#text) :: Nil);
        List.append(place({ r = 0.0, g = 0.0, b = 0.0 }, { x = at#x + 1.0, y = at#y + 1.5 }, zText()) |> List.map(fadeTo(0.55)),
                    place(ink, at, zText() + 1))

    def fadeTo(alpha: Float64): Render.PlacedItem -> Render.PlacedItem = placed -> Render.overItem(item -> Render.fade(alpha, item), placed)

    def inkOf(line: Page.Line, w: World.World): Color =
        if (World.isCurrentSeen(w) and Option.exists(c -> c#source == line#source, w#page#current)) theme(w)#inkSeen else theme(w)#ink

    /// 1 行が頁に占める高さ（行の数 × (字 + 行の間)）。
    def lineHeight(w: World.World, width: Float64, line: Page.Line): Float64 =
        let k = KindDoc.rec(w#kind);
        Int32.toFloat64(Page.rowsOf(k#bodySize, k#rubySize, width, line)) * (k#bodySize + k#lineGap)

    /// NVL: 画面いっぱいに幕を敷き、頁に積んだ行と今の行を上から並べる（行の間に少し空きを入れて段落にする）。
    def nvl(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let k = KindDoc.rec(w#kind);
        let area = Layout.nvlText();
        let veil = { at = { x = 0.0, y = 0.0 },
                     item = RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zVeil()) |> Render.fade(t#veil) };
        let current = w#page#current |> Option.map(line -> (line, Page.visibleCount(w#page)) :: Nil) |> Option.getWithDefault(Nil);
        let rows = List.append(w#page#lines |> List.map(line -> (line, String.length(line#text))), current);
        let (items, endY) = rows |> List.foldLeft((acc, row) -> {
            let (done, y) = acc;
            let (line, visible) = row;
            let placed = placeLine(atlas, { x = area#x, y = y }, area#width, k#bodySize, inkOf(line, w), visible, line, w);
            (placed :: done, y + lineHeight(w, area#width, line) + 6.0)
        }, (Nil, area#y));
        veil :: List.append(List.flatten(List.reverse(items)), waitMark(atlas, { x = area#x + area#width - 10.0, y = endY - 4.0 }, w))

    /// ADV: 下の窓（上から下へ濃くなる地と、金の細い縁）に、名前と今の 1 行。
    def adv(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let k = KindDoc.rec(w#kind);
        let p = Layout.advPanel();
        let panel = { at = p#position,
                      item = Render.vgrad(p#size, { top = t#panel, bottom = Color.darken(t#panel, 0.3) }, zVeil()) |> Render.fade(t#panelAlpha) };
        let rim = { at = p#position, item = RawDraw.box({ x = p#size#x, y = 1.0 }, t#accent, zVeil() + 1) |> Render.fade(0.45) };
        let text = Layout.advText();
        match w#page#current {
            case None => panel :: rim :: Nil
            case Some(line) =>
                let name = if (String.isEmpty(line#speaker)) Nil
                    else { at = Layout.advName(), item = Render.textTinted(line#speaker, atlas, k#nameSize, t#name, zText() + 1) } :: Nil;
                let body = placeLine(atlas, { x = text#x, y = text#y }, text#width, k#bodySize, inkOf(line, w),
                                     Page.visibleCount(w#page), line, w);
                List.flatten((panel :: rim :: name) :: body ::
                    waitMark(atlas, { x = p#position#x + p#size#x - 30.0, y = p#position#y + p#size#y - 30.0 }, w) :: Nil)
        }

    /// 送りの印（行を出し終えて、送れる時だけ明滅する）。オートの間は点けたまま（押さなくても進むと分かる）。
    def waitMark(atlas: FontAtlas, at: Vec2.Vec2, w: World.World): List[Render.PlacedItem] =
        if (not Page.isDone(w#page) or World.isAsking(w) or Option.isEmpty(w#page#current)) Nil
        else {
            let alpha = if (w#playback == World.Playback.Auto) 0.9 else 0.35 + 0.55 * (0.5 + 0.5 * Vec2.sin(realSeconds(w) * 4.0));
            { at = at, item = Render.textTinted("▼", atlas, 14.0, theme(w)#accent, zText() + 2) |> Render.fade(alpha) } :: Nil
        }

    // ── 選択肢 ──

    def choices(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let count = List.length(w#choices);
        // NVL は字が画面いっぱいにあるので、選ぶ間は幕を 1 枚足して頁を沈める。
        let dim = if (count > 0 and w#stage#mode == Stage.Mode.Nvl)
            { at = { x = 0.0, y = 0.0 }, item = RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zChoice() - 1) |> Render.fade(0.7) } :: Nil
            else Nil;
        dim ::: (w#choices |> List.zipWithIndex |> List.flatMap(match (i, option) -> {
            let r = Layout.choice(i, count);
            let picked = i == w#cursor and option#available;
            let base = { at = r#position, item = RawDraw.box(r#size, Color.lighten(t#panel, if (picked) 0.0 else 0.1), zChoice()) |> Render.fade(0.96) };
            let edge = if (picked) frameOf(r, t#accent, zChoice() + 1) else Nil;
            let ink = if (not option#available) Color.mix(t#ink, t#panel, 0.6) else if (picked) t#accent else t#ink;
            let text = TextDraw.centered({ text = option#line#text, atlas = atlas, size = 20.0, color = ink, z = zChoice() + 2,
                                           centerX = r#position#x + r#size#x / 2.0, y = r#position#y + 12.0 });
            base :: text :: edge
        }))

    /// 矩形の 1px の縁。
    def frameOf(r: Rect2.Rect2, color: Color, z: Int32): List[Render.PlacedItem] =
        let x = r#position#x;
        let y = r#position#y;
        let w = r#size#x;
        let h = r#size#y;
           { at = { x = x, y = y }, item = RawDraw.box({ x = w, y = 1.0 }, color, z) }
        :: { at = { x = x, y = y + h - 1.0 }, item = RawDraw.box({ x = w, y = 1.0 }, color, z) }
        :: { at = { x = x, y = y }, item = RawDraw.box({ x = 1.0, y = h }, color, z) }
        :: { at = { x = x + w - 1.0, y = y }, item = RawDraw.box({ x = 1.0, y = h }, color, z) }
        :: Nil

    // ── 読んでいる間のボタン（下の帯） ──

    def buttons(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let all = World.buttons();
        let n = List.length(all);
        all |> List.zipWithIndex |> List.map(match (i, button) -> {
            let r = Layout.button(i, n);
            let lit = (button == World.Button.Auto and w#playback == World.Playback.Auto) or (button == World.Button.Skip and w#playback == World.Playback.Skip);
            TextDraw.centered({ text = label(buttonLabel(button), w), atlas = atlas, size = 14.0,
                                color = if (lit) t#accent else Color.mix(t#ink, t#panel, 0.25), z = zButtons(),
                                centerX = r#position#x + r#size#x / 2.0, y = r#position#y + 3.0 })
        })

    pub def buttonLabel(button: World.Button): StoryDoc.Label = match button {
        case World.Button.Log      => StoryDoc.Label.Log
        case World.Button.Auto     => StoryDoc.Label.Auto
        case World.Button.Skip     => StoryDoc.Label.Skip
        case World.Button.Save     => StoryDoc.Label.Save
        case World.Button.Load     => StoryDoc.Label.Load
        case World.Button.Settings => StoryDoc.Label.Settings
        case World.Button.Hide     => StoryDoc.Label.Hide
        case World.Button.ToTitle  => StoryDoc.Label.ToTitle
    }

    // ── 表紙 ──

    def title(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let s = StoryDoc.rec(w#story);
        let center = World.width() / 2.0;
        let shade = { at = { x = 0.0, y = 0.0 },
                      item = Render.vgrad({ x = World.width(), y = World.height() },
                                          { top = t#panel, bottom = Color.darken(t#panel, 0.4) }, zVeil()) |> Render.fade(0.35) };
        let heading = TextDraw.centered({ text = s#title, atlas = atlas, size = 64.0, color = t#ink, z = zText(), centerX = center, y = 140.0 });
        let sub = TextDraw.centered({ text = s#subtitle, atlas = atlas, size = 18.0, color = t#inkSeen, z = zText(), centerX = center, y = 232.0 });
        let items = World.titleItems() |> List.zipWithIndex |> List.map(match (i, item) -> {
            let r = Layout.titleItem(i);
            let off = item == World.TitleItem.Continue and not Saves.hasAny(w#saves);
            let color = if (off) Color.mix(t#ink, t#panel, 0.6) else if (i == w#cursor) t#accent else t#ink;
            TextDraw.centered({ text = label(titleLabel(item), w), atlas = atlas, size = 22.0, color = color, z = zText(),
                                centerX = center, y = r#position#y + 4.0 })
        });
        let marker = Layout.titleItem(w#cursor) |> (r -> { at = { x = r#position#x + 40.0, y = r#position#y + r#size#y - 4.0 },
            item = RawDraw.box({ x = r#size#x - 80.0, y = 1.0 }, t#accent, zText()) |> Render.fade(0.6) });
        let hint = TextDraw.centered({ text = s#hint, atlas = atlas, size = 13.0, color = Color.mix(t#ink, t#panel, 0.4), z = zText(),
                                       centerX = center, y = 512.0 });
        shade :: heading :: sub :: marker :: hint :: items

    pub def titleLabel(item: World.TitleItem): StoryDoc.Label = match item {
        case World.TitleItem.NewGame  => StoryDoc.Label.NewGame
        case World.TitleItem.Continue => StoryDoc.Label.Continue
        case World.TitleItem.Settings => StoryDoc.Label.Settings
        case World.TitleItem.Credits  => StoryDoc.Label.Credits
        case World.TitleItem.Quit     => StoryDoc.Label.Quit
    }

    // ── クレジット（実時間で下から上へ流れる） ──

    def credits(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let scrolled = Clock.since(w#creditsFrom, w#realNow) * KindDoc.rec(w#kind)#creditsSpeed;
        let veil = { at = { x = 0.0, y = 0.0 },
                     item = RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zVeil()) |> Render.fade(0.7) };
        let (items, _) = CreditsDoc.rec(w#credits)#rows |> List.foldLeft((acc, row) -> {
            let (done, y) = acc;
            let (size, color) = match row#style {
                case CreditsDoc.Style.Heading => (26.0, t#accent)
                case CreditsDoc.Style.Body    => (19.0, t#ink)
                case CreditsDoc.Style.Small   => (13.0, t#inkSeen)
                case CreditsDoc.Style.Gap     => (0.0, t#ink)
            };
            let visible = y > -60.0 and y < World.height() + 10.0 and size > 0.0;
            let placed = if (visible)
                TextDraw.centered({ text = row#text, atlas = atlas, size = size, color = color, z = zText(),
                                    centerX = World.width() / 2.0, y = y }) :: done
                else done;
            (placed, y + World.creditsRowHeight(row#style))
        }, (Nil, World.height() - scrolled));
        veil :: items

    // ── 窓（ログ・栞・設定・隠す） ──

    def panel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#panel {
            case World.Panel.Closed    => Nil
            case World.Panel.Hidden    => Nil
            case World.Panel.Log       => logPanel(atlas, w)
            case World.Panel.SaveSlots => slotsPanel(atlas, StoryDoc.Label.SaveTitle, w)
            case World.Panel.LoadSlots => slotsPanel(atlas, StoryDoc.Label.LoadTitle, w)
            case World.Panel.Settings  => settingsPanel(atlas, w)
        }

    /// 窓の地と見出しと「戻る」。
    def panelFrame(atlas: FontAtlas, heading: String, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let back = Layout.back();
        { at = { x = 0.0, y = 0.0 },
          item = RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zPanel()) |> Render.fade(0.86) }
        :: TextDraw.centered({ text = heading, atlas = atlas, size = 24.0, color = t#accent, z = zPanelText(),
                               centerX = World.width() / 2.0, y = 40.0 })
        :: TextDraw.centered({ text = label(StoryDoc.Label.Back, w), atlas = atlas, size = 18.0, color = t#ink, z = zPanelText(),
                               centerX = back#position#x + back#size#x / 2.0, y = back#position#y + 8.0 })
        :: frameOf(back, Color.mix(t#ink, t#panel, 0.5), zPanelText())

    /// ログの 1 行の高さ（字の大きさはログ用に本文より小さく）。
    pub def logRowHeight(w: World.World): Float64 =
        let k = KindDoc.rec(w#kind);
        logSize(w) + k#lineGap * logSize(w) / k#bodySize

    def logSize(w: World.World): Float64 = KindDoc.rec(w#kind)#bodySize * 0.82

    /// ログの 1 項目の高さ（名前の行 + 本文の行 + 項目の間）。
    def logEntryHeight(w: World.World, line: Page.Line): Float64 =
        let k = KindDoc.rec(w#kind);
        let rows = Page.rowsOf(logSize(w), k#rubySize * logSize(w) / k#bodySize, Layout.logView()#size#x, line);
        Int32.toFloat64(rows) * logRowHeight(w) + 10.0

    /// ログを遡れる上限（全部の項目の高さ − 読む範囲の高さ）。
    pub def logMaxOffset(w: World.World): Float64 =
        let total = w#log |> List.foldLeft((sum, line) -> sum + logEntryHeight(w, line), 0.0);
        Float64.max(0.0, total - Layout.logView()#size#y)

    /// ログ: 新しい行を下に、遡るほど上の行が見える（offset 0 = 一番新しい所）。読む範囲の外は切り抜く。
    def logPanel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let k = KindDoc.rec(w#kind);
        let view = Layout.logView();
        let size = logSize(w);
        let bottom = view#position#y + view#size#y + w#logOffset;
        let (items, _) = w#log |> List.foldLeft((acc, line) -> {
            let (done, below) = acc;
            let h = logEntryHeight(w, line);
            let top = below - h;
            let visible = below > view#position#y and top < view#position#y + view#size#y;
            let color = if (String.isEmpty(line#source)) t#accent else t#ink;
            let placed = if (not visible) Nil
                else RichText.placeRuby({ atlas = atlas, size = size, baseTint = color, z = zPanelText(),
                                          pos = { x = view#position#x, y = top + logRowHeight(w) - size },
                                          maxWidth = view#size#x, lineGap = logRowHeight(w) - size },
                                        k#rubySize * size / k#bodySize, line#rubies, String.length(line#text),
                                        RichText.plain(line#text) :: Nil);
            (List.append(placed, done), top)
        }, (Nil, bottom));
        List.append(panelFrame(atlas, label(StoryDoc.Label.LogTitle, w), w), Render.clippedAll(view, items))

    /// 栞の枠 6 つ（場所の名前と、挟んだ所の台詞の頭）。
    def slotsPanel(atlas: FontAtlas, heading: StoryDoc.Label, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let slots = List.range(0, Saves.slotCount()) |> List.flatMap(i -> {
            let r = Layout.slot(i);
            let picked = i == w#cursor;
            let box = { at = r#position, item = RawDraw.box(r#size, Color.lighten(t#panel, 0.06), zPanelText()) };
            let edge = frameOf(r, if (picked) t#accent else Color.mix(t#ink, t#panel, 0.7), zPanelText() + 1);
            let number = { at = { x = r#position#x + 14.0, y = r#position#y + 10.0 },
                           item = Render.textTinted("${label(StoryDoc.Label.Save, w)} ${Int32.toString(i + 1)}", atlas, 15.0,
                                                    if (picked) t#accent else t#inkSeen, zPanelText() + 1) };
            let body = match Map.get(i, w#saves#slots) {
                case Some(slot) =>
                    { at = { x = r#position#x + 14.0, y = r#position#y + 38.0 },
                      item = Render.textTinted(slot#place, atlas, 17.0, t#ink, zPanelText() + 1) } ::
                    { at = { x = r#position#x + 14.0, y = r#position#y + 66.0 },
                      item = Render.textTinted(clipTo(r#size#x - 28.0, 14.0, atlas, slot#excerpt), atlas, 14.0, t#inkSeen, zPanelText() + 1) } :: Nil
                case None =>
                    { at = { x = r#position#x + 14.0, y = r#position#y + 52.0 },
                      item = Render.textTinted(label(StoryDoc.Label.EmptySlot, w), atlas, 15.0, Color.mix(t#ink, t#panel, 0.5), zPanelText() + 1) } :: Nil
            };
            List.flatten((box :: number :: body) :: edge :: Nil)
        });
        List.append(panelFrame(atlas, label(heading, w), w), slots)

    /// 幅 maxWidth に収まるよう末尾を「…」で切る。
    def clipTo(maxWidth: Float64, size: Float64, atlas: FontAtlas, text: String): String =
        if (TextDraw.width(text, atlas, size) <= maxWidth) text
        else {
            let room = maxWidth - TextDraw.width("…", atlas, size);
            def go(n: Int32): String = {
                let head = String.takeLeft(n, text);
                if (n <= 0 or TextDraw.width(head, atlas, size) <= room) "${head}…" else go(n - 1)
            };
            go(String.length(text) - 1)
        }

    /// 設定: 行の名前・つまみの帯・値。
    def settingsPanel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let rows = World.settings() |> List.zipWithIndex |> List.flatMap(match (i, setting) -> {
            let row = Layout.settingRow(i);
            let bar = Layout.settingBar(i);
            let (lo, hi, _) = World.rangeOf(setting);
            let v = World.valueOf(setting, w);
            let filled = if (hi > lo) (v - lo) / (hi - lo) else 0.0;
            let picked = i == w#cursor;
            let name = { at = { x = row#position#x, y = row#position#y + 12.0 },
                         item = Render.textTinted(label(settingLabel(setting), w), atlas, 18.0, if (picked) t#accent else t#ink, zPanelText()) };
            let track = { at = bar#position, item = RawDraw.box(bar#size, Color.lighten(t#panel, 0.15), zPanelText()) };
            let fill = { at = bar#position, item = RawDraw.box({ x = bar#size#x * filled, y = bar#size#y }, t#accent, zPanelText() + 1) };
            let value = { at = { x = bar#position#x + bar#size#x + 18.0, y = row#position#y + 14.0 },
                          item = Render.textTinted(valueText(setting, v), atlas, 15.0, t#inkSeen, zPanelText()) };
            name :: track :: fill :: value :: Nil
        });
        List.append(panelFrame(atlas, label(StoryDoc.Label.Settings, w), w), rows)

    pub def settingLabel(setting: World.Setting): StoryDoc.Label = match setting {
        case World.Setting.TextSpeed      => StoryDoc.Label.TextSpeed
        case World.Setting.AutoWait       => StoryDoc.Label.AutoWait
        case World.Setting.AmbienceVolume => StoryDoc.Label.AmbienceVolume
        case World.Setting.SeVolume       => StoryDoc.Label.SeVolume
    }

    def valueText(setting: World.Setting, v: Float64): String =
        let whole = x -> Float64.tryToInt32(Float64.round(x)) |> Option.getWithDefault(0) |> Int32.toString;
        match setting {
            case World.Setting.TextSpeed => "${whole(v)} 字/秒"
            case World.Setting.AutoWait  => "${Float64.toString(Float64.round(v * 10.0) / 10.0)} 秒"
            case _                       => "${whole(v * 100.0)}%"
        }

    // ── 知らせ ──

    def toast(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match World.toastOf(w) {
            case Some(text) =>
                { at = { x = World.width() - 40.0 - TextDraw.width(text, atlas, 15.0), y = 18.0 },
                  item = Render.textTinted(text, atlas, 15.0, theme(w)#accent, zToast()) } :: Nil
            case None => Nil
        }
}
