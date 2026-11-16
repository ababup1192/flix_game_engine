// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「夏の田舎の、記憶の中の写真」。背景は実写をぼかして時間帯の色に染め（Backdrop）、その上に明朝の字を置く。
//   主役は文章。写真はぼかして奥へ下げ、字の下には必ず暗い地（ADV のウィンドウ・NVL の幕・画面の幕）を敷いて読ませる。
//   色は 3 つ: 写真の時間帯の色 / 紙のような白い字 / 夕陽の金（選んでいる物・名前）。
//   やらないこと: 写真をぼかさずに出さない（字と喧嘩する）。字を写真の上に地無しで置かない。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「写真を奥へ下げて文章を主役にする」層の分け方。
//
// ── 画面の層（奥から手前へ）──
//   world: 層の数の順に並べる（ViewStage）。背景 0 → 背景に付く絵 → 粒 → 立ち絵と小物（Doc の layer）・ゲームの絵（GameView が決める）→ 覆い（overlay）
//          … カメラと揺れはこの層だけに掛かる
//   hud:   NVL の幕 / ADV のウィンドウ → 本文（ルビつき）・名前 → 送りの印 → 選択肢 → クイックメニュー（縦の画面は右の列と … とツールチップ）
//          → 素材を待つ間の黒と待ちの印（ブラウザ版で背景・環境音がまだ届いていない時）
//          → 画面（バックログ・セーブ・ロード・設定。セーブの枠のサムネはその時の画面を同じ関数で描いて縮める）→ 確認のウィンドウ → 知らせ
//          タイトルとクレジットも hud（写真の上に字だけを置く画面）
//
// ── 何を受けて描くか ──
// 入口（frame・hud）だけが World を受け、場面の enum を match して、その場面の値（Read・タイトルのカーソル・
// クレジットの時刻・画面の payload）と、どの場面でも使う描く元 Env を下の関数へ渡す。下の関数は World を読まないので、
// 「この画面はこの値しか見ない」が引数で分かる。
//
// ── 時計 ── 背景の重ね・揺れは物語の時計（画面を開くと止まる）、蛍・送りの印の明滅・クレジット・設定の見本は実時間（env#realNow）。
// ── 触れている物 ── マウスの位置 env#pointer に乗っている物（ボタン・枠・行）を明るくする。押せる所は Layout の同じ矩形。
mod View {
    use fge::{App, Clock, Color, DrawCmd, FontAtlas, Fx, Num, RawDraw, Rect2, Render, RichText, ShaderDoc, TextDraw, UiScroll, Vec2}

    /// どの場面でも使う描く元: Doc とシナリオ（res）・セーブデータ（既読と設定と枠）・マウスの位置・2 本の時計の今・
    /// 並べ方の組（fit。Controls が当たりを取る時と同じ組）・押している間の掴み（grab。列の長押しのツールチップ）・
    /// 字の本（fonts。GameView が Render.textTinted などに渡す）。
    pub type alias Env = {
        res = Res.Res,
        saves = Saves.Saves,
        pointer = { x = Float64, y = Float64 },
        grab = World.Grab,
        realNow = Clock.Time[Clock.Real],
        storyNow = Clock.Time[Stage.Story],
        fit = Layout.Fit,
        fonts = Fonts
    }

    /// 字の本: atlas = 本文の本（project.json の fonts の default）、fontOf = 名前で引く本（project.json の fonts[].name。
    /// 実機は GameBoot.app の App.withFonts で宣言した名前だけ引け、知らない名前は atlas が返る）。
    pub type alias Fonts = { atlas = FontAtlas, fontOf = String -> FontAtlas }

