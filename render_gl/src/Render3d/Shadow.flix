// Render3d.Shadow — 3D の描き手（Render3d）の影の地図の GL の backend（描き先の FBO・行を深度で描く・塗りへ渡す）。約束は Render3d.flix の頭と Scene3d.shadowMatrix の doc。
// どの描き先へ何を描くか（pass の計画）と描き先の寿命は前半の Render3d.ShadowMaps が決め、ここは鍵 → FBO だけを持つ。
mod Render3d.Shadow {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{PointShadowUse, ProgramUniforms, SceneShadows, ShadowTarget, ShadowUse, SunShadowUse, State, drawMeshRange, matrixArray, meshEntry,
                  programsOf, blankTextureUnit, pointShadowTextureUnit, shadowTextureUnit, sunShadowTextureUnit, skinnedProgramsOf, useMeshProgram}
    use Render3d.GlRows.{drawBillboardRuns}
    use Render3d.Counts.{BatchBreak, Counter, count, countDrawCall}
    use Render3d.SceneList.{SceneList, SceneRowKind, billboardAt, breakSlotAt, countAt, firstBillboardRowOf, firstBlendedRowOf, firstInstanceAt, headAt, kindAt, rowCountOf, valuesAt}
    use Render3d.ShadowMaps.{Key, ShadowPass, ShadowSampling}
    use Render3d.Uniforms.{R3dUniform, UniformLocations, has, put1f, put1i, put2f, put3f, put3fv, put4f, putMatrix4}

    // ── 影の地図 ──

    /// 描いた影の地図 1 枚（塗りへ渡す物）。
    enum Cast {
        case Spot(ShadowUse)
        case Sun(SunShadowUse)
        case Point(Int32, Scene3d.PointShadows.Atlas)
    }

