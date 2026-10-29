// FieldScreen — マップを歩く画面: 地面の動く側・家の影・人と小物（world）と、メニュー・店・会話のウィンドウ・暗転（HUD）。
// 地面の止まった絵はタイル層（View.tileLayers）。ここで描くのは見えているマスの動く地面だけ。
// 人と小物は足元の y の順に並べる（奥の物ほど先に描く）。
mod FieldScreen {
    use fge::{App, Depth, Dir4, Grid, RawDraw, Rect2, Render, Transition, UiTypewriter, Vec2, Yarn, ZStack}
    use ZOrder.{HudLayer, Layer}
    use Sheet.SheetId

    /// 描くのに要る値（ViewField.fieldIn が World から組む）。party = 隊列の全員（先頭から）、facing = 先頭の向き、
    /// npcs = マップに立っている人（加わった仲間と、依頼の段階で出る間の外の人は除いてある）・props = 今出ている小物、
    /// talkingTo = 話している人の id（その人は主人公の方を向く）、menu / shop = メニューと店のウィンドウ、
    /// talk = 画面の下の文のウィンドウ（会話・知らせ・店の台詞と確かめ）、transition = 暗転の種類と進み具合、
    /// things = マスにある物（WorldObject.objectsNow の今のマスと状態。無い物は描かない）。
    pub type alias In = {
        map = MapDoc.Doc,
        art = MapArt.Art,
        party = List[Walker],
        facing = Dir4.Dir4,
        npcs = List[MapDoc.Npc],
        props = List[MapDoc.Prop],
        things = List[Thing],
        talkingTo = Option[String],
        menu = Option[MenuView.In],
        shop = Option[ShopView.In],
        talk = Option[TalkBox],
        transition = Option[Cover],
        light = Option[Light],
        riding = Option[Vec2.Vec2]
    }

    /// 暗いマップの明かり: center = 先頭の絵の中心（px）・radius = 見えるマスの数（先頭のマスから）。明るいマップは None。
    pub type alias Light = { center = Vec2.Vec2, radius = Float64 }

    /// 画面を覆う物。Fade = 暗転（種類と進み具合 0..1）/ Flash = 出会いの点滅（進み具合 0..1）。
    pub enum Cover {
        case Fade(Transition.Kind, Float64)
        case Flash(Float64)
    }

    /// マスにある物 1 つ（種類・絵の名前・今のマス・状態）。
    pub type alias Thing = { kind = MapDoc.ObjectKind, sprite = String, x = Int32, y = Int32, state = WorldObject.ObjectState }

    /// 隊列の 1 人: 絵の名前・仮の四角の色・マスの左上の px（歩きの途中のずれを含む）・向き。
    pub type alias Walker = { who = String, placeholder = String, at = Vec2.Vec2, facing = Dir4.Dir4 }

    /// 会話のウィンドウに出す物: 話し手の呼び名・台詞・見えている字数・出し切ったか・選択肢（字と選べるか）とカーソル。
    pub type alias TalkBox = { speaker = String, text = String, shown = Int32, done = Bool,
                            choices = List[(String, Bool)], cursor = Int32 }

    def tile(): Float64 = Autotile.tile()

    // ── world ──

