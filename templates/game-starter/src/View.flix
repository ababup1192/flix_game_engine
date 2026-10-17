// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// ── 画面の層（奥から手前へ）──
// 単色の四角を 1 枚敷いただけの画面は未完成、というのがこのエンジンの決まり
// （.claude/rules/drawing.md の「絵の下限」= 面に階調か質感 / 主役が背景から分離 / 層が分かれている /
// 時間が流れている、の 4 つ）。
//
// **ここの見た目は数ある画風の 1 つでしかない。** 真似してほしいのは「層に分けて、
// 各層に役割を持たせる」組み方の方で、色や効果ではない。新しいゲームでは画風を先に決めて
// AGENTS.local.md に書き、この層構成ごと作り替えてよい（画風の決め方と別の作り方の例は
// engine の `docs/art-ref/visual-dict.md`）。
//
// 重なりは根の SortingLayer.compose が決める（層の表は ZOrder）。場面（Layer.Scene）の中は
// ZStack.of に積んだ順（奥から手前）で、z の数は書かない。積んだ部品と、それが受け持つ性質:
//   backdrop … 背景（宣言シェーダーの面）        → 面に階調と質感・時間が流れる
//   halo     … 主人公のまわりの背景を沈める      → 主役が背景から分離
//   hero     … 主人公（ドット絵 + PxShade の仕上げ）→ 主役が背景から分離・時間が流れる
//   dust     … 舞う塵                            → 時間が流れる
// 画面の縁の枠（frameBorder）は動かないので App.withStaticLayer で 1 度だけ GPU に作る（Main）。
// 終了の確認の窓（quitPrompt）は Layer.Prompt に置き、場面のどれよりも手前に出る。
mod View {

    use fge::{
        App, Color, DrawCmd, Fx, Num, PxSprite, RawDraw, Render, SortingLayer, Sway, TextDraw,
        Vec2, ZStack
    }
    use ZOrder.Layer

