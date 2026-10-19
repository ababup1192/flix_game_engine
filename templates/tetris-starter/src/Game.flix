// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う
// （同じ物を 3 か所で組み立てると、系や音の配線を 1 か所だけ直した時に実機と flow がずれる）。
// main だけが知る物（デバッグの印・ウィンドウ）は Main で足す。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
//   init    = 出発点の World（空の盤に最初のミノが涌いた状態）。
//   update  = 毎フレームの更新（Controls.step）。系は純粋（ファイルに書く物は App の出力が実機でだけ書く）。
//   view    = World → 「何をどこに描くか」（View.frame）。World は読むだけで変えない。
//   reloads = Nil（保存即反映・F1・表示中の名乗りは App.withDocTable が Doc の一覧表から配線する）。
mod Game {
    use fge::App

    pub def app(docs: World.Docs): App.App[World.World, {}] =
        App.game({
            init = World.initial(docs),
            update = (f, w) -> Controls.step(f, w),
            view = (ctx, w) -> View.frame(ctx, w),
            reloads = Nil
        })
            |> App.withDocTable(Controls.docTable())
            // 以下は App.game の外側の高度な入口（戻り値の App に後ろから pipe で足す）。
            // HUD（NEXT・スコア・幕）は withHudView — world 側の z に隠されない。
            |> App.withHudView((ctx, w) -> View.hud(ctx, w))
            // 音は規則が出した出来事（Controls.step が events に溜めた分）から導く。
            |> App.withAudio(ws -> Controls.sounds(ws))
            // 好きな場面から起動する・テストと flow が場面を名前で組む（START="stack gap=0" など）。
            |> App.withStarts(Starts.all())
            // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
            |> App.onRenderRequest(SceneRender.allShots)
}
