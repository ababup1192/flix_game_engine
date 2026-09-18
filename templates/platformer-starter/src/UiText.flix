// UiText — ui.text.json(画面に出る文言)の宣言ドキュメント層。
// プレイヤーの目に入る文字はコードに直書きしない — 訳語や言い回しは
// 遊びながら直したくなるし、翻訳のとき探し回ることになるため。
// fail-open — 読めない・壊れているときは defaults() へ落とす。
mod UiText {
    use Util.Json.Json

    pub type alias Rec = { version = Int32, clear = String, gameOver = String }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/ui.text.json"

    pub def defaults(): Doc =
        Doc.Doc({ version = 1, clear = "CLEAR!", gameOver = "GAME OVER" })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version  = JsonCodec.intOr("version", d#version, root),
          clear    = JsonCodec.stringOr("clear", d#clear, root),
          gameOver = JsonCodec.stringOr("gameOver", d#gameOver, root) })

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
