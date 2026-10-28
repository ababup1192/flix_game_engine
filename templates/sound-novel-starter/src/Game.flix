// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う。
// main だけが知る物（デバッグの印・セーブを書く出力・今の時刻）は Main で足す。
//
// 毎フレームの流れ: App が物語の時計を進める（画面や確認のウィンドウを開いている間は止まる = World.paceOf）
//   → Controls.step（待ち・文字送り・オート・スキップ = WorldRead.step）→ Controls.interact（入力）→ View.frame / View.hud が描く
//   → 前後の World の差から音（Controls.sounds）と、鳴り続ける環境音（Controls.ambience）を鳴らす。
mod Game {
    use fge::{App, Resources}

    /// res = 描く元（Doc とシナリオ）。clockBase = 起動した時のその土地の時刻（1970-01-01 からの秒。セーブの日時の元。テストと描き出しは決めた値）。
    /// App の w は描く元と遊びの状態の組（Resources.With）。系・絵・問いは Resources の口で両方を受ける。
    pub def app(res: Res.Res, saves: Saves.Saves, clockBase: Int64): App.App[Resources.With[Res.Res, World.World], {}] =
        App.game({
            init = Resources.of(res, World.initial(saves, clockBase)),
            update = Resources.system((f, r, w) -> Controls.interact(f, r, Controls.step(f, r, w))),
            view = Resources.view(View.frame),
            reloads = Nil
        })
            |> App.withDocTable(Controls.docTable())
            |> Resources.addClock({ clockOf = w -> w#storyClock, withClock = (c, w) -> { storyClock = c | w },
                                    paceOf = (_, w) -> World.paceOf(w) })
            |> App.quitWhen((f, h) -> Resources.read((_, w) -> Controls.isQuit(f, w), h))
            // ウィンドウの閉じるボタンもタイトルの「終了」と同じ確認のウィンドウを通す。
            |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.requestQuit(w)))
            // 設定の「画面」でウィンドウとフルスクリーンをその場で切り替える。
            |> App.withFullscreen(Resources.read((_, w) -> WorldSettings.isFullscreen(w)))
            // 文章・ウィンドウ・タイトル画面・クレジットは withHudView — 背景の z に隠されない。
            |> App.withHudView(Resources.view(View.hud))
            |> App.withAudio(ws -> Controls.sounds({ before = ws#before#world, after = ws#after#world }))
            |> App.withSustained(Resources.read(Controls.ambience))
            |> App.withMixer(Resources.read(Controls.mixerOf))
            |> App.withStarts(Starts.all() |> List.map(Resources.liftStart))
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read(E2e.fingerprint))
            |> App.withStatusLine(Resources.read((r, w) -> "phase=${World.sceneName(w)} panel=${World.panelName(w)} talk=${World.talkNodeOf(w)} line=${World.talkLineOf(w)} mode=${World.stageOf(r, w)#mode} playback=${World.playbackOf(w)} ask=${World.askOf(w)}"))
            |> App.onRenderRequest(SceneRender.allShots)
            |> App.onShotRequest(Resources.read(SceneRender.shotOf))
}
