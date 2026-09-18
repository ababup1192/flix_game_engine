// SceneRender — ゲーム画面を画面なしで PNG に描き出す（スナップショット比較用と、アトリエ候補のプレビュー用）。
// 実行: make render-all → gallery/title.png・choice.png・ending.png
//       make render SHOT=choice → debug/choice.png（1 枚だけ）
//       make atelier-preview → debug/atelier/*.png（スナップショットの外）
// 場面は「進めて作る」: 台本が伸びてもビート数を数え直さずに済むよう、
// 「選択肢待ちになるまで進める」「結末の最後のビートまで進める」で位置を決める。
mod SceneRender {
    import java.io.File
    import java.lang.System

    def design(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    def ttf(): String = "assets/PixelMplus10-Regular.ttf"

    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        // 面の縁はならさない — 額縁は 16×12 のドット絵を 4 倍で置くので、ならすと
        // legend に無い中間色が縁に湧く。字は残す（本文 9px・ヒント 7px の TTF は
        // 縁をならさないと読めない）。この 2 つが逆を向くのがこのテンプレの形。
        { design = design(), scale = 2, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = outDir, frameW = 960, frameH = 600,
          shapeAntialias = false | HeadlessRender.defaults() }

    def loadWorld(): World.World \ IO =
        run {
            World.initial(Controls.loadDocs(), NovelKit.spawnAssets())
        } with Fs.FileRead.runWithIO

    // ── 決定的な場面（スナップショット） ──

    pub def all(): Unit \ IO =
        discard allShots()

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    pub def shotNames(): List[String] =
        "title" :: "choice" :: "ending" :: Nil

    /// 名前 → その場面の World。shotNames と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ描くときに残りの場面は台本を歩かない。
    /// 場面ごとに時計 t を固定する（雨も炎も埃も t から導くので、
    /// 据えれば毎回同じ絵になる = スナップショットがバイトで比べられる）。
    def sceneOf(name: String, w0: World.World): Option[World.World] =
        match name {
            // 表紙: 灯りが全部ついた書斎とタイトル。
            case "title"  => Some({ t = 2.3 | w0 })
            // 最初の分岐: 問いを読み終え、選択肢のチップが出た状態。
            case "choice" => Some({ t = 5.1 | walkToAsk(40, World.advance(w0)) })
            // 結末: 疑いを重ねて灯りが消えた書斎で、最後の一文を読んでいる状態。
            // （分岐 2 つは選んで次の分岐まで歩き、最後の告発だけは結末の最後のビートで止める）
            case "ending" =>
                let ended = walkToAsk(40, World.advance(w0))
                    |> pickAndWalk(0) |> pickAndWalk(0) |> World.pick(1) |> walkToLast(40);
                Some({ t = 8.4 | ended })
            case _        => None
        }

    /// SceneRender.all の中身。描き出した PNG のパス列を返す — 走行中のゲームへの POST /render
    /// （Main の App.onRenderRequest）もこれを呼ぶ。プレイ状態には触れず Docs から組み立てる。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ描き出す（スナップショットを汚さない）。
    /// 実行: make render SHOT=choice
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

    /// keep が真を返す場面だけを outDir へ描き出し、そのファイルパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w0 = loadWorld();
        let (cfg, texInfo) = withAtlasOf(cfgOf(outDir, atlas, ThemeDoc.rec(w0#theme)#bg), w0);
        let ctx = App.viewCtxOf(atlas, design());
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, w0) |> Option.map(w -> shoot(cfg, texInfo, ctx, w, name)))

    /// 実機が GPU へ上げるのと同じアトラスの画素を PNG に落とし、「そこから貼れる cfg」と
    /// texInfo を返す（描き出しは PNG からしか絵を読めない）。View が drawQuad で貼るので、
    /// これを通さないとドット絵が仮色の板になる。
    /// 置き場所は生成先でなく debug/ に固定する — gallery/ に混ぜると、絵の顔ぶれを
    /// 突き合わせる reference-check が「増えた絵」として落とす。
    def withAtlasOf(cfg: HeadlessRender.RenderConfig, w: World.World):
            (HeadlessRender.RenderConfig, String -> Option[GameEngine.TextureInfo]) \ IO =
        let images = PxSpriteAtlas.asImages(
            { texture = World.atlasName(), baked = w#atlas } :: Nil);
        ({ texturePath = HeadlessRender.imagePngs("debug", images) | cfg },
         HeadlessRender.imageTextureInfo(images))

    def envOr(key: String, fallback: String): String \ IO =
        let value = System.getenv(key);
        if (Object.isNull(value)) fallback else value

    /// 1 場面を PNG に描き出し、そのファイルパスを返す。hud の合流は実機と同じ
    /// App.composeScene を通す（カメラ無しなので center = None・等倍）。
    /// アトラスから貼るクアッドがあるので、素の Render.draw ではなく texInfo つきの
    /// drawWith を通す。
    def shoot(cfg: HeadlessRender.RenderConfig, texInfo: String -> Option[GameEngine.TextureInfo],
              ctx: App.ViewCtx, w: World.World, name: String): String \ IO =
        let items = App.composeScene(None, 1.0, cfg#design,
            { world = View.frame(ctx, w), hud = View.hud(ctx, w) });
        let (drawables, polygons) = Render.drawWith(texInfo, items);
        HeadlessRender.renderPng(cfg, drawables, polygons, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path

    /// 文字送りを使い切って 1 ビート読み終えた状態にする（UI への投影も済む）。
    def settle(w: World.World): World.World = World.step(60.0, w)

    /// 選択肢待ちになるまでビートを進める（fuel で必ず止まる）。
    def walkToAsk(fuel: Int32, w: World.World): World.World =
        let settled = settle(w);
        if (fuel <= 0 or NovelKit.isAsking(settled#kit)) settled
        else walkToAsk(fuel - 1, World.advance(settled))

    /// 選択肢 i を選んで、次の選択肢待ちまで進める（途中に分岐が無ければ最後まで歩く）。
    def pickAndWalk(i: Int32, w: World.World): World.World =
        walkToAsk(40, World.pick(i, w))

    /// これ以上進めると表紙へ戻る、その手前（結末の最後のビート）で止める。
    def walkToLast(fuel: Int32, w: World.World): World.World =
        let settled = settle(w);
        let next = World.advance(settled);
        if (fuel <= 0 or next#phase == World.Phase.Title) settled
        else walkToLast(fuel - 1, next)

    // ── アトリエ（候補スプライト・候補テーマのプレビュー。スナップショットの外） ──

    /// atelier/*.sprite.json（候補）と assets/*.sprite.json（現行 → <名前>.current）を
    /// 実機と同じ描画経路（PxSprite.draw + ThemeDoc.resolver）でコンタクトシートに描き出す。
    /// atelier/*.theme.json（候補）は代表場面（表紙）で描き出す。
    /// 前回描き出した残り（古い候補の PNG）は先に消す。読めない・種類の違う JSON は黙って飛ばす（fail-open）。
    pub def atelier(): Unit \ IO =
        discard (new File("debug/atelier")).mkdirs();
        // 前回描き出した残りを消す（候補を消したのに絵が残ると紛らわしい）。
        jsonsIn("debug/atelier", ".png") |> List.forEach(f ->
            discard (new File("debug/atelier/${f}")).delete());
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let theme = run { ThemeDoc.load(ThemeDoc.path()) } with Fs.FileRead.runWithIO;
        let cfg = cfgOf("debug/atelier", atlas, ThemeDoc.rec(theme)#bg);
        let ctx = App.viewCtxOf(atlas, design());
        // スプライト: 候補 + 現行。
        let jobs = List.append(
            jsonsIn("atelier", ".sprite.json") |> List.map(f -> ("atelier/${f}", stripJson(f))),
            jsonsIn("assets", ".sprite.json") |> List.map(f -> ("assets/${f}", "${stripJson(f)}.current")));
        jobs |> List.forEach(job -> {
            let (path, out) = job;
            let doc = run { PxSpriteDoc.load(path) } with Fs.FileRead.runWithIO;
            if (Map.isEmpty(doc#sprites)) ()
            else spriteSheet(cfg, doc, theme, out)
        });
        // テーマ: 候補を代表場面（表紙）で描き出す（現行は SceneRender.all の title が兼ねる）。
        jsonsIn("atelier", ".theme.json") |> List.forEach(f -> {
            let text = run { Fs.ReadFile.read("atelier/${f}") } with Fs.ReadFile.runWithFileRead
                with Fs.FileRead.runWithIO;
            match (text |> Result.toOption |> Option.flatMap(ThemeDoc.fromJson)) {
                case None => ()
                case Some(cand) => {
                    // 候補テーマは配色ごと変わる = アトラスの画素も変わるので、候補ごとに作り直す。
                    let candWorld = World.withTheme(cand, loadWorld());
                    let (candCfg, candTex) = withAtlasOf({ background = ThemeDoc.rec(cand)#bg | cfg }, candWorld);
                    discard shoot(candCfg, candTex, ctx, candWorld, stripJson(f))
                }
            }
        })

    /// 1 Doc の全スプライト×全コマを 1 枚に並べる。
    def spriteSheet(cfg: HeadlessRender.RenderConfig, doc: PxSpriteDoc.Doc, theme: ThemeDoc.Doc,
                    out: String): Unit \ IO =
        let s = 4;
        let cellW = 74.0;
        let cellH = 56.0;
        let items = Map.toList(doc#sprites) |> List.zipWithIndex |> List.flatMap(entry -> {
            let (rowIdx, sp) = entry;
            let (name, sprite) = sp;
            let y0 = 10.0 + Int32.toFloat64(rowIdx) * cellH;
            Map.toList(sprite#frames) |> List.zipWithIndex |> List.flatMap(frEntry -> {
                let (frameIdx, fr) = frEntry;
                let (frame, _) = fr;
                let x0 = 10.0 + Int32.toFloat64(frameIdx) * cellW;
                PxSprite.draw(doc, name, frame, { x = x0, y = y0 },
                    false, s, key -> ThemeDoc.resolver(theme, key), 10)
            })
        });
        let (drawables, polygons) = Render.draw(items);
        HeadlessRender.renderPng(cfg, drawables, polygons, out);
        println("rendered: ${cfg#outDir}/${out}.png")

    // ── 小物 ──

    def jsonsIn(dir: String, suffix: String): List[String] \ IO =
        let entries = (new File(dir)).list();
        if (Object.isNull(entries)) Nil
        else Array.toList(entries)
            |> List.filter(f -> String.endsWith(suffix = suffix, f))
            |> List.sort

    def stripJson(f: String): String =
        if (String.endsWith(suffix = ".json", f))
            String.dropRight(String.length(".json"), f)
        else f
}
