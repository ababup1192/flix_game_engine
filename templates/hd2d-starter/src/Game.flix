// Game — App の組み立て。実機の起動（Main）・ブラウザ（web/WebMain）・flow の入口（E2e）・テストが同じ物を使う。
// 描く元（Res: Doc と組んだ町）は App を組む前に作る。App の w は描く元と遊びの状態（World）の組（Resources.With）。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
//   init    = 出発点の組（描く元 Res と初期の World）。
//   update  = 毎フレームの更新（入力 → 次の World。Controls.step）。
//   view    = (Res, World) → 3D の場面 1 枚（View.frame）。HUD（終了の確認の窓）は withHudView。
//   reloads = Nil（保存即反映・F1・表示中の名乗りは App.withDocTable が Doc の一覧表から配線する）。
// 音を足すなら: 起きた音 = App.withAudio・続く音（BGM）= App.withSustained・音量 = App.withMixer（engine の docs/audio.md）。
mod Game {
    use fge::{App, Resources}

    pub def app(res: Res.Res): App.App[Resources.With[Res.Res, World.World], {}] =
        let base = App.game({
            init = Resources.of(res, World.initial(res)),
            update = Resources.system(Controls.step),
            view = Resources.view(View.frame),
            reloads = Nil
        })
            |> App.withHudView(Resources.view(View.hud))
            |> App.withDocTable(Controls.docTable())
            // 好きな場面から起動する・テストと flow が場面を名前で組む（START="at col=13 row=47" など）。
            |> App.withStarts(Starts.all() |> List.map(Resources.liftStart))
            // ギャラリーの場面を実機でも開く（START=shot:title。描き出しと同じ World から始まる）。
            |> App.withShots(Resources.shotsOf(Shots.names(), Shots.worldOf))
            // e2e/<名前>.flow の語彙（役・問い）と、記録の再生が比べる指紋。
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read(E2e.fingerprint))
            |> App.withStatusLine(Resources.read(E2e.fingerprint));
        // WhyNot: post を毎コマ見て掛け外ししない — App.withPostStack は起動の時に繋ぐ口で、繋いだ後は外せない（explore.json の post は起動し直すと効く）。
        if (res#quality#post) base |> App.withPostStack(Resources.read(View.postOf)) else base
}
