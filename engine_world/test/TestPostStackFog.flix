// PostStack の高さの霧（HeightFog）を具体値で固定する: 使わない時の計画・Pass の並びと奥行きの絵の大きさ・
// CPU で描いた霧の濃さ（下向きほど濃い・遠いほど濃い・式の値・上限）・灯りのにじみ・むら・post.json。
// 場面は目の高さ 2・+z を水平に見るカメラ（far 100）。場面の色の絵と奥行きの絵は一様な絵を ShaderEval に渡す。
mod TestPostStackFog {

    use ShaderEval.TexImage

    def size(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(0.0, 2.0, 10.0), yaw = 0.0, pitch = 0.0, fovY = 0.8, near = 0.1, far = 100.0 }

    def sceneWith(lights: List[Scene3d.PointLight]): Render.PlacedItem =
        Render.scene3d(Vec2.zero(), { pointLights = lights | Scene3d.scene(camera(), size()) })

    def neutral(): PostStack.Stack = PostStack.preset(PostStack.Preset.Neutral)

    def white(): Color = Color.rgb(1.0, 1.0, 1.0)

    def fog(): PostStack.HeightFog =
        { color = white(), density = 0.05, baseHeight = 0.0, heightFalloff = 0.3, startDistance = 0.0, maxOpacity = 1.0, noise = None, lightGlow = 0.0 }

    def built(world: List[Render.PlacedItem], s: PostStack.Stack): { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[PostStack.Issue] } =
        PostStack.build({ size = size(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, s)

    def passNames(s: PostStack.Stack): List[String] = built(sceneWith(Nil) :: Nil, s)#plan#passes |> List.map(p -> p#name)

    def at(seconds: Float64): Clock.Time[Clock.Real] = Clock.after(seconds, Clock.zero())

    /// 計画と画面の面を字にした物。
    def planText(b: { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[PostStack.Issue] }): String =
        let itemText = (i: Render.PlacedItem) -> match i#item {
            case Render.Item.Shader(sh) => "${ShaderJson.toJson(sh#spec)} ${sh#params} ${sh#t}"
            case _                      => "${i#at#x},${i#at#y}"
        };
        let passes = b#plan#passes |> List.map(p -> {
            let d = Render.targetDescriptorOf(b#plan, p#name);
            "${p#name} ${d#format} ${d#scale} ${d#samples} ${List.length(p#items)}"
        });
        "${passes} ${itemText(b#present)}"

    // ── 計画 ──

    @Test
    def testNoneFogKeepsThePlan(): Unit \ Assert =
        let s = PostStack.preset(PostStack.Preset.DuskOutdoor);
        Assert.assertEq(expected = planText(built(sceneWith(Nil) :: Nil, s)), planText(built(sceneWith(Nil) :: Nil, s |> PostStack.withHeightFog(None))))

    @Test
    def testZeroDensityDrawsNoFogPass(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: Nil, passNames(neutral() |> PostStack.withHeightFog(Some({ density = 0.0 | fog() }))))

    @Test
    def testFogAddsDepthAndFogPasses(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: "ps_depth" :: "ps_fog" :: Nil, passNames(neutral() |> PostStack.withHeightFog(Some(fog()))))

