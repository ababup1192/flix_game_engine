// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う
// （同じ物を 3 か所で組み立てると、系の配線を 1 か所だけ直した時に実機と flow がずれる）。
// main だけが知る物（GPU のアトラス・デバッグの印）は Main で足す。
//
// 毎フレームの流れ: App が遊びの時計を進める（終了の確認の間は止まる = World.paceOf）
//   → Controls.step（暗転・歩き・文字送り → 入力 1 つ）→ View.frame / View.hud とタイル層が描く
//   → 前後の World の出来事の差から音（Controls.sounds）を鳴らし、場面とマップから曲（Controls.musicOf）を宣言する
//   （どちらも rpg.mixer.json のバスを通る = Controls.mixerOf）。
mod Game {
    use fge::{App, Log, Resources}

    /// save = 起動の時に読んだセーブ（実機だけ。flow とテストは None から始め、要れば Starts の title saved=yes）。
    pub def app(docs: Res.Docs, save: Option[Saves.SaveData]): App.App[Resources.With[Res.Res, World.World], {}] =
        let res = Res.build(docs);
        appOf(Log.warnAllThen(Res.problemsOf(res), res), save)

    /// 組み終えた描く元から App を組む（Drive が今の描く元のまま流す。Doc の問題は言わない — 言うのは読んだ時の app だけ）。
    pub def appOf(res: Res.Res, save: Option[Saves.SaveData]): App.App[Resources.With[Res.Res, World.World], {}] =
        App.game({
            init = Resources.of(res, World.initial(save)),
            update = Resources.system(Controls.step),
            view = Resources.view(View.frame),
            reloads = Nil
        })
            |> App.withHudView(Resources.view(View.hud))
            |> App.withDocTable(Controls.docTable())
            |> Resources.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w },
                                    paceOf = (_, w) -> World.paceOf(w) })
            // カメラは先頭を追い、マップの矩形の外を映さない（狭い軸は真ん中）。ドット絵なので 1 px に揃える。
            |> App.withCamera(Resources.read(View.cameraOf))
            |> App.withCameraBounds(Resources.read(View.boundsOf))
            |> App.withPixelSnap(_ -> 1.0)
            |> App.withTileLayers(Resources.read(View.tileLayers))
            |> App.withAudio(ws -> Controls.sounds({ before = ws#before#world, after = ws#after#world }))
            |> App.withSustained(Resources.read(Controls.musicOf))
            |> App.withMixer(Resources.read(Controls.mixerOf))
            // Esc とウィンドウの閉じるボタンは終了の確認へ（quitWhen を差し替えると既定の「Esc ですぐ終了」は外れる）。
            |> App.quitWhen((f, h) -> Resources.read((r, w) -> Controls.isQuit(f, r, w), h))
            |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.askQuit(w)))
            |> App.withStarts(Starts.all() |> List.map(Resources.liftStart))
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read((_, w) -> E2e.fingerprint(w)))
            |> App.withStatusLine(Resources.read((_, w) -> E2e.fingerprint(w)))
            |> App.onRenderRequest(SceneRender.allShots)
}
