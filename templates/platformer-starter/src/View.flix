// View — World を「何をどこに描くか」へ写す。World は読むだけ。
//
// ── 層の地図(z はここが唯一の権威)──
//   パララックス(Main が addParallaxLayer で繋ぐ。係数は Main が権威):
//     空 0.00 → 雲 0.04 → 遠山 0.10 → 丘 0.18 → 木立 0.30
//   世界: zWall 8(洞窟の背後壁)→ zFore 10(地形)→ zDeco 12(床・バネ・旗)→
//         zCoin 14 → zActor 20(主役・敵)→ zShot 22 → zFx 24
//   HUD: カメラ非追従(App.withHudView)
//
// ── 各層が「絵の下限」の 4 性質のどれを受け持つか ──
//   階調・質感: 空(vgrad の二色)/ 遠景ストリップ(裾のディザ)/ 地形タイル(粒 + 洞窟の tint)
//   主役の分離: 主役と敵だけ暖色 + PxShade のふち光。背景は寒色で沈める
//   層の分離  : 視差 5 層(上の並び)。手前ほど速く流れるので奥行きが出る
//   時間の流れ: 雲が流れる / 旗と炎とコインがコマ替え / 塵と星が湧いて消える
//               (静止画でも雲と旗が別位相なので、止まった絵にならない)
//
// 静的な地形は GPU タイル層(TerrainLayers.specs)が敷くので、実機(frameLive)は
// 「動く物 + 層に乗れなかった絵の補完」だけを毎フレーム組む。描き出し(frame)は
// GPU が無いので同じ記述(cellGroups)を全部動的に解釈する — 2 経路の絵は同じ。
mod View {

    pub def zWall(): Int32 = 8
    pub def zFore(): Int32 = 10
    def zDeco(): Int32 = 12
    def zCoin(): Int32 = 14
    def zActor(): Int32 = 20
    def zShot(): Int32 = 22
    def zFx(): Int32 = 24

    def scale(): Int32 = 1

    /// 設計解像度(px)。空・幕・描き出し・probe の「画面いっぱい」はここが唯一の権威。
    pub def design(): Vec2.Vec2 = { x = 640.0, y = 360.0 }