    @Test
    def testFogDrawsTheDepthAtWindowPixels(): Unit \ Assert =
        let b = built(sceneWith(Nil) :: Nil, neutral() |> PostStack.withHeightFog(Some(fog())));
        Assert.assertEq(expected = 1.0, Render.targetDescriptorOf(b#plan, "ps_depth")#scale)

    @Test
    def testFogBeforeDistortion(): Unit \ Assert =
        let d = { strength = { x = 2.0, y = 1.0 }, noiseSize = 24.0, speed = { x = 0.0, y = -20.0 }, mask = PostStack.DistortionMask.Full };
        Assert.assertEq(expected = "ps_scene" :: "ps_depth" :: "ps_fog" :: "ps_distort" :: Nil,
                        passNames(neutral() |> PostStack.withHeightFog(Some(fog())) |> PostStack.withDistortion(Some(d))))

    @Test
    def testDepthBandWithFogDrawsItsOwnFogDepth(): Unit \ Assert =
        let band = PostStack.DepthOfField.DepthBand({ focusDistance = 10.0, range = 4.0, band = 0.25, soft = 0.5, blur = 0.004 });
        let b = built(sceneWith(Nil) :: Nil, neutral() |> PostStack.withHeightFog(Some(fog())) |> PostStack.withDepthOfField(Some(band)));
        Assert.assertEq(expected = (true, 0.5, 1.0),
                        (List.exists(p -> p#name == "ps_fogdepth", b#plan#passes),
                         Render.targetDescriptorOf(b#plan, "ps_depth")#scale, Render.targetDescriptorOf(b#plan, "ps_fogdepth")#scale))

    @Test
    def testFogWithoutSceneIsReported(): Unit \ Assert =
        Assert.assertEq(expected = PostStack.Issue.NoScene3d :: Nil, built(Nil, neutral() |> PostStack.withHeightFog(Some(fog())))#issues)

    @Test
    def testMovingTheCameraKeepsTheSameSpec(): Unit \ Assert =
        let specAt = (eye: Vec3.Vec3) -> {
            let item = Render.scene3d(Vec2.zero(), Scene3d.scene({ eye = eye | camera() }, size()));
            fogItem(item :: Nil, neutral() |> PostStack.withHeightFog(Some(fog())))
                |> Option.flatMap(i -> match i#item {
                    case Render.Item.Shader(sh) => Some("${ShaderJson.toJson(sh#spec)}")
                    case _                      => None
                })
        };
        Assert.assertEq(expected = specAt(Vec3.v3(0.0, 2.0, 10.0)), specAt(Vec3.v3(3.0, 5.0, -4.0)))

    // ── CPU で描いた霧 ──

    def fogItem(world: List[Render.PlacedItem], s: PostStack.Stack): Option[Render.PlacedItem] =
        built(world, s)#plan#passes |> List.find(p -> p#name == "ps_fog") |> Option.flatMap(p -> List.head(p#items))

    def flat(r: Float64, g: Float64, b: Float64): TexImage =
        TexImage.Rgba16Float(ShaderEval.hdrTextureOf(4, 4, List.toVector(List.flatMap(_ -> r :: g :: b :: 1.0 :: Nil, List.range(0, 16)))))

    /// 霧の面を (u, v) で評価した r（場面は黒・霧は白なので、霧の濃さを sRGB の曲線で縮めた値）。distance = 面までの距離。
    def fogAt(world: List[Render.PlacedItem], s: PostStack.Stack, distance: Float64, u: Float64, v: Float64): Float64 =
        match fogItem(world, s) |> Option.map(i -> i#item) {
            case Some(Render.Item.Shader(sh)) =>
                let d = distance / camera()#far;
                let compiled = ShaderEval.compile(ShaderDoc.bindParams(sh#params, sh#spec),
                    Map#{ PostStack.sceneName() => flat(0.0, 0.0, 0.0), PostStack.depthName() => flat(d, d, d) });
                let (r, _, _, _) = ShaderEval.evalCompiled(compiled, u, v, sh#t);
                r
            case _ => -1.0
        }

    def fogged(h: PostStack.HeightFog): PostStack.Stack = neutral() |> PostStack.withHeightFog(Some(h))

    def decode(c: Float64): Float64 = if (c <= 0.04045) c / 12.92 else Float64.pow(base = (c + 0.055) / 1.055, 2.4)

    @Test
    def testLookingDownIsFoggierThanLookingUp(): Unit \ Assert =
        let world = sceneWith(Nil) :: Nil;
        Assert.assertEq(expected = true, fogAt(world, fogged(fog()), 30.0, 0.5, 0.9) > fogAt(world, fogged(fog()), 30.0, 0.5, 0.1) + 0.05)

    @Test
    def testFartherIsFoggier(): Unit \ Assert =
        let world = sceneWith(Nil) :: Nil;
        Assert.assertEq(expected = true, fogAt(world, fogged(fog()), 60.0, 0.5, 0.5) > fogAt(world, fogged(fog()), 10.0, 0.5, 0.5) + 0.05)

    // 水平な目の線では高さが変わらないので、霧は 1 − e^(−濃さ(目の高さ) × 距離)。
    @Test
    def testLevelRayMatchesTheFormula(): Unit \ Assert =
        let h = fog();
        let tau = h#density * Float64.exp(0.0 - h#heightFalloff * (2.0 - h#baseHeight)) * 40.0;
        let want = 1.0 - Float64.exp(0.0 - tau);
        let got = decode(fogAt(sceneWith(Nil) :: Nil, fogged(h), 40.0, 0.5, 0.5));
        Assert.assertEq(expected = true, Float64.abs(got - want) < 0.01)

    @Test
    def testStartDistanceKeepsTheNearClear(): Unit \ Assert =
        Assert.assertEq(expected = true, fogAt(sceneWith(Nil) :: Nil, fogged({ startDistance = 20.0 | fog() }), 15.0, 0.5, 0.5) < 0.001)

    @Test
    def testMaxOpacityCapsTheFog(): Unit \ Assert =
        let got = decode(fogAt(sceneWith(Nil) :: Nil, fogged({ density = 50.0, maxOpacity = 0.6 | fog() }), 90.0, 0.5, 0.9));
        Assert.assertEq(expected = true, got <= 0.6 + 0.002 and got >= 0.6 - 0.02)

    @Test
    def testFogColorIsMixedInLinear(): Unit \ Assert =
        let gray = { color = Color.rgb(0.5, 0.5, 0.5), density = 50.0 | fog() };
        Assert.assertEq(expected = true, Float64.abs(fogAt(sceneWith(Nil) :: Nil, fogged(gray), 90.0, 0.5, 0.5) - 0.5) < 0.01)

    // ── 灯りのにじみ ──

    def lamp(): Scene3d.PointLight = { position = Vec3.v3(0.0, 2.0, 30.0), color = Color.rgb(1.0, 0.8, 0.5), intensity = 2.0, range = 6.0 }

    def glowFog(): PostStack.HeightFog = { color = Color.rgb(0.0, 0.0, 0.0), lightGlow = 1.0 | fog() }

    @Test
    def testLampGlowsInTheFog(): Unit \ Assert =
        let world = sceneWith(lamp() :: Nil) :: Nil;
        Assert.assertEq(expected = true, fogAt(world, fogged(glowFog()), 90.0, 0.5, 0.5) > fogAt(world, fogged(glowFog()), 90.0, 0.05, 0.1) + 0.05)

    @Test
    def testWallInFrontOfTheLampHidesTheGlow(): Unit \ Assert =
        let world = sceneWith(lamp() :: Nil) :: Nil;
        Assert.assertEq(expected = true, fogAt(world, fogged(glowFog()), 5.0, 0.5, 0.5) < 0.01)

    @Test
    def testNoGlowWithoutLightGlow(): Unit \ Assert =
        let world = sceneWith(lamp() :: Nil) :: Nil;
        Assert.assertEq(expected = true, fogAt(world, fogged({ lightGlow = 0.0 | glowFog() }), 90.0, 0.5, 0.5) < 0.001)

    // ── むら ──

    def patchy(): PostStack.HeightFog = { noise = Some({ size = 6.0, amount = 0.8, speed = { x = 1.0, y = 0.5 } }) | fog() }

    @Test
    def testNoiseMakesTheFogUneven(): Unit \ Assert =
        let world = sceneWith(Nil) :: Nil;
        let values = List.range(0, 8) |> List.map(i -> fogAt(world, fogged(patchy()), 30.0, 0.1 + Int32.toFloat64(i) * 0.1, 0.8));
        let hi = List.maximum(values) |> Option.getWithDefault(0.0);
        let lo = List.minimum(values) |> Option.getWithDefault(0.0);
        Assert.assertEq(expected = true, hi - lo > 0.02)

    @Test
    def testNoiseFlowsWithTime(): Unit \ Assert =
        let world = sceneWith(Nil) :: Nil;
        let a = fogAt(world, fogged(patchy()) |> PostStack.withTime(at(0.0)), 30.0, 0.4, 0.8);
        let b = fogAt(world, fogged(patchy()) |> PostStack.withTime(at(2.0)), 30.0, 0.4, 0.8);
        Assert.assertEq(expected = true, Float64.abs(a - b) > 0.001)

    // ── post.json ──

    def parsed(text: String): Result[String, PostStack.Stack] = PostStack.parse(text) |> Result.mapErr(e -> "${e}")

    @Test
    def testDocReadsTheHeightFog(): Unit \ Assert =
        let h = parsed("{\"heightFog\": {\"density\": 0.1, \"color\": [0.2, 0.3, 0.4], \"lightGlow\": 0.5, \"noise\": {\"size\": 12}}}")
            |> Result.toOption |> Option.flatMap(PostStack.heightFogOf)
            |> Option.map(x -> (x#density, x#color#g, x#lightGlow, x#heightFalloff, x#noise |> Option.map(n -> (n#size, n#amount))));
        Assert.assertEq(expected = Some((0.1, 0.3, 0.5, 0.2, Some((12.0, 0.4)))), h)

    @Test
    def testDocNullRemovesTheHeightFog(): Unit \ Assert =
        Assert.assertEq(expected = Some(true), parsed("{\"heightFog\": null}") |> Result.toOption |> Option.map(x -> Option.isEmpty(PostStack.heightFogOf(x))))
}
