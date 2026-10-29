// Talk — 会話（assets/talk/*.yarn）とコードの繋ぎ。コマンドの名前と引数の読み方の source of truth はここ。
// 話し手の名前は rpg.text.json の speakers の鍵（呼び名と一緒に Doc に置き、話し手を足すのに Flix を触らない）。
// bin/fge yarn build の check は、この語彙を書き出した assets/talk/vocab.json を読む（書き直すのは make talk-vocab。TestDocs が一致を見る）。
//
//   assets/talk/rune.yarn ──bin/fge yarn build assets/talk──▶ assets/talk/dialogue.json ──fromJson──▶ Res#dialogue
//
// 人に話しかけた時に開くノードは、マップの Doc の npcs の node・exits の gateNode・events の node・objects の番をする者（guard）の node
// （コードの enum ではなく Doc が持つ）。
// World を変えるのはコマンドだけ（意味は WorldTalk.runCommand）。会話の変数 $quest・$mina・$gold・$innPrice は World と Doc から写す一方向で、
// Yarn の <<set>> で書かない（TestDocs が止める）。
mod Talk {
    use fge::{DocJson, Suggest, Yarn}
    use Util.Json.Json

    pub def dialoguePath(): String = "assets/talk/dialogue.json"

    pub def vocabPath(): String = "assets/talk/vocab.json"

    // ── World から写す変数 ──

    /// 会話が読むだけの変数（World が正。WorldTalk.valueOf が今の値を出す）。
    ///   Quest … $quest（依頼の段階の名前）/ Gold … $gold（手持ちのお金）/ InnPrice … $innPrice（宿の 1 泊の値段。rpg.shops.json）/
    ///   Joined(仲間) … $<仲間の名前>（加わったか）/ Has(だいじなもの) … $has_<道具の鍵>（ふくろに 1 つ以上あるか。items の kind = key の物だけ）
    pub enum SyncedVar with Eq, Order, ToString {
        case Quest
        case Gold
        case InnPrice
        case Joined(Member.Member)
        case Has(ItemsDoc.ItemId)
    }

    /// 写す変数の全部（$has_ は items の Doc のだいじなものの数だけ）。
    pub def syncedVars(items: ItemsDoc.Doc): List[SyncedVar] =
        List.flatten((SyncedVar.Quest :: SyncedVar.Gold :: SyncedVar.InnPrice :: Nil) :: (Member.all() |> List.map(SyncedVar.Joined)) ::
                     (ItemsDoc.keyItemsOf(items) |> List.map(SyncedVar.Has)) :: Nil)

    /// 会話の中の名前（$ 付き）。
    pub def varNameOf(v: SyncedVar): String = match v {
        case SyncedVar.Quest          => "$quest"
        case SyncedVar.Gold           => "$gold"
        case SyncedVar.InnPrice       => "$innPrice"
        case SyncedVar.Joined(member) => "$${Member.idOf(member)}"
        case SyncedVar.Has(item)      => "$has_${ItemsDoc.keyOf(item)}"
    }

    // ── コマンド ──

    /// World を変えるコマンド（<<名前 引数…>> を commandOf で読んだ物）。
    ///   Quest(段階) … <<quest accept>>: 依頼の段階を進め、手付けを払う（前の段階が合わなければ何もしない）
    ///   Join(仲間)  … <<join mina>>: 仲間に加える（加わっていれば何もしない）
    ///   Give(道具, 個数) … <<give yakusou 3>>: ふくろへ
    ///   Gold(数)    … <<gold 10>>: お金を足す（負なら引く。0 で止まる）
    ///   Shop        … <<shop>>: 道具屋を開く（閉じたら会話の続きへ）
    ///   Inn         … <<inn>>: 宿代を払って泊まる（暗転 → 全快 → セーブ → 会話の続きへ。払える時だけ流す）
    ///   Fight(敵, 勝った後のノード) … <<fight 敵 ノード>>: 会話を閉じて戦う。勝ったらフィールドへ戻ってそのノードを開く（ノードは省ける）
    ///   Take(道具, 個数) … <<take totostaff 1>>: ふくろから減らす（無い分は 0 で止まる）
    ///   Open(物の id) … <<open cave_mole>>: 今のマップの objects のその物を開けた事にする（扉は開き・番をする者は消える）
    ///   Heal … <<heal>>: 仲間全員の HP と MP を最大へ（倒れた人も起こす。お金も宿も要らない）
    ///   Ride … <<ride>>: 向いている前のマスのトロッコに乗って走り出す（会話は閉じる）
    pub enum Command {
        case Quest(Progress.Quest)
        case Join(Member.Member)
        case Give(ItemsDoc.ItemId, Int32)
        case Gold(Int32)
        case Shop(String)
        case Inn
        case Fight(FoesDoc.FoeId, Option[String])
        case Take(ItemsDoc.ItemId, Int32)
        case Open(String)
        case Heal
        case Ride
    }

