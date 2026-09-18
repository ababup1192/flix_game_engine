// KeysDoc — player.keys.json（キー割り当て）の宣言ドキュメント層。
// 「どのキーがどの操作か」だけを外に出す — 軸の合成や動きはコード（Controls / World）のまま。
// 1 つの操作に複数キーを並べられる（矢印と WASD の両対応のような形）。
// fail-open — 読めない・壊れているときは defaults() へ落とす。操作の欄が空・全部
// 知らない名前のときも、その操作だけ既定へ落とす — 書き間違いで操作不能を作らない。
mod KeysDoc {
    use GameEngine.Key
    use Util.Json.Json

    /// 操作ごとのキーの列。同じ操作に複数キーを割り当ててよい。
    // World が持つ record は enum で包む（型検査が record を展開しないため）。
    pub type alias Rec = {
        version = Int32,
        left = List[Key],   // 左へ動く
        right = List[Key],  // 右へ動く
        up = List[Key],     // 上へ動く
        down = List[Key]    // 下へ動く
    }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/player.keys.json"

    /// コード側の既定（assets/player.keys.json と同じ割り当てから出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
                  left  = Key.Left :: Key.A :: Nil,
                  right = Key.Right :: Key.D :: Nil,
                  up    = Key.Up :: Key.W :: Nil,
                  down  = Key.Down :: Key.S :: Nil })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違う欄は既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  left  = keysOr("left",  d#left,  root),
                  right = keysOr("right", d#right, root),
                  up    = keysOr("up",    d#up,    root),
                  down  = keysOr("down",  d#down,  root) })

    /// 欄の文字列列 → キーの列。知らない名前はその 1 個だけ捨て（InputMap.keysOf）、
    /// 列ごと空になる形（欄が無い・型違い・全部知らない名前）だけ フォールバックする。
    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): List[Key] =
        Map.get(field, root)
            |> Option.flatMap(element -> JsonCodec.decodeList(JsonCodec.expectString, element))
            |> Option.map(InputMap.keysOf)
            |> Option.flatMap(keys -> if (List.isEmpty(keys)) None else Some(keys))
            |> Option.getWithDefault(fallback)
}
