// 先に上げる物（Render3d.Preload）の、同じ key の間は組み直さないことと、置き場の上限で先に上げた物を後回しにすること。GL を呼ばずに決まる所。
mod Render3d.TestPreload {
    import java.io.ByteArrayOutputStream
    import fge.gl.GlContext
    import fge.gl.RecordingGl
    import java.io.PrintStream
    import java.lang.Boolean
    import java.lang.Integer
    import java.lang.Object
    import java.lang.RuntimeException
    import java.lang.System
    import java.lang.reflect.InvocationHandler
    import java.lang.reflect.Method
    import java.lang.reflect.Proxy
    import java.nio.IntBuffer

    // ── 上げる所（GL の呼び出しを捨てる偽物の上で）──

    /// 何も描かない GL。create で始まる呼び出しは連番を返し、ほかは 1 と偽（hasAlphaToOne だけ alphaToOne）と 1 × 1 の絵の入れ物を返す。
    def fakeGlWith(alphaToOne: Bool): GlContext \ IO =
        let next = Ref.fresh(Static, 1);
        let answers = new InvocationHandler {
            def invoke(_this: InvocationHandler, _proxy: Object, method: Method, _args: Array[Object, Static]): Object \ IO =
                let name = method.getName();
                match method.getReturnType().getName() {
                    case "int" if String.startsWith(prefix = "create", name) =>
                        Ref.put(Ref.get(next) + 1, next);
                        checked_cast(Integer.valueOf(Ref.get(next)))
                    case "int"     => checked_cast(Integer.valueOf(1))
                    case "boolean" => checked_cast(Boolean.valueOf(alphaToOne and name == "hasAlphaToOne"))
                    case "java.nio.IntBuffer" => checked_cast(IntBuffer.allocate(1))
                    case _         => checked_cast(null)
                }
        };
        let recording = (new RecordingGl(unchecked_cast(null as GlContext))).getClass();
        unchecked_cast(Proxy.newProxyInstance(recording.getClassLoader(), recording.getInterfaces(), answers) as GlContext)

    def fakeGl(): GlContext \ IO = fakeGlWith(false)

    def meshWithSide(side: Float64): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = { x = 0.0, y = 0.0, z = 0.0 } :: { x = side, y = 0.0, z = 0.0 } :: { x = 0.0, y = side, z = 0.0 } :: Nil,
                              color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    def cmdWith(key: String, side: Float64): Scene3d.PreloadCmd =
        { key = key, instances = () -> Scene3d.meshInstance(meshWithSide(side), Mat4.identity()) :: Nil, textures = () -> Nil }

