// PostStack（後がけの値の束）が組む Pass の並びを GL と SoftRaster で突き合わせる場面。どれも B 段階（差の数だけを見る）。
// 1 枚目は HDR の 2D の絵に今の見え方（AcesNarkowicz・ブルーム・ビネット・FXAA）・2 枚目は 3D の場面に奥行きのぼかし（DepthBand）。
mod PostScenes {

    use fge::{Color, Decal3d, PostStack, Render, Scene3d, ShaderDoc, Vec2, Vec3}

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

    /// 部屋の SSAO の値（半径 0.8 m・mask は半分）。
    def roomAo(): PostStack.AmbientOcclusion = { radius = 0.8, intensity = 2.0 | PostStack.ambientOcclusion() }

    /// 部屋（Scenes.roomWorld）の SSAO の mask だけ（DebugView.AmbientOcclusion）。式の差を光の式と分けて見る。
    pub def ambientOcclusionMask3d(): Scenes.Scene =
        sceneOf("ambientOcclusionMask3d", Scenes.roomWorld(),
            PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(roomAo())) |> PostStack.withDebugView(PostStack.DebugView.AmbientOcclusion))

    /// 部屋の SSAO を掛けた仕上がり（環境の光に mask を掛ける）。
    pub def ambientOcclusion3d(): Scenes.Scene =
        sceneOf("ambientOcclusion3d", Scenes.roomWorld(), PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(roomAo())))

    /// SSAO と高さの霧（霧は SSAO の奥行きの Pass（ps_depth_far）を読む）。
    pub def ambientOcclusionFog3d(): Scenes.Scene =
        sceneOf("ambientOcclusionFog3d", Scenes.roomWorld(),
            PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(roomAo()))
                |> PostStack.withHeightFog(Some({ density = 0.06, baseHeight = -2.0, heightFalloff = 0.3 | PostStack.heightFog() })))

    /// SSAO と Physical の奥行きのぼかし（ぼかしも ps_depth_far を読む）。
    pub def ambientOcclusionFocus3d(): Scenes.Scene =
        sceneOf("ambientOcclusionFocus3d", Scenes.roomWorld(),
            PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(roomAo()))
                |> PostStack.withDepthOfField(Some(PostStack.DepthOfField.Physical({ focusDistance = 10.0, fStop = 1.4 }))))

    /// SSAO と DepthBand の奥行きのぼかしと高さの霧（ぼかしは帯の自分の絵・霧は ps_depth_far）。
    pub def ambientOcclusionBandFog3d(): Scenes.Scene =
        sceneOf("ambientOcclusionBandFog3d", Scenes.roomWorld(),
            PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(roomAo()))
                |> PostStack.withHeightFog(Some({ density = 0.06, baseHeight = -2.0, heightFalloff = 0.3 | PostStack.heightFog() }))
                |> PostStack.withDepthOfField(Some(PostStack.DepthOfField.DepthBand({ focusDistance = 11.0, range = 6.0, band = 0.2, soft = 0.4, blur = 0.01 }))))

    /// 部屋の隅・壁と床の境・箱の足元に貼った半透明のデカール（Decal3d）に SSAO を掛けた仕上がり。
    /// 板は奥行きの絵に入らないが、真下の面の mask の暗さを受ける（受けないと暗がりの上の板だけが明るく浮く）。
    pub def decalAmbientOcclusion3d(): Scenes.Scene =
        let room = Scenes.roomScene();
        let stain = Scene3d.material({ name = "parity:decal:stain", cycleRate = 0.0, bindings = Nil,
                                       out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(Color.rgb(0.55, 0.08, 0.06)), alpha = ShaderDoc.Field.Const(0.7) }) })
            |> Scene3d.withAlphaBlend(true);
        let v = Vec3.v3;
        let decals = { size = v(3.0, 3.0, 1.0) | Decal3d.decal(stain, v(-5.0, -2.0, 13.0), v(0.0, 1.0, 0.0)) }
            :: { size = v(4.0, 1.6, 1.0) | Decal3d.decal(stain, v(1.0, -1.6, 16.0), v(0.0, 0.0, -1.0)) }
            :: { size = v(2.4, 1.2, 1.0), angleCutoff = 89.0 | Decal3d.decal(stain, v(-6.0, -1.6, 9.0), v(1.0, 0.0, 0.0)) } :: Nil;
        let scene = { instances = room#instances ::: Decal3d.buildInstances(decals, room#instances) | room };
        sceneOf("decalAmbientOcclusion3d", Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil,
            PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(roomAo())))

    /// 3D の場面（太陽で照らした床と板）に、ピントの奥行きを中心とする帯の外をぼかす。奥行きの絵は PostStack が場面から作る。
    pub def postStackDepthBand(): Scenes.Scene =
        sceneOf("postStackDepthBand", Scenes.sunWorld(),
            PostStack.preset(PostStack.Preset.Neutral)
                |> PostStack.withDepthOfField(Some(PostStack.DepthOfField.DepthBand({ focusDistance = 11.0, range = 6.0, band = 0.2, soft = 0.4, blur = 0.01 }))))
}
