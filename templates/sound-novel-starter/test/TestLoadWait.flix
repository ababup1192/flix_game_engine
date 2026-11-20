// ブラウザ版で engine が後回しの素材を待つ仕組みとのつなぎ: 本画面は届いていない絵も描く物の列に入れ（engine が見つけて待つ）、
// 押した所まで戻して待つ間はタイトルの選んだ行を光らせる。
mod TestLoadWait {

    use fge::{App, LoadProgress, Render}

    def ctx(): App.ViewCtx \ IO =
        App.viewCtxOf(SceneRender.cfgOf(SceneRender.design(), "debug", Map.empty())#fontAtlas, SceneRender.design())

    def wait(pressed: Bool): LoadProgress.LoadWait =
        { reason = LoadProgress.LoadWaitReason.Assets, names = "bg" :: Nil, waited = 0.2, progress = 0.0, pressed = pressed }

    def shownPhotoTexture(res: Res.Res, w: World.World): Option[String] =
        Stage.shownShot(res#backdrops, World.stageOf(res, w)) |> Option.flatMap(shot -> BackdropDoc.textureOf(shot#photo, res#backdrops))

    @Test
    def testFrameDrawsAnUnarrivedPhotoSoTheEngineCanWait(): Unit \ {Assert, Fs.FileRead, IO} =
        let res = TestKit.res();
        let c = ctx();
        let drawn = Shots.worldOf("nvl", res) |> Option.flatMap(w -> shownPhotoTexture(res, w) |> Option.map(texture ->
            Set.memberOf(texture, Render.assetNames(View.frame(c, Res.withMissing(Set#{texture}, res), w)))));
        Assert.assertEq(expected = Some(true), drawn)

    @Test
    def testTitleLightsTheChosenRowOnlyWhilePressWaiting(): Unit \ {Assert, Fs.FileRead, IO} =
        let res = TestKit.res();
        let c = ctx();
        let lit = Shots.worldOf("title", res) |> Option.map(w -> {
            let count = (lw: Option[LoadProgress.LoadWait]) -> List.length(View.hud(c, res, World.withLoadWait(lw, w)));
            (count(Some(wait(false))) == count(None), count(Some(wait(true))) > count(None))
        });
        Assert.assertEq(expected = Some((true, true)), lit)
}
