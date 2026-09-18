// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
// 場面は雨の夜の書斎: 壁・雨の窓・絵が消えた額縁（ドット絵）・館の灯り。
// 疑うたびに灯りが消え、部屋には暗くするオーバーレイが重なる（濃さは novel.kind.json の dim）。
// ダイアログと選択肢の枠は ui.json（UiRender）、本文の文字送りは NovelKit.body が描く。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「雨の夜の書斎。光は灯りの周りだけで、そこから離れるほど部屋は闇に沈む」。
//   色は 3 つ: 沈んだ藍 / 灯りの金 / 雨の窓の青。
//   やらないこと: 部屋を一様な明るさで塗らない（どの面も、灯りに近い側と遠い側で濃さが違う）。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「層に分けて、各層に役割を
// 持たせる」組み方の方で、色や効果ではない。別の作り方の例は `.claude/skills/visual-dict`。
//
// ── 画面の層（奥から手前へ）──
//   壁（縦のグラデ）→ 床（縦のグラデ + 灯りの映り込み）→ 雨の窓（すじが落ちる）
//   → 額縁の落ち影 → 額縁 → 灯り（炎が揺れる）→ 灯りの中を舞う埃 → 暗くするオーバーレイ → 表紙
//   ダイアログ・本文・エラーバナーは withHudView 側（hud）— 部屋の z に関わらず必ず手前
mod View {

    // ── z 層（部屋 0..9 / 額縁 10 / 灯り 20 / 暗くするオーバーレイ 50 / 表紙 60。UI は ui.json 側で 100+） ──

    def zRoom(): Int32 = 0
    def zWall(): Int32 = 1
    def zWindow(): Int32 = 2
    def zTrace(): Int32 = 9
    def zFrameShadow(): Int32 = 8
    def zFrame(): Int32 = 10
    def zLamp(): Int32 = 20
    def zDust(): Int32 = 25
    def zVeil(): Int32 = 50
    def zTitle(): Int32 = 60

    /// スプライトの格子は 1 セル = 4px で描く（16×12 の額縁 = 64×48px）。
    def px(): Int32 = 4

