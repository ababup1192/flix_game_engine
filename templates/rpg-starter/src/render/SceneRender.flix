// SceneRender — 場面を画面なしで PNG に描き出す。
// 実行: make render-all → gallery/<場面>.png
//       make render SHOT=village → debug/village.png（1 枚だけ）
mod SceneRender {
    use fge::{App, CameraRig, Clock, Color, Dir4, Emit, FontAtlas, HeadlessFont, HeadlessRender, PxSpriteAtlas, Render, Resources, TileScene, Vec2}

    import java.io.File

    def design(): Vec2.Vec2 = WindowView.design()

    /// 字のフォント（project.json の font と同じファイル）。
    pub def ttf(): String = "assets/PixelMplus10-Regular.ttf"

    /// 描き出しの設定。ドット絵なので面の縁も字の縁もならさない
    /// （WhyNot: 字をならすと PixelMplus の点が 3 倍の拡大でにじみ、色票の外の中間色が湧く）。
    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        { design = design(), scale = 3, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = outDir, frameW = 768, frameH = 720,
          shapeAntialias = false, textAntialias = false | HeadlessRender.defaults() }

    // ── 入口 ──

    pub def all(): Unit \ IO = App.Headless.exitWith(allJob(App.Headless.requestFromProcess()))

    /// SceneRender.all の中身（常駐の /run からも呼ぶ）。戻り値は終了コード。
    def allJob(_req: App.Headless.Request): Int32 \ IO =
        discard allShots();
        0

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("SceneRender", "one", req -> oneJob(req)) ::
        App.Headless.job("SceneRender", "all", req -> allJob(req)) :: Nil

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面を足したら、ここと sceneOf と Makefile の SHOTS を一緒に足す。
    def shotNames(): List[String] =
        "title" :: "village" :: "quest" :: "join" :: "world" :: "cave" :: "dungeon1" :: "dungeon2" :: "dungeon3" ::
        "battle" :: "magic" :: "item" :: "equip" :: "boss" :: "clear" :: Nil

    /// 描き出す時刻（秒）。WhyNot: 実時間を使わない — 点滅や水のゆれのコマが毎回変わり、
    /// 同じ PNG が出なくなる。0.25 秒はカーソルが見えていて、歩きが 1 コマ目の時刻。
    def shotTime(): Float64 = 0.25

