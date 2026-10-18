// エントリーポイント。Doc は App を組む前に読み、その値から初期 World を作る
// (壊れていても defaults で必ず起動する)。App の中でファイルに触るのは
// watchFile(保存即反映)と F1 の reloadOn だけ。
//
// ── ゲームループの全体像 ──
//   init    = 出発点の World(stage.json の 1 面目にプレイヤーを立たせる)。
//   update  = 毎フレーム(Controls.step: 入力 → World.step)。その前に App が遊びの時計を進める
//             (Controls.addPlayClock。ポーズで止まり、踏みつけのヒットストップで遅くなる)。
//   view    = World → 絵(View.frameLive。静的地形は withTileLayers の GPU 層)。
//   reloads = 保存で読み直す Doc(一覧表は Controls.docTable に 1 枚)。
// 空・遠山は addParallaxLayer の層(視差 0〜0.25)。withCamera がプレイヤーの
// 先読み位置(World.cameraFocus)を画面中央に映し、withCameraBounds が面の外の
// 虚空を映さないよう収める。
use fge::{App, GameEngine, LwjglLayer, PxSpriteDoc}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let motion = MotionDoc.load(MotionDoc.path());
            let keys = KeysDoc.load(KeysDoc.path());
            let rules = RulesDoc.load(RulesDoc.path());
            let enemyDoc = EnemyDoc.load(EnemyDoc.path());
            let stageDoc = StageDoc.load(StageDoc.path());
            let theme = Theme.load(Theme.path());
            let uiText = UiText.load(UiText.path());
            let pxDoc = PxSpriteDoc.load(World.spritePath());
            App.game({
                init = World.initial(motion, keys, rules, enemyDoc, stageDoc, theme, uiText, pxDoc),
                update = (f, w) -> checked_ecast(Controls.step(f, w)),
                view = (ctx, w) -> checked_ecast(View.frameLive(ctx, w)),
                reloads = Controls.reloads()
            })
                |> Controls.addPlayClock
                |> App.addParallaxLayer(0.0,  (_ctx, w) -> checked_ecast(View.backdrop(w)))
                |> App.addParallaxLayer(0.04, (ctx, w) -> checked_ecast(View.clouds(ctx, w)))
                |> App.addParallaxLayer(0.10, (ctx, w) -> checked_ecast(View.mountains(ctx, w)))
                |> App.addParallaxLayer(0.18, (ctx, w) -> checked_ecast(View.farHills(ctx, w)))
                |> App.addParallaxLayer(0.30, (ctx, w) -> checked_ecast(View.forest(ctx, w)))
                // ドット絵は 1 枚のアトラスにまとめて 1 コマ = 1 クアッドで描く。
                |> App.withSpriteAtlases(w ->
                    { texture = World.atlasName(), key = World.atlasKey(w),
                      baked = w#atlas } :: Nil)
                // 静的地形は GPU タイル層 ×2(背後壁・前景)。per-tile tint に洞窟の明度。
                |> App.withTileLayers(w -> TerrainLayers.specs(w))
                |> App.withHudView((ctx, w) -> checked_ecast(View.hud(ctx, w)))
                |> App.withCamera(w -> checked_ecast(World.cameraFocus(w)))
                |> App.withCameraBounds(w -> checked_ecast(World.worldRect(w)))
                |> App.withPixelSnap(_ -> 1.0)
                |> App.reloadOn(GameEngine.Key.F1, Controls.reloadAll)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
