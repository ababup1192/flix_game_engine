// Render3d.Shadow — 3D の描き手（Render3d）の影の地図（描く・置き場・塗りへ渡す）。約束は Render3d.flix の頭と Scene3d.shadowMatrix の doc。
mod Render3d.Shadow {
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.opengl.GL13
    import org.lwjgl.opengl.GL14
    import org.lwjgl.opengl.GL20
    import org.lwjgl.opengl.GL30
    use Render3d.{ShadowCaster, isSkinned, ShadowLocs, ShadowTarget, ShadowUse, State, drawPosedMesh, matrixArray, maxShadowMapSize,
                  maxShadowPcfRadius, meshDrawOf, meshIdleFrames, programsOf, shadowTextureUnit, skinnedProgramsOf, useMeshProgram}

    // ── 影の地図 ──

    /// 場面ごとに、影を落とすスポットがあれば影の地図を描き、塗りへ渡す物を返す（cmds と同じ並び）。
    /// 描き終えたら深度と scissor を切り、program と VAO を外す。描き先は呼ぶ側が戻す。
    // WhyNot: viewport をここで戻さない — glGet で前の値を読まない決まりで、この後に描く Design の場面と
    //   2D の並び（RenderFrame.renderFrameMixed）が、どちらも描き始めに自分の viewport を置く。
    pub def renderShadows(state: State, gen: Int64, cmds: List[Scene3d.RenderCmd]): List[Option[ShadowUse]] \ IO =
        let usedPerSize = Ref.fresh(Static, (Map.empty(): Map[Int32, Int32]));
        let shadows = cmds |> List.map(cmd -> shadowCasterOf(state, cmd#scene) |> Option.map(caster -> {
            let size = shadowMapSizeOf(state, caster#shadowMap);
            // 同じ mapSize の場面が 1 コマに 2 つあっても地図を分ける — 塗るのは全部の地図を描き終えた後。
            let ordinal = Map.getWithDefault(size, 0, Ref.get(usedPerSize));
            Ref.put(Map.insert(size, ordinal + 1, Ref.get(usedPerSize)), usedPerSize);
            let target = shadowTarget(state, gen, size, ordinal);
            renderShadowMap(state, gen, target, caster, cmd#scene);
            shadowUseOf(state, target, caster)
        }));
        if (List.exists(Option.nonEmpty, shadows)) endShadowPass() else ();
        shadows

    /// 影を落とすスポット。Output.Depth の場面と、置いた物の無い場面は None。
    /// mapSize が 0 以下の shadow は無い物として扱う。2 本目以降の shadow は使わない（1 回知らせる）。
    def shadowCasterOf(state: State, scene: Scene3d.Scene3dCmd): Option[ShadowCaster] \ IO =
        match scene#output {
            case Scene3d.Output.Depth(_) => None
            case Scene3d.Output.Color if List.isEmpty(scene#instances) => None
            case Scene3d.Output.Color =>
                let casters = Scene3d.pickLights(scene#camera#eye, scene)#spotLights
                    |> List.mapWithIndex((i, spot) -> spot#shadow |> Option.filter(m -> m#mapSize > 0) |> Option.map(m -> { spot = spot, shadowMap = m, spotIndex = i }))
                    |> List.filterMap(identity);
                if (List.length(casters) > 1)
                    warnShadowOnce(state, "second", "scene3d: 影を落とすスポットが 1 つの場面に 2 本以上ある — 最初の 1 本だけが影を落とす")
                else ();
                List.head(casters)
        }

    def shadowMapSizeOf(state: State, m: Scene3d.ShadowMap): Int32 \ IO =
        if (m#mapSize > maxShadowMapSize()) {
            warnShadowOnce(state, "size", "scene3d: 影の地図の mapSize ${m#mapSize} は大きすぎる — ${maxShadowMapSize()} で描く");
            maxShadowMapSize()
        } else m#mapSize

    /// 大きさ size の ordinal 枚目の影の描き先（無ければ作る）。lastUsed を今の世代にする。
    def shadowTarget(state: State, gen: Int64, size: Int32, ordinal: Int32): ShadowTarget \ IO =
        let targets = Ref.get(state#shadowTargetsRef);
        let target = match Map.get((size, ordinal), targets) {
            case Some(found) => { lastUsed = gen | found }
            case None        => createShadowTarget(gen, size)
        };
        Ref.put(Map.insert((size, ordinal), target, targets), state#shadowTargetsRef);
        target

    /// 深度テクスチャだけを付けた FBO を作る（作った FBO を bind したまま返す）。
    // WhyNot: 深度を renderbuffer にしない — 塗りのシェーダーが標本として読む。
    // WhyNot: 比べを sampler2DShadow（GL_COMPARE_REF_TO_TEXTURE）に任せない — 比べ方と周りの数え方を CPU の描き手とそろえる。
    def createShadowTarget(gen: Int64, size: Int32): ShadowTarget \ IO =
        // 作る間の bind で unit 0（sprite・font が共用する）の中身を替えない。
        GL13.glActiveTexture(GL13.GL_TEXTURE0 + shadowTextureUnit());
        let tex = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL14.GL_DEPTH_COMPONENT24, size, size, 0,
                          GL11.GL_DEPTH_COMPONENT, GL11.GL_FLOAT, 0i64);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_S, GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_T, GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL14.GL_TEXTURE_COMPARE_MODE, GL11.GL_NONE);
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, 0);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
        let fbo = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, fbo);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_ATTACHMENT, GL11.GL_TEXTURE_2D, tex, 0);
        GL11.glDrawBuffer(GL11.GL_NONE);
        GL11.glReadBuffer(GL11.GL_NONE);
        checkShadowFramebuffer(size);
        { fbo = fbo, tex = tex, size = size, lastUsed = gen }

