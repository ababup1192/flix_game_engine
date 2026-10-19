// Starts — 始まりの登録簿（App.withStarts）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="choice node=clock"）・リモートの POST /start・flow の `start choice`・テストの App.startOrBug が同じ表を引く。
// ノードの名前はシナリオ assets/talk/novel.yarn の title:。知らない名前は近い名前の案つきで断る。
mod Starts {
    use fge::{App, Suggest, Yarn, YarnStorage}

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[App.Start[World.World]] =
        { name = "title", doc = "表紙（起動の既定。決定で物語がはじまる）", args = Map.empty(),
          build = (w, _) -> Ok(w) } ::
        { name = "talk", doc = "シナリオのノード（node = ノードの名前。既定は最初に開く arrival）の 1 行目を読んでいる所。line = .yarn の行番号を渡すとその行まで進めて出し終えた所（Studio の会話のプレビュー・bin/fge talk goto）。$名前=値 でシナリオの変数をその値にして流す", args = Map.empty(),
          build = (w, args) -> nodeOf(args, w) |> Result.flatMap(node -> match Map.get("line", args) {
              case None       => Ok(World.openTalk(node, World.reading(w)))
              case Some(text) => forM (
                      line <- Int32.fromString(text) |> Option.toOk("line は .yarn の行番号（数）: '${text}'");
                      storage <- YarnStorage.withArgs(args, w#dialogue, YarnStorage.empty())
                  ) yield World.openTalkAt(storage, node, line, World.reading(w))
          }) } ::
        { name = "choice", doc = "ノード（node。既定は arrival）を読み終えて選択肢が開き、問いの文を出し終えた所", args = Map.empty(),
          build = (w, args) -> nodeOf(args, w) |> Result.flatMap(node ->
              World.openAtChoices(node, World.reading(w)) |> Option.toOk("ノード '${node}' には選択肢が無い")) } :: Nil

    /// 引数 node のノード（無ければコードが最初に開くノード）。
    def nodeOf(args: Map[String, String], w: World.World): Result[String, String] =
        let node = Map.getWithDefault("node", Talk.nodeName(Talk.Node.Arrival), args);
        let known = Yarn.nodeNames(w#dialogue);
        if (List.memberOf(node, known)) Ok(node)
        else Err("ノード '${node}' はシナリオに無い${Suggest.hint(node, known)}")
}
