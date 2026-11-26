// Render3d.GlScreenPasses — GL の 3D の描き手の中の、画面の上の pass（Render3d.ScreenPasses の表）を描く。場面の色の pass の前に、
// 奥行きの Pass（Scene3d.ScreenInputsFields#depth）から R8 の描き先 2 枚へ mask → 横 → 縦を全部の画面の三角形で描き、mask の絵を返す。
pub mod Render3d.GlScreenPasses {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{PixelBox, State}
    use Render3d.ScreenPasses.{ScreenPass, ScreenPassKind}

    /// 組んだ画面の上の pass のプログラム（0 は組めなかった物）と、uniform の名前 → location。
    pub type alias Program = { program = Int32, locs = Map[String, Int32] }

    /// R8 の描き先 1 枚（mask の大きさ）。
    pub type alias MaskTarget = { fbo = Int32, tex = Int32 }

    /// 描き手が持つ物。programs = pass の種類ごとのプログラム（初めて要る時に組む）・targets = mask の描き先 2 枚と大きさ（大きさが変わったら作り直す）・
    /// white = mask を描けない場面の代わりの絵（1 画素の 1 = 暗くしない。初めて要る時に作る）。
    pub type alias Data = { programs = Ref[Map[String, Program], Static], targets = Ref[Option[(Int32, Int32, MaskTarget, MaskTarget)], Static],
                            white = Ref[Option[Int32], Static] }

    /// 何も持たない Data。
    pub def fresh(): Data \ IO =
        { programs = Ref.fresh(Static, Map.empty()), targets = Ref.fresh(Static, None), white = Ref.fresh(Static, None) }

