// WebGPU の 3D の描き手の、GPU を呼ばない所（場面の値を R3dScene の欄の位置へ詰める・矩形の上下の向き・まだ描けない物の数え）を固定する。
// 欄の位置は Render3dWgsl.sceneDeclarations の並び（vec3 の後ろの 4 バイトに f32 か i32・光の配列は 400 バイト目から 16 バイト刻みの vec4）。
// WhyNot: mod TestWebGpuScene3d にしない — topLeftOf は Render3d.WebGpuRenderer の中の pub でない関数で、子のモジュールからしか呼べない。
mod Render3d.WebGpuRenderer.TestWebGpuScene3d {
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.ScenePlan.ScenePassSpec
    use Render3d.ShadowMaps.ShadowSampling
    use Render3d.WebGpuRenderer.{clearOf, packPassValues, packSceneValues, packShadowValues, sceneValueBytes, skipsOf, topLeftOf}

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(1.0, 2.0, 3.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 }

    def light(x: Float64, range: Float64): Scene3d.PointLight =
        { position = Vec3.v3(x, 4.0, 5.0), color = Color.rgb(1.0, 0.5, 0.25), intensity = 2.0, range = range }

    def scene(): Scene3d.Scene3dCmd =
        { pointLights = light(6.0, 7.0) :: light(8.0, 9.0) :: Nil,
          environment = { ambient = Color.rgb(0.2, 0.3, 0.4), hemisphere = 0.25, toonSteps = 3,
                          fog = Some({ color = Color.rgb(0.1, 0.1, 0.1), near = 10.0, far = 50.0 }), background = None }
          | Scene3d.scene(camera(), { x = 320.0, y = 180.0 }) }

    def packed(): ByteBuffer \ IO =
        let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
        packSceneValues(buf, Render3d.Light.lightDataOf(scene(), 0));
        buf