    pub def world(ctx: App.ViewCtx, env: WindowView.Env, field: In): List[(Layer, ZStack.Tree[Layer, Unit])] =
        let art = MapArt.rec(field#art);
        let visible = visibleCells(ctx#visible, field#map);
        let movingAt = depthOk -> visible |> List.flatMap(cell ->
            Map.getWithDefault((cell#x, cell#y), Nil, art#moving)
                |> List.filter(match (depth, _) -> depthOk(depth))
                |> List.flatMap(match (_, part) -> Sheet.drawTile(env#res#sheets, env#res#palette, env#t,
                    { part = part, at = FieldView.cellPx(cell), z = 0 })));
        let (flat, standing) = field#props |> List.partition(p -> p#flat);
        let (flatThings, standingThings) = field#things |> List.partition(isFlat);
        let underfoot = List.flatten(movingAt(d -> d > 0) :: (flat |> List.flatMap(propItems(env, field))) ::
                                     (flatThings |> List.filterMap(thingItems(env, field)) |> List.flatten) :: Nil);
        (Layer.Ground, ZStack.leaf(movingAt(d -> d == 0)))
            :: (Layer.Shade, ZStack.leaf(art#shadows))
            :: (Layer.Over, ZStack.leaf(underfoot))
            :: (Layer.Actors, ZStack.of(List.flatten(people(env, field) :: (standing |> List.map(propNode(env, field))) ::
                                                     (standingThings |> List.filterMap(thingNode(env, field))) :: Nil)))
            :: darkness(env, field, visible)
            :: Nil

    /// 暗いマップの墨: 見えているマスのうち、明かりの中心からのマスの距離が radius + 0.5 を超えるマスに墨を 1 枚。
    /// 明かりの縁の 1 マスの輪は、マスの 4 分の 1 の墨を市松に 2 枚（FC の階調はディザだけなので、なめらかな暗がりにしない）。
    def darkness(env: WindowView.Env, field: In, visible: List[Grid.Cell]): (Layer, ZStack.Tree[Layer, Unit]) =
        let ink = Palette.resolve(env#res#palette, "ink");
        let half = tile() / 2.0;
        let box = (at, size) -> Render.at(at, RawDraw.box(size, ink, 0));
        let items = field#light |> Option.map(light -> visible |> List.flatMap(cell -> {
            let px = FieldView.cellPx(cell);
            let dx = (px#x + half - light#center#x) / tile();
            let dy = (px#y + half - light#center#y) / tile();
            let d2 = dx * dx + dy * dy;
            let within = r -> d2 <= r * r;
            if (within(light#radius + 0.5)) Nil
            else if (within(light#radius + 1.5)) box(px, { x = half, y = half }) :: box({ x = px#x + half, y = px#y + half }, { x = half, y = half }) :: Nil
            else box(px, { x = tile(), y = tile() }) :: Nil
        })) |> Option.getWithDefault(Nil);
        (Layer.Dark, ZStack.leaf(items))

    def visibleCells(area: Rect2.Rect2, map: MapDoc.Doc): List[Grid.Cell] =
        Grid.cellsIn({ tileSize = tile(), area = area, cols = MapDoc.rec(map)#cols, rows = MapDoc.rec(map)#height,
                       margin = Grid.noMargin() })

    /// 小物の部品（その組の絵のファイルから。fps > 0 ならコマを回す）。
    def propPart(field: In, prop: MapDoc.Prop): Sheet.Part =
        let sheet = Tileset.sheetOf(MapDoc.rec(field#map)#tileset);
        let size = { x = tile(), y = tile() };
        if (prop#fps > 0.0) Sheet.cycling(sheet, prop#sprite, prop#fps, "fc10", size)
        else Sheet.part(sheet, prop#sprite, prop#frame, "fc10", size)

    def propAt(prop: MapDoc.Prop): Vec2.Vec2 = { x = prop#x * tile(), y = prop#y * tile() }

    def propItems(env: WindowView.Env, field: In, prop: MapDoc.Prop): List[Render.PlacedItem] =
        Sheet.draw(env#res#sheets, env#res#palette, env#t, { part = propPart(field, prop), at = propAt(prop), z = 0 })

    def propNode(env: WindowView.Env, field: In, prop: MapDoc.Prop): ZStack.Tree[Layer, Unit] =
        let foot = propAt(prop)#y + Sheet.sizeOf(env#res#sheets, propPart(field, prop))#y;
        ZStack.zIndex(Depth.orderAt(foot), ZStack.leaf(propItems(env, field, prop)))

    /// 物の絵の選び方。Lid = 閉じた物は「<絵の名前>」・開いた物は「<絵の名前>_open」（コマは base）/
    /// Frames(閉じた時, 開いた時) = 同じ絵のコマを替える（レバーの up / down）/
    /// Creature = 生き物（人の絵にあれば下向きの足踏み・敵の絵にあればそのコマを回す・どちらにも無ければその組の絵。化けた宝箱）/
    /// Still = 状態で絵を替えない（岩・トロッコ・飛び石・石碑。無い時だけ描かない）。
    enum Look {
        case Lid
        case Frames(String, String)
        case Creature
        case Still
    }

    /// 物の部品（絵の名前は thing#sprite）。どの絵かは種類の Look と状態だけで決める。無い物は描かない（通れる床が見える）。
    def thingPart(env: WindowView.Env, field: In, thing: Thing): Option[Sheet.Part] =
        let sheet = Tileset.sheetOf(MapDoc.rec(field#map)#tileset);
        let box = thingBoxOf(thing#kind);
        let (size, placeholder) = (box#size, box#placeholder);
        let still = (name, frame) -> Some(Sheet.part(sheet, name, frame, placeholder, size));
        match (box#look, thing#state) {
            case (_, WorldObject.ObjectState.Gone)                => None
            case (Look.Frames(closed, _), WorldObject.ObjectState.Closed) => still(thing#sprite, closed)
            case (Look.Frames(_, opened), WorldObject.ObjectState.Opened) => still(thing#sprite, opened)
            case (Look.Creature, _)                               => Some(creaturePart(env, sheet, thing#sprite, placeholder, size))
            case (Look.Still, _)                                  => still(thing#sprite, "base")
            case (Look.Lid, WorldObject.ObjectState.Opened)       => still(thing#sprite + "_open", "base")
            case (Look.Lid, WorldObject.ObjectState.Closed)       => still(thing#sprite, "base")
        }

    /// 生き物の部品: 人の絵（rpg.chars）にあれば下向きの 2 コマを時刻で、敵の絵（rpg.monsters）にあればそのコマを回し、
    /// どちらにも無ければその組の絵の base（宝箱に化けた敵）。
    def creaturePart(env: WindowView.Env, sheet: SheetId, sprite: String, placeholder: String, size: Vec2.Vec2): Sheet.Part =
        let has = id -> Map.get(id, env#res#sprites) |> Option.exists(doc -> Map.memberOf(sprite, doc#sprites));
        let step = Float64.floor(env#t * 2.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        if (has(SheetId.Chars)) Sheet.part(SheetId.Chars, sprite, "down_${Int32.modulo(step, 2)}", placeholder, size)
        else if (has(SheetId.Monsters)) Sheet.cycling(SheetId.Monsters, sprite, 2.0, placeholder, size)
        else Sheet.part(sheet, sprite, "base", placeholder, size)

    /// 種類ごとの絵の形: size = 絵が無い時の仮の四角の大きさ・placeholder = その色・look = 絵の選び方・
    /// flat = 床に敷く物（人と岩より奥の Over の層に描く。床のスイッチに載った岩が下に隠れない）。
    type alias ThingBox = { size = Vec2.Vec2, placeholder = String, look = Look, flat = Bool }

    def thingBoxOf(kind: MapDoc.ObjectKind): ThingBox =
        let one = { x = tile(), y = tile() };
        match kind {
            case MapDoc.ObjectKind.Chest(_)    => { size = one, placeholder = "fc28", look = Look.Lid, flat = false }
            case MapDoc.ObjectKind.Door(_)     => { size = { x = 3.0 * tile(), y = 3.0 * tile() }, placeholder = "fc04", look = Look.Lid, flat = false }
            case MapDoc.ObjectKind.Lever(_)    => { size = one, placeholder = "fc16", look = Look.Frames("up", "down"), flat = false }
            case MapDoc.ObjectKind.Gate(_)     => { size = one, placeholder = "fc10", look = Look.Lid, flat = false }
            case MapDoc.ObjectKind.Guard(_)    => { size = one, placeholder = "fc06", look = Look.Creature, flat = false }
            case MapDoc.ObjectKind.Plate(_)    => { size = one, placeholder = "fc10", look = Look.Frames("up", "down"), flat = true }
            case MapDoc.ObjectKind.Rock        => { size = one, placeholder = "fc2D", look = Look.Still, flat = false }
            case MapDoc.ObjectKind.Cart(_)     => { size = one, placeholder = "fc2D", look = Look.Still, flat = false }
            case MapDoc.ObjectKind.Junction(_) => { size = one, placeholder = "fc18", look = Look.Frames("north", "south"), flat = true }
            case MapDoc.ObjectKind.Crystal(_)  => { size = { x = tile(), y = 2.0 * tile() }, placeholder = "fc22", look = Look.Frames("f0", "f1"), flat = false }
            case MapDoc.ObjectKind.Bridge(_)   => { size = one, placeholder = "fc0C", look = Look.Still, flat = true }
            case MapDoc.ObjectKind.Sign(_)     => { size = { x = tile(), y = 2.0 * tile() }, placeholder = "fc00", look = Look.Still, flat = false }
        }

    /// 床に敷く物か（thingBoxOf の flat）。
    def isFlat(thing: Thing): Bool = thingBoxOf(thing#kind)#flat

    /// 物は、絵の下端の中央をマスの下端の中央に合わせる（3 マス幅の扉は扉のマスの左右と上の壁に、大きい敵の絵は上と左右に重なる）。
    def thingNode(env: WindowView.Env, field: In, thing: Thing): Option[ZStack.Tree[Layer, Unit]] =
        let foot = FieldView.cellPx({ x = thing#x, y = thing#y })#y + tile();
        thingItems(env, field, thing) |> Option.map(items -> ZStack.zIndex(Depth.orderAt(foot), ZStack.leaf(items)))

    def thingItems(env: WindowView.Env, field: In, thing: Thing): Option[List[Render.PlacedItem]] =
        thingPart(env, field, thing) |> Option.map(part -> {
            let size = Sheet.sizeOf(env#res#sheets, part);
            let cell = FieldView.cellPx({ x = thing#x, y = thing#y });
            let at = { x = cell#x + (tile() - size#x) / 2.0, y = cell#y + tile() - size#y };
            Sheet.draw(env#res#sheets, env#res#palette, env#t, { part = part, at = at, z = 0 })
        })

    /// 人（マップの人と隊列）。足元はマスの下端。
    /// 隊列は後ろの人ほど足元を少し奥に数える（出入口の直後に同じマスへ重なった時、先頭が手前に出る）。
    def people(env: WindowView.Env, field: In): List[ZStack.Tree[Layer, Unit]] =
        let npcs = field#npcs |> List.map(npc -> {
            let facing = if (field#talkingTo == Some(npc#id)) Dir4.opposite(field#facing) else npc#facing;
            personNode(env, npc#sprite, "fc00", facing, FieldView.cellPx({ x = npc#x, y = npc#y }), 0.0)
        });
        let walkers = field#party |> List.zipWithIndex |> List.map(match (i, walker) ->
            personNode(env, walker#who, walker#placeholder, walker#facing, walker#at, Int32.toFloat64(i) * 0.25));
        let cart = field#riding |> Option.map(at -> {
            let sprite = if (field#facing == Dir4.Dir4.Up or field#facing == Dir4.Dir4.Down) "minecart_v" else "minecart";
            let part = Sheet.part(SheetId.Mine, sprite, "base", "fc2D", { x = tile(), y = tile() });
            let lifted = { x = at#x, y = at#y + 4.0 };
            ZStack.zIndex(Depth.orderAt(at#y + tile() + 0.5), ZStack.leaf(Sheet.draw(env#res#sheets, env#res#palette, env#t, { part = part, at = lifted, z = 0 })))
        }) |> Option.toList;
        List.flatten(walkers :: cart :: npcs :: Nil)

    def personNode(env: WindowView.Env, who: String, placeholder: String, facing: Dir4.Dir4, at: Vec2.Vec2, behind: Float64): ZStack.Tree[Layer, Unit] =
        ZStack.zIndex(Depth.orderAt(at#y + tile() - behind),
            ZStack.leaf(FieldView.personAt(env, { who = who, facing = FieldView.facingOf(facing), placeholder = placeholder }, at, 0)))

    // ── HUD ──

    pub def hud(env: WindowView.Env, viewport: Vec2.Vec2, field: In): List[(HudLayer, ZStack.Tree[HudLayer, Unit])] =
        let menu = field#menu |> Option.map(MenuView.tree(env)) |> Option.getWithDefault(ZStack.leaf(Nil));
        let shop = field#shop |> Option.map(ShopView.tree(env)) |> Option.getWithDefault(ZStack.leaf(Nil));
        let talk = field#talk |> Option.map(talkTree(env)) |> Option.getWithDefault(ZStack.leaf(Nil));
        let window = ZStack.of(menu :: shop :: talk :: Nil);
        let transition = field#transition |> Option.map(transitionItems(env, viewport)) |> Option.getWithDefault(Nil);
        (HudLayer.Window, window) :: (HudLayer.Transition, ZStack.leaf(transition)) :: Nil

    /// 会話のウィンドウ（画面の下）の場所と、1 枚に出せる行の数・1 行の幅（px）。
    def talkRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 19, cols = 30, rows = 9 })

    def talkRows(): Int32 = 4

    def talkWidth(): Float64 = talkRect()#size#x - WindowView.padLeft() - WindowView.cell()

    /// 会話のウィンドウと、選択肢があれば右上の小さいウィンドウ。
    /// WhyNot: 先頭の talkRows 行で切らない — 切った残りは出し切っても見えないまま次の台詞へ送られ、黙って消える。
    /// 後ろの talkRows 行を出せば、文字送りで上へ流れて全部が一度は見える（収まらない台詞は overflowingLines が止める）。
    def talkTree(env: WindowView.Env, talk: TalkBox): ZStack.Tree[HudLayer, Unit] =
        let all = WindowView.talkLines(env, talk#speaker, talk#text, talk#shown, talkWidth());
        let lines = List.drop(Int32.max(0, List.length(all) - talkRows()), all);
        let message = WindowView.message(env, talkRect(), lines, talk#done and List.isEmpty(talk#choices), 0);
        let count = List.length(talk#choices);
        let choices = if (count == 0) Nil else {
            let small = WindowView.grid({ col = 22, row = 16 - 2 * count, cols = 9, rows = 2 * count + 2 });
            WindowView.choices(env, { rect = small, selected = talk#cursor, entries = talk#choices }, 0)
        };
        ZStack.of(ZStack.leaf(message) :: ZStack.leaf(choices) :: Nil)

    def transitionItems(env: WindowView.Env, viewport: Vec2.Vec2, cover: Cover): List[Render.PlacedItem] = match cover {
        case Cover.Fade(kind, t) =>
            Transition.itemsAt({ kind = kind, t = t, viewport = viewport, color = Palette.resolve(env#res#palette, "ink"), z = 0 })
        case Cover.Flash(t) if Int32.modulo(Float64.floor(t * 6.0) |> Float64.tryToInt32 |> Option.getWithDefault(0), 2) == 0 =>
            Transition.itemsAt({ kind = Transition.Kind.FadeOut, t = 1.0, viewport = viewport, color = Palette.resolve(env#res#palette, "fc30"), z = 0 })
        case Cover.Flash(_) => Nil
    }

    /// 出し切ると会話のウィンドウ 1 枚（talkRows 行）に収まらない台詞の場所（file:行）。呼び名の頭と折り返しを数に入れる。
    /// 台詞 1 行 = ウィンドウ 1 枚なので、ここに出た台詞は yarn で 2 行に分ける（TestDocs が全部の台詞で見る）。
    pub def overflowingLines(env: WindowView.Env, lines: List[Yarn.Line]): List[String] =
        lines
            |> List.filter(line -> {
                let speaker = TextDoc.speakerName(line#speaker, env#res#text);
                List.length(WindowView.talkLines(env, speaker, line#text, String.length(line#text), talkWidth())) > talkRows()
            })
            |> List.map(line -> Yarn.sourceText(line#source))

    /// 文字送りの値からウィンドウに出す物を組む。
    pub def buildTalk(speaker: String, reveal: UiTypewriter.Reveal, choices: List[(String, Bool)], cursor: Int32): TalkBox =
        { speaker = speaker, text = reveal#text, shown = UiTypewriter.visibleCount(reveal),
          done = UiTypewriter.isDone(reveal), choices = choices, cursor = cursor }
}
