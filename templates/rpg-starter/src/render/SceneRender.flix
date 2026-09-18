// SceneRender — ゲーム画面を画面なしで PNG に描き出す（スナップショット比較用と、アトリエ候補のプレビュー用）。
// 実行: make render-all → gallery/title.png・walk.png・talk.png・door.png・battle.png・clear.png・terrain_grain.png
//       make render SHOT=walk → debug/walk.png（1 枚だけ）
//       make atelier-preview → debug/atelier/*.png（スナップショットの外）
// 場面の作り方は 2 通りを使い分ける:
//   - 主人公の動き（歩く・話す・扉の前に立つ）は World の規則（stepOnce / confirm）で作る
//     — 実機と同じ経路を通った絵になる。
//   - 立ち位置そのものは Doc の配置（住人・扉のマス）から導いて直接置く
//     — 間取りを編集しても描き出しの脚本を書き直さずに済む。
mod SceneRender {
    import java.io.File
    import java.lang.System

    def design(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    def ttf(): String = "assets/PixelMplus10-Regular.ttf"

    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        // 面の縁はならさない — ドット絵は 16×16・等倍で、タイルの目に合わせて置く画面。
        // ならすとタイルの継ぎ目に色票に無い中間色が湧く。字は既定のまま残す。
        { design = design(), scale = 3, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = outDir, frameW = 960, frameH = 720,
          shapeAntialias = false | HeadlessRender.defaults() }

    def loadWorld(): World.World \ IO =
        run { World.initial(Controls.loadDocs()) } with Fs.FileRead.runWithIO

    // ── 決定的な場面（スナップショット） ──

    pub def all(): Unit \ IO =
        discard allShots()

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    pub def shotNames(): List[String] =
        "title" :: "walk" :: "talk" :: "door" :: "battle" :: "clear"
            :: "terrain_grain" :: Nil

    /// 名前 → その場面の World。shotNames と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ描くときに残りの場面は歩かせない。
    /// terrain_grain だけは World を持たない別の絵なので、ここでは None（shotsInto が描く）。
    def sceneOf(name: String, w0: World.World): Option[World.World] =
        match name {
            // 表紙: 里の一角に幕、その上に題と一行。
            case "title"  => Some(w0)
            // 歩き: start から 3 歩（規則で歩く。3 歩 = 歩きのコマが出る奇数）。
            case "walk"   => Some(World.confirm(w0)
                |> World.stepOnce(Dir4.Right) |> World.stepOnce(Dir4.Right)
                |> World.stepOnce(Dir4.Down))
            // 会話: いちばん後ろの住人（間取りの Doc の並びの末尾）の隣に立って話しかけ、
            // 文字送りを全部出す（settle）。
            case "talk"   => Some(talkScene(World.confirm(w0)))
            // 扉前: 閉じた木戸に向いて立つ。
            case "door"   => Some(doorScene(World.confirm(w0)))
            // 戦い: 魔物と向き合い、1 回殴り合った直後（下のウィンドウに打ち合いの結果が出ている）。
            case "battle" => Some(battleScene(World.confirm(w0)))
            // クリア: 薬草がそろい、灯りが全部ともった里。
            case "clear"  => Some(clearScene(World.confirm(w0)))
            case _        => None
        }

    /// SceneRender.all の中身。描き出した PNG のパス列を返す — 走行中のゲームへの POST /render
    /// （Main の App.onRenderRequest）もこれを呼ぶ。プレイ状態には触れず Docs から組み立てる。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ描き出す（スナップショットを汚さない）。
    /// 実行: make render SHOT=walk
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
        // 地面のタイルと建物は 1 枚のアトラスから貼る。SoftRaster はファイルからしか
        // 絵を読めないので、アトラスを debug/ に落として texturePath で渡す
        // （gallery/ にスナップショット以外の生成物を置かない）。
        let images = PxSpriteAtlas.asImages(
            { texture = TownMap.textureName(), baked = w0#townAtlas } ::
            { texture = World.charAtlasName(), baked = w0#charAtlas } :: Nil);
        let texPaths = HeadlessRender.imagePngs("debug", images);
        let cfg = { texturePath = texPaths | cfgOf(outDir, atlas, ThemeDoc.rec(w0#theme)#sky) };
        let shots = shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, w0) |> Option.map(w -> shoot(cfg, atlas, images, w, name)));
        // 地面の質感: assets/rpg.terrain.json の表で土・石垣・水路・畑を敷いた 1 枚。
        if (not keep("terrain_grain")) shots
        else {
            let terrainDoc = run { TerrainDoc.load(terrainPath()) } with Fs.FileRead.runWithIO;
            let terrain = terrainShot({ texturePath = Map.empty() | cfg }, w0#theme, terrainDoc);
            List.append(shots, terrain :: Nil)
        }

    def envOr(key: String, fallback: String): String \ IO =
        let value = System.getenv(key);
        if (Object.isNull(value)) fallback else value

    /// 魔物と出会い、「たたかう」を 1 回選んだ直後。歩数も打ち合いも規則どおりに進める
    /// （World を手で組まない = 規則が変わればこの絵も一緒に変わる）。
    def battleScene(playing: World.World): World.World =
        let met = walkUntilFoe(BattleDoc.rec(playing#battleDoc)#encounterSteps, playing);
        // 出会いの 1 行を読み終え（決定）、「たたかう」を選ぶ（決定）。
        World.confirm(World.confirm(met)) |> withClock(2.1)

    /// 魔物に出会うまで規則どおり歩く（左右に往復するので間取りが小さくても歩数が稼げる）。
    /// 上限を切って必ず止まる（Doc で encounterSteps を 0 にしても回り続けない）。
    def walkUntilFoe(budget: Int32, w: World.World): World.World =
        if (budget <= 0 or w#phase == World.Phase.Battle) w
        else {
            let dir = if (Int32.modulo(budget, 2) == 0) Dir4.Right else Dir4.Left;
            walkUntilFoe(budget - 1, World.stepOnce(dir, w))
        }

    /// 時計を決まった秒に据える（またたきや息づかいを毎回同じ位相で描き出すため）。
    def withClock(t: Float64, w: World.World): World.World = { t = t | w }

    /// 住人の隣（歩けるマス）に立ち、規則どおり話しかけて文字送りを終えた状態。
    /// 話し相手は villagers の末尾 — 約束の相手（先頭に置く習わし）でない住人が選ばれ、
    /// ふつうの 1 行のふきだしが写る。住人がいなければそのまま（fail-open）。
    def talkScene(playing: World.World): World.World =
        match List.last(MapDoc.rec(playing#map)#villagers) {
            case None           => playing
            case Some(villager) => match standNextTo(villager#cell, playing) {
                case None    => playing
                case Some(w) => settle(World.confirm(w))
            }
        }

    /// 閉じた木戸の前に立ち、木戸のほうを向いた状態。
    def doorScene(playing: World.World): World.World =
        standNextTo(MapDoc.rec(playing#map)#door#cell, playing) |> Option.getWithDefault(playing)

    /// 薬草がそろってクリアになった状態（扉は開き、灯りは全部ともる）。
    /// 収支は World の導出（goalOf / lampsLit）に合わせて置く。
    def clearScene(playing: World.World): World.World =
        { phase = World.Phase.Clear, doorOpen = true,
          herbs = Nil, picked = World.goalOf(playing) | playing }

    /// target の四方の歩けるマスに主人公を置き、target のほうを向かせる。
    /// （立ち位置は Doc の配置から導く — 間取りを編集しても脚本が壊れない。）
    /// 下側を先に試す — ふきだしは相手の頭の上に出るので、主人公が隠れない。
    def standNextTo(target: Grid.Cell, w: World.World): Option[World.World] =
        (Dir4.Down :: Dir4.Left :: Dir4.Right :: Dir4.Up :: Nil)
            |> List.filter(d -> World.walkable(Grid.neighborOf(target, d), w))
            |> List.head
            |> Option.map(d -> { hero = Grid.neighborOf(target, d), facing = Dir4.opposite(d) | w })

    /// 文字送りを使い切って 1 行を読み終えた状態にする。
    def settle(w: World.World): World.World = World.step(None, 60.0, w)

    /// 実機と同じ camera 中心を出す（追従 → bounds へ収める → 1px 吸着の順。
    /// App の resolvedCamera と同じ式 — 描き出しだけ別の式にすると実機と絵がずれる）。
    def cameraOf(w: World.World, design0: Vec2.Vec2): Vec2.Vec2 =
        let clamped = CameraRig.clampCenter(
            bounds = World.boardRect(w), seen = design0, World.cameraCenter(w));
        { x = Float64.round(clamped#x), y = Float64.round(clamped#y) }

    /// 1 場面を PNG に描き出し、そのファイルパスを返す。world 側の絵に camera を掛けて
    /// hud を重ねる合成は、実機と同じ App.composeScene を通す。
    /// 地面（タイル層）は実機ではエンジンの別チャンネルなので、描き出しでは
    /// TileScene.toItems の CPU 投影を world の先頭に足して同じ絵にする。
    def shoot(cfg: HeadlessRender.RenderConfig, atlas: FontAtlas,
              images: List[{ name = String, side = Int32, pixelAt = (Int32, Int32) -> Int32 }],
              w: World.World, name: String): String \ IO =
        shootAt(cfg, atlas, images, w, cameraOf(w, cfg#design), name)

    /// camera 中心を自分で決める版（建物のクローズアップ等）。
    def shootAt(cfg: HeadlessRender.RenderConfig, atlas: FontAtlas,
                images: List[{ name = String, side = Int32, pixelAt = (Int32, Int32) -> Int32 }],
                w: World.World, center: Vec2.Vec2, name: String): String \ IO =
        let design0 = cfg#design;
        let ctx = { atlas = atlas, fontOf = _ -> atlas,
                    visible = App.visibleOf(Some(center), 1.0, design0) };
        // hud には常に design 全体が見えている扱い（実機の sceneItems と同じ）。
        let hudCtx = { atlas = atlas, fontOf = _ -> atlas,
                       visible = App.visibleOf(None, 1.0, design0) };
        let ground = match w#phase {
            case World.Phase.Battle => Nil
            case _ => TileScene.toItems(TownMap.spec(w#townMap, w#townAtlas))
        };
        let items = App.composeScene(Some(center), 1.0, design0,
            { world = List.append(ground, View.frame(ctx, w)), hud = View.hud(hudCtx, w) });
        // シェーダー面（水面）は画素評価のチャンネルへ分け、draw 側からは外して二重に塗らない。
        let surfaces = Render.shaderSurfaces(items);
        let (drawables, polygons) =
            Render.drawWith(HeadlessRender.imageTextureInfo(images), Render.withoutShaders(items));
        HeadlessRender.renderPngWith(cfg, drawables, polygons, surfaces, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path

    // ── 地面の質感（terrain の表で敷いた 1 枚） ──
    // 遊ぶ画面（World / View）はこの経路を通らない。表は assets/rpg.terrain.json、
    // 盤の文字はこの場面だけの脚本。

    def terrainPath(): String = "assets/rpg.terrain.json"

    /// 石垣が三方を囲む城下町の一角。西の門から入った土の道が畑のあいだを東へ抜け、
    /// 途中で南へ折れて細くなり、水路の渡し場へ下りる。対岸にも畑が並ぶ。
    /// 道は幅 2 マス以上と幅 1 マスを両方持つ — 粒が細い形でも中央へ潰れずに
    /// 散るかを 1 枚で見るため。
    def terrainRows(): List[String] =
           "###################"
        :: "###################"
        :: "##               ##"
        :: ".............    ##"
        :: ".............    ##"
        :: "##,,,,,,   .. ,,,##"
        :: "##,,,,,,   .. ,,,##"
        :: "##,,,,,,   .. ,,,##"
        :: "##,,,,,,   .     ##"
        :: "##         .     ##"
        :: "~~~~~~~~~~~~~~~~~~~"
        :: "~~~~~~~~~~~~~~~~~~~"
        :: "  ,,,,,   ,,,,,    "
        :: "  ,,,,,   ,,,,,    "
        :: Nil

    /// Doc の表 → Terrain の表。char ごとにセル集合を引き、spec と重なり順を並べる。
    /// Terrain.fromRows は使わない — あれは spec#surface を見ないので粒が 1 粒も出ない。
    def terrainEntries(theme: ThemeDoc.Doc, doc: TerrainDoc.Doc,
                       rows: List[String]): List[Terrain.Entry] =
        doc#entries |> List.map(e -> {
            let cells = Terrain.cellsOf(ch -> ch == e#char, rows);
            { flagsAt = Terrain.flagsOf(cells), cells = cells,
              spec = TerrainDoc.specOf(key -> ThemeDoc.resolver(theme, key), e),
              z = { fill = 10, stroke = 11, surface = 12 } }
        })

    /// 時刻を見ない粒か。
    /// twinkleRate == 0.0 だけでは足りない — Bubble は period で時刻が入るので、
    /// twinkleRate が 0 でも粒は動く。
    def isStaticFx(fx: Material.SurfaceFx): Bool =
        match fx#shape {
            case Material.SurfaceShape.Bubble => fx#period <= 0.0
            case _                            => fx#twinkleRate == 0.0
        }

    /// entry の粒を、条件に合う fx だけへ絞った entry。
    def withSurfaceFxs(keep: Material.SurfaceFx -> Bool, e: Terrain.Entry): Terrain.Entry =
        { spec = { surface = e#spec#surface |> List.filter(keep) | e#spec } | e }

    /// 地面の質感を gallery/terrain_grain.png に描き出す。時刻は 2.1 で固定
    /// （水路のきらめきが時刻を持つので、揺れない絵にするには据える必要がある）。
    def terrainShot(cfg: HeadlessRender.RenderConfig, theme: ThemeDoc.Doc,
                    doc: TerrainDoc.Doc): String \ IO =
        let rows = terrainRows();
        let tile = World.tileSize();
        let origin = { x = 8.0, y = 8.0 };
        let cols = rows |> List.map(String.length) |> List.foldLeft(Int32.max, 0);
        let entries = terrainEntries(theme, doc, rows);
        // 芝の下地（表に載らない文字はここへ落ちる）。奥ほど深い緑・手前ほど明るい黄緑。
        let ground = { at = Vec2.zero(),
                       item = Render.vgrad(cfg#design,
                           { top = ThemeDoc.resolver(theme, "grassDeep"),
                             bottom = ThemeDoc.resolver(theme, "grassBright") }, 0) } :: Nil;
        let statics = Terrain.staticItems({ tileSize = tile, styleMix = doc#styleMix },
            entries, Terrain.cornersOf(cols, List.length(rows)));
        // 時刻を見ない粒（grain）はマスの並びだけで決まるので、entry ごとに 1 回だけ組んで
        // 持ち回る。毎フレーム描くゲームは、これを World か Ref に置いて使い回す。
        let prebuiltSurface = entries |> List.map(e ->
            Terrain.surfaceItems(tile, withSurfaceFxs(isStaticFx, e) :: Nil, 0.0));
        let animatedEntries = entries |> List.map(e ->
            withSurfaceFxs(fx -> not isStaticFx(fx), e));
        // 静的な表と動的な表を丸ごと連結しない — surface の z は全 entry 共通 12 で、
        // 同じ z の中は入力順で描かれるので、entry をまたいで並べ替えると重なりが変わる。
        // 粒には origin が掛からない（Terrain.fromRows と違い surfaceItems は素の座標）。
        // 掛け直さないと塗りだけがずれて、粒が盤の外へ取り残される。
        let surface = List.zip(prebuiltSurface, animatedEntries) |> List.flatMap(pair -> {
            let (prebuilt, e) = pair;
            List.append(prebuilt, Terrain.surfaceItems(tile, e :: Nil, 2.1))
        });
        let items = List.append(ground,
            Render.movedAll(origin, List.append(statics, surface)));
        let (drawables, polygons) = Render.draw(items);
        HeadlessRender.renderPng(cfg, drawables, polygons, "terrain_grain");
        // 絵の値段（docs/performance.md §9）へ「この分は毎フレーム組み直さない」と申告する。
        // 地形の塗りと時刻を見ない粒は 1 回組んで持ち回る物なので、動的の数から引く。
        // **renderPng の後に呼ぶ** — 先に呼ぶと render 側が前回の申告を消す規約に当たり、
        // 申告が無かったことになる（そのときは動的が過大に出るだけで、緑にはならない）。
        HeadlessRender.noteStaticItems(cfg, "terrain_grain",
            List.append(statics, List.flatten(prebuiltSurface)));
        let path = "${cfg#outDir}/terrain_grain.png";
        println("rendered: ${path}");
        path

    // ── 街の下書き（DQ6級の街並み検証。スナップショットの外・debug/ 行き） ──
    // 盤の正典は Doc（assets/town.map.json）、層の宣言は TownMap — ここは描き出すだけ。
    // この 2 枚は盤全体（640×480）を 1 枚で見たいので、design を盤の寸法に上げた
    // 別 config で描き出す（camera は掛けない — 全景のほうが批評しやすい）。

    def townCfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        { design = { x = 640.0, y = 480.0 }, scale = 2, frameW = 1280, frameH = 960
          | cfgOf(outDir, atlas, bg) }

    /// 街の全景（地面のタイル家族 + 建物 + 人）を debug/town_floor.png に描き出す。
    /// 里を歩いている状態（Play）で組む — 実機の walk 画面と同じ絵の全体が 1 枚で見える。
    pub def town(): Unit \ IO =
        discard (new File("debug")).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w = World.confirm(loadWorld());
        let images = PxSpriteAtlas.asImages(
            { texture = TownMap.textureName(), baked = w#townAtlas } ::
            { texture = World.charAtlasName(), baked = w#charAtlas } :: Nil);
        let texPaths = HeadlessRender.imagePngs("debug", images);
        let cfg = { texturePath = texPaths | townCfgOf("debug", atlas, ThemeDoc.rec(w#theme)#sky) };
        let ctx = App.viewCtxOf(atlas, cfg#design);
        let ground = TileScene.toItems(TownMap.spec(w#townMap, w#townAtlas));
        let items = List.append(ground, View.frame(ctx, { t = 2.1, npcClock = 2.1 | w }));
        let surfaces = Render.shaderSurfaces(items);
        let (drawables, polygons) =
            Render.drawWith(HeadlessRender.imageTextureInfo(images), Render.withoutShaders(items));
        HeadlessRender.renderPngWith(cfg, drawables, polygons, surfaces, "town_floor");
        println("rendered: debug/town_floor.png")

    /// 建物 1 棟のクローズアップ（320×240 等倍・建物が画面中央）を 3 枚描き出す:
    ///   house_closeup … 主人公なし（建物そのものの水準を見る）
    ///   house_behind  … 主人公が建物の裏（北側）— 屋根と壁に隠れることの証明
    ///   house_front   … 主人公が建物の手前（南側）— 全身が建物の前に出ることの証明
    pub def house(): Unit \ IO =
        discard (new File("debug")).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let playing = World.confirm(loadWorld()) |> withClock(2.1);
        let images = PxSpriteAtlas.asImages(
            { texture = TownMap.textureName(), baked = playing#townAtlas } ::
            { texture = World.charAtlasName(), baked = playing#charAtlas } :: Nil);
        let texPaths = HeadlessRender.imagePngs("debug", images);
        let cfg = { texturePath = texPaths | cfgOf("debug", atlas, ThemeDoc.rec(playing#theme)#sky) };
        // カメラは 1 棟目の民家の見た目の中心（位置を変えても追随する）。
        let nw = buildingCell("house", { x = 10, y = 11 });
        let t = World.tileSize();
        let center = { x = (Int32.toFloat64(nw#x) + 2.0) * t,
                       y = (Int32.toFloat64(nw#y) + 1.0) * t - 6.0 };
        let far = { hero = { x = 30, y = 20 } | playing };
        discard shootAt(cfg, atlas, images, far, center, "house_closeup");
        let behind = { hero = { x = nw#x + 1, y = nw#y - 1 }, facing = Dir4.Down | playing };
        discard shootAt(cfg, atlas, images, behind, center, "house_behind");
        let front = { hero = { x = nw#x + 1, y = nw#y + 3 }, facing = Dir4.Down | playing };
        discard shootAt(cfg, atlas, images, front, center, "house_front");
        // 門の開閉（絵が切り替わることの証明）。カメラは門のマスを bounds 内へ収めた位置。
        let doorCell = MapDoc.rec(playing#map)#door#cell;
        let gc0 = { x = Int32.toFloat64(doorCell#x) * t + t / 2.0,
                    y = Int32.toFloat64(doorCell#y) * t };
        let gc1 = CameraRig.clampCenter(bounds = World.boardRect(playing),
            seen = cfg#design, gc0);
        let gc = { x = Float64.round(gc1#x), y = Float64.round(gc1#y) };
        let atGate = { hero = { x = doorCell#x, y = doorCell#y + 1 },
                       facing = Dir4.Up | playing };
        discard shootAt(cfg, atlas, images, atGate, gc, "gate_closed");
        discard shootAt(cfg, atlas, images, { doorOpen = true | atGate }, gc, "gate_open");
        // 2棟目(パン屋)と教会の寄り。カメラは各建物の見た目の中心を bounds 内へ収めた位置。
        discard shootAt(cfg, atlas, images, far,
            buildingCamera(playing, cfg#design, "shop", 3, 3), "shop_closeup");
        discard shootAt(cfg, atlas, images, far,
            buildingCamera(playing, cfg#design, "church", 5, 4), "church_closeup")

    /// 動き物の証明: 同じ場面を別の時刻で描き出す（水面・煙・旗・巡回が動いていれば絵が変わる）。
    ///   water_a/b  … 橋のたもと（水面の網目が流れる）
    ///   smoke_a/b  … パン屋（窯の煙が立ちのぼる）+ 住人 ko の巡回も写る
    pub def motion(): Unit \ IO =
        discard (new File("debug")).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let playing = World.confirm(loadWorld());
        let images = PxSpriteAtlas.asImages(
            { texture = TownMap.textureName(), baked = playing#townAtlas } ::
            { texture = World.charAtlasName(), baked = playing#charAtlas } :: Nil);
        let texPaths = HeadlessRender.imagePngs("debug", images);
        let cfg = { texturePath = texPaths | cfgOf("debug", atlas, ThemeDoc.rec(playing#theme)#sky) };
        let shaderLoaded = run { ShaderJson.load(Controls.waterShaderPath()) } with Fs.FileRead.runWithIO;
        let shaderOk = Result.isOk(shaderLoaded);
        println(if (shaderOk) "waterShader: parsed ok (custom doc)"
                else "waterShader: FELL BACK to waterVeins (vocab?)");
        println("smokeFx: emitters=${Int32.toString(List.length(playing#smokeFx#emitters))} duration=${Float64.toString(playing#smokeFx#duration)} items(t=1.4)=${Int32.toString(List.length(Fx.sample(playing#smokeFx, 7i64, 1.4)))}");
        let bridgeC = { x = 272.0, y = 120.0 };
        let shopC = { x = 344.0, y = 120.0 };
        let at = (t, c, name) -> {
            discard shootAt(cfg, atlas, images,
                { t = t, npcClock = t | playing }, c, name)
        };
        at(1.0, bridgeC, "water_a");
        at(3.0, bridgeC, "water_b");
        at(1.4, shopC, "smoke_a");
        at(3.4, shopC, "smoke_b")

    /// スクロールの継ぎ目検分: camera を半端な座標に置いて描き出す（実機のスクロール中と
    /// 同じ条件）。タイルの貼りに継ぎ目対策（half-texel inset）が効いていれば、
    /// タイル境界に細線（下の色や隣のコマの色）は出ない。
    /// 橋のたもと — 芝・石畳・水の縁が全部写る場所で 2 枚描き出す:
    ///   seam_half  … center の x/y がどちらも .5（タイルとピクセルの位相が最悪の半分ずれ）
    ///   seam_cross … center が .25/.75 でマスの境界をまたぐ（丸めの向きが軸で食い違う形）
    pub def seam(): Unit \ IO =
        discard (new File("debug")).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let playing = World.confirm(loadWorld()) |> withClock(2.1);
        let images = PxSpriteAtlas.asImages(
            { texture = TownMap.textureName(), baked = playing#townAtlas } ::
            { texture = World.charAtlasName(), baked = playing#charAtlas } :: Nil);
        let texPaths = HeadlessRender.imagePngs("debug", images);
        let cfg = { texturePath = texPaths | cfgOf("debug", atlas, ThemeDoc.rec(playing#theme)#sky) };
        discard shootAt(cfg, atlas, images, playing, { x = 272.5, y = 120.5 }, "seam_half");
        discard shootAt(cfg, atlas, images, playing, { x = 264.25, y = 127.75 }, "seam_cross")

    /// 動的 PlacedItem の勘定（DQ6級チェックの性能欄）。タイル層は GPU 側の別チャンネルに
    /// 事前生成されるので数に入れない — 実機で毎フレーム組み直す動的な絵（world + hud）だけを
    /// 実機と同じ合成（App.composeScene = 画面外 culling 込み）で数える。
    pub def count(): Unit \ IO =
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w0 = loadWorld();
        let playing = World.confirm(w0) |> withClock(2.1);
        let scenes =
               ("title", w0)
            :: ("walk", playing)
            :: ("talk", talkScene(playing))
            :: ("battle", battleScene(playing))
            :: ("clear", clearScene(playing)) :: Nil;
        scenes |> List.forEach(sc -> {
            let (name, w) = sc;
            let design0 = design();
            let center = cameraOf(w, design0);
            let ctx = { atlas = atlas, fontOf = _ -> atlas,
                        visible = App.visibleOf(Some(center), 1.0, design0) };
            let hudCtx = { atlas = atlas, fontOf = _ -> atlas,
                          visible = App.visibleOf(None, 1.0, design0) };
            let items = App.composeScene(Some(center), 1.0, design0,
                { world = View.frame(ctx, w), hud = View.hud(hudCtx, w) });
            println("${name}: ${Int32.toString(List.length(items))} items")
        })

    /// 種類で建物の設置マスを引く（無ければ fallback — 描き出しが落ちるより絵がずれる方がよい）。
    def buildingCell(kind: String, fallback: Grid.Cell): Grid.Cell =
        TownMap.buildings()
            |> List.find(b -> b#kind == kind)
            |> Option.map(b -> b#cell)
            |> Option.getWithDefault(fallback)

    /// 建物の見た目の中心に合わせた camera 中心（bounds へ収めて丸める）。
    def buildingCamera(w: World.World, design0: Vec2.Vec2, kind: String,
                       fw: Int32, fh: Int32): Vec2.Vec2 =
        let t = World.tileSize();
        let nw = buildingCell(kind, { x = 0, y = 0 });
        let c0 = { x = (Int32.toFloat64(nw#x) + Int32.toFloat64(fw) / 2.0) * t,
                   y = (Int32.toFloat64(nw#y) + Int32.toFloat64(fh) / 2.0) * t - 24.0 };
        let c1 = CameraRig.clampCenter(bounds = World.boardRect(w), seen = design0, c0);
        { x = Float64.round(c1#x), y = Float64.round(c1#y) }

    /// 同じ盤をタイル層の宣言（TileLayerSpec → TileScene.toItems）経由で
    /// debug/town_floor_scene.png に描き出す。実機の GPU 経路と同じ Spec から派生するので、
    /// town との見比べが「宣言タイル層は正しく敷けるか」の検証になる。
    /// SoftRaster はファイルからしか絵を読めないため、bake したアトラスを
    /// debug/town_tiles.png に落として texturePath で渡す。
    pub def townScene(): Unit \ IO =
        discard (new File("debug")).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let (sprites, theme, townMap) = run {
            (World.loadTownSprites(), ThemeDoc.load(ThemeDoc.path()),
             TownMapDoc.load(TownMapDoc.path()))
        } with Fs.FileRead.runWithIO;
        let (baked, _atlasKey) = World.bakeTownAtlas(sprites, theme);
        let images = PxSpriteAtlas.asImages(
            { texture = TownMap.textureName(), baked = baked } :: Nil);
        let texPaths = HeadlessRender.imagePngs("debug", images);
        let cfg = { texturePath = texPaths | townCfgOf("debug", atlas, ThemeDoc.rec(theme)#sky) };
        let items = TileScene.toItems(TownMap.spec(townMap, baked));
        let (drawables, polygons) = Render.drawWith(HeadlessRender.imageTextureInfo(images), items);
        HeadlessRender.renderPng(cfg, drawables, polygons, "town_floor_scene");
        println("rendered: debug/town_floor_scene.png")

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
        let cfg = cfgOf("debug/atelier", atlas, ThemeDoc.rec(theme)#sky);
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
                    // 候補テーマはアトラスの実色も変える — その候補の色で bake し直して渡す。
                    let wc = World.withTheme(cand, loadWorld());
                    let images = PxSpriteAtlas.asImages(
                        { texture = TownMap.textureName(), baked = wc#townAtlas } ::
                        { texture = World.charAtlasName(), baked = wc#charAtlas } :: Nil);
                    let texPaths = HeadlessRender.imagePngs("debug", images);
                    discard shoot({ background = ThemeDoc.rec(cand)#sky, texturePath = texPaths | cfg },
                        atlas, images, wc, stripJson(f))
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
