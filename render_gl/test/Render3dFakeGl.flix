// 3D の描き手のテストが使う、呼び出しを控える偽の GL と、場面の組み立て。
mod Render3d.FakeGl {
    import fge.gl.GlContext
    import fge.gl.GlConst
    import fge.gl.RecordingGl
    import java.lang.Boolean
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.Integer
    import java.lang.Object
    import java.lang.RuntimeException
    import java.lang.System
    import java.lang.reflect.InvocationHandler
    import java.lang.reflect.Method
    import java.lang.reflect.Proxy
    import java.nio.FloatBuffer
    import java.nio.IntBuffer

    pub def oneJointSkin(): Skin3d.Skin3d =
        let rest = { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() };
        match Skin3d.make({ names = Vector#{ "root" }, parents = Vector#{ -1 }, rest = Vector#{ rest }, inverseBinds = None, rootTransform = Mat4.identity() }) {
            case Ok(skin) => skin
            case Err(e)   => bug!(e)
        }

    /// ジョイント 1 本を x へ動かした姿勢（joint 行列の 13 個目の数が x）。
    pub def poseAt(x: Float64): Pose3d.Pose3d =
        let rest = { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() };
        Pose3d.compute(oneJointSkin(), Vector#{ { translation = Vec3.v3(x, 0.0, 0.0) | rest } })

    /// 控えた呼び出し。calls = 名前（新しい物が頭）・allocated = texImageRgba32f の高さ（新しい物が頭）・
    /// uploaded = texSubImageRgba32f の (行の数, 行ごとの x)（新しい物が頭）・uploadWidths = texSubImageRgba32f の幅（新しい物が頭）・
    /// textureLimit = getInteger が返すテクスチャの高さの上限・instanceWidths = 1 体ごとの値の texSubImageRgba32f の幅（新しい物が頭）・usedPrograms = useProgram へ渡した 0 でない番号（新しい物が頭）・instanceData = 1 体ごとの値のテクスチャへ上げた float の並び（新しい物が頭）・instanceBinds = 1 体ごとの値の unit へ貼ったテクスチャ（新しい物が頭）・
    /// instanceBases = uInstanceBase へ入れた値（新しい物が頭）・instanceCounts = drawElementsInstanced の instance 数（新しい物が頭）・
    /// jointBinds = joint の unit へ貼ったテクスチャ（新しい物が頭）・activeUnit = 今の unit・targets = 描き先へ戻した bindFramebuffer の番号（新しい物が頭）。
    pub type alias Recorded = { calls = Ref[List[String], Static], allocated = Ref[List[Int32], Static], uploaded = Ref[List[(Int32, List[Float32])], Static],
                            uploadWidths = Ref[List[Int32], Static], textureLimit = Ref[Int32, Static], instanceData = Ref[List[List[Float32]], Static], instanceWidths = Ref[List[Int32], Static], usedPrograms = Ref[List[Int32], Static], instanceBinds = Ref[List[Int32], Static],
                            instanceBases = Ref[List[Int32], Static], instanceCounts = Ref[List[Int32], Static], jointBinds = Ref[List[Int32], Static],
                            activeUnit = Ref[Int32, Static], targets = Ref[List[Int32], Static] }

    pub def freshRecorded(): Recorded \ IO =
        { calls = Ref.fresh(Static, Nil), allocated = Ref.fresh(Static, Nil), uploaded = Ref.fresh(Static, Nil), uploadWidths = Ref.fresh(Static, Nil), textureLimit = Ref.fresh(Static, 4096),
          instanceData = Ref.fresh(Static, Nil), instanceWidths = Ref.fresh(Static, Nil), usedPrograms = Ref.fresh(Static, Nil), instanceBinds = Ref.fresh(Static, Nil), instanceBases = Ref.fresh(Static, Nil), instanceCounts = Ref.fresh(Static, Nil),
          jointBinds = Ref.fresh(Static, Nil), activeUnit = Ref.fresh(Static, 0), targets = Ref.fresh(Static, Nil) }

    /// getUniformLocation("uInstanceBase") の番号。
    pub def instanceBaseLocation(): Int32 = 77

    pub def intArg(args: Array[Object, Static], i: Int32): Int32 \ IO =
        let boxed = Array.get(i, args);
        (unchecked_cast(boxed as Integer)).intValue()

    pub def stringArg(args: Array[Object, Static], i: Int32): String \ IO =
        let boxed = Array.get(i, args);
        unchecked_cast(boxed as String)

    pub def bufferArg(args: Array[Object, Static], i: Int32): FloatBuffer \ IO =
        let boxed = Array.get(i, args);
        unchecked_cast(boxed as FloatBuffer)

    pub def note(log: Recorded, name: String, args: Array[Object, Static]): Unit \ IO =
        Ref.put(name :: Ref.get(log#calls), log#calls);
        let onJointUnit = Ref.get(log#activeUnit) == GlConst.TEXTURE0 + Render3d.jointTextureUnit();
        let onInstanceUnit = Ref.get(log#activeUnit) == GlConst.TEXTURE0 + Render3d.instanceTextureUnit();
        match name {
            case "texImageRgba32f" if onJointUnit => Ref.put(intArg(args, 1) :: Ref.get(log#allocated), log#allocated)
            case "texSubImageRgba32f" if onJointUnit =>
                let rowCount = intArg(args, 3);
                let pixels = bufferArg(args, 4);
                let stride = intArg(args, 2) * 4;
                Ref.put(intArg(args, 2) :: Ref.get(log#uploadWidths), log#uploadWidths);
                Ref.put((rowCount, List.range(0, rowCount) |> List.map(r -> pixels.get(r * stride + 12))) :: Ref.get(log#uploaded), log#uploaded)
            case "texSubImageRgba32f" =>
                let pixels = bufferArg(args, 4);
                let floats = List.range(0, pixels.limit()) |> List.map(i -> pixels.get(i));
                Ref.put(intArg(args, 2) :: Ref.get(log#instanceWidths), log#instanceWidths);
                Ref.put(floats :: Ref.get(log#instanceData), log#instanceData)
            case "activeTexture"   => Ref.put(intArg(args, 0), log#activeUnit)
            case "bindTexture" if onJointUnit    => Ref.put(intArg(args, 1) :: Ref.get(log#jointBinds), log#jointBinds)
            case "bindTexture" if onInstanceUnit => Ref.put(intArg(args, 1) :: Ref.get(log#instanceBinds), log#instanceBinds)
            case "uniform1i"       =>
                if (intArg(args, 0) == instanceBaseLocation()) Ref.put(intArg(args, 1) :: Ref.get(log#instanceBases), log#instanceBases) else ()
            case "useProgram"      => if (intArg(args, 0) != 0) Ref.put(intArg(args, 0) :: Ref.get(log#usedPrograms), log#usedPrograms) else ()
            case "drawElementsInstanced" => Ref.put(intArg(args, 4) :: Ref.get(log#instanceCounts), log#instanceCounts)
            case "bindFramebuffer" => Ref.put(intArg(args, 1) :: Ref.get(log#targets), log#targets)
            case _ => ()
        }

    /// 何も描かない GL。create で始まる呼び出しは連番、FBO の検査は完成、テクスチャの高さの上限は log#textureLimit、ほかは 1 と偽を返す。
    pub def recordingGl(log: Recorded): GlContext \ IO =
        let next = Ref.fresh(Static, 1);
        let answers = new InvocationHandler {
            def invoke(_this: InvocationHandler, _proxy: Object, method: Method, args: Array[Object, Static]): Object \ IO =
                let name = method.getName();
                note(log, name, args);
                let asksInstanceBase = name == "getUniformLocation" and stringArg(args, 1) == "uInstanceBase";
                match method.getReturnType().getName() {
                    case "int" if String.startsWith(prefix = "create", name) =>
                        Ref.put(Ref.get(next) + 1, next);
                        checked_cast(Integer.valueOf(Ref.get(next)))
                    case "int" if name == "checkFramebufferStatus" => checked_cast(Integer.valueOf(GlConst.FRAMEBUFFER_COMPLETE))
                    case "int" if name == "getInteger"             => checked_cast(Integer.valueOf(Ref.get(log#textureLimit)))
                    case "int" if asksInstanceBase                 => checked_cast(Integer.valueOf(instanceBaseLocation()))
                    case "int"                                     => checked_cast(Integer.valueOf(1))
                    case "boolean"                                 => checked_cast(Boolean.valueOf(false))
                    case "java.nio.IntBuffer"                      => checked_cast(IntBuffer.allocate(1))
                    case "java.nio.FloatBuffer"                    => checked_cast(FloatBuffer.allocate(intArg(args, 0)))
                    case _                                         => checked_cast(null)
                }
        };
        let recording = (new RecordingGl(unchecked_cast(null as GlContext))).getClass();
        unchecked_cast(Proxy.newProxyInstance(recording.getClassLoader(), recording.getInterfaces(), answers) as GlContext)

    pub def freshState(): Render3d.State \ IO = Render3d.fresh({ megabytes = 1, count = 1 }, Render3d.DrawMode.Instanced)

    pub def freshOneByOne(): Render3d.State \ IO = Render3d.fresh({ megabytes = 1, count = 1 }, Render3d.DrawMode.OneByOne)

    /// f が標準エラーへ書いた字（f が投げた例外はそのまま投げ直す）。
    pub def stderrOf(f: Unit -> Unit \ IO): String \ IO =
        let saved = System.err;
        let buffer = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buffer, true, "UTF-8"));
        let failure = try { f(); None } catch { case ex: RuntimeException => Some(ex) };
        System.setErr(saved);
        failure |> Option.forEach(ex -> throw ex);
        buffer.toString("UTF-8")

    /// ジョイント 1 本で曲げる三角形。
    pub def skinnedTriangle(): Mesh3d.Mesh3d =
        match Mesh3d.fromArrays({ positions = Vector#{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 }, normals = Vector#{ 0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, -1.0 },
                                  colors = Vector#{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 }, indices = Vector#{ 0, 1, 2 },
                                  skin = Some({ joints = Vector#{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, weights = Vector#{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 } }) }) {
            case Ok(mesh) => mesh
            case Err(e)   => bug!(e)
        }

    pub def skinnedAt(pose: Pose3d.Pose3d): Scene3d.Instance3d =
        Scene3d.meshInstance(skinnedTriangle(), Mat4.identity()) |> Scene3d.withPose(pose)

    pub def camera(): Camera3d.Camera3d =
        { eye = Vec3.v3(0.0, 0.0, -5.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }

    pub def sceneOf(instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        { instances = instances | Scene3d.scene(camera(), { x = 64.0, y = 64.0 }) }

    pub def cmdOf(scene: Scene3d.Scene3dCmd): Scene3d.RenderCmd =
        { scene = scene, at = Vec2.zero(), clip = None }

    pub def shadowSpot(): Scene3d.SpotLight =
        { position = Vec3.v3(0.0, 5.0, 0.0), target = Vec3.zero(), fovY = 1.0, innerFovY = None, color = { r = 1.0, g = 1.0, b = 1.0 },
          intensity = 1.0, range = 40.0, shadow = Some({ mapSize = 64, bias = 0.001, pcfRadius = 0, strength = 1.0 }) }

    pub def dest(): Scene3dRenderer.Dest = { framebuffer = 0, format = RenderTarget.Format.Rgba8Unorm, samples = 1 }

    /// HDR の Pass の中で準備する時の描き先。
    pub def passDest(): Scene3dRenderer.Dest = { framebuffer = 7, format = RenderTarget.Format.Rgba16Float, samples = 4 }

    pub def noTexture(_name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO = checked_ecast(None)

    pub def viewport(): Scene3dRenderer.Viewport = { x = 0, y = 0, width = 64, height = 64, scaleX = 1.0, scaleY = 1.0 }

    /// 1 回の prepare で場面を準備して、全部の場面を描く。
    pub def paintTo(gl: GlContext, state: Render3d.State, target: Scene3dRenderer.Dest, cmds: List[Scene3d.RenderCmd]): Unit \ IO =
        let prepared = Render3d.prepareNumbered(gl, state, 1i64, noTexture, target, cmds);
        List.range(0, List.length(cmds)) |> List.forEach(i -> prepared#draw(viewport(), i))

    pub def paint(gl: GlContext, state: Render3d.State, cmds: List[Scene3d.RenderCmd]): Unit \ IO = paintTo(gl, state, dest(), cmds)

    pub def timesCalled(name: String, log: Recorded): Int32 \ IO =
        Ref.get(log#calls) |> List.count(called -> called == name)

    pub def plainTriangle(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil, color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)
}