    def noTexture(_name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO = checked_ecast(None)

    def freshState(): Render3d.State \ IO = Render3d.fresh({ megabytes = 1, count = 1 }, Render3d.DrawMode.Instanced)

    /// cmds を順に上げて、置き場の形の数を返す。
    def meshesAfter(cmds: List[Scene3d.PreloadCmd]): Int32 \ IO =
        let gl = fakeGl();
        let state = freshState();
        cmds |> List.forEach(Render3d.Preload.upload(gl, state, 1i64, noTexture));
        Map.size(Ref.get(state#meshesRef))

    /// 同じ key の間は、中身が変わっても instances を読まず、最初の形だけが置き場にある。
    @Test
    def testSameKeyKeepsTheFirstUpload(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1, meshesAfter(cmdWith("a", 1.0) :: cmdWith("a", 2.0) :: Nil))

    /// key が変わると読み直し、新しい形を上げる。
    @Test
    def testChangedKeyUploadsTheNewMesh(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, meshesAfter(cmdWith("a", 1.0) :: cmdWith("b", 2.0) :: Nil))

    /// 名前 name の絵を読む材質を付けた物の宣言。
    def cmdReading(name: String, textures: List[Texture3d.Texture3d]): Scene3d.PreloadCmd =
        let material = Scene3d.texturedMaterial(name, ShaderDoc.FilterMode.Linear);
        { key = "textured", instances = () -> (Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, meshWithSide(1.0)), Mat4.identity()) |> Scene3d.withMaterial(material)) :: Nil,
          textures = () -> textures }

    /// textures に渡した絵は、場面が 1 つも無くても置き場へ上がる。
    @Test
    def testDeclaredTextureIsUploaded(): Unit \ {Assert, IO} =
        let state = freshState();
        Render3d.Preload.upload(fakeGl(), state, 1i64, noTexture, cmdReading(Texture3d.name(texture()), texture() :: Nil));
        Assert.assertEq(expected = 1, Map.size(Ref.get(state#textures3dRef)))

    /// 材質が読む tex3d: の絵が textures に無ければ 1 回知らせる。
    @Test
    def testMissingDeclaredTextureWarns(): Unit \ {Assert, IO} =
        let text = stderrOf(() -> Render3d.Preload.upload(fakeGl(), freshState(), 1i64, noTexture, cmdReading("tex3d:0123", Nil)));
        Assert.assertEq(expected = 2, List.length(String.split(regex = "tex3d:0123", text)))

    /// まだ作られていない Pass の絵のような全体の登録の名前は知らせない。
    @Test
    def testMissingRegisteredTextureDoesNotWarn(): Unit \ {Assert, IO} =
        let text = stderrOf(() -> Render3d.Preload.upload(fakeGl(), freshState(), 1i64, noTexture, cmdReading("passHistory", Nil)));
        Assert.assertFalse(String.contains(substr = "passHistory", text))

    /// step コマごとに key を変えて 60 回上げた時の知らせの回数。
    def timesKeyWarned(step: Int32): Int32 \ IO =
        let gl = fakeGl();
        let state = freshState();
        let text = stderrOf(() -> List.range(0, 60) |> List.forEach(i ->
            Render3d.Preload.upload(gl, state, Int32.toInt64(i * step), noTexture, cmdWith("key${i}", 1.0))));
        List.length(String.split(regex = "の key が", text)) - 1

    /// key を毎コマ変えても 2 コマに 1 回変えても、知らせは 1 回。100 コマに 1 回なら読み直しの速さとして黙る。
    @Test
    def testFrequentKeyChangesWarnOnce(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (1, 1, 0), (timesKeyWarned(1), timesKeyWarned(2), timesKeyWarned(100)))

    // ── 上げた物の控え ──

    /// cmd を上げた後の状態。
    def stateAfter(alphaToOne: Bool, cmd: Scene3d.PreloadCmd): Render3d.State \ IO =
        let state = freshState();
        Render3d.Preload.upload(fakeGlWith(alphaToOne), state, 1i64, noTexture, cmd);
        state

    /// 控えの鍵は置き場の鍵と同じで、プログラムは置き場の番号と同じ（違うと追い出しで守れない）。
    @Test
    def testMarksMatchTheCacheKeys(): Unit \ {Assert, IO} =
        let state = stateAfter(false, cmdReading(Texture3d.name(texture()), texture() :: Nil));
        let marks = Ref.get(state#preloadRef);
        Assert.assertEq(expected = (Map.keysOf(Ref.get(state#meshesRef)),
                                    Map.keysOf(Ref.get(state#textures3dRef)) |> Set.map(Render3d.TextureSlot.Scene),
                                    Map.valuesOf(Ref.get(state#materialsRef)) |> List.map(e -> e#locs#mesh#program) |> List.toSet),
                        (marks#meshes, marks#textures, marks#programs))

    def cutoutCmd(): Scene3d.PreloadCmd =
        let material = Scene3d.texturedMaterial("wall", ShaderDoc.FilterMode.Linear) |> Scene3d.withCutout(true);
        { key = "cutout", instances = () -> (Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, meshWithSide(1.0)), Mat4.identity()) |> Scene3d.withMaterial(material)) :: Nil,
          textures = () -> Nil }

    /// cutout の材質は、alpha to one のある GL では 2 版、無い GL では 1 版を組み、どれも控える。
    @Test
    def testCutoutBuildsBothVersionsOnlyWithAlphaToOne(): Unit \ {Assert, IO} =
        let programs = (on: Bool) -> Set.size(Ref.get(stateAfter(on, cutoutCmd())#preloadRef)#programs);
        Assert.assertEq(expected = (2, 1), (programs(true), programs(false)))

    def oneJointSkin(): Skin3d.Skin3d = match Skin3d.make({ names = Vector#{ "root" }, parents = Vector#{ -1 },
                                                            rest = Vector#{ { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() } },
                                                            inverseBinds = None, rootTransform = Mat4.identity() }) {
        case Ok(s)  => s
        case Err(e) => bug!(e)
    }

    def oneJointMesh(): Mesh3d.Mesh3d = match Mesh3d.fromArrays({
        positions = Vector#{ -1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0 }, normals = Vector#{ 0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, -1.0 },
        colors = Vector#{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 }, indices = Vector#{ 0, 1, 2 },
        skin = Some({ joints = Vector#{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, weights = Vector#{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 } }) }) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    }

    def skinnedInstance(): Scene3d.Instance3d =
        let skin = oneJointSkin();
        Scene3d.meshInstance(oneJointMesh(), Mat4.identity()) |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin)))

    /// 姿勢を付けて渡した物は、骨つきの版のプログラムまで組む。
    @Test
    def testPosedInstanceBuildsSkinnedPrograms(): Unit \ {Assert, IO} =
        let cmd = { key = "skin", instances = () -> skinnedInstance() :: Nil, textures = () -> Nil };
        Assert.assertTrue(Option.nonEmpty(Ref.get(stateAfter(false, cmd)#skinnedRef)))

    /// 置く物があれば頂点の色のプログラムも組み、何も置かない宣言では組まない。
    @Test
    def testBasePrograms(): Unit \ {Assert, IO} =
        let empty = { key = "none", instances = () -> Nil, textures = () -> Nil };
        Assert.assertEq(expected = (true, false),
                        (Option.nonEmpty(Ref.get(stateAfter(false, cmdWith("a", 1.0))#programsRef)), Option.nonEmpty(Ref.get(stateAfter(false, empty)#programsRef))))

    /// 枚数の上限 1 で先に上げた絵の方が古い時、コマの終わりに捨てるのはもう 1 枚の絵（endFrame まで通す）。
    @Test
    def testEndFrameKeepsTheDeclaredTexture(): Unit \ {Assert, IO} =
        let gl = fakeGl();
        let state = freshState();
        Render3d.Preload.upload(gl, state, 1i64, noTexture, cmdReading(Texture3d.name(texture()), texture() :: Nil));
        let declared = Map.keysOf(Ref.get(state#textures3dRef));
        let other = match Texture3d.fromArgb(1, 1, Vector#{7}) {
            case Ok(t)  => t
            case Err(_) => bug!("1 × 1 の絵は作れる")
        };
        discard Render3d.Material.resolveTextureAs(gl, state, 5i64, sourceWith(other :: Nil, ""), "材質の絵", Texture3d.name(other), Texture3d.TextureUse.MaterialTexture);
        Render3d.endFrame(gl, state, 100i64);
        Assert.assertEq(expected = declared, Map.keysOf(Ref.get(state#textures3dRef)))

    // ── 絵の置き場 ──

    def entry(lastUsed: Int64, preloaded: Bool): Render3d.Material.BudgetEntry =
        { lastUsed = lastUsed, size = 40i64, counted = true, preloaded = preloaded }

    /// 上限の 100 に 120 が入っている時、一番古くても先に上げた物は残し、ほかの物を捨てる。
    @Test
    def testBudgetDropsUnmarkedBeforeOlderMarked(): Unit \ Assert =
        let entries = ("marked", entry(1i64, true)) :: ("a", entry(5i64, false)) :: ("b", entry(6i64, false)) :: Nil;
        Assert.assertEq(expected = "a" :: Nil, Render3d.Material.budgetEvictions({ count = 10, size = 100i64 }, 1000i64, entries))

    /// ほかの物を捨てても足りなければ、先に上げた物も古い順に捨てる（120 → 上限 40 で 2 つ）。
    @Test
    def testBudgetDropsMarkedWhenUnmarkedAreNotEnough(): Unit \ Assert =
        let entries = ("old", entry(1i64, true)) :: ("new", entry(2i64, true)) :: ("plain", entry(9i64, false)) :: Nil;
        Assert.assertEq(expected = "plain" :: "old" :: Nil, Render3d.Material.budgetEvictions({ count = 10, size = 40i64 }, 1000i64, entries))

    // ── 形の置き場 ──

    /// 上限の 100 頂点に 120 頂点が入っている時、一番古くても先に上げた形は残す。
    @Test
    def testMeshBudgetKeepsMarked(): Unit \ Assert =
        let entries = ("marked", 40, 1i64) :: ("a", 40, 5i64) :: ("b", 40, 6i64) :: Nil;
        Assert.assertEq(expected = "a" :: Nil, Render3d.meshEvictions(100, 10i64, Set#{"marked"}, entries))

    /// 今と前のコマで使った形は（Pass の場面は 1 つ前の世代）、上限を超えていても先に上げた物より後に回す。
    @Test
    def testMeshBudgetDropsMarkedBeforeLastFrame(): Unit \ Assert =
        let entries = ("marked", 80, 1i64) :: ("pass", 80, 9i64) :: ("now", 80, 10i64) :: Nil;
        Assert.assertEq(expected = "marked" :: Nil, Render3d.meshEvictions(160, 10i64, Set#{"marked"}, entries))

    // ── 材質のプログラムの置き場 ──

    /// 番号 i・世代 i の材質を n 個。
    def materials(n: Int32): List[(String, Int32, Int64)] =
        List.range(1, n + 1) |> List.map(i -> ("m${i}", i, Int32.toInt64(i)))

    /// 使わない材質が下限の 64 を 1 つ超えた時、一番古くても先に上げた材質は捨てず、次に古い物を捨てる。
    @Test
    def testMaterialEvictionKeepsMarked(): Unit \ Assert =
        Assert.assertEq(expected = "m2" :: Nil, Render3d.Material.materialEvictions(1000i64, Set#{1}, materials(65)))

    /// 先に上げた材質は、今使っている物と同じに上限の元の数に入る（先に上げた物 40 個 → 上限 80。100 個から 20 個捨てる）。
    @Test
    def testMarkedMaterialsRaiseTheCap(): Unit \ Assert =
        Assert.assertEq(expected = 20, List.length(Render3d.Material.materialEvictions(1000i64, List.range(1, 41) |> List.toSet, materials(100))))

    // ── 絵の置き場の鍵 ──

    def sourceWith(own: List[Texture3d.Texture3d], registered: String): Render3d.TextureSource =
        { textureOf = name -> checked_ecast(if (name == registered) Some({ texId = 1, width = 1.0, height = 1.0, flipped = false, version = "" }) else None),
          own = own |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap }

    def texture(): Texture3d.Texture3d = match Texture3d.fromArgb(1, 1, Vector#{0}) {
        case Ok(t)  => t
        case Err(_) => bug!("1 × 1 の絵は作れる")
    }

    /// 場面の textures の絵と全体の登録の絵は見つかり、どちらにも無い名前は見つからない（待つ側へ回る）。
    @Test
    def testTextureSlotIsFoundOnlyInTheSource(): Unit \ {Assert, IO} =
        let source = sourceWith(texture() :: Nil, "wall");
        let gl = fakeGl();
        let found = name -> Render3d.Material.textureSlotOf(gl, source, name, Texture3d.TextureUse.MaterialTexture) |> Option.nonEmpty;
        Assert.assertEq(expected = (true, true, false, false), (found(Texture3d.name(texture())), found("wall"), found("tex3d:none"), found("none")))

    // ── 知らせ ──

    def stderrOf(f: Unit -> Unit \ IO): String \ IO =
        let saved = System.err;
        let buffer = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buffer, true, "UTF-8"));
        let failure = try { f(); None } catch { case ex: RuntimeException => Some(ex) };
        System.setErr(saved);
        failure |> Option.forEach(ex -> throw ex);
        buffer.toString("UTF-8")

    def timesWarned(text: String): Int32 =
        String.split(regex = "先に上げた(形|絵)を", text) |> List.length |> (n -> n - 1)

    /// 先に上げた形を何度捨てても知らせは 1 回で、絵の知らせは別に 1 回出る。
    @Test
    def testDroppingWarnsOncePerKind(): Unit \ {Assert, IO} =
        let state = freshState();
        let slot = Render3d.TextureSlot.Copy("a");
        let text = stderrOf(() -> {
            Render3d.warnDroppedMeshes(state, "a" :: Nil, Set#{"a"});
            Render3d.warnDroppedMeshes(state, "b" :: Nil, Set#{"b"});
            Render3d.warnDroppedTextures(state, slot :: Nil, Set#{slot});
            Render3d.warnDroppedTextures(state, slot :: Nil, Set#{slot})
        });
        Assert.assertEq(expected = 2, timesWarned(text))

    /// 形の知らせは project.json の上限を案内しない（形の上限は変えられない）。
    @Test
    def testMeshWarningDoesNotPointAtTheTextureBudget(): Unit \ {Assert, IO} =
        let text = stderrOf(() -> Render3d.warnDroppedMeshes(freshState(), "a" :: Nil, Set#{"a"}));
        Assert.assertFalse(String.contains(substr = "project.json", text))

    /// 先に上げていない物だけを捨てた時は知らせない。
    @Test
    def testDroppingUnmarkedDoesNotWarn(): Unit \ {Assert, IO} =
        let text = stderrOf(() -> Render3d.warnDroppedMeshes(freshState(), "plain" :: Nil, Set#{"a"}));
        Assert.assertEq(expected = 0, timesWarned(text))
}