    /// コマンドの名前（会話の語彙）。<<wait 秒>> は engine の実行器が扱うので並べない。
    def commandNames(): List[String] = "quest" :: "join" :: "give" :: "gold" :: "shop" :: "inn" :: "fight" :: "take" :: "open" :: "heal" :: "ride" :: Nil

    /// コマンドの書き方（知らせる文に並べる。引数の名前は Doc のどこを引くか）。
    def usageOf(name: String): String = match name {
        case "quest" => "quest ${questVerbs() |> List.join("|")}"
        case "join"  => "join ${Member.ids() |> List.join("|")}"
        case "give"  => "give 道具 個数"
        case "gold"  => "gold 数"
        case "fight" => "fight 敵 [勝った後のノード]"
        case "take"  => "take 道具 個数"
        case "open"  => "open 物の id"
        case "shop"  => "shop [店の名前]"
        case _       => name
    }

    /// <<quest 動詞>> の動詞と、進めた先の段階の表（動詞を足すのはここ 1 か所）。
    def questVerbTable(): List[(String, Progress.Quest)] = ("accept", Progress.Quest.Accepted) :: Nil

    def questVerbs(): List[String] = questVerbTable() |> List.map(fst)

    /// <<quest 動詞>> の動詞 → 進めた先の段階。
    def questVerbOf(verb: String): Option[Progress.Quest] =
        questVerbTable() |> List.find(row -> fst(row) == verb) |> Option.map(snd)

    /// コマンドを読む。名前・引数の数・Doc で引けない引数は理由を返す（会話の場所つき）。
    pub def commandOf(items: ItemsDoc.Doc, foes: FoesDoc.Doc, c: Yarn.Command): Result[String, Command] =
        let at = "（${Yarn.sourceText(c#source)}）";
        match (c#name, c#args) {
            case ("quest", verb :: Nil) =>
                questVerbOf(verb) |> Option.map(Command.Quest) |> Option.toOk("<<quest>> の動詞は ${questVerbs() |> List.join(" / ")}: '${verb}'${at}")
            case ("join", name :: Nil) =>
                Member.memberOf(name) |> Option.map(Command.Join) |> Option.toOk("<<join>> の仲間 '${name}' は居ない${Suggest.hint(name, Member.ids())}${at}")
            case ("give", item :: count :: Nil) =>
                forM (
                    id <- ItemsDoc.idOf(items, item) |> Option.toOk("<<give>> の道具 '${item}' は ${ItemsDoc.path()} に無い${Suggest.hint(item, ItemsDoc.keysOf(items))}${at}");
                    n <- Int32.fromString(count) |> Option.toOk("<<give>> の個数は数: '${count}'${at}")
                ) yield Command.Give(id, n)
            case ("gold", amount :: Nil) =>
                Int32.fromString(amount) |> Option.map(Command.Gold) |> Option.toOk("<<gold>> の数は数: '${amount}'${at}")
            case ("shop", Nil) => Ok(Command.Shop(""))
            case ("shop", name :: Nil) => Ok(Command.Shop(name))
            case ("heal", Nil) => Ok(Command.Heal)
            case ("ride", Nil) => Ok(Command.Ride)
            case ("inn", Nil)  => Ok(Command.Inn)
            case ("take", item :: count :: Nil) =>
                forM (
                    id <- ItemsDoc.idOf(items, item) |> Option.toOk("<<take>> の道具 '${item}' は ${ItemsDoc.path()} に無い${Suggest.hint(item, ItemsDoc.keysOf(items))}${at}");
                    n <- Int32.fromString(count) |> Option.filter(x -> x > 0) |> Option.toOk("<<take>> の個数は 1 以上の数: '${count}'${at}")
                ) yield Command.Take(id, n)
            case ("open", id :: Nil) => Ok(Command.Open(id))
            case ("fight", foe :: Nil) => fightOf(foes, foe, None, at)
            case ("fight", foe :: node :: Nil) => fightOf(foes, foe, Some(node), at)
            case (name, args) =>
                Err("<<${name}>> は引数 ${List.length(args)} 個では読めない（書けるのは ${commandNames() |> List.map(usageOf) |> List.join(" / ")}）${at}")
        }

