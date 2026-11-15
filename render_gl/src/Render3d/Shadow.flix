// Render3d.Shadow — 3D の描き手（Render3d）の影の地図（描く・置き場・塗りへ渡す）。約束は Render3d.flix の頭と Scene3d.shadowMatrix の doc。
mod Render3d.Shadow {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{SceneShadows, ShadowCaster, ShadowLight, ShadowPlan, ShadowLocs, SunShadowLocs, ShadowTarget, ShadowUse, SunShadowUse, State, drawBatch, matrixArray, maxShadowMapSize,
                  maxShadowPcfRadius, idleTargetFrames, programsOf, blankTextureUnit, shadowTextureUnit, sunShadowTextureUnit, skinnedProgramsOf, useMeshProgram, loc}
    use Render3d.Batch.{MeshBatch}
    use Render3d.Counts.{BatchBreak, Counter, count}
    use Render3d.ScenePlan.{warnShadowOnce}

    // ── 影の地図 ──

    /// 描いた影の地図 1 枚（塗りへ渡す物）。
    enum Cast {
        case Spot(ShadowUse)
        case Sun(SunShadowUse)
    }

    /// 場面ごとに、plans（場面と同じ並び）の影の地図を描き、塗りへ渡す物を返す。骨つきの物は今 joint の unit に貼ってある joint texture を読む。
    /// 描き終えたら深度と scissor を切り、program と VAO を外す。描き先は呼ぶ側が戻す。
    // WhyNot: viewport をここで戻さない — glGet で前の値を読まない決まりで、この後に描く Design の場面と
    //   2D の並び（RenderFrame.renderFrameMixed）が、どちらも描き始めに自分の viewport を置く。
    pub def renderShadows(gl: GlContext, state: State, gen: Int64, plans: List[List[ShadowPlan[MeshBatch]]]): List[SceneShadows] \ IO =
        let usedPerSize = Ref.fresh(Static, (Map.empty(): Map[Int32, Int32]));
        let shadows = plans |> List.map(scenePlans -> {
            let casts = scenePlans |> List.map(plan -> {
                let caster = plan#caster;
                let size = shadowMapSizeOf(state, caster#settings);
                // 同じ mapSize の場面が 1 コマに 2 つあっても（1 つの場面のスポットと太陽でも）地図を分ける — 塗るのは全部の地図を描き終えた後。
                let ordinal = Map.getWithDefault(size, 0, Ref.get(usedPerSize));
                Ref.put(Map.insert(size, ordinal + 1, Ref.get(usedPerSize)), usedPerSize);
                let target = shadowTarget(gl, state, gen, size, ordinal);
                renderShadowMap(gl, state, gen, target, plan);
                shadowUseOf(state, target, caster, plan#light)
            });
            { spot = List.findMap(spotOf, casts), sun = List.findMap(sunOf, casts) }
        });
        if (List.exists(s -> Option.nonEmpty(s#spot) or Option.nonEmpty(s#sun), shadows)) endShadowPass(gl) else ();
        shadows

    def spotOf(c: Cast): Option[ShadowUse] = match c {
        case Cast.Spot(shadow) => Some(shadow)
        case Cast.Sun(_)       => None
    }

    def sunOf(c: Cast): Option[SunShadowUse] = match c {
        case Cast.Sun(shadow)  => Some(shadow)
        case Cast.Spot(_)      => None
    }

    def shadowMapSizeOf(state: State, m: Scene3d.ShadowMap): Int32 \ IO =
        if (m#mapSize > maxShadowMapSize()) {
            warnShadowOnce(state#planner, "size","scene3d: 影の地図の mapSize ${m#mapSize} は大きすぎる — ${maxShadowMapSize()} で描く");
            maxShadowMapSize()
        } else m#mapSize

    /// 大きさ size の ordinal 枚目の影の描き先（無ければ作る）。lastUsed を今の世代にする。
    def shadowTarget(gl: GlContext, state: State, gen: Int64, size: Int32, ordinal: Int32): ShadowTarget \ IO =
        let targets = Ref.get(state#shadowTargetsRef);
        let target = match Map.get((size, ordinal), targets) {
            case Some(found) => { lastUsed = gen | found }
            case None        =>
                count(state, Counter.TargetRebuilds, 1);
                createShadowTarget(gl, gen, size)
        };
        Ref.put(Map.insert((size, ordinal), target, targets), state#shadowTargetsRef);
        target

    /// 深度テクスチャだけを付けた FBO を作る（作った FBO を bind したまま返す）。
    // WhyNot: 深度を renderbuffer にしない — 塗りのシェーダーが標本として読む。
    // WhyNot: 比べを sampler2DShadow（GL_COMPARE_REF_TO_TEXTURE）に任せない — 比べ方と周りの数え方を CPU の描き手とそろえる。
    def createShadowTarget(gl: GlContext, gen: Int64, size: Int32): ShadowTarget \ IO =
        // 作る間の bind で unit 0（sprite・font が共用する）の中身を替えない。
        gl.activeTexture(GlConst.TEXTURE0 + shadowTextureUnit());
        let tex = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        gl.texImageDepth24(size, size);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_COMPARE_MODE, GlConst.NONE);
        gl.bindTexture(GlConst.TEXTURE_2D, 0);
        gl.activeTexture(GlConst.TEXTURE0);
        let fbo = gl.createFramebuffer();
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(GlConst.FRAMEBUFFER, GlConst.DEPTH_ATTACHMENT, GlConst.TEXTURE_2D, tex, 0);
        gl.useNoColorBuffer();
        checkShadowFramebuffer(gl, size);
        { fbo = fbo, tex = tex, size = size, lastUsed = gen }

    def checkShadowFramebuffer(gl: GlContext, size: Int32): Unit \ IO =
        let status = gl.checkFramebufferStatus(GlConst.FRAMEBUFFER);
        if (status != GlConst.FRAMEBUFFER_COMPLETE)
            Log.warn("scene3d: 影の地図の FBO (${size}×${size}) が完成しない status=${status} — 影が正しく出ない")
        else ()

    /// 影の地図を描く: 光から見た置いた物の一番近い面の深度。ビルボードは影を落とさない。
    def renderShadowMap(gl: GlContext, state: State, gen: Int64, target: ShadowTarget, plan: ShadowPlan[MeshBatch]): Unit \ IO =
        let locs = programsOf(gl, state)#depth;
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, target#fbo);
        gl.viewport(0, 0, target#size, target#size);
        gl.disable(GlConst.SCISSOR_TEST);
        gl.depthMask(true);
        gl.clearDepth(1.0);
        gl.clear(GlConst.DEPTH_BUFFER_BIT);
        if (locs#mesh#program == 0) ()
        else {
            gl.enable(GlConst.DEPTH_TEST);
            gl.depthFunc(GlConst.LESS);
            // WhyNot: 背面を捨てない — 厚みの無い板を裏から照らすと面が全部捨てられ、影が抜ける。
            gl.disable(GlConst.CULL_FACE);
            // WhyNot: 深度だけのプログラムを影のために別に組まない — 色の出力は描き先が無いので捨てられる。
            let lightView = matrixArray(plan#caster#matrix);
            let identity = matrixArray(Mat4.identity());
            useMeshProgram(gl, locs#mesh, lightView, identity);
            plan#plain |> List.forEach(drawBatch(gl, state, gen, locs#mesh, BatchBreak.ShadowPass));
            // 骨つきの物は曲がった形で影を落とす（深度だけの骨つきの版を Output.Depth と共用）。
            if (List.isEmpty(plan#skinned)) ()
            else {
                let skinnedDepth = skinnedProgramsOf(gl, state)#depth;
                if (skinnedDepth#mesh#program == 0) ()
                else {
                    useMeshProgram(gl, skinnedDepth#mesh, lightView, identity);
                    plan#skinned |> List.forEach(drawBatch(gl, state, gen, skinnedDepth#mesh, BatchBreak.ShadowPass))
                }
            }
        }

    def endShadowPass(gl: GlContext): Unit \ IO =
        gl.disable(GlConst.DEPTH_TEST);
        gl.disable(GlConst.CULL_FACE);
        gl.depthMask(true);
        gl.disable(GlConst.SCISSOR_TEST);
        gl.useProgram(0);
        gl.bindVertexArray(0)

    def shadowUseOf(state: State, target: ShadowTarget, caster: ShadowCaster, light: ShadowLight): Cast \ IO = match light {
        case ShadowLight.Spot(spotIndex) =>
            let r = caster#settings#pcfRadius;
            let radius = if (r > maxShadowPcfRadius()) {
                warnShadowOnce(state#planner, "pcf","scene3d: 影の pcfRadius ${r} は大きすぎる — ${maxShadowPcfRadius()} で数える");
                maxShadowPcfRadius()
            } else Int32.max(0, r);
            Cast.Spot({ tex = target#tex, matrix = matrixArray(caster#matrix), bias = caster#settings#bias,
                        pcfRadius = radius, strength = caster#settings#strength, spotIndex = spotIndex })
        case ShadowLight.Sun(setup) =>
            let f = setup#forward;
            Cast.Sun({ tex = target#tex, matrix = matrixArray(caster#matrix), bias = setup#depthBias, normalShift = setup#normalShift,
                       pcfRadius = setup#pcfRadius, strength = setup#strength,
                       forward = Array#{ RenderUtil.f32(f#x), RenderUtil.f32(f#y), RenderUtil.f32(f#z) } @ Static,
                       distance = setup#distance, fadeWidth = setup#fadeWidth })
    }

    /// 塗りの間だけ影の地図を影の unit（スポットは 7・太陽は 13）に貼る（unit 0 へ戻して返す）。None なら何もしない。
    pub def bindShadowMap(gl: GlContext, shadows: SceneShadows): Unit \ IO =
        shadows#spot |> Option.forEach(s -> bindToUnit(gl, shadowTextureUnit(), s#tex));
        shadows#sun |> Option.forEach(s -> bindToUnit(gl, sunShadowTextureUnit(), s#tex))

    /// 影の地図を外す — 次のコマに同じテクスチャを描き先に付けた時、貼ったままだと読み書きが重なる。
    pub def unbindShadowMap(gl: GlContext, shadows: SceneShadows): Unit \ IO =
        shadows#spot |> Option.forEach(_ -> bindToUnit(gl, shadowTextureUnit(), 0));
        shadows#sun |> Option.forEach(_ -> bindToUnit(gl, sunShadowTextureUnit(), 0))

    def bindToUnit(gl: GlContext, unit: Int32, tex: Int32): Unit \ IO =
        gl.activeTexture(GlConst.TEXTURE0 + unit);
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        gl.activeTexture(GlConst.TEXTURE0)

    pub def putShadow(gl: GlContext, locs: ShadowLocs, shadow: Option[ShadowUse]): Unit \ IO =
        // WhyNot: 影のある場面でだけ uShadowMap を入れない — 影の無い場面で unit 0 のままになり、描き先の色テクスチャが unit 0 に残ると、
        //   読まない枝でも WebGL2 が feedback loop と見て draw を止める。
        // WhyNot: 影の無い場面で影の unit を指さない — 何も貼っていない unit になり、macOS の GL が起動のたびにログへ書く。
        gl.uniform1i(locs#map, if (Option.isEmpty(shadow)) blankTextureUnit() else shadowTextureUnit());
        match shadow {
            // プログラムは場面どうしで共有するので、影の無い場面でも毎回切る（前の場面の影が残る）。
            case None    => gl.uniform1i(locs#on, 0)
            case Some(s) =>
                gl.uniform1i(locs#on, 1);
                gl.uniform1i(locs#spot, s#spotIndex);
                gl.uniformMatrix4fv(locs#matrix, false, s#matrix);
                gl.uniform1f(locs#bias, RenderUtil.f32(s#bias));
                gl.uniform1i(locs#pcf, s#pcfRadius);
                gl.uniform1f(locs#strength, RenderUtil.f32(s#strength))
        }

    /// 太陽の影の uniform を入れる（putShadow と同じ決まり。影の無い場面は uSunShadowOn = 0 で、uSunMap は何も貼っていない blank の unit を指す）。
    pub def putSunShadow(gl: GlContext, locs: SunShadowLocs, shadow: Option[SunShadowUse]): Unit \ IO =
        gl.uniform1i(locs#map, if (Option.isEmpty(shadow)) blankTextureUnit() else sunShadowTextureUnit());
        match shadow {
            case None    => gl.uniform1i(locs#on, 0)
            case Some(s) =>
                gl.uniform1i(locs#on, 1);
                gl.uniformMatrix4fv(locs#matrix, false, s#matrix);
                gl.uniform1f(locs#bias, RenderUtil.f32(s#bias));
                gl.uniform1f(locs#normalShift, RenderUtil.f32(s#normalShift));
                gl.uniform1i(locs#pcf, s#pcfRadius);
                gl.uniform1f(locs#strength, RenderUtil.f32(s#strength));
                gl.uniform3fv(locs#forward, s#forward);
                gl.uniform2f(locs#fade, RenderUtil.f32(s#distance), RenderUtil.f32(s#fadeWidth))
        }

    /// 使われない影の描き先を捨てる（画面のコマの終わりに 1 回）。
    pub def sweepShadowTargets(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        let targets = Ref.get(state#shadowTargetsRef);
        let idle = Map.filter(t -> gen - t#lastUsed > idleTargetFrames(), targets);
        if (Map.isEmpty(idle)) ()
        else {
            Map.forEach((_key, t) -> {
                gl.deleteFramebuffer(t#fbo);
                gl.deleteTexture(t#tex)
            }, idle);
            Ref.put(Map.difference(targets, idle), state#shadowTargetsRef)
        }

    pub def shadowLocsOf(gl: GlContext, program: Int32): Render3d.ShadowLocs \ IO =
        { on = Render3d.loc(gl, program, "uShadowOn"), spot = Render3d.loc(gl, program, "uShadowSpot"), matrix = Render3d.loc(gl, program, "uShadowMatrix"),
          map = Render3d.loc(gl, program, "uShadowMap"), bias = Render3d.loc(gl, program, "uShadowBias"), pcf = Render3d.loc(gl, program, "uShadowPcf"),
          strength = Render3d.loc(gl, program, "uShadowStrength") }

    pub def sunShadowLocsOf(gl: GlContext, program: Int32): Render3d.SunShadowLocs \ IO =
        { on = Render3d.loc(gl, program, "uSunShadowOn"), matrix = Render3d.loc(gl, program, "uSunMatrix"), map = Render3d.loc(gl, program, "uSunMap"),
          bias = Render3d.loc(gl, program, "uSunBias"), normalShift = Render3d.loc(gl, program, "uSunNormalShift"), pcf = Render3d.loc(gl, program, "uSunPcf"),
          strength = Render3d.loc(gl, program, "uSunStrength"), forward = Render3d.loc(gl, program, "uSunForward"), fade = Render3d.loc(gl, program, "uSunFade") }
}