    /// 名前 → Starts で組んで決まった手を進めた World（World から描ける場面だけ）。
    def worldOf(name: String, res: Res.Res): Option[World.World] =
        let at = w -> { realNow = Clock.after(shotTime(), Clock.zero()) | w };
        match name {
            case "title"   => started(res, "title", Map.empty()) |> Option.map(at)
            case "village" => started(res, "field", Map#{"map" => "village", "x" => "6", "y" => "11", "facing" => "up"}) |> Option.map(at)
            // 依頼の台詞を出し切り、送って はい / いいえ を出した所。
            case "quest"   => started(res, "talk", Map#{"node" => "ChiefQuest", "map" => "chief_house", "x" => "7", "y" => "5", "facing" => "up"})
                |> Option.map(confirmTimes(res, 2)) |> Option.map(at)
            // 依頼を受けた後に鍛冶屋の前でミナに話しかけ、ミナの台詞を送って「ミナが なかまに くわわった！」を出し切った所。
            case "join"    => started(res, "talk", Map#{"node" => "Mina", "map" => "smithy", "x" => "3", "y" => "6", "facing" => "up", "quest" => "accepted"})
                |> Option.map(confirmTimes(res, 3)) |> Option.map(at)
            // 村でメニューを開き、どうぐ（2 行目の右）を選んだ所。
            case "item"    => started(res, "field", Map#{"map" => "village", "x" => "7", "y" => "8", "facing" => "down", "party" => "luka,mina",
                                                       "quest" => "accepted", "gold" => "120", "items" => "yakusou:3,seisui:2,maryoku:1,taimatsu:2"})
                |> Option.map(openItems(res)) |> Option.map(at)
            // 村でメニューを開き、そうび → ルカ と進めて、ぶき / よろい の一覧とつよさのウィンドウを出した所。
            case "equip"   => started(res, "field", Map#{"map" => "village", "x" => "7", "y" => "8", "facing" => "down", "party" => "luka,mina,toto",
                                                       "quest" => "accepted", "gold" => "120", "items" => "dounotsurugi:1,kawanoyoroi:1,mahounorobe:1"})
                |> Option.map(openEquipSlots(res)) |> Option.map(at)
            // ワールドマップ: 3 人で橋の手前から北へ 2 マス歩き、橋の上に立った所（坑道の入口・川・ほこらが映る）。
            case "world"   => started(res, "field", Map#{"map" => "world", "x" => "20", "y" => "12", "facing" => "up", "party" => "luka,mina,toto", "quest" => "accepted"})
                |> Option.map(walk(res, Dir4.Dir4.Up, 2)) |> Option.map(at)
            // 森の岩穴: 入口の部屋から北へ 2 マス歩き、鉄格子（閉）と右の壁のレバー・奥のほりモグが映る所。
            case "cave"     => started(res, "field", Map#{"map" => "toto_cave", "x" => "8", "y" => "11", "facing" => "up", "party" => "luka,mina", "quest" => "accepted"})
                |> Option.map(walk(res, Dir4.Dir4.Up, 2)) |> Option.map(at)
            // 坑道 B1: 分岐の広間を東へ 2 マス歩き、トロッコの駅の前に立った所（壁のレバー・トロッコ・分かれ目・北と南へ分かれるレール・岩の部屋の入口が映る）。
            case "dungeon1" => started(res, "field", Map#{"map" => "mine_b1", "x" => "6", "y" => "16", "facing" => "right", "party" => "luka,mina,toto", "quest" => "accepted"})
                |> Option.map(walk(res, Dir4.Dir4.Right, 2)) |> Option.map(at)
            // 坑道 B2: 暗い迷路でたいまつを灯し、南へ 2 マス歩いた所（明かりの中だけ見え、先の割れた床が明かりの縁に入る）。
            case "dungeon2" => started(res, "field", Map#{"map" => "mine_b2", "x" => "19", "y" => "9", "facing" => "down", "party" => "luka,mina,toto", "quest" => "accepted", "light" => "60"})
                |> Option.map(walk(res, Dir4.Dir4.Down, 2)) |> Option.map(at)
            // 坑道 B3: 水晶を 3 つ点けて飛び石が現れた湖を、南の岸から北へ 2 マス渡った所（小島の宝箱・飛び石・点いた水晶が映る）。
            case "dungeon3" => started(res, "field", Map#{"map" => "mine_b3", "x" => "16", "y" => "21", "facing" => "up", "party" => "luka,mina,toto", "quest" => "accepted",
                                                          "flags" => "b3_crystals", "opened" => "b3_crystal_e,b3_crystal_w,b3_crystal_n"})
                |> Option.map(walk(res, Dir4.Dir4.Up, 2)) |> Option.map(at)
            // 坑道 B1 で 3 体と出会い、「あらわれた！」を送ってルカのコマンドを選ぶ所。
            case "battle"   => started(res, "battle", Map#{"foes" => "koke,koumori,goblin", "map" => "mine_b1", "x" => "4", "y" => "16", "facing" => "right",
                                                         "party" => "luka,mina,toto", "quest" => "accepted", "lv" => "3"})
                |> Option.map(confirmUntilChoose(res, 4)) |> Option.map(at)
            // 同じ組で、ルカとミナが たたかう・トトが じゅもん → ファイア → 先頭の敵 と選び、ファイアの演出の半ばまで進めた所。
            case "magic"    => started(res, "battle", Map#{"foes" => "koke,koumori,goblin", "map" => "mine_b1", "x" => "4", "y" => "16", "facing" => "right",
                                                         "party" => "luka,mina,toto", "quest" => "accepted", "lv" => "3"})
                |> Option.map(confirmUntilChoose(res, 4)) |> Option.map(castFire(res)) |> Option.map(at)
            case _         => None
        }

    /// ルカとミナは たたかう（先頭の敵）・トトは じゅもん の 1 つ目を先頭の敵へ。ファイアの演出の Beat まで伝言を送り、
    /// 演出の半ばまで遊びの時計を進めた所（音の出来事は捨てる）。
    def castFire(res: Res.Res, w: World.World): World.World =
        let chosen = fst(Emit.collect(() -> w |> WorldBattle.confirm(res) |> WorldBattle.confirm(res)
                                              |> WorldBattle.confirm(res) |> WorldBattle.confirm(res)
                                              |> WorldBattle.move(res, 1) |> WorldBattle.confirm(res) |> WorldBattle.confirm(res) |> WorldBattle.confirm(res)));
        let atSpell = untilSpellBeat(res, 12, chosen);
        let half = Float64.floor(RulesDoc.rec(res#rules)#fxSeconds * 0.3 * 60.0) |> Float64.tryToInt32 |> Option.getWithDefault(7);
        Drive.play(List.repeat(half, Set.empty()), Resources.of(res, atSpell))#world

    /// 呪文の演出のある Beat を見せている所まで伝言を送る（n 回まで）。
    def untilSpellBeat(res: Res.Res, n: Int32, w: World.World): World.World =
        let isSpell = World.battleRecOf(w) |> Option.flatMap(WorldBattle.currentBeatOf) |> Option.flatMap(pair -> Battle.beatRecOf(fst(pair))#fx)
            |> Option.exists(fx -> match fx#kind {
                case Battle.FxKind.Spell(_) => true
                case _                      => false
            });
        if (n <= 0 or isSpell) w
        else untilSpellBeat(res, n - 1, fst(Emit.collect(() -> WorldBattle.confirmMessage(res, w) |> WorldBattle.confirmMessage(res))))

    /// 戦いの伝言を決定で送り、コマンドを選ぶ番になった所（n 回まで。音の出来事は捨てる）。
    def confirmUntilChoose(res: Res.Res, n: Int32, w: World.World): World.World =
        if (n <= 0 or Option.nonEmpty(WorldBattle.choosingOf(w))) w
        else confirmUntilChoose(res, n - 1, fst(Emit.collect(() -> WorldBattle.confirmMessage(res, w))))

    /// dir へ n マス歩いた所（実機と同じ道でキーを流す。Drive.walkKeys）。
    def walk(res: Res.Res, dir: Dir4.Dir4, n: Int32, w: World.World): World.World =
        Drive.play(Drive.walkKeys(res, dir, n), Resources.of(res, w))#world

    /// メニューを開き、カーソルを下・右へ動かして どうぐ を選んだ所（音の出来事は捨てる）。
    def openItems(res: Res.Res, w: World.World): World.World =
        fst(Emit.collect(() -> WorldMenu.open(w) |> WorldMenu.move(res, Dir4.Dir4.Down) |> WorldMenu.move(res, Dir4.Dir4.Right)
                                                 |> WorldMenu.confirm(res)))

    /// メニューを開き、カーソルを下へ 2 つ動かして そうび → 先頭の仲間 を選んだ所（音の出来事は捨てる）。
    def openEquipSlots(res: Res.Res, w: World.World): World.World =
        fst(Emit.collect(() -> WorldMenu.open(w) |> WorldMenu.move(res, Dir4.Dir4.Down) |> WorldMenu.move(res, Dir4.Dir4.Down)
                                                 |> WorldMenu.confirm(res) |> WorldMenu.confirm(res)))

    /// 会話を決定で n 回送った所（音の出来事は捨てる）。
    def confirmTimes(res: Res.Res, n: Int32, w: World.World): World.World =
        if (n <= 0) w else confirmTimes(res, n - 1, fst(Emit.collect(() -> WorldTalk.confirm(res, w))))

    def started(res: Res.Res, name: String, args: Map[String, String]): Option[World.World] =
        Starts.all() |> List.find(s -> s#name == name)
            |> Option.flatMap(s -> s#build(res, World.initial(None), args) |> Result.toOption)

    /// 実機と同じ絵: タイル層・world（カメラを掛ける）・HUD。
    def worldItems(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let center = CameraRig.clampCenter(bounds = View.boundsOf(res, w), seen = design(), View.cameraOf(res, w));
        let seen = { visible = CameraRig.visibleRect(center, zoom = 1.0, design = design()) | ctx };
        let tiles = View.tileLayers(res, w) |> List.flatMap(TileScene.toItems);
        App.composeScene(Some(center), 1.0, design(),
            { world = List.append(tiles, View.frame(seen, res, w)), hud = View.hud(seen, res, w) })

    /// 名前 → その場面の描き物。shotNames と対で保つ。World から描ける場面は worldOf、残りは描き出し用に直に組む場面。
    def sceneOf(name: String, ctx: App.ViewCtx, env: WindowView.Env): Option[List[Render.PlacedItem]] =
        match worldOf(name, env#res) {
            case Some(w) => Some(worldItems(ctx, env#res, w))
            case None    => legacySceneOf(name, env)
        }

    def legacySceneOf(name: String, env: WindowView.Env): Option[List[Render.PlacedItem]] =
        match name {
            case "boss"     => Some(BattleScenes.bossFight(env))
            case "clear"    => Some(FieldScenes.clear(env))
            case _          => None
        }

    /// 全部の場面を gallery/ へ。描いた PNG のパス列を返す。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ描き出す。
    pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))

    def oneJob(req: App.Headless.Request): Int32 \ IO =
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

    /// keep が真を返す場面だけを outDir へ描き出し、そのパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let res = run { Res.load() } with Fs.FileRead.runWithIO;
        let ctx = App.viewCtxOf(atlas, design());
        let images = PxSpriteAtlas.asImages(Res.atlases(res));
        // WhyNot: アトラスの PNG を gallery/ に置かない — 描いた場面の顔ぶれに混ざり、reference-check が「増えた絵」と読む。
        let cfg = { texturePath = HeadlessRender.imagePngs("debug", images)
                    | cfgOf(outDir, atlas, Palette.resolve(res#palette, "ink")) };
        let texInfo = HeadlessRender.imageTextureInfo(images);
        let env = { res = res, font = atlas, t = shotTime() };
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, ctx, env) |> Option.map(items -> {
                let (drawables, polygons) = Render.drawWith(texInfo, items);
                HeadlessRender.renderPng(cfg, drawables, polygons, name);
                let path = "${outDir}/${name}.png";
                println("rendered: ${path}");
                path
            }))
}