    /// 頭の欄: 環境光の r（0）・hemisphere（12）・目の x（16）・toonSteps（28）・かすみ（44）・かすみの遠い端（52）・点光源の数（56）。
    @Test
    def testHeadFieldsSitAtWgslOffsets(): Unit \ {Assert, IO} =
        let d = Render3d.Light.lightDataOf(scene(), 0);
        let buf = packed();
        Assert.assertEq(expected = (Array.get(0, d#ambient), 0.25f32, 1.0f32, 3, 1, 50.0f32, 2),
                        (buf.getFloat(0), buf.getFloat(12), buf.getFloat(16), buf.getInt(28), buf.getInt(44), buf.getFloat(52), buf.getInt(56)))

    /// 光の配列: 2 本目の点光源の x は 400 + 16 バイト目・その range は uPointRange[1].x（400 + 32 × 点光源の上限 + 16 バイト目）。
    @Test
    def testPointLightArraysAreVec4Strided(): Unit \ {Assert, IO} =
        let p = Scene3d.maxPointLights();
        let buf = packed();
        Assert.assertEq(expected = (8.0f32, 9.0f32), (buf.getFloat(400 + 16), buf.getFloat(400 + 32 * p + 16)))

    /// 影は切り、奥行きの書き出しの欄は書かない: uSunShadowOn（76）・uShadowOn（220）・uDepthOut（248）が 0・uShadowSpot（232）が -1。
    @Test
    def testShadowAndDepthOutputAreOff(): Unit \ {Assert, IO} =
        let buf = packed();
        Assert.assertEq(expected = (0, 0, 0, -1), (buf.getInt(76), buf.getInt(220), buf.getInt(248), buf.getInt(232)))

    def spotSampling(): ShadowSampling =
        ShadowSampling.Spot({ matrix = Mat4.translate(Vec3.v3(7.0, 0.0, 0.0)), bias = 0.25, pcfRadius = 3, strength = 0.75, spotIndex = 2 })

    def sunSampling(): ShadowSampling =
        ShadowSampling.Sun({ matrix = Mat4.translate(Vec3.v3(9.0, 0.0, 0.0)), bias = 0.5, normalShift = 1.5, pcfRadius = 2, strength = 0.625,
                             forward = Vec3.v3(0.1, 0.2, 0.3), distance = 40.0, fadeWidth = 6.0 })

    /// スポットの影: uShadowOn（220）に 1・uShadowSpot（232）・pcf（236）・bias（240）・濃さ（244）・行列の平行移動の x（272 + 48）。
    @Test
    def testSpotShadowFieldsSitAtWgslOffsets(): Unit \ {Assert, IO} =
        let buf = packed();
        packShadowValues(buf, spotSampling() :: Nil);
        Assert.assertEq(expected = (1, 2, 3, 0.25f32, 0.75f32, 7.0f32, 0),
                        (buf.getInt(220), buf.getInt(232), buf.getInt(236), buf.getFloat(240), buf.getFloat(244), buf.getFloat(272 + 48), buf.getInt(76)))

    /// 太陽の影: uSunShadowOn（76）に 1・normalShift（92）・forward の z（104）・bias（108）・薄めの距離と幅（112・116）・pcf（120）・濃さ（124）・行列の平行移動の x（336 + 48）。
    @Test
    def testSunShadowFieldsSitAtWgslOffsets(): Unit \ {Assert, IO} =
        let buf = packed();
        packShadowValues(buf, sunSampling() :: Nil);
        Assert.assertEq(expected = (1, 1.5f32, 0.3f32, 0.5f32, 40.0f32, 6.0f32, 2, 0.625f32, 9.0f32, 0),
                        (buf.getInt(76), buf.getFloat(92), buf.getFloat(104), buf.getFloat(108), buf.getFloat(112), buf.getFloat(116),
                         buf.getInt(120), buf.getFloat(124), buf.getFloat(336 + 48), buf.getInt(220)))

    /// 影の無い場面は、前の場面が両方の影を書いた入れ物でも uShadowOn（220）と uSunShadowOn（76）を 0 に戻す。
    @Test
    def testNoShadowTurnsBothOff(): Unit \ {Assert, IO} =
        let buf = packed();
        packShadowValues(buf, spotSampling() :: sunSampling() :: Nil);
        packShadowValues(buf, Nil);
        Assert.assertEq(expected = (0, 0), (buf.getInt(220), buf.getInt(76)))

    /// 奥行きの書き出しの pass は uDepthRange（224・228）に near と幅・uDepthOut（248）に 1。
    @Test
    def testDepthPassWritesRangeAndFlag(): Unit \ {Assert, IO} =
        let buf = packed();
        packPassValues(buf, ScenePassSpec.DepthOut({ near = 0.5, range = 12.0 }));
        Assert.assertEq(expected = (0.5f32, 12.0f32, 1), (buf.getFloat(224), buf.getFloat(228), buf.getInt(248)))

    /// 色の pass は、前の場面が奥行きの書き出しでも uDepthOut を 0 に戻し、幅を 1 にする（入れ物を場面をまたいで使い回す）。
    @Test
    def testColorPassClearsDepthFlag(): Unit \ {Assert, IO} =
        let buf = packed();
        packPassValues(buf, ScenePassSpec.DepthOut({ near = 0.5, range = 12.0 }));
        packPassValues(buf, ScenePassSpec.Color);
        Assert.assertEq(expected = (1.0f32, 0), (buf.getFloat(228), buf.getInt(248)))

    /// 奥行きの書き出しの幅が 0 でも 0 で割らない（GL の Render3d.putDepthRange と同じ下限）。
    @Test
    def testDepthPassRangeIsNeverZero(): Unit \ {Assert, IO} =
        let buf = packed();
        packPassValues(buf, ScenePassSpec.DepthOut({ near = 0.5, range = 0.0 }));
        Assert.assertEq(expected = RenderUtil.f32(0.000001), buf.getFloat(228))

    // ── 場面の地の色（clearOf）──

    def depthOut(): ScenePassSpec = ScenePassSpec.DepthOut({ near = 0.5, range = 12.0 })

    def sky(): Scene3d.Sky3d = Scene3d.gradientSky(Color.rgb(0.1, 0.2, 0.9), Color.rgb(0.8, 0.8, 0.9), Color.rgb(0.3, 0.3, 0.3))

    def withBackground(c: Color, s: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd = { environment = { background = Some(c) | s#environment } | s }

    def panorama(): Texture3d.Texture3d = match Texture3d.fromArgb(2, 2, Vector#{0, 0, 0, 0}) {
        case Ok(t)  => t
        case Err(e) => bug!(e)
    }

    /// 奥行きの書き出しで空を塗る場面は、background があっても一番奥の白で消す（GL は空の frag が白を塗る）。
    @Test
    def testDepthWithSkyClearsWhite(): Unit \ Assert =
        let s = { sky = Some(sky()) | withBackground(Color.rgb(0.25, 0.5, 0.75), scene()) };
        Assert.assertEq(expected = (1.0, 1.0, 1.0, 1.0), clearOf(depthOut(), s))

    /// 奥行きの書き出しで空の無い場面は background で消す（GL の beginScene と同じ）。
    @Test
    def testDepthWithoutSkyClearsBackground(): Unit \ Assert =
        Assert.assertEq(expected = (0.25, 0.5, 0.75, 1.0), clearOf(depthOut(), withBackground(Color.rgb(0.25, 0.5, 0.75), scene())))

    /// 色の pass で空のある場面は透明で消す（空は pass の頭で塗る・background は空があれば使わない）。
    @Test
    def testColorWithSkyClearsTransparent(): Unit \ Assert =
        let s = { sky = Some(sky()) | withBackground(Color.rgb(0.25, 0.5, 0.75), scene()) };
        Assert.assertEq(expected = (0.0, 0.0, 0.0, 0.0), clearOf(ScenePassSpec.Color, s))

    /// sky が無くても景色を背景に描く場面（Scene3d.drawnSkyOf が Some を返す）は、奥行きの書き出しで白で消す。
    @Test
    def testDepthWithBackgroundPanoramaClearsWhite(): Unit \ Assert =
        let e = Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentAsBackground(true);
        let s = { environmentMap = Some(e) | withBackground(Color.rgb(0.25, 0.5, 0.75), scene()) };
        Assert.assertEq(expected = (1.0, 1.0, 1.0, 1.0), clearOf(depthOut(), s))

    // ── 空（Render3d.WebGpuSky）──

    /// 空の frag が場面の値から読む空の 3 色と曲がり（uZenith 128・uCurve 140・uHorizon 144・uGround 160）は、空のある場面では空の色を線形へ戻した物
    /// （GL の drawSky が空のプログラムへ渡す値と同じ）。
    @Test
    def testSkySceneValuesAreLinearSkyColors(): Unit \ {Assert, IO} =
        let s = { sky = Some(sky() |> Scene3d.withSkyCurve(2.0)) | scene() };
        let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
        packSceneValues(buf, Render3d.Light.lightDataOf(s, 0));
        let lin = (c: Float64) -> RenderUtil.f32(Texture3d.srgbToLinearColor(Color.rgb(c, c, c))#r);
        Assert.assertEq(expected = (lin(0.1), 2.0f32, lin(0.8), lin(0.3)), (buf.getFloat(128), buf.getFloat(140), buf.getFloat(144), buf.getFloat(160)))

    /// R3dScene の末尾の空の欄（skyValuesAt から）: forward の z（+8）・描き先の幅（+12）・right の x（+16）・高さ（+28）・up の y（+36）。
    /// yaw と pitch が 0 の目（fovY 1）は +z を見て、right の x は tan(0.5) × 縦横の比（320 / 180）・up の y は tan(0.5)。
    @Test
    def testSkyValuesSitAtWgslOffsets(): Unit \ {Assert, IO} =
        let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
        Render3d.WebGpuSky.packValues(buf, scene(), 640, 360);
        let at = Render3dWgsl.skyValuesAt();
        let tanHalf = Num.sin(0.5) / Num.cos(0.5);
        Assert.assertEq(expected = (1.0f32, 640.0f32, RenderUtil.f32(tanHalf * 320.0 / 180.0), 360.0f32, RenderUtil.f32(tanHalf)),
                        (buf.getFloat(at + 8), buf.getFloat(at + 12), buf.getFloat(at + 16), buf.getFloat(at + 28), buf.getFloat(at + 36)))

    /// 空の欄は R3dScene の最後の 48 バイト（光の配列の後ろ）で、場面の値のバイト数の内に収まる。
    @Test
    def testSkyValuesEndTheSceneValues(): Unit \ Assert =
        Assert.assertEq(expected = sceneValueBytes(), Render3dWgsl.skyValuesAt() + 48)

    /// 空を描くのは sky のある場面と、sky が無く景色を背景に描く場面（GL の drawSky と同じ）。景色を背景に描かない環境マップだけの場面は描かない。
    @Test
    def testSkyIsDrawnWithSkyOrBackgroundPanorama(): Unit \ Assert =
        let e = Scene3d.environmentMap(panorama());
        Assert.assertEq(expected = (true, true, false, false),
                        (Render3d.WebGpuSky.isDrawn({ sky = Some(sky()) | scene() }),
                         Render3d.WebGpuSky.isDrawn({ environmentMap = Some(e |> Scene3d.withEnvironmentAsBackground(true)) | scene() }),
                         Render3d.WebGpuSky.isDrawn({ environmentMap = Some(e) | scene() }), Render3d.WebGpuSky.isDrawn(scene())))

    /// 空の frag が景色を読むかのフラグ（uSkyUp.w）は、sky が無く景色を背景に描く場面だけ 1。sky と背景の景色が両方ある場面は 0（GL も空の坂を描く）。
    @Test
    def testBackgroundFlagIsSetOnlyWithoutSky(): Unit \ {Assert, IO} =
        let e = Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentAsBackground(true);
        let flagOf = (s: Scene3d.Scene3dCmd) -> {
            let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
            Render3d.WebGpuSky.packValues(buf, s, 64, 32);
            buf.getFloat(Render3dWgsl.skyValuesAt() + 44)
        };
        Assert.assertEq(expected = (1.0f32, 0.0f32), (flagOf({ environmentMap = Some(e) | scene() }), flagOf({ sky = Some(sky()), environmentMap = Some(e) | scene() })))

    // ── 環境マップ ──

    /// 環境マップの欄（GL の Render3d.Light.environmentUniforms と同じ値）: uEnvOn（156）・uEnvBoxOn（172）・uEnvBoxMin の x（176）・uEnvLevels（188）・
    /// uEnvBoxMax の y（196）・uEnvIntensity（204）・uEnvBoxCenter の z（216）。
    @Test
    def testEnvironmentFieldsSitAtWgslOffsets(): Unit \ {Assert, IO} =
        let box = { min = Vec3.v3(-6.0, -5.0, 8.0), max = Vec3.v3(6.0, 5.0, 20.0), center = Vec3.v3(0.0, 0.0, 14.0) };
        let e = Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentBox(box) |> Scene3d.withEnvironmentIntensity(0.8);
        let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
        packSceneValues(buf, Render3d.Light.lightDataOf({ environmentMap = Some(e) | scene() }, 5));
        Assert.assertEq(expected = (1, 1, -6.0f32, 5.0f32, 5.0f32, 0.8f32, 14.0f32),
                        (buf.getInt(156), buf.getInt(172), buf.getFloat(176), buf.getFloat(188), buf.getFloat(196), buf.getFloat(204), buf.getFloat(216)))

    /// 環境マップの無い場面は、前の場面が書いた環境マップの欄を on と箱の on の 0 で上書きする（書く欄の組を場面ごとに変えない）。
    @Test
    def testSceneWithoutEnvironmentClearsTheFlags(): Unit \ {Assert, IO} =
        let box = { min = Vec3.v3(-1.0, -1.0, -1.0), max = Vec3.v3(1.0, 1.0, 1.0), center = Vec3.zero() };
        let e = Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentBox(box);
        let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
        packSceneValues(buf, Render3d.Light.lightDataOf({ environmentMap = Some(e) | scene() }, 3));
        packSceneValues(buf, Render3d.Light.lightDataOf(scene(), 0));
        Assert.assertEq(expected = (0, 0), (buf.getInt(156), buf.getInt(172)))

    /// 環境マップのある場面は、まだ描けない物に環境マップの種類を出さない（映り込みと背景を描く）。
    @Test
    def testEnvironmentMapIsNotCounted(): Unit \ {Assert, IO} =
        let e = Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentAsBackground(true);
        let skips = skipsOfScene({ environmentMap = Some(e) | Render3d.FakeGl.sceneOf(plainWithMaterial(Vec3.zero()) :: Nil) });
        Assert.assertEq(expected = None, Map.get("3D の環境マップ", skips))

    /// 空のある場面は、まだ描けない物に空の種類を出さない（色の pass で描く）。
    @Test
    def testSkyIsNotCounted(): Unit \ {Assert, IO} =
        let skips = skipsOfScene({ sky = Some(sky()) | Render3d.FakeGl.sceneOf(plainWithMaterial(Vec3.zero()) :: Nil) });
        Assert.assertEq(expected = None, Map.get("3D の空", skips))

    // ── まだ描けない物の数え（skipsOf）──

    def wood(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Nearest)

    def skinnedWithMaterial(at: Vec3.Vec3): Scene3d.Instance3d =
        Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.translate(at))
            |> Scene3d.withPose(Render3d.FakeGl.poseAt(0.0)) |> Scene3d.withMaterial(wood())

    def plainWithMaterial(at: Vec3.Vec3): Scene3d.Instance3d =
        Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.translate(at)) |> Scene3d.withMaterial(wood())

    /// 場面 1 つを計画の候補に分けて、まだ描けない物の種類と回数を返す。
    def skipsOfScene(scene: Scene3d.Scene3dCmd): Map[String, Int32] \ IO = skipsOfSceneOn(false, 1, scene)

    /// skipsOfScene の、描き先が alpha to one を持つか（alphaToOne）と標本の数 samples を決める版。
    def skipsOfSceneOn(alphaToOne: Bool, samples: Int32, scene: Scene3d.Scene3dCmd): Map[String, Int32] \ IO =
        let grouped = Render3d.ScenePlan.groupScenes(Render3d.ScenePlan.freshPlanner(Render3d.DrawMode.Instanced), { alphaToOne = alphaToOne, poseRowLimit = 0 }, samples,
                                                     Render3d.FakeGl.cmdOf(scene) :: Nil);
        grouped#scenes |> List.flatMap(skipsOf(grouped#members)) |> List.toMap

    def cutoutWood(): Scene3d.Material3d = Scene3d.withCutout(true, wood())

    /// Output.Depth の場面は描くので場面としては数えず、描けない版の材質の物（形だけで書く）だけを数える（ビルボードは描く）。
    /// cutout の材質の物は材質の道で抜いて書き、骨つきの物も描くので数えない。
    @Test
    def testDepthSceneCountsOnlyWhatItCannotDraw(): Unit \ {Assert, IO} =
        let cutout = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(cutoutWood());
        let scene = { output = Scene3d.Output.Depth({ near = 0.1, range = 10.0 })
                      | Render3d.FakeGl.sceneOf(skinnedWithMaterial(Vec3.zero()) :: plainWithMaterial(Vec3.zero()) :: cutout :: Nil) };
        Assert.assertEq(expected = Map#{"3D の奥行きの書き出しの材質の物（描けない版を形で書く）" => 0},
                        skipsOfScene(scene))

    /// 描ける版の材質の骨つきの物は数えない（骨つきの物の種類も無い）。
    @Test
    def testSkinnedWithDrawableMaterialIsNotCounted(): Unit \ {Assert, IO} =
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(skinnedWithMaterial(Vec3.zero()) :: Nil));
        Assert.assertEq(expected = (None, 0), (Map.get("3D の骨つきの物", skips), Map.foldLeft((acc, n) -> acc + n, 0, skips)))

    /// 半透明の材質の物は骨つきの物も含めて描くので、まだ描けない物に数えない。
    @Test
    def testBlendedMaterialIsNotCounted(): Unit \ {Assert, IO} =
        let skinnedGlass = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity())
            |> Scene3d.withPose(Render3d.FakeGl.poseAt(0.0)) |> Scene3d.withMaterial(glassWood());
        let glass = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(glassWood());
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(skinnedGlass :: glass :: Nil));
        Assert.assertEq(expected = 0, Map.foldLeft((acc, n) -> acc + n, 0, skips))

    /// 描ける版の不透明の材質の物（絵つき・cutout）は、まだ描けない物に数えない。
    @Test
    def testDrawableMaterialIsNotCounted(): Unit \ {Assert, IO} =
        let cutout = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(cutoutWood());
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(plainWithMaterial(Vec3.zero()) :: cutout :: Nil));
        Assert.assertEq(expected = 0, Map.foldLeft((acc, n) -> acc + n, 0, skips))