    pub def frame(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let scene = ZStack.of(
            ZStack.leaf(backdrop(w) :: Nil)
                :: ZStack.leaf(halo(w))
                :: ZStack.leaf(hero(w))
                :: ZStack.leaf(dust(w)) :: Nil);
        SortingLayer.compose(ctx, (Layer.Scene, scene) :: (Layer.Prompt, ZStack.leaf(quitPrompt(ctx, w))) :: Nil)

    // ── 背景（宣言シェーダーの面） ──

    /// 画素ごとの計算で塗る面。単色の box の代わりで、上下の色の移り変わりに
    /// 雲のムラが混ざり、ゆっくり流れる。何がどう効くかは Doc の note と
    /// engine の `docs/shader-doc.md` を参照。
    def backdrop(w: World.World): Render.PlacedItem =
        Render.shaderFill(w#shader,
            { position = { x = 0.0, y = 0.0 },
              size = { x = World.width(), y = World.height() } },
            w#t, 0)

    // ── 主人公のまわりを沈める ──

    /// 主役の後ろだけ背景を暗く落とす（乗算で重ねる）。主役そのものを明るくするより、
    /// 周りを沈めたほうが背景の絵を殺さずに輪郭が立つ。
    /// 色は黒でなく寒色へ近づけた暗い色にする（黒で沈めると絵が濁る）。
    def halo(w: World.World): List[Render.PlacedItem] =
        Render.glowAt({ x = w#x, y = w#y }, World.heroBox(w)#x * 1.7,
            Color.cool(Color.darken(ThemeDoc.rec(w#theme)#bg, 0.3), 0.1),
            { alpha = 0.45, blend = DrawCmd.BlendMode.Multiply }, 0)

    // ── 主人公（ドット絵 + 塗りの仕上げ） ──

    /// 絵は差し色 1 色で平らに塗ってあり、ふち光と影は World が読み込み時に
    /// PxShade で乗せている（走行中の負荷は増えない）。
    /// 立ち止まっていても少し上下する — 画面を完全に静止させないため。
    ///
    /// 描くのは drawQuad（作ったアトラスから 1 コマ = 1 クアッド）。画素ぶんの四角に開く
    /// PxSprite.draw もあるが、そちらは組む数が絵の大きさに比例するので、キャラが増えた
    /// 瞬間に重くなる。作る所と、なぜ作るかは World.bakedOf。
    def hero(w: World.World): List[Render.PlacedItem] =
        let box = World.heroBox(w);
        let bob = Sway.wave(w#t, 0.0, 1.7) * 1.5;
        let topLeft = { x = w#x - box#x / 2.0, y = w#y - box#y / 2.0 + bob };
        let items = PxSprite.drawQuad(w#sprites, w#atlas, World.atlasName(),
            "hero", "idle", topLeft, false, World.spriteScale(), 0);
        if (List.isEmpty(items))
            // fail-open: スプライトが無い・読めないときは差し色の四角。
            { at = topLeft, item = RawDraw.box(box, ThemeDoc.rec(w#theme)#accent, 0) } :: Nil
        else
            items

    // ── 舞う塵 ──

    /// 粒はどこにも保存せず、番号と時刻だけから計算する（巻き戻しても同じ絵）。
    /// 数や速さを Doc から調整したくなったら fx.json（FxDoc）へ移す。
    def dust(w: World.World): List[Render.PlacedItem] =
        let color = ThemeDoc.lighten(ThemeDoc.rec(w#theme)#accent, 0.6);
        Fx.derive(22, w#t, (_i, rand, t) -> {
            let speed = 5.0 + rand(1) * 12.0;
            let x = Num.wrapTo(World.width(), rand(0) * World.width() + t * speed);
            let y = rand(2) * World.height() + Sway.wave(t, rand(3), 0.35) * 7.0;
            RawDraw.circleAt({ x = x, y = y }, 0.8 + rand(4) * 1.3, color, 0)
                |> Render.overItem(Render.fade(0.20 + rand(5) * 0.30))
        })

    // ── 画面の縁の枠（静的な層） ──

    /// 画面の四辺に敷く細い枠。動かないので Main が App.withStaticLayer で 1 度だけ GPU に作り、
    /// 毎フレームは組まない（作り直すのは鍵 staticKey が変わった時 = 色を変えた時だけ）。
    /// 静的な層は compose を通らないので、z は層の表から引く（Layer.Frame = 場面のどれよりも手前・窓より奥）。
    pub def frameBorder(w: World.World): List[Render.PlacedItem] =
        let color = Color.darken(ThemeDoc.rec(w#theme)#bg, 0.4);
        let z = SortingLayer.bottom(Layer.Frame);
        let edge = 3.0;
        let rect = (x, y, rw, rh) -> { at = Vec2.zero(), item = RawDraw.polygon(
            { x = x, y = y } :: { x = x + rw, y = y } :: { x = x + rw, y = y + rh } :: { x = x, y = y + rh } :: Nil, color, z) };
        rect(0.0, 0.0, World.width(), edge)
            :: rect(0.0, World.height() - edge, World.width(), edge)
            :: rect(0.0, 0.0, edge, World.height())
            :: rect(World.width() - edge, 0.0, edge, World.height()) :: Nil

    /// 静的な層の鍵。枠の中身を決める入力（色）を 1 つの文字列にまとめる。
    pub def staticKey(w: World.World): String =
        let c = ThemeDoc.rec(w#theme)#bg;
        "border:${c#r},${c#g},${c#b}"

    // ── 終了の確認の窓（Layer.Prompt） ──

    /// Esc か閉じるボタンで出る確認。場面を薄く沈める幕・窓・文言（文言は sample.kind.json の quitPrompt）。
    def quitPrompt(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        if (not World.isAskingQuit(w)) Nil
        else {
            let theme = ThemeDoc.rec(w#theme);
            let size = { x = World.width() * 0.6, y = 48.0 };
            let at = { x = (World.width() - size#x) / 2.0, y = (World.height() - size#y) / 2.0 };
            { at = Vec2.zero(), item = RawDraw.box({ x = World.width(), y = World.height() }, theme#bg, 0)
                                         |> Render.fade(0.6) }
                :: { at = at, item = RawDraw.box(size, Color.darken(theme#bg, 0.2), 1) }
                :: TextDraw.centeredAt({ text = SampleDoc.rec(w#doc)#quitPrompt, atlas = ctx#atlas, size = 16.0,
                                         color = theme#accent, z = 2,
                                         center = { x = World.width() / 2.0, y = World.height() / 2.0 } })
                :: Nil
        }
}
