// Starts — 始まりの登録簿（App.withStarts。Game が Resources.liftStart で組の行にする）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="field map=chief_house x=7 y=7"）・リモートの POST /start・flow の `start field`・テストの App.startOrBug・
// 描き出し（SceneRender）が同じ表を引く。
mod Starts {
    use fge::{Dir4, Grid, Resources, Suggest, Yarn}

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[Resources.Start[Res.Res, World.World]] =
        { name = "title", doc = "タイトル画面（起動の既定）。saved = yes なら、field と同じ引数（party・quest・gold・items・seed）の中身のセーブがある所（「つづきから」を選べる）",
          args = Map#{"saved" => "no"}, build = title } ::
        { name = "field", doc = "マップのマスに立つ（暗転なし）。map = assets/maps の名前・x / y = マス・facing = up / down / left / right・seed = 乱数の回数・party = 加わった仲間（luka,mina。先頭から）・quest = 依頼の段階（none / accepted）・gold = 手持ちのお金・items = ふくろの道具（yakusou:3,seisui:1）・hp = 仲間全員の HP（最大で止める）・mp = 仲間全員の MP（最大で止める）・lv = 仲間全員の Lv・steps = 次の戦いまでの歩数（0 = 出会いのあるマップの最初の 1 歩で引く。歩く手順を確かめる flow は 999 で出会わない）・flags = 立てておく旗（cave_bars。, で区切る。仕掛けの途中から始める）・opened = 開けておく立つマップの objects の id（b1_pick,b2_kurogane。宝箱・番をする者・点けた水晶）・rocks = 押して動かした岩の今のマス（b1_rock:9:20。id:x:y を , で区切る）・light = たいまつの残りの歩数（暗いマップの明かり）。省いた物は rules の始まり（仲間はルカ 1 人・依頼の前・ふくろは空・HP は最大）",
          args = Map#{"map" => "village", "x" => "7", "y" => "8", "facing" => "up", "seed" => "0", "party" => "luka", "quest" => "none", "items" => ""}, build = field } ::
        { name = "talk", doc = "field と同じ所に立ち、node の会話を開いた所（前のマスの人がそのノードの人なら、その人に話しかけた所）",
          args = Map#{"node" => "ChiefQuest", "map" => "chief_house", "x" => "7", "y" => "5", "facing" => "up"}, build = talk } ::
        { name = "battle", doc = "field と同じ所に立ち、foes の敵と戦い始めた所（「〜が あらわれた！」）。foes = rpg.foes.json の鍵（koke,koumori。3 体まで）・背景は map の battleBack・lv = 仲間全員の Lv（省けば加わった時の Lv）。勝つとそのマスへ戻る",
          args = Map#{"foes" => "koke", "map" => "world", "x" => "20", "y" => "12", "facing" => "up", "party" => "luka"}, build = battle } :: Nil

    def battle(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        forM (
            foes <- foesArg(res, Map.getWithDefault("foes", "", args));
            placed <- field(res, w, args)
        ) yield WorldBattle.enter(res, foes, None, placed)

    /// 「koke,koumori」→ 敵の並び（1 体以上・rules の maxFoes まで）。
    def foesArg(res: Res.Res, text: String): Result[String, List[FoesDoc.FoeId]] =
        let names = text |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(name -> not String.isEmpty(name));
        let unknown = names |> List.filter(name -> Option.isEmpty(FoesDoc.idOf(res#foes, name)));
        if (not List.isEmpty(unknown)) Err("foes の敵 '${List.join(",", unknown)}' は ${FoesDoc.path()} に無い${Suggest.hint(List.join(",", unknown), FoesDoc.keysOf(res#foes))}")
        else if (List.isEmpty(names)) Err("foes に敵を 1 体以上: '${text}'")
        else if (List.length(names) > WorldBattle.maxFoesOf(res)) Err("foes は ${WorldBattle.maxFoesOf(res)} 体まで: '${text}'")
        else Ok(names |> List.filterMap(FoesDoc.idOf(res#foes)))

    def field(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        let rules = RulesDoc.rec(res#rules);
        (forM (
            id <- mapArg(res, Map.getWithDefault("map", rules#startMap, args));
            x <- intArg("x", rules#startX, args);
            y <- intArg("y", rules#startY, args);
            facing <- Map.get("facing", args) |> Option.map(dirArg) |> Option.getWithDefault(Ok(rules#startFacing));
            seed <- intArg("seed", 0, args);
            party <- partyArg(res, Map.getWithDefault("party", "luka", args));
            quest <- questArg(Map.getWithDefault("quest", "none", args));
            gold <- intArg("gold", rules#startGold, args);
            items <- itemsArg(res, Map.getWithDefault("items", "", args));
            lv <- Map.get("lv", args) |> Option.map(text -> Int32.fromString(text) |> Option.filter(n -> n >= 1) |> Option.toOk("lv は 1 以上の数: '${text}'") |> Result.map(Some)) |> Option.getWithDefault(Ok(None));
            hp <- Map.get("hp", args) |> Option.map(text -> Int32.fromString(text) |> Option.toOk("hp は数: '${text}'") |> Result.map(Some)) |> Option.getWithDefault(Ok(None));
            mp <- Map.get("mp", args) |> Option.map(text -> Int32.fromString(text) |> Option.toOk("mp は数: '${text}'") |> Result.map(Some)) |> Option.getWithDefault(Ok(None));
            steps <- intArg("steps", 0, args);
            light <- intArg("light", 0, args);
            rocks <- rocksArg(Map.getWithDefault("rocks", "", args))
        ) yield { party = party |> leveled(res, lv) |> (p -> hp |> Option.map(n -> withHp(res, n, p)) |> Option.getWithDefault(p))
                               |> (p -> mp |> Option.map(n -> withMp(res, n, p)) |> Option.getWithDefault(p)), progress = withFlags(Flag.listOfArg(Map.getWithDefault("flags", "", args)), Progress.withQuest(quest, w#progress)), bag = Bag.of(items, gold) | w }
            |> withOpened(id, Map.getWithDefault("opened", "", args))
            |> World.placeField(id, { x = x, y = y }, facing) |> World.mapField(r -> { stepsToFight = steps, light = light, rocks = rocks | r }) |> Dice.withSeed(seed))
            |> Result.flatMap(standable(res))

    /// タイトル。saved = yes なら field と同じ引数で組んだ中身をセーブにする（宿で書いた後に起動し直した所）。
    def title(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        match Map.getWithDefault("saved", "no", args) {
            case "no"  => Ok(w)
            case "yes" => field(res, w, args) |> Result.map(saved -> { save = Some(World.saveDataOf(saved)) | w })
            case other => Err("saved は yes / no: '${other}'")
        }

    def talk(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        let node = Map.getWithDefault("node", "", args);
        let known = Yarn.nodeNames(res#dialogue);
        if (not List.memberOf(node, known)) Err("ノード '${node}' は会話に無い${Suggest.hint(node, known)}")
        else field(res, w, args) |> Result.map(placed -> {
            let npc = WorldField.npcInFrontOf(res, placed) |> Option.filter(person -> person#node == node) |> Option.map(person -> person#id);
            WorldTalk.open(res, node, npc, placed)
        })

    /// 「luka,mina」→ 加わった順の仲間（Lv1・HP と MP は最大・装備は Doc の初めの物）。先頭はルカ（ルカの居ない隊列は作らない）。
    def partyArg(res: Res.Res, text: String): Result[String, Party.Party] =
        let names = text |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(name -> not String.isEmpty(name));
        let unknown = names |> List.filter(name -> Option.isEmpty(Member.memberOf(name)));
        if (not List.isEmpty(unknown)) Err("party の仲間 '${List.join(",", unknown)}' は居ない（${List.join(" / ", Member.ids())}）")
        else if (List.head(names) != Some(Member.idOf(Member.Member.Luka))) Err("party の先頭はルカ（luka）: '${text}'")
        else Ok(names |> List.filterMap(Member.memberOf) |> List.foldLeft((p, m) -> Party.join(res#party, res#items, m, p), Party.empty()))

    /// lv があれば全員をその Lv にする（経験値はその Lv の累計・HP と MP は最大）。
    def leveled(res: Res.Res, lv: Option[Int32], party: Party.Party): Party.Party =
        lv |> Option.map(n -> Party.atLevel(res#party, n, party)) |> Option.getWithDefault(party)

    /// 全員の HP を n にする（最大で止める・0 で止める）。
    def withHp(res: Res.Res, n: Int32, party: Party.Party): Party.Party =
        Party.statsList(party) |> List.foldLeft((acc, row) -> {
            let (m, stats) = row;
            Party.recover(res#party, m, { hp = n - stats#hp, mp = 0 }, acc)
        }, party)

    /// 全員の MP を n にする（最大で止める・0 で止める）。
    def withMp(res: Res.Res, n: Int32, party: Party.Party): Party.Party =
        Party.statsList(party) |> List.foldLeft((acc, row) -> {
            let (m, stats) = row;
            Party.recover(res#party, m, { hp = 0, mp = n - stats#mp }, acc)
        }, party)

    /// 「yakusou:3,seisui:1」→ 道具と個数（個数を省けば 1）。
    def itemsArg(res: Res.Res, text: String): Result[String, Map[ItemsDoc.ItemId, Int32]] =
        text |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(entry -> not String.isEmpty(entry))
            |> List.map(entry -> itemEntryOf(res, entry)) |> List.sequence |> Result.map(List.toMap)

    def itemEntryOf(res: Res.Res, entry: String): Result[String, (ItemsDoc.ItemId, Int32)] =
        let (name, count) = match String.splitOn(substr = ":", entry) {
            case n :: c :: Nil => (n, c)
            case _             => (entry, "1")
        };
        forM (
            id <- ItemsDoc.idOf(res#items, name) |> Option.toOk("items の道具 '${name}' は ${ItemsDoc.path()} に無い${Suggest.hint(name, ItemsDoc.keysOf(res#items))}");
            n <- Int32.fromString(count) |> Option.toOk("items の個数は数: '${entry}'")
        ) yield (id, n)

    def questArg(name: String): Result[String, Progress.Quest] =
        Progress.questOf(name) |> Option.toOk("quest は ${Progress.quests() |> List.map(Progress.nameOf) |> List.join(" / ")}: '${name}'")

    def mapArg(res: Res.Res, name: String): Result[String, MapDoc.MapId] =
        MapDoc.idOf(res#maps, name) |> Option.toOk("マップ '${name}' は無い${Suggest.hint(name, Map.keysOf(res#maps) |> Set.toList)}")

    def intArg(key: String, fallback: Int32, args: Map[String, String]): Result[String, Int32] =
        match Map.get(key, args) {
            case None       => Ok(fallback)
            case Some(text) => Int32.fromString(text) |> Option.toOk("${key} は数: '${text}'")
        }

    def dirArg(name: String): Result[String, Dir4.Dir4] =
        DirName.dirOf(name) |> Option.toOk("facing は ${DirName.names()}: '${name}'")

    /// flags= の旗を立てる（物の仕掛けの途中から始める）。
    def withFlags(flags: List[Flag.FlagId], p: Progress.Progress): Progress.Progress =
        flags |> List.foldLeft((acc, flag) -> Progress.withFlag(flag, true, acc), p)

    /// opened= の物（立つマップの objects の id。, で区切る）を開けた事にする（宝箱・扉・番をする者・点けた水晶）。
    def withOpened(map: MapDoc.MapId, text: String, w: World.World): World.World =
        let ids = text |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(id -> not String.isEmpty(id));
        { progress = ids |> List.foldLeft((acc, id) -> Progress.markOpened(map, id, acc), w#progress) | w }

    /// rocks= の岩の今のマス（id:x:y を , で区切る。読めない 1 つがあれば Err）。
    def rocksArg(text: String): Result[String, Map[String, Grid.Cell]] =
        text |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(entry -> not String.isEmpty(entry))
            |> List.map(entry -> match String.splitOn(substr = ":", entry) {
                case id :: x :: y :: Nil =>
                    forM (cx <- Int32.fromString(x); cy <- Int32.fromString(y)) yield (id, { x = cx, y = cy })
                case _ => None
            } |> Option.toOk("rocks は id:x:y を , で区切る: '${entry}'"))
            |> Result.sequence |> Result.map(List.toMap)

    def standable(res: Res.Res, w: World.World): Result[String, World.World] =
        let cell = World.fieldRecOf(w) |> Option.map(r -> "(${r#hero#x}, ${r#hero#y})") |> Option.getWithDefault("");
        if (WorldField.canStandHere(res, w)) Ok(w) else Err("${cell} には立てない")
}
