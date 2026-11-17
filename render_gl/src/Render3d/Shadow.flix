// Render3d.Shadow — 3D の描き手（Render3d）の影の地図の GL の backend（描き先の FBO・行を深度で描く・塗りへ渡す）。約束は Render3d.flix の頭と Scene3d.shadowMatrix の doc。
// どの描き先へ何を描くか（pass の計画）と描き先の寿命は前半の Render3d.ShadowMaps が決め、ここは鍵 → FBO だけを持つ。
mod Render3d.Shadow {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{BillboardLocs, PointShadowLocs, PointShadowUse, SceneShadows, ShadowLocs, SunShadowLocs, ShadowTarget, ShadowUse, SunShadowUse, State, MeshLocs, drawMeshRange, matrixArray, meshEntry,
                  programsOf, blankTextureUnit, pointShadowTextureUnit, shadowTextureUnit, sunShadowTextureUnit, skinnedProgramsOf, useMeshProgram, putBillboardShape}
    use Render3d.Counts.{BatchBreak, Counter, count, countDrawCall}
    use Render3d.SceneList.{SceneList, billboardAt, firstBillboardRowOf, firstBlendedRowOf, headAt, kindSkinned, rowAt, valuesAt}
    use Render3d.ShadowMaps.{Key, ShadowPass, ShadowSampling}

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
    /// textureOf = ビルボードの行の絵を引く元（全体の登録）。
    /// 点光源の影の atlas は鍵ごとに初めの面の前に 1 回だけ全体を消し、面ごとに viewport と scissor を面の塊に置いて描く。
    pub def renderShadows(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                          passes: List[List[ShadowPass]]): List[SceneShadows] \ IO =
        let cleared = Ref.fresh(Static, (Set.empty(): Set[Key]));
        let shadows = passes |> List.map(scenePasses -> {
            let casts = scenePasses |> List.filterMap(pass -> shadowTarget(gl, state, gen, pass#map#key) |> Option.map(target -> {
                let first = not Set.memberOf(pass#map#key, Ref.get(cleared));
                Ref.put(Set.insert(pass#map#key, Ref.get(cleared)), cleared);
                renderShadowMap(gl, state, gen, textureOf, target, pass, first);
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
    def createShadowTarget(gl: GlContext, extent: (Int32, Int32)): ShadowTarget \ IO =
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
    /// first = この描き先へ今の renderShadows で初めて描くか（atlas は初めての面の前だけ全体を消す）。
    def renderShadowMap(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                        target: ShadowTarget, pass: ShadowPass, first: Bool): Unit \ IO =
        let locs = programsOf(gl, state)#depth;
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, target#fbo);
        match pass#map#tile {
            case None    => clearWholeTarget(gl, target)
            case Some(t) => beginTile(gl, t, first)
        };
        if (locs#mesh#program == 0) ()
        else {
            gl.enable(GlConst.DEPTH_TEST);
            gl.depthFunc(GlConst.LESS);
            // WhyNot: 背面を捨てない — 厚みの無い板を裏から照らすと面が全部捨てられ、影が抜ける。
            gl.disable(GlConst.CULL_FACE);
            // WhyNot: 深度だけのプログラムを影のために別に組まない — 色の出力は描き先が無いので捨てられる。
            let frame = { list = pass#list, lightView = matrixArray(pass#map#view), identity = matrixArray(Mat4.identity()), bound = Array#{locs#mesh#program} @ Static };
            useMeshProgram(gl, locs#mesh, frame#lightView, frame#identity);
            drawShadowRows(gl, state, gen, frame, 0, firstBillboardRowOf(pass#list));
            drawShadowBillboards(gl, state, textureOf, frame, pass)
        }

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

    /// 行 list のビルボードの行を、ビルボードのプログラムで影の地図へ描く: 板の横は pass#billboardRight・縦は world の上・目は光の行列（射影は単位行列）。
    /// uDepthOut = 1 で、絵の α < 0.5 の画素を捨てた後に色を出さずに返る（描き先に色は無い）。絵の無い行は描かない（知らせは場面の行が出す）。
    // WhyNot: 影の地図のためのビルボードのプログラムを別に組まない — 色の段を捨てる描き先で、α で捨てる所まではビルボードのプログラムと同じ。
    // WhyNot: uSunMap を描いている地図の unit へ向けたままにしない — 読まない枝でも、描き先に付けた絵を sampler が指すと WebGL2 が feedback loop と見て draw を止める。
    def drawShadowBillboards(gl: GlContext, state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                             frame: ShadowFrame, pass: ShadowPass): Unit \ IO =
        let list = pass#list;
        let first = firstBillboardRowOf(list);
        let end = firstBlendedRowOf(list);
        let locs = programsOf(gl, state)#billboard;
        if (first >= end or locs#program == 0) ()
        else {
            gl.useProgram(locs#program);
            Array.put(locs#program, 0, frame#bound);
            gl.uniformMatrix4fv(locs#view, false, frame#lightView);
            gl.uniformMatrix4fv(locs#proj, false, frame#identity);
            putSunShadow(gl, locs#sunShadow, None);
            gl.uniform1i(locs#depthOut, 1);
            gl.uniform1i(locs#lit, 0);
            gl.uniform1i(locs#receive, 0);
            let right = pass#billboardRight;
            gl.uniform3f(locs#right, RenderUtil.f32(right#x), RenderUtil.f32(right#y), RenderUtil.f32(right#z));
            gl.uniform3f(locs#up, 0.0f32, 1.0f32, 0.0f32);
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindVertexArray(programsOf(gl, state)#quadVao);
            List.range(first, end) |> List.forEach(row -> {
                if (pass#rightPerBillboard) putRowRight(gl, locs, list, row) else ();
                drawShadowBillboard(gl, state, textureOf, locs, billboardAt(list, row))
            });
            gl.bindVertexArray(0)
        }

    /// 行 row の板の横の向き（Render3d.SceneList.putBillboardRights が値に入れた物）を uRight に入れる（値の無い行は描かないので何もしない）。
    def putRowRight(gl: GlContext, locs: BillboardLocs, list: SceneList, row: Int32): Unit \ IO =
        let at = valuesAt(list, row);
        if (at < 0) ()
        else gl.uniform3f(locs#right, Array.get(at + 12, list#values), Array.get(at + 13, list#values), Array.get(at + 14, list#values))

    def drawShadowBillboard(gl: GlContext, state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, locs: BillboardLocs,
                            b: Scene3d.BillboardFields): Unit \ IO =
        textureOf(b#texture) |> Option.forEach(texture -> {
            putBillboardShape(gl, locs, texture, b);
            gl.drawArrays(GlConst.TRIANGLES, 0, 6);
            countDrawCall(state, BatchBreak.ShadowPass)
        })

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
        let mesh = shadowLocsFor(gl, state, rowAt(list, row, 0) == kindSkinned());
        if (mesh#program == 0) ()
        else {
            if (mesh#program == Array.get(0, frame#bound)) ()
            else {
                Array.put(mesh#program, 0, frame#bound);
                useMeshProgram(gl, mesh, frame#lightView, frame#identity)
            };
            let entry = meshEntry(gl, state, gen, headAt(list, row)#fields#mesh);
            drawMeshRange(gl, state, mesh, rowAt(list, row, 5), (entry#vao, entry#indexCount), rowAt(list, row, 3), rowAt(list, row, 4))
        };
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で drawShadowRows のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// 骨つきの版は骨つきの行がある時だけ組む。
    def shadowLocsFor(gl: GlContext, state: State, skinned: Bool): MeshLocs \ IO =
        if (skinned) skinnedProgramsOf(gl, state)#depth#mesh else programsOf(gl, state)#depth#mesh

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

    /// 点光源の影の uniform を入れる（putShadow と同じ決まり。変種 +ps でないプログラムは何もしない・影の無い場面は全部の slot が −1 で、
    /// uPointShadowMap は何も貼っていない blank の unit を指す）。
    pub def putPointShadow(gl: GlContext, locs: PointShadowLocs, shadow: Option[PointShadowUse]): Unit \ IO =
        if (locs#map < 0) ()
        else {
            gl.uniform1i(locs#map, if (Option.isEmpty(shadow)) blankTextureUnit() else pointShadowTextureUnit());
            match shadow {
                case None    => locs#lights |> Vector.forEach(l -> gl.uniform4f(l, -1.0f32, 0.0f32, 0.0f32, 0.0f32))
                case Some(s) =>
                    Vector.zip(locs#lights, s#lights) |> Vector.forEach(lc -> {
                        let (l, (slot, a, b, strength)) = lc;
                        gl.uniform4f(l, slot, a, b, strength)
                    });
                    let (size, columns, scale, pcf) = s#atlas;
                    gl.uniform4f(locs#atlas, size, columns, scale, pcf);
                    let (bias, normalBias) = s#bias;
                    gl.uniform2f(locs#bias, bias, normalBias)
            }
        }

    /// 変種 +ps でないプログラムの点光源の影の location（putPointShadow が何もしない）。
    pub def noPointShadowLocs(): PointShadowLocs = { lights = Vector.empty(), atlas = -1, bias = -1, map = -1 }

    pub def pointShadowLocsOf(gl: GlContext, program: Int32): PointShadowLocs \ IO =
        { lights = Vector.range(0, Scene3d.maxPointLights()) |> Vector.map(i -> Render3d.loc(gl, program, "uPointShadow[${i}]")),
          atlas = Render3d.loc(gl, program, "uPointShadowAtlas"), bias = Render3d.loc(gl, program, "uPointShadowBias"),
          map = Render3d.loc(gl, program, "uPointShadowMap") }

    /// 使われない影の描き先を捨てる（画面のコマの終わりに 1 回・どれを捨てるかは寿命の表）。
    pub def sweepShadowTargets(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        discard Render3d.ShadowMaps.sweep(state#shadowMaps, allocatorOf(gl, state), gen)

    pub def shadowLocsOf(gl: GlContext, program: Int32): Render3d.ShadowLocs \ IO =
        { on = Render3d.loc(gl, program, "uShadowOn"), spot = Render3d.loc(gl, program, "uShadowSpot"), matrix = Render3d.loc(gl, program, "uShadowMatrix"),
          map = Render3d.loc(gl, program, "uShadowMap"), bias = Render3d.loc(gl, program, "uShadowBias"), pcf = Render3d.loc(gl, program, "uShadowPcf"),
          strength = Render3d.loc(gl, program, "uShadowStrength") }

    pub def sunShadowLocsOf(gl: GlContext, program: Int32): Render3d.SunShadowLocs \ IO =
        { on = Render3d.loc(gl, program, "uSunShadowOn"), matrix = Render3d.loc(gl, program, "uSunMatrix"), map = Render3d.loc(gl, program, "uSunMap"),
          bias = Render3d.loc(gl, program, "uSunBias"), normalShift = Render3d.loc(gl, program, "uSunNormalShift"), pcf = Render3d.loc(gl, program, "uSunPcf"),
          strength = Render3d.loc(gl, program, "uSunStrength"), forward = Render3d.loc(gl, program, "uSunForward"), fade = Render3d.loc(gl, program, "uSunFade") }
}
