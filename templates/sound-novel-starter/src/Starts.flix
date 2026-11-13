// Starts — 始まりの登録簿（App.withStarts）。名前と引数から、新しく作った初期の World を場面へ組む。
// talk はシナリオの直しを描く元（Res）へ当てるので組（Resources.With）の行のまま書き、World だけを組む title は Resources.liftStart で持ち上げる。
// 起動（START="talk node=River"）・リモートの POST /start・flow の `start talk`・テストの App.startOrBug・
// ブラウザ版の URL のクエリ（?talk=Station&line=31&at=…。WebLayer.devTools）が同じ表を引く。
// ノードの名前はシナリオ assets/talk/natsukusa.yarn の title:。知らない名前は近い名前の案つきで断る。
mod Starts {
    use fge::{App, Emit, Resources, Suggest, Yarn, YarnStorage}

    /// App の w（描く元と World の組）。
    type alias AppState = Resources.With[Res.Res, World.World]

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[App.Start[AppState]] =
        Resources.liftStart({ name = "title", doc = "タイトル画面（起動の既定）", args = Map.empty(), build = (_, w, _) -> Ok(w) }) ::
        { name = "talk", doc = "シナリオのノード（node か talk。既定は最初の Station）の頭から読む所。line = .yarn の行番号を渡すとその行まで進めて出した所（Studio の会話のプレビュー・bin/fge talk goto）。" +
                               "at = その行の前の文のハッシュ（合わなければ同じ文の行を探し、無ければノードの頭）。edit.<行>=<後の文> と was.<行>=<前の文のハッシュ> で台詞を直して遊ぶ（注釈の頁の「ここから遊ぶ」）。$名前=値 でシナリオの変数をその値にして流す",
          args = Map.empty(), build = (h, args) -> talk(h#resources, h#world, args) } :: Nil

    /// talk の始まり: 直しを描く元に当て、始める行まで進めた組。
    def talk(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, AppState] =
        nodeOf(res, args) |> Result.flatMap(node -> {
            let found = Yarn.nodeOf(node, res#dialogue);
            let rows = found |> Option.map(ScriptEdits.rowsOf) |> Option.getWithDefault(Nil);
            let file = found |> Option.map(n -> n#source#file) |> Option.getWithDefault("");
            let edited = Res.withScriptEdits(ScriptEdits.applyArgs(file, ScriptEdits.fileRows(file, res#dialogue), args), res);
            let line = match Map.get("line", args) {
                case Some(text) => Int32.fromString(text) |> Option.toOk("line は .yarn の行番号（数）: '${text}'") |> Result.map(Some)
                case None       => Ok(None)
            };
            forM (
                asked <- line;
                storage <- YarnStorage.withArgs(args, res#dialogue, YarnStorage.empty())
            ) yield {
                let at = ScriptEdits.startLine(rows, asked, Map.get("at", args));
                Resources.of(edited, fst(Emit.collect(() -> WorldRead.openAt(edited, storage, node, at, w))))
            }
        })

    /// 引数 node（無ければ talk。どちらも無ければコードが最初に開くノード）のノード。
    def nodeOf(res: Res.Res, args: Map[String, String]): Result[String, String] =
        let node = Map.getWithDefault("node", Map.getWithDefault("talk", Talk.nodeName(Talk.Node.Opening), args), args);
        let known = Yarn.nodeNames(res#dialogue);
        if (List.memberOf(node, known)) Ok(node)
        else Err("ノード '${node}' はシナリオに無い${Suggest.hint(node, known)}")
}
