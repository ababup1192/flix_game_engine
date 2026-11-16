// 入口。bench/scene3d の部屋（Room）を GL（GlOffscreen）と WebGPU（RenderPaint.Internal.WebGpuPaint・Dawn）の両方で、ウィンドウを開かずに 960×540 で描き
// （warmup のコマの後に 1 コマ）、画素を比べて 1 行 1 場面の表を出す（"[webgpu-v2] <場面> …"）。
// 続けて 1 コマの時間（GL は glFinish まで・WebGPU は waitIdle まで）を GL・WebGPU・貼る形 A・B の順に何回か交互に測って中央値を出す（記録。門ではない）。
// 許す差を超えた場面がある・WebGPU の誤りの数が 0 でない、のどちらかで exit 1。絵は debug/gl・debug/webgpu に書く。
mod V2Main {
    use RenderPaint.Internal.WebGpuPaint
    use Render3d.WebGpuRenderer.SplitPassTrial

    import fge.webgpu.WebGpu
    import java.lang.System
    import java.nio.ByteBuffer
    import org.lwjgl.opengl.GL11

    /// design 320×180 を何倍で描くか（bench/scene3d の窓と同じ 960×540）。
    def scale(): Int32 = 3

    def warmupFrames(): Int32 = 30

    /// 1 回の区間で測るコマの数と、GL・WebGPU を交互に回す回数。
    def timedFrames(): Int32 = 300
    def rounds(): Int32 = 5

    /// 比べる場面。passes と targets = 本編の前に描く Pass と、その描き先の作り方・items = 画面の描き物。
    type alias Case = { name = String, passes = List[Render.Pass], targets = Map[String, RenderTarget.Descriptor], items = List[Render.PlacedItem] }

