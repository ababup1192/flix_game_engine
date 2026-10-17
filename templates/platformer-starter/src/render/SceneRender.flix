// SceneRender — ゲーム画面を画面なしで PNG に描き出す(スナップショット比較用)。
// 実行: make render-all → gallery/*.png(title / hill / cave / tower)
//       make render SHOT=cave → debug/cave.png(1 枚だけ)
// 時刻 t は固定値 — 空・コイン・旗・動く床がこの t だけで決まるので、
// 何度描き出しても同じ PNG が出る(スナップショットのバイト比較が成り立つ)。
mod SceneRender {
    use flix_game_engine::{
        App, CameraRig, Color, FontAtlas, GameEngine, HeadlessFont, HeadlessRender, PxSpriteAtlas,
        PxSpriteDoc, Render, Vec2
    }

    import java.io.File
    import java.lang.System

    def design(): Vec2.Vec2 = View.design()

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def cfgOf(atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        // 面の縁はならさない — タイルもキャラも px.sprite.json のドット絵で、
        // px.palette.json の色だけで塗る画面。字は読めないと困るので既定のまま残す。
        { design = design(), scale = 2, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = "gallery", frameW = 1280, frameH = 720,
          shapeAntialias = false | HeadlessRender.defaults() }

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

    /// 実機が GPU へ上げているのと同じアトラス画素をファイルへ落とす
    /// (描き出しは PNG からしか絵を読めない)。
    def atlasImages(w: World.World): List[{ name = String, side = Int32,
                                            pixelAt = (Int32, Int32) -> Int32 }] =
        { name = World.atlasName(), side = w#atlas#side,
          pixelAt = (x, y) -> PxSpriteAtlas.pixelAt(w#atlas, x, y) } :: Nil

    def envOr(key: String, fallback: String): String \ IO =
        let value = System.getenv(key);
        if (Object.isNull(value)) fallback else value

    // コイン(spin_0 / spin_1)が表を向く時刻を選ぶ — 横向きのコマだと
    // 見本の絵でコインが棒に見える。floor(t*5) が偶数なら表。
    def renderTime(): Float64 = 3.2

    def withT(w: World.World): World.World = { t = renderTime() | w }

    pub def all(): Unit \ IO =
        discard allShots()

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    pub def shotNames(): List[String] =
        "title" :: "hill" :: "cave" :: "tower" :: Nil

    /// 名前 → (その場面の World, HUD を重ねるか)。shotNames と対で保つ。
    /// 名前で引く形にしてあるので、SHOT で 1 枚だけ描くときに残りの面は組まない。
    def sceneOf(name: String, w0: World.World): Option[(World.World, Bool)] =
        match name {
            // title は Studio のジャンルカードの顔(GET /genesis/title が読む)と、
            // HUD 経路のリグレッション検知を兼ねる — 丘を HUD ごと描き出す。
            // 「夕方の丘を走って跳ぶ」が 1 枚で伝わる場面を選んでいる。
            case "title" => Some((withT(w0), true))
            case "hill"  => Some((withT(w0), false))
            case "cave"  => Some((withT(World.loadStage(1, w0)), false))
            case "tower" => Some((withT(World.loadStage(2, w0)), false))
            case _       => None
        }

    /// SHOT で指した場面だけを debug/ へ描き出す(スナップショットを汚さない)。
    /// 実行: make render SHOT=cave — 洞窟のように 1 枚が重い面を見ながら直すとき、
    /// 4 枚まとめて描き出し直すのを待たずに済む。
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

    /// SceneRender.all の中身。走行中の POST /render(App.onRenderRequest)もこれを呼べる。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// keep が真を返す場面だけを outDir へ描き出し、そのファイルパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w0 = loadWorld();
        let images = atlasImages(w0);
        let cfg = { outDir = outDir,
                    texturePath = HeadlessRender.imagePngs("debug", images)
                    | cfgOf(atlas, Theme.resolve(w0#theme, "ink")) };
        let texInfo = HeadlessRender.imageTextureInfo(images);
        let ctx = App.viewCtxOf(atlas, design());
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            match sceneOf(name, w0) {
                case None => None
                case Some((w, hud)) =>
                    Some(shootWith(cfg, texInfo, atlas, w, name,
                        if (hud) View.hud(ctx, w) else Nil))
            })

    /// カメラを面の中へ収める(実機の App.withCameraBounds と同じ役)。
    /// 面が画面より小さい軸は中央に置く。
    def clampFocus(w: World.World, focus: Vec2.Vec2): Vec2.Vec2 =
        let r = World.worldRect(w);
        let clampAxis = (size, half, v) ->
            if (size <= half * 2.0) size / 2.0
            else CameraRig.clampAxis(half, size - half, v);
        { x = clampAxis(r#size#x, design()#x / 2.0, focus#x),
          y = clampAxis(r#size#y, design()#y / 2.0, focus#y) }

    /// カメラ中心 = World.cameraFocus。visible をその矩形にして View.frame(全動的)を呼び、
    /// ワールド座標の絵を画面座標へ平行移動する。視差レイヤは実機
    /// (CameraRig.parallaxCenter)と同じ式で「見かけのカメラ」を作って重ねる。
    /// extras は画面座標のまま最後へ重ねる(実機の withHudView と同じ)。
    def shootWith(cfg: HeadlessRender.RenderConfig, texInfo: String -> Option[GameEngine.TextureInfo],
                  atlas: FontAtlas, w: World.World, name: String,
                  extras: List[Render.PlacedItem]): String \ IO =
        let focus = clampFocus(w, World.cameraFocus(w));
        let topLeft = { x = focus#x - design()#x / 2.0, y = focus#y - design()#y / 2.0 };
        let ctx = { visible = { position = topLeft, size = design() }
                  | App.viewCtxOf(atlas, design()) };
        let layerOf = (factor, lview) -> {
            let lcenter = CameraRig.parallaxCenter(factor, focus, design = design());
            let ltl = Vec2.sub(lcenter, Vec2.mul(design(), 0.5));
            let lctx = { visible = { position = ltl, size = design() }
                       | App.viewCtxOf(atlas, design()) };
            lview(lctx, w) |> Render.movedAll({ x = -ltl#x, y = -ltl#y })
        };
        let layers = layerOf(0.0, (_lctx, lw) -> View.backdrop(lw))
            |> List.append(layerOf(0.04, View.clouds))
            |> List.append(layerOf(0.10, View.mountains))
            |> List.append(layerOf(0.18, View.farHills))
            |> List.append(layerOf(0.30, View.forest));
        let items = layers
            |> List.append(
                View.frame(ctx, w) |> Render.movedAll({ x = -topLeft#x, y = -topLeft#y }))
            |> List.append(extras);
        let (drawables, polygons) = Render.drawWith(texInfo, items);
        HeadlessRender.renderPng(cfg, drawables, polygons, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
