// Controls — キーとスティックを動く向き（長さ 0〜1）へ写し、World.step で 1 歩進める。
// どのキーがどの操作かは KeysDoc（explore.keys.json）が決める — 既定は矢印キーと WASD。パッドと画面のスティックは frame#leftStick から読む。
// Doc の読み直し（保存即反映・F1）の表もここに置く。
mod Controls {
    use fge::{App, DocTable, GameEngine, Log, Num, Resources, SortingLayer, Vec2}

    /// 動く向きと強さ（長さ 0〜1・右が +x・上（北）が +y）。スティック（パッド・画面のスティック）を倒していればその値、
    /// 無ければキー（2 つ押しで斜め・長さ 1）。
    pub def inputOf(keys: KeysDoc.Doc, frame: App.Frame): (Float64, Float64) =
        let stick = frame#leftStick;
        let stickLength = Num.sqrt(stick#x * stick#x + stick#y * stick#y);
        if (stickLength > 0.01) { let k = Float64.min(1.0, stickLength) / stickLength; (stick#x * k, stick#y * k) }
        else keyInput(KeysDoc.rec(keys), frame)

    def keyInput(k: KeysDoc.Rec, frame: App.Frame): (Float64, Float64) =
        let held = (ks: List[GameEngine.Key]) -> if (List.exists(key -> App.isDown(key, frame), ks)) 1.0 else 0.0;
        let x = held(k#right) - held(k#left);
        let y = held(k#up) - held(k#down);
        let length = Num.sqrt(x * x + y * y);
        if (length < 0.5) (0.0, 0.0) else (x / length, y / length)

    /// 毎フレームのシステム。終了の確認の窓が出ている間は Enter で終わる・Esc で戻る（マウスは tapAt）。
    /// Esc と Enter は OS の決まりに合わせた固定のキー（割り当ての Doc には載せない）。
    pub def step(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let pressed = key -> App.justPressed(key, frame);
        let w1 =
            if (World.isAskingQuit(w))
                (if (pressed(GameEngine.Key.Enter)) World.answerQuit(true, w)
                 else if (pressed(GameEngine.Key.Escape)) World.answerQuit(false, w)
                 else w)
            else if (pressed(GameEngine.Key.Escape)) World.askQuit(w)
            else w;
        let w2 = if (frame#mouseClicked) tapAt(res, frame#cursor, w1) else w1;
        World.step(res, inputOf(res#docs#keys, frame), Float64.min(frame#dt, 0.1), w2)

    /// cursor を押した。押した物は絵と同じ木（View.promptLayers）から描く順の手前で選ぶ。
    pub def tapAt(res: Res.Res, cursor: Vec2.Vec2, w: World.World): World.World =
        let ctx = App.pickCtx(View.size());
        match SortingLayer.pickFrom(cursor, View.promptLayers(ctx, View.promptOf(res, w))) {
            case Some(World.Press.QuitYes) => World.answerQuit(true, w)
            case Some(World.Press.QuitNo)  => World.answerQuit(false, w)
            case None                      => w
        }

    // ── Doc の読み直し（watchFile / F1） ──

    def reloadLook(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withDocs({ look = TownLook.load(TownLook.path()) | res#docs }, res)

    def reloadExplore(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withDocs({ explore = ExploreDoc.load(ExploreDoc.path()) | res#docs }, res)

    def reloadKeys(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withKeys(KeysDoc.load(KeysDoc.path()), res)

    /// 地図を読み直す。読めなければ前の町のまま 1 行言う（書きかけの地図を保存しても、走っているゲームは止めない）。
    def reloadMap(res: Res.Res): Res.Res \ Fs.FileRead = keptWarned(Res.mapPath(), "前の地図", mapReloaded(TownMap.load(Res.mapPath()), res))

    /// 読み直した地図 loaded で組み直した描く元と、読めずに前の res のまま続けた時の理由。
    pub def mapReloaded(loaded: Result[String, TownMap.TownMap], res: Res.Res): (Res.Res, Option[String]) = match loaded {
        case Ok(m)    => (Res.withDocs({ map = m | res#docs }, res), None)
        case Err(why) => (res, Some(why))
    }

    /// 小物の Doc path を読み直す。読めなければ前の小物のまま 1 行言う。
    def reloadDecor(path: String, res: Res.Res): Res.Res \ Fs.FileRead = keptWarned(path, "前の小物", decorReloaded(path, TownDecor.load(path), res))

    /// 読み直した小物 loaded で組み直した描く元と、読めずに前の res のまま続けた時の理由。
    pub def decorReloaded(path: String, loaded: Result[String, List[TownDecor.Decor]], res: Res.Res): (Res.Res, Option[String]) = match loaded {
        case Ok(ds)   => (Res.withDocs({ decor = Map.insert(path, ds, res#docs#decor) | res#docs }, res), None)
        case Err(why) => (res, Some(why))
    }

    /// 読み直しの結果の描く元（前のまま続けた時は 1 行言う）。
    def keptWarned(subject: String, fallback: String, result: (Res.Res, Option[String])): Res.Res =
        let (res, kept) = result;
        kept |> Option.map(why -> Log.fellBackThen("hd2d", subject, fallback, why, res)) |> Option.getWithDefault(res)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る「表示中」の 3 つは、どれもこの 1 枚から導く。
    /// docId は project.json の editor.resources[] の id と同じ物。
    /// 地図・小物・手触り・見た目（カメラの角度が建物の北に隠れるマスを決める）は格子を替えるので、settle で先頭を通れるマスへ収める。
    // WhyNot: 地図や小物を読み直す時に絵（PNG）を読み直さない — 読み直しは Fs.FileRead だけで、絵を画素にする関数（javax.imageio・ブラウザの decoder）が無い。
    //   地図や小物に新しい絵の名前を書いたら、その板は起動し直すまで出ない。
    pub def docTable(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] =
        Resources.reloadRow("map", Res.mapPath(), reloadMap, World.settle)
            :: Resources.reloadRow("look", TownLook.path(), reloadLook, World.settle)
            :: Resources.reloadRow("explore", ExploreDoc.path(), reloadExplore, World.settle)
            :: Resources.reloadRow("keys", KeysDoc.path(), reloadKeys, (_, w) -> w)
            :: (Res.decorPaths() |> List.map(p -> Resources.reloadRow("decor", p, reloadDecor(p), World.settle)))
}