    def cases(kit: Room.Kit): List[Case] =
        skinnedTwiceCase(kit) ::
        roomCase("room", kit, 0.0, Scene3d.Resolution.Native) ::
        roomCase("roomTurned", kit, 0.5, Scene3d.Resolution.Native) ::
        roomCase("roomDesign", kit, 0.0, Scene3d.Resolution.Design) ::
        roomDepthCase(kit) ::
        roomDepthPassCase(kit) ::
        materialCase("matTextured", kit, V2Materials.textured) ::
        materialCase("matCutout", kit, V2Materials.cutout) ::
        materialCase("matTwoSided", kit, V2Materials.twoSided) ::
        materialCase("matNormal", kit, V2Materials.normalMapped) ::
        materialDepthCase(kit) ::
        materialCase("matMany", kit, V2Materials.manyMaterials(manyCount(), kit#torch)) ::
        materialCase("lmTextured", kit, V2Lightmaps.textured) ::
        materialCase("lmNormalLinear", kit, V2Lightmaps.normalLinear) ::
        lightmapDepthCase(kit) ::
        sceneCase("sky", Scene3d.Resolution.Native, V2Sky.yard(kit, 0.0, -0.45, 1.0)) ::
        sceneCase("skyTurned", Scene3d.Resolution.Native, V2Sky.yard(kit, 3.0, 0.25, 0.6)) ::
        sceneCase("skyDesign", Scene3d.Resolution.Design, V2Sky.yard(kit, 0.0, -0.45, 1.0)) ::
        sceneCase("skyDepth", Scene3d.Resolution.Native, { output = depthOfRoom() | V2Sky.yard(kit, 0.0, -0.45, 1.0) }) ::
        skyMsaaPassCase("skyMsaaPass", kit, true) ::
        skyMsaaPassCase("yardMsaaPass", kit, false) ::
        sceneCase("blend", Scene3d.Resolution.Native, V2Blend.room(kit)) ::
        sceneCase("blendDesign", Scene3d.Resolution.Design, V2Blend.room(kit)) ::
        sceneCase("blendDepth", Scene3d.Resolution.Native, { output = depthOfRoom() | V2Blend.room(kit) }) ::
        msaaPassCase("blendMsaaPass", V2Blend.room(kit)) ::
        postCase("post", kit, 1, PostProcess.Tonemap.AcesFitted, Scene3d.Resolution.Native) ::
        postCase("postMsaa", kit, 4, PostProcess.Tonemap.AcesFitted, Scene3d.Resolution.Native) ::
        postCase("postDesign", kit, 1, PostProcess.Tonemap.Reinhard, Scene3d.Resolution.Design) ::
        halfDepthPassCase("halfDepthDesign", kit, Scene3d.Resolution.Design) ::
        halfDepthPassCase("halfDepthNative", kit, Scene3d.Resolution.Native) ::
        skinnedCase("skinned", kit, Scene3d.Output.Color, V2Skinned.vertexColored) ::
        skinnedCase("skinnedTextured", kit, Scene3d.Output.Color, V2Skinned.textured(V2Materials.colorTexture())) ::
        skinnedCase("skinnedDepth", kit, depthOfRoom(), V2Skinned.vertexColored) ::
        skinnedCase("crowd", kit, Scene3d.Output.Color, V2Skinned.crowd(crowdCount(), kit#torch)) ::
        shadowCase("shadowSpot", V2Shadows.spotRoom(kit)) ::
        shadowCase("shadowSpotTextured", V2Shadows.spotRoomTextured(kit)) ::
        shadowCase("shadowSun", V2Shadows.sunYard(kit, 0)) ::
        shadowCase("shadowSunCrowd", V2Shadows.sunYard(kit, crowdCount())) ::
        shadowCase("shadowSunTextured", V2Shadows.sunYardTextured(kit)) ::
        shadowCase("shadowBoth", V2Shadows.spotAndSun(kit)) ::
        railsCase("railsMsaa", 4, Some(Color.rgb(0.04, 0.04, 0.12)), Color.rgb(0.0, 0.0, 0.0)) ::
        railsCase("railsNoMsaa", 1, Some(Color.rgb(0.04, 0.04, 0.12)), Color.rgb(0.0, 0.0, 0.0)) ::
        railsCase("railsMsaaClear", 4, None, Color.rgb(0.3, 0.15, 0.05)) ::
        slantCase("slant2dMsaa", false) ::
        slantCase("slant2dMsaaFlip", true) :: Nil

    /// railsMsaa と同じ標本 4 の Pass に、3D を使わず 2D の斜めの細い多角形 3 本を描いて貼る（3D の貼る形に依らない MSAA のふちの差を見る比べ相手）。
    /// flipped = 多角形を design の上下に裏返して描く（標本の位置の確かめ・slantFlipProbe）。
    def slantCase(name: String, flipped: Bool): Case =
        let y = (v: Float64) -> if (flipped) Room.design()#y - v else v;
        let bar = (x: Float64, tilt: Float64) -> RawDraw.polygon({ x = x, y = y(150.0) } :: { x = x + tilt, y = y(30.0) } :: { x = x + tilt + 3.0, y = y(30.0) } :: { x = x + 3.0, y = y(150.0) } :: Nil,
                                                                Color.rgb(0.9, 0.9, 0.9), 1);
        let place = (x: Float64, tilt: Float64) -> ({ at = Vec2.zero(), item = bar(x, tilt) }: Render.PlacedItem);
        let pass: Render.Pass = { name = "slant", clear = RenderTarget.LoadOp.Clear(Color.rgb(0.04, 0.04, 0.12)),
                                  items = place(60.0, 60.0) :: place(110.0, 40.0) :: place(160.0, 24.0) :: Nil };
        let design = Room.design();
        { name = name, passes = pass :: Nil, targets = Map#{ "slant" => RenderTarget.withMsaa(4, RenderTarget.defaultDescriptor()) },
          items = Render.blitRegion({ name = "slant", design = design, src = { position = Vec2.zero(), size = design },
                                      at = { x = design#x * 0.5, y = design#y * 0.5 }, size = design, z = 1 }) :: Nil }

    def roomCase(name: String, kit: Room.Kit, yaw: Float64, resolution: Scene3d.Resolution): Case =
        { name = name, passes = Nil, targets = Map.empty(),
          items = Render.scene3d(Vec2.zero(), { resolution = resolution | Room.scene(kit, yaw) }) :: Nil }

    /// 値の binding の比べ（matMany と timeValues）で足す材質の小物の数（uniform の buffer 全体を 1 つの binding にすると 256 個が上限になる数を超える）。
    def manyCount(): Int32 = 300

    /// 部屋の物に材質 restyle（V2Materials）を付けて画面へ直に（Native・yaw 0.3 で家具の側面も映す）。
    def materialCase(name: String, kit: Room.Kit, restyle: Scene3d.Scene3dCmd -> Scene3d.Scene3dCmd): Case =
        { name = name, passes = Nil, targets = Map.empty(), items = Render.scene3d(Vec2.zero(), restyle(Room.scene(kit, 0.3))) :: Nil }

    /// 部屋に restyle（V2Skinned）で物を足して画面へ直に（Native・正面）。output = 場面の Output（Depth なら奥行きの書き出し）。
    def skinnedCase(name: String, kit: Room.Kit, output: Scene3d.Output, restyle: Scene3d.Scene3dCmd -> Scene3d.Scene3dCmd): Case =
        { name = name, passes = Nil, targets = Map.empty(), items = Render.scene3d(Vec2.zero(), { output = output | restyle(Room.scene(kit, 0.0)) }) :: Nil }

    /// 影の場面（V2Shadows）を画面へ直に（Native）。
    def shadowCase(name: String, scene: Scene3d.Scene3dCmd): Case =
        { name = name, passes = Nil, targets = Map.empty(), items = Render.scene3d(Vec2.zero(), scene) :: Nil }

    /// 小物 crowdCount() 個と人形の場面を左右に 2 つ並べて 1 回の prepare で描く（左右で yaw を変える）。1 つ目の場面の 1 体ごとの値だけで 1,024 体を超え、
    /// 2 つ足すと 2,048 体を超えるので、2 つ目の場面の前で 1 体ごとの値の buffer があふれて submit が入り、2 つ目の場面は姿勢を送り直す
    /// （buffer の始めの大きさ 1,024 体のままでも、前の場面で 2,048 体へ伸びていても同じ）。
    def skinnedTwiceCase(kit: Room.Kit): Case =
        let half = (yaw: Float64) -> { size = { x = 0.5 * Room.design()#x, y = Room.design()#y } | V2Skinned.vertexColored(V2Skinned.crowd(crowdCount(), kit#torch, Room.scene(kit, yaw))) };
        { name = "skinnedTwice", passes = Nil, targets = Map.empty(),
          items = Render.scene3d(Vec2.zero(), half(-0.2)) :: Render.scene3d({ x = 0.5 * Room.design()#x, y = 0.0 }, half(0.2)) :: Nil }

    /// crowd の小物の数（形 2 種で行が 2 本・2 本目の行の頭の物は 1 体ごとの値の途中を指す）。
    def crowdCount(): Int32 = 1200

    /// 穴あきの両面の材質を奥行きの書き出しで（cutout の穴を抜いた灰色・裏の面も書く）。
    def materialDepthCase(kit: Room.Kit): Case =
        { name = "matDepth", passes = Nil, targets = Map.empty(),
          items = Render.scene3d(Vec2.zero(), { output = depthOfRoom() | V2Materials.twoSided(Room.scene(kit, 0.3)) }) :: Nil }

    /// lightmap の材質を奥行きの書き出しで（lightmap の版の材質の frag が奥行きの灰色を書く）。
    def lightmapDepthCase(kit: Room.Kit): Case =
        { name = "lmDepth", passes = Nil, targets = Map.empty(),
          items = Render.scene3d(Vec2.zero(), { output = depthOfRoom() | V2Lightmaps.textured(Room.scene(kit, 0.3)) }) :: Nil }

    /// 場面 scene（V2Sky・V2Blend）を解像度 resolution で画面へ直に。
    def sceneCase(name: String, resolution: Scene3d.Resolution, scene: Scene3d.Scene3dCmd): Case =
        { name = name, passes = Nil, targets = Map.empty(), items = Render.scene3d(Vec2.zero(), { resolution = resolution | scene }) :: Nil }

    /// 空の場面を標本 4 の Pass に描いて貼る（空の pipeline の標本 4 の版を通す）。
    /// withSky が偽なら空を外して地の色（部屋の黒）にした比べ相手（yardMsaaPass・MSAA のふちの差が空に依らない事を見る）。
    def skyMsaaPassCase(name: String, kit: Room.Kit, withSky: Bool): Case =
        let yard = V2Sky.yard(kit, 0.4, -0.2, 1.5);
        msaaPassCase(name, if (withSky) yard else { sky = None | yard })

    /// 場面 scene を標本 4 の Pass（design の解像度・マゼンタで消す）に描いて resolve し、画面いっぱいに貼る。
    def msaaPassCase(name: String, scene: Scene3d.Scene3dCmd): Case =
        let pass: Render.Pass = { name = "msaa", clear = RenderTarget.LoadOp.Clear(Color.rgb(1.0, 0.0, 1.0)),
                                  items = Render.scene3d(Vec2.zero(), scene) :: Nil };
        let design = Room.design();
        { name = name, passes = pass :: Nil, targets = Map#{ "msaa" => RenderTarget.withMsaa(4, RenderTarget.defaultDescriptor()) },
          items = Render.blitRegion({ name = "msaa", design = design, src = { position = Vec2.zero(), size = design },
                                      at = { x = design#x * 0.5, y = design#y * 0.5 }, size = design, z = 1 }) :: Nil }

    /// 後がけの鎖（V2Post）: 部屋（yaw 0.3・解像度 resolution）を標本 samples のウィンドウの画素の HDR の Pass に描き、奥行き・ぼかし・ブルーム・トーンマップ（曲線 op）・FXAA の面を通して画面へ。
    def postCase(name: String, kit: Room.Kit, samples: Int32, op: PostProcess.Tonemap, resolution: Scene3d.Resolution): Case =
        let c = V2Post.chain(Room.design(), samples, op, { resolution = resolution | Room.scene(kit, 0.3) }, depthOfRoom());
        { name = name, passes = c#passes, targets = c#targets, items = c#items }

    /// 部屋の奥行きの書き出し（Output.Depth）。目から 1 m で黒・13.5 m で白（部屋の奥の壁まで灰色の坂が入る幅）。
    def depthOfRoom(): Scene3d.Output = Scene3d.Output.Depth({ near = 16.0, range = 200.0 })

    /// 部屋の奥行きの書き出しを画面へ直に（Native）。地の色は部屋の background（黒）。
    def roomDepthCase(kit: Room.Kit): Case =
        { name = "roomDepth", passes = Nil, targets = Map.empty(),
          items = Render.scene3d(Vec2.zero(), { output = depthOfRoom() | Room.scene(kit, 0.3) }) :: Nil }

    /// 後がけの奥行きの Pass と同じ形: 半分の大きさ（design × 0.5）の Rgba16Float の Pass に、解像度 resolution の部屋の奥行きの書き出しを描き、画面いっぱいに貼る。
    /// Design の場面は design の画素で描いた絵を 2:1 に縮めて貼るので、貼る画素の真ん中がちょうど 2 つの texel の境目に来る（最も近い画素の選び方が絵に出る）。
    def halfDepthPassCase(name: String, kit: Room.Kit, resolution: Scene3d.Resolution): Case =
        let room = Room.scene(kit, 0.3);
        let scene = { output = depthOfRoom(), resolution = resolution, environment = { background = None | room#environment } | room };
        let pass: Render.Pass = { name = "halfDepth", clear = RenderTarget.LoadOp.Clear(Color.rgb(1.0, 1.0, 1.0)), items = Render.scene3d(Vec2.zero(), scene) :: Nil };
        let design = Room.design();
        { name = name, passes = pass :: Nil, targets = Map#{ "halfDepth" => RenderTarget.withHdr({ scale = 0.5 | RenderTarget.defaultDescriptor() }) },
          items = Render.blitRegion({ name = "halfDepth", design = design, src = { position = Vec2.zero(), size = design },
                                      at = { x = design#x * 0.5, y = design#y * 0.5 }, size = design, z = 1 }) :: Nil }

    /// ゲームの被写界深度と同じ形: 白で消した Pass（1 を超える値を持つ Rgba16Float）に、地の色の無い部屋の奥行きの書き出しを描き、画面いっぱいに貼る。
    def roomDepthPassCase(kit: Room.Kit): Case =
        let room = Room.scene(kit, 0.3);
        let scene = { output = depthOfRoom(), environment = { background = None | room#environment } | room };
        let pass: Render.Pass = { name = "depth", clear = RenderTarget.LoadOp.Clear(Color.rgb(1.0, 1.0, 1.0)), items = Render.scene3d(Vec2.zero(), scene) :: Nil };
        let design = Room.design();
        { name = "roomDepthPass", passes = pass :: Nil, targets = Map#{ "depth" => RenderTarget.withHdr(RenderTarget.defaultDescriptor()) },
          items = Render.blitRegion({ name = "depth", design = design, src = { position = Vec2.zero(), size = design },
                                      at = { x = design#x * 0.5, y = design#y * 0.5 }, size = design, z = 1 }) :: Nil }

    /// 標本 samples の Pass（design の解像度）に、斜めの細い棒 3 本（bench/gl_parity の msaaEdges の手すりと同じ形・頂点の色）の 3D の場面を描き、
    /// スプライトで画面いっぱいに貼る（bench/gl_parity の passPaste と同じ道）。標本 4 では 3D の場面を標本 4 で描いて resolve してから、標本 4 の Pass へ貼る。
    /// background = 場面の地の色（None なら透明のまま貼り、Pass の clear の色が透ける）・clear = Pass を消す色。
    def railsCase(name: String, samples: Int32, background: Option[Color], clear: Color): Case =
        let bar = (x: Float64, tilt: Float64) -> { points = Vec3.v3(x, -4.0, 12.0) :: Vec3.v3(x + tilt, 4.0, 12.0)
                                                            :: Vec3.v3(x + tilt + 0.15, 4.0, 12.0) :: Vec3.v3(x + 0.15, -4.0, 12.0) :: Nil,
                                                   color = Color.rgb(0.9, 0.9, 0.9) };
        let rails = Scene3d.meshInstance(Mesh3d.fromPolygons(bar(-6.0, 3.0) :: bar(-4.0, 2.0) :: bar(-2.0, 1.2) :: Nil), Mat4.identity());
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 };
        let scene = { instances = rails :: Nil, zIndex = 1,
                      environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = background }
                      | Scene3d.scene(camera, Room.design()) };
        let pass: Render.Pass = { name = "rails", clear = RenderTarget.LoadOp.Clear(clear), items = Render.scene3d(Vec2.zero(), scene) :: Nil };
        let design = Room.design();
        { name = name, passes = pass :: Nil, targets = Map#{ "rails" => RenderTarget.withMsaa(samples, RenderTarget.defaultDescriptor()) },
          items = Render.blitRegion({ name = "rails", design = design, src = { position = Vec2.zero(), size = design },
                                      at = { x = design#x * 0.5, y = design#y * 0.5 }, size = design, z = 1 }) :: Nil }

    /// 場面ごとの許す差: 成分の差が 2 以上の画素の数（差が 1 の画素は数えない）と、違う画素の数の上限（±1 の全体のずれを拾う）。無い場面は (0, 0)。
    /// room と roomTurned（2026-11-16・Apple M4 Pro の実測で ±2 以上 7 px・6 px・違う画素 14 px・8 px）: 同じ深さに重なる面（燭台の台と卓の天板）と三角形のふちの画素で、
    /// 勝つ面が奥行きの丸めで入れ替わる【推: GL は clip の z を固定の段で、WebGPU は頂点シェーダーの sg_clipFromGl で 0..1 へ移すので最後の bit が違う・
    /// Apple Silicon の GL は Metal の上で動くので、GLSL と MSL の compiler の FMA のまとめ方の違いかもしれない】。
    /// 式の取り違え（光・かすみ・色の空間・面の向き）なら面の中が丸ごと違い、千 px の桁になる。
    /// railsMsaa と slant2dMsaa（同じ日の実測で違う画素 3,330 px・5,040 px・±2 以上 2,493 px・4,464 px・どちらも max ±55 = 覆う割合 1/4 の段）: 斜めのふちの画素だけで、
    /// 3D を使わない 2D の多角形でも同じ桁で出るので、3D の貼る形ではなく GL と WebGPU の標本の位置の違い
    /// （4 標本の位置の型が上下に鏡写し・slantFlipProbe で確かめた【推: 描き先の行の並びが上下逆な事から】。軸に沿ったふち（bench/webgpu_v1 の msaaPass）は 0 px）。
    /// MSAA が消えたかは許す差でなく、標本 4 と 1 の差（WebGPU の差が GL の差の半分以上）で見る。
    /// 差の最大の上限: 標本の位置の違いなら覆う割合 1/4 の段（±55）で止まる。それを超えるのは色か式の取り違え。room は勝つ面の入れ替わりで ±82 まで出るので切らない。
    /// railsMsaaClear（地の色の無い場面を色の付いた clear の Pass へ貼る・同じ日の実測で違う画素 4,761 px・±2 以上 2,493 px・max ±54）: ±2 以上は railsMsaa と同じ数で、
    /// 増えた 1,431 px は ±1 だけ【推: ふちの α が 1 未満の画素を clear の色に重ねる時の丸め】。違う画素の上限だけ広げる。
    /// 4,761 px が GL の標本 4 と 1 の差と同じ数なのは偶然でない: 標本 4 で α が 1 未満になるふちの画素の数そのもので、そこが全部 ±1 以上ずれる【推】。
    /// slant2dMsaaFlip を上下に裏返して GL の slant2dMsaa と比べると max ±1（同じ日）なので、MSAA のふちの差は標本の位置が上下に鏡写しな事から来る。
    /// roomDepth（2026-11-16・同じ機械の実測で違う画素 3 px・±2 以上 1 px・max ±4）: room と同じく、三角形のふちと重なる面で勝つ面が奥行きの丸めで入れ替わる画素。
    /// 奥行きの灰色は重なる 2 面の距離の差しか違わないので、色の場面（±82）より差の最大が小さい。式（距離・near・幅・空の白）を取り違えれば面の中が丸ごと違い、万 px の桁になる。
    /// roomDepthPass（design の解像度の Rgba16Float の Pass に描いて貼る）は 0 px なので許す差を置かない。
    /// 材質の場面（2026-11-16・同じ機械の実測。違う画素・±2 以上・max）: matTextured 222・75・±77、matCutout 6・5・±149、matTwoSided 25・25・±68、
    /// matNormal 248・76・±75、matDepth 2・1・±105、matMany 219・214・±147。±2 以上の画素は room と同じく重なる面（床と敷物・家具の天板と小物・格子に重ねた小物）で
    /// 勝つ面が奥行きの丸めで入れ替わる所に固まる（差の絵で確かめた）。matTwoSided と matDepth は物を床から浮かせて（V2Materials.twoSided）その争いを無くした。
    /// ±1 の画素は面の中に点で散る【推: 絵の段の間の補間と sRGB の戻しの丸め】。
    /// 壊して確かめた（同じ日に 1 回ずつ）: 材質の頂点シェーダーで uv の上下を返すと絵つきの 5 場面が 47 万〜52 万 px 違う・両面の裏の法線の向きを逆にすると matTwoSided が 33 万 px・
    /// 両面の材質の裏を間引くと matTwoSided と matDepth が 6.6 万 px 違って落ちる。
    /// 骨つきと小物の場面（同じ日の実測。違う画素・±2 以上・max）: skinned 9・1・±70、skinnedTextured 46・1・±70、skinnedDepth 3・0・±1、crowd 21・10・±146、skinnedTwice 22・14・±230。
    /// ±2 以上は重なる面（人形と卓・小物どうし）で勝つ面が入れ替わる所【推】。skinnedTwice は 2 つ目の場面の前で submit が入る形（姿勢の送り直し）を通す。
    /// 上限はどれも実測のほぼ 2 倍・差の最大は面の入れ替わりで切らない（255）。
    /// 影の場面（同じ日の実測。違う画素・±2 以上・max）: shadowSpot 12・1・±84、shadowSpotTextured 173・1・±69、shadowSun 4・3・±71、shadowSunCrowd 31・22・±145、
    /// shadowSunTextured 40・3・±58、shadowBoth 8・2・±83。±2 以上は room と同じく重なる面で勝つ面が入れ替わる所と、影のふちで地図の比べ（z − bias ≦ 地図の値）が
    /// 最後の bit で入れ替わる画素【推: GL の地図は 24 bit・WebGPU は 32 bit の float】。±1 は面の中に点で散る（絵の補間と光の坂の丸め）。上限は実測のほぼ 2 倍（小さい物は 8）。
    /// 壊して確かめた（同じ日に 1 回ずつ）: 色の pass の影の行列を単位行列にすると 6 場面が 5.8 万〜14.3 万 px・bias を 0 にすると 1.2 万〜17.5 万 px・
    /// 骨つきの物の影の pass で姿勢を読まない（骨の無い版の pipeline で描く）と 5.4 千〜3.1 万 px・影の pass の firstInstance を 1 つずらすと 1.7 万〜10.4 万 px 違って落ちる。
    /// lightmap の場面（2026-11-16・同じ機械の実測。違う画素・±2 以上・max）: lmTextured 231・74・±79、lmNormalLinear 289・80・±86、lmDepth 3・1・±4。
    /// 絵つきの材質の場面（matTextured・matNormal）と同じ所（重なる面の入れ替わり）と同じ桁で、lightmap を足して増えたのは ±1 の点だけ【推: lightmap の段の間の補間と sRGB の戻しの丸め】。
    /// lmDepth は roomDepth と同じ画素。上限は実測のほぼ 2 倍・差の最大は面の入れ替わりで切らない（lmDepth は roomDepth と同じ ±16）。
    /// 壊して確かめた（同じ日に 1 回ずつ）: 材質の頂点シェーダーで 2 本目の uv の上下を返すと lmTextured と lmNormalLinear が 40 万 px・lightmap の強さを 1 のままにすると
    /// 2 場面が全 518,400 px・法線マップの版で lightmap の絵の組の番号を 1 つ手前（法線マップ）にすると lmNormalLinear だけが全 px 違って落ちる。
    /// 空の場面（2026-11-16・同じ機械の実測。違う画素・±2 以上・max）: sky 7・0・±1、skyTurned 0・0・±0、skyDesign 0・0・±0、skyDepth 0・0・±0、skyMsaaPass 14,238・12,249・±60。
    /// 空の画素はどれも GL と ±1 以内で、sky の 7 px も ±1 だけ。skyMsaaPass の差は物のふちで、空を外した比べ相手 yardMsaaPass（13,653・12,195・±64）と同じ桁なので
    /// railsMsaa と同じ標本の位置の違い（空の差ではない）。上限は違う画素を実測のほぼ 2 倍・±2 以上は 4（小さい物の下限）・差の最大は ±16（skyMsaaPass は ±128）。
    /// 壊して確かめた（同じ日に 1 回ずつ）: 空の frag で NDC の y を返さないと skyDepth を除く 4 場面が 43 万〜51 万 px・空の色を sRGB へ戻さないと 43 万〜51 万 px・
    /// 空の向きの材料の幅と高さを入れ替えると 43 万〜50 万 px 違って落ちる（skyDepth は空を描かず白で消すのでこの 3 つでは 0 px）。
    /// 空の曲がりを 1 に決め打ちすると曲がりが 1 でない skyTurned と skyMsaaPass が 43 万 px・奥行きの書き出しの pass でも空を描くと skyDepth が 50 万 px 違って落ちる。
    /// 半透明の場面（同じ機械の実測。違う画素・±2 以上・max）: blend 14・7・±70、blendDesign 0・0・±0、blendDepth 11・1・±2、blendMsaaPass 17,181・13,689・±49。
    /// blend は room と同じ所（重なる面の入れ替わり）で同じ数（半透明の板の画素は差に出ていない）。blendDepth は半透明の物を書かないので部屋の奥行きの書き出しと同じ形の差。
    /// blendMsaaPass は skyMsaaPass と同じ標本の位置の違い。上限は実測のほぼ 2 倍（blend は room と同じ・blendDesign は skyDesign と同じ小さい物の下限）・
    /// 差の最大は blend が面の入れ替わりで切らず、blendDesign と blendDepth は roomDepth と同じ ±16・blendMsaaPass は ±128。
    /// 壊して確かめた（同じ日に 1 回ずつ）: WebGPU の半透明の pipeline の混ぜ方を外すと blend・blendDesign が 13.5 万 px・blendMsaaPass が 14.8 万 px、
    /// 半透明の pipeline で深度を書くと（交わる板が欠ける）blend と blendDesign が 1.2 万 px 違って落ちる（blendMsaaPass は 2.99 万 px で上限の内）。
    /// 計画の並べ順を逆にすると GL と WebGPU の両方が同じに変わるのでこの比べは通る（GL の blend の絵は変わる・守るのは TestSceneList.testPlanSortsBlendedFarToNear）。
    /// 後がけの場面（同じ機械の実測。違う画素・±2 以上・max）: post 247・42・±34、postMsaa 55,680・13,138・±47、postDesign 15,386・3,624・±48、
    /// halfDepthDesign 95,868・9,576・±63、halfDepthNative 0。post は room と同じ所（重なる面の入れ替わり）の差を、ぼかしと FXAA が周りの数画素へ広げた物（差の絵で確かめた）。
    /// postMsaa はウィンドウの画素の標本 4 の Pass の物のふちで、blendMsaaPass と同じ標本の位置の違いをぼかしが広げた物（±2 以上は blendMsaaPass と同じ桁）。
    /// halfDepthDesign と postDesign は、design の画素の絵を 2:1 に縮めて貼る所で貼る画素の真ん中が texel の境目に来て、GL の補間した uv が
    /// 境目のどちら側に落ちるかが列ごとに揺れる所【推: 右の 1/5 の列はそろい、ほかの列で GL だけ 1 つ手前の texel を読む】。上下は GL と同じ選び方にそろえてある（下の壊して確かめた）。
    /// 上限は実測のほぼ 2 倍・差の最大は面の入れ替わりで切らない post を除いて ±128。
    def tolerances(): Map[String, (Int32, Int32, Int32)] =
        Map#{"room" => (32, 64, 255), "roomTurned" => (32, 64, 255), "roomDepth" => (8, 16, 16), "railsMsaa" => (3000, 4000, 60), "railsMsaaClear" => (3000, 6000, 60), "slant2dMsaa" => (5400, 6000, 60),
             "matTextured" => (150, 450, 255), "matCutout" => (16, 32, 255), "matTwoSided" => (50, 50, 255), "matNormal" => (150, 500, 255),
             "matDepth" => (4, 8, 255), "matMany" => (430, 440, 255),
             "skinned" => (8, 32, 255), "skinnedTextured" => (8, 100, 255), "skinnedDepth" => (4, 8, 16), "crowd" => (32, 64, 255), "skinnedTwice" => (32, 64, 255),
             "shadowSpot" => (8, 32, 255), "shadowSpotTextured" => (8, 350, 255), "shadowSun" => (8, 16, 255), "shadowSunCrowd" => (48, 64, 255),
             "shadowSunTextured" => (8, 80, 255), "shadowBoth" => (8, 16, 255),
             "lmTextured" => (150, 460, 255), "lmNormalLinear" => (160, 580, 255), "lmDepth" => (8, 16, 16),
             "sky" => (4, 16, 16), "skyTurned" => (4, 8, 16), "skyDesign" => (4, 8, 16), "skyDepth" => (4, 8, 16), "skyMsaaPass" => (24000, 28000, 128),
             "blend" => (32, 64, 255), "blendDesign" => (4, 8, 16), "blendDepth" => (4, 24, 16), "blendMsaaPass" => (28000, 34000, 128),
             "post" => (84, 500, 255), "postMsaa" => (27000, 112000, 128), "postDesign" => (7300, 31000, 128), "halfDepthDesign" => (19000, 192000, 128)}

    /// 門にしない場面（行は出すが合否に入れない）。slant2dMsaaFlip は標本の位置の確かめ（slantFlipProbe）の材料。
    def probes(): Set[String] = Set#{"slant2dMsaaFlip", "yardMsaaPass"}

    def drawFrame(c: Case): Unit \ Platform.Rendering + Platform.Window + RenderTarget.Target =
        drawPasses(c);
        App.Internal.Paint.submitGpuItems(_ -> (), c#items, Nil, None);
        Platform.Window.presentFrame()

    def drawPasses(c: Case): Unit \ Platform.Rendering + RenderTarget.Target =
        if (List.isEmpty(c#passes)) ()
        else discard App.Internal.Paint.drawPassPlan(_ -> (), Room.design(), Set.empty(), { targets = c#targets | Render.passPlan(c#passes) })

    // ── GL ──

    def shootGl(session: GlOffscreen.Session, c: Case): ByteBuffer \ IO =
        List.range(0, warmupFrames()) |> List.forEach(_ -> GlOffscreen.handle(session, () -> drawFrame(c)));
        let buf = GlOffscreen.freshBuffer(session);
        GlOffscreen.readRgba(session, buf);
        buf

    def timeGl(session: GlOffscreen.Session, kit: Room.Kit): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let c = roomCase("timed", kit, yawAt(i), Scene3d.Resolution.Native);
            let started = System.nanoTime();
            GlOffscreen.handle(session, () -> drawFrame(c));
            GL11.glFinish();
            System.nanoTime() - started
        })

    /// i コマ目のカメラの向き（bench/scene3d の窓と同じ振れ幅）。
    def yawAt(i: Int32): Float64 = 0.6 * Num.sin(Int32.toFloat64(i) / 60.0 * 0.4)

    // ── WebGPU ──

    def shootWebGpu(paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts, c: Case, width: Int32, height: Int32): ByteBuffer \ IO =
        List.range(0, warmupFrames()) |> List.forEach(_ -> handle(paint, fonts, () -> drawFrame(c)));
        let buf = ByteBuffer.allocateDirect(width * height * 4);
        WebGpuPaint.readFrame(paint, buf);
        buf

    def timeWebGpu(gpu: WebGpu, paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts, kit: Room.Kit): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let c = roomCase("timed", kit, yawAt(i), Scene3d.Resolution.Native);
            let started = System.nanoTime();
            handle(paint, fonts, () -> drawFrame(c));
            gpu.waitIdle();
            System.nanoTime() - started
        })

    /// 貼る形 A か B（SplitPassTrial）で i コマ目を組んで GPU を待つ時間。
    def timeTrial(gpu: WebGpu, trial: SplitPassTrial.Trial, kit: Room.Kit, splitPass: Bool): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let cmds = Render.drawScenes3d(Room.items(kit, yawAt(i)));
            let started = System.nanoTime();
            if (splitPass) SplitPassTrial.frameB(trial, cmds) else SplitPassTrial.frameA(trial, cmds);
            gpu.waitIdle();
            System.nanoTime() - started
        })

    /// 材質の小物 manyCount() 個の場面を貼る形 A で i コマ目を組んで GPU を待つ時間（材質の値の binding の比べ。trial の描き手の binding で読む）。
    def timeValues(gpu: WebGpu, trial: SplitPassTrial.Trial, kit: Room.Kit): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let cmds = Render.drawScenes3d(Render.scene3d(Vec2.zero(), V2Materials.manyMaterials(manyCount(), kit#torch, Room.scene(kit, yawAt(i)))) :: Nil);
            let started = System.nanoTime();
            SplitPassTrial.frameA(trial, cmds);
            gpu.waitIdle();
            System.nanoTime() - started
        })

    /// 小物 crowdCount() 個と骨つきの人形の場面を貼る形 A で i コマ目を組んで GPU を待つ時間（1 体ごとの値と姿勢の送り方の記録）。
    def timeCrowd(gpu: WebGpu, trial: SplitPassTrial.Trial, kit: Room.Kit): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let scene = V2Skinned.vertexColored(V2Skinned.crowd(crowdCount(), kit#torch, Room.scene(kit, yawAt(i))));
            let cmds = Render.drawScenes3d(Render.scene3d(Vec2.zero(), scene) :: Nil);
            let started = System.nanoTime();
            SplitPassTrial.frameA(trial, cmds);
            gpu.waitIdle();
            System.nanoTime() - started
        })

    /// f の中の Platform の effect と Target を WebGpuPaint で受ける（bench/webgpu_v1 の handle と同じ並び）。
    def handle(paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts, f: Unit -> a \ ef): a \ (ef - GlOffscreen.HandledEffects) + IO =
        WebGpuPaint.handleTarget(paint, () ->
        windowless(paint, () ->
        WebGpuPaint.handleDiagnostics(paint, () ->
        Platform.runTasksInPlace(() ->
        WebGpuPaint.handleDraw3d(paint, () ->
        WebGpuPaint.handleDraw2d(paint, (_, _, _) -> (), () ->
        WebGpuPaint.handleGpuResources(paint, fonts, f)))))))

    def windowless(paint: WebGpuPaint.Paint, f: Unit -> a \ ef):
            a \ (ef - Platform.Input - Platform.Window - Platform.FrameClock - Platform.Annotation) + IO =
        let design = Room.design();
        run f() with handler Platform.Input {
            def isKeyPressed(_key, k) = k(false)
            def getMousePosition(k) = k(Vec2.zero())
            def isMouseButtonPressed(_button, k) = k(false)
            def isGamepadTouched(k) = k(false)
            def gamepadSticks(k) = k({ left = Vec2.zero(), right = Vec2.zero() })
            def gamepadKind(k) = k(GamepadMap.PadKind.Unknown)
            def consumeScrollDelta(k) = k(0.0)
            def consumeMouseDelta(k) = k(Vec2.zero())
            def isWindowFocused(k) = k(true)
        } with handler Platform.Window {
            def pollEvents(k) = k(())
            def shouldClose(k) = k(false)
            def setShouldClose(_close, k) = k()
            def getViewportRect(k) = k({ position = Vec2.zero(), size = design })
            def getDisplay(k) = k(Display.desktop(design))
            def presentFrame(k) = {
                WebGpuPaint.present(paint, None);
                k(())
            }
            def setCursor(_cursor, k) = k(())
            def setCursorVisible(_visible, k) = k(())
            def setMouseCaptured(_captured, k) = k(())
            def setFullscreen(_on, k) = k(())
            def isFullscreen(k) = k(false)
            def setDebugBadge(_enabled, k) = k(())
        } with handler Platform.FrameClock {
            def getDeltaTime(k) = k(Duration.seconds(1.0 / 60.0))
        } with handler Platform.Annotation {
            def saveAnnotation(_req, k) = k(None)
        }

    // ── 比べる ──

    /// 2 枚の差: 違う画素の数・成分の差の最大（0〜255）・差が 2 以上の画素の数。
    type alias Diff = { pixels = Int32, maxDelta = Int32, overOne = Int32 }

    def diffOf(a: ByteBuffer, b: ByteBuffer, count: Int32): Diff \ IO = diffFrom(a, b, count, 0, { pixels = 0, maxDelta = 0, overOne = 0 })

    def diffFrom(a: ByteBuffer, b: ByteBuffer, count: Int32, i: Int32, acc: Diff): Diff \ IO =
        if (i >= count) acc
        else {
            let d = Int32.max(Int32.max(channelDelta(a, b, i * 4), channelDelta(a, b, i * 4 + 1)),
                              Int32.max(channelDelta(a, b, i * 4 + 2), channelDelta(a, b, i * 4 + 3)));
            let next = if (d == 0) acc
                       else { pixels = acc#pixels + 1, maxDelta = Int32.max(acc#maxDelta, d), overOne = acc#overOne + (if (d >= 2) 1 else 0) };
            diffFrom(a, b, count, i + 1, next)
        }

    def channelDelta(a: ByteBuffer, b: ByteBuffer, at: Int32): Int32 \ IO =
        Int32.abs(Int32.bitwiseAnd(Int8.toInt32(a.get(at)), 255) - Int32.bitwiseAnd(Int8.toInt32(b.get(at)), 255))

    def pad(s: String, n: Int32): String = if (String.length(s) >= n) s else pad(s + " ", n)

    def judge(width: Int32, height: Int32, c: Case, gl: ByteBuffer, gpu: ByteBuffer): (String, Bool) \ IO =
        LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.writePng(gl, width, height, "debug/gl/${c#name}.png");
        LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.writePng(gpu, width, height, "debug/webgpu/${c#name}.png");
        let diff = diffOf(gl, gpu, width * height);
        let (limit, limitAll, limitMax) = Map.getWithDefault(c#name, (0, 0, 0), tolerances());
        let probe = Set.memberOf(c#name, probes());
        let ok = probe or (diff#overOne <= limit and diff#pixels <= limitAll and diff#maxDelta <= limitMax);
        let verdict = if (probe) "記録" else if (ok) "OK" else "NG";
        ("[webgpu-v2] ${pad(c#name, 15)} ${verdict}  差 ${Int32.toString(diff#pixels)} px（許容 ${Int32.toString(limitAll)}）"
            + "・±2 以上 ${Int32.toString(diff#overOne)} px（許容 ${Int32.toString(limit)}）・max ±${Int32.toString(diff#maxDelta)}（許容 ±${Int32.toString(limitMax)}）"
            + "・全 ${Int32.toString(width * height)} px", ok)

    /// 標本の位置が GL と WebGPU で上下に鏡写しかの確かめ（記録・門ではない）: GL の slant2dMsaa と、WebGPU の slant2dMsaaFlip を上下に裏返した絵の差。
    /// 鏡写しなら、裏返した形を描いて裏返し戻した WebGPU の絵は GL の絵に重なり、差が slant2dMsaa の行より大きく減る。
    def slantFlipProbe(width: Int32, height: Int32, gl: ByteBuffer, gpuFlipped: ByteBuffer): Diff \ IO =
        let back = ByteBuffer.allocateDirect(width * height * 4);
        let row = width * 4;
        List.range(0, height) |> List.forEach(y -> List.range(0, row) |> List.forEach(i -> discard back.put((height - 1 - y) * row + i, gpuFlipped.get(y * row + i))));
        diffOf(gl, back, width * height)

    /// ns の列の中央値（ms・小数 3 桁の字）。
    def medianMs(xs: List[Int64]): String =
        let sorted = Sort.sortStable(xs);
        let mid = List.drop(List.length(sorted) / 2, sorted) |> List.head |> Option.getWithDefault(0i64);
        let ms = Int64.toFloat64(mid) / 1000000.0;
        Float64.toString(Float64.round(ms * 1000.0) / 1000.0)

    pub def go(): Unit \ IO =
        let config = match (run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO) {
            case Ok(loaded) => loaded#config
            case Err(why)   => bug!("project.json を読めない: ${why}")
        };
        let kit = match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Ok(meshes) => Room.kitOf(meshes)
            case Err(why)   => bug!("家具を読めない: ${why}")
        };
        let width = config#designWidth * scale();
        let height = config#designHeight * scale();
        let session = match GlOffscreen.open({ config = config, scale = scale() }) {
            case Ok(opened) => opened
            case Err(why)   => bug!("GL を開けない: ${why}")
        };
        let outcome = run { compareAndTime(config, kit, session, width, height) } with WebGpuDevice.runDawn;
        GlOffscreen.close(session);
        let ok = match outcome {
            case Ok(passed) => passed
            case Err(why)   => bug!("WebGPU を開けない: ${why}")
        };
        println("[webgpu-v2] ${if (ok) "OK" else "NG"}");
        if (ok) () else System.exit(1)

    /// 撮った絵の表（場面の名前 → GL と WebGPU の絵）。
    type alias Shots = Map[String, (ByteBuffer, ByteBuffer)]

    /// 標本 4 の場面 on と標本 1 の場面 off の差（GL・WebGPU の違う画素の数）。0 なら MSAA が掛かっていない。場面が無ければ (0, 0)。
    def msaaDiffOf(byName: Shots, on: String, off: String, width: Int32, height: Int32): (Int32, Int32) \ IO =
        match (Map.get(on, byName), Map.get(off, byName)) {
            case (Some((glOn, gpuOn)), Some((glOff, gpuOff))) => (diffOf(glOn, glOff, width * height)#pixels, diffOf(gpuOn, gpuOff, width * height)#pixels)
            case _                                            => (0, 0)
        }

    /// on と off の標本 4 と 1 の差を 1 行出し、WebGPU の差が GL の差の半分以上か（MSAA が抜けていないか）を返す。
    // WhyNot: WebGPU の差が 0 でなければ良し、にしない — 場面の一部だけ MSAA が抜けても 0 にはならない。GL と同じ桁で掛かっている事を見る。
    def msaaGate(byName: Shots, on: String, off: String, width: Int32, height: Int32): Bool \ IO =
        let (gl, gpu) = msaaDiffOf(byName, on, off, width, height);
        println("[webgpu-v2] 標本 4 と 1 の差（${on} と ${off}）GL ${Int32.toString(gl)} px・WebGPU ${Int32.toString(gpu)} px（WebGPU が GL の半分未満なら MSAA が抜けている）");
        gl > 0 and 2 * gpu >= gl

    /// 標本の位置の確かめ（slantFlipProbe）の行を出す（場面が無ければ何もしない）。
    def printSlantFlipProbe(byName: Shots, width: Int32, height: Int32): Unit \ IO =
        match (Map.get("slant2dMsaa", byName), Map.get("slant2dMsaaFlip", byName)) {
            case (Some((glSlant, _)), Some((_, gpuFlip))) =>
                let probe = slantFlipProbe(width, height, glSlant, gpuFlip);
                println("[webgpu-v2] 標本の位置の確かめ（記録）: GL の slant2dMsaa と、WebGPU の slant2dMsaaFlip を上下に裏返した絵の差 ${Int32.toString(probe#pixels)} px"
                    + "・±2 以上 ${Int32.toString(probe#overOne)} px・max ±${Int32.toString(probe#maxDelta)}")
            case _ => ()
        }

    def compareAndTime(config: GameEngine.EngineConfig, kit: Room.Kit, session: GlOffscreen.Session, width: Int32, height: Int32): Result[String, Bool] \ IO + WebGpuDevice =
        match WebGpuDevice.requestDevice() {
            case Err(why) => Err(why)
            case Ok(gpu)  =>
                let paint = WebGpuPaint.create(gpu, { designWidth = config#designWidth, designHeight = config#designHeight, clearColor = config#clearColor,
                                                      width = width, height = height });
                let fonts = LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.loadAll(paint, config);
                println("[webgpu-v2] adapter: ${gpu.adapterInfo()}");
                let shots = cases(kit) |> List.map(c -> (c, shootGl(session, c), shootWebGpu(paint, fonts, c, width, height)));
                let rows = shots |> List.map(match (c, gl, shot) -> judge(width, height, c, gl, shot));
                List.forEach(r -> println(fst(r)), rows);
                let byName = shots |> List.map(match (c, gl, shot) -> (c#name, (gl, shot))) |> List.toMap;
                let railsMsaaOk = msaaGate(byName, "railsMsaa", "railsNoMsaa", width, height);
                let postMsaaOk = msaaGate(byName, "postMsaa", "post", width, height);
                let msaaOk = railsMsaaOk and postMsaaOk;
                printSlantFlipProbe(byName, width, height);
                let design = (Int32.toFloat64(config#designWidth), Int32.toFloat64(config#designHeight));
                let trial = SplitPassTrial.open(gpu, width, height, design);
                let storageTrial = SplitPassTrial.openWith(gpu, width, height, design, Render3d.WebGpuMaterials.ValuesBinding.Storage);
                List.range(0, rounds()) |> List.forEach(round -> {
                    let gl = timeGl(session, kit);
                    let webgpu = timeWebGpu(gpu, paint, fonts, kit);
                    let a = timeTrial(gpu, trial, kit, false);
                    let b = timeTrial(gpu, trial, kit, true);
                    println("[webgpu-v2] 1 コマ（${Int32.toString(round + 1)} 回目・${Int32.toString(timedFrames())} コマの中央値・ms）: GL ${medianMs(gl)}・WebGPU ${medianMs(webgpu)}"
                        + "・貼る形 A ${medianMs(a)}・B ${medianMs(b)}");
                    let uniform = timeValues(gpu, trial, kit);
                    let storage = timeValues(gpu, storageTrial, kit);
                    println("[webgpu-v2] 材質 ${Int32.toString(manyCount())} 個の 1 コマ（${Int32.toString(round + 1)} 回目・ms）: 値を uniform で ${medianMs(uniform)}・storage で ${medianMs(storage)}");
                    let crowd = timeCrowd(gpu, trial, kit);
                    println("[webgpu-v2] 小物 ${Int32.toString(crowdCount())} 個と人形 ${Int32.toString(V2Skinned.figureCount())} 体の 1 コマ（${Int32.toString(round + 1)} 回目・ms）: ${medianMs(crowd)}")
                });
                SplitPassTrial.close(trial);
                SplitPassTrial.close(storageTrial);
                let errors = gpu.errorCount();
                let lastError = gpu.lastError();
                println("[webgpu-v2] errors ${Int32.toString(errors)}${if (errors == 0) "" else " last=[${lastError}]"}");
                WebGpuPaint.release(paint);
                gpu.destroy();
                Ok(errors == 0 and msaaOk and List.forAll(snd, rows))
        }
}

def main(): Unit \ IO = V2Main.go()