    def fightOf(foes: FoesDoc.Doc, foe: String, node: Option[String], at: String): Result[String, Command] =
        FoesDoc.idOf(foes, foe) |> Option.map(id -> Command.Fight(id, node))
            |> Option.toOk("<<fight>> の敵 '${foe}' は ${FoesDoc.path()} に無い${Suggest.hint(foe, FoesDoc.keysOf(foes))}${at}")

    /// 会話の食い違い: 読めないコマンド・<<fight>> の勝った後のノードが無い・<<open>> の物がどのマップの objects にも無い
    /// （objectIds = 全部のマップの objects の id）・World から写す変数への <<set>>（書いても次の写しで消える）。
    /// Res.problemsOf が起動時に言い、テストは空であることを見る。
    pub def problemsOf(items: ItemsDoc.Doc, foes: FoesDoc.Doc, objectIds: Set[String], program: Yarn.Program): List[String] =
        let synced = syncedVars(items) |> List.map(varNameOf) |> List.toSet;
        let nodes = Yarn.nodeNames(program) |> List.toSet;
        let commandProblems = commandsOf(program) |> List.filterMap(c -> match commandOf(items, foes, c) {
            case Ok(Command.Fight(_, Some(node))) if not Set.memberOf(node, nodes) =>
                Some("[talk] <<fight>> の勝った後のノード '${node}' が会話に無い（${Yarn.sourceText(c#source)}）")
            case Ok(Command.Open(id)) if not Set.memberOf(id, objectIds) =>
                Some("[talk] <<open>> の物 '${id}' がどのマップの objects にも無い（${Yarn.sourceText(c#source)}）")
            case Ok(_)       => None
            case Err(reason) => Some("[talk] ${reason}")
        });
        let setProblems = setsOf(program) |> List.filter(pair -> Set.memberOf(fst(pair), synced))
            |> List.map(match (name, at) -> "[talk] ${name} は World から写す変数なので <<set>> で書かない（${at}）。コマンドで World を変える");
        List.flatten(commandProblems :: setProblems :: varNameProblems(items) :: Nil)

    /// World から写す変数の名前の重なり（仲間の名前が quest や gold だと、$quest を 2 つの値で書き合う）。
    def varNameProblems(items: ItemsDoc.Doc): List[String] =
        syncedVars(items) |> List.map(varNameOf)
            |> List.foldLeft((acc, name) -> Map.insertWith((a, b) -> a + b, name, 1, acc), Map.empty())
            |> Map.toList |> List.filter(pair -> snd(pair) > 1)
            |> List.map(match (name, _) -> "[talk] World から写す変数 ${name} が 2 つ以上ある（仲間の名前を quest・gold 以外にする）")

    // ── 読む ──

    /// 会話を読む。読めない・壊れている時はノードの無い会話（どの人に話しかけてもウィンドウは開かない）。
    pub def load(): Yarn.Program \ Fs.FileRead = DocJson.loadOr(fromJson, Yarn.empty(), dialoguePath())

    /// 会話の木の JSON から。ゲームのコマンド（wait 以外）の直後に <<wait 0>> を差し込んでから読む。
    /// WhyNot: 木をそのまま読まない — 実行器はコマンドで止まらずに次の台詞まで流すので、<<gold 10>> の直後の
    /// <<if $gold >= …>> が、World へ当てて写し直す前の古い値で分かれる。<<wait 0>> で 1 度止め、
    /// WorldTalk が当てて写し直してから続きを流す（.yarn に毎回 <<wait 0>> を書かせると、書き忘れが黙って古い値を読む）。
    pub def fromJson(text: String): Option[Yarn.Program] =
        DocJson.parse(text) |> Option.map(pauseAfterCommands) |> Option.flatMap(json -> Yarn.fromJson(Util.Json.toCompactString(json)))

    def pauseAfterCommands(json: Json): Json = match json {
        case Json.JObject(fields) => Json.JObject(fields |> Map.mapWithKey((key, value) ->
            if (key == "body") pauseInBody(value) else pauseAfterCommands(value)))
        case Json.JArray(items)   => Json.JArray(Vector.map(pauseAfterCommands, items))
        case _                    => json
    }

