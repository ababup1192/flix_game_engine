// Controls — キーとスティックを動く向き（長さ 0〜1）へ写し、World.step で 1 歩進める（純粋）。
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
        Res.withDocs({ keys = KeysDoc.load(KeysDoc.path()) | res#docs }, res)

    /// 地図を読み直す。読めなければ前の町のまま 1 行言う（書きかけの地図を保存しても、走っているゲームは止めない）。
    def reloadMap(res: Res.Res): Res.Res \ Fs.FileRead = mapReloaded(TownMap.load(Res.mapPath()), res)

    /// 読み直した地図 loaded で描く元を組み直す（読めなければ前の res のまま）。
    pub def mapReloaded(loaded: Result[String, TownMap.TownMap], res: Res.Res): Res.Res = match loaded {
        case Ok(m)    => Res.withDocs({ map = m | res#docs }, res)
        case Err(why) => Log.fellBackThen("hd2d", Res.mapPath(), "前の地図", why, res)
    }

    /// 小物の Doc path を読み直す。読めなければ前の小物のまま 1 行言う。
    def reloadDecor(path: String, res: Res.Res): Res.Res \ Fs.FileRead = decorReloaded(path, TownDecor.load(path), res)

    /// 読み直した小物 loaded で描く元を組み直す（読めなければ前の res のまま）。
    pub def decorReloaded(path: String, loaded: Result[String, List[TownDecor.Decor]], res: Res.Res): Res.Res = match loaded {
        case Ok(ds)   => Res.withDocs({ decor = Map.insert(path, ds, res#docs#decor) | res#docs }, res)
        case Err(why) => Log.fellBackThen("hd2d", path, "前の小物", why, res)
    }

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る「表示中」の 3 つは、どれもこの 1 枚から導く。
    /// docId は project.json の editor.resources[] の id と同じ物。
    /// 地図・小物・手触りは格子を替えるので、settle で先頭を通れるマスへ収める。
    // WhyNot: 地図や小物を読み直す時に絵（PNG）を読み直さない — 読み直しは Fs.FileRead だけで、絵を画素にする口（javax.imageio・ブラウザの decoder）が無い。
    //   地図や小物に新しい絵の名前を書いたら、その板は起動し直すまで出ない。
    pub def docTable(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] =
        let unchanged = (_, w) -> w;
        Resources.reloadRow("map", Res.mapPath(), reloadMap, World.settle)
            :: Resources.reloadRow("look", TownLook.path(), reloadLook, unchanged)
            :: Resources.reloadRow("explore", ExploreDoc.path(), reloadExplore, World.settle)
            :: Resources.reloadRow("keys", KeysDoc.path(), reloadKeys, unchanged)
            :: (Res.decorPaths() |> List.map(p -> Resources.reloadRow("decor", p, reloadDecor(p), World.settle)))
}
