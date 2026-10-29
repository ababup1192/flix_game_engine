// View — World から絵への入口（純粋）: world と HUD の絵・カメラ・タイル層。場面ごとの In は
// ViewField（フィールド）・ViewMenu（メニューと店のウィンドウ）・ViewBattle（戦い）が組み、場面の部品（TitleView・FieldScreen・
// BattleView）はその In を受ける。World を受けるのはこの入口と、In を組む ViewField.fieldIn・ViewBattle.battleIn だけ。
// 画風の層（奥から）:
//   world（カメラで動く）: 地面（タイル層 + 水と岸）→ 家の影 → 重ねる物（木・柵・床の敷物）→ 人と小物（足元の y の順）
//   HUD（動かない）     : メニュー・店・会話・選択肢・タイトルのメニュー → 暗転 → 終了の確認
// 層の名前と z の範囲は ZOrder。
mod View {
    use fge::{App, Clock, Rect2, Render, SortingLayer, TileLayerSpec, Vec2}
    use ZOrder.HudLayer

    /// ウィンドウと部品を描く元。t = 実時間の秒（点滅と足踏みのコマ）。
    def envOf(ctx: App.ViewCtx, res: Res.Res, t: Float64): WindowView.Env = { res = res, font = ctx#atlas, t = t }

    /// world の絵（App の view）。
    pub def frame(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let env = envOf(ctx, res, World.realSeconds(w));
        let layers = match w#scene {
            case World.Scene.Title(_) => TitleView.world(env)
            case World.Scene.Field(_) => ViewField.fieldIn(res, w) |> Option.map(FieldScreen.world(ctx, env)) |> Option.getWithDefault(Nil)
            case World.Scene.Battle(_) => ViewBattle.battleIn(env, w) |> Option.map(BattleView.world(env)) |> Option.getWithDefault(Nil)
            case World.Scene.Ending(_) => ViewField.fieldIn(res, w) |> Option.map(FieldScreen.world(ctx, env)) |> Option.getWithDefault(Nil)
        };
        SortingLayer.compose(ctx, layers)

    /// HUD の絵（App.withHudView）。
    pub def hud(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let env = envOf(ctx, res, World.realSeconds(w));
        let scene = match w#scene {
            case World.Scene.Title(item) => TitleView.hud(env, titleIn(res, item, Option.nonEmpty(w#save)))
            case World.Scene.Field(_)    => ViewField.fieldIn(res, w) |> Option.map(FieldScreen.hud(env, WindowView.design())) |> Option.getWithDefault(Nil)
            case World.Scene.Battle(_)   => ViewBattle.battleIn(env, w) |> Option.map(BattleView.hud(env)) |> Option.getWithDefault(Nil)
            case World.Scene.Ending(_)   => endingIn(res, w) |> Option.map(EndingView.hud(env, WindowView.design())) |> Option.getWithDefault(Nil)
        };
        let prompt = w#ask |> Option.map(ask -> (HudLayer.Prompt, PromptView.quit(env, res#text, World.answerOf(ask))) :: Nil) |> Option.getWithDefault(Nil);
        SortingLayer.compose(ctx, List.append(scene, prompt))

    /// saved = セーブがあるか（「つづきから」を選べるか）。
    def titleIn(res: Res.Res, item: World.TitleItem, saved: Bool): TitleView.In =
        let items = WorldTitle.items();
        { entries = items |> List.map(it -> (TextDoc.menuText(menuTextOf(it), res#text), WorldTitle.isOpen(it, saved))),
          selected = List.indexOf(item, items) |> Option.getWithDefault(0),
          credit = TextDoc.menuText(TextDoc.MenuText.Credit, res#text) }

    /// エンディングの In: スタッフの字（{lv} = 先頭の Lv・{gold} = 手持ちのお金）と、流れた割合・晴らす進み具合（遊びの時計）。
    def endingIn(res: Res.Res, w: World.World): Option[EndingView.In] =
        World.endingRecOf(w) |> Option.map(e -> {
            let since = Clock.since(e#startedAt, World.now(w));
            let rules = RulesDoc.rec(res#rules);
            let lv = Party.statsList(w#party) |> List.head |> Option.map(row -> snd(row)#lv) |> Option.getWithDefault(1);
            { lines = TextDoc.creditLines((TextDoc.Placeholder.Lv, "${lv}") :: (TextDoc.Placeholder.Gold, "${Bag.goldOf(w#bag)}") :: Nil, res#text),
              scrolled = WorldTitle.creditProgressOf(res, w),
              theEnd = TextDoc.menuText(TextDoc.MenuText.TheEnd, res#text),
              fadeIn = if (rules#fadeSeconds <= 0.0) 1.0 else since / rules#fadeSeconds }
        })

    def menuTextOf(item: World.TitleItem): TextDoc.MenuText = match item {
        case World.TitleItem.NewGame  => TextDoc.MenuText.NewGame
        case World.TitleItem.Continue => TextDoc.MenuText.Continue
    }

    // ── カメラとタイル層 ──

    /// カメラの中心: フィールド（とエンディングの下敷き）は先頭の真ん中、タイトルと戦いは画面の真ん中。
    pub def cameraOf(res: Res.Res, w: World.World): Vec2.Vec2 =
        let half = Autotile.tile() / 2.0;
        World.shownFieldOf(w)
            |> Option.map(r -> { let p = ViewField.heroPx(res, World.now(w), r); ({ x = p#x + half, y = p#y + half }: Vec2.Vec2) })
            |> Option.getWithDefault({ x = WindowView.design()#x / 2.0, y = WindowView.design()#y / 2.0 })

    /// カメラが映してよい矩形: フィールド（とエンディングの下敷き）はマップの矩形、タイトルと戦いは画面。
    pub def boundsOf(res: Res.Res, w: World.World): Rect2.Rect2 =
        World.shownFieldOf(w) |> Option.flatMap(r -> MapDoc.docOf(res#maps, r#map))
            |> Option.map(map -> {
                let m = MapDoc.rec(map);
                ({ position = { x = 0.0, y = 0.0 },
                   size = { x = Int32.toFloat64(m#cols) * Autotile.tile(), y = Int32.toFloat64(m#height) * Autotile.tile() } }: Rect2.Rect2)
            })
            |> Option.getWithDefault({ position = { x = 0.0, y = 0.0 }, size = WindowView.design() })

    /// いるマップの地面のタイル層（App.withTileLayers）。鍵はマップとアトラスの鍵なので、作り直しはマップを移った時と絵を読み直した時だけ。
    pub def tileLayers(res: Res.Res, w: World.World): List[TileLayerSpec] =
        World.shownFieldOf(w)
            |> Option.flatMap(r -> Map.get(MapDoc.nameOf(r#map), res#arts) |> Option.map(art -> (MapDoc.nameOf(r#map), art)))
            |> Option.map(match (name, art) -> MapArt.rec(art)#layers |> List.filterMap(layerSpec(res, name)))
            |> Option.getWithDefault(Nil)

    def layerSpec(res: Res.Res, mapName: String, layer: MapArt.Layer): Option[TileLayerSpec] =
        Map.get(layer#sheet, res#sheets) |> Option.map(sheet -> {
            let side = Int32.toFloat64(sheet#baked#side);
            let z = if (layer#depth == 0) SortingLayer.bottom(ZOrder.Layer.Ground) else SortingLayer.bottom(ZOrder.Layer.Over);
            { key = "${mapName}:${layer#depth}:${sheet#key}",
              tileSet = { atlasSource = { textureName = sheet#texture, texWidth = side, texHeight = side, tileSize = Autotile.tile(),
                                          marginX = 0.0, marginY = 0.0, spacingX = 0.0, spacingY = 0.0 } },
              tiles = _ -> layer#tiles, origin = { x = 0.0, y = 0.0 }, zIndex = z }
        })
}