    def pauseInBody(body: Json): Json = match body {
        case Json.JArray(statements) =>
            Json.JArray(statements |> Vector.toList |> List.flatMap(statement -> {
                let inner = pauseAfterCommands(statement);
                waitAfter(inner) |> Option.map(wait -> inner :: wait :: Nil) |> Option.getWithDefault(inner :: Nil)
            }) |> List.toVector)
        case _ => pauseAfterCommands(body)
    }

    /// statement がゲームのコマンドなら、同じ行の <<wait 0>>。
    def waitAfter(statement: Json): Option[Json] = match statement {
        case Json.JObject(fields) if Map.get("kind", fields) == Some(Json.JString("command"))
                                     and Map.get("name", fields) != Some(Json.JString("wait")) =>
            Some(Json.JObject(Map#{ "kind" => Json.JString("command"), "name" => Json.JString("wait"),
                                    "args" => Json.JArray(Vector#{Json.JString("0")}),
                                    "line" => Map.getWithDefault("line", Json.JNull, fields) }))
        case _ => None
    }

    // ── 会話の中身を並べる ──

    /// 全部の文（選択肢と <<if>> の枝の中も。ノードの名前の順）。
    def statementsOf(program: Yarn.Program): List[Yarn.Statement] =
        Yarn.nodeNames(program)
            |> List.filterMap(name -> Yarn.nodeOf(name, program))
            |> List.flatMap(node -> statementsIn(node#body))

    def statementsIn(body: List[Yarn.Statement]): List[Yarn.Statement] = List.flatMap(nestedOf, body)

    def nestedOf(statement: Yarn.Statement): List[Yarn.Statement] = match statement {
        case Yarn.Statement.Choose(choices)  => statement :: List.flatMap(choice -> statementsIn(choice#body), choices)
        case Yarn.Statement.If(branches, _)  => statement :: List.flatMap(branch -> statementsIn(branch#body), branches)
        case _                               => statement :: Nil
    }

    /// 会話の全部の台詞。
    pub def linesOf(program: Yarn.Program): List[Yarn.Line] =
        statementsOf(program) |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Say(line) => Some(line)
            case _                        => None
        })

    /// 会話の全部のゲームのコマンド（wait は除く）。
    def commandsOf(program: Yarn.Program): List[Yarn.Command] =
        statementsOf(program) |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Command(c) if c#name != "wait" => Some(c)
            case _                                             => None
        })

    /// <<set>> で書いている変数と、その場所（「ファイル:行」）。
    def setsOf(program: Yarn.Program): List[(String, String)] =
        statementsOf(program) |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Set(name, _, source) => Some((name, Yarn.sourceText(source)))
            case _                                   => None
        })

    // ── 語彙 ──

    /// コードが開くノード: マップの人の node・出入口の gateNode・イベントのマスの node・番をする者の node（名前の順・重なりなし）。
    def openedNodesOf(maps: MapDoc.Table): List[String] =
        let docs = maps |> Map.valuesOf |> List.map(MapDoc.rec);
        let npcNodes = docs |> List.flatMap(m -> m#npcs) |> List.map(npc -> npc#node);
        let gateNodes = docs |> List.flatMap(m -> m#exits) |> List.filterMap(exit -> exit#gate |> Option.map(gate -> gate#node));
        let eventNodes = docs |> List.flatMap(m -> m#events) |> List.map(e -> e#node);
        let guardNodes = docs |> List.flatMap(m -> m#objects) |> List.filterMap(o -> MapDoc.guardNodeOf(o#kind));
        List.flatten(npcNodes :: gateNodes :: eventNodes :: guardNodes :: Nil) |> List.filter(node -> not String.isEmpty(node)) |> List.toSet |> Set.toList

    /// 会話の語彙（bin/fge yarn build の検査の材料）。speakers は rpg.text.json の話し手・nodes はコードが開くノード・commands はコマンドの名前。
    pub def vocabOf(maps: MapDoc.Table, text: TextDoc.Doc): Yarn.Vocab =
        { speakers = TextDoc.speakerIds(text),
          nodes = openedNodesOf(maps),
          tags = Nil,
          commands = commandNames() |> List.sort }

    /// 語彙を assets/talk/vocab.json に書く（make talk-vocab）。
    pub def vocab(): Unit \ IO =
        run {
            let vocab = vocabOf(MapDoc.loadTable(ItemsDoc.load(ItemsDoc.path())), TextDoc.load(TextDoc.path()));
            println(if (Yarn.writeVocab(vocabPath(), vocab)) "[talk] 語彙を書いた: ${vocabPath()}" else "[talk] 語彙を書けない: ${vocabPath()}")
        } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO
}
