// エントリーポイント。Doc は App を組む前に読み、その値から初期 World を作る
// （壊れていても defaults で必ず起動する）。App の中でファイルを読むのは F1 の reloadOn と
// 保存検知（watchFile）だけ。外の世界に触れる処理（effect）は隠さず with で並べる。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
// ここを読めば「何から始まり・毎フレームどう進み・どう絵になり・保存で何を読み直すか」が掴める。
//   init    = 出発点の World（空の盤に最初のミノが涌いた状態）。
//   update  = 毎フレームの更新。1 本の合成関数で渡す決まり — 入力で状態を進め（Controls.step）、
//             系は純粋（表示中の Doc の名乗りは App.withDocTable が実機のフレームの後でだけ書く）。
//   view    = World → 「何をどこに描くか」（View.frame）。World は読むだけで変えない。
//   reloads = Nil（保存即反映・F1・表示中の名乗りは App.withDocTable が Doc の一覧表から配線する）。
//
// 落下・移動・回転・接地/固定・ライン消去・涌き の規則そのものは World.flix にある。
// まず World 冒頭の「毎フレームの流れ」と「場面の移り変わりの図」を読むとよい。
use fge::{App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let docs = Controls.loadDocs();
            App.game({
                init = World.initial(docs),
                // 入力を読み World.step で次の状態へ（系は純粋）。
                update = (f, w) -> checked_ecast(Controls.step(f, w)),
                view = (ctx, w) -> checked_ecast(View.frame(ctx, w)),
                // 保存即反映・F1 の一括読み直し・Studio への「表示中」の名乗りは、下の App.withDocTable が
                // Doc の一覧表 1 枚から配線する（ここでは足さない）。
                reloads = Nil
            })
                |> App.withDocTable(Controls.docTable())
                // 以下は App.game の外側の高度な口（戻り値の App に後ろから pipe で足す）。
                // HUD（NEXT・スコア・幕）は withHudView — world 側の z に隠されない。
                |> App.withHudView((ctx, w) -> checked_ecast(View.hud(ctx, w)))
                // 音は規則が出した出来事（Controls.step が events に溜めた分）から導く。
                |> App.withAudio(ws -> checked_ecast(Controls.sounds(ws)))
                // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
                |> App.onRenderRequest(SceneRender.allShots)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
