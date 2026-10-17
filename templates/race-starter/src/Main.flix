// エントリーポイント。Doc は App を組む前に読み、その値から初期 World を作る
// （壊れていても defaults で必ず起動する）。App の中でファイルを読むのは F1 の reloadOn と
// 保存検知（watchFile）だけ。外の世界に触れる処理（effect）は隠さず with で並べる。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
// ここを読めば「何から始まり・毎フレームどう進み・どう絵になり・保存で何を読み直すか」が掴める。
//   init    = 出発点の World（Title 画面）。
//   update  = 毎フレームの更新。1 本の合成関数で渡す決まり — 入力で状態を進め（Controls.step）、
//             そのあと表示中の Doc を名乗る（ActiveDocs.step）。繋ぎが Main に見えるのが教育的。
//   view    = World → 「何をどこに描くか」（View.frame）。World は読むだけで変えない。
//   reloads = 保存で読み直す Doc（各 1 本の watchFile に展開される）。
//
// 遊びの骨格はドリフトとニトロ: X で滑りながら曲がってゲージを貯め、満タンで Z の爆速。
// 曲がる・滑る・抜く・壊れる・周回する の規則そのものは World.flix にある。
// まず World 冒頭の「遊びの骨格（5 本柱）」と「場面の移り変わりの図」を読むとよい。
use fge::{ActiveDocs, App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let docs = Controls.loadDocs();
            App.game({
                init = World.initial(docs),
                // 入力を読み World.step で次の状態へ → 表示中の Doc を名乗る。
                // ActiveDocs.step だけ Fs.FileWrite を使うので、純粋な部品は checked_ecast で
                // 同じ効果行へそろえる（部品側の ef は {} のまま保つ）。
                update = (f, w) ->
                    checked_ecast(Controls.step(f, w))
                        |> (w1 -> ActiveDocs.step(Controls.activeDocs(w1), w1)),
                view = (ctx, w) -> checked_ecast(View.frame(ctx, w)),
                // 保存即反映で読み直す Doc たち（各 1 本の watchFile に展開される）。
                reloads = Controls.reloads()
            })
                // 以下は App.game の外側の高度な口（戻り値の App に後ろから pipe で足す）。
                // HUD（チップ・幕）は withHudView — world 側の z に隠されない。
                |> App.withHudView((ctx, w) -> checked_ecast(View.hud(ctx, w)))
                |> App.reloadOn(GameEngine.Key.F1, Controls.reloadAll)
                // ドット絵は 1 枚のアトラスに生成し、ヤシと残像を 1 コマ = 1 クアッドで描く。
                // 世代鍵（atlasKey）が変わったフレームに App が GPU へ上げ直す（テーマ・色票・
                // ドット絵の保存で World 側が生成し直す）。
                |> App.withSpriteAtlases(w ->
                    { texture = World.atlasName(), key = World.atlasKey(w),
                      baked = w#atlas } :: Nil)
                // 音: 1 フレームの前後の World から鳴らす音名を導く（再生は App が持つ）。
                |> App.withAudio(worlds -> checked_ecast(Sounds.eventNames(worlds)))
                // 鳴り続ける音: 走っている間のエンジンの唸りと、滑っている間の擦れ。
                // 宣言が消えたフレームで App が止めるので、ここは「今どう鳴っていてほしいか」だけ書く。
                |> App.withSustained(w -> checked_ecast(Sounds.sustains(w)))
                // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
                |> App.onRenderRequest(SceneRender.allShots)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
