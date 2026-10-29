// テストが共有する組み立てと取り出し（Doc から組んだ App・始まりの World・キーの列を 1 フレームずつ流す）。
mod Fixtures {
    use fge::{App, CameraRig, Clock, Dir4, DocJson, HeadlessFont, JsonCodec, Resources, YarnRunner}
    use fge::GameEngine.Key

    /// App の w（描く元と World の組）。
    pub type alias Run = Resources.With[Res.Res, World.World]

    /// assets の Doc で組んだ実機と同じ App。
    pub def app(): App.App[Run, {}] \ Fs.FileRead = Game.app(Res.loadDocs(), None)

    /// 始まりの登録簿の name で組んだ組。
    pub def started(name: String, args: Map[String, String]): Run \ Fs.FileRead = App.startOrBug(app(), name, args)

    /// 1 フレームに押しているキーの列を、1/60 秒ずつ実機と同じ道（Drive.play）で流した後。
    pub def play(keys: List[Set[Key]], h: Run): Run = Drive.play(keys, h)

    /// keys を n フレーム押したまま。
    pub def hold(keys: Set[Key], n: Int32): List[Set[Key]] = List.repeat(n, keys)

    /// 何も押さない n フレーム。
    pub def idle(n: Int32): List[Set[Key]] = List.repeat(n, Set.empty())

    /// keys を 1 フレーム押して離す。
    pub def tap(keys: Set[Key]): List[Set[Key]] = keys :: Set.empty() :: Nil

    /// held を押したまま、tapped を 1 フレーム押して離す。
    pub def tapWhileHolding(held: Set[Key], tapped: Set[Key]): List[Set[Key]] = Set.union(held, tapped) :: held :: Nil

    // ── 操作のキー（KeysDoc の既定の割り当ての先頭） ──

    def firstOf(keys: List[Key]): Set[Key] = List.take(1, keys) |> List.toSet

    def keys(): KeysDoc.Rec = KeysDoc.rec(KeysDoc.defaults())

