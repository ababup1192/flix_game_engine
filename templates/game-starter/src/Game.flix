// Game — App の組み立て。実機の起動（Main）・flow の入口（E2e）・テストが同じ物を使う。
// Doc は App を組む前に読み、その値から描く元（Res）を作る（壊れていても defaults で必ず起動する）。
// App の w は描く元と遊びの状態（World）の組（Resources.With）で、系・絵・問いは Resources の口で両方を受ける。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
//   init    = 出発点の組（描く元 Res と初期の World）。
//   update  = 毎フレームの更新（入力 → 次の World）。1 本の合成関数で渡す決まり —
//             複数のシステムは `w |> step(f, res) |> …` と中で繋いでから渡す（繋ぎが Controls.step に見える）。
//   view    = (Res, World) → 「何をどこに描くか」。どちらも読むだけで変えない。
//   reloads = Nil（保存即反映・F1・表示中の名乗りは App.withDocTable が Doc の一覧表から配線する）。
// 場面（表紙・クリア等）が増えたら World.Screen の enum に case を足し、その場面だけの値を payload に持たせて
// step / frame を match で分ける（手本は templates/tidepool-starter）。Doc を足すなら Res に欄を足す（World には置かない）。
// 音も同じ形で足す: 起きた音 = App.withAudio + Emit.since（規則が出した出来事から鳴らす名前を導く）・
// 続く音 = App.withSustained・バスの音量やダッキング = App.withMixer + mixer.json
// （engine の docs/audio.md の「音の通り道」。実例は engine の templates/tidepool-starter/src/Controls.flix の sounds と ambience）。
// GPU やウィンドウにしか効かない口（アトラス・静的な層・終了の確認・注釈）は Main が後ろから足す。
mod Game {
    use fge::{App, Resources}

    pub def app(docs: Res.Docs): App.App[Resources.With[Res.Res, World.World], {}] =
        App.game({
            init = Resources.of(Res.build(docs), World.initial()),
            // 入力を読み World.step で次の状態へ。系は純粋（ファイルに書く物は App の口が実機でだけ書く）。
            update = Resources.system(Controls.step),
            view = Resources.view(View.frame),
            reloads = Nil
        })
            |> App.withDocTable(Controls.docTable())
            // 好きな場面から起動する・テストと flow が場面を名前で組む（START="at x=40 y=40" など）。
            |> App.withStarts(Starts.all() |> List.map(Resources.liftStart))
            // e2e/<名前>.flow の語彙（役・問い）と、記録の再生が比べる指紋。
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read(E2e.fingerprint))
            // 1 行の要点（flow の失敗・リモートの /step が最後の World として見せる）。
            |> App.withStatusLine(Resources.read(E2e.fingerprint))
            // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
            |> App.onRenderRequest(SceneRender.allShots)
}
