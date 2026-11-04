// Render3d.Material — 3D の描き手（Render3d）の材質のある置いた物（材質のプログラムと鍵・場面の絵の置き場・描き方）。約束は Render3d.flix の頭。
mod Render3d.Material {
    import fge.gl.GlContext
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.opengl.GL13
    import org.lwjgl.opengl.GL20
    import org.lwjgl.opengl.GL33
    import org.lwjgl.system.MemoryUtil
    use Render3d.Shadow.{putShadow}
    use Render3dGlsl.{materialFragmentSource, materialVertexSource}
    use Render3d.Light.{putLights}
    use Render3d.{materialKey, ProgramKind, BoundTexture, CameraData, MaterialDraw, MaterialEntry, MaterialLocs,
                  MaterialPass, MeshDraw, State, Texture3dEntry, TextureSource, bindJointsBlock, drawPosedMesh, hasUv, isSkinned,
                  lightLocsOf, lightmapTextureUnit, loc, meshDrawOf, meshIdleFrames, meshLocsOf, normalMapTextureUnit, putLinearizedColor,
                  putDepthRange, shadowLocsOf, useMeshProgram, warnSceneOnce}
    use Scene3dRenderer.{RegisteredTexture}

    // ── 材質のある置いた物 ──

    /// 置いた物を、頂点の色で描く物と材質のプログラムで描く物に分ける。wants が偽の材質と、組めなかった材質は頂点の色の側へ。
    /// 初めての材質はここで組む（3D を使わないゲームと、材質を使わない場面は GLSL のコンパイルを払わない）。
    /// outside = 描かずに済ませる物か（視錐台の外。MeshDraw の culled になる）。間引く物の材質も組む（間引くのは描く段の手前）。
    // WhyNot: 間引いた物を材質の組み立ての前に除かない — 初めて振り向いたコマで GLSL を組んで止まる（読み込み中に先に組ませる作りが効かない）。
    /// coverage = 描き先が標本を持ち、色の段で描く（cutout の材質を alpha to coverage の版で組む）。
    pub def splitByMaterial(gl: GlContext, state: State, gen: Int64, outside: Scene3d.Instance3d -> Bool, wants: Scene3d.MaterialFields -> Bool, coverage: Bool,
                        instances: List[Scene3d.Instance3d]): (List[MeshDraw], List[MaterialDraw]) \ IO =
        let classified = instances |> List.map(placed -> {
            Scene3d.lightmapWarning(placed) |> Option.forEach(line ->
                warnSceneOnce(state, "lightmap:" + line + Mesh3d.contentHash(Scene3d.instanceFieldsOf(placed)#mesh), line));
            let draw = meshDrawOf(state, outside, placed);
            let material = draw#fields#material
                |> Option.map(Scene3d.materialFieldsOf)
                |> Option.filter(wants)
                |> Option.flatMap(m -> materialEntry(gl, state, gen, m, vertexKindOf(state, coverage, draw, m))
                    |> Option.map(e -> { entry = e, material = m, draw = draw }));
            (draw, material)
        });
        let plain = classified |> List.filterMap(fd -> if (Option.isEmpty(snd(fd))) Some(fst(fd)) else None);
        let materials = classified |> List.filterMap(snd);
        (plain, materials)

    /// 置いた物 d を材質 m で描くプログラムの頂点の形。法線マップは uv つきの形にだけ当てる（uv の無い形は形ごとに 1 回知らせて無視する）。
    def vertexKindOf(state: State, coverage: Bool, d: MeshDraw, m: Scene3d.MaterialFields): ProgramKind \ IO =
        let uv = hasUv(d);
        let wantsNormalMap = Option.nonEmpty(m#normalMap);
        if (wantsNormalMap and not uv)
            warnSceneOnce(state, "nouv:" + Mesh3d.contentHash(d#fields#mesh),
                "scene3d: uv の無い形に法線マップの材質 '${m#spec#name}' が付いている — 法線マップを当てずに描く（Mesh3d.withUvs か withBoxUvs で uv を付ける）")
        else ();
        { skinned = isSkinned(d), uv = uv, normalMap = wantsNormalMap and uv, lightmap = Option.nonEmpty(Scene3d.lightmapOfFields(d#fields)),
          blend = m#blend, doubleSided = m#doubleSided, coverage = isCoverageCutout(coverage, m) }

    /// 材質のある物を draws の順に描く（呼び手が並べる: 不透明はプログラムの番号で並べて切り替えを減らす・半透明は遠い物から）。
    /// 続く物が同じプログラムなら組み直さない。描き終えたら、絵を貼った unit（材質の絵と法線マップ）の sampler を外して unit 0 へ戻す。
    // WhyNot: 間引いた物を並べる前に除かない — sortBy は安定ソートではなく、減らした列を並べると同じプログラムの物どうしの順が変わり、
    //   同じ平面に重なった面の画素が入れ替わる。呼び手は間引く前の全部で並べ、ここで飛ばす（半透明を外した列は、半透明の無い場面では
    //   前と同じ列。半透明の有る場面の同じ深さの不透明の面の勝ち方は、CPU と揃うことを約束しない）。
    pub def drawMaterials(gl: GlContext, state: State, gen: Int64, camera: CameraData, pass: MaterialPass, source: TextureSource,
                      draws: List[MaterialDraw]): Unit \ IO =
        let bound = Array#{0, 0, 0, 0} @ Static;
        draws |> List.forEach(d -> if (d#draw#culled) drawPosedMesh(gl, state, gen, d#entry#locs#mesh, d#draw) else {
            let locs = d#entry#locs;
            if (locs#mesh#program == Array.get(0, bound)) ()
            else {
                Array.put(locs#mesh#program, 0, bound);
                useMaterialProgram(state, camera, pass, locs)
            };
            let units = drawMaterialInstance(gl, state, gen, source, d#entry#coverage, d);
            Array.put(Int32.max(units, Array.get(1, bound)), 1, bound);
            if (d#entry#normalMapped) Array.put(1, 2, bound) else ();
            if (d#entry#lightmapped) Array.put(1, 3, bound) else ()
        });
        releaseMaterialUnits(Array.get(1, bound), Array.get(2, bound) == 1, Array.get(3, bound) == 1)

    /// unit 0〜count−1（と、normalMap が真なら法線マップの unit・lightmap が真なら lightmap の unit）の sampler を外して unit 0 へ戻す。どれも貼っていなければ何もしない。
    // WhyNot: 貼ったテクスチャまでは外さない — ビルボードと 2D の面は描く前に自分のテクスチャを貼り直すが、sampler は貼り直さず unit の物を読む。
    def releaseMaterialUnits(count: Int32, normalMap: Bool, lightmap: Bool): Unit \ IO =
        if (count <= 0 and not normalMap and not lightmap) ()
        else {
            List.range(0, count) |> List.forEach(unit -> GL33.glBindSampler(unit, 0));
            if (normalMap) GL33.glBindSampler(normalMapTextureUnit(), 0) else ();
            if (lightmap) GL33.glBindSampler(lightmapTextureUnit(), 0) else ();
            GL13.glActiveTexture(GL13.GL_TEXTURE0)
        }

    def useMaterialProgram(state: State, camera: CameraData, pass: MaterialPass, locs: MaterialLocs): Unit \ IO =
        useMeshProgram(locs#mesh, camera#view, camera#proj);
        putLights(locs#light, camera#lights);
        putShadow(locs#shadow, camera#shadow);
        GL20.glUniform1f(locs#time, RenderUtil.f32(Array.get(0, state#timeHolder)));
        match pass {
            case MaterialPass.Color     => GL20.glUniform1i(locs#depthOut, 0)
            case MaterialPass.Depth(dr) =>
                GL20.glUniform1i(locs#depthOut, 1);
                putDepthRange(locs#depthRange, dr)
        }

    /// 材質 m の cutout を alpha to coverage で描くか。coverage = 描き先が標本を持ち、色の段で描く（Output.Depth は偽で渡す）。
    // WhyNot: 深度の段（Output.Depth）と半透明に使わない — 深度の灰色は縁で混ぜると奥行きが嘘になり、半透明の α は重ねる量に使う。
    def isCoverageCutout(coverage: Bool, m: Scene3d.MaterialFields): Bool =
        coverage and m#cutout and not m#blend

    /// 材質のある物 1 つを描き、絵を貼った unit の数を返す。coverage = cutout を discard でなく alpha to coverage で抜く
    /// （出す α を標本の数に使い、書く α は 1。GL_SAMPLE_ALPHA_TO_ONE）。
    def drawMaterialInstance(gl: GlContext, state: State, gen: Int64, source: TextureSource, coverage: Bool, d: MaterialDraw): Int32 \ IO =
        let locs = d#entry#locs;
        putLinearizedColor(locs#tint, d#draw#fields#tint);
        GL20.glUniform1f(locs#emissionIntensity, RenderUtil.f32(d#material#emissionIntensity));
        GL20.glUniform1i(locs#cutout, if (d#material#cutout) 1 else 0);
        // WhyNot: ShaderDoc.materialParamValues で並べない — あちらは上限を超えた tex を 0 にする前の Spec から名前を拾い、
        //   compile3d が uParamN に割り当てた並び（0 にした後）と食い違う余地がある。uniform を宣言した側の並びで引く。
        List.zip(locs#params, d#entry#paramNames) |> List.forEach(ln -> {
            let (paramLoc, name) = ln;
            GL20.glUniform1f(paramLoc, RenderUtil.f32(Map.getWithDefault(name, 0.0, d#material#params)))
        });
        let units = bindMaterialTextures(gl, state, gen, source, d);
        bindNormalMap(gl, state, gen, source, d);
        bindLightmap(gl, state, gen, source, d);
        if (coverage) {
            GL11.glEnable(GL13.GL_SAMPLE_ALPHA_TO_COVERAGE);
            GL11.glEnable(GL13.GL_SAMPLE_ALPHA_TO_ONE)
        } else ();
        if (d#material#doubleSided) {
            GL11.glDisable(GL11.GL_CULL_FACE);
            drawPosedMesh(gl, state, gen, locs#mesh, d#draw);
            GL11.glEnable(GL11.GL_CULL_FACE)
        } else drawPosedMesh(gl, state, gen, locs#mesh, d#draw);
        if (coverage) {
            GL11.glDisable(GL13.GL_SAMPLE_ALPHA_TO_COVERAGE);
            GL11.glDisable(GL13.GL_SAMPLE_ALPHA_TO_ONE)
        } else ();
        units

    /// lightmap を lightmap の unit に貼り、段の数・色空間・強さを入れる（Clamp・段つきの Linear で読む）。lightmap を読まないプログラムは何もしない。
    /// 名前が場面の textures に無い絵は 0（黒）で読み、名前ごとに 1 回知らせる（材質の絵と同じ道）。
    // WhyNot: プログラムごとに 1 回だけ入れない — 同じ形と材質で lightmap だけ違う物は同じプログラムで続けて描かれ、前の物の絵と強さを引き継ぐ。
    def bindLightmap(gl: GlContext, state: State, gen: Int64, source: TextureSource, d: MaterialDraw): Unit \ IO =
        if (not d#entry#lightmapped) ()
        else Scene3d.lightmapOfFields(d#draw#fields) |> Option.forEach(lm -> {
            let unit = lightmapTextureUnit();
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + unit);
            let bound = resolveTextureAs(gl, state, gen, source, "lightmap の絵", lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace));
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound#texId);
            GL33.glBindSampler(unit, materialSampler(state, Scene3d.Wrap.Clamp, ShaderDoc.FilterMode.Linear, bound#levels > 1));
            GL20.glUniform1f(d#entry#locs#lightmapLevels, RenderUtil.f32(Int32.toFloat64(Int32.min(bound#levels, lm#maxLevels))));
            GL20.glUniform1i(d#entry#locs#lightmapSrgb, if (lm#colorSpace == Texture3d.ColorSpace.Srgb) 1 else 0);
            GL20.glUniform1f(d#entry#locs#lightmapIntensity, RenderUtil.f32(lm#intensity))
        })

    /// 法線マップを法線マップの unit に貼る（材質の wrap・Linear で読む）。法線マップを当てないプログラムは何もしない。
    def bindNormalMap(gl: GlContext, state: State, gen: Int64, source: TextureSource, d: MaterialDraw): Unit \ IO =
        match (d#entry#normalMapped, d#material#normalMap) {
            case (true, Some(n)) =>
                let unit = normalMapTextureUnit();
                GL13.glActiveTexture(GL13.GL_TEXTURE0 + unit);
                let bound = resolveMaterialTexture(gl, state, gen, source, n#texture, Texture3d.TextureUse.NormalMap);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound#texId);
                GL33.glBindSampler(unit, materialSampler(state, d#material#wrap, ShaderDoc.FilterMode.Linear, bound#levels > 1));
                GL20.glUniform1f(d#entry#locs#normalStrength, RenderUtil.f32(n#strength));
                GL20.glUniform1f(d#entry#locs#normalFlip, if (bound#flipped) 1.0f32 else 0.0f32);
                GL20.glUniform1f(d#entry#locs#normalLevels, RenderUtil.f32(Int32.toFloat64(bound#levels)))
            case _ => ()
        }

    /// 材質の絵を unit 0〜 に貼り、読み方（wrap と補間）の sampler を付けて、貼った数を返す。
    /// 名前は描く材質から引き直す（eqSpec は tex の名前を並びの番号で比べるので、名前だけ違う材質が同じプログラムを使う）。
    def bindMaterialTextures(gl: GlContext, state: State, gen: Int64, source: TextureSource, d: MaterialDraw): Int32 \ IO =
        if (List.isEmpty(d#entry#texReads)) 0
        else {
            let reads = ShaderDoc.materialTexReads(d#material#spec, d#material#emission) |> List.take(Scene3d.maxMaterialTextures());
            List.zip(reads, List.zip(d#entry#locs#texFlips, d#entry#locs#texLevels)) |> List.forEachWithIndex((unit, pair) -> {
                let ((name, filter), (flipLoc, levelsLoc)) = pair;
                // WhyNot: 引いてから unit を選ばない — 初めての絵は引く時に上げて今の unit に貼るので、前の unit に貼った絵を外してしまう。
                GL13.glActiveTexture(GL13.GL_TEXTURE0 + unit);
                let bound = resolveMaterialTexture(gl, state, gen, source, name, Texture3d.TextureUse.MaterialTexture);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound#texId);
                GL33.glBindSampler(unit, materialSampler(state, d#material#wrap, filter, bound#levels > 1));
                GL20.glUniform1f(flipLoc, if (bound#flipped) 1.0f32 else 0.0f32);
                GL20.glUniform1f(levelsLoc, RenderUtil.f32(Int32.toFloat64(bound#levels)))
            });
            List.length(reads)
        }

    /// 材質の Tex の名前を、貼る GPU のテクスチャ・上下を反転して読むか（レンダーターゲット）・段の数へ引く。
    /// "tex3d:" は場面の textures（置き場に無ければ段ごと上げる）・ほかは全体の登録（段つきの写しを作る。レンダーターゲットは
    /// 毎コマ書き換わるので段を作らず、そのまま読む）・どちらにも無ければ透明な黒（名前ごとに 1 回知らせる）。
    def resolveMaterialTexture(gl: GlContext, state: State, gen: Int64, source: TextureSource, name: String, textureUse: Texture3d.TextureUse): BoundTexture \ IO =
        resolveTextureAs(gl, state, gen, source, "材質の絵", name, textureUse)

    /// resolveMaterialTexture の、見つからない時の知らせで何の絵かを label で言う版（知らせの鍵は名前ごとに共有）。
    /// textureUse = 貼る使い方（段の平均の仕方を決める）。
    // WhyNot: 同じ絵を色と法線の両方に貼った時に 1 枚にまとめない — 段の平均の仕方が違うので 2 枚上がり、置き場の上限にも 2 回数える。
    //   その使い方は今の使い手に無い。
    pub def resolveTextureAs(gl: GlContext, state: State, gen: Int64, source: TextureSource, label: String, name: String,
                             textureUse: Texture3d.TextureUse): BoundTexture \ IO =
        let average = Texture3d.mipAverageOf(Texture3d.mipSpaceOf(textureUse));
        let found = if (String.startsWith(prefix = Texture3d.namePrefix(), name))
            Map.get(name, source#own) |> Option.map(t -> texture3dBound(state, gen, average, t))
        else (source#textureOf)(name) |> Option.map(t ->
            if (t#flipped) { texId = t#texId, flipped = true, levels = 1 } else mipCopyOf(state, gen, name, average, t));
        match found {
            case Some(hit) => hit
            case None =>
                warnSceneOnce(state, "missing:" + name, "scene3d: ${label} '${name}' が見つからない — 0（黒・透明）で読む"
                    + "（tex3d: の名前は場面の textures に、ほかは project.json の textures に同名の宣言があるか確認）");
                { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
        }

    /// 全体の登録の絵 t の段つきの写し（average で平均した段。置き場の鍵は名前と平均の仕方。
    /// 無いか、元の絵が作り直されていたら、元の段 0 を読み戻して段を作り、上げ直す）。
    // WhyNot: 登録の絵の画素を Java の側に持ち続けない — STB で直に上げているので持っておらず、全部の絵をヒープに二重に持つことになる。
    def mipCopyOf(state: State, gen: Int64, name: String, average: Mip.Average, t: RegisteredTexture): BoundTexture \ IO =
        let copies = Ref.get(state#mipCopiesRef);
        let key = name + ":" + ToString.toString(average);
        let copy = match Map.get(key, copies) {
            case Some(c) if c#sourceId == t#texId and c#version == t#version => { lastUsed = gen | c }
            case old =>
                old |> Option.forEach(c -> GL11.glDeleteTextures(c#texId));
                let w = Float64.tryToInt32(Float64.round(t#width)) |> Option.getWithDefault(1);
                let h = Float64.tryToInt32(Float64.round(t#height)) |> Option.getWithDefault(1);
                let pixels = Array.repeat(Static, Int32.max(1, w * h), 0);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, t#texId);
                GL11.glGetTexImage(GL11.GL_TEXTURE_2D, 0, GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, pixels);
                let chain = Mip.build(average, { width = w, height = h, pixels = Array.toVector(pixels) });
                { sourceId = t#texId, version = t#version, texId = uploadMipChain(chain), levels = List.length(chain), lastUsed = gen }
        };
        Ref.put(Map.insert(key, copy, copies), state#mipCopiesRef);
        { texId = copy#texId, flipped = false, levels = copy#levels }

    /// 段の列を 1 枚のテクスチャの段 0〜 に上げる（行 0 が絵の上・ARGB）。
    def uploadMipChain(chain: List[ShaderEval.TexData]): Int32 \ IO =
        let texId = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, texId);
        chain |> List.forEachWithIndex((level, td) -> {
            let buf = MemoryUtil.memAllocInt(Int32.max(1, Vector.length(td#pixels)));
            discard buf.put(unchecked_cast(td#pixels as Array[Int32, Static]));
            discard buf.flip();
            GL11.glTexImage2D(GL11.GL_TEXTURE_2D, level, GL11.GL_RGBA, td#width, td#height, 0,
                              GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, buf);
            MemoryUtil.memFree(buf)
        });
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL12.GL_TEXTURE_BASE_LEVEL, 0);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL12.GL_TEXTURE_MAX_LEVEL, Int32.max(0, List.length(chain) - 1));
        texId

    /// 見つからない絵の代わりに貼る 1 × 1 の透明な黒（初めて要る時に作る）。
    // WhyNot: テクスチャ 0 を貼らない — 完全でないテクスチャの読みはドライバ次第で α が 1 になり、CPU の 0 と食い違う。
    def blankTextureId(gl: GlContext, state: State): Int32 \ IO =
        let held = Array.get(0, state#blankTexture);
        if (held != 0) held
        else {
            let made = GpuHandle.textureIdInt(RenderTexture.loadTextureFromPixels(gl, 1, 1, Vector#{0})#id);
            Array.put(made, 0, state#blankTexture);
            made
        }

    /// wrap と補間と段の有無の組の sampler（初めて要る時に作る）。段つきの Nearest は NEAREST_MIPMAP_LINEAR（段の切り替わりの筋を出さない）・
    /// Linear は LINEAR_MIPMAP_LINEAR（CPU の Mip の読み方と同じ）。段の無い絵（レンダーターゲット・代わりの絵）は段なしで読む。
    def materialSampler(state: State, wrap: Scene3d.Wrap, filter: ShaderDoc.FilterMode, mipped: Bool): Int32 \ IO =
        let linear = filter == ShaderDoc.FilterMode.Linear;
        let index = (if (mipped) 4 else 0) + (if (wrap == Scene3d.Wrap.Clamp) 2 else 0) + (if (linear) 1 else 0);
        let held = Array.get(index, state#materialSamplers);
        if (held != 0) held
        else {
            let sampler = GL33.glGenSamplers();
            let glFilter = if (linear) GL11.GL_LINEAR else GL11.GL_NEAREST;
            let minFilter = match (mipped, linear) {
                case (true, true)  => GL11.GL_LINEAR_MIPMAP_LINEAR
                case (true, false) => GL11.GL_NEAREST_MIPMAP_LINEAR
                case (false, _)    => glFilter
            };
            let glWrap = if (wrap == Scene3d.Wrap.Clamp) GL12.GL_CLAMP_TO_EDGE else GL11.GL_REPEAT;
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_MIN_FILTER, minFilter);
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_MAG_FILTER, glFilter);
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_WRAP_S, glWrap);
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_WRAP_T, glWrap);
            Array.put(sampler, index, state#materialSamplers);
            sampler
        }

    // ── 場面の絵の置き場 ──

    /// 場面の絵を contentHash と段の平均の仕方 average で引き、無ければ段を作って段ごと上げる。どちらでも lastUsed を今の世代にする。
    def texture3dBound(state: State, gen: Int64, average: Mip.Average, t: Texture3d.Texture3d): BoundTexture \ IO =
        let key = Texture3d.contentHash(t) + ":" + ToString.toString(average);
        let held = Ref.get(state#textures3dRef);
        let entry = match Map.get(key, held) {
            case Some(found) => { lastUsed = gen | found }
            case None =>
                let chain = Mip.build(average, { width = Texture3d.width(t), height = Texture3d.height(t), pixels = Texture3d.argb(t) });
                { texId = uploadMipChain(chain), levels = List.length(chain),
                  bytes = chain |> List.foldLeft((acc, td) -> acc + Int32.toInt64(td#width) * Int32.toInt64(td#height) * 4i64, 0i64),
                  lastUsed = gen }
        };
        Ref.put(Map.insert(key, entry, held), state#textures3dRef);
        { texId = entry#texId, flipped = false, levels = entry#levels }

    /// 使われない場面の絵を捨て、上限を超えたら今と前のコマで使っていない古い物から捨てる（画面のコマの終わりに 1 回）。
    /// 今と前のコマで使う物だけで上限を超えていたら 1 回だけ知らせる（Pass の場面は画面のコマの 1 つ前の世代で描かれる）。
    pub def sweepTextures3d(state: State, gen: Int64): Unit \ IO =
        let held = Ref.get(state#textures3dRef);
        let isIdle = (e: Texture3dEntry) -> gen - e#lastUsed > meshIdleFrames();
        let kept = Map.filter(e -> not isIdle(e), held);
        let overBudget = (m: Map[String, Texture3dEntry]) ->
            Map.size(m) > state#textureCountBudget or Map.foldLeft((acc, e) -> acc + e#bytes, 0i64, m) > state#textureByteBudget;
        let oldestFirst = Map.toList(kept) |> List.filter(ke -> snd(ke)#lastUsed < gen - 1i64)
            |> List.map(ke -> (snd(ke)#lastUsed, ke)) |> List.sortBy(fst) |> List.map(snd);
        let trimmed = List.foldLeft((acc, ke) -> if (overBudget(acc)) Map.remove(fst(ke), acc) else acc, kept, oldestFirst);
        let dropped = Map.difference(held, trimmed);
        Map.forEach((_key, e) -> GL11.glDeleteTextures(e#texId), dropped);
        Ref.put(trimmed, state#textures3dRef);
        let copies = Ref.get(state#mipCopiesRef);
        let idleCopies = Map.filter(c -> gen - c#lastUsed > meshIdleFrames(), copies);
        Map.forEach((_key, c) -> GL11.glDeleteTextures(c#texId), idleCopies);
        Ref.put(Map.difference(copies, idleCopies), state#mipCopiesRef);
        if (overBudget(trimmed))
            warnSceneOnce(state, "@budget", "scene3d: 場面の絵（Texture3d）が ${state#textureCountBudget} 枚か"
                + " ${Int64.toString(state#textureByteBudget / 1048576i64)} MB を超えて使われている — 絵を減らすか小さくするか、project.json の scene3dTextureBudgetCount / scene3dTextureBudgetMB を上げる")
        else ()

    // ── 材質のプログラムの置き場 ──


    /// 材質のプログラムを引く。無いか、同じ鍵で中身が違えば組み直す。組めなかった材質は None（頂点の色で描く）。
    def materialEntry(gl: GlContext, state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind): Option[MaterialEntry] \ IO =
        let key = materialKey(m, kind);
        let cache = Ref.get(state#materialsRef);
        let entry = match Map.get(key, cache) {
            // 来た方の spec を持ち直す — 古い方を持ち続けると、次のコマも参照の一致で抜けられず毎回木を比べる。
            case Some(found) if sameMaterial(found, m) => { spec = m#spec, emission = m#emission, lastUsed = gen | found }
            case old                                   => rebuildMaterial(gl, state, gen, { key = key, kind = kind }, old, m)
        };
        Ref.put(Map.insert(key, entry, Ref.get(state#materialsRef)), state#materialsRef);
        if (entry#locs#mesh#program == 0) None else Some(entry)

    def sameMaterial(entry: MaterialEntry, m: Scene3d.MaterialFields): Bool =
        ShaderGen.eqMaterial(entry#spec, entry#emission, m#spec, m#emission)

    /// 鍵 key の材質を組み直す。古いプログラムはすぐ消さず引退させる（同じコマの先の物がまだ使う）。
    def rebuildMaterial(gl: GlContext, state: State, gen: Int64, slot: { key = String, kind = ProgramKind }, old: Option[MaterialEntry],
                        m: Scene3d.MaterialFields): MaterialEntry \ IO =
        old |> Option.forEach(e -> {
            if (e#lastUsed == gen) warnMaterialThrash(state, slot#key, m#spec#name) else ();
            retireMaterial(state, e)
        });
        buildMaterial(gl, state, gen, m, slot#kind)

    /// 材質のプログラムを組む。読む絵の組が Scene3d.maxMaterialTextures() を超える材質は、後ろの組を 0 にして組み、1 回知らせる。
    def buildMaterial(gl: GlContext, state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind): MaterialEntry \ IO =
        Array.put(1, 2, state#materialStreak);
        let readCount = List.length(ShaderDoc.materialTexReads(m#spec, m#emission));
        if (readCount > Scene3d.maxMaterialTextures())
            warnSceneOnce(state, "limit:" + m#spec#name, "scene3d: 材質 '${m#spec#name}' が読む絵の組が ${readCount} 組ある"
                + " — ${Scene3d.maxMaterialTextures()} 組目より後ろは 0 で描く")
        else ();
        let (spec, emission) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), m#spec, m#emission);
        let glsl = ShaderGen.compile3d(spec, emission);
        let label = "scene3d:material" + (if (kind#skinned) ":skin" else "") + (if (kind#uv) ":uv" else "")
            + (if (kind#normalMap) ":nm" else "") + (if (kind#lightmap) ":lm" else "") + (if (kind#blend) ":bl" else "")
            + (if (kind#doubleSided) ":ds" else "") + (if (kind#coverage) ":cov" else "") + ":${m#spec#name}";
        let vertex = materialVertexSource({ skinned = kind#skinned, uv = kind#uv, lightmap = kind#lightmap });
        let fragment = materialFragmentSource(glsl, kind);
        let program = match RenderShader.tryCreateProgram(gl, vertex, fragment, label) {
            case Some(p) => p
            case None    =>
                Log.warnThen("scene3d: 材質 '${m#spec#name}' のプログラムが組めなかった — この材質の物は頂点の色で描く", 0)
        };
        if (kind#skinned) bindJointsBlock(program) else ();
        bindTextureUnits(program, List.length(glsl#texReads), kind#normalMap, kind#lightmap);
        { spec = m#spec, emission = m#emission, paramNames = glsl#paramNames, texReads = glsl#texReads, normalMapped = kind#normalMap,
          lightmapped = kind#lightmap, coverage = kind#coverage,
          locs = materialLocsOf(program, glsl#paramNames, List.length(glsl#texReads)), lastUsed = gen }

    /// uTexN を unit N へ、uNormalMap を法線マップの unit へ向ける（プログラムごとに 1 回。組めなかったプログラムと、
    /// 絵も法線マップも無い材質は何もしない）。
    def bindTextureUnits(program: Int32, count: Int32, normalMap: Bool, lightmap: Bool): Unit \ IO =
        if (program == 0 or (count == 0 and not normalMap and not lightmap)) ()
        else {
            GL20.glUseProgram(program);
            List.range(0, count) |> List.forEach(unit -> GL20.glUniform1i(loc(program, "uTex${unit}"), unit));
            if (normalMap) GL20.glUniform1i(loc(program, "uNormalMap"), normalMapTextureUnit()) else ();
            if (lightmap) GL20.glUniform1i(loc(program, "uLightmap"), lightmapTextureUnit()) else ();
            GL20.glUseProgram(0)
        }

    def retireMaterial(state: State, e: MaterialEntry): Unit \ IO =
        if (e#locs#mesh#program == 0) ()
        else Ref.put(e#locs#mesh#program :: Ref.get(state#retiredMaterialsRef), state#retiredMaterialsRef)

    def warnMaterialThrash(state: State, key: String, name: String): Unit \ IO =
        let warned = Ref.get(state#thrashWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), state#thrashWarnedRef);
            Log.warn("scene3d: 中身の違う材質の鍵（ShaderGen.hashMaterial）が同じコマにぶつかった（'${name}'）"
                + " — 毎コマ組み直している。spec か emission の数に NaN があれば直す（NaN は自分とも等しくない）。無ければ engine の不具合")
        }

    def materialLocsOf(program: Int32, paramNames: List[String], texCount: Int32): MaterialLocs \ IO =
        { mesh = meshLocsOf(program), tint = loc(program, "uTint"), light = lightLocsOf(program), shadow = shadowLocsOf(program),
          time = loc(program, "uTime"), cutout = loc(program, "uCutout"),
          depthOut = loc(program, "uDepthOut"), depthRange = loc(program, "uDepthRange"),
          params = paramNames |> List.mapWithIndex((i, _) -> loc(program, "uParam${i}")),
          texFlips = List.range(0, texCount) |> List.map(i -> loc(program, "uTexFlip${i}")),
          normalStrength = loc(program, "uNormalStrength"), normalFlip = loc(program, "uNormalFlip"),
          texLevels = List.range(0, texCount) |> List.map(i -> loc(program, "uTexLevels${i}")), normalLevels = loc(program, "uNormalLevels"),
          lightmapLevels = loc(program, "uLightmapLevels"), lightmapSrgb = loc(program, "uLightmapSrgb"),
          lightmapIntensity = loc(program, "uLightmapIntensity"), emissionIntensity = loc(program, "uEmissionIntensity") }

    /// 引退した材質のプログラムを消し、使われない材質を LRU で追い出す（画面のコマの終わりに 1 回）。
    /// 今と前のコマで使った材質は捨てない（Pass の場面は画面のコマの 1 つ前の世代で描かれる）。
    pub def sweepMaterials(state: State, gen: Int64): Unit \ IO =
        Ref.get(state#retiredMaterialsRef) |> List.forEach(program -> GL20.glDeleteProgram(program));
        Ref.put(Nil, state#retiredMaterialsRef);
        let cache = Ref.get(state#materialsRef);
        let isLive = (e: MaterialEntry) -> e#lastUsed >= gen - 1i64;
        let pinned = Map.valuesOf(cache) |> List.filter(isLive) |> List.map(e -> e#locs#mesh#program) |> List.toSet;
        // WhyNot: 上限を固定の数にしない — 材質の数はゲームが決めるので、多いゲームで毎コマ作っては捨てるだけになる。
        let cap = Int32.max(16, Set.size(pinned) * 2);
        let victims = RenderShaderCache.computeEvictions({
            entries = Map.toList(cache) |> List.map(ke -> (fst(ke), snd(ke)#locs#mesh#program, snd(ke)#lastUsed)),
            pinned = pinned, cap = cap });
        if (List.isEmpty(victims)) ()
        else {
            victims |> List.forEach(key -> Map.get(key, cache) |> Option.forEach(e ->
                if (e#locs#mesh#program == 0) () else GL20.glDeleteProgram(e#locs#mesh#program)));
            Ref.put(List.foldLeft((acc, key) -> Map.remove(key, acc), cache, victims), state#materialsRef)
        }
}
