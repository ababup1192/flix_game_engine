// エントリーポイント。App の組み立ては Game.app（ブラウザ・flow の入口 E2e・テストも同じ物を使う）。
// ここで足すのは main だけが知る物（終了の確認・注釈・デバッグの印・開発の道具の /render・環境変数のつまみ）。
// 描き方の重さは環境変数 SHADOW_MAP（影の地図の一辺・0 で影なし）・DOF（0 / 1）・POST（0 / 1）で差し替える。
use fge::{App, LwjglLayer}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else {
        let knobs = Launch.envKnobs();
        run {
            App.loadAndLaunch(() -> Launch.loadedApp(knobs))
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }

mod Launch {
    use fge::{App, LoadProgress, ProcessEnv, Resources}

    /// (環境変数の名前, つまみの鍵) の表（Knobs.envNames）でつまみの表にする。置いていない・空の環境変数は入れない。
    pub def envKnobs(): Knobs.Knobs \ IO =
        let env = ProcessEnv.snapshot();
        Knobs.envNames() |> List.foldLeft((acc, pair) -> match Map.get(fst(pair), env) {
            case Some(value) if value != "" => Map.insert(snd(pair), value, acc)
            case _                          => acc
        }, Map.empty())

    /// Doc と絵を読み、遊ぶ App にする（読めなければ止める: 起動時の必須入力）。
    // WhyNot: loadAndLaunch へ渡す lambda に本文を書かない — 読み込みが lambda の中へ畳まれ、JVM の 1 メソッドの上限を超える。
    pub def loadedApp(knobs: Knobs.Knobs): App.App[Resources.With[Res.Res, World.World], {}] \ IO + Fs.FileRead + LoadProgress =
        let decoder = LoadProgress.imageDecoder();
        let res = Res.loadOrBug(Images.readImageWith(decoder), TownScene.TextureNames.ProjectTextures, knobs, Res.loadDocsOrBug());
        Game.app(res)
            // 窓の閉じるボタンも Esc と同じ確認へ回し、はいを選んだら終わる（quitWhen を差し替えると既定の「Esc ですぐ終了」は外れる）。
            |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.askQuit(w)))
            |> App.quitWhen((_, h) -> Resources.read((_, w) -> World.isQuitting(w), h))
            // F8 で書き出す注釈チケットに、その瞬間の文脈と z の層の名前を添える（層の表は ZOrder）。
            |> App.withAnnotationContext(Resources.read((r, w) ->
                { facts = ("状態", E2e.fingerprint(r, w)) :: Nil,
                  layers = (Nil: List[ZOrder.Layer]), hudLayers = ZOrder.layers() }))
            |> App.withDebug(App.debugFromEnv())
            // WhyNot: Game.app で繋がない — Game.app はテスト・flow・ブラウザ版と共有するので、開発の道具（POST /render）を持たせない。
            |> App.onRenderRequest(SceneRender.allShots)
}
