// View — 描く元と World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// ── 画面の層（奥から手前へ）──
// 3D の場面 1 枚（Render.scene3d）の中で、奥から手前へ次の物を重ね、ポストプロセスを掛ける。
// 受け持つ絵の下限の 5 性質（面に階調か質感 / 主役が背景から分離 / 層が分かれている / 時間が流れている / 形が物として読める）:
//   空と霞     … 背景の空の色と、奥ほど霞の色へ寄せる（TownLook の sky・fog）        → 層が分かれている（奥）
//   地図の外   … 低い地面と暗い森の板                                              → 層が分かれている（奥）
//   町の面     … 床・段・水路・建物・生垣（タイルの絵・頂点の AO・太陽の影）         → 面に階調か質感・形が物として読める
//   町の板     … 木・街灯・町の人（ドット絵の板・足元の楕円の影・太陽の影を落とす） → 形が物として読める（接地）
//   小物の板   … 広場の店・NPC・動物（コマが動く・風船が揺れる）                    → 時間が流れている
//   隊列       … 旅の 3 人（歩きと待機モーションのコマ・人形の影）                  → 主役が背景から分離・時間が流れている
//   ポストプロセス … 手前と奥のぼけ（ピントは先頭の足元）・周りを暗く・色の掛け目  → 主役が背景から分離・層が分かれている（手前）
// 終了の確認の窓は HUD（App.withHudView）に置く — ポストプロセスのぼけと周りの暗さを窓に掛けない。
mod View {
    use fge::{App, Color, PostStack, RawDraw, Render, Scene3d, SortingLayer, TextDraw, Vec2, ZStack}
    use ZOrder.Layer

    /// 描き物の大きさ（project.json の design と同じ 1280×720）。
    pub def size(): Vec2.Vec2 = { x = 1280.0, y = 720.0 }

    /// 終了の確認の窓に要る値（部品は World でなくこれを読む）。
    pub type alias Prompt = { asking = Bool, text = String }

    /// 描く元と World から終了の確認の窓に要る値を写す（文言は explore.json の quitPrompt）。
    pub def promptOf(res: Res.Res, w: World.World): Prompt = { asking = World.isAskingQuit(w), text = Res.exploreOf(res)#quitPrompt }

    /// 3D の場面（町・隊列・小物）。
    pub def frame(_ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        Render.scene3d(Vec2.zero(), sceneOf(res, World.partyOf(w), w#time)) :: Nil

    /// HUD（終了の確認の窓）。
    pub def hud(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        SortingLayer.compose(ctx, promptLayers(ctx, promptOf(res, w)))

    /// ポストプロセス（ピントは先頭の足元）。
    pub def postOf(res: Res.Res, w: World.World): PostStack.Stack =
        let focus = World.partyOf(w) |> Option.map(World.focusOf(res)) |> Option.getWithDefault(10.0);
        TownScene.postOf(res#docs#look, focus, res#quality#depthOfField)

    /// 1 コマの場面。party = 歩き回っている間の中身（無ければ町だけを立ち始めのカメラで）・time = 時刻（小物と待機モーションのコマ）。
    def sceneOf(res: Res.Res, party: Option[World.PartyRec], time: Float64): Scene3d.Scene3dCmd =
        let e = Res.exploreOf(res);
        let look = Res.lookOf(res);
        let m = Res.mapOf(res);
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        let eye = party |> Option.map(World.eyeOf(res)) |> Option.getWithDefault(startEye(res));
        let camera = TownCamera.cameraAt(res#lens, look#far, eye);
        let members = party |> Option.map(p -> e#party |> List.mapWithIndex((i, walker) -> {
            let ((x, y), d) = World.memberAt(res, p, i);
            let (strip, perDir, frameNo) =
                if (p#moving) (walker#strip, Walkers.walkFrames(), Walkers.walkFrameAt(p#walkClock, e#walkFrameSec))
                else (walker#idleStrip, Walkers.idleFrames(), Walkers.idleFrameAt(time, i, e#idleFrameSec, e#idlePhaseSec));
            let (cell, flip) = Walkers.cellOf(walker, d, perDir, frameNo);
            TownScene.walkerBoard(res#boards, strip, cell, flip, snap(x), snap(y), TownMap.groundZAt(m, x, y))
        }) |> List.filterMap(identity)) |> Option.getWithDefault(Nil);
        let decor = TownScene.decorBoards(res#boards, m, Res.decorOf(res#docs), time);
        let billboards = List.append(List.map(fst, members), List.map(fst, decor));
        let shadows = List.append(List.map(snd, members), List.filterMap(snd, decor));
        { time = time | TownScene.sceneOf(res#built, res#docs#look, res#quality#shadowMapSize, camera, size(), billboards, shadows) }

    /// 隊列の居ない画面の目の位置（立ち始めのマスを、引き 1 で見る）。
    def startEye(res: Res.Res): TownCamera.Eye =
        let e = Res.exploreOf(res);
        let (x, y) = TownMap.centerOf(Res.mapOf(res), e#startCol, e#startRow);
        { x = x, z = y - res#feetDepth, height = res#groundZ + res#eyeRise }

    // ── 終了の確認の窓（Layer.Prompt） ──

    /// 層ごとの木（絵と押せる物の当たり）。Controls.tapAt も同じ木から押した物を選ぶ。
    pub def promptLayers(ctx: App.ViewCtx, p: Prompt): List[(Layer, ZStack.Tree[Layer, World.Press])] =
        (Layer.Prompt, quitPrompt(ctx, p)) :: Nil

    /// 窓の地の色（夕暮れでない昼の町に合わせ、黒でなく青紫の暗い色）。
    def promptShade(): Color = Color.rgb(0.16, 0.18, 0.3)

    /// Esc か閉じるボタンで出る確認。町を薄く沈める幕・窓・文言（文言は explore.json の quitPrompt）。
    /// 窓の中を押すと QuitYes・外を押すと QuitNo（blocking が奥の当たりを塞ぐ）。
    def quitPrompt(ctx: App.ViewCtx, p: Prompt): ZStack.Tree[Layer, World.Press] =
        if (not p#asking) ZStack.leaf(Nil)
        else {
            let screen = size();
            let box = { x = screen#x * 0.6, y = 96.0 };
            let at = { x = (screen#x - box#x) / 2.0, y = (screen#y - box#y) / 2.0 };
            let window =
                { at = Vec2.zero(), item = RawDraw.box(screen, promptShade(), 0) |> Render.fade(0.45) }
                    :: { at = at, item = RawDraw.box(box, Color.darken(promptShade(), 0.2), 1) |> Render.rounded(10.0) }
                    :: TextDraw.centeredAt({ text = p#text, atlas = ctx#atlas, size = 30.0, color = Color.rgb(1.0, 0.94, 0.84), z = 2,
                                             center = { x = screen#x / 2.0, y = screen#y / 2.0 } })
                    :: Nil;
            ZStack.blocking(Some(World.Press.QuitNo),
                ZStack.of(ZStack.leaf(window) :: ZStack.hit(World.Press.QuitYes, { position = at, size = box }) :: Nil))
        }
}
