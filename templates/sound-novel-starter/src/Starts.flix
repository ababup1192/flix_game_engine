// Starts — 始まりの登録簿（App.withStarts）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="talk node=River"）・リモートの POST /start・flow の `start talk`・テストの App.startOrBug が同じ表を引く。
// ノードの名前はシナリオ assets/talk/natsukusa.yarn の title:。知らない名前は近い名前の案つきで断る。
mod Starts {
    use fge::{App, Emit, Suggest, Yarn, YarnStorage}

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[App.Start[World.World]] =
        { name = "title", doc = "タイトル画面（起動の既定）", args = Map.empty(), build = (w, _) -> Ok(w) } ::
        { name = "talk", doc = "シナリオのノード（node。既定は最初の Station）の頭から読む所。line = .yarn の行番号を渡すとその行まで進めて出した所（Studio の会話のプレビュー・bin/fge talk goto）。$名前=値 でシナリオの変数をその値にして流す", args = Map.empty(),
          build = (w, args) -> nodeOf(args, w) |> Result.flatMap(node -> {
              let line = Map.get("line", args) |> Option.map(text -> Int32.fromString(text) |> Option.toOk("line は .yarn の行番号（数）: '${text}'"))
                  |> Option.getWithDefault(Ok(0));
              forM (
                  at <- line;
                  storage <- YarnStorage.withArgs(args, w#docs#dialogue, YarnStorage.empty())
              ) yield fst(Emit.collect(() -> WorldRead.openAt(storage, node, at, w)))
          }) } :: Nil

    /// 引数 node のノード（無ければコードが最初に開くノード）。
    def nodeOf(args: Map[String, String], w: World.World): Result[String, String] =
        let node = Map.getWithDefault("node", Talk.nodeName(Talk.Node.Opening), args);
        let known = Yarn.nodeNames(w#docs#dialogue);
        if (List.memberOf(node, known)) Ok(node)
        else Err("ノード '${node}' はシナリオに無い${Suggest.hint(node, known)}")
}
