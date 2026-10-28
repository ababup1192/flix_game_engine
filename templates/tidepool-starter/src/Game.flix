// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う
// （同じ物を 3 か所で組み立てると、系の配線を 1 か所だけ直した時に実機と flow がずれる）。
// main だけが知る物（デバッグの印・ウィンドウ・GPU のアトラス・終了の確認）は Main で足す。
// App の w は描く元（Res）と遊びの状態（World）の組。系・絵・問いは Resources の口で両方を受ける。
mod Game {
    use fge::{App, Resources}

    pub def app(docs: Res.Docs): App.App[Resources.With[Res.Res, World.World], {}] =
        let res = Res.build(docs);
        App.game({
            init = Resources.of(res, World.initial()),
            update = Resources.system(Controls.step),
            view = Resources.view(View.frame),
            reloads = Nil
        })
            |> App.withDocTable(Controls.docTable())
            // 音: 一発の音は World が溜めた出来事から、波の環境音は鳴り続ける宣言で。大きさはミキサーのバス（tidepool.mixer.json）。
            |> App.withAudio(ws -> Controls.sounds({ before = ws#before#world, after = ws#after#world }))
            |> App.withSustained(Resources.read((_, w) -> Controls.ambience(w)))
            |> App.withMixer(Resources.read((r, _) -> r#mixer))
            // 好きな場面から起動する・テストと flow が場面を名前で組む（START="level n=2" など）。
            |> App.withStarts(Starts.all() |> List.map(Resources.liftStart))
            // e2e/<名前>.flow の語彙（役・問い）と、記録の再生が比べる指紋。
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read(E2e.fingerprint))
            // 1 行の要点（flow の失敗・リモートの /step が最後の World として見せる）。
            |> App.withStatusLine(Resources.read(E2e.fingerprint))
            // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
            |> App.onRenderRequest(SceneRender.allShots)
}
