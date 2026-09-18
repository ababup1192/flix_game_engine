// SceneRender — ゲーム画面を画面なしで PNG に生成する（スナップショット比較・目視批評用）。
// 実行: make render-all → gallery/title.png・s1_start.png .. s4_over.png
//       make render SHOT=s3_clear → debug/s3_clear.png（1 枚だけ）
// すべて決定的な場面（時計 t は場面ごとに固定値を入れる）。World を直接組み（RNG を回さず固定し）、
// 実機と同じ描画経路（View.frame → Render.draw → HeadlessRender.renderPng）で生成する。
mod SceneRender {
    import java.io.File
    import java.lang.System

    def design(): Vec2.Vec2 = { x = 256.0, y = 352.0 }

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        { design = design(), scale = 2, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = outDir, frameW = 512, frameH = 704 | HeadlessRender.defaults() }

    def loadWorld(): World.World \ IO =
        run { World.initial(Controls.loadDocs()) } with Fs.FileRead.runWithIO

    pub def all(): Unit \ IO =
        discard allShots()

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    pub def shotNames(): List[String] =
        "title" :: "s1_start" :: "s2_stack" :: "s3_clear" :: "s4_over" :: Nil

    /// 名前 → その場面の World。shotNames と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ描くときに残りの場面は組まない。
    def sceneOf(name: String, w0: World.World): Option[World.World] =
        match name {
            // title: ジャンルカードの顔（彩り豊かな中盤の一枚）。Studio が reference/title.png を
            // /genesis/title で読み、「パズル」のジャンルカードのサムネイルにする（各 starter 共通の規約）。
            case "title"    => Some(stackScene(w0))
            // s1: 初期盤（空）+ 涌いたばかりの current + NEXT + score 0。
            case "s1_start" => Some({ t = 0.4 | w0 })
            // s2: 積み上がった中盤 + 落下中のミノ + ゴースト。
            case "s2_stack" => Some(stackScene(w0))
            // s3: ライン消しの演出中（下 2 行が満杯・演出の途中で固定）。
            case "s3_clear" => Some(clearScene(w0))
            // s4: GAME OVER の幕。
            case "s4_over"  => Some(overScene(w0))
            case _          => None
        }

    /// SceneRender.all の中身。生成した PNG のパス列を返す — 走行中のゲームへの POST /render も呼ぶ。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ生成する（スナップショットを汚さない）。
    /// 実行: make render SHOT=s3_clear
    pub def one(): Unit \ IO =
        let wanted = envOr("SHOT", "") |> String.splitOn(substr = " ")
            |> List.map(String.trim) |> List.filter(n -> not String.isEmpty(n));
        let known = List.toSet(shotNames());
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            println("[render] 描けない名前です: ${List.join(" ", unknown)}");
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", shotNames())}");
            System.exit(1)
        } else {
            let picked = List.toSet(wanted);
            discard shotsInto("debug", n -> Set.memberOf(n, picked))
        }

    /// keep が真を返す場面だけを outDir へ生成し、そのファイルパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w0 = loadWorld();
        let cfg = cfgOf(outDir, atlas, ThemeDoc.rec(w0#theme)#bg);
        let ctx = App.viewCtxOf(atlas, design());
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, w0) |> Option.map(w -> shoot(cfg, ctx, w, name)))

    def envOr(key: String, fallback: String): String \ IO =
        let value = System.getenv(key);
        if (Object.isNull(value)) fallback else value

    // ── 決定的な場面の脚本（RNG を回さず board を直接組む） ──

    /// 下のほうに凸凹の山を積み、落下中の T ミノを中空に置いた中盤。ゴーストも出る。
    def stackScene(w0: World.World): World.World =
        // 各列の「山の高さ」（下から何段積むか）。決定的な凸凹。
        let heights = 4 :: 6 :: 5 :: 3 :: 2 :: 4 :: 5 :: 6 :: 3 :: 1 :: Nil;
        let board = heights |> List.zipWithIndex |> List.foldLeft((b, entry) -> {
            let (c, h) = entry;
            List.range(0, h) |> List.foldLeft((b2, k) -> {
                let r = World.rows() - 1 - k;
                Map.insert((c, r), stackKind(c + k), b2)   // 色は決定的にばらす
            }, b)
        }, Map.empty());
        { board = board,
          current = { kind = World.Kind.T, rot = 0, col = 4, row = 3 },
          nextKind = World.Kind.L, phase = World.Phase.Playing, t = 1.1 | w0 }

    /// ライン消しの演出中。下 2 行を満杯にして固定し、演出を途中（40%）で止める。
    def clearScene(w0: World.World): World.World =
        let bottom = World.rows() - 1;
        let full = (bottom :: (bottom - 1) :: Nil) |> List.foldLeft((b, r) ->
            List.range(0, World.cols()) |> List.foldLeft((b2, c) ->
                Map.insert((c, r), clearKind(c), b2), b), Map.empty());
        // その上に少し土台を残す（消える行の上に積みがある状態を見せる）。
        let withTower = List.range(0, 4) |> List.foldLeft((b, c) ->
            Map.insert((c, bottom - 2), World.Kind.J, b), full);
        { board = withTower, phase = World.Phase.Clearing,
          clearRows = bottom :: (bottom - 1) :: Nil,
          clearTimer = RulesDoc.rec(w0#doc)#clearDuration * 0.4, t = 2.6 | w0 }

    /// GAME OVER の幕。盤を上まで積んで overlay を写す。
    def overScene(w0: World.World): World.World =
        let board = List.range(0, World.rows()) |> List.foldLeft((b, r) ->
            List.range(0, World.cols()) |> List.foldLeft((b2, c) ->
                // まばらに空けて「積み上がった山」らしく（全面ベタ塗りにしない）。
                if (Int32.modulo(c + r, 5) == 0) b2 else Map.insert((c, r), overKind(c, r), b2), b),
            Map.empty());
        { board = board, phase = World.Phase.GameOver, score = 4200, lines = 24, t = 5.0 | w0 }

    // ── セルの色を決定的にばらす小物（種類 = 色。7 種を順に舐める） ──
    def kindAt(i: Int32): World.Kind =
        List.drop(Int32.modulo(Int32.abs(i), 7), Pieces.all()) |> List.head
            |> Option.getWithDefault(World.Kind.I)
    def stackKind(i: Int32): World.Kind = kindAt(i)
    def clearKind(i: Int32): World.Kind = kindAt(i + 2)
    def overKind(c: Int32, r: Int32): World.Kind = kindAt(c * 3 + r)

    /// 1 場面を PNG に生成し、生成したファイルパスを返す。hud の合流は実機と同じ
    /// App.composeScene を通す（カメラ無しなので center = None・等倍）。
    def shoot(cfg: HeadlessRender.RenderConfig, ctx: App.ViewCtx, w: World.World, name: String): String \ IO =
        let items = App.composeScene(None, 1.0, cfg#design,
            { world = View.frame(ctx, w), hud = View.hud(ctx, w) });
        let (drawables, polygons) = Render.draw(items);
        HeadlessRender.renderPng(cfg, drawables, polygons, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