    pub def confirm(): Set[Key] = firstOf(keys()#confirm)

    pub def cancel(): Set[Key] = firstOf(keys()#cancel)

    pub def up(): Set[Key] = firstOf(keys()#up)

    pub def down(): Set[Key] = firstOf(keys()#down)

    pub def left(): Set[Key] = firstOf(keys()#left)

    pub def right(): Set[Key] = firstOf(keys()#right)

    /// Esc（OS の決まりで固定。割り当ての Doc には載せない）。
    pub def escape(): Set[Key] = Set#{Key.Escape}

    /// 描き出しと同じ字のアトラスで組んだ、ウィンドウと部品を描く元（字の幅を測るテストが使う）。
    pub def windowEnv(res: Res.Res): WindowView.Env \ IO =
        { res = res, font = HeadlessFont.buildUiAtlas(SceneRender.ttf(), SceneRender.ttf()), t = 0.0 }

    /// 先頭のマスと向き（フィールドでなければ None）。
    pub def heroOf(h: Run): Option[((Int32, Int32), Dir4.Dir4)] =
        World.fieldRecOf(h#world) |> Option.map(r -> ((r#hero#x, r#hero#y), r#facing))

    /// いるマップの名前（フィールドでなければ None）。
    pub def mapOf(h: Run): Option[String] = World.fieldRecOf(h#world) |> Option.map(r -> MapDoc.nameOf(r#map))

    /// 歩き始めた時刻（止まっていれば None）。
    pub def strideStartOf(h: Run): Option[Clock.Time[World.Play]] =
        World.fieldRecOf(h#world) |> Option.flatMap(r -> match r#stride {
            case World.Stride.Walking(_, at) => Some(at)
            case World.Stride.Still          => None
            case World.Stride.Riding(ride)   => Some(ride#startedAt)
            case World.Stride.Boarding       => None
        })

    /// 入力を受ける層の名前。
    pub def layerOf(h: Run): String = InputLayer.nameOf(InputLayer.layerOf(h#world))

    /// 依頼の段階。
    pub def questOf(h: Run): Quest.Quest = Progress.rec(h#world#progress)#quest

    /// 加わった仲間（先頭から）。
    pub def membersOf(h: Run): List[Member.Member] = Party.membersOf(h#world#party)

    /// 手持ちのお金。
    pub def goldOf(h: Run): Int32 = Bag.goldOf(h#world#bag)

    /// 2 人目が立つマス（trail の頭。無ければ None）。
    pub def secondCellOf(h: Run): Option[(Int32, Int32)] =
        World.fieldRecOf(h#world) |> Option.flatMap(r -> List.head(r#trail)) |> Option.map(spot -> (fst(spot)#x, fst(spot)#y))

    /// trail の i 番目（0 から。新しい順）のマス（無ければ None）。
    pub def trailCellAt(i: Int32, h: Run): Option[(Int32, Int32)] =
        World.fieldRecOf(h#world) |> Option.flatMap(r -> List.nth(i, r#trail)) |> Option.map(spot -> (fst(spot)#x, fst(spot)#y))

    /// マップの (x, y) に今立つ人（今の依頼の段階と加わった仲間で決まる。無ければ None）。
    pub def npcAt(map: String, x: Int32, y: Int32, h: Run): Option[MapDoc.Npc] =
        Map.get(map, h#resources#maps)
            |> Option.flatMap(doc -> MapDoc.standingAt(Party.joinedIds(h#world#party), Progress.rec(h#world#progress)#quest, x, y, doc))

    /// マップの id の人の立つマス（無ければ None）。
    pub def npcCellOf(map: String, id: String, h: Run): Option[(Int32, Int32)] =
        Map.get(map, h#resources#maps) |> Option.flatMap(doc -> List.find(npc -> npc#id == id, MapDoc.rec(doc)#npcs))
            |> Option.map(npc -> (npc#x, npc#y))

    /// 終了の確認（開いていなければ None）。
    pub def askOf(h: Run): Option[World.Ask] = h#world#ask

    /// assets/map.schema.json の出入口の gate に書ける名前（読めなければ None）。
    pub def schemaGateNames(): Option[List[String]] \ Fs.FileRead =
        Fs.FileRead.read("assets/map.schema.json") |> Result.toOption
            |> Option.flatMap(DocJson.parse) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("sections")) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("exits")) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("fields")) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("gate")) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("type")) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("enum")) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))

    /// 出している台詞の字（無ければ None）。
    pub def lineTextOf(h: Run): Option[String] =
        WorldTalk.openTalkOf(h#world) |> Option.flatMap(t -> t#line) |> Option.map(line -> line#text)

    /// ふくろの道具の個数（道具が items の Doc に無ければ None）。
    pub def itemCountOf(name: String, h: Run): Option[Int32] =
        ItemsDoc.idOf(h#resources#items, name) |> Option.map(id -> Bag.countOf(id, h#world#bag))

    /// マップの (x, y) の出入口（無ければ None）。
    pub def exitAt(map: String, x: Int32, y: Int32, h: Run): Option[MapDoc.Exit] =
        Map.get(map, h#resources#maps) |> Option.flatMap(doc -> Map.get((x, y), MapDoc.rec(doc)#exitAt))

    // ── 仲間・ふくろ・セーブ・メニュー・店 ──

    /// 仲間の今の HP（加わっていなければ None）。
    pub def hpOf(m: Member.Member, h: Run): Option[Int32] = Party.statsOf(m, h#world#party) |> Option.map(s -> s#hp)

    /// 仲間の今の MP（加わっていなければ None）。
    pub def mpOf(m: Member.Member, h: Run): Option[Int32] = Party.statsOf(m, h#world#party) |> Option.map(s -> s#mp)

    /// 文字送りをしているウィンドウ（会話・知らせ）の字（無ければ None）。
    pub def typingTextOf(h: Run): Option[String] = World.typingOf(h#world) |> Option.map(pair -> snd(pair)#text)

    /// 仲間の最大 HP（Doc から）。
    pub def maxHpOf(m: Member.Member, h: Run): Int32 = Party.maxHpOf(h#resources#party, m, h#world#party)

    /// 仲間のちから（Doc の値 + 付けている物）。
    pub def atkOf(m: Member.Member, h: Run): Int32 = Party.atkOf(h#resources#party, h#resources#items, m, h#world#party)

    /// 道具の Doc の値（無ければ None）。
    pub def itemOf(name: String, h: Run): Option[ItemsDoc.Item] =
        ItemsDoc.idOf(h#resources#items, name) |> Option.flatMap(ItemsDoc.itemOf(h#resources#items))

    /// 開いているメニューのページ（メニューでなければ None）。
    pub def menuPageOf(h: Run): Option[World.MenuPage] = WorldMenu.openPageOf(h#world)

    /// 開いている店のページ（店でなければ None）。
    pub def shopPageOf(h: Run): Option[World.ShopPage] = WorldShop.openShopOf(h#world) |> Option.map(fst)

    /// タイトルのカーソル（タイトルでなければ None）。
    pub def titleCursorOf(h: Run): Option[World.TitleItem] = World.titleCursorOf(h#world)

    /// 起動し直した所: h の World のセーブだけを持って、起動の World（タイトル）から始める（Main が読んだセーブを渡すのと同じ）。
    pub def relaunch(h: Run): Run = Resources.of(h#resources, World.initial(h#world#save))

    /// save を読んで起動した所（タイトル）。
    pub def launchedWith(save: Option[Saves.SaveData]): Run \ Fs.FileRead = Resources.of(started("title", Map.empty())#resources, World.initial(save))

    // ── 1 ノードだけの会話（bin/fge yarn build が書く木の JSON の形） ──

    /// <<name arg>> の文。
    pub def command(name: String, arg: String): String =
        "{\"kind\":\"command\",\"line\":2,\"name\":\"${name}\",\"args\":[\"${arg}\"]}"

    /// マップの、依頼の段階 q の間に出る小物の絵の名前（Doc の並び。マップが無ければ None）。
    pub def propSpritesOf(map: String, q: Quest.Quest, h: Run): Option[List[String]] =
        Map.get(map, h#resources#maps) |> Option.map(doc -> MapDoc.propsIn(q, doc) |> List.map(p -> p#sprite))

    /// seconds 秒ぶんのフレームの数（1/60 秒で切り上げ。Int32 に収まらなければ None）。
    pub def framesOf(seconds: Float64): Option[Int32] = Float64.ceil(seconds * 60.0) |> Float64.tryToInt32

    /// 引数の無い <<name>> の文。
    pub def bareCommand(name: String): String =
        "{\"kind\":\"command\",\"line\":2,\"name\":\"${name}\",\"args\":[]}"

    /// 話し手の無い台詞の文。
    pub def line(text: String): String = "{\"kind\":\"line\",\"line\":3,\"text\":\"${text}\"}"

    /// <<if $gold >= n>> whenTrue <<else>> whenFalse <<endif>> の文。
    pub def ifGoldAtLeast(n: Int32, whenTrue: String, whenFalse: String): String =
        "{\"kind\":\"if\",\"line\":4,\"clauses\":[" +
        "{\"line\":4,\"condition\":{\"kind\":\">=\",\"args\":[{\"kind\":\"variable\",\"name\":\"$gold\"},{\"kind\":\"value\",\"value\":${n}}]},\"body\":[${whenTrue}]}," +
        "{\"line\":5,\"body\":[${whenFalse}]}]}"

    /// 2 つの選択肢（a を選ぶと aBody・b を選ぶと bBody を流す）の文。
    pub def options(a: String, aBody: String, b: String, bBody: String): String =
        "{\"kind\":\"options\",\"line\":6,\"options\":[" +
        "{\"line\":6,\"text\":\"${a}\",\"body\":[${aBody}]},{\"line\":7,\"text\":\"${b}\",\"body\":[${bBody}]}]}"

    /// 文の並び body を 1 ノード T の会話の木にする（変数 $gold を宣言する）。
    pub def treeOf(body: String): String =
        "{\"version\":1,\"variables\":[{\"name\":\"$gold\",\"value\":0,\"file\":\"t.yarn\",\"line\":1}]," +
        "\"nodes\":[{\"title\":\"T\",\"file\":\"t.yarn\",\"line\":1,\"headers\":[],\"body\":[${body}]}]}"

    /// body の 1 ノードの会話を Res に差し替え、h の場所で開いた所（木が読めなければ None）。
    pub def openTree(body: String, h: Run): Option[Run] =
        Talk.fromJson(treeOf(body)) |> Option.map(program -> {
            let res = Res.withDialogue(program, h#resources);
            Resources.of(res, WorldTalk.open(res, "T", None, h#world))
        })

    /// 開いている会話のノード（無ければ None）。
    pub def talkNodeOf(h: Run): Option[String] =
        WorldTalk.openTalkOf(h#world) |> Option.flatMap(t -> YarnRunner.nodeOf(t#runner))

    // ── ワールドマップと坑道 ──

    /// 次の戦いまでの歩数（フィールドでなければ None）。
    pub def stepsToFightOf(h: Run): Option[Int32] = World.fieldRecOf(h#world) |> Option.map(r -> r#stepsToFight)

    /// マップの id の宝箱・扉（無ければ None）。
    pub def objectOf(map: String, id: String, h: Run): Option[MapDoc.Object] =
        Map.get(map, h#resources#maps) |> Option.flatMap(doc -> List.find(o -> o#id == id, MapDoc.rec(doc)#objects))

    /// マップの id の宝箱・扉を開けたか（マップが無ければ None）。
    pub def isOpenedOf(map: String, id: String, h: Run): Option[Bool] =
        MapDoc.idOf(h#resources#maps, map) |> Option.map(m -> Progress.isOpened(m, id, h#world#progress))

    /// マップの id の出入口（無ければ None）。
    pub def exitOf(map: String, id: String, h: Run): Option[MapDoc.Exit] =
        Map.get(map, h#resources#maps) |> Option.flatMap(doc -> List.find(e -> e#id == id, MapDoc.rec(doc)#exits))

    /// マップの (x, y) のイベントの会話のノード（無ければ None）。
    pub def eventNodeAt(map: String, x: Int32, y: Int32, h: Run): Option[String] =
        Map.get(map, h#resources#maps) |> Option.flatMap(doc -> Map.get((x, y), MapDoc.rec(doc)#eventAt)) |> Option.map(e -> e#node)

    /// 描き出しと同じ見え方（カメラを掛け、見えている矩形を ctx に入れた）の world の描き物の数（タイル層は数えない）。
    pub def worldItemCountOf(h: Run): Int32 \ IO =
        let atlas = HeadlessFont.buildUiAtlas(SceneRender.ttf(), SceneRender.ttf());
        let ctx = App.viewCtxOf(atlas, WindowView.design());
        let center = CameraRig.clampCenter(bounds = View.boundsOf(h#resources, h#world), seen = WindowView.design(), View.cameraOf(h#resources, h#world));
        let seen = { visible = CameraRig.visibleRect(center, zoom = 1.0, design = WindowView.design()) | ctx };
        List.length(View.frame(seen, h#resources, h#world))

    /// いるマップの物 id の今のマス（岩は動かした後のマス。いるマップに無ければ None）。
    pub def objectCellOf(id: String, h: Run): Option[(Int32, Int32)] =
        forM (r <- World.fieldRecOf(h#world); doc <- MapDoc.docOf(h#resources#maps, r#map);
              p <- WorldObject.objectsNow(doc, r, h#world#progress) |> List.find(p -> p#object#id == id))
        yield (p#cell#x, p#cell#y)

    /// トロッコで走っているか（フィールドでなければ false）。
    pub def isRidingOf(h: Run): Bool = World.fieldRecOf(h#world) |> Option.exists(World.isRiding)

    /// たいまつの残りの歩数（フィールドでなければ None）。
    pub def lightOf(h: Run): Option[Int32] = World.fieldRecOf(h#world) |> Option.map(r -> r#light)

    /// 描き出しと同じ見え方の、フィールドの絵の In の明かり（明るいマップ・フィールドでなければ None）。
    pub def lightRadiusOf(h: Run): Option[Float64] =
        ViewField.fieldIn(h#resources, h#world) |> Option.flatMap(field -> field#light) |> Option.map(light -> light#radius)

    /// いるマップのタイル層の鍵の並び。
    pub def tileLayerKeysOf(h: Run): List[String] = View.tileLayers(h#resources, h#world) |> List.map(spec -> spec#key)

    /// 先頭のマスから、map の出入口 id のマスまでの縦横の歩数（どちらかが無ければ None）。
    pub def stepsToExitOf(map: String, id: String, h: Run): Option[Int32] =
        forM (e <- exitOf(map, id, h); cell <- MapDoc.cellOf(e); r <- World.fieldRecOf(h#world)) yield Int32.abs(r#hero#x - fst(cell)) + Int32.abs(r#hero#y - snd(cell))

    /// map の id の扉を開ける道具（Doc の key）を 1 つ、ふくろへ入れた所（扉が Doc に無ければそのまま）。
    pub def withDoorKey(map: String, id: String, h: Run): Run =
        objectOf(map, id, h) |> Option.flatMap(doorKeyOf) |> Option.toList
            |> List.foldLeft((acc, key) -> Resources.of(acc#resources, { bag = Bag.give(key, 1, acc#world#bag) | acc#world }), h)

    def doorKeyOf(o: MapDoc.Object): Option[ItemsDoc.ItemId] = match o#kind {
        case MapDoc.ObjectKind.Door(door) => Some(door#key)
        case _                            => None
    }

    /// map の id の宝箱の中身（宝箱でなければ None）。
    pub def chestOf(map: String, id: String, h: Run): Option[MapDoc.ChestContents] =
        objectOf(map, id, h) |> Option.flatMap(chestContentsOf)

    def chestContentsOf(o: MapDoc.Object): Option[MapDoc.ChestContents] = match o#kind {
        case MapDoc.ObjectKind.Chest(chest) => Some(chest)
        case _                              => None
    }

    /// 名前の旗（Starts の flags= と同じ読み方。名前が空ならテストの前提の破れなので止める）。
    pub def flagId(name: String): Flag.FlagId = match Flag.listOfArg(name) {
        case flag :: _ => flag
        case Nil       => bug!("旗の名前が空: '${name}'")
    }

    /// 名前の旗が立っているか。
    pub def isFlagSetOf(name: String, h: Run): Bool = Progress.isFlagSet(flagId(name), h#world#progress)

    /// map の id の番をする者の会話のノード（番をする者でなければ None）。
    pub def guardNodeOf(map: String, id: String, h: Run): Option[String] =
        objectOf(map, id, h) |> Option.flatMap(o -> MapDoc.profileOf(o#kind)#node)

    /// ふくろの道具の個数。
    pub def bagCountOf(id: ItemsDoc.ItemId, h: Run): Int32 = Bag.countOf(id, h#world#bag)

    // ── 戦い ──

    /// 戦いの間の値（戦いでなければ None）。
    pub def battleOf(h: Run): Option[World.BattleRec] = World.battleRecOf(h#world)

    /// 戦いの値の敵の HP（並びの順）。
    pub def foeHpsOf(b: Battle.Battle): List[Int32] = Battle.rec(b)#foes |> Vector.toList |> List.map(f -> f#hp)

    /// 戦いの値の仲間の HP（加わった順）。
    pub def allyHpsOf(b: Battle.Battle): List[Int32] = Party.statsList(Battle.rec(b)#party) |> List.map(row -> snd(row)#hp)

    /// 敵の鍵の Doc の名前（無ければ None）。
    pub def foeNameOf(key: String, h: Run): Option[String] = FoesDoc.foeOf(h#resources#foes, foeId(h#resources, key)) |> Option.map(foe -> foe#name)

    /// 敵の呼び名（並びの順）。
    pub def foeLabelsOf(b: Battle.Battle): List[String] = Battle.rec(b)#foes |> Vector.toList |> List.map(f -> f#label)

    /// Beat の伝言の字（行ごと）。
    pub def beatLinesOf(res: Res.Res, beat: Battle.Beat): List[String] =
        Battle.beatRecOf(beat)#lines |> List.map(line -> TextDoc.battleText(line#text, line#values, res#text))

    /// Beat の列の伝言（Beat ごとに行の字）。
    pub def transcriptOf(res: Res.Res, beats: List[Battle.Beat]): List[List[String]] = beats |> List.map(beatLinesOf(res))

    /// 1 ターンの結果の形（ターンの後の敵と仲間の HP・伝言・乱数の回数）。
    pub def roundShapeOf(res: Res.Res, round: (Battle.Battle, List[Battle.Beat], Int32)): (List[Int32], List[Int32], List[List[String]], Int32) =
        let (after, beats, dice) = round;
        (foeHpsOf(after), allyHpsOf(after), transcriptOf(res, beats), dice)

    /// 仲間の Lv と経験値の累計（加わっていなければ None）。
    pub def lvExpOf(m: Member.Member, h: Run): Option[(Int32, Int32)] = Party.statsOf(m, h#world#party) |> Option.map(s -> (s#lv, s#exp))

    /// 敵の id（Doc に無ければ bug!。テストの前提が破れている）。
    pub def foeId(res: Res.Res, key: String): FoesDoc.FoeId =
        match FoesDoc.idOf(res#foes, key) {
            case Some(id) => id
            case None     => bug!("rpg.foes.json に '${key}' が無い")
        }

    /// 呪文の id（Doc に無ければ bug!。テストの前提が破れている）。
    pub def spellId(res: Res.Res, key: String): SpellsDoc.SpellId =
        match SpellsDoc.idOf(res#spells, key) {
            case Some(id) => id
            case None     => bug!("rpg.spells.json に '${key}' が無い")
        }

    /// 道具の id（Doc に無ければ bug!。テストの前提が破れている）。
    pub def itemId(res: Res.Res, key: String): ItemsDoc.ItemId =
        match ItemsDoc.idOf(res#items, key) {
            case Some(id) => id
            case None     => bug!("rpg.items.json に '${key}' が無い")
        }

    /// 呪文の値（Doc に無ければ bug!）。
    pub def spellOf(res: Res.Res, key: String): SpellsDoc.Spell =
        match SpellsDoc.spellOf(res#spells, spellId(res, key)) {
            case Some(s) => s
            case None    => bug!("rpg.spells.json に '${key}' が無い")
        }

    /// 戦いの最中の仲間 m の HP を n にした所。
    pub def withBattleHpOf(m: Member.Member, n: Int32, h: Run): Run =
        Resources.of(h#resources, World.mapBattle(r ->
            { battle = Battle.withParty(Party.withHp(h#resources#party, m, n, Battle.rec(r#battle)#party), r#battle) | r }, h#world))

    /// 決定を 1 回押して離し、演出と文字送りが済むまで待つ（1 秒）を n 回。戦いを先へ送る。
    pub def confirmEach(n: Int32): List[Set[Key]] = List.repeat(n, List.append(tap(confirm()), idle(60))) |> List.flatten

    // ── 音と曲 ──

    /// xs のうち、音の名前（soundOf）が project.json の sounds に無い物の名前（載っていない名前は黙って鳴らない。読めなければ None）。
    pub def notInProject(soundOf: a -> String, xs: List[a]): Option[List[String]] \ Fs.FileRead =
        Fs.FileRead.read("project.json") |> Result.toOption
            |> Option.flatMap(DocJson.parse) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("sounds"))
            |> Option.flatMap(JsonCodec.decodeList(json -> JsonCodec.expectObject(json) |> Option.map(JsonCodec.stringOr("name", ""))))
            |> Option.map(List.toSet)
            |> Option.map(known -> xs |> List.map(soundOf) |> List.filter(name -> not Set.memberOf(name, known)))

    /// payload の無い出来事の全部と、声の 3 つ（呪文は Doc の fx から）。
    pub def allEvents(): List[World.Event] =
        World.Event.Cursor :: World.Event.Confirm :: World.Event.Cancel :: World.Event.Bump :: World.Event.Door ::
        World.Event.Denied :: World.Event.TalkOpen :: World.Event.TalkNext ::
        World.Event.TalkBlip(TextDoc.Voice.Low) :: World.Event.TalkBlip(TextDoc.Voice.Mid) :: World.Event.TalkBlip(TextDoc.Voice.High) ::
        World.Event.Lever :: World.Event.Switch :: World.Event.RockPush :: World.Event.CartRide :: World.Event.CrystalLit ::
        World.Event.CrystalReset :: World.Event.Stairs :: World.Event.Chest :: World.Event.Unlock :: World.Event.Gold ::
        World.Event.Inn :: World.Event.Encounter :: World.Event.BossAppear :: World.Event.Attack :: World.Event.Critical ::
        World.Event.Hurt :: World.Event.Heal :: World.Event.Sleep :: World.Event.Flee :: World.Event.FoeDown ::
        World.Event.Victory :: World.Event.LevelUp :: World.Event.Wiped :: Nil

    /// マップの名前の順に、その Doc の bgm。
    pub def mapBgmsOf(res: Res.Res): List[Option[Bgm.Track]] =
        MapDoc.names() |> List.map(name -> Map.get(name, res#maps) |> Option.flatMap(m -> MapDoc.rec(m)#bgm))

    /// マップの Doc の bgm（マップが無ければ None）。
    pub def mapBgmOf(map: String, h: Run): Option[Bgm.Track] =
        Map.get(map, h#resources#maps) |> Option.flatMap(m -> MapDoc.rec(m)#bgm)

    /// マップの名前の順に、そのマップへ入る出入口の着くマスに立った時の曲。
    pub def fieldTracksOf(res: Res.Res): List[Option[Bgm.Track]] \ Fs.FileRead =
        let arrivals = res#maps |> Map.valuesOf |> List.flatMap(m -> MapDoc.rec(m)#exits) |> List.map(e -> (e#to, (e#spawnX, e#spawnY))) |> List.toMap;
        MapDoc.names() |> List.map(name -> Map.get(name, arrivals) |> Option.flatMap(cell -> {
            let h = started("field", Map#{"map" => name, "x" => Int32.toString(fst(cell)), "y" => Int32.toString(snd(cell))});
            Controls.trackOf(h#resources, h#world)
        }))

    /// keys を 1 フレームずつ流し、フレームごとの音と曲を集める（Emit の溜めは数フレームで捨てるので、1 フレームずつ見る）。
    pub def playCollecting(keys: List[Set[Key]], h: Run): { last = Run, sounds = List[String], tracks = List[Option[Bgm.Track]] } =
        keys |> List.foldLeft((acc, k) -> {
            let after = play(k :: Nil, acc#last);
            { last = after, sounds = List.append(acc#sounds, Controls.sounds({ before = acc#last#world, after = after#world })),
              tracks = acc#tracks ::: Controls.trackOf(after#resources, after#world) :: Nil }
        }, { last = h, sounds = Nil, tracks = Nil })
}
