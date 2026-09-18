// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
// 画面は 2 つある: 里（歩く画面）と 戦い（魔物と向き合う画面）。frame が phase で振り分ける。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「晴れた昼の城下町」。高い青空の下、石畳と水路が光り、家々の漆喰がまぶしい。
//   色は 3 つ: 芝の緑 / 漆喰の白 / 屋根の赤茶。
//   やらないこと: 輪郭に純黒を使わない（影も彩度のある濃色にする — 昼の影は色が残る）。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「層に分けて、各層に役割を
// 持たせる」組み方の方で、色や効果ではない。別の作り方の例は `.claude/skills/visual-dict`。
//
// ── 絵は 2 系統（camera の掛かり方が違う）──
//   frame = world 側（camera が掛かる）: 盤・扉・薬草・灯り・住人・主人公・ふきだし
//   hud   = 画面固定側（camera を掛けない）: 空・霧・表紙とクリアの幕・戦いのウィンドウ
// 重なり順は 2 つのリストの並びでなく zIndex が決める（Render.draw が安定ソート）。
//
// ── 里の層（奥から手前へ）──
//   地面のタイル層（エンジンの別チャンネル。縁・角は TownMap が選ぶ）
//   → 扉・薬草・灯り → 前後の深度の範囲（建物・住人・主人公 — 足元 y で前後が入れ替わる）
//   → 霧(hud) → ふきだし → 幕(hud)
// 建物は複数タイルにまたがる大きな 1 枚（town_house.sprite.json の house_*）をアトラスの
// quad で置く — タイルを 1 枚ずつ独立に描かない。
//
// ── 絵の下限の 4 性質 × 層の担当（agents-pack/AGENTS.core.md「絵の下限」）──
//   面の階調  … 地面のタイル層（縁・角・散らしのバリエーション）と水面シェーダー
//               （流れる網目）。ベタの単色面を作らない。
//   主役の分離 … 前後の深度の範囲のスプライト（彩度のある濃色の輪郭 + 接地影。純黒は使わない）。
//   層の分かれ … 地面 → 置き物 → 前後の深度の範囲 → 霧 → ふきだし → 幕の z-index の範囲
//               （下の「z 層」の数が唯一の権威）。
//   時間の流れ … 水面シェーダー・窯の煙(Fx)・旗と住人の歩き（コマ送り）・灯りの明滅。
//               表紙や幕の下でも t は進み続ける（World の doc 参照）。
//
// ── 戦いの層（奥から手前へ）──
//   夜空のグラデ → 霧 → 地面のグラデ → 魔物の影 → 魔物（息をする）→ ウィンドウ(hud)
// 戦いの背景と魔物は画面座標のまま world 側に組む — 戦いでは camera が design 中央に
// 固定される（World.cameraCenter）ので、ずらしは常にゼロになる。
mod View {

    // ── z 層 ──
    // 地面はタイル層（エンジンが動的な絵より必ず奥に敷く）なので、ここには出てこない。
    // 置き物 10..29 / 前後の深度の範囲（人・建物）100..131 / 霧 200 / 幕 210.. / ふきだし 220..
    // 前後の深度は Depth.forRows が行ごとに 1 つ割り当てる — その範囲の上下の数と重ならないこと。

    def zHerb(): Int32 = 12
    def zDepthBack(): Int32 = 100
    def zFog(): Int32 = 200
    def zVeil(): Int32 = 210
    def zOverlayText(): Int32 = 212
    def zBubble(): Int32 = 220