    /// 字を描かない所（当たりを取る・バックログの寸法・テープの物の矩形）の Env。fonts は字の形を持たない本（emptyFonts）。
    pub def envOf(fit: Layout.Fit, res: Res.Res, w: World.World): Env =
        { res = res, saves = w#saves, pointer = w#pointer, grab = w#grab, realNow = w#realNow, storyNow = World.now(w), fit = fit, fonts = emptyFonts() }

    /// 描く所の Env（並べ方の組と字の本は ctx から）。
    pub def envOfCtx(ctx: App.ViewCtx, res: Res.Res, w: World.World): Env =
        { fonts = { atlas = ctx#atlas, fontOf = ctx#fontOf } | envOf(fitOfCtx(ctx, res), res, w) }

    /// 字の形を持たない本（どの字も幅 0 で描かれない）。
    // WhyNot: 当たりを取る所に実機の本を渡さない — Controls は Frame しか受けず、本は描く側（ViewCtx）にしか無い。
    pub def emptyFonts(): Fonts =
        let empty = { textureName = "", fontSize = 32.0, textureSize = 256.0, ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() };
        { atlas = empty, fontOf = _ -> empty }

    /// 描く画面の区分と design の向き・大きさから並べ方の組を選ぶ（Controls が Frame から引く組と同じ）。
    // WhyNot: ctx#visible#size を design の大きさとして読んでよいのは、このゲームが camera を使わないから（HUD は常に design 全体）。
    def fitOfCtx(ctx: App.ViewCtx, res: Res.Res): Layout.Fit =
        Layout.fitOf(ctx#display#sizeClass, ctx#display#orientation, ctx#visible#size, res#smallScreen, res#portrait)

    /// world の層（ViewStage）でまとまり 1 つが使う z の幅（まとまりの中の z は 0..この幅-1）。
    pub def zWorldStride(): Int32 = 8

    /// 背景の層の中の z: 地 0・前の背景 1..3・今の背景 4..6（GameView.backdrop の絵の中の z 0..2 をこの幅へ）。
    pub def zBackdropUnder(): Int32 = 1

    pub def zBackdropShot(): Int32 = 4

    // ── hud の中の z（小さいほど奥） ──
    pub def zVeil(): Int32 = 10
    /// 頁の幕の上・字の下に置く小物（NVL と縦の画面の頁。幕で小物がくすまないように）。
    pub def zPageProp(): Int32 = 15
    pub def zText(): Int32 = 20
    /// ゲームの hud の物（GameView.hud）の帯の下端。UnderWindow は 1..9（文字の枠の覆いより奥）、OverWindow は 21..29（本文の上・選択肢の下）。
    pub def zGameHudUnder(): Int32 = 1
    /// サムネで UnderWindow をまとめる z（world を 0..8 に詰めた上・字の 10 の下）。
    pub def zThumbHudUnder(): Int32 = 9
    pub def zGameHud(): Int32 = 21
    def zChoice(): Int32 = 30
    def zButtons(): Int32 = 40
    /// 素材を待つ間の黒（本文とボタンの上・画面と確認のウィンドウの下）と、その上の待ちの印。
    /// <<overlay layer=screen>> の覆い（本文とボタンの上・素材を待つ間の黒の下）。
    def zOverlay(): Int32 = 44
    def zHold(): Int32 = 45
    def zHoldMark(): Int32 = 46
    def zPanel(): Int32 = 50
    def zCard(): Int32 = 52
    /// サムネの縮めた画面は zThumb + 元の z（元は 0..zButtons の少し上）に入る。縁と印は zThumbTop から。
    def zThumb(): Int32 = 60
    def zThumbTop(): Int32 = 110
    def zPanelText(): Int32 = 120
    def zAsk(): Int32 = 140
    def zBanner(): Int32 = 150
    def zToast(): Int32 = 160

    pub def frame(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let env = envOfCtx(ctx, res, w);
        match w#scene {
            case World.Scene.Title(_) => ViewStage.titleFrame(env, World.stageOf(res, w))
            case _                    => ViewStage.frame(env, World.stageOf(res, w), not ViewStage.isPropOnPage(env, w))
        }

    /// 舞台だけの絵（frame と、画面に被せる overlay）。文字の枠・HUD・画面・知らせ・素材の待ちの字は描かない（移行の突き合わせの world の層のコマ）。
    // WhyNot: frame だけにしない — layer=screen の overlay は hud の側に描くので、frame だけでは overlay の秒を替えた差が world の層のコマに出ない。
    pub def worldLayer(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let env = envOfCtx(ctx, res, w);
        let covered = World.readOf(w) |> Option.map(r -> ViewStage.screenOverlay(env, r#stage, zOverlay())) |> Option.getWithDefault(Nil);
        List.append(frame(ctx, res, w), covered)

    pub def hud(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let atlas = ctx#atlas;
        let env = envOfCtx(ctx, res, w);
        // 画面（バックログ・セーブ・設定）の間は下の画面を描かない（幕越しに字が二重に透けて読みにくい）。背景の写真は frame が描き続ける。
        let screen = if (coversScreen(w#panel)) Nil else match w#scene {
            case World.Scene.Title(item)      => title(atlas, env, item)
            case World.Scene.Credits(startedAt, _) => credits(atlas, env, startedAt)
            case World.Scene.Reading(r)       => if (w#panel == World.Panel.Hidden) Nil
                                                 else if (Stage.isWindowHidden(env#storyNow, r#stage)) gameHud(env, r)
                                                 else List.append(gameHud(env, r), shakenWindow(env, r, List.append(fadedWindow(env, r, reading(atlas, env, r)), pageProps(env, r))))
        };
        let covered = World.readOf(w) |> Option.map(r -> ViewStage.screenOverlay(env, r#stage, zOverlay())) |> Option.getWithDefault(Nil);
        let holding = World.readOf(w) |> Option.flatMap(r -> r#hold) |> Option.map(holdLayer(atlas, env)) |> Option.getWithDefault(Nil);
        List.flatten(screen :: covered :: holding :: panel(res, atlas, env, w) :: askLayer(atlas, env, w#ask) :: editedBanner(atlas, env) :: toast(atlas, env, World.toastOf(res, w)) :: Nil)

    /// GameView.hud の物を置く帯。UnderWindow = 文字の枠の覆いより奥（hud の一番奥。カメラと揺れを受けない。画面に掛かる血など）・
    /// OverWindow = 本文の上・選択肢の下（状態バー・コメント欄など）。
    pub enum HudBand with Eq {
        case UnderWindow
        case OverWindow
    }

    /// ゲームの hud の物（GameView.hud）。
    def gameHud(env: Env, r: World.Read): List[Render.PlacedItem] = gameHudUsing(GameView.hud, env, r)

    /// hud が返す物を帯ごとの z（帯の下端から 9 段）へ置く（物の中の z 0..8。テストが hud を差し替える）。
    pub def gameHudUsing(hud: (Env, World.Read) -> List[(HudBand, Render.PlacedItem)], env: Env, r: World.Read): List[Render.PlacedItem] =
        placeHud(z -> zGameHudUnder() + clampHudZ(z), hud(env, r))

    /// サムネのゲームの hud: world を 0..8 に詰めるので、UnderWindow は 1 段（zThumbHudUnder）にまとめる（world より手前・字より奥）。
    // WhyNot: 実際の画面と同じ 1..9 に置かない — サムネの world の 0..8 と重なり、画面に掛かる血が立ち絵や覆いの下に潜る。
    pub def thumbHudUsing(hud: (Env, World.Read) -> List[(HudBand, Render.PlacedItem)], env: Env, r: World.Read): List[Render.PlacedItem] =
        placeHud(_ -> zThumbHudUnder(), hud(env, r))

    /// 帯の付いた物を置く: UnderWindow は under で z を決め、OverWindow は zGameHud から 9 段。
    def placeHud(under: Int32 -> Int32, items: List[(HudBand, Render.PlacedItem)]): List[Render.PlacedItem] =
        items |> List.map(match (band, item) ->
            Render.overItem(ViewStage.mapZ(z -> if (band == HudBand.UnderWindow) under(z) else zGameHud() + clampHudZ(z)), item))

    def clampHudZ(z: Int32): Int32 = Int32.max(0, Int32.min(8, z))

    /// 頁の幕の上に描く小物（ViewStage.propsOnPage の時だけ）。
    // WhyNot: 小物に文字の枠の薄さ（<<window off time=>>）を掛けない — 消し終えると world の層が小物を濃いまま描くので、薄くなってからぱっと戻る。
    def pageProps(env: Env, r: World.Read): List[Render.PlacedItem] =
        if (ViewStage.propsOnPage(env, r#stage)) ViewStage.pageProps(env, r#stage) else Nil

    /// 文字の枠と字を <<window off|on time=>> の途中の濃さにする。
    def fadedWindow(env: Env, r: World.Read, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        let a = Stage.windowAlphaAt(env#storyNow, r#stage);
        if (a >= 1.0) items else items |> List.map(Render.overItem(Render.fade(a)))

    /// 文字の枠と字を <<shake on=window>> の分だけずらす。
    def shakenWindow(env: Env, r: World.Read, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        let (dx, dy) = Stage.shakeOffset(env#storyNow, Stage.ShakeTarget.Window, r#stage);
        if (dx == 0.0 and dy == 0.0) items else Render.movedAll({ x = dx, y = dy }, items)

    pub def realSeconds(env: Env): Float64 = Clock.secondsOf(env#realNow)

    pub def theme(env: Env): ThemeDoc.Rec = ThemeDoc.rec(env#res#theme)

    pub def kindOf(env: Env): KindDoc.Rec = KindDoc.rec(env#res#kind)

    def label(l: StoryDoc.Label, env: Env): String = StoryDoc.labelOf(l, env#res#story)

    def isOver(r: Rect2.Rect2, env: Env): Bool = Layout.contains(r, env#pointer)

    /// 添え書きの字（案内・日時・番号・群の見出し）の大きさ。縦の画面は 1 design px が CSS px で小さいので 1.25 倍。
    // WhyNot: 添え書きの字まで novel.portrait.json に出さない — 押す物と本文の字だけが手触りで、添え書きはそれらに付いて決まる。
    def captionSize(env: Env, size: Float64): Float64 = if (Layout.isPortrait(env#fit)) size * 1.25 else size

    /// 字の薄い色（選べない物・空き）。
    def dim(env: Env): Color = Color.mix(theme(env)#ink, theme(env)#panel, 0.55)

    pub def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem = { at = { x = x, y = y }, item = item }

    /// 文章のウィンドウの濃さ（設定の「ウィンドウの濃さ」）。NVL の幕はこれに theme の veil を掛ける。
    pub def windowAlpha(env: Env): Float64 = Saves.configOf(env#saves)#windowAlpha

    pub def textAt(x: Float64, y: Float64, text: String, atlas: FontAtlas, size: Float64, color: Color, z: Int32): Render.PlacedItem =
        at(x, y, Render.textTinted(text, atlas, size, color, z))

    /// 右端を right に合わせた字。
    def textRight(right: Float64, y: Float64, text: String, atlas: FontAtlas, size: Float64, color: Color, z: Int32): Render.PlacedItem =
        textAt(right - TextDraw.width(text, atlas, size), y, text, atlas, size, color, z)

    /// 矩形の真ん中に置いた 1 行。
    def textIn(r: Rect2.Rect2, text: String, atlas: FontAtlas, size: Float64, color: Color, z: Int32): Render.PlacedItem =
        TextDraw.centered({ text = text, atlas = atlas, size = size, color = color, z = z,
                            centerX = r#position#x + r#size#x / 2.0, y = r#position#y + (r#size#y - size) / 2.0 - 1.0 })

    /// 平らなボタンの地と縁（lit = 選んでいる・触れている）。
    def plate(r: Rect2.Rect2, lit: Bool, env: Env, z: Int32): Render.PlacedItem =
        let t = theme(env);
        let fill = if (lit) Color.mix(t#panel, t#accent, 0.16) else Color.lighten(t#panel, 0.06);
        at(r#position#x, r#position#y,
           RawDraw.box(r#size, fill, z) |> Render.fade(0.92)
               |> Render.outlineA({ color = if (lit) t#accent else Color.mix(t#ink, t#panel, 0.7), alpha = if (lit) 0.9 else 0.6, width = 1.0 })
               |> Render.rounded(3.0))

    /// 画面（バックログ・セーブ・設定）が下の画面を覆うか。
    pub def coversScreen(panel: World.Panel): Bool = match panel {
        case World.Panel.Closed          => false
        case World.Panel.Hidden          => false
        case World.Panel.Menu(_)         => false
        case World.Panel.SaveLoadPick(_) => false
        case _                           => true
    }

    // ── 素材の待ち（ブラウザ版で背景・環境音がまだ届いていない間の暗転） ──

    /// 画面を夜の地の色で覆う（黒へ重ねる・黒のまま・黒から戻す）。黒のまま holdMarkSeconds を過ぎたら待ちの印（形は novel.theme.json の loadingMark）。
    /// 重ねの進みは物語の時計（画面を開くと止まる）、印の動きは実時間。
    def holdLayer(atlas: FontAtlas, env: Env): World.Hold -> List[Render.PlacedItem] = hold ->
        let k = kindOf(env);
        let progress = if (k#holdFadeSeconds <= 0.0) 1.0
                       else Float64.min(1.0, Float64.max(0.0, Clock.since(hold#phaseFrom, env#storyNow) / k#holdFadeSeconds));
        let alpha = match hold#phase {
            case World.HoldPhase.FadingOut => progress
            case World.HoldPhase.Waiting   => 1.0
            case World.HoldPhase.FadingIn  => 1.0 - progress
        };
        let whole = Layout.screen(env#fit);
        let veil = at(0.0, 0.0, RawDraw.box(whole#size, Backdrop.groundOf(env#res#backdrops), zHold()) |> Render.fade(alpha));
        let marked = hold#phase == World.HoldPhase.Waiting and hold#waited >= k#holdMarkSeconds;
        let mark = if (marked) loadingMark(atlas, env, theme(env)#loadingMark, whole, { x = 60.0, y = 36.0 }, 1.0, zHoldMark()) else Nil;
        veil :: mark

    /// 素材を待つ間の印を矩形 place（画面かサムネの枠）に置く。Dots = 右下の金の点 3 つ（左の点の中心を右下の角から inset だけ内へ）、
    /// Ring = 真ん中に回る点の輪と字のラベル、Hidden = 何も描かない。scale = 大きさの倍率（サムネは小さく）。
    def loadingMark(atlas: FontAtlas, env: Env, kind: ThemeDoc.LoadingMark, place: Rect2.Rect2, inset: Vec2.Vec2, scale: Float64, z: Int32): List[Render.PlacedItem] =
        let right = place#position#x + place#size#x;
        let bottom = place#position#y + place#size#y;
        match kind {
            case ThemeDoc.LoadingMark.Dots => waitDots(env, { x = right - inset#x, y = bottom - inset#y }, scale, z)
            case ThemeDoc.LoadingMark.Ring =>
                ringBadge(atlas, env, { x = place#position#x + place#size#x / 2.0, y = place#position#y + place#size#y / 2.0 }, scale, z)
            case ThemeDoc.LoadingMark.Hidden  => Nil
        }

    /// 待ちの印: 金の小さな点 3 つが左から順に息をするように明滅する（蛍と同じ、芯と滲む光）。
    /// origin = 左の点の中心、scale = 大きさの倍率（サムネは小さく）。
    def waitDots(env: Env, origin: Vec2.Vec2, scale: Float64, z: Int32): List[Render.PlacedItem] =
        let color = theme(env)#accent;
        let t = realSeconds(env);
        List.range(0, 3) |> List.flatMap(i -> {
            let pulse = 0.5 + 0.5 * Num.sin(t * 4.2 - Int32.toFloat64(i) * 0.9);
            let a = 0.2 + 0.8 * pulse * pulse;
            let center = { x = origin#x + Int32.toFloat64(i) * 14.0 * scale, y = origin#y };
            RawDraw.circleAt(center, 2.6 * scale, Color.lighten(color, 0.35), z + 1) |> Render.overItem(item -> Render.fade(a, item))
            :: Render.glowAt(center, 9.0 * scale, color, { alpha = 0.45 * a, blend = DrawCmd.BlendMode.Add }, z)
        })

    /// 待ちの印の輪: 角の丸いラベル（上がわずかに明るい panel の地・差し色の細い縁）に、回る点の輪 8 つと labels の waiting の字。
    /// 字が空ならラベルを輪の大きさに詰める。center = ラベルの中心。点は 0.1 秒ごとに 1 つ先へ明るさが移る。
    def ringBadge(atlas: FontAtlas, env: Env, center: Vec2.Vec2, scale: Float64, z: Int32): List[Render.PlacedItem] =
        let t = theme(env);
        let word = label(StoryDoc.Label.Waiting, env);
        let size = captionSize(env, 18.0) * scale;
        let ring = 9.0 * scale;
        let gap = if (String.isEmpty(word)) 0.0 else 10.0 * scale;
        let padX = 16.0 * scale;
        let h = 40.0 * scale;
        let textW = if (String.isEmpty(word)) 0.0 else TextDraw.width(word, atlas, size);
        let w = padX + 2.0 * ring + gap + textW + padX;
        let left = center#x - w / 2.0;
        let top = center#y - h / 2.0;
        let plateSize = { x = w, y = h };
        let ground = at(left, top, RawDraw.box(plateSize, t#panel, z) |> Render.fade(0.88)
                                       |> Render.outlineA({ color = t#accent, alpha = 0.35, width = 1.0 }) |> Render.rounded(h / 2.0));
        let sheen = at(left, top, roundedSheen(plateSize, h / 2.0, t#ink, { top = 0.08, bottom = 0.0 }, z));
        let hub = { x = left + padX + ring, y = center#y };
        let head = Float64.tryToInt32(Float64.floor(realSeconds(env) * 10.0)) |> Option.getWithDefault(0);
        let dots = List.range(0, 8) |> List.map(i -> {
            let angle = Num.pi() * 2.0 * Int32.toFloat64(i) / 8.0;
            let a = 1.0 - Int32.toFloat64(Int32.modulo(head - i, 8)) / 8.0;
            RawDraw.circleAt({ x = hub#x + ring * Num.cos(angle), y = hub#y + ring * Num.sin(angle) }, 1.9 * scale, t#ink, z + 1)
                |> Render.overItem(item -> Render.fade(0.15 + 0.85 * a, item))
        });
        let text = if (String.isEmpty(word)) Nil
                   else textAt(hub#x + ring + gap, center#y - size / 2.0 - 1.0, word, atlas, size, t#ink, z + 1) :: Nil;
        ground :: sheen :: List.append(text, dots)

    // ── 読んでいる間の画面（本文・選択肢・クイックメニュー） ──

    /// 読んでいる間の 1 画面。サムネも同じ関数で描く。novel.cast.json で hideWindow の絵が出ている間は、文字の枠と字だけを描かない（選択肢とボタンは描く）。
    def reading(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let hidden = Cast.hidesWindow(env#res#cast, r#stage#cast);
        if (Layout.isPortrait(env#fit))
            List.flatten((if (hidden) Nil else ViewText.portraitPage(atlas, env, r)) :: choices(atlas, env, r) :: gateHint(atlas, env, r) :: portraitButtons(atlas, env, r) :: Nil)
        else List.flatten((if (hidden) Nil else ViewText.textLayer(atlas, env, r)) :: choices(atlas, env, r) :: gateHint(atlas, env, r) :: quickMenu(atlas, env, r) :: Nil)

    // ── 縦の画面の右の列と … ──

    /// 縦の画面の操作: 右端の縦の列に字の無い丸いアイコン（しおり・ログ・オート）と、右上の …。押せる所は Rail.button の正方形
    /// （44 CSS px 以上）で、丸はその真ん中に小さく置く。オートが動いている間は丸を差し色で塗って線を暗くし ‖ にする、
    /// スキップの間はオートの縁を差し色で太くする。長押しの間はツールチップを出す。
    // WhyNot: 列の丸に階調を入れない — 49 px の小さな記号で、面の階調は … の丸・ツールチップ・メニューの地が受け持つ。
    def portraitButtons(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let t = theme(env);
        let all = WorldMenu.buttonsOf(env#fit);
        let rail = all |> List.zipWithIndex |> List.flatMap(match (i, button) -> {
            let hit = Rail.button(env#fit, i);
            let icon = Rail.icon(env#fit, i);
            let lit = button == World.Button.Auto and r#playback == World.Playback.Auto;
            // WhyNot: スキップ中を何も出さないままにしない — 列にスキップは無く、オートの長押しで入ってオートで止めるので、オートの縁で見せる。
            let skipping = button == World.Button.Auto and r#playback == World.Playback.Skip;
            let over = isOver(hit, env);
            let fill = if (lit) t#accent else if (over) Color.lighten(t#panel, 0.12) else t#panel;
            let line = if (lit) Color.darken(t#panel, 0.2) else t#ink;
            let d = icon#radius * 2.0;
            let disc = at(icon#center#x - icon#radius, icon#center#y - icon#radius,
                          RawDraw.box({ x = d, y = d }, fill, zButtons() - 1) |> Render.fade(if (lit) 1.0 else 0.62)
                              |> Render.outlineA({ color = if (lit or skipping) t#accent else t#ink, alpha = if (skipping) 0.95 else if (over or lit) 0.5 else 0.18, width = if (skipping) 2.0 else 1.0 })
                              |> Render.rounded(icon#radius));
            disc :: iconStrokes(iconPaths(button, lit), icon#center, d, line, zButtons())
        });
        List.flatten(rail :: moreMark(env) :: tooltip(atlas, env, r) :: Nil)

    /// 右上の … の印（上がわずかに明るい半透明の丸に点 3 つ。点の間と大きさは丸の大きさに比べて決める）。
    def moreMark(env: Env): List[Render.PlacedItem] =
        let t = theme(env);
        let more = Rail.moreButton(env#fit);
        let center = more#center;
        let gap = more#radius * 0.4;
        let dot = more#radius * 0.12;
        let d = more#radius * 2.0;
        let over = isOver(more#hit, env);
        let corner = { x = center#x - more#radius, y = center#y - more#radius };
        at(corner#x, corner#y,
           RawDraw.box({ x = d, y = d }, if (over) Color.lighten(t#panel, 0.12) else t#panel, zButtons() - 1) |> Render.fade(0.62)
               |> Render.outlineA({ color = t#ink, alpha = if (over) 0.5 else 0.18, width = 1.0 }) |> Render.rounded(more#radius))
        :: at(corner#x, corner#y, roundedSheen({ x = d, y = d }, more#radius, t#ink, { top = 0.12, bottom = 0.0 }, zButtons()))
        :: (List.range(-1, 2) |> List.map(k -> RawDraw.circleAt({ x = center#x + Int32.toFloat64(k) * gap, y = center#y }, dot, t#ink, zButtons())))

    /// 角の丸い矩形（左上原点・角の半径 radius）の形で、上から下へ濃さが変わる color の面（地の上を明るく見せる重ね）。
    // WhyNot: Render.vgrad を … とツールチップの地に使わない — 頂点色の矩形なので角の丸めと縁が効かず、丸い … が四角く描かれる。
    def roundedSheen(size: Vec2.Vec2, radius: Float64, color: Color, alpha: { top = Float64, bottom = Float64 }, z: Int32): Render.Item =
        let r = Float64.min(radius, Float64.min(size#x, size#y) / 2.0);
        let arc = (cx, cy, startDeg) -> List.range(0, 7) |> List.map(k -> {
            let a = (startDeg + Int32.toFloat64(k) * 15.0) * Num.pi() / 180.0;
            { x = cx + r * Num.cos(a), y = cy + r * Num.sin(a) }
        });
        let outline = List.flatten(arc(size#x - r, r, 270.0) :: arc(size#x - r, size#y - r, 0.0) :: arc(r, size#y - r, 90.0) :: arc(r, r, 180.0) :: Nil);
        Render.gradPolygon(outline |> List.map(p -> { pos = p, color = color, alpha = alpha#top + (alpha#bottom - alpha#top) * p#y / size#y }), z)

    /// 長押しのツールチップ: 押し続けているボタンの左に、暗い地と右向きの小さな三角で名前を出す（長押しの秒に届いてから）。
    /// 指の長押し（Read の tip）は離した後に知らせと同じ秒だけ出す。
    def tooltip(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let all = WorldMenu.buttonsOf(env#fit);
        let tipped = World.tipOf(env#res, env#realNow, r);
        let pressed = match env#grab {
            case World.Grab.LongPress(i, since) if Rail.isLong(env#fit, Clock.since(since, env#realNow)) => Some(i)
            case _                                                                                       => tipped
        };
        pressed |> Option.flatMap(i -> List.nth(i, all) |> Option.map(b -> (i, b)))
            |> Option.filter(match (_, b) -> WorldMenu.longPressOf(b) == WorldMenu.LongPressAction.Tooltip)
            |> Option.map(match (i, b) -> tooltipPlate(atlas, env, Rail.tooltipAnchor(env#fit, i), label(buttonLabel(b), env)))
            |> Option.getWithDefault(Nil)

    /// ツールチップの地（上がわずかに明るい暗い角丸の地・差し色の細い縁）と、ボタンを指す右向きの三角と、名前の字。
    def tooltipPlate(atlas: FontAtlas, env: Env, anchor: Vec2.Vec2, word: String): List[Render.PlacedItem] =
        let t = theme(env);
        let size = Rail.tooltipTextSize(env#fit);
        let padX = 14.0;
        let h = size + 18.0;
        let w = TextDraw.width(word, atlas, size) + 2.0 * padX;
        let left = anchor#x - 8.0 - w;
        let top = anchor#y - h / 2.0;
        let ground = Color.darken(t#panel, 0.2);
        at(left, top, RawDraw.box({ x = w, y = h }, ground, zButtons() + 4) |> Render.fade(0.92)
                          |> Render.outlineA({ color = t#accent, alpha = 0.45, width = 1.0 }) |> Render.rounded(8.0))
        :: at(left, top, roundedSheen({ x = w, y = h }, 8.0, t#ink, { top = 0.08, bottom = 0.0 }, zButtons() + 4))
        :: at(0.0, 0.0, RawDraw.polygon(List#{{ x = anchor#x - 8.5, y = anchor#y - 6.0 }, { x = anchor#x, y = anchor#y }, { x = anchor#x - 8.5, y = anchor#y + 6.0 }},
                                        ground, zButtons() + 4) |> Render.fade(0.92))
        :: textIn({ position = { x = left, y = top }, size = { x = w, y = h } }, word, atlas, size, t#ink, zButtons() + 5) :: Nil

    /// アイコンの線（24 × 24 の升目で描いた線を、丸の直径 diameter に合わせて置く。線の太さは升目で 1.8）。
    /// 線の継ぎ目と端には線の太さの丸を置き、角を丸くする。
    def iconStrokes(paths: List[List[(Float64, Float64)]], center: Vec2.Vec2, diameter: Float64, color: Color, z: Int32): List[Render.PlacedItem] =
        let unit = diameter * 18.0 / 34.0 / 24.0;
        let width = 1.8 * unit;
        let toScreen = (p: (Float64, Float64)) -> { let (x, y) = p; { x = center#x + (x - 12.0) * unit, y = center#y + (y - 12.0) * unit } };
        let stroke = (points: List[(Float64, Float64)]) -> {
            let pts = points |> List.map(toScreen);
            let segs = List.zip(pts, List.drop(1, pts)) |> List.map(match (a, b) -> RawDraw.lineSeg(a, b, width, color, z));
            List.append(segs, pts |> List.map(p -> RawDraw.circleAt(p, width / 2.0, color, z)))
        };
        paths |> List.flatMap(stroke)

    /// アイコンの形（24 × 24 の升目の折れ線の束）。しおり = 下が V 字に切れた細長い紙と紐、ログ = 3 本の横線、
    /// オート = 三角（動いている間 on は ‖）。
    def iconPaths(button: World.Button, on: Bool): List[List[(Float64, Float64)]] = match button {
        case World.Button.Auto =>
            if (on) ((9.0, 6.0) :: (9.0, 18.0) :: Nil) :: ((15.0, 6.0) :: (15.0, 18.0) :: Nil) :: Nil
            else ((7.0, 5.0) :: (18.0, 12.0) :: (7.0, 19.0) :: (7.0, 5.0) :: Nil) :: Nil
        case World.Button.Log  =>
            ((5.0, 6.0) :: (19.0, 6.0) :: Nil) :: ((5.0, 11.0) :: (19.0, 11.0) :: Nil) :: ((5.0, 16.0) :: (14.0, 16.0) :: Nil) :: Nil
        case World.Button.SaveLoad =>
            // WhyNot: 紙の幅を広くしない — 幅の広い紙はブックマークの旗の形に読める。紐と房でしおりと分かる。
            ((7.5, 7.0) :: (16.5, 7.0) :: (16.5, 22.0) :: (12.0, 18.0) :: (7.5, 22.0) :: (7.5, 7.0) :: Nil)
            :: ((12.0, 7.0) :: (12.0, 3.6) :: Nil) :: ((12.0, 3.6) :: (9.4, 1.2) :: Nil) :: ((12.0, 3.6) :: (14.6, 1.2) :: Nil) :: Nil
        case _ => Nil
    }

    // ── 縦の画面の … のメニューとしおりの選び ──

    /// 小さなメニューの下に敷く物: 画面を薄く沈める幕と、box の地（上から下へ少し暗くなる・差し色の細い縁）。
    def popupGround(env: Env, box: Rect2.Rect2): List[Render.PlacedItem] =
        let t = theme(env);
        at(0.0, 0.0, RawDraw.box(Layout.size(env#fit), Color.darken(t#panel, 0.4), zPanel()) |> Render.fade(0.35))
        :: at(box#position#x, box#position#y,
              Render.vgrad(box#size, { top = Color.lighten(t#panel, 0.05), bottom = t#panel }, zPanel() + 1) |> Render.fade(0.94)
                  |> Render.outlineA({ color = t#accent, alpha = 0.45, width = 1.0 }) |> Render.rounded(10.0)) :: Nil

    /// 小さなメニューの 1 項目の字（カーソル・触れている項目は板を敷いて差し色の字）。
    def popupItem(atlas: FontAtlas, env: Env, r: Rect2.Rect2, item: World.Button, lit: Bool): List[Render.PlacedItem] =
        let t = theme(env);
        let inset = { position = { x = r#position#x + 4.0, y = r#position#y + 4.0 }, size = { x = r#size#x - 8.0, y = r#size#y - 8.0 } };
        let mark = if (lit) plate(inset, true, env, zPanel() + 2) :: Nil else Nil;
        textIn(r, label(menuLabel(item), env), atlas, Layout.menuItemTextSize(env#fit), if (lit) t#accent else t#ink, zPanelText()) :: mark

    /// … から開く小さなメニュー: 画面を薄く沈め、… の下に項目を縦に並べる。
    def menuPanel(atlas: FontAtlas, env: Env, cursor: Int32): List[Render.PlacedItem] =
        let items = WorldMenu.menuItems();
        let rows = items |> List.zipWithIndex |> List.flatMap(match (i, item) -> {
            let r = Rail.menuItem(env#fit, i);
            popupItem(atlas, env, r, item, i == cursor or isOver(r, env))
        });
        List.append(popupGround(env, Rail.menuBox(env#fit, List.length(items))), rows)

    /// しおりのボタンから開く選び: … のメニューと同じ地と縁で、しおりの左に [セーブ｜ロード] を横に並べ、間に細い線。
    def saveLoadPanel(atlas: FontAtlas, env: Env, cursor: Int32): List[Render.PlacedItem] =
        let t = theme(env);
        let items = WorldMenu.saveLoadItems();
        let count = List.length(items);
        let dividers = List.range(1, count) |> List.map(i -> {
            let r = Rail.saveLoadItem(env#fit, i, count);
            RawDraw.lineSeg({ x = r#position#x, y = r#position#y + 14.0 }, { x = r#position#x, y = r#position#y + r#size#y - 14.0 },
                            1.0, Color.mix(t#ink, t#panel, 0.6), zPanel() + 2)
        });
        let cells = items |> List.zipWithIndex |> List.flatMap(match (i, item) -> {
            let r = Rail.saveLoadItem(env#fit, i, count);
            popupItem(atlas, env, r, item, i == cursor or isOver(r, env))
        });
        List.flatten(popupGround(env, Rail.saveLoadBox(env#fit, count)) :: dividers :: cells :: Nil)

    /// 小さなメニューの項目の言葉（… の「タイトルへ」だけ、下の帯の「タイトル」と言葉を分ける）。
    def menuLabel(item: World.Button): StoryDoc.Label = match item {
        case World.Button.ToTitle => StoryDoc.Label.BackToTitle
        case _                    => buttonLabel(item)
    }

    // ── 選択肢 ──

    /// 選択肢のボタン（ゲートはボタンを出さず、入力の案内 gateHint が受け持つ）。
    def choices(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        if (Option.nonEmpty(WorldRead.gateOf(r))) Nil else buttonChoices(atlas, env, r)

    /// ゲートの入力の案内（矢印の高さは novel.prompts.json の arrow の y・右の端は縦の画面なら右の列の左）。
    def gateHint(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        WorldRead.gateOf(r) |> Option.map(gate -> {
            let size = Layout.size(env#fit);
            let margin = PromptsDoc.rec(env#res#prompts)#margin;
            let railLeft = List.range(0, List.length(WorldMenu.buttonsOf(env#fit))) |> List.map(i -> Rail.button(env#fit, i)#position#x) |> List.minimum;
            let right = if (Layout.isPortrait(env#fit)) railLeft |> Option.map(x -> x - 8.0) |> Option.getWithDefault(size#x - margin) else size#x - margin;
            let t = theme(env);
            let look = { width = size#x, height = size#y, y = size#y * PromptsDoc.rec(env#res#prompts)#arrow#y, right = right, t = realSeconds(env),
                         z = zChoice(), doc = env#res#prompts, ink = t#ink, ground = t#panel };
            Hint.items(atlas, look, ViewStage.targetRectOf(env, r#stage), gate)
        }) |> Option.getWithDefault(Nil)

    def buttonChoices(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let t = theme(env);
        let count = List.length(r#choices);
        // NVL は字が画面いっぱいにあるので、選ぶ間は幕を 1 枚足して頁を沈める。
        // 縦の画面は頁を選択肢の上までに縮めるので、頁を沈める幕は要らない。
        let sink = if (count > 0 and Stage.kindOf(env#res#theme, r#stage) == ThemeDoc.WindowKind.Nvl and not Layout.isPortrait(env#fit))
            at(0.0, 0.0, RawDraw.box(Layout.size(env#fit), t#panel, zChoice() - 1) |> Render.fade(0.7)) :: Nil
            else Nil;
        sink ::: (r#choices |> List.zipWithIndex |> List.flatMap(match (i, option) -> {
            let rect = Layout.choice(env#fit, i, count);
            let picked = i == r#choiceCursor and option#available;
            let ink = if (not option#available) dim(env) else if (picked) t#accent else t#ink;
            plate(rect, picked, env, zChoice()) :: textIn(rect, option#line#text, atlas, Layout.choiceTextSize(env#fit), ink, zChoice() + 2) :: Nil
        }))

    // ── クイックメニュー（下の帯） ──

    def quickMenu(atlas: FontAtlas, env: Env, r: World.Read): List[Render.PlacedItem] =
        let t = theme(env);
        let all = WorldMenu.buttonsOf(env#fit);
        let n = List.length(all);
        let first = Layout.button(env#fit, 0, n);
        // ADV のウィンドウの下は写真の上なので、帯に薄い地を敷いてから字を置く。
        let strip = at(0.0, first#position#y - 4.0,
                       Render.vgrad({ x = Layout.width(env#fit), y = Layout.height(env#fit) - first#position#y + 4.0 },
                                    { top = t#panel, bottom = Color.darken(t#panel, 0.4) }, zButtons() - 1) |> Render.fade(0.55 * windowAlpha(env)));
        strip :: (all |> List.zipWithIndex |> List.map(match (i, button) -> {
            let rect = Layout.button(env#fit, i, n);
            let lit = (button == World.Button.Auto and r#playback == World.Playback.Auto) or (button == World.Button.Skip and r#playback == World.Playback.Skip);
            let color = if (not isButtonOpen(button, env, r)) Color.mix(t#ink, t#panel, 0.7)
                        else if (lit) t#accent
                        else if (isOver(rect, env)) t#ink
                        else Color.mix(t#ink, t#panel, 0.3);
            textIn(rect, label(buttonLabel(button), env), atlas, Layout.buttonTextSize(env#fit), color, zButtons())
        }))

    /// 押して何か起きるボタンか（戻れない時の「戻る」・クイックセーブが無い時の「Qロード」は薄く出す）。
    def isButtonOpen(button: World.Button, env: Env, r: World.Read): Bool = match button {
        case World.Button.Rollback  => r#log |> List.zipWithIndex |> List.exists(match (i, entry) -> i >= 1 and WorldLog.isJumpable(entry))
        case World.Button.QuickLoad => Option.nonEmpty(Saves.slotOf(Saves.Tab.Quick, 0, env#saves))
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
        case World.Button.Menu      => StoryDoc.Label.Menu
        case World.Button.SaveLoad  => StoryDoc.Label.SaveLoad
    }

    // ── タイトル ──

    def title(atlas: FontAtlas, env: Env, cursor: World.TitleItem): List[Render.PlacedItem] =
        let t = theme(env);
        let s = StoryDoc.rec(env#res#story);
        let center = Layout.width(env#fit) / 2.0;
        let shade = at(0.0, 0.0, Render.vgrad(Layout.size(env#fit),
                                              { top = t#panel, bottom = Color.darken(t#panel, 0.4) }, zVeil()) |> Render.fade(0.35));
        let fit = env#fit;
        let heading = TextDraw.centered({ text = s#title, atlas = atlas, size = 64.0, color = t#ink, z = zText(), centerX = center, y = Layout.titleHeadingY(fit) });
        let sub = TextDraw.centered({ text = s#subtitle, atlas = atlas, size = 18.0, color = t#inkSeen, z = zText(), centerX = center, y = Layout.titleSubtitleY(fit) });
        let placed = WorldMenu.titleItems() |> List.zipWithIndex;
        let count = List.length(placed);
        let items = placed |> List.map(match (i, item) -> {
            let r = Layout.titleItem(fit, i, count);
            let color = if (not WorldMenu.isTitleItemOpen(item, env#saves)) dim(env) else if (item == cursor) t#accent else t#ink;
            textIn(r, label(titleLabel(item), env), atlas, Layout.titleItemTextSize(fit), color, zText())
        });
        let marker = placed |> List.find(match (_, item) -> item == cursor) |> Option.map(match (i, _) -> {
            let r = Layout.titleItem(fit, i, count);
            at(r#position#x + 50.0, r#position#y + r#size#y - 3.0, RawDraw.box({ x = r#size#x - 100.0, y = 1.0 }, t#accent, zText()) |> Render.fade(0.6))
        }) |> Option.toList;
        // WhyNot: 下に操作の案内を描かない — 項目そのものが押せる物として読め、指の端末で「クリックか Enter」は誤りになる。
        List.flatten((shade :: heading :: sub :: Nil) :: marker :: items :: Nil)

    pub def titleLabel(item: World.TitleItem): StoryDoc.Label = match item {
        case World.TitleItem.NewGame  => StoryDoc.Label.NewGame
        case World.TitleItem.Continue => StoryDoc.Label.Continue
        case World.TitleItem.LoadGame => StoryDoc.Label.LoadGame
        case World.TitleItem.Settings => StoryDoc.Label.Settings
        case World.TitleItem.Credits  => StoryDoc.Label.Credits
        case World.TitleItem.Quit     => StoryDoc.Label.Quit
    }

    // ── クレジット（実時間で下から上へ流れる） ──

    def credits(atlas: FontAtlas, env: Env, startedAt: Clock.Time[Clock.Real]): List[Render.PlacedItem] =
        let t = theme(env);
        let scrolled = Clock.since(startedAt, env#realNow) * kindOf(env)#creditsSpeed;
        let screenH = Layout.height(env#fit);
        let veil = at(0.0, 0.0, RawDraw.box(Layout.size(env#fit), t#panel, zVeil()) |> Render.fade(0.7));
        let (items, _) = CreditsDoc.rec(env#res#credits)#rows |> List.foldLeft((acc, row) -> {
            let (done, y) = acc;
            let (size, color) = match row#style {
                case CreditsDoc.Style.Heading => (26.0, t#accent)
                case CreditsDoc.Style.Body    => (19.0, t#ink)
                case CreditsDoc.Style.Small   => (13.0, t#inkSeen)
                case CreditsDoc.Style.Gap     => (0.0, t#ink)
            };
            let visible = y > -60.0 and y < screenH + 10.0 and size > 0.0;
            let placed = if (visible)
                TextDraw.centered({ text = row#text, atlas = atlas, size = size, color = color, z = zText(),
                                    centerX = Layout.width(env#fit) / 2.0, y = y }) :: done
                else done;
            (placed, y + World.creditsRowHeight(row#style))
        }, (Nil, screenH - scrolled));
        veil :: items

    // ── 画面（バックログ・セーブ・ロード・設定・隠す） ──

    /// 開いている画面。サムネはその枠の戻れる所へ戻した画面（WorldRead.screenOf）なので、ここだけ World を使う。
    def panel(res: Res.Res, atlas: FontAtlas, env: Env, w: World.World): List[Render.PlacedItem] =
        let screenOf = (mark: Saves.Mark) -> World.readOf(WorldRead.screenOf(res, mark, w));
        match w#panel {
            case World.Panel.Closed            => Nil
            case World.Panel.Hidden            => Nil
            case World.Panel.Log(offset)       => logPanel(atlas, env, World.logOf(w), offset)
            case World.Panel.SaveSlots(tab, i) =>
                slotsPanel(atlas, env, StoryDoc.Label.SaveTitle, { tabs = Saves.writableTabs(), tab = tab, cursor = i }, screenOf)
            case World.Panel.LoadSlots(tab, i) =>
                slotsPanel(atlas, env, StoryDoc.Label.LoadTitle, { tabs = Saves.tabs(), tab = tab, cursor = i }, screenOf)
            case World.Panel.Settings(at)      => settingsPanel(atlas, env, at)
            case World.Panel.Menu(cursor)      => menuPanel(atlas, env, cursor)
            case World.Panel.SaveLoadPick(cursor) => saveLoadPanel(atlas, env, cursor)
        }

    /// 画面の地・左上の見出しと下の線・右上の「戻る」・下の案内（空なら出さない）。
    def panelFrame(atlas: FontAtlas, heading: String, hint: String, env: Env): List[Render.PlacedItem] =
        let t = theme(env);
        let back = Layout.back(env#fit);
        let h = Layout.heading(env#fit);
        let ground = at(0.0, 0.0, Render.vgrad(Layout.size(env#fit),
                                               { top = Color.darken(t#panel, 0.1), bottom = t#panel }, zPanel()) |> Render.fade(0.9));
        let rule = at(h#x, Layout.rule(env#fit), RawDraw.box({ x = Layout.width(env#fit) - 2.0 * h#x, y = 1.0 }, t#accent, zPanelText()) |> Render.fade(0.35));
        let hintRow = if (String.isEmpty(hint)) Nil
            else textAt(h#x, Layout.hintY(env#fit) + 6.0, hint, atlas, captionSize(env, 12.0), Color.mix(t#ink, t#panel, 0.45), zPanelText()) :: Nil;
        ground :: rule :: textAt(h#x, h#y, heading, atlas, 28.0, t#accent, zPanelText())
            :: plate(back, isOver(back, env), env, zPanelText())
            :: textIn(back, label(StoryDoc.Label.Back, env), atlas, Layout.backTextSize(env#fit), if (isOver(back, env)) t#accent else t#ink, zPanelText() + 1)
            :: hintRow

    // ── バックログ ──

    /// バックログの 1 行の高さ（字の大きさはバックログ用に本文より小さく）。Controls がスクロールの量に使う。
    pub def logRowHeight(fit: Layout.Fit, res: Res.Res, w: World.World): Float64 = rowHeightOf(envOf(fit, res, w))

    def rowHeightOf(env: Env): Float64 =
        let k = kindOf(env);
        logSize(env) + k#lineGap * logSize(env) / k#bodySize

    def logSize(env: Env): Float64 = match env#fit {
        case Layout.Fit.Portrait(p, _) => p#logTextSize
        case _                         => kindOf(env)#bodySize * 0.8
    }

    /// 縦の画面で、項目の上に置く名前の行の高さ（名前の無い項目は 0）。横は名前を左の列に置くので 0。
    def logNameRow(env: Env, entry: World.Entry): Float64 =
        let named = match entry {
            case World.Entry.Said(line, _) => not String.isEmpty(line#speaker)
            case World.Entry.Chose(_)      => false
        };
        if (named and Layout.isPortrait(env#fit)) logSize(env) * 0.75 + 6.0 else 0.0

    /// 項目の本文（選択肢は選んだ字そのまま）。
    def entryText(entry: World.Entry): String = match entry {
        case World.Entry.Said(line, _) => line#text
        case World.Entry.Chose(text)   => text
    }

    def entryLine(entry: World.Entry): Page.Line = match entry {
        case World.Entry.Said(line, _) => line
        case World.Entry.Chose(text)   => Page.plainLine(text, "")
    }

    /// 1 項目の高さ（本文の行の数 + 項目の間）。
    def logEntryHeight(env: Env, entry: World.Entry): Float64 =
        let k = kindOf(env);
        let rows = Page.rowsOf(logSize(env), k#rubySize * logSize(env) / k#bodySize, Layout.logText(env#fit)#width, entryLine(entry));
        Int32.toFloat64(rows) * rowHeightOf(env) + 14.0 + logNameRow(env, entry)

    /// 項目ごとの (番号, 項目, 上端, 高さ)。新しい項目を下に、遡るほど上（offset 0 = 一番新しい所が一番下に見える）。
    def logPlaced(env: Env, log: List[World.Entry], offset: Float64): List[(Int32, World.Entry, Float64, Float64)] =
        let view = Layout.logView(env#fit);
        let bottom = view#position#y + view#size#y + offset;
        let (rows, _) = log |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (done, below) = acc;
            let (i, entry) = pair;
            let h = logEntryHeight(env, entry);
            ((i, entry, below - h, h) :: done, below - h)
        }, (Nil, bottom));
        rows

    /// バックログの長さと読む範囲の高さ（UiScroll の勘定へ）。
    pub def logScrollSize(fit: Layout.Fit, res: Res.Res, w: World.World): { contentPx = Float64, viewportPx = Float64 } = scrollSizeOf(envOf(fit, res, w), World.logOf(w))

    def scrollSizeOf(env: Env, log: List[World.Entry]): { contentPx = Float64, viewportPx = Float64 } =
        { contentPx = log |> List.foldLeft((sum, entry) -> sum + logEntryHeight(env, entry), 0.0),
          viewportPx = Layout.logView(env#fit)#size#y }

    /// p の下にある項目の番号（読む範囲の外・戻れない項目は None）。
    pub def logEntryAt(fit: Layout.Fit, res: Res.Res, p: { x = Float64, y = Float64 }, w: World.World): Option[Int32] =
        entryAtOf(p, envOf(fit, res, w), World.logOf(w), WorldLog.offsetOf(w))

    def entryAtOf(p: { x = Float64, y = Float64 }, env: Env, log: List[World.Entry], offset: Float64): Option[Int32] =
        if (not Layout.contains(Layout.logView(env#fit), p)) None
        else logPlaced(env, log, offset) |> List.find(match (_, entry, top, h) -> p#y >= top and p#y < top + h and WorldLog.isJumpable(entry))
                                         |> Option.map(match (i, _, _, _) -> i)

    /// バックログ: 左の列に話し手の名前、右の列に本文。選んだ選択肢は金の字と左の印。戻れる行に触れると明るくなる。
    def logPanel(atlas: FontAtlas, env: Env, log: List[World.Entry], offset: Float64): List[Render.PlacedItem] =
        let t = theme(env);
        let k = kindOf(env);
        let view = Layout.logView(env#fit);
        let text = Layout.logText(env#fit);
        let size = logSize(env);
        let rowHeight = rowHeightOf(env);
        let hovered = entryAtOf(env#pointer, env, log, offset);
        // 上の端で切れる項目は出さない（字の頭だけが線のように残る）。下の端は一番新しい項目が必ず収まる。
        let items = logPlaced(env, log, offset) |> List.filter(match (_, _, top, _) -> top >= view#position#y - 1.0 and top < view#position#y + view#size#y)
            |> List.flatMap(match (i, entry, top, h) -> {
                let lit = hovered == Some(i) and i > 0;
                let glow = if (lit) at(view#position#x, top + 2.0,
                                       RawDraw.box({ x = view#size#x, y = h - 6.0 }, Color.lighten(t#panel, 0.12), zCard()) |> Render.fade(0.7) |> Render.rounded(3.0)) :: Nil
                           else Nil;
                let nameRow = logNameRow(env, entry);
                let baseY = top + 6.0 + nameRow;
                let (name, ink) = match entry {
                    case World.Entry.Said(line, _) =>
                        let speaker = ViewText.speakerOf(line, env);
                        let n = if (String.isEmpty(line#speaker)) Nil
                                else if (nameRow > 0.0) textAt(text#x, top + 6.0, line#speaker, atlas, size * 0.75, speaker#color, zPanelText()) :: Nil
                                else textRight(Layout.logNameRight(), baseY + rowHeight - size, line#speaker, atlas, size * 0.9, speaker#color, zPanelText()) :: Nil;
                        (n, if (lit) Color.lighten(speaker#ink, 0.1) else speaker#ink)
                    case World.Entry.Chose(_) =>
                        (at(text#x - 12.0, baseY + 4.0, RawDraw.box({ x = 2.0, y = h - 22.0 - nameRow }, t#accent, zPanelText())) :: Nil, t#accent)
                };
                let body = RichText.placeRuby({ atlas = atlas, size = size, baseTint = ink, z = zPanelText(),
                                                pos = { x = text#x, y = baseY + rowHeight - size },
                                                maxWidth = text#width, lineGap = rowHeight - size },
                                              k#rubySize * size / k#bodySize, entryLine(entry)#rubies, String.length(entryText(entry)),
                                              RichText.plain(entryText(entry)) :: Nil);
                List.flatten(glow :: name :: body :: Nil)
            });
        List.flatten(panelFrame(atlas, label(StoryDoc.Label.LogTitle, env), label(StoryDoc.Label.LogHint, env), env)
                     :: Render.clippedAll(view, items) :: scrollbar(env, log, offset) :: Nil)

    /// スクロールバー（中身が読む範囲より長い時だけ）。つまみの長さは見えている割合、位置は遡った量。
    def scrollbar(env: Env, log: List[World.Entry], offset: Float64): List[Render.PlacedItem] =
        let t = theme(env);
        let track = Layout.logTrack(env#fit);
        let size = scrollSizeOf(env, log);
        if (size#contentPx <= size#viewportPx) Nil
        else {
            let h = Float64.max(28.0, track#size#y * size#viewportPx / size#contentPx);
            let top = UiScroll.topPx(size, offset) / UiScroll.maxOffsetPx(size);
            let y = track#position#y + (track#size#y - h) * top;
            at(track#position#x, track#position#y, RawDraw.box(track#size, Color.lighten(t#panel, 0.12), zPanelText()) |> Render.rounded(2.0))
            :: at(track#position#x, y, RawDraw.box({ x = track#size#x, y = h }, t#accent, zPanelText() + 1) |> Render.fade(0.8) |> Render.rounded(2.0))
            :: Nil
        }

    // ── セーブ・ロード ──

    def tabLabel(tab: Saves.Tab, env: Env): String = match tab {
        case Saves.Tab.Auto        => label(StoryDoc.Label.TabAuto, env)
        case Saves.Tab.Quick       => label(StoryDoc.Label.TabQuick, env)
        case Saves.Tab.Numbered(n) => Int32.toString(n)
    }

    /// 枠の番号の字（ページ 1〜3 は通しの No.、オートとクイックはページの名前と順）。
    def slotNumber(tab: Saves.Tab, i: Int32, env: Env): String = match tab {
        case Saves.Tab.Numbered(n) =>
            let no = (n - 1) * Saves.perPage() + i + 1;
            if (no < 10) "No.0${no}" else "No.${no}"
        case _ => "${tabLabel(tab, env)} ${i + 1}"
    }

    /// セーブ・ロードの画面: 上にページのタブ、2 列 × 3 行の枠。枠はサムネ・番号・保存した日時・場所・台詞の頭。
    /// pages = 並べるページ・今のページ・枠のカーソル、screenOf = 枠の戻れる所の画面（サムネ）。
    def slotsPanel(atlas: FontAtlas, env: Env, heading: StoryDoc.Label, pages: { tabs = List[Saves.Tab], tab = Saves.Tab, cursor = Int32 },
                   screenOf: Saves.Mark -> Option[World.Read]): List[Render.PlacedItem] =
        let t = theme(env);
        let tabs = pages#tabs |> List.zipWithIndex |> List.flatMap(match (j, tab) -> {
            let r = Layout.tab(env#fit, List.length(pages#tabs), j);
            let on = tab == pages#tab;
            let lit = on or isOver(r, env);
            let bar = if (on) at(r#position#x, r#position#y + r#size#y - 2.0, RawDraw.box({ x = r#size#x, y = 2.0 }, t#accent, zPanelText() + 1)) :: Nil else Nil;
            plate(r, lit, env, zPanelText()) :: textIn(r, tabLabel(tab, env), atlas, Layout.tabTextSize(env#fit), if (on) t#accent else if (lit) t#ink else t#inkSeen, zPanelText() + 1) :: bar
        });
        let newest = Saves.latest(env#saves);
        let cards = List.range(0, Saves.perPage()) |> List.flatMap(i -> slotCard(atlas, env, pages#tab, i, i == pages#cursor, newest, screenOf));
        List.flatten(panelFrame(atlas, label(heading, env), label(StoryDoc.Label.SlotsHint, env), env) :: tabs :: cards :: Nil)

    def slotCard(atlas: FontAtlas, env: Env, tab: Saves.Tab, i: Int32, picked: Bool, newest: Option[(Saves.Tab, Int32)],
                 screenOf: Saves.Mark -> Option[World.Read]): List[Render.PlacedItem] =
        let t = theme(env);
        let r = Layout.slot(env#fit, i);
        let lit = picked or isOver(r, env);
        let thumb = Layout.thumb(env#fit, i);
        let tx = thumb#position#x + thumb#size#x + 14.0;
        let textWidth = r#position#x + r#size#x - 12.0 - tx;
        let y = r#position#y;
        let small = captionSize(env, 13.0);
        let number = textAt(tx, y + 10.0, slotNumber(tab, i, env), atlas, small, if (lit) t#accent else t#inkSeen, zPanelText());
        let card = plate(r, lit, env, zCard());
        match Saves.slotOf(tab, i, env#saves) {
            case Some(slot) =>
                let rm = Layout.remove(env#fit, i);
                let removeMark = textIn(rm, "×", atlas, captionSize(env, 16.0), if (isOver(rm, env)) t#accent else dim(env), zPanelText());
                let date = textRight(rm#position#x - 6.0, y + 10.0, Saves.dateText(slot#savedAt), atlas, small, t#inkSeen, zPanelText());
                let placeSize = captionSize(env, 17.0);
                let place = textAt(tx, y + captionSize(env, 32.0), clipTo(textWidth, placeSize, atlas, slot#place), atlas, placeSize, t#ink, zPanelText());
                let said = if (String.isEmpty(slot#speaker)) slot#excerpt else "${slot#speaker}${slot#excerpt}";
                let excerpt = linesWithin(textWidth, small, 2, atlas, said) |> List.zipWithIndex
                    |> List.map(match (n, row) -> textAt(tx, y + captionSize(env, 62.0) + Int32.toFloat64(n) * captionSize(env, 19.0), row, atlas, small, Color.mix(t#ink, t#panel, 0.2), zPanelText()));
                let badge = if (newest == Some((tab, i))) newBadge(atlas, thumb, env) else Nil;
                List.flatten((card :: number :: removeMark :: date :: place :: excerpt) :: thumbnail(atlas, env, screenOf(slot#mark), thumb) :: badge :: Nil)
            case None =>
                let empty = at(thumb#position#x, thumb#position#y, RawDraw.box(thumb#size, Color.darken(t#panel, 0.3), zThumb())
                                   |> Render.outlineA({ color = Color.mix(t#ink, t#panel, 0.75), alpha = 0.6, width = 1.0 }));
                // 縦の画面のサムネは細いので、空きの字は右の字の列に置く。
                let emptyAt = if (Layout.isPortrait(env#fit)) textAt(tx, y + captionSize(env, 32.0), label(StoryDoc.Label.EmptySlot, env), atlas, small, dim(env), zPanelText())
                              else textIn(thumb, label(StoryDoc.Label.EmptySlot, env), atlas, small, dim(env), zPanelText());
                card :: number :: empty :: emptyAt :: Nil
        }

    /// サムネ: その枠の戻れる所へ戻した画面（WorldRead.screenOf）を、実際の画面と同じ関数で描いて枠の大きさへ縮める（字は読めなくてよい）。
    /// 縮めた画面の中の前後は元の z のまま、枠のカードより手前（zThumb から）へ持ち上げる。
    def thumbnail(atlas: FontAtlas, env: Env, screen: Option[World.Read], r: Rect2.Rect2): List[Render.PlacedItem] =
        let t = theme(env);
        let away = { pointer = { x = -1.0, y = -1.0 } | env };
        let shown = screen |> Option.map(read ->
            List.flatten(ViewStage.thumbnail(away, read#stage, not ViewStage.propsOnPage(away, read#stage)) :: thumbHudUsing(GameView.hud, away, read) :: reading(atlas, away, read) :: pageProps(away, read) :: Nil))
            |> Option.getWithDefault(Nil);
        let k = Float64.min(r#size#x / Layout.width(env#fit), r#size#y / Layout.height(env#fit));
        let small = shown |> Render.scaledAllAround(k, { x = 0.0, y = 0.0 }) |> Render.movedAll(r#position)
            |> List.map(Render.overItem(ViewStage.mapZ(z -> z + zThumb()))) |> Render.clippedAll(r);
        // 写真がまだ届いていない枠は、暗い地（backdropsIn が写真を描かない）に待ちの印。
        let photoMissing = screen |> Option.exists(read -> stagePhotoMissing(env, read#stage));
        let mark = if (photoMissing) loadingMark(atlas, env, t#loadingMark, r, { x = 30.0, y = 12.0 }, 0.6, zThumbTop() + 1) else Nil;
        List.flatten(small :: frameOf(r, Color.mix(t#ink, t#panel, 0.6), zThumbTop()) :: mark :: Nil)

    /// 舞台の写真が、まだ届いていない後回しの絵か。
    def stagePhotoMissing(env: Env, stage: Stage.Stage): Bool =
        Stage.shownShot(env#res#backdrops, stage) |> Option.flatMap(shot -> BackdropDoc.textureOf(shot#photo, env#res#backdrops))
            |> Option.exists(texture -> Set.memberOf(texture, env#res#missing))

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

    def newBadge(atlas: FontAtlas, thumb: Rect2.Rect2, env: Env): List[Render.PlacedItem] =
        let t = theme(env);
        let r = { position = { x = thumb#position#x + 4.0, y = thumb#position#y + 4.0 }, size = { x = 38.0, y = 17.0 } };
        at(r#position#x, r#position#y, RawDraw.box(r#size, t#accent, zThumbTop() + 1) |> Render.rounded(2.0))
        :: textIn(r, label(StoryDoc.Label.NewBadge, env), atlas, 11.0, t#panel, zThumbTop() + 2) :: Nil

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

    /// 設定: 左の列に文章、右の列に音と画面。スライダー・2 つから選ぶボタン・初期設定に戻す。左下に文字の速さとウィンドウの濃さの見本。
    def settingsPanel(atlas: FontAtlas, env: Env, cursor: World.Setting): List[Render.PlacedItem] =
        let t = theme(env);
        let groups = (0 :: 1 :: Nil) |> List.flatMap(col -> {
            let g = Layout.group(env#fit, col);
            let name = if (col == 0) StoryDoc.Label.GroupText else StoryDoc.Label.GroupSound;
            textAt(g#x, g#y, label(name, env), atlas, captionSize(env, 14.0), t#accent, zPanelText())
            :: at(g#x, g#y + 22.0, RawDraw.box({ x = Layout.groupRuleWidth(env#fit), y = 1.0 }, Color.mix(t#ink, t#panel, 0.7), zPanelText()) |> Render.fade(0.6)) :: Nil
        });
        let rows = WorldSettings.settings() |> List.zipWithIndex
            |> List.flatMap(match (i, setting) -> settingRow(atlas, env, i, setting, setting == cursor));
        List.flatten(panelFrame(atlas, label(StoryDoc.Label.SettingsTitle, env), "", env) :: groups :: rows :: preview(atlas, env) :: Nil)

    def settingRow(atlas: FontAtlas, env: Env, i: Int32, setting: World.Setting, picked: Bool): List[Render.PlacedItem] =
        let t = theme(env);
        let config = Saves.configOf(env#saves);
        let fit = env#fit;
        let text = Layout.settingText(fit);
        let row = Layout.settingRow(fit, i);
        let focus = if (picked) at(row#position#x - 8.0, row#position#y, RawDraw.box({ x = 2.0, y = row#size#y }, t#accent, zPanelText())) :: Nil else Nil;
        let name = textAt(row#position#x + 4.0, row#position#y + text#nameTop, label(settingLabel(setting), env), atlas, text#name,
                          if (picked) t#accent else t#ink, zPanelText());
        match setting {
            case World.Setting.Slider(slider) =>
                let range = WorldSettings.rangeOf(slider, env#res#kind);
                let bar = Layout.settingBar(fit, i);
                let v = WorldSettings.levelOf(slider, config);
                let filled = if (range#max > range#min) (v - range#min) / (range#max - range#min) else 0.0;
                let knobX = bar#position#x + bar#size#x * filled;
                List.flatten(focus :: (name ::
                    at(bar#position#x, bar#position#y, RawDraw.box(bar#size, Color.lighten(t#panel, 0.18), zPanelText()) |> Render.rounded(3.0))
                    :: at(bar#position#x, bar#position#y, RawDraw.box({ x = bar#size#x * filled, y = bar#size#y }, t#accent, zPanelText() + 1) |> Render.rounded(3.0))
                    :: RawDraw.circleAt({ x = knobX, y = bar#position#y + bar#size#y / 2.0 }, if (picked) 8.0 else 7.0, if (picked) t#accent else t#ink, zPanelText() + 2)
                    :: textRight(row#position#x + row#size#x, row#position#y + text#valueTop, valueText(slider, v, env), atlas, text#value, t#inkSeen, zPanelText())
                    :: Nil) :: Nil)
            case World.Setting.Pair(pair) =>
                let chosen = WorldSettings.sideOf(pair, config);
                let (left, right) = WorldSettings.pairLabels(pair);
                let buttons = Layout.sides() |> List.flatMap(side -> {
                    let r = Layout.settingSide(fit, i, side);
                    let on = side == chosen;
                    plate(r, on or isOver(r, env), env, zPanelText())
                    :: textIn(r, label(if (side == Layout.Side.Left) left else right, env), atlas, text#pair, if (on) t#accent else t#inkSeen, zPanelText() + 1) :: Nil
                });
                List.flatten(focus :: (name :: Nil) :: buttons :: Nil)
            case World.Setting.Reset =>
                let r = Layout.settingAction(fit, i);
                List.append(focus, plate(r, picked or isOver(r, env), env, zPanelText()) :: textIn(r, label(StoryDoc.Label.Reset, env), atlas, text#action, t#ink, zPanelText() + 1) :: Nil)
        }

    /// 見本: ウィンドウの濃さで地を敷き、文字の速さで見本の文を流し続ける（実時間。読み終えて少し置いてから頭へ戻る）。
    def preview(atlas: FontAtlas, env: Env): List[Render.PlacedItem] =
        Layout.preview(env#fit) |> Option.map(r -> previewIn(atlas, env, r)) |> Option.getWithDefault(Nil)

    def previewIn(atlas: FontAtlas, env: Env, r: Rect2.Rect2): List[Render.PlacedItem] =
        let t = theme(env);
        let k = kindOf(env);
        let sample = label(StoryDoc.Label.Preview, env);
        let cps = Saves.configOf(env#saves)#cps;
        let length = Int32.toFloat64(String.length(sample));
        let cycle = length / Float64.max(1.0, cps) + 1.6;
        let elapsed = realSeconds(env) - Float64.floor(realSeconds(env) / cycle) * cycle;
        let visible = if (KindDoc.isNoWait(cps, env#res#kind)) String.length(sample)
                      else Float64.tryToInt32(Float64.floor(elapsed * cps)) |> Option.getWithDefault(0) |> Int32.min(String.length(sample));
        let size = 16.0;
        at(r#position#x, r#position#y,
           Render.vgrad(r#size, { top = t#panel, bottom = Color.darken(t#panel, 0.3) }, zCard()) |> Render.fade(windowAlpha(env))
               |> Render.outlineA({ color = t#accent, alpha = 0.35, width = 1.0 }) |> Render.rounded(3.0))
        :: RichText.placeRuby({ atlas = atlas, size = size, baseTint = t#ink, z = zPanelText(),
                                pos = { x = r#position#x + 16.0, y = r#position#y + Layout.previewTextInset(env#fit) },
                                maxWidth = r#size#x - 32.0, lineGap = k#lineGap * size / k#bodySize },
                              k#rubySize * size / k#bodySize, Nil, visible, RichText.plain(sample) :: Nil)

    pub def settingLabel(setting: World.Setting): StoryDoc.Label = match setting {
        case World.Setting.Slider(World.Slider.TextSpeed)      => StoryDoc.Label.TextSpeed
        case World.Setting.Slider(World.Slider.AutoWait)       => StoryDoc.Label.AutoWait
        case World.Setting.Slider(World.Slider.MasterVolume)   => StoryDoc.Label.MasterVolume
        case World.Setting.Slider(World.Slider.AmbienceVolume) => StoryDoc.Label.AmbienceVolume
        case World.Setting.Slider(World.Slider.MusicVolume)    => StoryDoc.Label.MusicVolume
        case World.Setting.Slider(World.Slider.SeVolume)       => StoryDoc.Label.SeVolume
        case World.Setting.Slider(World.Slider.WindowAlpha)    => StoryDoc.Label.WindowAlpha
        case World.Setting.Pair(World.Pair.SkipScope)          => StoryDoc.Label.SkipScope
        case World.Setting.Pair(World.Pair.AfterChoice)        => StoryDoc.Label.AfterChoice
        case World.Setting.Pair(World.Pair.Display)            => StoryDoc.Label.Display
        case World.Setting.Reset                               => StoryDoc.Label.Reset
    }

    def valueText(slider: World.Slider, v: Float64, env: Env): String =
        let whole = x -> Float64.tryToInt32(Float64.round(x)) |> Option.getWithDefault(0) |> Int32.toString;
        match slider {
            case World.Slider.TextSpeed => if (KindDoc.isNoWait(v, env#res#kind)) "ノーウェイト" else "${whole(v)} 字/秒"
            case World.Slider.AutoWait  => "${Float64.toString(Float64.round(v * 10.0) / 10.0)} 秒"
            case _                      => "${whole(v * 100.0)}%"
        }

    // ── 確認のウィンドウ ──

    def askLayer(atlas: FontAtlas, env: Env, ask: Option[(World.Ask, World.Answer)]): List[Render.PlacedItem] =
        match ask {
            case None => Nil
            case Some((asked, cursor)) =>
                let t = theme(env);
                let box = Layout.askBox(env#fit);
                let center = box#position#x + box#size#x / 2.0;
                let (question, note) = askText(asked);
                let shade = at(0.0, 0.0, RawDraw.box(Layout.size(env#fit), Color.darken(t#panel, 0.4), zAsk()) |> Render.fade(0.6));
                let ground = at(box#position#x, box#position#y,
                                Render.vgrad(box#size, { top = Color.lighten(t#panel, 0.05), bottom = t#panel }, zAsk() + 1)
                                    |> Render.outlineA({ color = t#accent, alpha = 0.6, width = 1.0 }) |> Render.rounded(4.0));
                let line = TextDraw.centered({ text = label(question, env), atlas = atlas, size = 19.0, color = t#ink, z = zAsk() + 2,
                                               centerX = center, y = box#position#y + 40.0 });
                let sub = note |> Option.map(n -> TextDraw.centered({ text = label(n, env), atlas = atlas, size = captionSize(env, 13.0), color = t#inkSeen,
                                                                       z = zAsk() + 2, centerX = center, y = box#position#y + 74.0 }) :: Nil)
                              |> Option.getWithDefault(Nil);
                let answers = (World.Answer.Yes :: World.Answer.No :: Nil) |> List.flatMap(answer -> {
                    let r = Layout.askButton(env#fit, WorldMenu.sideOf(answer));
                    let on = answer == cursor;
                    plate(r, on, env, zAsk() + 2)
                    :: textIn(r, label(if (answer == World.Answer.Yes) StoryDoc.Label.Yes else StoryDoc.Label.No, env), atlas, Layout.askButtonTextSize(env#fit),
                              if (on) t#accent else t#ink, zAsk() + 3) :: Nil
                });
                List.flatten((shade :: ground :: line :: Nil) :: sub :: answers :: Nil)
        }

    /// 尋ねる言葉と、下に添える注意（進行が失われる時）。
    def askText(ask: World.Ask): (StoryDoc.Label, Option[StoryDoc.Label]) = match ask {
        case World.Ask.Overwrite(_, _) => (StoryDoc.Label.AskOverwrite, None)
        case World.Ask.Delete(_, _)    => (StoryDoc.Label.AskDelete, None)
        case World.Ask.Load(_, _)      => (StoryDoc.Label.AskLoad, Some(StoryDoc.Label.LostNote))
        case World.Ask.QuickLoad       => (StoryDoc.Label.AskLoad, Some(StoryDoc.Label.LostNote))
        case World.Ask.Jump(_)         => (StoryDoc.Label.AskJump, None)
        case World.Ask.ToTitle         => (StoryDoc.Label.AskToTitle, Some(StoryDoc.Label.LostNote))
        case World.Ask.Quit            => (StoryDoc.Label.AskQuit, None)
        case World.Ask.Reset           => (StoryDoc.Label.AskReset, None)
    }

    // ── 知らせ ──

    /// シナリオの直し（Starts の talk の edit.*）で開いた間ずっと、画面の上の端に細いバナーを出す。前の文が合わず当てなかった行があればそれも言う。
    // WhyNot: 画面を覆う幕にしない — 直した台詞を遊んで確かめる所なので、文章のウィンドウとボタンに被せない。
    def editedBanner(atlas: FontAtlas, env: Env): List[Render.PlacedItem] =
        let edits = env#res#scriptEdits;
        if (not edits#edited) Nil
        else {
            let t = theme(env);
            let width = Layout.width(env#fit);
            let skipped = if (edits#skipped == 0) Nil else "${label(StoryDoc.Label.ScriptEditsSkipped, env)}（${Int32.toString(edits#skipped)} 行）" :: Nil;
            let notices = label(StoryDoc.Label.ScriptEdited, env) :: skipped;
            let (rows, size) = bannerRows((text, s) -> TextDraw.width(text, atlas, s), width - 16.0, captionSize(env, 13.0), notices);
            let lineHeight = size + 4.0;
            let height = lineHeight * Int32.toFloat64(List.length(rows)) + 5.0;
            let ground = at(0.0, 0.0, Render.vgrad({ x = width, y = height }, { top = Color.darken(t#panel, 0.2), bottom = t#panel }, zBanner()) |> Render.fade(0.9));
            let rim = at(0.0, height - 1.0, RawDraw.box({ x = width, y = 1.0 }, t#accent, zBanner() + 1) |> Render.fade(0.7));
            let texts = rows |> List.zipWithIndex |> List.map(match (i, row) ->
                TextDraw.centered({ text = row, atlas = atlas, size = size, color = t#accent,
                                    z = zBanner() + 2, centerX = width / 2.0, y = 4.0 + lineHeight * Int32.toFloat64(i) }));
            ground :: rim :: texts
        }

    /// バナーに出す行と字の大きさ。知らせを「。」でつないで room に入れば 1 行、入らなければ知らせごとに 1 行、
    /// それでも一番長い行が room を越えれば、その行が room に収まるまで字を縮める。measure = (字, 大きさ) → 幅。
    pub def bannerRows(measure: (String, Float64) -> Float64, room: Float64, size: Float64, notices: List[String]): (List[String], Float64) =
        let joined = String.intercalate("。", notices);
        if (measure(joined, size) <= room) (joined :: Nil, size)
        else {
            let widest = notices |> List.map(n -> measure(n, size)) |> List.maximum |> Option.getWithDefault(0.0);
            if (widest <= room) (notices, size) else (notices, size * room / widest)
        }

    def toast(atlas: FontAtlas, env: Env, shown: Option[String]): List[Render.PlacedItem] =
        match shown {
            case Some(text) =>
                let t = theme(env);
                let width = TextDraw.width(text, atlas, 14.0) + 32.0;
                let r = { position = { x = Layout.width(env#fit) - 32.0 - width, y = if (Layout.isPortrait(env#fit)) Layout.rule(env#fit) + 12.0 else 20.0 }, size = { x = width, y = 32.0 } };
                at(r#position#x, r#position#y, RawDraw.box(r#size, t#panel, zToast()) |> Render.fade(0.88)
                                                   |> Render.outlineA({ color = t#accent, alpha = 0.5, width = 1.0 }) |> Render.rounded(4.0))
                :: textIn(r, text, atlas, 14.0, t#accent, zToast() + 1) :: Nil
            case None => Nil
        }
}
