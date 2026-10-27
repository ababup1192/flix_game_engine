// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「夏の田舎の、記憶の中の写真」。背景は実写をぼかして時間帯の色に染め（Backdrop）、その上に明朝の字を置く。
//   主役は文章。写真はぼかして奥へ下げ、字の下には必ず暗い地（ADV の窓・NVL の幕・画面の幕）を敷いて読ませる。
//   色は 3 つ: 写真の時間帯の色 / 紙のような白い字 / 夕陽の金（選んでいる物・名前）。
//   やらないこと: 写真をぼかさずに出さない（字と喧嘩する）。字を写真の上に地無しで置かない。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「写真を奥へ下げて文章を主役にする」層の分け方。
//
// ── 画面の層（奥から手前へ）──
//   world: 前の背景（重ねている間だけ）→ 今の背景（進みで現れる）→ 粒の演出（蛍）        … 揺れはこの層だけに掛かる
//   hud:   NVL の幕 / ADV の窓 → 本文（ルビつき）・名前 → 送りの印 → 選択肢 → クイックメニュー
//          → 画面（バックログ・セーブ・ロード・設定。セーブの枠のサムネは背景と同じ式で小さく塗る）→ 確認の窓 → 知らせ
//          タイトルとクレジットも hud（写真の上に字だけを置く画面）
//
// ── 時計 ── 背景の重ね・揺れは物語の時計（画面を開くと止まる）、蛍・送りの印の明滅・クレジット・設定の見本は実時間（w#realNow）。
// ── 触れている物 ── マウスの位置 w#pointer に乗っている物（ボタン・枠・行）を明るくする。押せる所は Layout の同じ矩形。
mod View {
    use fge::{App, Clock, Color, DrawCmd, FontAtlas, Fx, RawDraw, Rect2, Render, RichText, ShaderDoc, TextDraw, UiScroll, Vec2}

    // ── hud の中の z（小さいほど奥） ──
    def zVeil(): Int32 = 10
    def zText(): Int32 = 20
    def zChoice(): Int32 = 30
    def zButtons(): Int32 = 40
    def zPanel(): Int32 = 50
    def zCard(): Int32 = 52
    def zThumb(): Int32 = 54
    def zPanelText(): Int32 = 56
    def zAsk(): Int32 = 70
    def zToast(): Int32 = 90

