// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う。
// main だけが知る物（デバッグの印・セーブを書く出力・今の時刻）は Main で足す。
//
// 毎フレームの流れ: App が物語の時計を進める（画面や確認のウィンドウを開いている間は止まる = World.paceOf）
//   → Controls.step（待ち・文字送り・オート・スキップ = WorldRead.step）→ Controls.interact（入力）→ View.frame / View.hud が描く
//   → 前後の World の差から音（Controls.sounds）と、鳴り続ける環境音（Controls.ambience）を鳴らす。
mod Game {
    use fge::{App, LoadProgress, Resources}

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
            |> App.withAudio(ws -> Controls.sounds(ws#after#resources#missing, { before = ws#before#world, after = ws#after#world }))
            |> App.withSustained(Resources.read(Controls.ambience))
            |> App.withMixer(Resources.read(Controls.mixerOf))
            |> App.withStarts(Starts.all())
            |> App.withShots(Resources.shotsOf(Shots.names(), Shots.worldOf))
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read(E2e.fingerprint))
            // WhyNot: 起動した時刻を World 全体の要約に入れない — Main だけが読む外の値で遊んだ記録に残らず、
            //   画面なしの再生（E2e）は 0 で組むので、決定性の門（make determinism）が毎回食い違う。
            //   セーブは置き換えない（遊ぶ間に書く進行の値）。起動の時に読むセーブも外の値なので、門は saves/ を外して流す。
            //   セーブの枠の日時は clockBase + realNow の秒なので、clockBase の分だけ引いて「起動からの秒」にそろえる
            //   （新しいノードの最初の行のオートセーブは門の台本でも書かれる）。
            |> App.withWorldSummaryMask(Resources.mapWorld((_, w) ->
                { clockBase = 0i64, saves = Saves.withSavedAtShifted(0i64 - w#clockBase, w#saves) | w }))
            |> App.withStatusLine(Resources.read((r, w) -> "phase=${World.sceneName(w)} panel=${World.panelName(w)} talk=${World.talkNodeOf(w)} line=${World.talkLineOf(w)} mode=${World.stageOf(r, w)#mode} playback=${World.playbackOf(w)} ask=${World.askOf(w)}"))

    /// ブラウザ版で後回しにした絵と音（project.json の web.deferred）が届くたびに Res の missing を書き替え、
    /// 届いた絵を登録する量（Controls.decodeBudget）を渡す。Main とブラウザの入口だけが足す
    /// （downloads = 読み込みの頭で LoadProgress.downloads() から受け取った物。デスクトップは missing がいつも空で何もしない）。
    // WhyNot: Game.app に入れない — テスト・flow・描き出しは全部届いた形（missing が空）で回し、偽の downloads はテストが渡す。
    pub def withAssetLoading(downloads: LoadProgress.AssetDownloads, app: App.App[Resources.With[Res.Res, World.World], {}]):
            App.App[Resources.With[Res.Res, World.World], {}] =
        app
            |> App.withDecodeBudget(Controls.decodeBudget)
            |> App.withMissingAssets({ downloads = downloads, missingOf = h -> h#resources#missing,
                                       withMissing = (missing, h) -> Resources.of(Res.withMissing(missing, h#resources), h#world) })
}