    /// 場面ごとに、passes（場面と同じ並び・Render3d.ShadowMaps.buildPasses の答え）の影の地図を描き、塗りへ渡す物を返す。骨つきの物は今 joint の unit に貼ってある joint texture を読む。
    /// 描き終えたら深度と scissor を切り、program と VAO を外す。描き先は呼ぶ側が戻す。
    // WhyNot: viewport をここで戻さない — glGet で前の値を読まない決まりで、この後に描く Design の場面と
    //   2D の並び（RenderFrame.renderFrameMixed）が、どちらも描き始めに自分の viewport を置く。
    /// ビルボードの行は行に入れた絵の番号（行を作る時に全体の登録から引いた物）で描く。
    /// 点光源の影の atlas は鍵ごとに初めの面の前に 1 回だけ全体を消し、面ごとに viewport と scissor を面の塊に置いて描く。
    /// passes の組の 2 つ目 = 場面の持ち越した集まり（影の行を場面の行の後に描く）・instanceTexture = その prepare の 1 体ごとの値のテクスチャ（集まりの行を描いた後に貼り直す）。
    /// measure = 地図 1 枚（atlas は面 1 つ）を描く GPU の時間を光の種類の区間（Render3d.GpuSpans.shadowSpanOf）として測る関数（Scene3dRenderer.Dest#measure）。
    pub def renderShadows(gl: GlContext, state: State, gen: Int64, instanceTexture: Option[Int32], measure: (String, Unit -> Unit \ IO) -> Unit \ IO,
                          passes: List[(List[ShadowPass], List[Render3d.GlStatic.CarriedDraw])]): List[SceneShadows] \ IO =
        let cleared = Ref.fresh(Static, (Set.empty(): Set[Key]));
        let shadows = passes |> List.map(pc -> {
            let (scenePasses, carried) = pc;
            let casts = scenePasses |> List.filterMap(pass -> shadowTarget(gl, state, gen, pass#map#key) |> Option.map(target -> {
                let first = not Set.memberOf(pass#map#key, Ref.get(cleared));
                Ref.put(Set.insert(pass#map#key, Ref.get(cleared)), cleared);
                measure(Render3d.GpuSpans.shadowSpanOf(pass#map#sampling), () ->
                    renderShadowMap(gl, state, gen, target, pass, first, { carried = carried, restore = instanceTexture }));
                castOf(target, pass#map#sampling)
            }));
            { spot = List.findMap(spotOf, casts), sun = List.findMap(sunOf, casts), point = List.findMap(pointOf, casts) }
        });
        if (List.exists(s -> Option.nonEmpty(s#spot) or Option.nonEmpty(s#sun) or Option.nonEmpty(s#point), shadows)) endShadowPass(gl) else ();
        shadows

    def spotOf(c: Cast): Option[ShadowUse] = match c {
        case Cast.Spot(shadow) => Some(shadow)
        case Cast.Sun(_)       => None
        case Cast.Point(_, _)  => None
    }

    def sunOf(c: Cast): Option[SunShadowUse] = match c {
        case Cast.Sun(shadow)  => Some(shadow)
        case Cast.Spot(_)      => None
        case Cast.Point(_, _)  => None
    }

    def pointOf(c: Cast): Option[PointShadowUse] = match c {
        case Cast.Point(tex, atlas) => Some(pointShadowUseOf(tex, atlas))
        case Cast.Spot(_)           => None
        case Cast.Sun(_)            => None
    }

    /// atlas（描いた深度テクスチャ tex）を塗りのシェーダーの uniform の並びにする。点光源の番号 i の (slot, A, B, strength)・影を落とさない灯りは slot −1。
    pub def pointShadowUseOf(tex: Int32, atlas: Scene3d.PointShadows.Atlas): PointShadowUse =
        let f = RenderUtil.f32;
        let byIndex = atlas#lights |> List.map(l -> (l#pointIndex, l)) |> List.toMap;
        let lights = Vector.range(0, Scene3d.maxPointLights()) |> Vector.map(i -> match Map.get(i, byIndex) {
            case None    => (-1.0f32, 0.0f32, 0.0f32, 0.0f32)
            case Some(l) =>
                let (a, b) = Scene3d.PointShadows.depthTermsOf(l);
                (Int32.toFloat32(l#slot), f(a), f(b), f(l#strength))
        });
        { tex = tex, lights = lights,
          atlas = (Int32.toFloat32(atlas#tileSize), Int32.toFloat32(atlas#blocksPerRow), f(atlas#guardScale), Int32.toFloat32(atlas#pcfRadius)),
          bias = (f(atlas#bias), f(atlas#normalBias)) }

    /// 鍵 key の影の描き先（無ければ寿命の表が作らせる。引けない鍵は None で、その地図は描かない）。
    // WhyNot: 引けない時に fbo 0 の描き先で続けない — 深度を画面の framebuffer へ描き、WebGPU の backend（描かずに飛ばす）と振る舞いが分かれる。
    def shadowTarget(gl: GlContext, state: State, gen: Int64, key: Key): Option[ShadowTarget] \ IO =
        discard Render3d.ShadowMaps.ensure(state#shadowMaps, allocatorOf(gl, state), gen, key);
        Map.get(key, Ref.get(state#shadowTargetsRef))

    /// 寿命の表（Render3d.ShadowMaps）へ渡す、GL の影の描き先を作る・捨てる関数の組。
    def allocatorOf(gl: GlContext, state: State): Render3d.ShadowMaps.Allocator =
        { create = key -> {
              count(state, Counter.TargetRebuilds, 1);
              let made = createShadowTarget(gl, Render3d.ShadowMaps.extentOf(key));
              Ref.put(Map.insert(key, made, Ref.get(state#shadowTargetsRef)), state#shadowTargetsRef)
          },
          destroy = key -> {
              Map.get(key, Ref.get(state#shadowTargetsRef)) |> Option.forEach(t -> {
                  gl.deleteFramebuffer(t#fbo);
                  gl.deleteTexture(t#tex)
              });
              Ref.put(Map.remove(key, Ref.get(state#shadowTargetsRef)), state#shadowTargetsRef)
          } }

    /// 深度テクスチャだけを付けた FBO を作る（作った FBO を bind したまま返す）。
    // WhyNot: 深度を renderbuffer にしない — 塗りのシェーダーが標本として読む。
    // WhyNot: 比べを sampler2DShadow（GL_COMPARE_REF_TO_TEXTURE）に任せない — 比べ方と周りの数え方を CPU の描き手とそろえる。
    pub def createShadowTarget(gl: GlContext, extent: (Int32, Int32)): ShadowTarget \ IO =
        let (width, height) = extent;
        // 作る間の bind で unit 0（sprite・font が共用する）の中身を替えない。
        gl.activeTexture(GlConst.TEXTURE0 + shadowTextureUnit());
        let tex = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        gl.texImageDepth24(width, height);
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
        checkShadowFramebuffer(gl, width, height);
        { fbo = fbo, tex = tex, width = width, height = height }

    def checkShadowFramebuffer(gl: GlContext, width: Int32, height: Int32): Unit \ IO =
        let status = gl.checkFramebufferStatus(GlConst.FRAMEBUFFER);
        if (status != GlConst.FRAMEBUFFER_COMPLETE)
            Log.warn("scene3d: 影の地図の FBO (${width}×${height}) が完成しない status=${status} — 影が正しく出ない")
        else ()

    /// 影の地図を描く: 光から見た置いた物の一番近い面の深度。行は骨の無い物 → 骨つきの物 → castShadows のビルボードの順（Render3d.SceneList.buildShadowList）。
    /// first = この描き先へ今の renderShadows で初めて描くか（atlas は初めての面の前だけ全体を消す）・
    /// carried = 場面の持ち越した集まり（場面の行の後にその影の行を描く）と、描いた後に貼り直す 1 体ごとの値のテクスチャ restore。
    /// 集まりの行は、動かない物だけの控え（Render3d.GlShadowCache）に描いて写す。鍵が前と同じなら控えを描き直さずに写すだけ。
    def renderShadowMap(gl: GlContext, state: State, gen: Int64, target: ShadowTarget, pass: ShadowPass, first: Bool,
                        carried: { carried = List[Render3d.GlStatic.CarriedDraw], restore = Option[Int32] }): Unit \ IO =
        let depth = programsOf(gl, state)#depth;
        let drawable = depth#program != 0 and not Render3d.GpuSpans.skipsShadowDraws();
        let frame = { list = pass#list, lightView = matrixArray(pass#map#view), identity = matrixArray(Mat4.identity()), bound = Array#{depth#program} @ Static };
        let cached = if (drawable) cacheOf(gl, state, gen, pass, carried#carried) else None;
        cached |> Option.forEach(match (e, made) -> if (made) drawStaticsInto(gl, state, gen, e, frame, carried) else ());
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, target#fbo);
        match pass#map#tile {
            case None    => clearWholeTarget(gl, target)
            case Some(t) => beginTile(gl, t, first)
        };
        let (ox, oy) = pass#map#tile |> Option.map(t -> (t#x, t#y)) |> Option.getWithDefault((0, 0));
        cached |> Option.forEach(match (e, _) -> Render3d.GlShadowCache.copyInto(gl, e, target, ox, oy));
        if (not drawable) ()
        else {
            beginDepthOnly(gl);
            useMeshProgram(gl, depth, frame#lightView, frame#identity);
            Array.put(depth#program, 0, frame#bound);
            drawShadowRows(gl, state, gen, frame, 0, firstBillboardRowOf(pass#list));
            if (Option.isEmpty(cached)) drawCarriedShadows(gl, state, gen, frame, carried) else ();
            drawShadowBillboards(gl, state, frame, pass)
        }

    /// 深度だけを LESS で描く状態にする。
    // WhyNot: 深度だけのプログラムを影のために別に組まない — 色の出力は描き先が無いので捨てられる。
    def beginDepthOnly(gl: GlContext): Unit \ IO =
        gl.enable(GlConst.DEPTH_TEST);
        gl.depthFunc(GlConst.LESS);
        // WhyNot: 背面を捨てない — 厚みの無い板を裏から照らすと面が全部捨てられ、影が抜ける。
        gl.disable(GlConst.CULL_FACE)

    /// 持ち越した集まりの影の行を描く（今の描き先・今のプログラムのまま）。
    def drawCarriedShadows(gl: GlContext, state: State, gen: Int64, frame: ShadowFrame,
                           carried: { carried = List[Render3d.GlStatic.CarriedDraw], restore = Option[Int32] }): Unit \ IO =
        Render3d.GlStatic.withValues(gl, carried#restore, c -> {
            let shadowList = c#carried#rows#shadowList;
            drawShadowRows(gl, state, gen, { list = shadowList | frame }, 0, rowCountOf(shadowList))
        }, carried#carried)

    /// 場面に持ち越した集まりがあれば、pass の地図（atlas は面）の動かない物だけの控えと、今作ったか（作った控えは中身が無い）。
    /// 集まりが無い場面と、試しの旗 FLIX_GE_SHADOW_CACHE=off の時は None（毎コマ集まりも描く）。
    def cacheOf(gl: GlContext, state: State, gen: Int64, pass: ShadowPass, carried: List[Render3d.GlStatic.CarriedDraw]): Option[(Render3d.GlShadowCache.Entry, Bool)] \ IO =
        if (List.isEmpty(carried) or Render3d.GpuSpans.isShadowCacheOff()) None
        else {
            let size = Render3d.ShadowMaps.cacheSizeOf(pass);
            let key = Render3d.ShadowMaps.cacheKeyOf(size, pass, Render3d.GlStatic.keyOfCarried(carried));
            let found = Render3d.GlShadowCache.ensure(gl, state#statics#shadowCache, gen, key, size);
            Render3d.Counts.noteShadowCache(state, snd(found));
            Some(found)
        }

    /// 控え e へ動かない物だけを描く（深度を 1 で消し、控えの全体を viewport にする）。
    def drawStaticsInto(gl: GlContext, state: State, gen: Int64, e: Render3d.GlShadowCache.Entry, frame: ShadowFrame,
                        carried: { carried = List[Render3d.GlStatic.CarriedDraw], restore = Option[Int32] }): Unit \ IO =
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, e#target#fbo);
        clearWholeTarget(gl, e#target);
        beginDepthOnly(gl);
        useMeshProgram(gl, programsOf(gl, state)#depth, frame#lightView, frame#identity);
        Array.put(programsOf(gl, state)#depth#program, 0, frame#bound);
        drawCarriedShadows(gl, state, gen, frame, carried)

    def clearWholeTarget(gl: GlContext, target: ShadowTarget): Unit \ IO =
        gl.viewport(0, 0, target#width, target#height);
        gl.disable(GlConst.SCISSOR_TEST);
        gl.depthMask(true);
        gl.clearDepth(1.0);
        gl.clear(GlConst.DEPTH_BUFFER_BIT)

    /// atlas の面の塊 t へ描き始める（first なら先に atlas の全体を消す）。
    // WhyNot: viewport だけで面を分けない — 三角形は viewport の外へ切られるが、描き先の外周の画素の丸めを scissor でも止めておく（面どうしの深度が混ざると継ぎ目に筋が出る）。
    def beginTile(gl: GlContext, t: Render3d.ShadowMaps.Tile, first: Bool): Unit \ IO =
        gl.depthMask(true);
        if (first) {
            gl.disable(GlConst.SCISSOR_TEST);
            gl.clearDepth(1.0);
            gl.clear(GlConst.DEPTH_BUFFER_BIT)
        } else ();
        gl.viewport(t#x, t#y, t#size, t#size);
        gl.enable(GlConst.SCISSOR_TEST);
        gl.scissor(t#x, t#y, t#size, t#size)

    /// 行 list のビルボードの行を、ビルボードのプログラムで影の地図へ描く: 板の横は pass#billboardRight（点光源の面は板ごとの値の向き）・縦は world の上・目は光の行列（射影は単位行列）。
    /// uDepthOut = 1 で、絵の α < 0.5 の画素を捨てた後に色を出さずに返る（描き先に色は無い）。同じ絵の板の並びを 1 回の instanced draw で描く（Render3d.GlRows.drawBillboardRuns）。
    // WhyNot: 影の地図のためのビルボードのプログラムを別に組まない — 色の段を捨てる描き先で、α で捨てる所まではビルボードのプログラムと同じ。
    // WhyNot: uSunMap を描いている地図の unit へ向けたままにしない — 読まない枝でも、描き先に付けた絵を sampler が指すと WebGL2 が feedback loop と見て draw を止める。
    def drawShadowBillboards(gl: GlContext, state: State, frame: ShadowFrame, pass: ShadowPass): Unit \ IO =
        let list = pass#list;
        let first = firstBillboardRowOf(list);
        let end = firstBlendedRowOf(list);
        let billboard = programsOf(gl, state)#billboard;
        if (first >= end or billboard#program == 0) ()
        else {
            let locs = billboard#locs;
            useMeshProgram(gl, billboard, frame#lightView, frame#identity);
            Array.put(billboard#program, 0, frame#bound);
            putSunShadow(gl, locs, None);
            put1i(gl, locs, R3dUniform.DepthOut, 1);
            let right = pass#billboardRight;
            put3f(gl, locs, R3dUniform.Right, RenderUtil.f32(right#x), RenderUtil.f32(right#y), RenderUtil.f32(right#z));
            put3f(gl, locs, R3dUniform.Up, 0.0f32, 1.0f32, 0.0f32);
            put1i(gl, locs, R3dUniform.RightPerBillboard, if (pass#rightPerBillboard) 1 else 0);
            drawBillboardRuns(gl, state, list, BatchBreak.ShadowPass)
        }

    /// drawShadowRows の 1 回で行をまたいで変わらない物。bound = 今付いているプログラム（要素 1 つ）。
    type alias ShadowFrame = { list = SceneList, lightView = Array[Float32, Static], identity = Array[Float32, Static], bound = Array[Int32, Static] }

    def drawShadowRows(gl: GlContext, state: State, gen: Int64, frame: ShadowFrame, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawShadowRow(gl, state, gen, frame, row);
            drawShadowRows(gl, state, gen, frame, row + 1, n)
        }

    /// 行 row を深度だけのプログラムで描く。骨つきの行は骨つきの版（Output.Depth と共用）で、曲がった形で影を落とす。描く物の無い行も形を今のコマで使った物として数える。
    def drawShadowRow(gl: GlContext, state: State, gen: Int64, frame: ShadowFrame, row: Int32): Unit \ IO =
        let list = frame#list;
        let mesh = shadowProgramFor(gl, state, kindAt(list, row) == SceneRowKind.Skinned);
        if (mesh#program == 0) ()
        else {
            if (mesh#program == Array.get(0, frame#bound)) ()
            else {
                Array.put(mesh#program, 0, frame#bound);
                useMeshProgram(gl, mesh, frame#lightView, frame#identity)
            };
            let entry = meshEntry(gl, state, gen, headAt(list, row)#fields#mesh);
            drawMeshRange(gl, state, mesh#locs, breakSlotAt(list, row), (entry#vao, entry#indexCount), firstInstanceAt(list, row), countAt(list, row))
        };
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で drawShadowRows のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// 骨つきの版は骨つきの行がある時だけ組む。
    def shadowProgramFor(gl: GlContext, state: State, skinned: Bool): ProgramUniforms \ IO =
        if (skinned) skinnedProgramsOf(gl, state)#depth else programsOf(gl, state)#depth

    def endShadowPass(gl: GlContext): Unit \ IO =
        gl.disable(GlConst.DEPTH_TEST);
        gl.disable(GlConst.CULL_FACE);
        gl.depthMask(true);
        gl.disable(GlConst.SCISSOR_TEST);
        gl.useProgram(0);
        gl.bindVertexArray(0)

    /// 描いた地図 target と、色の pass が引く値 sampling（Render3d.ShadowMaps.assign が頭打ちにした値）を塗りへ渡す形にする。
    def castOf(target: ShadowTarget, sampling: ShadowSampling): Cast \ IO = match sampling {
        case ShadowSampling.Point(atlas) => Cast.Point(target#tex, atlas)
        case ShadowSampling.Spot(s) =>
            Cast.Spot({ tex = target#tex, matrix = matrixArray(s#matrix), bias = s#bias, pcfRadius = s#pcfRadius, strength = s#strength, spotIndex = s#spotIndex })
        case ShadowSampling.Sun(s) =>
            let f = s#forward;
            Cast.Sun({ tex = target#tex, matrix = matrixArray(s#matrix), bias = s#bias, normalShift = s#normalShift,
                       pcfRadius = s#pcfRadius, strength = s#strength,
                       forward = Array#{ RenderUtil.f32(f#x), RenderUtil.f32(f#y), RenderUtil.f32(f#z) } @ Static,
                       distance = s#distance, fadeWidth = s#fadeWidth })
    }

    /// 塗りの間だけ影の地図を影の unit（スポットは 7・太陽は 13・点光源の atlas は 14）に貼る（unit 0 へ戻して返す）。None なら何もしない。
    pub def bindShadowMap(gl: GlContext, shadows: SceneShadows): Unit \ IO =
        shadows#spot |> Option.forEach(s -> bindToUnit(gl, shadowTextureUnit(), s#tex));
        shadows#sun |> Option.forEach(s -> bindToUnit(gl, sunShadowTextureUnit(), s#tex));
        shadows#point |> Option.forEach(s -> bindToUnit(gl, pointShadowTextureUnit(), s#tex))

    /// 影の地図を外す — 次のコマに同じテクスチャを描き先に付けた時、貼ったままだと読み書きが重なる。
    pub def unbindShadowMap(gl: GlContext, shadows: SceneShadows): Unit \ IO =
        shadows#spot |> Option.forEach(_ -> bindToUnit(gl, shadowTextureUnit(), 0));
        shadows#sun |> Option.forEach(_ -> bindToUnit(gl, sunShadowTextureUnit(), 0));
        shadows#point |> Option.forEach(_ -> bindToUnit(gl, pointShadowTextureUnit(), 0))

    def bindToUnit(gl: GlContext, unit: Int32, tex: Int32): Unit \ IO =
        gl.activeTexture(GlConst.TEXTURE0 + unit);
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        gl.activeTexture(GlConst.TEXTURE0)

    pub def putShadow(gl: GlContext, locs: UniformLocations, shadow: Option[ShadowUse]): Unit \ IO =
        // WhyNot: 影のある場面でだけ uShadowMap を入れない — 影の無い場面で unit 0 のままになり、描き先の色テクスチャが unit 0 に残ると、
        //   読まない枝でも WebGL2 が feedback loop と見て draw を止める。
        // WhyNot: 影の無い場面で影の unit を指さない — 何も貼っていない unit になり、macOS の GL が起動のたびにログへ書く。
        put1i(gl, locs, R3dUniform.ShadowMap, if (Option.isEmpty(shadow)) blankTextureUnit() else shadowTextureUnit());
        match shadow {
            // プログラムは場面どうしで共有するので、影の無い場面でも毎回切る（前の場面の影が残る）。
            case None    => put1i(gl, locs, R3dUniform.ShadowOn, 0)
            case Some(s) =>
                put1i(gl, locs, R3dUniform.ShadowOn, 1);
                put1i(gl, locs, R3dUniform.ShadowSpot, s#spotIndex);
                putMatrix4(gl, locs, R3dUniform.ShadowMatrix, s#matrix);
                put1f(gl, locs, R3dUniform.ShadowBias, RenderUtil.f32(s#bias));
                put1i(gl, locs, R3dUniform.ShadowPcf, s#pcfRadius);
                put1f(gl, locs, R3dUniform.ShadowStrength, RenderUtil.f32(s#strength))
        }

    /// 太陽の影の uniform を入れる（putShadow と同じ決まり。影の無い場面は uSunShadowOn = 0 で、uSunMap は何も貼っていない blank の unit を指す）。
    pub def putSunShadow(gl: GlContext, locs: UniformLocations, shadow: Option[SunShadowUse]): Unit \ IO =
        put1i(gl, locs, R3dUniform.SunMap, if (Option.isEmpty(shadow)) blankTextureUnit() else sunShadowTextureUnit());
        match shadow {
            case None    => put1i(gl, locs, R3dUniform.SunShadowOn, 0)
            case Some(s) =>
                put1i(gl, locs, R3dUniform.SunShadowOn, 1);
                putMatrix4(gl, locs, R3dUniform.SunMatrix, s#matrix);
                put1f(gl, locs, R3dUniform.SunBias, RenderUtil.f32(s#bias));
                put1f(gl, locs, R3dUniform.SunNormalShift, RenderUtil.f32(s#normalShift));
                put1i(gl, locs, R3dUniform.SunPcf, s#pcfRadius);
                put1f(gl, locs, R3dUniform.SunStrength, RenderUtil.f32(s#strength));
                put3fv(gl, locs, R3dUniform.SunForward, s#forward);
                put2f(gl, locs, R3dUniform.SunFade, RenderUtil.f32(s#distance), RenderUtil.f32(s#fadeWidth))
        }

    /// 点光源の影の uniform を入れる（putShadow と同じ決まり。変種 +ps でないプログラムは何もしない・影の無い場面は全部の slot が −1 で、
    /// uPointShadowMap は何も貼っていない blank の unit を指す）。
    pub def putPointShadow(gl: GlContext, locs: UniformLocations, shadow: Option[PointShadowUse]): Unit \ IO =
        if (not has(R3dUniform.PointShadowMap, locs)) ()
        else {
            put1i(gl, locs, R3dUniform.PointShadowMap, if (Option.isEmpty(shadow)) blankTextureUnit() else pointShadowTextureUnit());
            match shadow {
                case None    => putPointShadowsOff(gl, locs, 0)
                case Some(s) =>
                    s#lights |> Vector.forEachWithIndex((i, l) -> {
                        let (slot, a, b, strength) = l;
                        put4f(gl, locs, R3dUniform.PointShadow(i), slot, a, b, strength)
                    });
                    let (size, columns, scale, pcf) = s#atlas;
                    put4f(gl, locs, R3dUniform.PointShadowAtlas, size, columns, scale, pcf);
                    let (bias, normalBias) = s#bias;
                    put2f(gl, locs, R3dUniform.PointShadowBias, bias, normalBias)
            }
        }

    /// uPointShadow[i..] の slot を全部 −1（影を落とさない）にする。
    def putPointShadowsOff(gl: GlContext, locs: UniformLocations, i: Int32): Unit \ IO =
        if (i >= Scene3d.maxPointLights()) ()
        else {
            put4f(gl, locs, R3dUniform.PointShadow(i), -1.0f32, 0.0f32, 0.0f32, 0.0f32);
            putPointShadowsOff(gl, locs, i + 1)
        }

    /// 使われない影の描き先を捨てる（画面のコマの終わりに 1 回・どれを捨てるかは寿命の表）。
    pub def sweepShadowTargets(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        discard Render3d.ShadowMaps.sweep(state#shadowMaps, allocatorOf(gl, state), gen)
}
