// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// ── 画面の層（奥から手前へ）──
// 単色の四角を 1 枚敷いただけの画面は未完成、というのがこのエンジンの決まり
// （AGENTS.md の「絵の下限」= 面に階調か質感 / 主役が背景から分離 / 層が分かれている /
// 時間が流れている、の 4 つ）。
//
// **ここの見た目は数ある画風の 1 つでしかない。** 真似してほしいのは「層に分けて、
// 各層に役割を持たせる」組み方の方で、色や効果ではない。新しいゲームでは画風を先に決めて
// AGENTS.local.md に書き、この層構成ごと作り替えてよい（画風の決め方と別の作り方の例は
// `.claude/skills/visual-dict`）。
//
// この骨組みが置いている層と、それが受け持つ性質:
//    0  backdrop … 背景（宣言シェーダーの面）        → 面に階調と質感・時間が流れる
//    8  halo     … 主人公のまわりの背景を沈める      → 主役が背景から分離
//   10  hero     … 主人公（ドット絵 + PxShade の仕上げ）→ 主役が背景から分離・時間が流れる
//   12  dust     … 舞う塵                            → 時間が流れる
mod View {

    def zBackdrop(): Int32 = 0
    def zHalo(): Int32 = 8
    def zHero(): Int32 = 10
    def zDust(): Int32 = 12

    pub def frame(_ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        backdrop(w) :: Nil
            |> List.append(halo(w))
            |> List.append(hero(w))
            |> List.append(dust(w))

    // ── 0. 背景（宣言シェーダーの面） ──

    /// 画素ごとの計算で塗る面。単色の box の代わりで、上下の色の移り変わりに
    /// 雲のムラが混ざり、ゆっくり流れる。何がどう効くかは Doc の note と
    /// engine の `docs/shader-doc.md` を参照。
    def backdrop(w: World.World): Render.PlacedItem =
        Render.shaderFill(w#shader,
            { position = { x = 0.0, y = 0.0 },
              size = { x = World.width(), y = World.height() } },
            w#t, zBackdrop())

    // ── 8. 主人公のまわりを沈める ──

    /// 主役の後ろだけ背景を暗く落とす（乗算で重ねる）。主役そのものを明るくするより、
    /// 周りを沈めたほうが背景の絵を殺さずに輪郭が立つ。
    /// 色は黒でなく寒色へ近づけた暗い色にする（黒で沈めると絵が濁る）。
    def halo(w: World.World): List[Render.PlacedItem] =
        Render.glowAt({ x = w#x, y = w#y }, World.heroBox(w)#x * 1.7,
            Color.cool(Color.darken(ThemeDoc.rec(w#theme)#bg, 0.3), 0.1),
            { alpha = 0.45, blend = DrawCmd.BlendMode.Multiply }, zHalo())

    // ── 10. 主人公（ドット絵 + 塗りの仕上げ） ──

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
            "hero", "idle", topLeft, false, World.spriteScale(), zHero());
        if (List.isEmpty(items))
            // fail-open: スプライトが無い・読めないときは差し色の四角。
            { at = topLeft, item = RawDraw.box(box, ThemeDoc.rec(w#theme)#accent, zHero()) } :: Nil
        else
            items

    // ── 12. 舞う塵 ──

    /// 粒はどこにも保存せず、番号と時刻だけから計算する（巻き戻しても同じ絵）。
    /// 数や速さを Doc から調整したくなったら fx.json（FxDoc）へ移す。
    def dust(w: World.World): List[Render.PlacedItem] =
        let color = ThemeDoc.lighten(ThemeDoc.rec(w#theme)#accent, 0.6);
        Fx.derive(22, w#t, (_i, rand, t) -> {
            let speed = 5.0 + rand(1) * 12.0;
            let x = Num.wrapTo(World.width(), rand(0) * World.width() + t * speed);
            let y = rand(2) * World.height() + Sway.wave(t, rand(3), 0.35) * 7.0;
            RawDraw.circleAt({ x = x, y = y }, 0.8 + rand(4) * 1.3, color, zDust())
                |> Render.overItem(Render.fade(0.20 + rand(5) * 0.30))
        })
}
