// Probe — 「重い一手」を測る道具。ウィンドウを開けずに、面の読み込みと 1 tick、
// そしてタイル層の組み立てにかかる時間を出す。
//
// 実行: make probe
//
// これが要る理由: クリアの瞬間に固まる・面が切り替わらない、といった症状は
// 描画とロジックのどちらが重いか分からない。ここで数字にしておくと、
// 「1 面クリアで固まる」が二度と勘の当てっこにならない。
mod Probe {
    import java.lang.System

    def loadWorld(): World.World \ IO =
        run {
            World.initial(MotionDoc.load(MotionDoc.path()),
                KeysDoc.load(KeysDoc.path()),
                RulesDoc.load(RulesDoc.path()),
                EnemyDoc.load(EnemyDoc.path()),
                StageDoc.load(StageDoc.path()),
                Theme.load(Theme.path()),
                UiText.load(UiText.path()),
                PxSpriteDoc.load(World.spritePath()))
        } with Fs.FileRead.runWithIO

    /// マイクロ秒。ms 単位だと「速い」と「測れていない」の区別が付かない。
    /// 純粋な計算はそのままだと並べ替えられて「0 us」に潰れるので、
    /// 結果を region の箱へ入れて時計の間に縛り付ける。
    def usOf(thunk: Unit -> a \ ef): (a, Int64) \ ef + IO =
        region rc {
            let t0 = System.nanoTime();
            let cell = Ref.fresh(rc, thunk());
            let t1 = System.nanoTime();
            (Ref.get(cell), (t1 - t0) / 1000i64)
        }

    def idle(): World.Input =
        { dir = 0.0, jumpHeld = false, jumpPressed = false, drop = false, dash = false }

    /// 1 フレームの予算(us)。60fps の 1 コマ = 16.7ms — 実機が毎フレーム組む
    /// frameLive がこれを超えたら、その面はもう間に合っていない。
    def budgetUs(): Int64 = 16000i64

    pub def all(): Unit \ IO =
        let w0 = loadWorld();
        let font = HeadlessFont.buildUiAtlas("assets/Xolonium-Regular.ttf",
                                            "assets/Xolonium-Regular.ttf");
        List.forEach(ix -> probeStage(font, ix, w0),
                     List.range(0, List.length(StageDoc.rec(w0#stageDoc)#stages)));
        // 実戦の遷移: clear の間を置いてから次の面へ落ちるところ全部。
        let (_, us) = usOf(_ -> {
            let cleared = { phase = "clear", phaseT = 1.7 | w0 };
            World.step(idle(), 1.0 / 60.0, cleared)
        });
        println("clear->next transition: ${us} us")

    /// 実機が毎フレーム組むのと同じ絵の部品。
    def ctxOf(font: FontAtlas, w: World.World): App.ViewCtx =
        let design = View.design();
        { visible = { position = Vec2.sub(w#cam, Vec2.mul(design, 0.5)), size = design }
        | App.viewCtxOf(font, design) }

    def probeStage(font: FontAtlas, ix: Int32, w0: World.World): Unit \ IO =
        let (w, loadUs) = usOf(_ -> World.loadStage(ix, w0));
        let (_, stepUs) = usOf(_ ->
            List.range(0, 60) |> List.foldLeft((acc, _) ->
                World.step(idle(), 1.0 / 60.0, acc), w));
        let (tiles, tileUs) = usOf(_ ->
            List.length(TerrainLayers.layerTiles(w, View.zWall()))
                + List.length(TerrainLayers.layerTiles(w, View.zFore())));
        let ctx = ctxOf(font, w);
        // 実機は frameLive(GPU 層に乗らない分だけ)・描き出しは frame(全部を絵にする)。
        let (live, liveUs) = usOf(_ -> List.length(View.frameLive(ctx, w)));
        let (rendered, renderUs) = usOf(_ -> List.length(View.frame(ctx, w)));
        // 実機の 1 フレームが予算に収まったかを印にする(数字だけだと合否が読めない)。
        let mark = if (liveUs <= budgetUs()) "OK " else "NG ";
        println("${mark}${Stage.rec(w#stage)#name}: loadStage ${loadUs} us / 60 tick ${stepUs} us"
            + " / tiles ${tiles} 枚 ${tileUs} us"
            + " / 実機 ${live} 部品 ${liveUs} us / 描き出し ${rendered} 部品 ${renderUs} us")
}
