// エントリーポイント。Doc は App を組む前に読み、その値から初期 World を作る
// （壊れていても defaults で必ず起動する）。App の中でファイルを読むのは F1 の reloadOn と
// 保存検知（watchFile）だけ。外の世界に触れる処理（effect）は隠さず with で並べる。
//
// ゲーム 1 本の標準形は App.game の 1 レコードに宣言する — ここを読めばループの全体像
// （出発点 init・毎フレームの更新 update・描画 view・保存で読み直す Doc reloads）が掴める。
// update は「1 本の合成関数」: 複数のシステムを `w |> step |> interact |> …` と中で繋いで渡す
// （繋ぎが Main に見えるのが教育的）。App.game の外側で足す設定（reloadOn・onRenderRequest・withDebug）は
// 戻り値の App に従来どおり後ろから pipe で足す。

use flix_game_engine::{ActiveDocs, App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let docs = Controls.loadDocs();
            App.game({
                init = World.initial(docs),
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
                // 街タイル: World が作ったアトラスを GPU へ上げ（同じ key の間は何も起きない）、
                // タイル層として敷く。タイル層の zIndex は動的な絵と同じ z 空間で解釈される
                // （z=0 の床は DualGrid 地形の下に隠れる — 見比べのため既存の絵は残してある）。
                // 人と物（rpg_*.sprite.json）も同じ経路で 2 枚目のアトラスとして上げる。
                |> App.withSpriteAtlases(w ->
                    { texture = TownMap.textureName(), key = w#townAtlasKey,
                      baked = w#townAtlas } ::
                    { texture = World.charAtlasName(), key = w#charAtlasKey,
                      baked = w#charAtlas } :: Nil)
                // 宣言は World の持ち物を返すだけ — ここで TownMap.spec を呼ぶと
                // エンジンが毎フレーム評価して全盤走査が 1 フレーム予算を食い潰す。
                |> App.withTileLayers(w -> w#tileSpec :: Nil)
                // camera: 主人公を追い、盤の外の虚空は映さない。ドット絵なので 1px に吸着。
                // 画面固定の UI（空・霧・幕・戦いのウィンドウ）は hudView 側 — camera が掛からない。
                |> App.withCamera(w -> checked_ecast(World.cameraCenter(w)))
                |> App.withCameraBounds(w -> checked_ecast(World.boardRect(w)))
                |> App.withPixelSnap(_ -> 1.0)
                |> App.withHudView((ctx, w) -> checked_ecast(View.hud(ctx, w)))
                |> App.reloadOn(GameEngine.Key.F1, Controls.reloadAll)
                // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
                |> App.onRenderRequest(SceneRender.allShots)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