    /// mask を描けない場面の代わりの絵（1 画素の白）。
    def whiteOf(gl: GlContext, state: State): Int32 \ IO =
        let d = state#screenPasses;
        match Ref.get(d#white) {
            case Some(t) => t
            case None    =>
                let made = RenderTexture.loadTextureFromPixels(gl, 1, 1, Vector#{-1});
                let tex = GpuHandle.textureIdInt(made#id);
                Ref.put(Some(tex), d#white);
                tex
        }

    /// mask の絵の texture unit（色の pass の間、材質の frag の +ao のために貼っておく）。
    // WhyNot: 材質の絵（0〜5）や影の地図の unit と共有しない — 色の pass の間ずっと貼っておき、材質ごとに貼り直さない。GL 3.3 と WebGL2 が約束する 16 枚の最後の 1 つ。
    pub def maskTextureUnit(): Int32 = 15

    /// 場面 scene の SSAO の mask を描き、その絵（texture の番号）を返す（+ao の場面だけが呼ぶ。奥行きの Pass が見つからない場面は白の代わりの絵）。
    /// rect = 場面の描き先の矩形（GL の左下が原点・奥行きの Pass の中の同じ場所）・dest = 描き終えた後に戻す FBO。描き終えたら viewport と scissor は呼ぶ側が置き直す。
    pub def renderMask(gl: GlContext, state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, rect: PixelBox, dest: Int32,
                       scene: Scene3d.Scene3dCmd): Int32 \ IO =
        let found = Render3d.ScreenPasses.ambientOcclusionOf(scene)
                    |> Option.flatMap(pair -> depthTextureOf(state, textureOf, fst(pair)) |> Option.map(depth -> (pair, depth)));
        match found {
            case Some(((inputs, ao), depth)) => drawMask(gl, state, rect, dest, scene, inputs, ao, depth)
            case None                        => whiteOf(gl, state)
        }

    /// 奥行きの Pass の texture（見つからない・R32Float で作れず落ちた時は 1 回知らせて None）。
    def depthTextureOf(state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, inputs: Scene3d.ScreenInputs): Option[Int32] \ IO =
        let name = Scene3d.screenInputsFieldsOf(inputs)#depth;
        match textureOf(name) {
            case Some(t) => Some(t#texId)
            case None    =>
                Render3d.ScenePlan.warnOnce(state#planner, "@screen-effects-depth:" + name, Scene3d.Internal.ScreenInputs.missingDepthLine(name));
                None
        }

    def drawMask(gl: GlContext, state: State, rect: PixelBox, dest: Int32, scene: Scene3d.Scene3dCmd, inputs: Scene3d.ScreenInputs,
                 ao: ScreenEffects3d.AmbientOcclusion, depth: Int32): Int32 \ IO =
        let (mw, mh) = ScreenEffects3d.maskSizeOf(ao, rect#width, rect#height);
        let (a, b) = targetsOf(gl, state, mw, mh);
        let values = Render3d.ScreenPasses.valuesOf(scene, inputs, ao, (rect#x, rect#y, rect#width, rect#height));
        gl.disable(GlConst.SCISSOR_TEST);
        gl.disable(GlConst.DEPTH_TEST);
        gl.disable(GlConst.CULL_FACE);
        gl.disable(GlConst.BLEND);
        gl.viewport(0, 0, mw, mh);
        let target = (0.0f32, 0.0f32, Int32.toFloat32(mw), Int32.toFloat32(mh));
        Render3d.ScreenPasses.passesOf(inputs) |> List.filter(p -> p#scaled) |> List.forEach(p -> {
            let (drawTo, readFrom) = match p#kind {
                case ScreenPassKind.AoBlurH => (b, a)
                case _                      => (a, b)
            };
            gl.bindFramebuffer(GlConst.FRAMEBUFFER, drawTo#fbo);
            drawPass(gl, state, p, values, target, depth, readFrom#tex)
        });
        gl.activeTexture(GlConst.TEXTURE0 + 1);
        gl.bindTexture(GlConst.TEXTURE_2D, 0);
        gl.activeTexture(GlConst.TEXTURE0);
        gl.bindTexture(GlConst.TEXTURE_2D, 0);
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, dest);
        a#tex

    /// mask の絵 mask を maskTextureUnit() に貼る（色の pass の頭で Some・尻で外す）。SSAO の無い場面（mask が None）は触らない。
    pub def bindMask(gl: GlContext, mask: Option[Int32]): Unit \ IO =
        mask |> Option.forEach(tex -> {
            gl.activeTexture(GlConst.TEXTURE0 + maskTextureUnit());
            gl.bindTexture(GlConst.TEXTURE_2D, tex);
            gl.activeTexture(GlConst.TEXTURE0)
        })

    /// DebugView.AmbientOcclusion: 場面の色の代わりに mask を灰色で rect（今の描き先の中）へ描く。
    pub def drawShow(gl: GlContext, state: State, rect: PixelBox, scene: Scene3d.Scene3dCmd, mask: Int32): Unit \ IO =
        scene#screenInputs |> Option.forEach(inputs ->
            Scene3d.screenInputsFieldsOf(inputs)#ambientOcclusion |> Option.forEach(ao -> {
                let values = Render3d.ScreenPasses.valuesOf(scene, inputs, ao, (rect#x, rect#y, rect#width, rect#height));
                gl.disable(GlConst.DEPTH_TEST);
                gl.disable(GlConst.CULL_FACE);
                gl.disable(GlConst.BLEND);
                let show = Render3d.ScreenPasses.showPass();
                drawPass(gl, state, show, values,
                         (Int32.toFloat32(rect#x), Int32.toFloat32(rect#y), Int32.toFloat32(rect#width), Int32.toFloat32(rect#height)), 0, mask)
            }))

    /// pass p を今の描き先へ全部の画面の三角形 1 つで描く。target = 描く絵の矩形（GL の左下が原点）・depth と mask = 読む絵（0 は読まない）。
    def drawPass(gl: GlContext, state: State, p: ScreenPass, values: Render3d.ScreenPasses.Values, target: (Float32, Float32, Float32, Float32),
                 depth: Int32, mask: Int32): Unit \ IO =
        let prog = programOf(gl, state, p#kind);
        if (prog#program == 0) ()
        else {
            gl.useProgram(prog#program);
            let put = (name: String, v: (Float32, Float32, Float32, Float32)) -> match Map.get(name, prog#locs) {
                case Some(loc) => { let (x, y, z, w) = v; gl.uniform4f(loc, x, y, z, w) }
                case None      => ()
            };
            put("uSsaoEye", values#eye);
            put("uSsaoForward", values#forward);
            put("uSsaoRight", values#right);
            put("uSsaoUp", values#up);
            put("uSsaoParams", values#params);
            put("uSsaoRect", values#rect);
            put("uSsaoTarget", target);
            let (dx, dy) = p#dir;
            put("uSsaoDir", (dx, dy, 0.0f32, 0.0f32));
            Map.get(Render3d.ScreenPasses.depthName(), prog#locs) |> Option.forEach(loc -> gl.uniform1i(loc, 0));
            Map.get(Render3d.ScreenPasses.maskName(), prog#locs) |> Option.forEach(loc -> gl.uniform1i(loc, 1));
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindTexture(GlConst.TEXTURE_2D, depth);
            gl.activeTexture(GlConst.TEXTURE0 + 1);
            gl.bindTexture(GlConst.TEXTURE_2D, mask);
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindVertexArray(Render3d.programsOf(gl, state)#quadVao);
            gl.drawArrays(GlConst.TRIANGLES, 0, 3);
            gl.bindVertexArray(0);
            gl.useProgram(0)
        }

    /// pass の種類 kind のプログラム（初めて要る時に組む。ぼかしの 2 つは同じプログラム）。
    def programOf(gl: GlContext, state: State, kind: ScreenPassKind): Program \ IO =
        let shared = match kind {
            case ScreenPassKind.AoBlurV => ScreenPassKind.AoBlurH
            case other                  => other
        };
        let key = ToString.toString(shared);
        let d = state#screenPasses;
        match Map.get(key, Ref.get(d#programs)) {
            case Some(p) => p
            case None =>
                let vertex = ShaderAst.Glsl.vertex(Render3d.ScreenPasses.vertex());
                let fragment = ShaderAst.Glsl.fragment(Render3d.ScreenPasses.fragment(shared, Nil));
                let program = Render3d.compile(gl, vertex, fragment, "scene3d:screen:" + key);
                let names = Render3d.ScreenPasses.depthName() :: Render3d.ScreenPasses.maskName() :: Render3d.ScreenPasses.uniformNames();
                let locs = if (program == 0) Map.empty()
                           else names |> List.foldLeft((acc, n) -> {
                               let loc = gl.getUniformLocation(program, n);
                               if (loc < 0) acc else Map.insert(n, loc, acc)
                           }, Map.empty());
                let made = { program = program, locs = locs };
                Ref.put(Map.insert(key, made, Ref.get(d#programs)), d#programs);
                made
        }

    /// mask の大きさ w × h の R8 の描き先 2 枚（大きさが変わったら作り直す）。
    def targetsOf(gl: GlContext, state: State, w: Int32, h: Int32): (MaskTarget, MaskTarget) \ IO =
        let d = state#screenPasses;
        match Ref.get(d#targets) {
            case Some((tw, th, a, b)) if tw == w and th == h => (a, b)
            case old =>
                old |> Option.forEach(e -> { let (_, _, a, b) = e; destroyTarget(gl, a); destroyTarget(gl, b) });
                let a = createTarget(gl, w, h, Render3d.ScreenPasses.ScreenTargetFormat.R8);
                let b = createTarget(gl, w, h, Render3d.ScreenPasses.ScreenTargetFormat.R8);
                Ref.put(Some((w, h, a, b)), d#targets);
                (a, b)
        }

    def createTarget(gl: GlContext, w: Int32, h: Int32, format: Render3d.ScreenPasses.ScreenTargetFormat): MaskTarget \ IO =
        let tex = gl.createTexture();
        gl.activeTexture(GlConst.TEXTURE0 + maskTextureUnit());
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        match format {
            case Render3d.ScreenPasses.ScreenTargetFormat.R8 => gl.texImageR8Zero(w, h)
        };
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
        gl.bindTexture(GlConst.TEXTURE_2D, 0);
        gl.activeTexture(GlConst.TEXTURE0);
        let fbo = gl.createFramebuffer();
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(GlConst.FRAMEBUFFER, GlConst.COLOR_ATTACHMENT0, GlConst.TEXTURE_2D, tex, 0);
        { fbo = fbo, tex = tex }

    def destroyTarget(gl: GlContext, t: MaskTarget): Unit \ IO =
        gl.deleteFramebuffer(t#fbo);
        gl.deleteTexture(t#tex)

    /// 持っている物を手放す。
    pub def release(gl: GlContext, state: State): Unit \ IO =
        let d = state#screenPasses;
        Ref.get(d#targets) |> Option.forEach(e -> { let (_, _, a, b) = e; destroyTarget(gl, a); destroyTarget(gl, b) });
        Ref.put(None, d#targets);
        Map.forEach((_, p) -> if (p#program == 0) () else gl.deleteProgram(p#program), Ref.get(d#programs));
        Ref.put(Map.empty(), d#programs)
}
