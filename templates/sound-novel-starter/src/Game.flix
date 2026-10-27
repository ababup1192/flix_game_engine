// Game — ゲーム 1 本の App の組み立て。実機（Main）・flow の入口（E2e）・テストが同じ App を使う。
// main だけが知る物（デバッグの印・セーブを書く出力・今の時刻）は Main で足す。
//
// 毎フレームの流れ: App が物語の時計を進める（画面や確認の窓を開いている間は止まる = World.paceOf）
//   → Controls.step（待ち・文字送り・オート・スキップ）→ Controls.interact（入力）→ View.frame / View.hud が描く
//   → 前後の World の差から音（Controls.sounds）と、鳴り続ける環境音（Controls.ambience）を鳴らす。
mod Game {
    use fge::{App}

    /// clockBase = 起動した時のその土地の時刻（1970-01-01 からの秒。セーブの日時の元。テストと描き出しは決めた値）。
    pub def app(docs: World.Docs, saves: Saves.Saves, clockBase: Int64): App.App[World.World, {}] =
        App.game({
            init = World.initial(docs, saves, clockBase),
            update = (f, w) -> Controls.interact(f, Controls.step(f, w)),
            view = (ctx, w) -> View.frame(ctx, w),
            reloads = Nil
        })
            |> App.withDocTable(Controls.docTable())
            |> App.addClock({ clockOf = w -> w#storyClock, withClock = (c, w) -> { storyClock = c | w },
                              paceOf = World.paceOf })
            |> App.quitWhen((f, w) -> Controls.isQuit(f, w))
            // 窓の閉じるボタンもタイトルの「終了」と同じ確認の窓を通す。
            |> App.withCloseRequest(World.requestQuit)
            // 設定の「画面」でウィンドウとフルスクリーンをその場で切り替える。
            |> App.withFullscreen(World.isFullscreen)
            // 文章・窓・タイトル画面・クレジットは withHudView — 背景の z に隠されない。
            |> App.withHudView((ctx, w) -> View.hud(ctx, w))
            |> App.withAudio(ws -> Controls.sounds(ws))
            |> App.withSustained(w -> Controls.ambience(w))
            |> App.withMixer(w -> Controls.mixerOf(w))
            |> App.withStarts(Starts.all())
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(E2e.fingerprint)
            |> App.withStatusLine(w -> "phase=${w#phase} panel=${w#panel} talk=${World.talkNodeOf(w)} line=${World.talkLineOf(w)} mode=${w#stage#mode} playback=${w#playback} ask=${w#ask}")
            |> App.onRenderRequest(SceneRender.allShots)
            |> App.onShotRequest(SceneRender.shotOf)
}