    pub def frame(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        List.flatten(
               room(w)
            :: emptyFrame(w)
            :: lamps(w)
            :: dust(w)
            :: veil(w)
            :: title(ctx#atlas, w)
            :: Nil)

    /// 画面固定の絵（ダイアログ・選択肢・本文・エラーバナー）。App.withHudView へ繋ぐ —
    /// world 側の z がどれだけ大きくても、読ませたい文字は必ず手前に出る。
    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        List.flatten(
               UiRender.itemsWith(_ -> ctx#atlas, _ -> None, w#ui, ctx#visible#size)
            :: NovelKit.body(ctx#atlas, ThemeDoc.rec(w#theme)#ink,
                   { size = KindDoc.rec(w#kind)#bodySize, lineGap = KindDoc.rec(w#kind)#bodyGap },
                   w#ui, w#kit)
            :: TextDraw.errorBanner(ctx#atlas, w#docError)
            :: Nil)

    // ── 部屋（壁・床・雨の窓） ──

    /// 壁と床の境目（design px）。
    def wallBottom(): Float64 = 190.0

    /// 壁 → 床 → 幅木 → 雨の窓。壁も床も一様には塗らない —
    /// 灯りは天井の近くにあるので、壁は上ほど明るく、床は奥（上）ほど明るい。
    /// 平らな 1 色で塗ると、部屋ではなく「色の付いた四角」に見える。
    def room(w: World.World): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let floorTop = wallBottom();
           { at = { x = 0.0, y = 0.0 },
             item = RawDraw.box({ x = World.width(), y = World.height() }, theme#bg, zRoom()) }
        :: { at = { x = 0.0, y = 0.0 },
             item = Render.vgrad({ x = World.width(), y = floorTop },
                 { top = ThemeDoc.lighten(theme#wall, 0.14),
                   bottom = ThemeDoc.darken(theme#wall, 0.30) }, zWall()) }
        // 壁の下を bg のまま残さない — 背景色が覗くと部屋の底が抜けて見える。
        :: { at = { x = 0.0, y = floorTop },
             item = Render.vgrad({ x = World.width(), y = World.height() - floorTop },
                 { top = ThemeDoc.darken(theme#wall, 0.18),
                   bottom = ThemeDoc.darken(theme#wall, 0.55) }, zWall()) }
        // 幅木。暗い床と暗い壁だけでは境目が立たず、床を敷いたことが伝わらない。
        :: { at = { x = 0.0, y = floorTop - 2.0 },
             item = RawDraw.box({ x = World.width(), y = 2.0 },
                               ThemeDoc.lighten(theme#wall, 0.25), zWall() + 1) }
        :: List.append(window(w), lightCones(w))

    /// 灯りが壁を照らす広いにじみ（ついている灯りの下だけ）。灯りそのものの glow より
    /// 大きく薄くして、壁に光が「当たっている」面を作る。
    /// 三角の光線として描かないのは、縁が立つと舞台照明に見えて部屋の空気が消えるため。
    def lightCones(w: World.World): List[Render.PlacedItem] =
        let lit = World.lampsLit(w);
        let count = StoryDoc.rec(w#story)#lamps;
        List.range(0, count) |> List.flatMap(i ->
            if (i >= lit) Nil
            else Render.glowAt({ x = lampX(count, i), y = 74.0 }, 96.0, ThemeDoc.rec(w#theme)#accent,
                     { alpha = 0.10, blend = DrawCmd.BlendMode.Add }, zWall() + 2))

    /// 雨の窓。枠は壁の派生色、雨すじは Hash01 で決定的に散らす（保存も乱数の種も持たない）。
    def window(w: World.World): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let frameColor = ThemeDoc.lighten(theme#wall, 0.18);
        let paneAt = { x = 336.0, y = 38.0 };
        let paneSize = { x = 88.0, y = 104.0 };
        List.flatten(
               border(paneAt, paneSize, 4.0, frameColor, zWindow())
            :: ({ at = paneAt, item = RawDraw.box(paneSize, theme#window, zWindow()) } :: Nil)
            :: ({ at = { x = paneAt#x + paneSize#x / 2.0 - 2.0, y = paneAt#y },
                  item = RawDraw.box({ x = 4.0, y = paneSize#y }, frameColor, zWindow() + 1) } :: Nil)
            :: rain(paneAt, paneSize, w)
            :: Nil)

    /// 矩形のまわりの枠線 4 本。
    def border(at: Vec2.Vec2, size: Vec2.Vec2, thickness: Float64,
               color: Color, z: Int32): List[Render.PlacedItem] =
           { at = { x = at#x - thickness, y = at#y - thickness },
             item = RawDraw.box({ x = size#x + thickness * 2.0, y = thickness }, color, z) }
        :: { at = { x = at#x - thickness, y = at#y + size#y },
             item = RawDraw.box({ x = size#x + thickness * 2.0, y = thickness }, color, z) }
        :: { at = { x = at#x - thickness, y = at#y },
             item = RawDraw.box({ x = thickness, y = size#y }, color, z) }
        :: { at = { x = at#x + size#x, y = at#y },
             item = RawDraw.box({ x = thickness, y = size#y }, color, z) }
        :: Nil

    /// 雨すじ。本数と明るさは色票（novel.theme.json）から、i 番目の位置・長さ・速さは
    /// 番号と時刻だけから導く（どこにも保存しない = 巻き戻しても同じ絵）。
    /// 窓の外へはみ出さないよう、ガラスの高さで折り返す。
    def rain(paneAt: Vec2.Vec2, paneSize: Vec2.Vec2, w: World.World): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let streakColor = ThemeDoc.lighten(theme#window, theme#rainGlow);
        Fx.derive(theme#rainCount, w#t, (_i, rand, t) -> {
            let len = 12.0 + rand(2) * 20.0;
            let speed = 40.0 + rand(3) * 70.0;
            let travel = paneSize#y + len;
            let y = Num.wrapTo(travel, rand(1) * travel + t * speed) - len;
            { at = { x = paneAt#x + 4.0 + rand(0) * (paneSize#x - 8.0), y = paneAt#y + y },
              item = RawDraw.box({ x = 1.0, y = len }, streakColor, zWindow() + 1)
                  |> Render.clipped({ position = paneAt, size = paneSize }) }
        })

    // ── 絵が消えた額縁（ドット絵。内側に「絵があった跡」が透ける） ──

    def frameTopLeft(): Vec2.Vec2 = { x = 118.0, y = 64.0 }

    def emptyFrame(w: World.World): List[Render.PlacedItem] =
        let topLeft = frameTopLeft();
        let cell = Int32.toFloat64(px());
        // 絵があった跡: 長く飾られて壁が焼けなかった、ひとまわり明るい矩形。
        let trace = { at = { x = topLeft#x + cell * 2.0, y = topLeft#y + cell * 2.0 },
                      item = RawDraw.box({ x = cell * 12.0, y = cell * 8.0 },
                                        ThemeDoc.lighten(ThemeDoc.rec(w#theme)#wall, 0.08), zTrace()) };
        // 壁に落ちる影（右下へずらした薄い闇）。額縁が壁から浮いて見える。
        let shadow = { at = { x = topLeft#x + 5.0, y = topLeft#y + 6.0 },
                       item = RawDraw.box({ x = cell * 16.0, y = cell * 12.0 },
                                         ThemeDoc.darken(ThemeDoc.rec(w#theme)#wall, 0.6), zFrameShadow())
                           |> Render.fade(0.45) };
        // 作ったアトラスから 1 コマ = 1 クアッドで貼る（PxSprite.draw は 1 コマを画素ぶんの
        // 四角に開くので、この額縁だけで毎フレーム百個規模になる）。作る所は World.bakedOf。
        let items = PxSprite.drawQuad(w#sprites, w#atlas, World.atlasName(),
            "frame", "idle", topLeft, false, px(), zFrame());
        if (List.isEmpty(items))
            // fail-open: スプライトが無い・読めないときは差し色の枠線だけ。
            shadow :: trace :: border(topLeft, { x = cell * 16.0, y = cell * 12.0 }, cell,
                            ThemeDoc.rec(w#theme)#accent, zFrame())
        else
            shadow :: trace :: items

    // ── 館の灯り（疑うたびに右からひとつ消える） ──

    def lamps(w: World.World): List[Render.PlacedItem] =
        let count = StoryDoc.rec(w#story)#lamps;
        let lit = World.lampsLit(w);
        List.range(0, count) |> List.flatMap(i ->
            // 灯りごとに揺れの位相をずらす（そろって明滅すると機械に見える）。
            lamp({ x = lampX(count, i), litNow = i < lit,
                   flicker = 0.82 + 0.18 * Sway.wave(w#t, Int32.toFloat64(i) * 0.37, 1.9) },
                 ThemeDoc.rec(w#theme)))

    /// i 番目の灯りの x（壁の上に等間隔。1 つなら真ん中）。
    def lampX(count: Int32, i: Int32): Float64 =
        if (count <= 1) World.width() / 2.0
        else 80.0 + Int32.toFloat64(i) * (World.width() - 160.0) / Int32.toFloat64(count - 1)

    /// 灯りひとつ: 腕木 + 火屋。ついていれば glow（加算の光球）をまとい、炎の強さが揺れる。
    /// 同じ型の値が並ぶので名前で渡す。
    def lamp(spec: { x = Float64, litNow = Bool, flicker = Float64 },
             theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        let x = spec#x;
        let head = { x = x - 4.0, y = 28.0 };
        let arm = { at = { x = x - 2.0, y = 36.0 },
                    item = RawDraw.box({ x = 4.0, y = 10.0 },
                                      ThemeDoc.lighten(theme#wall, 0.1), zLamp()) };
        let headColor = if (spec#litNow) ThemeDoc.lighten(theme#accent, 0.3 * spec#flicker)
                        else ThemeDoc.lighten(theme#bg, 0.08);
        let headBox = { at = head, item = RawDraw.box({ x = 8.0, y = 8.0 }, headColor, zLamp() + 1) };
        let glow = if (spec#litNow)
            Render.glowAt({ x = x, y = 32.0 }, 36.0 * spec#flicker, theme#accent,
                          { alpha = 0.32 * spec#flicker, blend = DrawCmd.BlendMode.Add }, zLamp() + 2)
        else Nil;
        arm :: headBox :: glow

    // ── 灯りの中を舞う埃 ──

    /// ついている灯りの下だけ、ゆっくり昇る細かい粒。どこにも保存せず、番号と時刻だけから
    /// 計算する（巻き戻しても同じ絵）。部屋に空気があることを、粒 1 つで見せる。
    def dust(w: World.World): List[Render.PlacedItem] =
        let lit = World.lampsLit(w);
        let count = StoryDoc.rec(w#story)#lamps;
        List.range(0, count) |> List.flatMap(i ->
            if (i >= lit) Nil
            else {
                let cx = lampX(count, i);
                Fx.derive(6, w#t + Int32.toFloat64(i) * 3.1, (_k, rand, t) -> {
                    let rise = 46.0;
                    let y = 88.0 - Num.wrapTo(rise, rand(1) * rise + t * 7.0);
                    let x = cx - 16.0 + rand(0) * 32.0 + Sway.wave(t, rand(2), 0.4) * 4.0;
                    RawDraw.circleAt({ x = x, y = y }, 0.7 + rand(3) * 0.6,
                            ThemeDoc.lighten(ThemeDoc.rec(w#theme)#accent, 0.35), zDust())
                        |> Render.overItem(item -> item
                            |> Render.fade(0.10 + rand(4) * 0.16)
                            |> Render.blended(DrawCmd.BlendMode.Add))
                })
            })

    // ── 暗くするオーバーレイ（消えた灯りの数 × dim の濃さで部屋が沈む） ──

    def veil(w: World.World): List[Render.PlacedItem] =
        let alpha = Float64.min(1.0, Int32.toFloat64(w#lightsOut) * KindDoc.rec(w#kind)#dim);
        if (alpha <= 0.0) Nil
        else { at = { x = 0.0, y = 0.0 },
               item = RawDraw.box({ x = World.width(), y = World.height() },
                                 { r = 0.02, g = 0.02, b = 0.05 }, zVeil())
                   |> Render.fade(alpha) } :: Nil

    // ── 表紙（文言はすべて台本 Doc から: 事件の名前・一行・はじめ方のヒント） ──

    def title(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Story => Nil
            case World.Phase.Title =>
                   TextDraw.centered({ text = StoryDoc.rec(w#story)#title, atlas = atlas, size = 30.0,
                                       color = ThemeDoc.lighten(ThemeDoc.rec(w#theme)#accent, 0.2),
                                       z = zTitle(), centerX = World.width() / 2.0, y = 118.0 })
                :: TextDraw.centered({ text = StoryDoc.rec(w#story)#subtitle,
                                       atlas = atlas, size = 10.0, color = ThemeDoc.rec(w#theme)#ink,
                                       z = zTitle(), centerX = World.width() / 2.0, y = 160.0 })
                :: TextDraw.centered({ text = StoryDoc.rec(w#story)#hint, atlas = atlas, size = 9.0,
                                       color = ThemeDoc.lighten(ThemeDoc.rec(w#theme)#bg, 0.35),
                                       z = zTitle(), centerX = World.width() / 2.0, y = 196.0 })
                :: Nil
        }
}
