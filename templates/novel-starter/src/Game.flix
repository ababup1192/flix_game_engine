// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う
// （同じ物を 3 か所で組み立てると、系や音の配線を 1 か所だけ直した時に実機と flow がずれる）。
// main だけが知る物（デバッグの印・ウィンドウ）は Main で足す。
//
// ゲーム 1 本の標準形は App.game の 1 レコードに宣言する — ここを読めばループの全体像
// （出発点 init・毎フレームの更新 update・描画 view）が掴める。
// update は「1 本の合成関数」: 複数のシステムを中で繋いで渡す（繋ぎがここに見えるのが教育的）。
// 系は純粋（ファイルに書く物は App の出力が実機のフレームの後でだけ書く）。
//
// 時計: 物語の時計（World の storyClock）は App.addClock で宣言し、App が系より先に毎フレーム 1 回だけ進める
// （止めるかは World.paceOf — メニューの間は止まる）。実時間は App が frame#realNow で配り、Controls.step が World へ写す。
mod Game {
    use fge::{App, UiStore}

    pub def app(docs: World.Docs, ui: UiStore.UiWorld): App.App[World.World, {}] =
        App.game({
            init = World.initial(docs, ui),
            // 毎フレーム: 入力で状態を進め → 相互作用を解決する。
            update = (f, w) -> Controls.interact(f, Controls.step(f, w)),
            view = (ctx, w) -> View.frame(ctx, w),
            // 保存即反映・F1 の一括読み直し・Studio への「表示中」の名乗りは、下の App.withDocTable が
            // Doc の一覧表 1 枚から配線する（ここでは足さない）。
            reloads = Nil
        })
            // 以下は App.game の外側の高度な入口（戻り値の App に後ろから pipe で足す）。
            |> App.withDocTable(Controls.docTable())
            |> App.addClock({ clockOf = w -> w#storyClock, withClock = (c, w) -> { storyClock = c | w },
                              paceOf = World.paceOf })
            // 終われるのは表紙だけ（物語の途中の Esc はメニュー。キーは novel.keys.json）。
            |> App.quitWhen((f, w) -> Controls.isQuit(f, w))
            // 会話窓・本文・エラーバナーは withHudView — world 側の z に隠されない。
            |> App.withHudView((ctx, w) -> View.hud(ctx, w))
            // 音は返事（Controls.interact が events に溜めた出来事）と灯りの演出の時刻表から導く。
            |> App.withAudio(ws -> Controls.sounds(ws))
            // ドット絵を作った 1 枚を GPU へ上げる（View はこの名前で 1 コマ 1 クアッドを貼る）。
            // 鍵が同じ間は上げ直さないので、毎フレームの費用はゼロ。
            |> App.withSpriteAtlases(w ->
                { texture = World.atlasName(), key = w#atlasKey, baked = w#atlas } :: Nil)
            // 好きな場面から起動する・テストと flow が場面を名前で組む（START="choice node=clock" など）。
            |> App.withStarts(Starts.all())
            // e2e/<名前>.flow の語彙（役・問い・名前付きの操作）と、記録の再生が比べる指紋。
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(E2e.fingerprint)
            // 1 行の要点（flow の失敗・リモートの /step が最後の World として見せる）。
            |> App.withStatusLine(w -> "phase=${w#phase} talk=${World.talkNodeOf(w)} line=${World.talkLineOf(w)} choice=${NovelKit.isAsking(w#kit)} lamps=${World.lampsLit(w)}")
            // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
            |> App.onRenderRequest(SceneRender.allShots)
            // 渡した World を 1 枚に描く（リモートの view=shot・窓なしのゲーム E2e.serveHeadless。Studio の会話のプレビュー）。
            |> App.onShotRequest(SceneRender.shotOf)
}
