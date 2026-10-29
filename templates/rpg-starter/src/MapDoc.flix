// MapDoc — マップ 1 枚（assets/maps/<名前>.map.json）の Doc 層と、マップを指す名前（MapId）。
// 格子は読んだ時に 1 回だけ Vector[Vector[Char]] にし、出入口と人はマスで引ける表にして持つ（毎フレーム文字列から引かない）。
// 文字の絵と通れるかは Tileset。fail-open — 読めない欄は既定、読めない行（出入口・人・小物）は飛ばして 1 行言う。
mod MapDoc {
    use fge::{Dir4, DocJson, JsonCodec, Log}
    use Util.Json.Json

    /// マップを指す名前。作れるのは idOf（読んだマップの表にある名前）だけ。
    enum MapKey with Eq, Order, ToString {
        case Key(String)
    }
    pub type alias MapId = MapKey

    /// 出入口 1 つ: place で通ると、to のマップの (spawnX, spawnY) へ facing を向いて移る。
    /// gate = 閉じる条件（無ければ誰でも通れる）。
    pub type alias Exit = { id = String, place = ExitPlace, to = String, spawnX = Int32, spawnY = Int32, facing = Dir4.Dir4,
                            gate = Option[Gate] }

    /// 出入口の通り方。Cell = そのマスに着いたら（扉・階段・道の端）/
    /// Edge = マップの端のマスから、その向きの外へ出ようとしたら（村の外周。書いた向きの辺の全部のマス）/
    /// Nowhere = 歩いては通らない（会話の <<warp 出口の id>> だけが通る。ボスの後に坑道の入口へ戻す類）。
    pub enum ExitPlace {
        case Cell(Int32, Int32)
        case Edge(List[Dir4.Dir4])
        case Nowhere
    }

