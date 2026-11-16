// GameBoot — 起動の時にゲームが App と描く元へ足す物。
//   app          どの入口（実機・ブラウザ・flow・描き出し・テスト）でも通る（Game.app の最後）。ドットのアトラス（App.withSpriteAtlases）・
//                GameView が名前で引く字の本（App.withFonts("gothic" :: Nil)。名前は project.json の fonts[].name）など
//   loadAssets   実機・ブラウザ・描き出しが通る。後から届く素材（glb と絵）を、今届いている分だけ読んで Res#game に置き、読み残しを待ちの表に載せる
//                （BackgroundLoad.start。絵は LoadProgress.imageDecoder() で解く。描き出しでは全部届いている）
//   withLoading  実機とブラウザだけが通る。loadAssets の読み残しを毎コマ解く口（App.withBackgroundLoad）を足す
// テストと flow（E2e）は loadAssets と withLoading を通らない（3D の素材は無い形で回る。GameView.backdrop は None で写真に落ちる）。
mod GameBoot {
    use fge::{App, ImageData, LoadProgress, Resources}

    /// どの入口でも App に足す物。
    pub def app(a: App.App[Resources.With[Res.Res, World.World], {}]): App.App[Resources.With[Res.Res, World.World], {}] = a

    /// 後から届く素材を読み始めたゲームの描く元。素材を読むゲームは効果に \ {IO, LoadProgress, Fs.FileRead} を足す（呼ぶ所はどれも持っている）。
    pub def loadAssets(game: GameRes.Data): GameRes.Data = game

    /// loadAssets の読み残しを毎コマ解く口。downloads = LoadProgress.downloads()・decoder = LoadProgress.imageDecoder()。
    pub def withLoading(_loads: { downloads = LoadProgress.AssetDownloads, decoder = ImageData.ImageDecoder },
                        a: App.App[Resources.With[Res.Res, World.World], {}]): App.App[Resources.With[Res.Res, World.World], {}] = a
}