    pub def frame(_ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let now = Clock.nowOf(w#storyClock);
        let k = KindDoc.rec(w#kind);
        let (dx, dy) = Stage.shakeOffset(now, k#shakeSeconds, k#shakePx, w#stage);
        List.append(backdrops(w), particles(w))
            |> List.map(placed -> { at = { x = placed#at#x + dx, y = placed#at#y + dy } | placed })

    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let atlas = ctx#atlas;
        // 画面（バックログ・セーブ・設定）の間は下の画面を描かない（幕越しに字が二重に透けて読みにくい）。背景の写真は frame が描き続ける。
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
                else List.flatten(textLayer(atlas, w) :: choices(atlas, w) :: quickMenu(atlas, w) :: Nil)
        };
        List.flatten(screen :: panel(atlas, w) :: askLayer(atlas, w) :: toast(atlas, w) :: Nil)

    def realSeconds(w: World.World): Float64 = Clock.secondsOf(w#realNow)

    def theme(w: World.World): ThemeDoc.Rec = ThemeDoc.rec(w#theme)

    def label(l: StoryDoc.Label, w: World.World): String = StoryDoc.labelOf(l, w#story)

    def isOver(r: Rect2.Rect2, w: World.World): Bool = Layout.contains(r, w#pointer)

    /// 字の薄い色（選べない物・空き）。
    def dim(w: World.World): Color = Color.mix(theme(w)#ink, theme(w)#panel, 0.55)

    def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem = { at = { x = x, y = y }, item = item }

    def textAt(x: Float64, y: Float64, text: String, atlas: FontAtlas, size: Float64, color: Color, z: Int32): Render.PlacedItem =
        at(x, y, Render.textTinted(text, atlas, size, color, z))

    /// 右端を right に合わせた字。
    def textRight(right: Float64, y: Float64, text: String, atlas: FontAtlas, size: Float64, color: Color, z: Int32): Render.PlacedItem =
        textAt(right - TextDraw.width(text, atlas, size), y, text, atlas, size, color, z)

    /// 矩形の真ん中に置いた 1 行。
    def textIn(r: Rect2.Rect2, text: String, atlas: FontAtlas, size: Float64, color: Color, z: Int32): Render.PlacedItem =
        TextDraw.centered({ text = text, atlas = atlas, size = size, color = color, z = z,
                            centerX = r#position#x + r#size#x / 2.0, y = r#position#y + (r#size#y - size) / 2.0 - 1.0 })

    /// 平らなボタンの地と縁（lit = 選んでいる・触れている）。
    def plate(r: Rect2.Rect2, lit: Bool, w: World.World, z: Int32): Render.PlacedItem =
        let t = theme(w);
        let fill = if (lit) Color.mix(t#panel, t#accent, 0.16) else Color.lighten(t#panel, 0.06);
        at(r#position#x, r#position#y,
           RawDraw.box(r#size, fill, z) |> Render.fade(0.92)
               |> Render.outlineA({ color = if (lit) t#accent else Color.mix(t#ink, t#panel, 0.7), alpha = if (lit) 0.9 else 0.6, width = 1.0 })
               |> Render.rounded(3.0))

    // ── 背景（写真をぼかして時間帯の色に） ──

    /// 揺れても画面の端が覗かないよう、背景は画面より一回り大きく敷く。
    def backdropRect(): Rect2.Rect2 = { position = { x = -12.0, y = -12.0 }, size = { x = World.width() + 24.0, y = World.height() + 24.0 } }

    def backdrops(w: World.World): List[Render.PlacedItem] =
        let now = Clock.nowOf(w#storyClock);
        let ground = at(-12.0, -12.0, RawDraw.box(backdropRect()#size, Backdrop.groundColor(), 0));
        let layer = (shot: Stage.Shot, progress, z) -> specOf(shot, w)
            |> Option.map(spec -> Backdrop.surface(spec, backdropRect(), progress, z) :: Nil)
            |> Option.getWithDefault(Nil);
        let under = w#stage#under |> Option.map(shot -> layer(shot, 1.0, 1)) |> Option.getWithDefault(Nil);
        let top = w#stage#shot |> Option.map(shot -> layer(shot, Stage.fadeProgress(now, w#stage), 2)) |> Option.getWithDefault(Nil);
        ground :: List.append(under, top)

    def specOf(shot: Stage.Shot, w: World.World): Option[ShaderDoc.Spec] =
        forM (photo <- BackdropDoc.photoOf(shot#photo, w#backdrops);
              grade <- BackdropDoc.gradeOf(shot#grade, w#backdrops))
        yield Backdrop.specOf("${shot#photo}_${shot#grade}", photo, grade)

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

    /// 文章の窓の濃さ（設定の「ウィンドウの濃さ」）。NVL の幕はこれに theme の veil を掛ける。
    def windowAlpha(w: World.World): Float64 = Saves.configOf(w#saves)#windowAlpha

    /// 1 行を置く（字の下に 1px ずらした影を敷き、写真の明るい所でも字の縁が立つようにする）。
    def placeLine(atlas: FontAtlas, pos: Vec2.Vec2, width: Float64, size: Float64, ink: Color, visible: Int32,
                  line: Page.Line, w: World.World): List[Render.PlacedItem] =
        let k = KindDoc.rec(w#kind);
        let place = (tint, p, z) -> RichText.placeRuby(
            { atlas = atlas, size = size, baseTint = tint, z = z, pos = p, maxWidth = width, lineGap = k#lineGap * size / k#bodySize },
            k#rubySize * size / k#bodySize, line#rubies, visible, RichText.plain(line#text) :: Nil);
        List.append(place({ r = 0.0, g = 0.0, b = 0.0 }, { x = pos#x + 1.0, y = pos#y + 1.5 }, zText()) |> List.map(fadeTo(0.55)),
                    place(ink, pos, zText() + 1))

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
        let veil = at(0.0, 0.0, RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zVeil())
                                    |> Render.fade(Float64.min(0.95, windowAlpha(w) * t#veil)));
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
                      item = Render.vgrad(p#size, { top = t#panel, bottom = Color.darken(t#panel, 0.3) }, zVeil()) |> Render.fade(windowAlpha(w)) };
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
    def waitMark(atlas: FontAtlas, pos: Vec2.Vec2, w: World.World): List[Render.PlacedItem] =
        if (not Page.isDone(w#page) or World.isAsking(w) or Option.isEmpty(w#page#current)) Nil
        else {
            let alpha = if (w#playback == World.Playback.Auto) 0.9 else 0.35 + 0.55 * (0.5 + 0.5 * Vec2.sin(realSeconds(w) * 4.0));
            { at = pos, item = Render.textTinted("▼", atlas, 14.0, theme(w)#accent, zText() + 2) |> Render.fade(alpha) } :: Nil
        }

    // ── 選択肢 ──

    def choices(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let count = List.length(w#choices);
        // NVL は字が画面いっぱいにあるので、選ぶ間は幕を 1 枚足して頁を沈める。
        let sink = if (count > 0 and w#stage#mode == Stage.Mode.Nvl)
            at(0.0, 0.0, RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zChoice() - 1) |> Render.fade(0.7)) :: Nil
            else Nil;
        sink ::: (w#choices |> List.zipWithIndex |> List.flatMap(match (i, option) -> {
            let r = Layout.choice(i, count);
            let picked = i == w#cursor and option#available;
            let ink = if (not option#available) dim(w) else if (picked) t#accent else t#ink;
            plate(r, picked, w, zChoice()) :: textIn(r, option#line#text, atlas, 20.0, ink, zChoice() + 2) :: Nil
        }))

    // ── クイックメニュー（下の帯） ──

    def quickMenu(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let all = World.buttons();
        let n = List.length(all);
        let first = Layout.button(0, n);
        // ADV の窓の下は写真の上なので、帯に薄い地を敷いてから字を置く。
        let strip = at(0.0, first#position#y - 4.0,
                       Render.vgrad({ x = World.width(), y = World.height() - first#position#y + 4.0 },
                                    { top = t#panel, bottom = Color.darken(t#panel, 0.4) }, zButtons() - 1) |> Render.fade(0.55 * windowAlpha(w)));
        strip :: (all |> List.zipWithIndex |> List.map(match (i, button) -> {
            let r = Layout.button(i, n);
            let lit = (button == World.Button.Auto and w#playback == World.Playback.Auto) or (button == World.Button.Skip and w#playback == World.Playback.Skip);
            let open = isButtonOpen(button, w);
            let color = if (not open) Color.mix(t#ink, t#panel, 0.7)
                        else if (lit) t#accent
                        else if (isOver(r, w)) t#ink
                        else Color.mix(t#ink, t#panel, 0.3);
            textIn(r, label(buttonLabel(button), w), atlas, 13.0, color, zButtons())
        }))

    /// 押して何か起きるボタンか（戻れない時の「戻る」・クイックセーブが無い時の「Qロード」は薄く出す）。
    def isButtonOpen(button: World.Button, w: World.World): Bool = match button {
        case World.Button.Rollback  => w#log |> List.zipWithIndex |> List.exists(match (i, entry) -> i >= 1 and World.isJumpable(entry))
        case World.Button.QuickLoad => Option.nonEmpty(Saves.slotOf(Saves.Tab.Quick, 0, w#saves))
        case _                      => true
    }

    pub def buttonLabel(button: World.Button): StoryDoc.Label = match button {
        case World.Button.Rollback  => StoryDoc.Label.Rollback
        case World.Button.Log       => StoryDoc.Label.Log
        case World.Button.Auto      => StoryDoc.Label.Auto
        case World.Button.Skip      => StoryDoc.Label.Skip
        case World.Button.QuickSave => StoryDoc.Label.QuickSave
        case World.Button.QuickLoad => StoryDoc.Label.QuickLoad
        case World.Button.Save      => StoryDoc.Label.Save
        case World.Button.Load      => StoryDoc.Label.Load
        case World.Button.Settings  => StoryDoc.Label.Config
        case World.Button.Hide      => StoryDoc.Label.Hide
        case World.Button.ToTitle   => StoryDoc.Label.ToTitle
    }

    // ── タイトル ──

    def title(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let s = StoryDoc.rec(w#story);
        let center = World.width() / 2.0;
        let shade = at(0.0, 0.0, Render.vgrad({ x = World.width(), y = World.height() },
                                              { top = t#panel, bottom = Color.darken(t#panel, 0.4) }, zVeil()) |> Render.fade(0.35));
        let heading = TextDraw.centered({ text = s#title, atlas = atlas, size = 64.0, color = t#ink, z = zText(), centerX = center, y = 130.0 });
        let sub = TextDraw.centered({ text = s#subtitle, atlas = atlas, size = 18.0, color = t#inkSeen, z = zText(), centerX = center, y = 222.0 });
        let items = World.titleItems() |> List.zipWithIndex |> List.map(match (i, item) -> {
            let r = Layout.titleItem(i);
            let color = if (not World.isTitleItemOpen(item, w)) dim(w) else if (i == w#cursor) t#accent else t#ink;
            textIn(r, label(titleLabel(item), w), atlas, 21.0, color, zText())
        });
        let marker = Layout.titleItem(w#cursor) |> (r -> at(r#position#x + 50.0, r#position#y + r#size#y - 3.0,
            RawDraw.box({ x = r#size#x - 100.0, y = 1.0 }, t#accent, zText()) |> Render.fade(0.6)));
        let hint = TextDraw.centered({ text = s#hint, atlas = atlas, size = 13.0, color = Color.mix(t#ink, t#panel, 0.4), z = zText(),
                                       centerX = center, y = 512.0 });
        shade :: heading :: sub :: marker :: hint :: items

    pub def titleLabel(item: World.TitleItem): StoryDoc.Label = match item {
        case World.TitleItem.NewGame  => StoryDoc.Label.NewGame
        case World.TitleItem.Continue => StoryDoc.Label.Continue
        case World.TitleItem.LoadGame => StoryDoc.Label.LoadGame
        case World.TitleItem.Settings => StoryDoc.Label.Settings
        case World.TitleItem.Credits  => StoryDoc.Label.Credits
        case World.TitleItem.Quit     => StoryDoc.Label.Quit
    }

    // ── クレジット（実時間で下から上へ流れる） ──

    def credits(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let scrolled = Clock.since(w#creditsFrom, w#realNow) * KindDoc.rec(w#kind)#creditsSpeed;
        let veil = at(0.0, 0.0, RawDraw.box({ x = World.width(), y = World.height() }, t#panel, zVeil()) |> Render.fade(0.7));
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

    // ── 画面（バックログ・セーブ・ロード・設定・隠す） ──

    def panel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#panel {
            case World.Panel.Closed    => Nil
            case World.Panel.Hidden    => Nil
            case World.Panel.Log       => logPanel(atlas, w)
            case World.Panel.SaveSlots => slotsPanel(atlas, StoryDoc.Label.SaveTitle, w)
            case World.Panel.LoadSlots => slotsPanel(atlas, StoryDoc.Label.LoadTitle, w)
            case World.Panel.Settings  => settingsPanel(atlas, w)
        }

    /// 画面の地・左上の見出しと下の線・右上の「戻る」・下の案内（空なら出さない）。
    def panelFrame(atlas: FontAtlas, heading: String, hint: String, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let back = Layout.back();
        let h = Layout.heading();
        let ground = at(0.0, 0.0, Render.vgrad({ x = World.width(), y = World.height() },
                                               { top = Color.darken(t#panel, 0.1), bottom = t#panel }, zPanel()) |> Render.fade(0.9));
        let rule = at(h#x, Layout.rule(), RawDraw.box({ x = World.width() - 2.0 * h#x, y = 1.0 }, t#accent, zPanelText()) |> Render.fade(0.35));
        let hintRow = if (String.isEmpty(hint)) Nil
            else textAt(h#x, Layout.hintY() + 6.0, hint, atlas, 12.0, Color.mix(t#ink, t#panel, 0.45), zPanelText()) :: Nil;
        ground :: rule :: textAt(h#x, h#y, heading, atlas, 28.0, t#accent, zPanelText())
            :: plate(back, isOver(back, w), w, zPanelText())
            :: textIn(back, label(StoryDoc.Label.Back, w), atlas, 15.0, if (isOver(back, w)) t#accent else t#ink, zPanelText() + 1)
            :: hintRow

    // ── バックログ ──

    /// バックログの 1 行の高さ（字の大きさはバックログ用に本文より小さく）。
    pub def logRowHeight(w: World.World): Float64 =
        let k = KindDoc.rec(w#kind);
        logSize(w) + k#lineGap * logSize(w) / k#bodySize

    def logSize(w: World.World): Float64 = KindDoc.rec(w#kind)#bodySize * 0.8

    /// 項目の本文（選択肢は選んだ字そのまま）。
    def entryText(entry: World.Entry): String = match entry {
        case World.Entry.Said(line, _) => line#text
        case World.Entry.Chose(text)   => text
    }

    def entryLine(entry: World.Entry): Page.Line = match entry {
        case World.Entry.Said(line, _) => line
        case World.Entry.Chose(text)   => { speaker = "", text = text, rubies = Nil, source = "" }
    }

    /// 1 項目の高さ（本文の行の数 + 項目の間）。
    def logEntryHeight(w: World.World, entry: World.Entry): Float64 =
        let k = KindDoc.rec(w#kind);
        let rows = Page.rowsOf(logSize(w), k#rubySize * logSize(w) / k#bodySize, Layout.logText()#width, entryLine(entry));
        Int32.toFloat64(rows) * logRowHeight(w) + 14.0

    /// 項目ごとの (番号, 項目, 上端, 高さ)。新しい項目を下に、遡るほど上（offset 0 = 一番新しい所が一番下に見える）。
    def logPlaced(w: World.World): List[(Int32, World.Entry, Float64, Float64)] =
        let view = Layout.logView();
        let bottom = view#position#y + view#size#y + w#logOffset;
        let (rows, _) = w#log |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (done, below) = acc;
            let (i, entry) = pair;
            let h = logEntryHeight(w, entry);
            ((i, entry, below - h, h) :: done, below - h)
        }, (Nil, bottom));
        rows

    /// バックログの長さと読む範囲の高さ（UiScroll の勘定へ）。
    pub def logScrollSize(w: World.World): { contentPx = Float64, viewportPx = Float64 } =
        { contentPx = w#log |> List.foldLeft((sum, entry) -> sum + logEntryHeight(w, entry), 0.0),
          viewportPx = Layout.logView()#size#y }

    /// p の下にある項目の番号（読む範囲の外・戻れない項目は None）。
    pub def logEntryAt(p: { x = Float64, y = Float64 }, w: World.World): Option[Int32] =
        if (not Layout.contains(Layout.logView(), p)) None
        else logPlaced(w) |> List.find(match (_, entry, top, h) -> p#y >= top and p#y < top + h and World.isJumpable(entry))
                          |> Option.map(match (i, _, _, _) -> i)

    /// バックログ: 左の列に話し手の名前、右の列に本文。選んだ選択肢は金の字と左の印。戻れる行に触れると明るくなる。
    def logPanel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let k = KindDoc.rec(w#kind);
        let view = Layout.logView();
        let text = Layout.logText();
        let size = logSize(w);
        let hovered = logEntryAt(w#pointer, w);
        // 上の端で切れる項目は出さない（字の頭だけが線のように残る）。下の端は一番新しい項目が必ず収まる。
        let items = logPlaced(w) |> List.filter(match (_, _, top, _) -> top >= view#position#y - 1.0 and top < view#position#y + view#size#y)
            |> List.flatMap(match (i, entry, top, h) -> {
                let lit = hovered == Some(i) and i > 0;
                let glow = if (lit) at(view#position#x, top + 2.0,
                                       RawDraw.box({ x = view#size#x, y = h - 6.0 }, Color.lighten(t#panel, 0.12), zCard()) |> Render.fade(0.7) |> Render.rounded(3.0)) :: Nil
                           else Nil;
                let baseY = top + 6.0;
                let (name, ink) = match entry {
                    case World.Entry.Said(line, _) =>
                        let n = if (String.isEmpty(line#speaker)) Nil else textRight(Layout.logNameRight(), baseY + logRowHeight(w) - size, line#speaker, atlas, size * 0.9, t#name, zPanelText()) :: Nil;
                        (n, if (lit) Color.lighten(t#ink, 0.1) else t#ink)
                    case World.Entry.Chose(_) =>
                        (at(text#x - 12.0, baseY + 4.0, RawDraw.box({ x = 2.0, y = h - 22.0 }, t#accent, zPanelText())) :: Nil, t#accent)
                };
                let body = RichText.placeRuby({ atlas = atlas, size = size, baseTint = ink, z = zPanelText(),
                                                pos = { x = text#x, y = baseY + logRowHeight(w) - size },
                                                maxWidth = text#width, lineGap = logRowHeight(w) - size },
                                              k#rubySize * size / k#bodySize, entryLine(entry)#rubies, String.length(entryText(entry)),
                                              RichText.plain(entryText(entry)) :: Nil);
                List.flatten(glow :: name :: body :: Nil)
            });
        List.flatten(panelFrame(atlas, label(StoryDoc.Label.LogTitle, w), label(StoryDoc.Label.LogHint, w), w)
                     :: Render.clippedAll(view, items) :: scrollbar(w) :: Nil)

    /// スクロールバー（中身が読む範囲より長い時だけ）。つまみの長さは見えている割合、位置は遡った量。
    def scrollbar(w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let track = Layout.logTrack();
        let size = logScrollSize(w);
        if (size#contentPx <= size#viewportPx) Nil
        else {
            let h = Float64.max(28.0, track#size#y * size#viewportPx / size#contentPx);
            let top = UiScroll.topPx(size, w#logOffset) / UiScroll.maxOffsetPx(size);
            let y = track#position#y + (track#size#y - h) * top;
            at(track#position#x, track#position#y, RawDraw.box(track#size, Color.lighten(t#panel, 0.12), zPanelText()) |> Render.rounded(2.0))
            :: at(track#position#x, y, RawDraw.box({ x = track#size#x, y = h }, t#accent, zPanelText() + 1) |> Render.fade(0.8) |> Render.rounded(2.0))
            :: Nil
        }

    // ── セーブ・ロード ──

    def tabLabel(tab: Saves.Tab, w: World.World): String = match tab {
        case Saves.Tab.Auto        => label(StoryDoc.Label.TabAuto, w)
        case Saves.Tab.Quick       => label(StoryDoc.Label.TabQuick, w)
        case Saves.Tab.Numbered(n) => Int32.toString(n)
    }

    /// 枠の番号の字（ページ 1〜3 は通しの No.、オートとクイックはページの名前と順）。
    def slotNumber(tab: Saves.Tab, i: Int32, w: World.World): String = match tab {
        case Saves.Tab.Numbered(n) =>
            let no = (n - 1) * Saves.perPage() + i + 1;
            if (no < 10) "No.0${no}" else "No.${no}"
        case _ => "${tabLabel(tab, w)} ${i + 1}"
    }

    /// セーブ・ロードの画面: 上にページのタブ、2 列 × 3 行の枠。枠はサムネ・番号・保存した日時・場所・台詞の頭。
    def slotsPanel(atlas: FontAtlas, heading: StoryDoc.Label, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let tabs = World.tabsOf(w) |> List.zipWithIndex |> List.flatMap(match (j, tab) -> {
            let r = Layout.tab(j);
            let on = tab == w#slotTab;
            let lit = on or isOver(r, w);
            let bar = if (on) at(r#position#x, r#position#y + r#size#y - 2.0, RawDraw.box({ x = r#size#x, y = 2.0 }, t#accent, zPanelText() + 1)) :: Nil else Nil;
            plate(r, lit, w, zPanelText()) :: textIn(r, tabLabel(tab, w), atlas, 15.0, if (on) t#accent else if (lit) t#ink else t#inkSeen, zPanelText() + 1) :: bar
        });
        let newest = Saves.latest(w#saves);
        let cards = List.range(0, Saves.perPage()) |> List.flatMap(i -> slotCard(atlas, i, newest, w));
        List.flatten(panelFrame(atlas, label(heading, w), label(StoryDoc.Label.SlotsHint, w), w) :: tabs :: cards :: Nil)

    def slotCard(atlas: FontAtlas, i: Int32, newest: Option[(Saves.Tab, Int32)], w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let r = Layout.slot(i);
        let lit = i == w#cursor or isOver(r, w);
        let thumb = Layout.thumb(i);
        let tx = thumb#position#x + thumb#size#x + 14.0;
        let textWidth = r#position#x + r#size#x - 12.0 - tx;
        let y = r#position#y;
        let number = textAt(tx, y + 10.0, slotNumber(w#slotTab, i, w), atlas, 13.0, if (lit) t#accent else t#inkSeen, zPanelText());
        let card = plate(r, lit, w, zCard());
        match Saves.slotOf(w#slotTab, i, w#saves) {
            case Some(slot) =>
                let rm = Layout.remove(i);
                let removeMark = textIn(rm, "×", atlas, 16.0, if (isOver(rm, w)) t#accent else dim(w), zPanelText());
                let date = textRight(rm#position#x - 6.0, y + 10.0, Saves.dateText(slot#savedAt), atlas, 13.0, t#inkSeen, zPanelText());
                let place = textAt(tx, y + 32.0, clipTo(textWidth, 17.0, atlas, slot#place), atlas, 17.0, t#ink, zPanelText());
                let said = if (String.isEmpty(slot#speaker)) slot#excerpt else "${slot#speaker}${slot#excerpt}";
                let excerpt = linesWithin(textWidth, 13.0, 2, atlas, said) |> List.zipWithIndex
                    |> List.map(match (n, row) -> textAt(tx, y + 62.0 + Int32.toFloat64(n) * 19.0, row, atlas, 13.0, Color.mix(t#ink, t#panel, 0.2), zPanelText()));
                let badge = if (newest == Some((w#slotTab, i))) newBadge(atlas, thumb, w) else Nil;
                List.flatten((card :: number :: removeMark :: date :: place :: excerpt) :: thumbnail(atlas, slot, thumb, w) :: badge :: Nil)
            case None =>
                let empty = at(thumb#position#x, thumb#position#y, RawDraw.box(thumb#size, Color.darken(t#panel, 0.3), zThumb())
                                   |> Render.outlineA({ color = Color.mix(t#ink, t#panel, 0.75), alpha = 0.6, width = 1.0 }));
                card :: number :: empty :: textIn(thumb, label(StoryDoc.Label.EmptySlot, w), atlas, 13.0, dim(w), zPanelText()) :: Nil
        }

    /// サムネに載せる字の大きさ（px）。
    def thumbTextSize(): Float64 = 7.5

    /// サムネ: セーブした時の写真と時間帯を背景と同じ式で小さく塗り、文章の窓（NVL の幕・ADV の窓）とその時の文を重ねる。
    /// 字は画面と同じ縮みでは潰れて読めないので、縮みより大きい thumbTextSize で、窓の幅に収まる所まで折り返して載せる。
    /// WhyNot: 実機の画面を写して残さない —— 描き出しと実機で同じ絵にならず、セーブの JSON に絵を入れると重い。
    def thumbnail(atlas: FontAtlas, slot: Saves.Slot, r: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let ground = at(r#position#x, r#position#y, RawDraw.box(r#size, Backdrop.groundColor(), zThumb()));
        let photo = slot#mark#shot |> Option.flatMap(shot -> specOf(shot, w))
            |> Option.map(spec -> Backdrop.surface(spec, r, 1.0, zThumb() + 1) :: Nil) |> Option.getWithDefault(Nil);
        let ink = Color.mix(t#ink, t#panel, 0.1);
        let size = thumbTextSize();
        let rowGap = size + 2.0;
        let rows = (x, yy, width, maxRows, texts) -> texts
            |> List.flatMap(text -> linesWithin(width, size, maxRows, atlas, text)) |> List.take(maxRows) |> List.zipWithIndex
            |> List.map(match (n, row) -> textAt(x, yy + Int32.toFloat64(n) * rowGap, row, atlas, size, ink, zThumb() + 3));
        let sx = r#size#x / World.width();
        let sy = r#size#y / World.height();
        let window = match slot#mark#mode {
            case Stage.Mode.Nvl =>
                at(r#position#x, r#position#y, RawDraw.box(r#size, t#panel, zThumb() + 2) |> Render.fade(Float64.min(0.95, windowAlpha(w) * t#veil)))
                :: rows(r#position#x + 110.0 * sx, r#position#y + 56.0 * sy, Layout.nvlText()#width * sx, 8, slot#page)
            case Stage.Mode.Adv =>
                let p = Layout.advPanel();
                at(r#position#x + p#position#x * sx, r#position#y + p#position#y * sy,
                   RawDraw.box({ x = p#size#x * sx, y = p#size#y * sy }, t#panel, zThumb() + 2) |> Render.fade(windowAlpha(w)))
                :: List.append(
                    if (String.isEmpty(slot#speaker)) Nil
                    else textAt(r#position#x + 72.0 * sx, r#position#y + 356.0 * sy, slot#speaker, atlas, size, t#name, zThumb() + 3) :: Nil,
                    rows(r#position#x + 72.0 * sx, r#position#y + 398.0 * sy, Layout.advText()#width * sx, 2,
                         if (List.isEmpty(slot#page)) slot#excerpt :: Nil else slot#page))
        };
        let edge = frameOf(r, Color.mix(t#ink, t#panel, 0.6), zThumb() + 4);
        List.flatten((ground :: Nil) :: photo :: window :: edge :: Nil)

    /// 矩形の 1px の縁。
    def frameOf(r: Rect2.Rect2, color: Color, z: Int32): List[Render.PlacedItem] =
        let x = r#position#x;
        let y = r#position#y;
        let w = r#size#x;
        let h = r#size#y;
           at(x, y, RawDraw.box({ x = w, y = 1.0 }, color, z))
        :: at(x, y + h - 1.0, RawDraw.box({ x = w, y = 1.0 }, color, z))
        :: at(x, y, RawDraw.box({ x = 1.0, y = h }, color, z))
        :: at(x + w - 1.0, y, RawDraw.box({ x = 1.0, y = h }, color, z))
        :: Nil

    def newBadge(atlas: FontAtlas, thumb: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let r = { position = { x = thumb#position#x + 4.0, y = thumb#position#y + 4.0 }, size = { x = 38.0, y = 17.0 } };
        at(r#position#x, r#position#y, RawDraw.box(r#size, t#accent, zThumb() + 5) |> Render.rounded(2.0))
        :: textIn(r, label(StoryDoc.Label.NewBadge, w), atlas, 11.0, t#panel, zThumb() + 6) :: Nil

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

    /// 幅 maxWidth で折り、rows 行まで（あふれた最後の行は「…」で切る）。
    def linesWithin(maxWidth: Float64, size: Float64, rows: Int32, atlas: FontAtlas, text: String): List[String] =
        def take(n: Int32, rest: String): String = {
            if (n >= String.length(rest) or TextDraw.width(String.takeLeft(n + 1, rest), atlas, size) > maxWidth) String.takeLeft(n, rest)
            else take(n + 1, rest)
        };
        def go(left: Int32, rest: String): List[String] = {
            if (String.isEmpty(rest) or left <= 0) Nil
            else if (left == 1) clipTo(maxWidth, size, atlas, rest) :: Nil
            else {
                let head = take(0, rest);
                let n = Int32.max(1, String.length(head));
                String.takeLeft(n, rest) :: go(left - 1, String.dropLeft(n, rest))
            }
        };
        go(rows, text)

    // ── 設定 ──

    /// 設定: 左の列に文章、右の列に音と画面。つまみ・2 つから選ぶボタン・初期設定に戻す。左下に文字の速さと窓の濃さの見本。
    def settingsPanel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let groups = (0 :: 1 :: Nil) |> List.flatMap(col -> {
            let g = Layout.group(col);
            let name = if (col == 0) StoryDoc.Label.GroupText else StoryDoc.Label.GroupSound;
            textAt(g#x, g#y, label(name, w), atlas, 14.0, t#accent, zPanelText())
            :: at(g#x, g#y + 22.0, RawDraw.box({ x = 400.0, y = 1.0 }, Color.mix(t#ink, t#panel, 0.7), zPanelText()) |> Render.fade(0.6)) :: Nil
        });
        let rows = World.settings() |> List.zipWithIndex |> List.flatMap(match (i, setting) -> settingRow(atlas, i, setting, w));
        List.flatten(panelFrame(atlas, label(StoryDoc.Label.SettingsTitle, w), "", w) :: groups :: rows :: preview(atlas, w) :: Nil)

    def settingRow(atlas: FontAtlas, i: Int32, setting: World.Setting, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let row = Layout.settingRow(i);
        let picked = i == w#cursor;
        let focus = if (picked) at(row#position#x - 8.0, row#position#y, RawDraw.box({ x = 2.0, y = row#size#y }, t#accent, zPanelText())) :: Nil else Nil;
        let name = textAt(row#position#x + 4.0, row#position#y + 12.0, label(settingLabel(setting), w), atlas, 16.0,
                          if (picked) t#accent else t#ink, zPanelText());
        let control = match World.controlOf(setting) {
            case World.Control.Slider(lo, hi, _) =>
                let bar = Layout.settingBar(i);
                let v = World.valueOf(setting, w);
                let filled = if (hi > lo) (v - lo) / (hi - lo) else 0.0;
                let knobX = bar#position#x + bar#size#x * filled;
                at(bar#position#x, bar#position#y, RawDraw.box(bar#size, Color.lighten(t#panel, 0.18), zPanelText()) |> Render.rounded(3.0))
                :: at(bar#position#x, bar#position#y, RawDraw.box({ x = bar#size#x * filled, y = bar#size#y }, t#accent, zPanelText() + 1) |> Render.rounded(3.0))
                :: RawDraw.circleAt({ x = knobX, y = bar#position#y + bar#size#y / 2.0 }, if (picked) 8.0 else 7.0, if (picked) t#accent else t#ink, zPanelText() + 2)
                :: textRight(row#position#x + row#size#x, row#position#y + 13.0, valueText(setting, v), atlas, 14.0, t#inkSeen, zPanelText())
                :: Nil
            case World.Control.Pair(left, right) =>
                let chosen = if (World.valueOf(setting, w) >= 0.5) 1 else 0;
                (0 :: 1 :: Nil) |> List.flatMap(side -> {
                    let r = Layout.settingSide(i, side);
                    let on = side == chosen;
                    plate(r, on or isOver(r, w), w, zPanelText())
                    :: textIn(r, label(if (side == 0) left else right, w), atlas, 14.0, if (on) t#accent else t#inkSeen, zPanelText() + 1) :: Nil
                })
            case World.Control.Action =>
                let r = Layout.settingAction(i);
                plate(r, picked or isOver(r, w), w, zPanelText()) :: textIn(r, label(StoryDoc.Label.Reset, w), atlas, 15.0, t#ink, zPanelText() + 1) :: Nil
        };
        match World.controlOf(setting) {
            case World.Control.Action => List.append(focus, control)
            case _                    => List.flatten(focus :: (name :: Nil) :: control :: Nil)
        }

    /// 見本: 窓の濃さで地を敷き、文字の速さで見本の文を流し続ける（実時間。読み終えて少し置いてから頭へ戻る）。
    def preview(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let t = theme(w);
        let r = Layout.preview();
        let k = KindDoc.rec(w#kind);
        let sample = label(StoryDoc.Label.Preview, w);
        let cps = Saves.configOf(w#saves)#cps;
        let length = Int32.toFloat64(String.length(sample));
        let cycle = length / Float64.max(1.0, cps) + 1.6;
        let elapsed = realSeconds(w) - Float64.floor(realSeconds(w) / cycle) * cycle;
        let visible = Float64.tryToInt32(Float64.floor(elapsed * cps)) |> Option.getWithDefault(0) |> Int32.min(String.length(sample));
        let size = 16.0;
        at(r#position#x, r#position#y,
           Render.vgrad(r#size, { top = t#panel, bottom = Color.darken(t#panel, 0.3) }, zCard()) |> Render.fade(windowAlpha(w))
               |> Render.outlineA({ color = t#accent, alpha = 0.35, width = 1.0 }) |> Render.rounded(3.0))
        :: RichText.placeRuby({ atlas = atlas, size = size, baseTint = t#ink, z = zPanelText(),
                                pos = { x = r#position#x + 16.0, y = r#position#y + 18.0 },
                                maxWidth = r#size#x - 32.0, lineGap = k#lineGap * size / k#bodySize },
                              k#rubySize * size / k#bodySize, Nil, visible, RichText.plain(sample) :: Nil)

    pub def settingLabel(setting: World.Setting): StoryDoc.Label = match setting {
        case World.Setting.TextSpeed      => StoryDoc.Label.TextSpeed
        case World.Setting.AutoWait       => StoryDoc.Label.AutoWait
        case World.Setting.SkipScope      => StoryDoc.Label.SkipScope
        case World.Setting.AfterChoice    => StoryDoc.Label.AfterChoice
        case World.Setting.Display        => StoryDoc.Label.Display
        case World.Setting.MasterVolume   => StoryDoc.Label.MasterVolume
        case World.Setting.AmbienceVolume => StoryDoc.Label.AmbienceVolume
        case World.Setting.SeVolume       => StoryDoc.Label.SeVolume
        case World.Setting.WindowAlpha    => StoryDoc.Label.WindowAlpha
        case World.Setting.Reset          => StoryDoc.Label.Reset
    }

    def valueText(setting: World.Setting, v: Float64): String =
        let whole = x -> Float64.tryToInt32(Float64.round(x)) |> Option.getWithDefault(0) |> Int32.toString;
        match setting {
            case World.Setting.TextSpeed => "${whole(v)} 字/秒"
            case World.Setting.AutoWait  => "${Float64.toString(Float64.round(v * 10.0) / 10.0)} 秒"
            case _                       => "${whole(v * 100.0)}%"
        }

    // ── 確認の窓 ──

    def askLayer(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#ask {
            case None      => Nil
            case Some(ask) =>
                let t = theme(w);
                let box = Layout.askBox();
                let center = box#position#x + box#size#x / 2.0;
                let (question, note) = askText(ask);
                let shade = at(0.0, 0.0, RawDraw.box({ x = World.width(), y = World.height() }, Color.darken(t#panel, 0.4), zAsk()) |> Render.fade(0.6));
                let ground = at(box#position#x, box#position#y,
                                Render.vgrad(box#size, { top = Color.lighten(t#panel, 0.05), bottom = t#panel }, zAsk() + 1)
                                    |> Render.outlineA({ color = t#accent, alpha = 0.6, width = 1.0 }) |> Render.rounded(4.0));
                let line = TextDraw.centered({ text = label(question, w), atlas = atlas, size = 19.0, color = t#ink, z = zAsk() + 2,
                                               centerX = center, y = box#position#y + 40.0 });
                let sub = note |> Option.map(n -> TextDraw.centered({ text = label(n, w), atlas = atlas, size = 13.0, color = t#inkSeen,
                                                                       z = zAsk() + 2, centerX = center, y = box#position#y + 74.0 }) :: Nil)
                              |> Option.getWithDefault(Nil);
                let answers = (0 :: 1 :: Nil) |> List.flatMap(i -> {
                    let r = Layout.askButton(i);
                    let on = i == w#askCursor;
                    plate(r, on, w, zAsk() + 2)
                    :: textIn(r, label(if (i == 0) StoryDoc.Label.Yes else StoryDoc.Label.No, w), atlas, 17.0, if (on) t#accent else t#ink, zAsk() + 3) :: Nil
                });
                List.flatten((shade :: ground :: line :: Nil) :: sub :: answers :: Nil)
        }

    /// 尋ねる言葉と、下に添える注意（進行が失われる時）。
    def askText(ask: World.Ask): (StoryDoc.Label, Option[StoryDoc.Label]) = match ask {
        case World.Ask.Overwrite(_) => (StoryDoc.Label.AskOverwrite, None)
        case World.Ask.Delete(_)    => (StoryDoc.Label.AskDelete, None)
        case World.Ask.Load(_)      => (StoryDoc.Label.AskLoad, Some(StoryDoc.Label.LostNote))
        case World.Ask.QuickLoad    => (StoryDoc.Label.AskLoad, Some(StoryDoc.Label.LostNote))
        case World.Ask.Jump(_)      => (StoryDoc.Label.AskJump, None)
        case World.Ask.ToTitle      => (StoryDoc.Label.AskToTitle, Some(StoryDoc.Label.LostNote))
        case World.Ask.Quit         => (StoryDoc.Label.AskQuit, None)
        case World.Ask.Reset        => (StoryDoc.Label.AskReset, None)
    }

    // ── 知らせ ──

    def toast(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match World.toastOf(w) {
            case Some(text) =>
                let t = theme(w);
                let width = TextDraw.width(text, atlas, 14.0) + 32.0;
                let r = { position = { x = World.width() - 32.0 - width, y = 20.0 }, size = { x = width, y = 32.0 } };
                at(r#position#x, r#position#y, RawDraw.box(r#size, t#panel, zToast()) |> Render.fade(0.88)
                                                   |> Render.outlineA({ color = t#accent, alpha = 0.5, width = 1.0 }) |> Render.rounded(4.0))
                :: textIn(r, text, atlas, 14.0, t#accent, zToast() + 1) :: Nil
            case None => Nil
        }
}
