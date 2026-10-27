// SceneRender — ゲーム画面を画面なしで PNG に描き出す（スナップショット比較用）。
// 実行: make render-all → gallery/*.png（場面は shotNames）
//       make render SHOT=nvl → debug/nvl.png（1 枚だけ）
// 背景のぼかしは宣言シェーダーの面なので、draw には渡さず ShaderEval が画素ごとに塗る（Render.shaderSurfaces）。
// 写真は project.json の textures をそのまま読む（実機と同じ名前 → 同じファイル）。
// 場面は「進めて作る」: 台本が伸びても行番号を数え直さずに済むよう、「ノードの n 番目の台詞」「選択肢が出るまで」で位置を決める。
mod SceneRender {
    use fge::{App, Clock, DocJson, Emit, HeadlessFont, HeadlessRender, JsonCodec, Render, Vec2, Yarn, YarnStorage}

    import java.io.File
    import java.lang.ProcessHandle

    def design(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    def ttf(): String = "assets/ShipporiMincho-Regular.subset.ttf"

    /// 字の縁も面の縁もならす（写真と明朝の画面。格子に乗せる絵は無い）。
    def cfgOf(outDir: String, textures: Map[String, String]): HeadlessRender.RenderConfig \ IO =
        { design = design(), scale = 1, background = Backdrop.groundColor(),
          fontTtf = ttf(), fontAtlas = HeadlessFont.buildUiAtlas(ttf(), ttf()), texturePath = textures,
          outDir = outDir, frameW = 960, frameH = 540 | HeadlessRender.defaults() }

    /// project.json の textures（名前 → パス）。読めなければ空（背景は代表色ではなく黒になる）。
    def texturesOf(): Map[String, String] \ IO =
        let rows = run { DocJson.readJson("project.json") } with Fs.FileRead.runWithIO;
        rows |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
             |> Option.flatMap(root -> Map.get("textures", root))
             |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(obj ->
                    (JsonCodec.stringOr("name", "", obj), JsonCodec.stringOr("path", "", obj)))))
             |> Option.getWithDefault(Nil) |> List.toMap

    def loadWorld(): World.World \ IO =
        run {
            let docs = Controls.loadDocs();
            World.initial(docs, Saves.fresh(docs#kind))
        } with Fs.FileRead.runWithIO

    pub def all(): Unit \ IO = App.Headless.exitWith(allJob(App.Headless.requestFromProcess()))

    pub def allJob(_req: App.Headless.Request): Int32 \ IO =
        discard allShots();
        0

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。E2e.serveHeadless が束ねる。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("SceneRender", "one", req -> oneJob(req)) ::
        App.Headless.job("SceneRender", "all", req -> allJob(req)) :: Nil

    /// 描き出せる場面の名前（make render の SHOT とギャラリーの並びの正）。
    pub def shotNames(): List[String] =
        "title" :: "nvl" :: "adv" :: "choice" :: "lane" :: "engawa" :: "night" :: "morning" :: "log" :: "load" :: "settings" :: "credits" :: Nil

    /// 名前 → その場面の World。時計は秒で据える（蛍もクレジットも実時間から導くので、据えれば毎回同じ絵）。
    def sceneOf(name: String, w0: World.World): Option[World.World] =
        match name {
            // 表紙: 夕暮れの駅の写真に題とメニュー。
            case "title"    => Some(at(3.0, w0))
            // NVL: 最初の頁。蜩（ひぐらし）のルビが載った 3 行目まで出した所。
            case "nvl"      => Some(at(4.0, nthLine("Station", 2, w0)))
            // ADV: 田んぼの畦道で千夏が振り返る台詞。
            case "adv"      => Some(at(4.0, nthLine("Paddy", 3, w0)))
            // 選択肢: 千夏の呼び方を選ぶ所。
            case "choice"   => Some(at(4.0, toChoices("Paddy", YarnStorage.empty(), w0)))
            // 坂道: 夕暮れの坂の上の家（ADV）。
            case "lane"     => Some(at(4.0, nthLine("Lane", 2, w0)))
            // 縁側: 夜の祖母の家（風鈴が鳴った後）。
            case "engawa"   => Some(at(4.0, nthLine("Engawa", 3, w0)))
            // 朝: 駅へ戻る朝（NVL）。
            case "morning"  => Some(at(4.0, nthLine("Morning", 1, w0)))
            // 夜: 蛍の川で、条件つきの選択肢が選べる所（$closeness = 2）。
            case "night"    =>
                let storage = YarnStorage.withArgs(Map#{ "$closeness" => "2" }, w0#dialogue, YarnStorage.empty()) |> Result.getWithDefault(YarnStorage.empty());
                Some(at(6.5, toChoices("River", storage, w0)))
            // ログ: 田んぼの選択肢まで読んでからログを開いた所。
            case "log"      => Some(at(4.0, open(World.Panel.Log, toChoices("Paddy", YarnStorage.empty(), w0))))
            // 栞: 2 枚挟んである栞の窓（ロード）。
            case "load"     => Some(at(4.0, open(World.Panel.LoadSlots, withTwoSlots(w0))))
            // 設定: 表紙から開いた設定。
            case "settings" => Some(at(3.0, open(World.Panel.Settings, w0)))
            // クレジット: 流れ始めて 12 秒（写真の出典が見えている所）。
            case "credits"  => Some(at(12.0, { creditsFrom = Clock.zero() | World.toCredits(w0) }))
            case _          => None
        }

    /// 物語の時計と実時間の今を、どちらも seconds 秒に据える。
    def at(seconds: Float64, w: World.World): World.World =
        { storyClock = Clock.startAt(seconds), realNow = Clock.after(seconds, Clock.zero()) | w }

    def quiet(f: Unit -> World.World \ Emit[World.Event]): World.World = fst(Emit.collect(f))

    /// node の上から n 番目（0 から）の台詞を出し終えた所（その行までのコマンドは畳んで、演出は終わりの形）。
    def nthLine(node: String, n: Int32, w: World.World): World.World =
        let line = Yarn.nodeOf(node, w#dialogue)
            |> Option.map(found -> found#body |> List.filterMap(statement -> match statement {
                   case Yarn.Statement.Say(say) => Some(say#source#line)
                   case _                       => None
               }))
            |> Option.flatMap(List.nth(n)) |> Option.getWithDefault(0);
        World.revealLine(quiet(() -> World.openAt(YarnStorage.empty(), node, line, w)))

    /// node の頭から選択肢が出るまで送った所（fuel で必ず止まる）。
    def toChoices(node: String, storage: YarnStorage.Storage, w: World.World): World.World =
        def walk(fuel: Int32, cur: World.World): World.World =
            if (fuel <= 0 or World.isAsking(cur)) cur
            else walk(fuel - 1, quiet(() -> World.advance(World.revealLine(cur))));
        World.revealLine(walk(60, quiet(() -> World.openAt(storage, node, 0, w))))

    def open(panel: World.Panel, w: World.World): World.World = quiet(() -> World.openPanel(panel, w))

    /// 田んぼと縁側で 1 枚ずつ栞を挟んだ World（表紙へ戻した形）。
    def withTwoSlots(w: World.World): World.World =
        let first = quiet(() -> World.saveSlot(0, nthLine("Paddy", 3, w)));
        let second = quiet(() -> World.saveSlot(1, nthLine("Engawa", 4, first)));
        World.toTitle({ toast = None | second })

    pub def allShots(): List[String] \ IO = shotsInto("gallery", _ -> true)

    /// 渡した World を 1 枚描いて、そのパスを返す（App.onShotRequest。Studio の会話のプレビュー・bin/fge talk shot）。
    pub def shotOf(w: World.World): String \ IO =
        discard (new File("debug/shot")).mkdirs();
        let cfg = cfgOf("debug/shot", texturesOf());
        shoot(cfg, w, "shot-${ProcessHandle.current().pid()}")

    pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))

    pub def oneJob(req: App.Headless.Request): Int32 \ IO =
        let wanted = Map.getWithDefault("SHOT", "", App.Headless.envOf(req)) |> String.splitOn(substr = " ")
            |> List.map(String.trim) |> List.filter(n -> not String.isEmpty(n));
        let known = List.toSet(shotNames());
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            println("[render] 描けない名前です: ${List.join(" ", unknown)}");
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", shotNames())}");
            1
        } else {
            let picked = List.toSet(wanted);
            discard shotsInto("debug", n -> Set.memberOf(n, picked));
            0
        }

    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let cfg = cfgOf(outDir, texturesOf());
        let w0 = loadWorld();
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, w0) |> Option.map(w -> shoot(cfg, w, name)))

    /// 1 場面を PNG に描き出し、そのファイルパスを返す。hud の合流は実機と同じ App.composeScene を通し、
    /// 背景の面は surfaces として別に取り出して画素ごとに評価させる（draw に渡すと代表色のベタ塗りになる）。
    def shoot(cfg: HeadlessRender.RenderConfig, w: World.World, name: String): String \ IO =
        let ctx = App.viewCtxOf(cfg#fontAtlas, design());
        let items = App.composeScene(None, 1.0, cfg#design, { world = View.frame(ctx, w), hud = View.hud(ctx, w) });
        let (drawables, polygons) = Render.draw(Render.withoutShaders(items));
        HeadlessRender.renderPngWith(cfg, drawables, polygons, Render.shaderSurfaces(items), name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
