// KeysDoc — player.keys.json（キー割り当て）の宣言ドキュメント層。
// 「どのキーがどの操作か」だけを外に出す — 軸の合成や動きはコード（Controls / World）のまま。
// 1 つの操作に複数キーを並べられる（矢印と WASD の両対応・左右どちらの Shift でも走る のような形）。
// fail-open — 読めない・壊れているときは defaults() へ落とす。操作の欄が空・全部
// 知らない名前のときも、その操作だけ既定へ落とす — 書き間違いで操作不能を作らない。
mod KeysDoc {
    use fge::{DocJson, InputMap, JsonCodec}
    use fge::GameEngine.Key
    use Util.Json.Json

    /// 操作ごとのキーの列。同じ操作に複数キーを割り当ててよい。
    // World が持つ record は enum で包む（型検査が record を展開しないため）。
    pub type alias Rec = {
        version = Int32,
        forward = List[Key],      // 前へ歩く
        back = List[Key],         // 後ろへ下がる
        strafeLeft = List[Key],   // 左へ横歩き
        strafeRight = List[Key],  // 右へ横歩き
        turnLeft = List[Key],     // 左を向く
        turnRight = List[Key],    // 右を向く
        lookUp = List[Key],       // 見上げる
        lookDown = List[Key],     // 見下ろす
        dash = List[Key],         // 押している間は走る
        map = List[Key],          // 紙のマップを開く・閉じる
        talk = List[Key],         // 人物に話しかける・物を拾う・鍵の戸を調べる・会話の文字送り
        items = List[Key]         // アイテム画面を開く・閉じる
    }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/player.keys.json"

    /// コード側の既定（assets/player.keys.json と同じ割り当てから出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
                  forward     = Key.W :: Key.Up :: Nil,
                  back        = Key.S :: Key.Down :: Nil,
                  strafeLeft  = Key.A :: Nil,
                  strafeRight = Key.D :: Nil,
                  turnLeft    = Key.Left :: Key.Q :: Nil,
                  turnRight   = Key.Right :: Key.E :: Nil,
                  lookUp      = Key.R :: Nil,
                  lookDown    = Key.F :: Nil,
                  dash        = Key.LeftShift :: Key.RightShift :: Nil,
                  map         = Key.M :: Nil,
                  talk        = Key.Space :: Key.Enter :: Key.Z :: Nil,
                  items       = Key.I :: Key.Tab :: Key.C :: Nil })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違う欄は既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  forward     = keysOr("forward",     d#forward,     root),
                  back        = keysOr("back",        d#back,        root),
                  strafeLeft  = keysOr("strafeLeft",  d#strafeLeft,  root),
                  strafeRight = keysOr("strafeRight", d#strafeRight, root),
                  turnLeft    = keysOr("turnLeft",    d#turnLeft,    root),
                  turnRight   = keysOr("turnRight",   d#turnRight,   root),
                  lookUp      = keysOr("lookUp",      d#lookUp,      root),
                  lookDown    = keysOr("lookDown",    d#lookDown,    root),
                  dash        = keysOr("dash",        d#dash,        root),
                  map         = keysOr("map",         d#map,         root),
                  talk        = keysOr("talk",        d#talk,        root),
                  items       = keysOr("items",       d#items,       root) })

    /// 欄の文字列列 → キーの列。知らない名前はその 1 個だけ捨て（InputMap.keysOf）、
    /// 列ごと空になる形（欄が無い・型違い・全部知らない名前）だけ フォールバックする。
    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): List[Key] =
        Map.get(field, root)
            |> Option.flatMap(element -> JsonCodec.decodeList(JsonCodec.expectString, element))
            |> Option.map(InputMap.keysOf)
            |> Option.flatMap(keys -> if (List.isEmpty(keys)) None else Some(keys))
            |> Option.getWithDefault(fallback)
}
