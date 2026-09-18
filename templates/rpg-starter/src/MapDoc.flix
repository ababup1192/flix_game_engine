// MapDoc — rpg.map.json（里の間取り: タイルの rows・住人・扉と約束・薬草の配置）の宣言ドキュメント層。
// 盤面のデータは全部この Doc にあり、rows と配置を書き換えれば別の里になる。
// 歩ける・ぶつかるの規則（衝突・扉の開き方・クリア条件）はコード（World）側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod MapDoc {
    use Util.Json.Json

    /// 住人 1 人。id = 扉の promise が指す名前、cell = 立っているマス、
    /// line = 話しかけたときの 1 行（約束にかかわる文言は Door 側が持つ）。
    pub type alias Villager = { id = String, cell = Grid.Cell, line = String }

    /// 扉と、それを開ける約束。cell = 扉のマス、promise = 約束の相手（住人の id）、
    /// need = 果たすのに要る薬草の数、ask = 頼まれごとの 1 行、opened = 果たしたときの 1 行。
    /// 物の鍵は出てこない — 約束を果たすと開くのがこのゲームの鍵。
    pub type alias Door = { cell = Grid.Cell, promise = String, need = Int32,
                            ask = String, opened = String }

    /// 里の間取り。rows = タイルの文字格子（'#' = 石垣、',' = 畑、'.' = 道。
    /// 知らない文字は道にする）、start = 主人公の最初のマス、goal = クリアに要る薬草の数、
    /// lamps = 灯りの立つマス（薬草を拾うたびひとつ点く）。
    /// title / subtitle / clear / hint / clearHint は画面の文言（hint = 表紙、clearHint = クリア画面の操作ヒント）。
    pub type alias Rec = {
        version = Int32,
        title = String,
        subtitle = String,
        clear = String,
        hint = String,
        clearHint = String,
        start = Grid.Cell,
        rows = List[String],
        villagers = List[Villager],
        door = Door,
        herbs = List[Grid.Cell],
        lamps = List[Grid.Cell],
        goal = Int32
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/rpg.map.json"

    /// コード側の既定値。間取りが読めなくても小さな里でゲームは必ず起動する。
    ///
    ///   ############
    ///   #*...#.....#      * = 薬草   G = 門番   D = 扉（約束で開く）
    ///   #.@.GD...*.#      @ = 主人公のはじまり
    ///   #....#.....#
    ///   ############
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          title = "霧の里",
          subtitle = "薬草を届けに、夕暮れの段々畑へ",
          clear = "薬草はぜんぶ届いた。里に灯がともる",
          hint = "Zキーではじめる",
          clearHint = "Zキーではじめにもどる",
          start = { x = 2, y = 2 },
          rows =
                 "############"
              :: "#....#.....#"
              :: "#..........#"
              :: "#....#.....#"
              :: "############"
              :: Nil,
          villagers =
              { id = "gate", cell = { x = 4, y = 2 },
                line = "この先が届け先だ。霧が深いから気をつけて" } :: Nil,
          door = { cell = { x = 5, y = 2 }, promise = "gate", need = 1,
                   ask = "薬草を 1つ 持ってきておくれ。そうしたら通そう",
                   opened = "約束どおりだ。通っていいよ" },
          herbs = { x = 1, y = 1 } :: { x = 9, y = 2 } :: Nil,
          lamps = { x = 5, y = 0 } :: { x = 8, y = 0 } :: Nil,
          goal = 2 })

    // ── 盤面の読み取り（マスの中身。歩ける・ぶつかるの判断は World 側） ──

    /// 同じマスか（レコードは == で比べられないので、成分で比べる唯一の入口）。
    pub def sameCell(a: Grid.Cell, b: Grid.Cell): Bool =
        a#x == b#x and a#y == b#y

    /// 盤の列数（一番長い行に合わせる。短い行の足りない分は石垣とみなす）。
    pub def cols(doc: Doc): Int32 =
        rec(doc)#rows |> List.map(String.length) |> List.foldLeft(Int32.max, 0)

    /// 盤の行数。
    pub def rowCount(doc: Doc): Int32 =
        List.length(rec(doc)#rows)

    /// cell のタイル文字。盤の外・短い行の外は '#'（石垣）にする。
    pub def tileAt(cell: Grid.Cell, doc: Doc): Char =
        List.nth(cell#y, rec(doc)#rows)
            |> Option.flatMap(row -> List.nth(cell#x, String.toList(row)))
            |> Option.getWithDefault('#')

    /// cell が石垣（通れないタイル）か。知らない文字は道にする（fail-open）。
    pub def solidAt(cell: Grid.Cell, doc: Doc): Bool =
        tileAt(cell, doc) == '#'

    /// cell に立っている住人（いなければ None）。
    pub def villagerAt(cell: Grid.Cell, doc: Doc): Option[Villager] =
        List.find(villager -> sameCell(villager#cell, cell), rec(doc)#villagers)

    // ── JSON からの読み込み ──

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          title = JsonCodec.stringOr("title", d#title, root),
          subtitle = JsonCodec.stringOr("subtitle", d#subtitle, root),
          clear = JsonCodec.stringOr("clear", d#clear, root),
          hint = JsonCodec.stringOr("hint", d#hint, root),
          clearHint = JsonCodec.stringOr("clearHint", d#clearHint, root),
          start = cellOr(d#start, "start", root),
          rows = Map.get("rows", root)
              |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
              |> Option.getWithDefault(d#rows),
          villagers = Map.get("villagers", root)
              |> Option.flatMap(JsonCodec.decodeList(villagerFromJson))
              |> Option.getWithDefault(d#villagers),
          door = Map.get("door", root)
              |> Option.flatMap(doorFromJson)
              |> Option.getWithDefault(d#door),
          herbs = Map.get("herbs", root)
              |> Option.flatMap(JsonCodec.decodeList(cellFromJson))
              |> Option.getWithDefault(d#herbs),
          lamps = Map.get("lamps", root)
              |> Option.flatMap(JsonCodec.decodeList(cellFromJson))
              |> Option.getWithDefault(d#lamps),
          goal = JsonCodec.intOr("goal", d#goal, root) })

    /// {"x": .., "y": ..} をマスに読む（欠けたフィールドは 0）。
    def cellFromJson(json: Json): Option[Grid.Cell] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { x = JsonCodec.intOr("x", 0, obj), y = JsonCodec.intOr("y", 0, obj) })

    def cellOr(fallback: Grid.Cell, key: String, obj: Map[String, Json]): Grid.Cell =
        Map.get(key, obj) |> Option.flatMap(cellFromJson) |> Option.getWithDefault(fallback)

    def villagerFromJson(json: Json): Option[Villager] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { id = JsonCodec.stringOr("id", "", obj),
              cell = { x = JsonCodec.intOr("x", 0, obj), y = JsonCodec.intOr("y", 0, obj) },
              line = JsonCodec.stringOr("line", "", obj) })

    def doorFromJson(json: Json): Option[Door] =
        let d = rec(defaults())#door;
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { cell = { x = JsonCodec.intOr("x", 0, obj), y = JsonCodec.intOr("y", 0, obj) },
              promise = JsonCodec.stringOr("promise", d#promise, obj),
              need = JsonCodec.intOr("need", d#need, obj),
              ask = JsonCodec.stringOr("ask", d#ask, obj),
              opened = JsonCodec.stringOr("opened", d#opened, obj) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
