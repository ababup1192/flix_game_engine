// KeysDoc — novel.keys.json（キーの割り当て）の宣言ドキュメント層。
// 「どのキーがどの操作か」だけを外に出す — 操作の意味（送る・バックログを開く・オート）はコード（Controls / World）のまま。
// fail-open — 欄が無い・全部知らない名前の時は、その操作だけ既定へ落とす（書き間違いで操作不能を作らない）。
mod KeysDoc {
    use fge::{DocJson, InputMap, JsonCodec}
    use fge::GameEngine.Key
    use Util.Json.Json

    /// 操作ごとのキーの列。confirm = 送る・選ぶ、back = 窓を閉じる・ボタンの窓を開く、prev / next = カーソル、
    /// left / right = 設定の値・セーブの枠を横へ、log = バックログ、auto = オート、skip = スキップ、hide = 窓を隠す、
    /// rollback = 1 行戻る、quickSave / quickLoad = クイックセーブ・クイックロード、tabPrev / tabNext = セーブのページを替える、
    /// remove = セーブデータを削除する、quit = タイトルで終了を尋ねる。
    pub type alias Rec = {
        version = Int32,
        confirm = List[Key],
        back = List[Key],
        prev = List[Key],
        next = List[Key],
        left = List[Key],
        right = List[Key],
        log = List[Key],
        auto = List[Key],
        skip = List[Key],
        hide = List[Key],
        rollback = List[Key],
        quickSave = List[Key],
        quickLoad = List[Key],
        tabPrev = List[Key],
        tabNext = List[Key],
        remove = List[Key],
        quit = List[Key]
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.keys.json"

    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          confirm = Key.Enter :: Key.Space :: Key.Z :: Nil,
          back    = Key.Escape :: Key.X :: Key.Backspace :: Nil,
          prev    = Key.Up :: Key.W :: Nil,
          next    = Key.Down :: Key.S :: Nil,
          left    = Key.Left :: Key.A :: Nil,
          right   = Key.Right :: Key.D :: Nil,
          log     = Key.L :: Nil,
          auto    = Key.O :: Nil,
          skip    = Key.K :: Key.Tab :: Nil,
          hide    = Key.H :: Nil,
          rollback  = Key.PageUp :: Key.R :: Nil,
          quickSave = Key.F5 :: Nil,
          quickLoad = Key.F9 :: Nil,
          tabPrev = Key.Q :: Nil,
          tabNext = Key.E :: Nil,
          remove  = Key.Delete :: Nil,
          quit    = Key.Escape :: Nil })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let keys = (field, fallback) -> keysOr(field, fallback, root);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          confirm = keys("confirm", d#confirm), back = keys("back", d#back),
          prev = keys("prev", d#prev), next = keys("next", d#next),
          left = keys("left", d#left), right = keys("right", d#right),
          log = keys("log", d#log), auto = keys("auto", d#auto), skip = keys("skip", d#skip),
          hide = keys("hide", d#hide), rollback = keys("rollback", d#rollback),
          quickSave = keys("quickSave", d#quickSave), quickLoad = keys("quickLoad", d#quickLoad),
          tabPrev = keys("tabPrev", d#tabPrev), tabNext = keys("tabNext", d#tabNext), remove = keys("remove", d#remove),
          quit = keys("quit", d#quit) })

    /// 欄の文字列列 → キーの列。知らない名前はその 1 個だけ捨て（InputMap.keysOf）、列ごと空になる形だけ既定へ落とす。
    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): List[Key] =
        Map.get(field, root)
            |> Option.flatMap(element -> JsonCodec.decodeList(JsonCodec.expectString, element))
            |> Option.map(InputMap.keysOf)
            |> Option.flatMap(keys -> if (List.isEmpty(keys)) None else Some(keys))
            |> Option.getWithDefault(fallback)
}
