// エントリーポイント。Doc と ui.json は App を組む前に読み、その値から初期 World を作る
// （壊れていても defaults で必ず起動する）。App の中でファイルを読むのは F1 の reloadOn と
// 保存検知（watchFile）だけ。外の世界に触れる処理（effect）は隠さず with で並べる。
//
// ゲーム 1 本の標準形は App.game の 1 レコードに宣言する — ここを読めばループの全体像
// （出発点 init・毎フレームの更新 update・描画 view・保存で読み直す Doc reloads）が掴める。
// update は「1 本の合成関数」: 複数のシステムを `w |> step |> interact |> …` と中で繋いで渡す
// （繋ぎが Main に見えるのが教育的）。App.game の外側で足す設定（reloadOn・onRenderRequest・withDebug）は
// 戻り値の App に従来どおり後ろから pipe で足す。

use fge::{ActiveDocs, App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let ui = NovelKit.spawnAssets();
            let docs = Controls.loadDocs();
            App.game({
                init = World.initial(docs, ui),
                // 毎フレーム: 入力で状態を進め → 相互作用を解決し → 表示中の Doc を名乗る。
                // ActiveDocs.step だけ Fs.FileWrite を使うので、純粋な部品は checked_ecast で
                // 同じ効果行へそろえる（部品側の ef は {} のまま保つ）。ActiveDocs は debug/active-docs.json に
                // 「表示中」を書くだけ（Studio のバッジ用・一覧が変わった瞬間だけ書くので無駄な IO は走らない）。
                update = (f, w) ->
                    checked_ecast(Controls.step(f, w))
                        |> (w1 -> checked_ecast(Controls.interact(f, w1)))
                        |> (w2 -> ActiveDocs.step(Controls.activeDocs(w2), w2)),
                view = (ctx, w) -> checked_ecast(View.frame(ctx, w)),
                // 保存即反映で読み直す Doc たち（各 1 本の watchFile に展開される）。
                reloads = Controls.reloads()
            })
                // 以下は App.game の外側の高度な口（戻り値の App に後ろから pipe で足す）。
                // 会話窓・本文・エラーバナーは withHudView — world 側の z に隠されない。
                |> App.withHudView((ctx, w) -> checked_ecast(View.hud(ctx, w)))
                // 音は返事（after#events）と灯りの演出の時刻表から導く。
                |> App.withAudio(ws -> checked_ecast(Controls.sounds(ws)))
                // ドット絵を作った 1 枚を GPU へ上げる（View はこの名前で 1 コマ 1 クアッドを貼る）。
                // 鍵が同じ間は上げ直さないので、毎フレームの費用はゼロ。
                |> App.withSpriteAtlases(w ->
                    { texture = World.atlasName(), key = w#atlasKey, baked = w#atlas } :: Nil)
                |> App.reloadOn(GameEngine.Key.F1, Controls.reloadAll)
                // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
                |> App.onRenderRequest(SceneRender.allShots)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