    /// 人・建物の前後を決める z の範囲。足元が下（南）にある物ほど手前に出る。
    def depthRange(w: World.World): Depth.ZRange =
        Depth.forRows({ back = zDepthBack(), originY = 0.0,
                        rows = MapDoc.rowCount(w#map), tileSize = World.tileSize() })

    // ── 戦いの画面の z 層 ──
    def zBattleSky(): Int32 = 0
    def zBattleGround(): Int32 = 5
    def zFoeShadow(): Int32 = 10
    def zFoe(): Int32 = 12
    def zWindow(): Int32 = 20
    def zWindowText(): Int32 = 23

    /// スプライトの格子は 1 セル = 1px で描く（16×16 の格子 = 16px。タイル 16px にぴったり収まる）。
    def px(): Int32 = 1

    /// 戦いのときだけ、魔物をこの倍率で大きく描く（16×16 → 64px）。
    def foeScale(): Int32 = 5

    /// world 側の絵（camera が掛かる）。
    pub def frame(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Battle => battleWorld(w)
            case _                  => village(ctx, w)
        }

    /// 画面固定側の絵（camera を掛けない。App.withHudView と SceneRender が同じ物を読む）。
    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Battle =>
                List.flatten(
                       statusWindow(ctx#atlas, w)
                    :: commandWindow(ctx#atlas, w)
                    :: messageWindow(ctx#atlas, w)
                    :: Nil)
            case _ =>
                // 空の面は出さない — 地面のタイル層が画面全体を覆う（bounds が虚空を映さない）。
                // hud に空の矩形を置くと、常に奥へ敷かれるタイル層より手前に来て地面を塗り潰す。
                List.flatten(
                       fogStrips(ThemeDoc.rec(w#theme))
                    // 薄い昼下がりの空気（乗算 1 枚）。幕・文字（z 210..）は染めない。
                    :: Daylight.overlay({ keys = Daylight.defaults(),
                           at = { x = 0.0, y = 0.0 },
                           size = { x = World.width(), y = World.height() },
                           z = 205 }, dayT())
                    :: overlay(ctx#atlas, w)
                    :: Nil)
        }

    /// 1 日のどこの空気か（0..1）。昼下がりの薄い暖色 — 画風の3色が濁らない強さに留める。
    def dayT(): Float64 = 0.62

    /// 里の world 側（歩く・話す・拾う）。地面はタイル層（TownMap）、霧・幕は hud 側。
    def village(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        List.flatten(
               waterSurface(w)
            :: door(w)
            :: fencesView(w)
            :: herbs(w)
            :: lamps(w)
            :: bridgeRails(w)
            :: houses(w)
            :: smoke(w)
            :: flags(w)
            :: villagers(w)
            :: hero(w)
            :: bubble(ctx, w)
            :: Nil)

    // ── 盤の位置合わせ ──

    /// 盤の左上の world 座標。盤が design より大きいので中央寄せはせず (0,0) 固定
    /// （world 座標 = マス×16。どこを映すかは camera が選ぶ）。
    def boardOrigin(_w: World.World): Vec2.Vec2 =
        { x = 0.0, y = 0.0 }

    /// cell の中心の world 座標（盤の位置合わせ込み）。
    def cellCenter(w: World.World, cell: Grid.Cell): Vec2.Vec2 =
        let origin = boardOrigin(w);
        let center = Grid.cellCenterOf(World.tileSize(), cell);
        { x = origin#x + center#x, y = origin#y + center#y }

    /// cell の左上の world 座標（盤の位置合わせ込み）。
    def cellTopLeft(w: World.World, cell: Grid.Cell): Vec2.Vec2 =
        let t = World.tileSize();
        let center = cellCenter(w, cell);
        { x = center#x - t / 2.0, y = center#y - t / 2.0 }

    // ── 建物（複数タイルにまたがる大きな 1 枚をアトラスの quad で置く）──

    /// 建物。壁と屋根は別 sprite だが足元 y（接地の南端）を共有して前後の深度の範囲に載る —
    /// 主人公が北側（裏）を歩くと屋根と壁に隠れ、南側では建物の前に立つ。
    def houses(w: World.World): List[Render.PlacedItem] =
        TownMap.buildings() |> List.flatMap(b ->
            buildingAt(w, b#cell, TownMap.buildingSpec(b#kind)))

    def buildingAt(w: World.World, nw: Grid.Cell,
                   spec: { w = Int32, h = Int32, wall = String, roof = String }): List[Render.PlacedItem] =
        let t = World.tileSize();
        let southY = Int32.toFloat64(nw#y + spec#h) * t;
        let x0 = Int32.toFloat64(nw#x) * t;
        let bodyW = Int32.toFloat64(spec#w) * t;
        let tex = TownMap.textureName();
        // 大きさは絵から測る（描き替えても足元がずれない）。
        let wallSize = PxSprite.sizeOf(w#townSprites, spec#wall, "idle", 1)
            |> Option.getWithDefault({ x = bodyW, y = 32.0 });
        let roofSize = PxSprite.sizeOf(w#townSprites, spec#roof, "idle", 1)
            |> Option.getWithDefault({ x = bodyW + 2.0 * t, y = 48.0 });
        let wallTop = southY - wallSize#y;
        let wall = PxSprite.drawQuad(w#townSprites, w#townAtlas, tex, spec#wall, "idle",
            { x = x0, y = wallTop }, false, 1, 0);
        // 屋根は接地の幅の真ん中に載せ、軒が壁の頭に 4px かぶる
        // （壁の上端の軒の陰と重なって、屋根が壁に載って見える）。
        let roof = PxSprite.drawQuad(w#townSprites, w#townAtlas, tex, spec#roof, "idle",
            { x = x0 + (bodyW - roofSize#x) / 2.0, y = wallTop + 4.0 - roofSize#y }, false, 1, 1);
        Depth.place(depthRange(w), southY, List.append(wall, roof))

    /// 低い柵（門の並び）。当たりは rpg.map の '#' が持ち、ここは絵だけ。
    def fencesView(w: World.World): List[Render.PlacedItem] =
        let t = World.tileSize();
        TownMap.fences() |> List.flatMap(cell -> {
            let bottom = Int32.toFloat64(cell#y + 1) * t;
            Depth.place(depthRange(w), bottom,
                PxSprite.drawQuad(w#townSprites, w#townAtlas, TownMap.textureName(),
                    "fence", "idle",
                    { x = Int32.toFloat64(cell#x) * t, y = bottom - 12.0 }, false, 1, 0))
        })

    // ── 門（約束で開く木戸。閉じている間は通れない） ──

    /// 家の扉と同じ描法の独立した木の門（門柱2本+板戸+小さな屋根）。
    /// 開閉はコマの差し替え（gate_closed / gate_open）— ルールは World の doorOpen のまま。
    def door(w: World.World): List[Render.PlacedItem] =
        let t = World.tileSize();
        let at = cellTopLeft(w, MapDoc.rec(w#map)#door#cell);
        let bottom = at#y + t;
        let name = if (w#doorOpen) "gate_open" else "gate_closed";
        let size = PxSprite.sizeOf(w#townSprites, name, "idle", 1)
            |> Option.getWithDefault({ x = t, y = 24.0 });
        Depth.place(depthRange(w), bottom,
            PxSprite.drawQuad(w#townSprites, w#townAtlas, TownMap.textureName(),
                name, "idle", { x = at#x, y = bottom - size#y }, false, 1, 0))

    // ── 橋の欄干（橋面はタイル層。欄干は前後の深度の範囲に立てる）──

    /// 北の欄干は主人公の後ろ（足元 = マスの上端）、南の欄干は前
    /// （足元 = 次の行の中ほど）— 渡っている間、体が南の欄干に半分隠れる。
    def bridgeRails(w: World.World): List[Render.PlacedItem] =
        let t = World.tileSize();
        w#bridgeCells |> List.flatMap(cell -> {
            let x0 = Int32.toFloat64(cell#x) * t;
            let top = Int32.toFloat64(cell#y) * t;
            let bottom = top + t;
            let north = PxSprite.drawQuad(w#townSprites, w#townAtlas, TownMap.textureName(),
                "bridge_rail", "idle", { x = x0, y = top - 3.0 }, false, 1, 0);
            let south = PxSprite.drawQuad(w#townSprites, w#townAtlas, TownMap.textureName(),
                "bridge_rail", "idle", { x = x0, y = bottom - 3.0 }, false, 1, 0);
            List.append(
                Depth.place(depthRange(w), top, north),
                Depth.place(depthRange(w), bottom + t / 2.0, south))
        })

    // ── 水面（宣言シェーダー。岸と落ち影の 4px はタイルの絵に任せて内側だけ塗る） ──

    // 橋・水面の配置は World の持ち物を読む — 毎フレームの全盤走査は予算を食い潰す。
    def waterSurface(w: World.World): List[Render.PlacedItem] =
        match w#waterRect {
            case None       => Nil
            case Some(rect) =>
                let polys = w#waterMaskRects |> List.map(r ->
                       r#position
                    :: { x = r#position#x + r#size#x, y = r#position#y }
                    :: { x = r#position#x + r#size#x, y = r#position#y + r#size#y }
                    :: { x = r#position#x, y = r#position#y + r#size#y }
                    :: Nil);
                Render.shaderFillMasked(w#waterShader, rect, polys, w#t, 1) :: Nil
        }

    // ── 窯の煙（閉形式の粒。パン屋の煙突の口から） ──

    def smoke(w: World.World): List[Render.PlacedItem] =
        match List.find(b -> b#kind == "shop", TownMap.buildings()) {
            case None    => Nil
            case Some(b) =>
                let t = World.tileSize();
                let spec = TownMap.buildingSpec(b#kind);
                let southY = Int32.toFloat64(b#cell#y + spec#h) * t;
                // 煙突の口 = 屋根 sprite の cols10-15 の中心（屋根は接地幅の中央に載る）。
                let roofX = Int32.toFloat64(b#cell#x) * t
                    + (Int32.toFloat64(spec#w) * t - 64.0) / 2.0;
                let mouth = { x = roofX + 13.0, y = southY - 32.0 + 4.0 - 40.0 + 1.0 };
                let dur = Float64.max(0.1, w#smokeFx#duration);
                let items = Fx.sampleAt(w#smokeFx, 7i64, w#t - dur * Float64.floor(w#t / dur), mouth);
                Depth.place(depthRange(w), southY, items)
        }

    // ── 旗（教会の尖塔の先。Sway で揺れる — 完全に止まった画面を出さない） ──

    def flags(w: World.World): List[Render.PlacedItem] =
        match List.find(b -> b#kind == "church", TownMap.buildings()) {
            case None    => Nil
            case Some(b) =>
                let t = World.tileSize();
                let spec = TownMap.buildingSpec(b#kind);
                let southY = Int32.toFloat64(b#cell#y + spec#h) * t;
                // 尖塔の頂点 = church_top(96×72) の col74（屋根は接地幅の中央に載る）。
                let topX = Int32.toFloat64(b#cell#x) * t
                    + (Int32.toFloat64(spec#w) * t - 96.0) / 2.0;
                let apex = { x = topX + 74.0, y = southY - 48.0 + 4.0 - 72.0 };
                let swayX = Sway.wave(w#t, 0.3, 0.9) * 1.6;
                let swayY = Sway.wave(w#t, 0.8, 1.3) * 0.8;
                let pole = { at = { x = apex#x, y = apex#y - 6.0 },
                             item = RawDraw.box({ x = 1.0, y = 6.0 },
                                 ThemeDoc.resolver(w#theme, "woodDark"), 2) };
                let pennant = { at = { x = apex#x + 1.0, y = apex#y - 6.0 },
                                item = RawDraw.polygon(
                                       { x = 0.0, y = 0.0 }
                                    :: { x = 7.0 + swayX, y = 1.5 + swayY }
                                    :: { x = 0.0, y = 4.0 }
                                    :: Nil, ThemeDoc.rec(w#theme)#accent, 3) };
                Depth.place(depthRange(w), southY, pole :: pennant :: Nil)
        }

    // ── 薬草・灯り・住人・主人公 ──

    def herbs(w: World.World): List[Render.PlacedItem] =
        w#herbs |> List.flatMap(cell -> sprite(w, "herb", "idle", cell, false, zHerb(),
            ThemeDoc.resolver(w#theme, "leaf")))

    /// 灯り。薬草を拾った数だけ、並び順に点いていく（夕暮れの里に灯がともる）。
    def lamps(w: World.World): List[Render.PlacedItem] =
        let lit = World.lampsLit(w);
        MapDoc.rec(w#map)#lamps |> List.zipWithIndex |> List.flatMap(entry -> {
            let (i, cell) = entry;
            lamp(w, cell, i < lit)
        })

    /// 街灯 1 本（木の柱+鉄の腕+吊りランタン）。昼はガラスの暖色だけで光らせない —
    /// 点灯（Daylight 連動は将来）はコマ差し替え + グロー。クリアの「全灯」演出はここが担う。
    def lamp(w: World.World, cell: Grid.Cell, litNow: Bool): List[Render.PlacedItem] =
        let center = cellCenter(w, cell);
        let bottom = center#y + World.tileSize() / 2.0;
        let quad = PxSprite.drawQuad(w#townSprites, w#townAtlas, TownMap.textureName(),
            "lamp", if (litNow) "lit" else "idle",
            { x = center#x - 6.0, y = bottom - 20.0 }, false, 1, 0);
        // ランタンのガラスの位置（絵の cols7-11 × rows3-8）にグローの芯を合わせる。
        let lantern = { x = center#x + 3.0, y = bottom - 14.0 };
        let glow = if (litNow)
            List.append(
                Render.glowAt(lantern, 30.0, ThemeDoc.rec(w#theme)#accent,
                    { alpha = 0.40, blend = DrawCmd.BlendMode.Add }, 1),
                Render.glowAt(lantern, 12.0, ThemeDoc.rec(w#theme)#accent,
                    { alpha = 0.55, blend = DrawCmd.BlendMode.Add }, 2))
        else Nil;
        Depth.place(depthRange(w), bottom, List.append(quad, glow))

    def villagers(w: World.World): List[Render.PlacedItem] =
        MapDoc.rec(w#map)#villagers |> List.flatMap(villager -> {
            // 位置は巡回の見本（World.villagerSampleAt）から。絵の位置と
            // 歩ける・話せるの判定（villagerCellAt）が同じ見本を読むのでずれない。
            let smp = World.villagerSampleAt(w, villager);
            let talking = w#talkingTo
                |> Option.map(cell -> MapDoc.sameCell(cell, World.villagerCellAt(w, villager)))
                |> Option.getWithDefault(false);
            // 歩きコマ: 歩いた累計 px 8px ごとに足を入れ替える（Journey.Sample#walking が種）。
            let stepping = Int32.modulo(
                Float64.tryToInt32(Float64.floor(smp#walking / 8.0)) |> Option.getWithDefault(0), 2) == 1;
            let frameName = if (talking) "talk" else if (stepping) "walk" else "idle";
            Depth.place(depthRange(w), smp#pos#y + World.tileSize() / 2.0,
                spriteAt(w, { name = "villager", frame = frameName, center = smp#pos,
                              flipX = false, scale = px(), z = 0, fallback = ThemeDoc.rec(w#theme)#cloth }))
        })

    /// 主人公。向きごとに絵を持ち、歩数の偶奇で足を入れ替える。
    /// 左向きは右向きの絵の左右反転で済ませる（絵を増やさない）。
    def hero(w: World.World): List[Render.PlacedItem] =
        let (frameName, flipX) = heroFrame(w);
        placeAtFeet(w, w#hero, sprite(w, "hero", frameName, w#hero, flipX, 0, ThemeDoc.rec(w#theme)#accent))

    /// マスに立つ 1 体を前後の深度の範囲へ載せる（足元 = マスの下端）。
    def placeAtFeet(w: World.World, cell: Grid.Cell, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        Depth.place(depthRange(w), cellCenter(w, cell)#y + World.tileSize() / 2.0, items)

    /// 向き + 歩数 → 「どのコマを、反転するか」。
    def heroFrame(w: World.World): (String, Bool) =
        let walking = Int32.modulo(w#steps, 2) == 1;
        match w#facing {
            case Dir4.Up    => (if (walking) "up_walk"   else "up",   false)
            case Dir4.Down  => (if (walking) "down_walk" else "down", false)
            case Dir4.Left  => (if (walking) "side_walk" else "side", true)
            case Dir4.Right => (if (walking) "side_walk" else "side", false)
        }

    /// ドット絵 1 体をマスの中心に置く（里の等倍）。
    def sprite(w: World.World, name: String, frameName: String, cell: Grid.Cell,
               flipX: Bool, z: Int32, fallbackColor: Color): List[Render.PlacedItem] =
        spriteAt(w, { name = name, frame = frameName, center = cellCenter(w, cell),
                      flipX = flipX, scale = px(), z = z, fallback = fallbackColor })

    /// ドット絵 1 体を画面のどこにでも、好きな倍率で置く。大きさは絵から測るので
    /// （PxSprite.sizeOf）、絵を描き替えても置き位置がずれない。
    /// スプライトが読めないときは添えられた色の四角にする（fail-open）。
    /// 同じ型の値が並ぶので名前で渡す。
    def spriteAt(w: World.World,
                 spec: { name = String, frame = String, center = Vec2.Vec2, flipX = Bool,
                         scale = Int32, z = Int32, fallback = Color }): List[Render.PlacedItem] =
        let side = 16.0 * Int32.toFloat64(spec#scale);
        let box = PxSprite.sizeOf(w#sprites, spec#name, spec#frame, spec#scale)
            |> Option.getWithDefault({ x = side, y = side });
        let topLeft = { x = spec#center#x - box#x / 2.0, y = spec#center#y - box#y / 2.0 };
        // 置き場所は anchor（握るところ）で指すので、中心から anchor へのずれを足して渡す。
        let off = PxSprite.anchorOffsetOf(w#sprites, spec#name, spec#frame, spec#scale);
        let at = { x = spec#center#x + off#x, y = spec#center#y + off#y };
        // 作ったアトラスから 1 コマ = 1 クアッドで貼る（街タイルと同じ経路。PxSprite.draw は
        // 1 コマを画素ぶんの四角に開くので、人と物が増えるほど組む数が伸びる）。
        // 作る所は World.bakeCharAtlas。
        let items = PxSprite.drawQuad(w#sprites, w#charAtlas, World.charAtlasName(),
            spec#name, spec#frame, at, spec#flipX, spec#scale, spec#z);
        if (List.isEmpty(items))
            { at = topLeft, item = RawDraw.box(box, spec#fallback, spec#z) } :: Nil
        else
            items

    // ── 霧（決定的なばらつきで横に流れるストリップ。保存も乱数の種も持たない） ──

    def fogStrips(theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        List.range(0, 5) |> List.map(i ->
            { at = { x = 0.0, y = Hash01.at(i, 11) * (World.height() - 40.0) },
              item = RawDraw.box({ x = World.width(), y = 30.0 + Hash01.at(i, 12) * 34.0 },
                                theme#fog, zFog())
                  |> Render.fade(0.10 + Hash01.at(i, 13) * 0.08) })

    // ── ふきだし（住人の頭の上。本文は文字送りの途中まで） ──
    // 枠は ui.json（UiStore）にしない: ふきだしは話し相手のマスに吸い付く世界側の物で、
    // 画面に固定のウィンドウではないため。開閉・行送り・文字送りの状態はエンジンの UiDialog が持ち、
    // ここは visibleBody を RichText.place で描くだけ（文字折りも自前で書かない）。

    def bubble(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        match (UiDialog.isOpen(w#dialog), w#talkingTo) {
            case (true, Some(cell)) => bubbleAt(ctx, cellCenter(w, cell), w)
            case _                  => Nil
        }

    def bubbleAt(ctx: App.ViewCtx, speakerCenter: Vec2.Vec2, w: World.World): List[Render.PlacedItem] =
        let atlas = ctx#atlas;
        let spans = UiDialog.visibleBody(w#dialog);
        let fullSpans = UiDialog.currentLine(w#dialog)
            |> Option.map(line -> line#body) |> Option.getWithDefault(Nil);
        // 文字の大きさ・行間・余白・最大幅は手触り（rpg.kind.json）から来る。
        let fontSize = KindDoc.rec(w#kind)#bubbleSize;
        let lineGap = KindDoc.rec(w#kind)#bubbleGap;
        let pad = KindDoc.rec(w#kind)#bubblePad;
        let maxTextW = KindDoc.rec(w#kind)#bubbleWidth;
        // 枠の寸法は「全文」で測る — 文字送りの途中で枠がガタつかない。
        let lineCount = RichText.wrapLinesBy(
            ch -> TextDraw.width(Char.toString(ch), atlas, fontSize),
            maxTextW, fullSpans) |> List.length |> Int32.max(1);
        let textW = Float64.min(maxTextW,
            TextDraw.width(RichText.plainText(fullSpans), atlas, fontSize));
        let boxW = textW + pad * 2.0;
        let boxH = Int32.toFloat64(lineCount) * (fontSize + lineGap)
            - lineGap + pad * 2.0;
        // 収める先は world 全体でなく「いま見えている矩形」（camera 込み）—
        // 盤の東側で話しても、ふきだしは画面の中に残る。
        let vis = ctx#visible;
        let boxX = clampF(vis#position#x + edgeMargin(),
            vis#position#x + vis#size#x - boxW - edgeMargin(),
            speakerCenter#x - boxW / 2.0);
        let boxY = Float64.max(vis#position#y + edgeMargin(),
            speakerCenter#y - World.tileSize() / 2.0 - boxH - 8.0);
        List.flatten(
               ({ at = { x = boxX, y = boxY },
                  item = RawDraw.box({ x = boxW, y = boxH }, ThemeDoc.rec(w#theme)#paper, zBubble()) } :: Nil)
            :: tail(speakerCenter, boxY + boxH, ThemeDoc.rec(w#theme)#paper)
            :: RichText.place(
                   { atlas = atlas, size = fontSize, baseTint = ThemeDoc.rec(w#theme)#ink,
                     z = zBubble() + 2, pos = { x = boxX + pad, y = boxY + pad },
                     maxWidth = maxTextW, lineGap = lineGap }, spans)
            :: Nil)

    /// ふきだしの口（枠の下辺から話し手へ落ちる小さな三角）。
    def tail(speakerCenter: Vec2.Vec2, fromY: Float64, color: Color): List[Render.PlacedItem] =
        { at = { x = speakerCenter#x, y = fromY },
          item = RawDraw.polygon(
              { x = -4.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 6.0 } :: Nil,
              color, zBubble() + 1) } :: Nil

    /// ふきだしの枠を見えている縁から離す幅。0 にすると枠が縁に接して切れて見えるので、
    /// はみ出し止めの最小値ではなく目に見える余白として取る。
    def edgeMargin(): Float64 = 8.0

    def clampF(lo: Float64, hi: Float64, v: Float64): Float64 =
        Float64.max(lo, Float64.min(hi, v))

    // ── 表紙とクリアの幕（文言はすべて間取りの Doc から: 見出し・一行・操作のヒント） ──

    def overlay(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Play   => Nil
            case World.Phase.Battle => Nil        // 戦いの画面は overlay を通らない
            case World.Phase.Title  =>
                List.append(veil(ThemeDoc.rec(w#theme), ThemeDoc.rec(w#theme)#titleVeil), banner(atlas, ThemeDoc.rec(w#theme),
                    { head = MapDoc.rec(w#map)#title, headSize = 26.0,
                      body = MapDoc.rec(w#map)#subtitle, hint = MapDoc.rec(w#map)#hint }))
            case World.Phase.Clear  =>
                List.append(veil(ThemeDoc.rec(w#theme), ThemeDoc.rec(w#theme)#clearVeil), banner(atlas, ThemeDoc.rec(w#theme),
                    { head = MapDoc.rec(w#map)#title, headSize = 16.0,
                      body = MapDoc.rec(w#map)#clear, hint = MapDoc.rec(w#map)#clearHint }))
        }

    def veil(theme: ThemeDoc.Rec, alpha: Float64): List[Render.PlacedItem] =
        { at = { x = 0.0, y = 0.0 },
          item = RawDraw.box({ x = World.width(), y = World.height() },
                            ThemeDoc.darken(theme#sky, 0.5), zVeil())
              |> Render.fade(alpha) } :: Nil

    /// 見出し・一行・操作ヒントを画面の真ん中に積む。
    def banner(atlas: FontAtlas, theme: ThemeDoc.Rec,
               opts: { head = String, headSize = Float64, body = String, hint = String }): List[Render.PlacedItem] =
           TextDraw.centered({ text = opts#head, atlas = atlas, size = opts#headSize,
                               color = theme#paper, z = zOverlayText(),
                               centerX = World.width() / 2.0, y = 88.0 })
        :: TextDraw.centered({ text = opts#body, atlas = atlas, size = 10.0,
                               color = theme#fog, z = zOverlayText(),
                               centerX = World.width() / 2.0, y = 120.0 })
        :: TextDraw.centered({ text = opts#hint, atlas = atlas, size = 9.0,
                               color = ThemeDoc.lighten(theme#sky, 0.4), z = zOverlayText(),
                               centerX = World.width() / 2.0, y = 150.0 })
        :: Nil

    // ══════════════════════════════════════════════════════
    // 戦いの画面（魔物と向き合う）
    // ══════════════════════════════════════════════════════
    //
    // 里の絵は出さない（盤・霧のストリップ・ふきだしは village 側の物）。ここは
    // 「夜空 → 霧 → 地面 → 魔物」の 4 層（ウィンドウは hud 側）で、視線が魔物と下の文に集まるようにする。

    def battleWorld(w: World.World): List[Render.PlacedItem] =
        List.flatten(
               battleSky(ThemeDoc.rec(w#theme))
            :: battleMist(ThemeDoc.rec(w#theme))
            :: battleGround(ThemeDoc.rec(w#theme))
            :: foe(w)
            :: Nil)

    /// 夜空。上ほど暗く、下ほど地面の色に近づく縦のグラデ（1px の色帯は積まない）。
    def battleSky(theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        { at = { x = 0.0, y = 0.0 },
          item = Render.vgrad({ x = World.width(), y = World.height() },
              { top = ThemeDoc.darken(theme#sky, 0.45),
                bottom = ThemeDoc.lighten(theme#sky, 0.10) }, zBattleSky()) } :: Nil

    /// 遠くにかかる霧。濃さが縦に変わる面を数枚重ねる。里の霧（fogStrips）は四角い面で
    /// よいが、こちらは下地がなめらかなグラデなので、縁が立つと面の四角が見えてしまう —
    /// 上下で薄れる頂点色つきの面にして、境目を消す。
    def battleMist(theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        List.range(0, 3) |> List.map(i -> {
            let top = 48.0 + Hash01.at(i, 21) * 72.0;
            let height = 20.0 + Hash01.at(i, 22) * 24.0;
            let alpha = 0.07 + Hash01.at(i, 23) * 0.05;
            softStrip(theme#fog, { top = top, bottom = top + height }, alpha, zBattleSky() + 1)
        })

    /// 上下の縁が透けて消える横帯（霧・地面のなじませに使う）。
    def softStrip(color: Color, span: { top = Float64, bottom = Float64 },
                 peak: Float64, z: Int32): Render.PlacedItem =
        let mid = (span#top + span#bottom) / 2.0;
        { at = { x = 0.0, y = 0.0 },
          item = Render.gradPolygon(
                 { pos = { x = 0.0, y = span#top },            color = color, alpha = 0.0 }
              :: { pos = { x = World.width(), y = span#top },  color = color, alpha = 0.0 }
              :: { pos = { x = World.width(), y = mid },       color = color, alpha = peak }
              :: { pos = { x = World.width(), y = span#bottom },color = color, alpha = 0.0 }
              :: { pos = { x = 0.0, y = span#bottom },         color = color, alpha = 0.0 }
              :: { pos = { x = 0.0, y = mid },                 color = color, alpha = peak }
              :: Nil, z) }

    /// 魔物の立っている地面。上端は透けさせて空へなじませ、手前ほど明るくする
    /// （硬い横線が 1 本入ると、そこで絵が 2 枚に割れて見えるため）。
    def battleGround(theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        let top = 94.0;
        let near = ThemeDoc.darken(theme#path, 0.25);
        let far = ThemeDoc.darken(theme#path, 0.6);
           { at = { x = 0.0, y = 0.0 },
             item = Render.gradPolygon(
                    { pos = { x = 0.0, y = top },              color = far,  alpha = 0.0 }
                 :: { pos = { x = World.width(), y = top },    color = far,  alpha = 0.0 }
                 :: { pos = { x = World.width(), y = top + 40.0 }, color = far, alpha = 1.0 }
                 :: { pos = { x = World.width(), y = World.height() }, color = near, alpha = 1.0 }
                 :: { pos = { x = 0.0, y = World.height() },   color = near, alpha = 1.0 }
                 :: { pos = { x = 0.0, y = top + 40.0 },       color = far,  alpha = 1.0 }
                 :: Nil, zBattleGround()) }
        :: Nil

    /// 魔物と、その足元の影。上下にゆっくり息をする（手を止めても画面が止まらない）。
    /// 殴った直後のコマ（hit）は World が持つ foeHurt が決める。
    def foe(w: World.World): List[Render.PlacedItem] =
        let groundY = 165.0;
        let bob = Sway.wave(w#t, 0.0, 0.55) * 4.0;
        let half = 8.0 * Int32.toFloat64(foeScale());
        let center = { x = World.width() / 2.0, y = groundY - half + bob };
        // 影は本体が浮くほど小さく薄くする（浮き沈みが影で読める）。
        let lift = (bob + 4.0) / 8.0;
        let shadow = RawDraw.ellipseAt({ x = center#x, y = groundY + 3.0 },
            { x = 40.0 - lift * 5.0, y = 10.0 - lift * 2.0 },
            ThemeDoc.darken(ThemeDoc.rec(w#theme)#sky, 0.55), zFoeShadow())
            |> (placed -> { item = Render.fade(0.7, placed#item) | placed });
        let frameName = if (w#battle#foeHurt) "hit" else "idle";
        shadow :: spriteAt(w, { name = "foe", frame = frameName, center = center,
                                flipX = false, scale = foeScale(), z = zFoe(),
                                fallback = ThemeDoc.resolver(w#theme, "foe") })

    // ── ウィンドウ（ドラクエ風の「紙の縁 + 濃い地」）──

    /// ウィンドウ 1 枚。紙色の縁を敷き、その内側を濃い地で塗る。中身は呼び側が上に置く。
    /// 角丸や影を足さないのは、この画風のウィンドウが「紙を切って貼った物」だから。
    def window(rect: Rect2.Rect2, theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        let inset = 2.0;
           { at = rect#position, item = RawDraw.box(rect#size, theme#paper, zWindow()) }
        :: { at = { x = rect#position#x + inset, y = rect#position#y + inset },
             item = RawDraw.box({ x = rect#size#x - inset * 2.0, y = rect#size#y - inset * 2.0 },
                 ThemeDoc.darken(theme#ink, 0.15), zWindow() + 1) }
        :: Nil

    /// ウィンドウの中に 1 行置く。
    def windowLine(atlas: FontAtlas, text: String, at: Vec2.Vec2, color: Color): Render.PlacedItem =
        { at = at, item = Render.textTinted(text, atlas, 12.0, color, zWindowText()) }

    /// 体力のウィンドウ（左上）。数だけでなく残りをバーでも出す — 数を読まなくても危なさが判る。
    def statusWindow(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let rect = { position = { x = 16.0, y = 14.0 }, size = { x = 132.0, y = 44.0 } };
        let maxHp = Int32.max(1, BattleDoc.rec(w#battleDoc)#heroMaxHp);
        let ratio = Num.clamp01(Int32.toFloat64(w#heroHp) / Int32.toFloat64(maxHp));
        let barW = 100.0;
        // 減るほど灯りの色から離れて危うい色へ寄る（色でも残りが読める）。
        let barColor = Color.mix(ThemeDoc.rec(w#theme)#cloth, ThemeDoc.rec(w#theme)#accent, ratio);
        List.append(window(rect, ThemeDoc.rec(w#theme)),
               windowLine(atlas, "HP ${Int32.toString(w#heroHp)}/${Int32.toString(maxHp)}",
                   { x = 26.0, y = 22.0 }, ThemeDoc.rec(w#theme)#paper)
            :: { at = { x = 26.0, y = 40.0 },
                 item = RawDraw.box({ x = barW, y = 6.0 },
                     ThemeDoc.darken(ThemeDoc.rec(w#theme)#paper, 0.75), zWindowText()) }
            :: { at = { x = 26.0, y = 40.0 },
                 item = RawDraw.box({ x = barW * ratio, y = 6.0 }, barColor, zWindowText() + 1) }
            :: Nil)

    /// コマンドのウィンドウ（左下）。コマンドを選んでいる間だけ出す。
    /// 選んでいる行にはまたたく三角を置く（点滅は「いま入力を待っている」の合図）。
    def commandWindow(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        if (w#battle#step != World.BattleStep.Choosing) Nil
        else {
            let rect = { position = { x = 16.0, y = 126.0 }, size = { x = 108.0, y = 62.0 } };
            let blink = 0.55 + 0.45 * Sway.wave(w#t, 0.0, 1.6);
            let rows = World.battleCommands() |> List.zipWithIndex |> List.flatMap(entry -> {
                let (i, label) = entry;
                let y = 136.0 + Int32.toFloat64(i) * 22.0;
                let chosen = i == w#battle#cursor;
                let mark = if (chosen)
                        { at = { x = 30.0, y = y + 7.0 },
                          item = RawDraw.polygon(
                              { x = 0.0, y = -5.0 } :: { x = 7.0, y = 0.0 } :: { x = 0.0, y = 5.0 } :: Nil,
                              ThemeDoc.rec(w#theme)#accent, zWindowText() + 1)
                              |> Render.fade(blink) } :: Nil
                    else Nil;
                windowLine(atlas, label, { x = 44.0, y = y },
                    if (chosen) ThemeDoc.rec(w#theme)#paper else ThemeDoc.darken(ThemeDoc.rec(w#theme)#paper, 0.45)) :: mark
            });
            List.append(window(rect, ThemeDoc.rec(w#theme)), rows)
        }

    /// 文のウィンドウ（下）。いま読ませたい行を上から順に並べる。
    /// 行が無いとき（コマンド選び中）は出さない — 空のウィンドウは画面を狭くするだけ。
    def messageWindow(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        if (List.isEmpty(w#battle#lines)) Nil
        else {
            let count = List.length(w#battle#lines);
            let height = 26.0 + Int32.toFloat64(count) * 20.0;
            let top = World.height() - height - 14.0;
            let rect = { position = { x = 132.0, y = top },
                         size = { x = World.width() - 148.0, y = height } };
            let rows = w#battle#lines |> List.zipWithIndex |> List.map(entry -> {
                let (i, line) = entry;
                windowLine(atlas, line, { x = rect#position#x + 14.0,
                                          y = top + 14.0 + Int32.toFloat64(i) * 20.0 },
                    ThemeDoc.rec(w#theme)#paper)
            });
            // 読み終えて次へ進める合図（またたく小さな三角）。
            let blink = 0.5 + 0.5 * Sway.wave(w#t, 0.25, 1.4);
            let more = { at = { x = rect#position#x + rect#size#x - 16.0,
                                y = top + height - 12.0 },
                         item = RawDraw.polygon(
                             { x = -5.0, y = 0.0 } :: { x = 5.0, y = 0.0 } :: { x = 0.0, y = 6.0 } :: Nil,
                             ThemeDoc.rec(w#theme)#accent, zWindowText() + 1)
                             |> Render.fade(blink) };
            List.append(window(rect, ThemeDoc.rec(w#theme)), more :: rows)
        }
}