    def billboardAt(texture: String, z: Float64): Scene3d.Billboard3d =
        Scene3d.billboard(texture, { position = { x = 0.0, y = 0.0 }, size = { x = 1.0, y = 1.0 } }, Vec3.v3(0.0, 0.0, z), { x = 1.0, y = 1.0 })

    /// ビルボードは色の場面でも奥行きの書き出しの場面でも描くので、まだ描けない物に数えない。
    @Test
    def testBillboardsAreNotCounted(): Unit \ {Assert, IO} =
        let scene = { billboards = billboardAt("sprite", 5.0) :: billboardAt("sprite", 8.0) :: Nil | Render3d.FakeGl.sceneOf(Nil) };
        let depth = { output = Scene3d.Output.Depth({ near = 0.1, range = 10.0 }) | scene };
        let total = (m: Map[String, Int32]) -> Map.foldLeft((acc, n) -> acc + n, 0, m);
        Assert.assertEq(expected = (0, 0), (total(skipsOfScene(scene)), total(skipsOfScene(depth))))

    /// 2D の描き手は、Pass の中の 3D の場面のビルボードがその Pass の history を貼る時も history を用意する（スプライトと面だけを見ない）。
    @Test
    def testSceneBillboardReadsPassHistory(): Unit \ Assert =
        let reading = { billboards = billboardAt(RenderTarget.historyName("trail"), 5.0) :: Nil | Render3d.FakeGl.sceneOf(Nil) };
        let frameWith = (scene: Scene3d.Scene3dCmd) -> { scenes = Render3d.FakeGl.cmdOf(scene) :: Nil | RenderPaint.emptyFrame() };
        Assert.assertEq(expected = (true, false),
                        (RenderPaint.Internal.WebGpuPaint.isHistoryReadIn("trail", frameWith(reading)),
                         RenderPaint.Internal.WebGpuPaint.isHistoryReadIn("other", frameWith(reading))))

