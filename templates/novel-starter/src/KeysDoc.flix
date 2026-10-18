// KeysDoc — novel.keys.json（キー割り当て）の宣言ドキュメント層。
// 「どのキーがどの操作か」だけを外に出す — 操作の意味（決定で読み進める・メニューで物語を止める）は
// コード（Controls / World）のまま。1 つの操作に複数キーを並べられる（Z と Enter の両対応のような形）。
// fail-open — 読めない・壊れているときは defaults() へ落とす。操作の欄が空・全部
// 知らない名前のときも、その操作だけ既定へ落とす — 書き間違いで操作不能を作らない。
mod KeysDoc {
    use fge::{DocJson, InputMap, JsonCodec}
    use fge::GameEngine.Key
    use Util.Json.Json

    /// 操作ごとのキーの列。同じ操作に複数キーを割り当ててよい。
    pub type alias Rec = {
        version = Int32,
        confirm = List[Key], // 読み進める・選ぶ（クリックは別に常に効く）
        prev = List[Key],    // 選択肢のカーソルを前へ
        next = List[Key],    // 選択肢のカーソルを後ろへ
        menu = List[Key],    // メニューを開く・閉じる（開いている間は物語が止まる）
        quit = List[Key]     // 表紙でゲームを終える（物語の途中では効かない）
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.keys.json"

    /// コード側の既定（assets/novel.keys.json と同じ割り当てから出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          confirm = Key.Z :: Key.Enter :: Key.Space :: Nil,
          prev    = Key.Left :: Key.Up :: Key.A :: Key.W :: Nil,
          next    = Key.Right :: Key.Down :: Key.D :: Key.S :: Nil,
          menu    = Key.Escape :: Nil,
          quit    = Key.Escape :: Nil })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違う欄は既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          confirm = keysOr("confirm", d#confirm, root),
          prev    = keysOr("prev",    d#prev,    root),
          next    = keysOr("next",    d#next,    root),
          menu    = keysOr("menu",    d#menu,    root),
          quit    = keysOr("quit",    d#quit,    root) })

    /// 欄の文字列列 → キーの列。知らない名前はその 1 個だけ捨て（InputMap.keysOf）、
    /// 列ごと空になる形（欄が無い・型違い・全部知らない名前）だけ既定へ落とす。
    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): List[Key] =
        Map.get(field, root)
            |> Option.flatMap(element -> JsonCodec.decodeList(JsonCodec.expectString, element))
            |> Option.map(InputMap.keysOf)
            |> Option.flatMap(keys -> if (List.isEmpty(keys)) None else Some(keys))
            |> Option.getWithDefault(fallback)
}