    /// 2 コマ替えのコマが「前」か(fps = 1 秒あたりのコマ数)。コイン・炎・旗・
    /// 無敵の点滅・走り・敵はどれもこの 1 本で振る — 位相の丸めを揃えるため。
    def two(w: World.World, fps: Float64): Bool =
        Anim.frameAt({ row = 0, frames = 2, fps = fps, looping = true }, w#t) == 0

    // ── パララックス層(Main が addParallaxLayer で繋ぐ)──

    /// 空(視差 0)。kind ごとの二色 + 夕日。design 全面に敷く。
    pub def backdrop(w: World.World): List[Render.PlacedItem] =
        let c = key -> Theme.resolve(w#theme, key);
        let kind = Stage.rec(w#stage)#kind;
        let (top, bottom) =
            if (kind == "cave") (c("caveTop"), c("caveBottom"))
            else if (kind == "tower") (c("towerTop"), c("towerBottom"))
            else (c("skyTop"), c("skyBottom"));
        let sky = { at = { x = 0.0, y = 0.0 },
                    item = Render.vgrad(design(), { top = top, bottom = bottom }, 0) };
        if (kind == "cave") sky :: Nil
        else sky
            :: RawDraw.circleAt({ x = 500.0, y = 116.0 }, 24.0, c("sun"), 1)
            :: Nil

    // ── 遠景のシルエット(横リピートのドット絵ストリップ。terra_like と同じ技法)──
    // 奇数枚目は左右反転 — 1 枚のストリップでも並びの繰り返しが目立ちにくい。

    /// 夕方の雲(視差 0.04)。時刻でゆっくり流れる。
    pub def clouds(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        strip(ctx, w, "cloud", 96.0, 0.34, None, 2, w#t * 3.0)

    /// 遠い山なみ(視差 0.10)。夕日の稜線リムが入る。
    /// 埋め板の色は**そのストリップの下端 1 行と同じ色**にする — 別の色を敷くと
    /// 境目が横縞になり、敷かないと平らな下端が空中に一本線で出て板が浮いて見える。
    pub def mountains(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        strip(ctx, w, "mountain", 128.0, 0.66, Some("bgMountainDark"), 3, 0.0)

    /// なだらかな丘(視差 0.18)。
    pub def farHills(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        strip(ctx, w, "hill", 128.0, 0.76, Some("bgHillDark"), 4, 0.0)

    /// 木立のシルエット(視差 0.30)。
    pub def forest(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        strip(ctx, w, "forest", 128.0, 0.88, Some("bgForestDark"), 5, 0.0)

    /// 横リピートのストリップ 1 本。bottomFrac = 画面のどの高さに底を置くか。
    /// fillKey があれば下端から画面の底まで同じ色の板で埋める(下が切れて空が見えないように)。
    /// drift は右→左へ流す px(雲用。ストリップ幅で一周する)。
    def strip(ctx: App.ViewCtx, w: World.World, sprite: String, stripW: Float64,
              bottomFrac: Float64, fillKey: Option[String], z: Int32,
              drift: Float64): List[Render.PlacedItem] =
        if (Stage.rec(w#stage)#kind == "cave") Nil
        else {
            let stripH = PxSprite.sizeOf(w#pxDoc, sprite, "strip", scale())
                |> Option.map(s -> s#y) |> Option.getWithDefault(0.0);
            if (stripH <= 0.0) Nil
            else {
                let s = Int32.toFloat64(scale());
                let stepW = stripW * s;              // 画面上の 1 枚ぶんの幅
                let dx = World.fmod(drift, stepW);
                let x0 = ctx#visible#position#x - stepW + dx;
                let x1 = ctx#visible#position#x + ctx#visible#size#x + stepW;
                let bottom = ctx#visible#position#y + ctx#visible#size#y * bottomFrac;
                let top = bottom - stripH;
                let i0 = Num.floorInt(x0 / stepW);
                let i1 = Num.floorInt(x1 / stepW);
                let quads = List.range(i0, i1 + 1) |> List.flatMap(i -> {
                    let flip = Int32.modulo(i, 2) == 1;
                    let x = Int32.toFloat64(i) * stepW - dx;
                    PxSprite.drawQuad(w#pxDoc, w#atlas, World.atlasName(),
                        sprite, "strip", { x = x, y = top }, flip, scale(), z)
                });
                let fillH = ctx#visible#position#y + ctx#visible#size#y - bottom;
                let under = match fillKey {
                    case Some(key) =>
                        if (fillH <= 0.0) Nil
                        else RawDraw.boxAt(
                            { x = (x0 + x1) / 2.0, y = bottom + fillH / 2.0 },
                            { x = x1 - x0, y = fillH },
                            Theme.resolve(w#theme, key), z) :: Nil
                    case None => Nil
                };
                List.append(quads, under)
            }
        }

    // ── 実機と描き出しの入口 ──

    /// 描き出し・全動的経路: 地形も動的に解釈する(GPU 層と同じ cellGroups が源)。
    pub def frame(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        tileItems(ctx#visible, w) ::: worldItems(ctx#visible, w)

    /// 実機: 地形は GPU 層が敷くので、乗れなかった絵の補完 + 動く物だけ。
    pub def frameLive(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        liveComplement(ctx#visible, w) ::: worldItems(ctx#visible, w)

    /// 見えている矩形が覆うマス(面の外へはみ出さない。上の行から・行の中は左から)。
    /// 画面の外まで地形を組むと、面が大きいほど 1 フレームの絵の数がそのまま増える。
    def cellsIn(visible: Rect2.Rect2, w: World.World): List[Grid.Cell] =
        Grid.cellsIn({ tileSize = Physics.tileSize(), area = visible,
                       cols = Stage.rec(w#stage)#width, rows = Stage.rec(w#stage)#height,
                       margin = { left = 1, top = 1, right = 1, bottom = 1 } })

    /// 画面に写る動く物だけを組む。ここを絞らないと、面が長いほど 1 フレームの
    /// 部品数がそのまま増える — 洞窟は 1 コマが画素ごとの箱に展開されるので
    /// (明度を CPU で乗せるため)、絞らないと数千部品になって固まる。
    def worldItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        apronItems(w) ::: gimmickItems(vis, w) ::: actorItems(vis, w) ::: fxItems(vis, w)

    /// 画面(+ 余白 2 マス)に掛かるか。1 マス以下の物(コイン・敵・弾・粒)専用 —
    /// 点で見るので、これより大きい物は nearBox を使うこと。
    def near(vis: Rect2.Rect2, at: Vec2.Vec2): Bool =
        let pad = Physics.tileSize() * 2.0;
        at#x > vis#position#x - pad and at#x < vis#position#x + vis#size#x + pad
            and at#y > vis#position#y - pad and at#y < vis#position#y + vis#size#y + pad

    /// 大きさを持つ物(動く床は 4〜6 マス)の判定。点で見ると、左端が画面の外へ
    /// 少し出ただけで**まだ画面に掛かっている床が消える** — 当たりは World 側に
    /// 残るので「見えないのに乗れる」という一番たちの悪い食い違いになる。
    def nearBox(vis: Rect2.Rect2, at: Vec2.Vec2, size: Vec2.Vec2): Bool =
        let pad = Physics.tileSize() * 2.0;
        let grown = { x = vis#size#x + pad * 2.0, y = vis#size#y + pad * 2.0 };
        Hit.boxBox(Vec2.add(vis#position, Vec2.mul(vis#size, 0.5)), grown#x, grown#y,
                   Vec2.add(at, Vec2.mul(size, 0.5)), size#x, size#y)

    /// マスの中心で判定する near(コイン・松明のようにマスに置く物)。
    def nearCell(vis: Rect2.Rect2, c: Stage.Cell): Bool =
        near(vis, Stage.centerOf(c))

    /// 面の外(最下段の下と左右)を地の色で塞ぐ — カメラが端に寄った時に
    /// 別レイヤ(丘・空)が覗かないように。
    def apronItems(w: World.World): List[Render.PlacedItem] =
        let ts = Physics.tileSize();
        let wpx = Int32.toFloat64(Stage.rec(w#stage)#width) * ts;
        let hpx = Int32.toFloat64(Stage.rec(w#stage)#height) * ts;
        let ground = if (Stage.rec(w#stage)#kind == "outdoor") "dirtDark" else "stoneDark";
        let c = litColor(w, 0, Stage.rec(w#stage)#height - 1, Theme.resolve(w#theme, ground));
        { at = { x = -240.0, y = hpx },
          item = RawDraw.box({ x = wpx + 480.0, y = 320.0 }, c, zFore()) }
            :: { at = { x = -240.0, y = 0.0 },
                 item = RawDraw.box({ x = 240.0, y = hpx + 320.0 }, c, zFore()) }
            :: { at = { x = wpx, y = 0.0 },
                 item = RawDraw.box({ x = 240.0, y = hpx + 320.0 }, c, zFore()) }
            :: Nil

    // ── 地形(cellGroups の解釈)──

    /// 見えているマスを動的に描く(描き出し用)。洞窟は 1 マスごとに明度で沈める —
    /// GPU 層の per-tile tint と同じ丸め(LightGrid.toColor)を通す。
    pub def tileItems(visible: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        forM (c <- cellsIn(visible, w);
              g <- TerrainLayers.cellGroups(w, c#x, c#y);
              it <- groupItems(w, c#x, c#y, g, false))
            yield it

    /// GPU 層に乗れなかったクアッドの補完(実機用)。絵が揃っていれば空。
    pub def liveComplement(visible: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        forM (c <- cellsIn(visible, w);
              g <- TerrainLayers.cellGroups(w, c#x, c#y);
              it <- groupItems(w, c#x, c#y, g, true))
            yield it

    /// 1 群を絵にする。dynamicOnly = 層に乗るクアッドを除く(実機の補完)。
    /// どのクアッドも絵に解決しなければ fallback の仮色の板を 1 枚。
    def groupItems(w: World.World, x: Int32, y: Int32, g: TerrainLayers.Group,
                   dynamicOnly: Bool): List[Render.PlacedItem] =
        let ts = Physics.tileSize();
        let at = { x = Int32.toFloat64(x) * ts, y = Int32.toFloat64(y) * ts };
        let quads = g#quads |> List.filter(q ->
            if (dynamicOnly) not TerrainLayers.ridesLayer(w, q) else true);
        let drawn = quads |> List.flatMap(q -> tileQuad(w, x, y, q, at, g#z));
        let anyResolved = g#quads |> List.exists(q -> TerrainLayers.ridesLayer(w, q));
        match (anyResolved, g#fallback) {
            case (false, Some(color)) =>
                RawDraw.orBoxAt({ x = at#x + ts / 2.0, y = at#y + ts / 2.0 },
                               { x = ts, y = ts }, litColor(w, x, y, color), g#z, drawn)
            case _ => drawn
        }

    /// タイル 1 コマ。outdoor は 1 クアッド(速い)、cave は明度を掛けるため box 列で。
    def tileQuad(w: World.World, x: Int32, y: Int32, q: TerrainLayers.Quad,
                 at: Vec2.Vec2, z: Int32): List[Render.PlacedItem] =
        PxSprite.drawQuad(w#pxDoc, w#atlas, World.atlasName(),
                          q#sprite, q#frame, at, false, scale(), z)
            |> lit(w, x, y)

    /// 洞窟の明度を GPU の tint に載せる(cave 以外は素通し)。
    ///
    /// 暗くする掛け算は描画時に GPU がやるので、1 コマ = 1 クアッドのまま済む。
    /// 以前はここで PxSprite.draw を使い、画素の並びごとに CPU で色を作っていた —
    /// コイン 1 枚が箱数十個へ膨らみ、洞窟だけ 1 フレームが桁違いに重かった。
    /// GPU タイル層(TerrainLayers)が使っている tint と同じ値なので、
    /// 描き出しと実機の絵が構造的に一致する(前は 2 経路で明度の載せ方が違った)。
    def lit(w: World.World, x: Int32, y: Int32,
            items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        if (Stage.rec(w#stage)#kind != "cave") items
        else Render.tintedAll(
            LightGrid.toColor(LightGrid.brightnessAt(w#stage, w#light, x, y)), items)

    /// マスの明度で色を沈める(cave 以外は素通し)。板を 1 枚だけ置く所で使う。
    def litColor(w: World.World, x: Int32, y: Int32, color: Color): Color =
        let (br, bg, bb) = LightGrid.brightnessAt(w#stage, w#light, x, y);
        Color.rgb(color#r * br, color#g * bg, color#b * bb)

    // ── 動く物(実機・描き出し共通)──

    def gimmickItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        platformItems(vis, w) ::: blinkItems(vis, w) ::: springItems(vis, w)
            ::: coinItems(vis, w) ::: torchItems(vis, w) ::: checkpointItems(vis, w)
            ::: flagItems(w)

    /// 動く床(1 マス = 1 コマの並び)。
    def platformItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        let ts = Physics.tileSize();
        Stage.rec(w#stage)#platforms
            |> List.filter(p -> nearBox(vis, World.platformPosAt(w#motion, p, w#t),
                                        { x = Int32.toFloat64(p#wTiles) * ts, y = ts }))
            |> List.flatMap(p -> {
            let pos = World.platformPosAt(w#motion, p, w#t);
            List.range(0, p#wTiles) |> List.flatMap(i ->
                spriteAt(w, "platform", "deck",
                    { x = pos#x + Int32.toFloat64(i) * Physics.tileSize(), y = pos#y },
                    false, zDeco()))
        })

    /// 消える床(硬い間だけ見える。消える間際は点滅)。
    def blinkItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        let ts = Physics.tileSize();
        forM (c <- cellsIn(vis, w);
              if (Stage.blinkAt(w#stage, c#x, c#y) and World.blinkOn(w#motion, w#t, c#x, c#y));
              it <- spriteAt(w, "oneway", "plank",
                        { x = Int32.toFloat64(c#x) * ts, y = Int32.toFloat64(c#y) * ts },
                        false, zDeco()))
            yield it

    /// バネ(踏んだ直後だけ伸びたコマ)。
    def springItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        Stage.rec(w#stage)#springs |> List.filter(nearCell(vis)) |> List.flatMap(c -> {
            let live = Map.get((c#x, c#y), w#springT) |> Option.getWithDefault(0.0);
            let frame = if (live > 0.0) "launch" else "rest";
            let ts = Physics.tileSize();
            spriteAt(w, "spring", frame,
                { x = (Int32.toFloat64(c#x) + 0.5) * ts, y = Int32.toFloat64(c#y + 1) * ts - 1.0 },
                false, zDeco())
        })

    /// コイン(まだ取っていない物だけ・回転はコマ替え)。
    def coinItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        let frame = if (two(w, 5.0)) "spin_0" else "spin_1";
        Stage.rec(w#stage)#coins
            |> List.filter(c -> World.coinAlive(w, c) and nearCell(vis, c))
            |> List.flatMap(c -> {
                let pos = Stage.centerOf(c);
                spriteAt(w, "coin", frame, { x = pos#x, y = pos#y + 6.0 }, false, zCoin())
            })

    /// 松明(柄 + コマ替えの炎 + 洞窟では加算のぼんやり)。
    def torchItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        Stage.rec(w#stage)#torches |> List.filter(nearCell(vis)) |> List.flatMap(c -> {
            let pos = Stage.centerOf(c);
            let base = spriteAt(w, "torch", "base",
                { x = pos#x, y = pos#y + 6.0 }, false, zDeco());
            let ff = if (two(w, 8.0)) "flame_0" else "flame_1";
            let flame = spriteAt(w, "flame", ff,
                { x = pos#x, y = pos#y - 6.0 }, false, zDeco());
            let glow = if (Stage.rec(w#stage)#kind == "cave")
                Render.glowAt({ x = pos#x, y = pos#y - 4.0 }, 22.0,
                              Color.rgb(0.95, 0.65, 0.35),
                              { alpha = 0.35, blend = DrawCmd.BlendMode.Add }, zFx())
                else Nil;
            base ::: flame ::: glow
        })

    /// チェックポイントのランタン(点いたら on)。
    def checkpointItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        Stage.rec(w#stage)#checkpoints |> List.filter(nearCell(vis)) |> List.flatMap(c -> {
            let on = Set.memberOf((c#x, c#y), w#cpOn);
            let ts = Physics.tileSize();
            spriteAt(w, "checkpoint", if (on) "on" else "off",
                { x = (Int32.toFloat64(c#x) + 0.5) * ts, y = Int32.toFloat64(c#y + 1) * ts - 1.0 },
                false, zDeco())
        })

    /// ゴール旗(旗はコマ替えでなびく)。
    def flagItems(w: World.World): List[Render.PlacedItem] =
        let g = Stage.rec(w#stage)#goal;
        let frame = if (two(w, 3.0)) "wave_0" else "wave_1";
        let ts = Physics.tileSize();
        spriteAt(w, "flag", frame,
            { x = Int32.toFloat64(g#x) * ts + 2.0, y = Int32.toFloat64(g#y + 1) * ts - 1.0 },
            false, zDeco())

    // ── 主役・敵・弾 ──

    def actorItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        playerItems(w) ::: enemyItems(vis, w) ::: shotItems(vis, w)

    def playerItems(w: World.World): List[Render.PlacedItem] =
        let p = w#player;
        // 被弾後の無敵は点滅(消えるコマを作る)。
        let blinkOut = w#invuln > 0.0 and two(w, 12.0);
        if (blinkOut) Nil
        else {
            let body = p#body;
            let frame =
                if (not body#onGround) { if (body#vel#y < 0.0) "jump" else "fall" }
                else if (Float64.abs(body#vel#x) > 12.0) {
                    if (two(w, 8.0)) "run_0" else "run_1"
                } else "idle";
            let feet = { x = body#pos#x, y = body#pos#y + Physics.playerSize()#y * 0.5 };
            spriteAt(w, "player", frame, feet, p#facing < 0.0, zActor())
        }

    def enemyItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        w#enemies |> List.filter(e -> near(vis, e#pos)) |> List.flatMap(e -> {
            let first = two(w, 6.0);
            let (sprite, frame) = match e#behavior {
                case Enemies.Behavior.Walking(_)  => ("walker", if (first) "walk_0" else "walk_1")
                case Enemies.Behavior.Flying(_)   => ("flyer", if (first) "fly_0" else "fly_1")
                case Enemies.Behavior.Shooting(_) => ("shooter", if (first) "idle_0" else "idle_1")
            };
            let feet = { x = e#pos#x, y = e#pos#y + Enemies.sizeOf(e#behavior)#y * 0.5 };
            spriteAt(w, sprite, frame, feet, e#dir > 0.0, zActor())
        })

    def shotItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        w#shots |> List.filter(s -> near(vis, s#pos)) |> List.flatMap(s -> spriteAt(w, "shot", "ball", s#pos, false, zShot()))

    /// 絵 1 コマ。絵が無ければ仮色の箱(大きさは当たり箱と合わせる)。
    /// 洞窟では体の位置の明度で沈める(タイルと同じ丸め)。
    def spriteAt(w: World.World, sprite: String, frame: String, at: Vec2.Vec2,
                 flip: Bool, z: Int32): List[Render.PlacedItem] =
        let cx = Physics.tileOf(at#x);
        let cy = Physics.tileOf(at#y);
        let items = PxSprite.drawQuad(w#pxDoc, w#atlas, World.atlasName(),
                                      sprite, frame, at, flip, scale(), z)
            |> lit(w, cx, cy);
        RawDraw.orBoxAt({ x = at#x, y = at#y - 6.0 }, { x = 12.0, y = 12.0 },
            litColor(w, cx, cy, Theme.resolve(w#theme, "shirt")), z, items)

    // ── ぱっと出て消える演出 ──

    def fxItems(vis: Rect2.Rect2, w: World.World): List[Render.PlacedItem] =
        let dust = Theme.resolve(w#theme, "dust");
        let spark = Theme.resolve(w#theme, "coinLight");
        w#fx |> List.filter(f -> near(vis, f#pos)) |> List.flatMap(f -> {
            let age = Float64.max(0.0, (w#t - f#t0) / World.fxLifeSec());
            let fade = 1.0 - age;
            if (fade <= 0.0) Nil
            else if (f#kind == "land" or f#kind == "spring")
                // 砂煙: 足元から左右へ広がって薄れる。
                Render.fadeAll(fade * 0.6,
                    RawDraw.circleAt({ x = f#pos#x - 6.0 - age * 8.0, y = f#pos#y - 2.0 },
                                    3.0 + age * 2.0, dust, zFx())
                    :: RawDraw.circleAt({ x = f#pos#x + 6.0 + age * 8.0, y = f#pos#y - 2.0 },
                                       3.0 + age * 2.0, dust, zFx())
                    :: Nil)
            else if (f#kind == "stomp")
                // 星: その場で広がる十字。
                Render.fadeAll(fade,
                    RawDraw.boxAt(f#pos, { x = 2.0, y = 10.0 + age * 12.0 }, spark, zFx())
                    :: RawDraw.boxAt(f#pos, { x = 10.0 + age * 12.0, y = 2.0 }, spark, zFx())
                    :: Nil)
            else
                // コイン: 上へ抜ける光の粒。
                Render.fadeAll(fade,
                    RawDraw.circleAt({ x = f#pos#x, y = f#pos#y - age * 14.0 }, 3.0,
                                    spark, zFx()) :: Nil)
        })

    // ── HUD(カメラ非追従)──

    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let hearts = List.range(0, RulesDoc.rec(w#rules)#maxHearts) |> List.flatMap(i ->
            spriteAt(w, "ui", if (i < w#hearts) "heart" else "heart_empty",
                { x = 10.0 + Int32.toFloat64(i) * 12.0, y = 18.0 }, false, 100));
        let score = { at = { x = 560.0, y = 10.0 },
                      item = Render.text("${w#score}", ctx#atlas, 14.0, 100) };
        let name = { at = { x = 10.0, y = 24.0 },
                     item = Render.text(Stage.rec(w#stage)#name, ctx#atlas, 10.0, 100) };
        hearts ::: score :: name :: overlayItems(ctx, w)

    /// 場面の幕: clear / over の間だけ、薄い覆いと大きな字。
    def overlayItems(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        if (w#phase == "play") Nil
        else {
            let veil = { at = { x = 0.0, y = 0.0 },
                         item = RawDraw.box(design(), Theme.resolve(w#theme, "ink"), 98) };
            let msg = if (w#phase == "clear") UiText.rec(w#uiText)#clear else UiText.rec(w#uiText)#gameOver;
            let label = { at = { x = 250.0, y = 160.0 },
                          item = Render.text(msg, ctx#atlas, 28.0, 99) };
            Render.fadeAll(0.55, veil :: Nil) ::: label :: Nil
        }
}