    def glassWood(): Scene3d.Material3d = Scene3d.withAlphaBlend(true, wood())

    /// 視錐台の外（目の後ろ）の材質の物は数えない。骨つきの物は計画が間引かない（Scene3d.isOutsideFrustum がいつも偽・GL も描く）ので目の後ろでも数える。
    /// 描けない版は alpha to coverage の cutout（alpha to one を持つ標本 4 の描き先で計画した物）。
    @Test
    def testCulledThingsAreNotCounted(): Unit \ {Assert, IO} =
        let behind = Vec3.v3(0.0, 0.0, -50.0);
        let cutout = (at: Vec3.Vec3) -> Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.translate(at)) |> Scene3d.withMaterial(cutoutWood());
        let skinnedCutout = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.translate(behind))
            |> Scene3d.withPose(Render3d.FakeGl.poseAt(0.0)) |> Scene3d.withMaterial(cutoutWood());
        let skips = skipsOfSceneOn(true, 4, Render3d.FakeGl.sceneOf(skinnedCutout :: cutout(behind) :: cutout(Vec3.zero()) :: Nil));
        Assert.assertEq(expected = Some(2), Map.get("3D の alpha to coverage の材質の物（頂点の色で描く）", skips))

    /// GL の左下が原点の矩形（y = 20・高さ 40）を、高さ 200 の描き先の左上が原点にすると y は 200 − 20 − 40 = 140。
    @Test
    def testTopLeftFlipsGlOrigin(): Unit \ Assert =
        Assert.assertEq(expected = (10, 140, 30, 40), topLeftOf(200, { x = 10, y = 20, width = 30, height = 40 }))

    // ── 形の版の並び（Render3d.WebGpuRows）──

    /// ジョイントの重みつきの形（uv 無し）は 1 頂点 17 float: 位置・法線・色の 9 の後にジョイントの番号 4（float）と重み 4。
    @Test
    def testSkinnedVersionAppendsJointsAndWeights(): Unit \ {Assert, IO} =
        let mesh = Render3d.FakeGl.skinnedTriangle();
        let out = Render3d.WebGpuRows.interleaveVersion(mesh);
        let width = Render3d.WebGpuRows.floatsPerVertex(mesh);
        let at = (v: Int32, k: Int32) -> Array.get(v * width + k, out);
        Assert.assertEq(expected = (17, 0.0f32, 1.0f32, 1.0f32, 0.0f32), (width, at(1, 9), at(1, 13), at(2, 13), at(2, 15)))

    /// 骨の無い形の版は今までどおり 9 float（位置・法線・色）。
    @Test
    def testPlainVersionHasNoSkin(): Unit \ Assert =
        Assert.assertEq(expected = 9, Render3d.WebGpuRows.floatsPerVertex(Render3d.FakeGl.plainTriangle()))
}
