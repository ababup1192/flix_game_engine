// PostStack（後がけの値の束）が組む Pass の並びを GL と SoftRaster で突き合わせる場面。どれも B 段階（差の数だけを見る）。
// 1 枚目は HDR の 2D の絵に今の見え方（AcesNarkowicz・ブルーム・ビネット・FXAA）・2 枚目は 3D の場面に奥行きのぼかし（DepthBand）。
mod PostScenes {

    use fge::{Color, PostStack, Render, Vec2}

    def size(): Vec2.Vec2 = { x = Scenes.designW(), y = Scenes.designH() }

    def sceneOf(name: String, world: List[Render.PlacedItem], s: PostStack.Stack): Scenes.Scene =
        let built = PostStack.build({ size = size(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, s);
        { name = name, via = Scenes.ShotVia.ViaScreen, repeats = 1, targets = built#plan#targets, exact = false,
          passes = built#plan#passes, items = built#present :: Nil }

    /// HDR の 2D の絵（1 を超える色の箱）に、今のゲームの手書きの後がけと同じ組（白の点 4・ブルーム・ビネット・FXAA）。
    pub def postStackLook(): Scenes.Scene =
        sceneOf("postStackLook", Scenes.hdrWorld(),
            PostStack.preset(PostStack.Preset.Neutral)
                |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.06 }))
                |> PostStack.withExposure(-0.3)
                |> PostStack.withBloom(Some({ threshold = 0.9, smoothness = 0.6, size = 0.04, strength = 0.8 }))
                |> PostStack.withVignette(Some({ strength = 0.35, inner = 0.35, outer = 1.05, center = { x = 0.5, y = 0.5 } }))
                |> PostStack.withFxaa(true))

    /// PS1 風の箱（Design の解像度・Bayer のディザ）に CRT のにじみ（横のぼかし 1.5 px・色だけのにじみ 2 px・走査線 0.3）。
    /// 窓が design と同じ大きさなので、走査線は行の真ん中だけを読んで効かない（形が組めて GL と CPU で同じ絵になるかを見る）。
    pub def postStackCrt(): Scenes.Scene =
        sceneOf("postStackCrt", Scenes.psxWorld(),
            PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withCrt(Some({ compositeBlur = 1.5, scanlines = 0.3, chromaBleed = 2.0 })))

    /// 3D の場面（太陽で照らした床と板）に、ピントの奥行きを中心とする帯の外をぼかす。奥行きの絵は PostStack が場面から作る。
    pub def postStackDepthBand(): Scenes.Scene =
        sceneOf("postStackDepthBand", Scenes.sunWorld(),
            PostStack.preset(PostStack.Preset.Neutral)
                |> PostStack.withDepthOfField(Some(PostStack.DepthOfField.DepthBand({ focusDistance = 11.0, range = 6.0, band = 0.2, soft = 0.4, blur = 0.01 }))))
}