    /// 着いたら通るマス（端の出入口と歩いては通らない出入口は None）。
    pub def cellOf(exit: Exit): Option[(Int32, Int32)] = match exit#place {
        case ExitPlace.Cell(x, y) => Some((x, y))
        case ExitPlace.Edge(_)    => None
        case ExitPlace.Nowhere    => None
    }

    /// その向きの端から出る出入口か。
    def leavesBy(dir: Dir4.Dir4, exit: Exit): Bool = match exit#place {
        case ExitPlace.Cell(_, _) => false
        case ExitPlace.Edge(dirs) => List.memberOf(dir, dirs)
        case ExitPlace.Nowhere    => false
    }

    /// id の出入口（会話の <<warp>> が引く）。
    pub def exitNamed(id: String, d: Doc): Option[Exit] = rec(d)#exits |> List.find(e -> e#id == id)

    /// 依頼の段階で出る間（since の段階から until の段階まで。両端を含み、None はその側に限りが無い）。
    /// 人と小物に書き、泉が湧いた後の村（水の戻った泉と集まる人）を同じマップのまま描き分ける。
    pub type alias Span = { since = Option[Quest.Quest], until = Option[Quest.Quest] }

    /// 段階 q の間に出るか。
    def isShownIn(q: Quest.Quest, span: Span): Bool =
        Option.forAll(first -> q >= first, span#since) and Option.forAll(last -> q <= last, span#until)

    /// その人が今マップに立っているか: 依頼の段階 q で出る間にいて、加わってマップから消えた仲間（absent の id）でない。
    def isStanding(absent: Set[String], q: Quest.Quest, npc: Npc): Bool =
        not Set.memberOf(npc#id, absent) and isShownIn(q, npc#span)

    /// (x, y) に今立っている人（同じマスに段階の違う人を何人書いてもよい。立っているのは isStanding の 1 人目）。
    pub def standingAt(absent: Set[String], q: Quest.Quest, x: Int32, y: Int32, d: Doc): Option[Npc] =
        Map.getWithDefault((x, y), Nil, rec(d)#npcAt) |> List.find(isStanding(absent, q))

    /// 今立っている人の全部（Doc の並び）。
    pub def standingOf(absent: Set[String], q: Quest.Quest, d: Doc): List[Npc] =
        rec(d)#npcs |> List.filter(isStanding(absent, q))

    /// 段階 q の間に出る小物（Doc の並び）。
    pub def propsIn(q: Quest.Quest, d: Doc): List[Prop] = rec(d)#props |> List.filter(p -> isShownIn(q, p#span))

    /// 出入口を閉じる条件: member が加わるまで、このマスへ進めない・この端から出られない（進もうとすると node の会話を開く）。
    pub type alias Gate = { member = Member.Member, node = String }

    /// 人 1 人: sprite は rpg.chars.sprite.json の絵の名前・node は話しかけた時に開く会話のノード。
    /// id が仲間の名前（Member.idOf）の人は、その仲間が加わるとマップから消える（隊列に入る）。
    /// span = 依頼の段階で出る間（questFrom / questUntil の欄。書かなければいつでも）。
    pub type alias Npc = { id = String, sprite = String, x = Int32, y = Int32, facing = Dir4.Dir4, node = String, span = Span }

    /// マスにある物の種類と、その種類だけが使う値（JSON は平らな 1 行で、読む時に組む）。規則は WorldObject に kind ごとに置く。
    ///   Chest = 宝箱（item = 中の道具・無ければ None / count = その数 / gold = 中のお金）
    ///   Door  = 鍵の掛かった扉（key = 開ける道具。ふくろにあれば開き、減らさない）
    ///   Lever = 壁のレバー（調べると flag の旗を立てる・下ろす。壁のマスに置き、前の床から調べる）
    ///   Gate  = 開く物（flag の旗が openWhen の時だけ通れる。鉄格子・がれき。絵は sprite）
    ///   Guard = 番をする者（調べると node の会話を開く。固定の戦いは会話の <<fight 敵 勝ちのノード>>、消すのは勝ちのノードの <<open id>>）
    ///   Plate = 床のスイッチ（hold = false: 先頭が踏むと flag の旗を立てる / hold = true: 同じ flag の床が全部岩で押さえられると旗を立てる。どちらも立てたまま）
    ///   Rock  = 押せる岩（歩いて押すと 1 マス動く。今のマスは場面の値で、マップを出ると Doc の位置へ戻る）
    ///   Cart  = トロッコ（調べると node の会話。<<ride>> で dir の向きへレールを走り、レールの終わりで降りる）
    ///   Junction = レールの分かれ目（flag の旗が下りていれば dir・立っていれば dirOn へ曲がる。上を歩ける）
    ///   Crystal = 水晶（order の順に調べて点ける。違えば同じ flag の水晶が全部消え、全部点くと flag の旗を立てる）
    ///   Bridge = 飛び石（flag の旗が立つと現れ、水のマスでも通れる。立つまでは描かない）
    ///   Sign  = 読む物（石碑。調べると node の会話を開く。マスを塞ぐ）
    pub enum ObjectKind {
        case Chest(ChestContents)
        case Door({ key = ItemsDoc.ItemId })
        case Lever({ flag = Flag.FlagId })
        case Gate({ flag = Flag.FlagId, openWhen = Bool })
        case Guard({ node = String })
        case Plate({ flag = Flag.FlagId, hold = Bool })
        case Rock
        case Cart({ dir = Dir4.Dir4, node = String })
        case Junction({ flag = Flag.FlagId, dir = Dir4.Dir4, dirOn = Dir4.Dir4 })
        case Crystal({ flag = Flag.FlagId, order = Int32 })
        case Bridge({ flag = Flag.FlagId })
        case Sign({ node = String })
    }

    /// 種類ごとの変わらない値（その物の今の状態に依らない物）。
    ///   sprite   = 既定の絵（行に sprite を書かない時）
    ///   raises   = 立てる・下ろす旗（Res.flagProblemsOf が、読む旗に立てる物があるかを見る）
    ///   reads    = 読むだけの旗
    ///   node     = 開く会話のノード（会話の語彙の「コードが開くノード」）
    ///   flat     = 床に敷く物（マスを塞がず、絵は人と岩より奥の層）
    ///   steps    = 着いた時に WorldObject.onArrive が何かする
    ///   pushable = 塞がれて押された時に WorldObject.onPush が何かする
    pub type alias KindProfile = { sprite = String, raises = Option[Flag.FlagId], reads = Option[Flag.FlagId], node = Option[String],
                                   flat = Bool, steps = Bool, pushable = Bool }

    /// 種類の変わらない値（KindProfile）。種類を足す時の網羅はここが受け持つ。
    pub def profileOf(kind: ObjectKind): KindProfile =
        let base = { sprite = "", raises = None, reads = None, node = None, flat = false, steps = false, pushable = false };
        match kind {
            case ObjectKind.Chest(_)    => { sprite = "chest" | base }
            case ObjectKind.Door(_)     => { sprite = "boss_door" | base }
            case ObjectKind.Lever(l)    => { sprite = "lever", raises = Some(l#flag) | base }
            case ObjectKind.Gate(g)     => { sprite = "gate_bars", reads = Some(g#flag) | base }
            case ObjectKind.Guard(g)    => { sprite = "goblin_guard", node = Some(g#node) | base }
            case ObjectKind.Plate(p)    => { sprite = "plate", raises = Some(p#flag), flat = true, steps = true | base }
            case ObjectKind.Rock        => { sprite = "boulder", pushable = true | base }
            case ObjectKind.Cart(c)     => { sprite = "minecart", node = Some(c#node) | base }
            case ObjectKind.Junction(j) => { sprite = "rail_switch", reads = Some(j#flag), flat = true | base }
            case ObjectKind.Crystal(c)  => { sprite = "crystal_l", raises = Some(c#flag) | base }
            case ObjectKind.Bridge(b)   => { sprite = "stepping_stone", reads = Some(b#flag), flat = true | base }
            case ObjectKind.Sign(s)     => { sprite = "tablet_l", node = Some(s#node) | base }
        }

    /// 宝箱の中身（ObjectKind.Chest の値）。
    pub type alias ChestContents = { item = Option[ItemsDoc.ItemId], count = Int32, gold = Int32 }

    /// マスにある物 1 つ。id はマップの中で 1 つだけの名前（開けた旗の鍵）・x, y は Doc の位置（今の位置は WorldObject.objectsNow）・
    /// sprite はその組の絵のファイルの絵の名前（書かなければ種類の既定）。
    pub type alias Object = { id = String, x = Int32, y = Int32, sprite = String, kind = ObjectKind }

    /// 着くと node の会話を開くマス（台詞が出ずに終わるノードならウィンドウは開かない）。
    pub type alias Event = { x = Int32, y = Int32, node = String }

    /// 出会いの組 1 つ（敵の名前の並びと、選ばれやすさ）。行が 1 つも無いマップでは次の戦いまでの歩数を数えない。
    pub type alias Encounter = { foes = List[String], weight = Int32 }

    /// 小物 1 つ（通れるかには効かない。塞ぎたいマスは格子の文字で塞ぐ）。x, y はマス（半マスも書ける）。
    /// fps > 0 ならコマを名前の順に回し、0 なら frame の 1 コマ。flat は床に敷く物（人より奥に描く）。span = 依頼の段階で出る間。
    pub type alias Prop = { sprite = String, frame = String, fps = Float64, flat = Bool, x = Float64, y = Float64, span = Span }

    /// マップ 1 枚。battleBack = このマップで戦う時の背景の帯（rpg.battlefx.sprite.json の絵の名前）、
    /// dark = 暗い（先頭のまわりしか見えない。たいまつで広がる）、steps = 次の戦いまでの歩数を引く範囲（None なら rules の minSteps..maxSteps）、
    /// grid は rows を Vector にした物、exitAt・npcAt・eventAt はマス → その物（objects は動く物があるのでマスで引かない。WorldObject.objectsNow）、
    /// problems は読む時に既定へ落とした欄・飛ばした行（load が 1 行ずつ言う）。
    pub type alias Rec = {
        version = Int32,
        title = String,
        tileset = Tileset.TilesetId,
        battleBack = String,
        dark = Bool,
        steps = Option[(Int32, Int32)],
        rows = List[String],
        grid = Vector[Vector[Char]],
        cols = Int32,
        height = Int32,
        exits = List[Exit],
        npcs = List[Npc],
        props = List[Prop],
        objects = List[Object],
        events = List[Event],
        encounter = List[Encounter],
        exitAt = Map[(Int32, Int32), Exit],
        npcAt = Map[(Int32, Int32), List[Npc]],
        eventAt = Map[(Int32, Int32), Event],
        problems = List[String]
    }

    /// WhyNot: 外で組ませない — grid と *At の表は rows と一覧の欄から作った物で、build を通らないと食い違う。
    enum MapDocOf(Rec)

    /// 読んだマップ（作るのは fromJson と既定だけ）。
    pub type alias Doc = MapDocOf

    pub def rec(d: Doc): Rec = match d { case MapDocOf.MapDocOf(r) => r }

    /// 読み込むマップの名前（assets/maps/<名前>.map.json）。マップを足したらここに 1 行足す。
    pub def names(): List[String] =
        "village" :: "chief_house" :: "smithy" :: "inn" :: "shop" :: "world" :: "toto_cave" :: "mine_b1" :: "mine_b2" :: "mine_b3" :: Nil

    /// files（assets/maps の中のファイルの名前かパス）のうち、names に無い *.map.json の名前。
    pub def unlistedIn(files: List[String]): List[String] =
        let listed = names() |> List.toSet;
        files |> List.map(file -> file |> String.splitOn(substr = "/") |> List.last |> Option.getWithDefault(file))
            |> List.filter(String.endsWith(suffix = ".map.json"))
            |> List.map(String.dropRight(String.length(".map.json")))
            |> List.filter(name -> not Set.memberOf(name, listed))

    pub def pathOf(name: String): String = "assets/maps/${name}.map.json"

    /// マップの表（名前 → マップ）。
    pub type alias Table = Map[String, Doc]

    /// 表にある名前なら MapId。
    pub def idOf(table: Table, name: String): Option[MapId] =
        if (Map.memberOf(name, table)) Some(MapKey.Key(name)) else None

    pub def nameOf(id: MapId): String = match id { case MapKey.Key(name) => name }

    /// MapId のマップ（読み直しで消えていれば None）。
    pub def docOf(table: Table, id: MapId): Option[Doc] = Map.get(nameOf(id), table)

    /// 既定（読めない時の 1 マスの草地。出入口も人も無い）。
    def defaults(): Doc = build({ version = 1, title = "", tileset = Tileset.TilesetId.Village, battleBack = "bg_plains", dark = false, steps = None, rows = "." :: Nil,
                                      exits = Nil, npcs = Nil, props = Nil, objects = Nil, events = Nil, encounter = Nil, problems = Nil })

    def build(spec: { version = Int32, title = String, tileset = Tileset.TilesetId, battleBack = String, dark = Bool, steps = Option[(Int32, Int32)],
                      rows = List[String], exits = List[Exit], npcs = List[Npc], props = List[Prop], objects = List[Object], events = List[Event],
                      encounter = List[Encounter], problems = List[String] }): Doc =
        let grid = spec#rows |> List.map(row -> String.toList(row) |> List.toVector) |> List.toVector;
        MapDocOf.MapDocOf({ version = spec#version, title = spec#title, tileset = spec#tileset, battleBack = spec#battleBack,
                  dark = spec#dark, steps = spec#steps, rows = spec#rows, grid = grid,
                  cols = spec#rows |> List.map(String.length) |> List.maximum |> Option.getWithDefault(0),
                  height = List.length(spec#rows),
                  exits = spec#exits, npcs = spec#npcs, props = spec#props,
                  objects = spec#objects, events = spec#events, encounter = spec#encounter,
                  exitAt = spec#exits |> List.filterMap(e -> cellOf(e) |> Option.map(cell -> (cell, e))) |> List.toMap,
                  npcAt = spec#npcs |> List.foldRight((n, acc) -> Map.insertWith((mine, rest) -> List.append(mine, rest), (n#x, n#y), n :: Nil, acc), Map.empty()),
                  eventAt = spec#events |> List.map(e -> ((e#x, e#y), e)) |> List.toMap,
                  problems = spec#problems })

    /// (x, y) から dir へ 1 マス進むと格子の外へ出る時の、その向きの端の出入口（Doc の並びで最初の 1 つ）。
    pub def edgeExitOf(x: Int32, y: Int32, dir: Dir4.Dir4, d: Doc): Option[Exit] =
        let (dx, dy) = Dir4.delta(dir);
        let (nx, ny) = (x + dx, y + dy);
        let outside = nx < 0 or ny < 0 or nx >= rec(d)#cols or ny >= rec(d)#height;
        if (outside) rec(d)#exits |> List.find(leavesBy(dir)) else None

    /// (x, y) の文字（格子の外・短い行の右は None）。
    pub def charAt(x: Int32, y: Int32, d: Doc): Option[Char] =
        Vector.nth(y, rec(d)#grid) |> Option.flatMap(Vector.nth(x))

    // ── 読み込み ──

    /// テキストから Doc へ（fail-open）。JSON でなければ None。物の道具の名前は items で ItemId に引く。
    pub def fromJson(items: ItemsDoc.Doc, name: String, text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot(items, name), text)

    /// name のマップを読む。読めない・壊れているときは defaults。既定へ落とした欄と飛ばした行は problems に残す（Res.problemsOf が言う）。
    def load(items: ItemsDoc.Doc, name: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson(items, name), defaults(), pathOf(name))

    /// names の全部のマップを読む（物の道具の名前は items で引く）。
    pub def loadTable(items: ItemsDoc.Doc): Table \ Fs.FileRead =
        names() |> List.map(name -> (name, load(items, name))) |> List.toMap

    def fromRoot(items: ItemsDoc.Doc, name: String, root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let tilesetName = JsonCodec.stringOr("tileset", Tileset.nameOf(d#tileset), root);
        let (tileset, tilesetProblem) = match Tileset.idOf(tilesetName) {
            case Some(id) => (id, Nil)
            case None     => (d#tileset, Log.fellBackLine("map", "${name} の tileset '${tilesetName}'", "village", "知らない組") :: Nil)
        };
        let rows = Map.get("rows", root)
            |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
            |> Option.filter(xs -> not List.isEmpty(xs))
            |> Option.getWithDefault(d#rows);
        let (exits, exitProblems) = listOf(name, "exits", exitOf, root);
        let (npcs, npcProblems) = listOf(name, "npcs", npcOf, root);
        let (props, propProblems) = listOf(name, "props", propOf, root);
        let (objects, objectProblems) = objectsOf(items, name, root);
        let (events, eventProblems) = listOf(name, "events", eventOf, root);
        let (encounter, encounterProblems) = listOf(name, "encounter", encounterOf, root);
        let (steps, stepsProblem) = stepsOf(name, root);
        build({ version = JsonCodec.intOr("version", d#version, root),
                title = JsonCodec.stringOr("title", d#title, root),
                tileset = tileset, battleBack = JsonCodec.stringOr("battleBack", d#battleBack, root),
                dark = JsonCodec.boolOr("dark", false, root), steps = steps,
                rows = rows, exits = exits, npcs = npcs, props = props,
                objects = objects, events = events, encounter = encounter,
                problems = List.flatten(tilesetProblem :: stepsProblem :: exitProblems :: npcProblems :: propProblems ::
                                        objectProblems :: eventProblems :: encounterProblems :: Nil) })

    /// minSteps / maxSteps の欄（どちらも 1 以上で min ≤ max なら Some。両方無ければ None で rules の範囲）。
    /// WhyNot: 片方だけ・逆さまの範囲を片方の値で埋めない — 書き損じで出会いが黙って多く・少なくなる。rules の範囲へ落として 1 行言う。
    def stepsOf(name: String, root: Map[String, Json]): (Option[(Int32, Int32)], List[String]) =
        match (intAt("minSteps", root), intAt("maxSteps", root)) {
            case (None, None) => (None, Nil)
            case (Some(lo), Some(hi)) if lo >= 1 and lo <= hi => (Some((lo, hi)), Nil)
            case _ => (None, Log.fellBackLine("map", "${name} の minSteps / maxSteps", "rules の範囲", "片方だけか、1 未満か、min > max") :: Nil)
        }

    /// 一覧の欄を 1 行ずつ読む。読めない行は飛ばし、何行目かを問題の行として返す。
    def listOf(name: String, field: String, decode: Map[String, Json] -> Option[a], root: Map[String, Json]): (List[a], List[String]) =
        let decoded = Map.get(field, root)
            |> Option.flatMap(JsonCodec.decodeList(json -> Some(json)))
            |> Option.getWithDefault(Nil)
            |> List.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(decode));
        let problems = decoded |> List.zipWithIndex |> List.filterMap(match (i, row) ->
            if (Option.isEmpty(row)) Some("[map] ${name} の ${field} の ${i + 1} 行目を読めないので飛ばす") else None);
        (List.filterMap(x -> x, decoded), problems)

    def intAt(key: String, obj: Map[String, Json]): Option[Int32] = Map.get(key, obj) |> Option.flatMap(JsonCodec.expectInt)

    def textAt(key: String, obj: Map[String, Json]): Option[String] = Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString)

    def dirAt(key: String, obj: Map[String, Json]): Option[Dir4.Dir4] = textAt(key, obj) |> Option.flatMap(DirName.dirOf)

    def exitOf(obj: Map[String, Json]): Option[Exit] =
        forM (id <- textAt("id", obj); place <- placeAt(obj); to <- textAt("to", obj);
              spawnX <- intAt("spawnX", obj); spawnY <- intAt("spawnY", obj); gate <- gateAt(obj))
        yield { id = id, place = place, to = to, spawnX = spawnX, spawnY = spawnY,
                facing = dirAt("facing", obj) |> Option.getWithDefault(Dir4.Dir4.Down), gate = gate }

    /// edge の欄（空・無し = x, y のマス / all = 4 辺 / up・down・left・right = その辺 / none = 歩いては通らない）。
    /// 知らない名前と、edge も x, y も無い行は None。
    /// WhyNot: x, y の無い行を「歩いては通らない」と読まない — x, y の書き忘れで、出口が黙ってどこからも通れなくなる。none と書かせる。
    def placeAt(obj: Map[String, Json]): Option[ExitPlace] =
        match textAt("edge", obj) |> Option.getWithDefault("") {
            case ""     => forM (x <- intAt("x", obj); y <- intAt("y", obj)) yield ExitPlace.Cell(x, y)
            case "all"  => Some(ExitPlace.Edge(Dir4.all()))
            case "none" => Some(ExitPlace.Nowhere)
            case name  => DirName.dirOf(name) |> Option.map(dir -> ExitPlace.Edge(dir :: Nil))
        }

    /// gate と gateNode の欄: gate が無い・空なら Some(None)、仲間の名前と空でない gateNode なら Some(Some(閉じる条件))。
    /// WhyNot: 知らない名前・gateNode の無い gate を gate 無しへ落とさない — 書き損じで、閉じておくはずの出口が黙って開く。
    /// 行ごと読めない扱いにして言う（出口の行ごと消える。扉のマスなら壁になり、道のマスなら移らない行き止まりになる）。
    def gateAt(obj: Map[String, Json]): Option[Option[Gate]] =
        let name = textAt("gate", obj) |> Option.getWithDefault("");
        let node = textAt("gateNode", obj) |> Option.getWithDefault("");
        if (String.isEmpty(name)) Some(None)
        else forM (member <- Member.memberOf(name); open <- if (String.isEmpty(node)) None else Some(node))
             yield Some({ member = member, node = open })

    def npcOf(obj: Map[String, Json]): Option[Npc] =
        forM (id <- textAt("id", obj); sprite <- textAt("sprite", obj); x <- intAt("x", obj); y <- intAt("y", obj); span <- spanAt(obj))
        yield { id = id, sprite = sprite, x = x, y = y,
                facing = dirAt("facing", obj) |> Option.getWithDefault(Dir4.Dir4.Down),
                node = textAt("node", obj) |> Option.getWithDefault(""), span = span }

    def propOf(obj: Map[String, Json]): Option[Prop] =
        forM (sprite <- textAt("sprite", obj);
              x <- Map.get("x", obj) |> Option.flatMap(JsonCodec.expectFloat);
              y <- Map.get("y", obj) |> Option.flatMap(JsonCodec.expectFloat);
              span <- spanAt(obj))
        yield { sprite = sprite, x = x, y = y,
                frame = JsonCodec.stringOr("frame", "idle", obj),
                fps = JsonCodec.floatOr("fps", 0.0, obj),
                flat = JsonCodec.boolOr("flat", false, obj), span = span }

    /// questFrom / questUntil の欄（依頼の段階の名前。無し・空ならその側に限りが無い）。知らない名前は None（行ごと読めない）。
    /// WhyNot: 知らない名前を「限り無し」へ落とさない — 書き損じで、泉が湧く前から湧いた後の人が立つ。
    def spanAt(obj: Map[String, Json]): Option[Span] =
        let bound = key -> match textAt(key, obj) |> Option.getWithDefault("") {
            case ""   => Some(None)
            case name => Quest.questOf(name) |> Option.map(Some)
        };
        forM (first <- bound("questFrom"); last <- bound("questUntil")) yield { since = first, until = last }

    /// objects の欄を 1 行ずつ読む。読めない行は飛ばし、何行目かとわけを問題の行として返す。
    /// WhyNot: 書き損じた道具の名前を「無し」へ落とさない — 扉なら鍵が無いのに開き、宝箱なら空になって、どちらも黙って遊びが変わる。
    def objectsOf(items: ItemsDoc.Doc, name: String, root: Map[String, Json]): (List[Object], List[String]) =
        let decoded = Map.get("objects", root)
            |> Option.flatMap(JsonCodec.decodeList(json -> Some(json)))
            |> Option.getWithDefault(Nil)
            |> List.map(json -> JsonCodec.expectObject(json) |> Option.toOk("物の行でない") |> Result.flatMap(objectOf(items)));
        let problems = decoded |> List.zipWithIndex |> List.filterMap(match (i, row) ->
            whyOf(row) |> Option.map(why -> "[map] ${name} の objects の ${i + 1} 行目を読めないので飛ばす（${why}）"));
        (decoded |> List.filterMap(Result.toOption), problems)

    def whyOf(row: Result[String, a]): Option[String] = match row {
        case Err(why) => Some(why)
        case Ok(_)    => None
    }

    /// 物の 1 行（id・x・y が無い行・知らない kind・Doc に無い道具の名前は Err）。
    def objectOf(items: ItemsDoc.Doc, obj: Map[String, Json]): Result[String, Object] =
        forM (id <- textAt("id", obj) |> Option.toOk("id が無い");
              x <- intAt("x", obj) |> Option.toOk("x が無い");
              y <- intAt("y", obj) |> Option.toOk("y が無い");
              kind <- objectKindOf(items, obj))
        yield { id = id, x = x, y = y, sprite = spriteOr(profileOf(kind)#sprite, obj), kind = kind }

    def spriteOr(fallback: String, obj: Map[String, Json]): String =
        textAt("sprite", obj) |> Option.filter(sprite -> not String.isEmpty(sprite)) |> Option.getWithDefault(fallback)

    /// kind の名前と、その種類が使う欄から ObjectKind を組む。
    def objectKindOf(items: ItemsDoc.Doc, obj: Map[String, Json]): Result[String, ObjectKind] =
        match JsonCodec.stringOr("kind", "", obj) {
            case "chest" => chestOf(items, obj)
            case "door"  => doorOf(items, obj)
            case "lever" => flagOf(obj) |> Result.map(flag -> ObjectKind.Lever({ flag = flag }))
            case "gate"  => forM (flag <- flagOf(obj); openWhen <- openWhenOf(obj)) yield ObjectKind.Gate({ flag = flag, openWhen = openWhen })
            case "guard" => guardOf(obj)
            case "plate" => forM (flag <- flagOf(obj)) yield ObjectKind.Plate({ flag = flag, hold = JsonCodec.boolOr("hold", false, obj) })
            case "rock"  => Ok(ObjectKind.Rock)
            case "cart"  => forM (dir <- dirOf("dir", obj)) yield ObjectKind.Cart({ dir = dir, node = JsonCodec.stringOr("node", "Cart", obj) })
            case "junction" => forM (flag <- flagOf(obj); dir <- dirOf("dir", obj); dirOn <- dirOf("dirOn", obj))
                               yield ObjectKind.Junction({ flag = flag, dir = dir, dirOn = dirOn })
            case "crystal" => forM (flag <- flagOf(obj); order <- intAt("order", obj) |> Option.filter(n -> n >= 1) |> Option.toOk("順番（order）は 1 から"))
                              yield ObjectKind.Crystal({ flag = flag, order = order })
            case "bridge" => forM (flag <- flagOf(obj)) yield ObjectKind.Bridge({ flag = flag })
            case "sign"  =>
                let node = JsonCodec.stringOr("node", "", obj);
                if (String.isEmpty(node)) Err("読む物の会話（node）が無い") else Ok(ObjectKind.Sign({ node = node }))
            case other   => Err("知らない kind '${other}'")
        }

    /// 宝箱: item（空なら無し）・count（既定 1）・gold（既定 0）。
    def chestOf(items: ItemsDoc.Doc, obj: Map[String, Json]): Result[String, ObjectKind] =
        let key = JsonCodec.stringOr("item", "", obj);
        let item = if (String.isEmpty(key)) Ok(None)
                   else ItemsDoc.idOf(items, key) |> Option.toOk("道具 '${key}' が ${ItemsDoc.path()} に無い") |> Result.map(Some);
        item |> Result.map(it -> ObjectKind.Chest({ item = it, count = JsonCodec.intOr("count", 1, obj), gold = JsonCodec.intOr("gold", 0, obj) }))

    /// 扉: key（開ける道具。空・Doc に無い名前は Err）。
    def doorOf(items: ItemsDoc.Doc, obj: Map[String, Json]): Result[String, ObjectKind] =
        let key = JsonCodec.stringOr("key", "", obj);
        if (String.isEmpty(key)) Err("扉の鍵（key）が無い")
        else ItemsDoc.idOf(items, key) |> Option.toOk("鍵 '${key}' が ${ItemsDoc.path()} に無い") |> Result.map(id -> ObjectKind.Door({ key = id }))

    /// flag の欄（空・無しは Err。旗の無いレバーと開く物は何もしない・ずっと閉じたまま）。
    def flagOf(obj: Map[String, Json]): Result[String, Flag.FlagId] =
        Map.get("flag", obj) |> Option.flatMap(Flag.fromJson) |> Option.toOk("旗（flag）が無い")

    /// 向きの欄（up / down / left / right。無い・知らない字は Err。向きの無いトロッコと分かれ目は走る先が決まらない）。
    def dirOf(key: String, obj: Map[String, Json]): Result[String, Dir4.Dir4] =
        dirAt(key, obj) |> Option.toOk("向き（${key}）が無い")

    /// openWhen の欄（on = 旗が立つと通れる・off = 旗が下りると通れる。無ければ on。ほかの字は Err）。
    /// WhyNot: 知らない字を on へ落とさない — off のつもりの書き損じで、レバーと逆に開く。
    def openWhenOf(obj: Map[String, Json]): Result[String, Bool] =
        match JsonCodec.stringOr("openWhen", "on", obj) {
            case "on"  => Ok(true)
            case "off" => Ok(false)
            case other => Err("openWhen は on / off: '${other}'")
        }

    /// 番をする者: node（話しかけた時の会話。空は Err。会話に有るかは Res.kindProblemsOf が見る）。
    def guardOf(obj: Map[String, Json]): Result[String, ObjectKind] =
        let node = JsonCodec.stringOr("node", "", obj);
        if (String.isEmpty(node)) Err("番をする者の会話（node）が無い") else Ok(ObjectKind.Guard({ node = node }))

    def eventOf(obj: Map[String, Json]): Option[Event] =
        forM (x <- intAt("x", obj); y <- intAt("y", obj); node <- textAt("node", obj)) yield { x = x, y = y, node = node }

    /// 出会いの 1 行（foe1..foe3 の空でない名前と weight。敵が 1 体もいない行・weight が 1 未満の行は読めない行）。
    def encounterOf(obj: Map[String, Json]): Option[Encounter] =
        let foes = ("foe1" :: "foe2" :: "foe3" :: Nil) |> List.filterMap(key -> textAt(key, obj)) |> List.filter(foe -> not String.isEmpty(foe));
        let weight = JsonCodec.intOr("weight", 1, obj);
        if (List.isEmpty(foes) or weight < 1) None else Some({ foes = foes, weight = weight })
}