    def checkShadowFramebuffer(size: Int32): Unit \ IO =
        let status = GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER);
        if (status != GL30.GL_FRAMEBUFFER_COMPLETE)
            Log.warn("scene3d: 影の地図の FBO (${size}×${size}) が完成しない status=${status} — 影が正しく出ない")
        else ()

    /// 影の地図を描く: 光から見た置いた物の一番近い面の深度。ビルボードは影を落とさない。
    def renderShadowMap(state: State, gen: Int64, target: ShadowTarget, caster: ShadowCaster, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let locs = programsOf(state)#depth;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, target#fbo);
        GL11.glViewport(0, 0, target#size, target#size);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glDepthMask(true);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_DEPTH_BUFFER_BIT);
        if (locs#mesh#program == 0) ()
        else {
            GL11.glEnable(GL11.GL_DEPTH_TEST);
            GL11.glDepthFunc(GL11.GL_LESS);
            // WhyNot: 背面を捨てない — 厚みの無い板を裏から照らすと面が全部捨てられ、影が抜ける。
            GL11.glDisable(GL11.GL_CULL_FACE);
            // WhyNot: 深度だけのプログラムを影のために別に組まない — 色の出力は描き先が無いので捨てられる。
            let lightView = matrixArray(Scene3d.shadowMatrix(caster#spot));
            let identity = matrixArray(Mat4.identity());
            let outside = Scene3d.isOutsideFrustum(Scene3d.shadowFrustumOf(caster#spot));
            // WhyNot: 半透明の物に影を落とさせない — 影の地図は 0 か 1 の奥行きで、薄い色ガラスが真っ黒な影を落とす。
            let (skinned, plain) = scene#instances |> List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)))
                |> List.map(meshDrawOf(state, outside)) |> List.partition(isSkinned);
            useMeshProgram(locs#mesh, lightView, identity);
            plain |> List.forEach(drawPosedMesh(state, gen, locs#mesh));
            // 骨つきの物は曲がった形で影を落とす（深度だけの骨つきの版を Output.Depth と共用）。
            if (List.isEmpty(skinned)) ()
            else {
                let skinnedDepth = skinnedProgramsOf(state)#depth;
                if (skinnedDepth#mesh#program == 0) ()
                else {
                    useMeshProgram(skinnedDepth#mesh, lightView, identity);
                    skinned |> List.forEach(drawPosedMesh(state, gen, skinnedDepth#mesh))
                }
            }
        }

    def endShadowPass(): Unit \ IO =
        GL11.glDisable(GL11.GL_DEPTH_TEST);
        GL11.glDisable(GL11.GL_CULL_FACE);
        GL11.glDepthMask(true);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL20.glUseProgram(0);
        GL30.glBindVertexArray(0)

    def shadowUseOf(state: State, target: ShadowTarget, caster: ShadowCaster): ShadowUse \ IO =
        let r = caster#shadowMap#pcfRadius;
        let radius = if (r > maxShadowPcfRadius()) {
            warnShadowOnce(state, "pcf", "scene3d: 影の pcfRadius ${r} は大きすぎる — ${maxShadowPcfRadius()} で数える");
            maxShadowPcfRadius()
        } else Int32.max(0, r);
        { tex = target#tex, matrix = matrixArray(Scene3d.shadowMatrix(caster#spot)), bias = caster#shadowMap#bias,
          pcfRadius = radius, strength = caster#shadowMap#strength, spotIndex = caster#spotIndex }

    def warnShadowOnce(state: State, kind: String, message: String): Unit \ IO =
        let warned = Ref.get(state#shadowWarnedRef);
        if (Set.memberOf(kind, warned)) ()
        else {
            Ref.put(Set.insert(kind, warned), state#shadowWarnedRef);
            Log.warn(message)
        }

    /// 塗りの間だけ影の地図を影の unit に貼る（unit 0 へ戻して返す）。None なら何もしない。
    pub def bindShadowMap(shadow: Option[ShadowUse]): Unit \ IO =
        shadow |> Option.forEach(s -> {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + shadowTextureUnit());
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, s#tex);
            GL13.glActiveTexture(GL13.GL_TEXTURE0)
        })

    /// 影の地図を外す — 次のコマに同じテクスチャを描き先に付けた時、貼ったままだと読み書きが重なる。
    pub def unbindShadowMap(shadow: Option[ShadowUse]): Unit \ IO =
        shadow |> Option.forEach(_ -> {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + shadowTextureUnit());
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, 0);
            GL13.glActiveTexture(GL13.GL_TEXTURE0)
        })

    pub def putShadow(locs: ShadowLocs, shadow: Option[ShadowUse]): Unit \ IO =
        match shadow {
            // プログラムは場面どうしで共有するので、影の無い場面でも毎回切る（前の場面の影が残る）。
            case None    => GL20.glUniform1i(locs#on, 0)
            case Some(s) =>
                GL20.glUniform1i(locs#on, 1);
                GL20.glUniform1i(locs#spot, s#spotIndex);
                GL20.glUniformMatrix4fv(locs#matrix, false, s#matrix);
                GL20.glUniform1i(locs#map, shadowTextureUnit());
                GL20.glUniform1f(locs#bias, RenderUtil.f32(s#bias));
                GL20.glUniform1i(locs#pcf, s#pcfRadius);
                GL20.glUniform1f(locs#strength, RenderUtil.f32(s#strength))
        }

    /// 使われない影の描き先を捨てる（画面のコマの終わりに 1 回）。
    pub def sweepShadowTargets(state: State, gen: Int64): Unit \ IO =
        let targets = Ref.get(state#shadowTargetsRef);
        let idle = Map.filter(t -> gen - t#lastUsed > meshIdleFrames(), targets);
        if (Map.isEmpty(idle)) ()
        else {
            Map.forEach((_key, t) -> {
                GL30.glDeleteFramebuffers(t#fbo);
                GL11.glDeleteTextures(t#tex)
            }, idle);
            Ref.put(Map.difference(targets, idle), state#shadowTargetsRef)
        }
}
