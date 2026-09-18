// KeysDoc — player.keys.json(キー割り当て)の宣言ドキュメント層。
// 「どのキーがどの操作か」だけを外に出す — 軸の合成やゆるしはコード(Controls / Player)のまま。
// 1 つの操作に複数キーを並べられる(矢印と WASD の両対応のような形)。
// fail-open — 読めない・壊れているときは defaults() へ落とす。操作の欄が空・全部
// 知らない名前のときも、その操作だけ既定へ落とす — 書き間違いで操作不能を作らない。
mod KeysDoc {
    use GameEngine.Key
    use Util.Json.Json

    /// 操作ごとのキーの列。同じ操作に複数キーを割り当ててよい。
    pub type alias Rec = {
        version = Int32,
        left = List[Key],   // 左へ歩く
        right = List[Key],  // 右へ歩く
        jump = List[Key],   // ジャンプ(押しっぱなしで高く)
        drop = List[Key],   // 一方通行の床から降りる
        dash = List[Key]    // B ダッシュ
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/player.keys.json"

    /// コード側の既定(assets/player.keys.json と同じ割り当てから出発する)。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          left  = Key.Left :: Key.A :: Nil,
          right = Key.Right :: Key.D :: Nil,
          jump  = Key.Space :: Key.Up :: Key.W :: Nil,
          drop  = Key.Down :: Key.S :: Nil,
          dash  = Key.B :: Key.LeftShift :: Key.X :: Nil })

    /// テキストから Doc へ(fail-open)。JSON でない・形が違う欄は既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    /// path の Doc を読む。読めない・壊れているときは defaults(fail-open)。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          left  = keysOr("left",  d#left,  root),
          right = keysOr("right", d#right, root),
          jump  = keysOr("jump",  d#jump,  root),
          drop  = keysOr("drop",  d#drop,  root),
          dash  = keysOr("dash",  d#dash,  root) })

    /// 欄の文字列列 → キーの列。知らない名前はその 1 個だけ捨て(InputMap.keysOf)、
    /// 列ごと空になる形(欄が無い・型違い・全部知らない名前)だけ フォールバックする。
    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): List[Key] =
        Map.get(field, root)
            |> Option.flatMap(element -> JsonCodec.decodeList(JsonCodec.expectString, element))
            |> Option.map(InputMap.keysOf)
            |> Option.flatMap(keys -> if (List.isEmpty(keys)) None else Some(keys))
            |> Option.getWithDefault(fallback)
}
