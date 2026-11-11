// Render3d.Material — 3D の描き手（Render3d）の材質のある置いた物（材質のプログラムと鍵・場面の絵の置き場・描き方）。約束は Render3d.flix の頭。
mod Render3d.Material {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.Shadow.{putShadow}
    use Render3dGlsl.{materialFragmentSource, materialVertexSource}
    use Render3d.Light.{putLights}
    use Render3d.{materialKey, ProgramKind, BoundTexture, CameraData, MaterialEntry, MaterialLocs,
                  MaterialPass, MeshDraw, State, Texture3dEntry, TextureSlot, TextureSource, bindDataTextureUnits, drawBatch, ensureTangents, hasUv, isSkinned,
                  lightLocsOf, lightmapTextureUnit, loc, meshDrawOf, meshLocsOf, normalMapTextureUnit,
                  putDepthRange, shadowLocsOf, useMeshProgram, warnDroppedTextures, warnSceneOnce}
    use Render3d.Batch.{MaterialBatch, MeshBatch, PlannedBatch, batchKeyOf, batchOf, groupByTextures, groupInOrder}
    use Scene3dRenderer.{RegisteredTexture}
    use Render3d.Counts.{Counter, Phase, count, noteMaterialBuild, timed}

    // ── 材質のある置いた物 ──

    /// 置いた物 1 つを batch へ分ける材料。surface = 描く材質とプログラムの版（無ければ頂点の色で描く）。
    type alias PlacedDraw = { draw = MeshDraw, surface = Option[(Scene3d.MaterialFields, ProgramKind)] }

    /// 置いた物を batch に分け、頂点の色で描く batch と材質のプログラムで描く batch を返す。wants が偽の材質と、組めなかった材質は頂点の色の側へ。
    /// 材質のプログラムは batch ごとに 1 回引き、初めての材質はここで組む（3D を使わないゲームと、材質を使わない場面は GLSL のコンパイルを払わない）。
    /// outside = 描かずに済ませる物か（視錐台の外。MeshDraw の culled になる）。間引く物の材質も組む（間引くのは描く段の手前）。
    // WhyNot: 間引いた物を材質の組み立ての前に除かない — 初めて振り向いたコマで GLSL を組んで止まる（読み込み中に先に組ませる作りが効かない）。
    /// coverage = 描き先が標本を持ち、色の段で描く（cutout の材質を alpha to coverage の版で組む）。
    pub def splitByMaterial(gl: GlContext, state: State, gen: Int64, outside: Scene3d.Instance3d -> Bool, wants: Scene3d.MaterialFields -> Bool, coverage: Bool,
                        instances: List[Scene3d.Instance3d]): (List[PlannedBatch], List[MaterialBatch[PlannedBatch]]) \ IO = timed(state, Phase.Split, () -> {
        let placed = instances |> List.map(i -> {
            Scene3d.lightmapWarning(i) |> Option.forEach(line ->
                warnSceneOnce(state, "lightmap:" + line + Mesh3d.contentHash(Scene3d.instanceFieldsOf(i)#mesh), line));
            let draw = meshDrawOf(state, outside, i);
            let surface = draw#fields#material |> Option.map(Scene3d.materialFieldsOf) |> Option.filter(wants)
                |> Option.map(m -> (m, vertexKindOf(state, coverage, draw, m)));
            { draw = draw, surface = surface }
        });
        let (plain, materials) = groupInOrder(p -> Mesh3d.contentHash(p#draw#fields#mesh), p -> batchKeyOf(state#drawMode, p#draw, p#surface), placed)
            |> List.flatMap(groupByTextures(p -> Option.map(fst, p#surface)))
            |> List.foldLeft(addPlaced(gl, state, gen), (Nil, Nil));
        (List.reverse(plain), List.reverse(materials))
    })

    /// members の batch を acc の頭へ足す: 材質のプログラムが組めたら右の列へ、ほかは左の列へ。
    def addPlaced(gl: GlContext, state: State, gen: Int64, acc: (List[PlannedBatch], List[MaterialBatch[PlannedBatch]]),
                  members: List[PlacedDraw]): (List[PlannedBatch], List[MaterialBatch[PlannedBatch]]) \ IO =
        let (plain, materials) = acc;
        match members {
            case Nil         => acc
            case head :: _   =>
                let batch = batchOf(head#draw, List.map(p -> p#draw, members));
                let material = head#surface |> Option.flatMap(mk -> {
                    let (m, kind) = mk;
                    materialEntry(gl, state, gen, m, kind) |> Option.map(e -> { entry = e, material = m, batch = batch })
                });
                match material {
                    case Some(d) => (plain, d :: materials)
                    case None    => (batch :: plain, materials)
                }
        }

    /// 置いた物 d を材質 m で描くプログラムの頂点の形。法線マップは uv つきの形にだけ当てる（uv の無い形は形ごとに 1 回知らせて無視する）。
    def vertexKindOf(state: State, coverage: Bool, d: MeshDraw, m: Scene3d.MaterialFields): ProgramKind \ IO =
        let uv = hasUv(d);
        let wantsNormalMap = Option.nonEmpty(m#normalMap);
        if (wantsNormalMap and not uv)
            warnSceneOnce(state, "nouv:" + Mesh3d.contentHash(d#fields#mesh),
                "scene3d: uv の無い形に法線マップの材質 '${m#spec#name}' が付いている — 法線マップを当てずに描く（Mesh3d.withUvs か withBoxUvs で uv を付ける）")
        else ();
        { skinned = isSkinned(d), uv = uv, normalMap = wantsNormalMap and uv, lightmap = Option.nonEmpty(Scene3d.lightmapOfFields(d#fields)),
          blend = m#blend, doubleSided = m#doubleSided, coverage = isCoverageCutout(coverage, m),
          metallicRoughness = Option.nonEmpty(m#metallicRoughnessShade) }

    /// 材質の batch を draws の順に描く（呼び手が並べる: 不透明はプログラムの番号で並べて切り替えを減らす・半透明は遠い物から）。
    /// 続く物が同じプログラムなら組み直さない。描き終えたら、絵を貼った unit（材質の絵と法線マップ）の sampler を外して unit 0 へ戻す。
    pub def drawMaterials(gl: GlContext, state: State, gen: Int64, camera: CameraData, pass: MaterialPass, source: TextureSource,
                      draws: List[MaterialBatch[MeshBatch]]): Unit \ IO =
        let bound = Array#{0, 0, 0, 0} @ Static;
        draws |> List.forEach(d -> if (d#batch#count == 0) drawBatch(gl, state, gen, d#entry#locs#mesh, d#batch) else {
            let locs = d#entry#locs;
            if (locs#mesh#program == Array.get(0, bound)) ()
            else {
                Array.put(locs#mesh#program, 0, bound);
                useMaterialProgram(gl, state, camera, pass, locs)
            };
            let units = drawMaterialBatch(gl, state, gen, source, d#entry#coverage, d);
            Array.put(Int32.max(units, Array.get(1, bound)), 1, bound);
            if (d#entry#normalMapped) Array.put(1, 2, bound) else ();
            if (d#entry#lightmapped) Array.put(1, 3, bound) else ()
        });
        releaseMaterialUnits(gl, Array.get(1, bound), Array.get(2, bound) == 1, Array.get(3, bound) == 1)

    /// unit 0〜count−1（と、normalMap が真なら法線マップの unit・lightmap が真なら lightmap の unit）の sampler を外して unit 0 へ戻す。どれも貼っていなければ何もしない。
    // WhyNot: 貼ったテクスチャまでは外さない — ビルボードと 2D の面は描く前に自分のテクスチャを貼り直すが、sampler は貼り直さず unit の物を読む。
    def releaseMaterialUnits(gl: GlContext, count: Int32, normalMap: Bool, lightmap: Bool): Unit \ IO =
        if (count <= 0 and not normalMap and not lightmap) ()
        else {
            List.range(0, count) |> List.forEach(unit -> gl.bindSampler(unit, 0));
            if (normalMap) gl.bindSampler(normalMapTextureUnit(), 0) else ();
            if (lightmap) gl.bindSampler(lightmapTextureUnit(), 0) else ();
            gl.activeTexture(GlConst.TEXTURE0)
        }

    def useMaterialProgram(gl: GlContext, state: State, camera: CameraData, pass: MaterialPass, locs: MaterialLocs): Unit \ IO =
        useMeshProgram(gl, locs#mesh, camera#view, camera#proj);
        putLights(gl, locs#light, camera#lights);
        putShadow(gl, locs#shadow, camera#shadow);
        gl.uniform1f(locs#time, RenderUtil.f32(Array.get(0, state#timeHolder)));
        match pass {
            case MaterialPass.Color     => gl.uniform1i(locs#depthOut, 0)
            case MaterialPass.Depth(dr) =>
                gl.uniform1i(locs#depthOut, 1);
                putDepthRange(gl, locs#depthRange, dr)
        }

    /// 材質 m の cutout を alpha to coverage で描くか。coverage = 描き先が標本を持ち、色の段で描く（Output.Depth は偽で渡す）。
    // WhyNot: 深度の段（Output.Depth）と半透明に使わない — 深度の灰色は縁で混ぜると奥行きが嘘になり、半透明の α は重ねる量に使う。
    pub def isCoverageCutout(coverage: Bool, m: Scene3d.MaterialFields): Bool =
        coverage and m#cutout and not m#blend

    /// 材質の batch 1 つを描き、絵を貼った unit の数を返す。coverage = cutout を discard でなく alpha to coverage で抜く
    /// （出す α を標本の数に使い、書く α は 1。GL_SAMPLE_ALPHA_TO_ONE）。
    def drawMaterialBatch(gl: GlContext, state: State, gen: Int64, source: TextureSource, coverage: Bool, d: MaterialBatch[MeshBatch]): Int32 \ IO =
        let locs = d#entry#locs;
        gl.uniform1i(locs#cutout, if (d#material#cutout) 1 else 0);
        // WhyNot: ShaderDoc.materialParamValues で並べない — あちらは上限を超えた tex を 0 にする前の Spec から名前を拾い、
        //   compile3d が uParamN に割り当てた並び（0 にした後）と食い違う余地がある。uniform を宣言した側の並びで引く。
        List.zip(locs#params, d#entry#paramNames) |> List.forEach(ln -> {
            let (paramLoc, name) = ln;
            gl.uniform1f(paramLoc, RenderUtil.f32(Map.getWithDefault(name, 0.0, d#material#params)))
        });
        let units = bindMaterialTextures(gl, state, gen, source, d);
        bindNormalMap(gl, state, gen, source, d);
        bindLightmap(gl, state, gen, source, d);
        if (d#entry#normalMapped) ensureTangents(gl, state, gen, d#batch#head#fields#mesh) else ();
        if (coverage) {
            gl.enable(GlConst.SAMPLE_ALPHA_TO_COVERAGE);
            gl.enable(GlConst.SAMPLE_ALPHA_TO_ONE)
        } else ();
        if (d#material#doubleSided) {
            gl.disable(GlConst.CULL_FACE);
            drawBatch(gl, state, gen, locs#mesh, d#batch);
            gl.enable(GlConst.CULL_FACE)
        } else drawBatch(gl, state, gen, locs#mesh, d#batch);
        if (coverage) {
            gl.disable(GlConst.SAMPLE_ALPHA_TO_COVERAGE);
            gl.disable(GlConst.SAMPLE_ALPHA_TO_ONE)
        } else ();
        units

    /// lightmap を lightmap の unit に貼り、段の数・色空間・強さを入れる（Clamp・段つきの Linear で読む）。lightmap を読まないプログラムは何もしない。
    /// 名前が場面の textures に無い絵は 0（黒）で読み、名前ごとに 1 回知らせる（材質の絵と同じ道）。
    // WhyNot: プログラムごとに 1 回だけ入れない — 同じ形と材質で lightmap だけ違う物は同じプログラムで続けて描かれ、前の物の絵と強さを引き継ぐ。
    def bindLightmap(gl: GlContext, state: State, gen: Int64, source: TextureSource, d: MaterialBatch[MeshBatch]): Unit \ IO =
        if (not d#entry#lightmapped) ()
        else Scene3d.lightmapOfFields(d#batch#head#fields) |> Option.forEach(lm -> {
            let unit = lightmapTextureUnit();
            gl.activeTexture(GlConst.TEXTURE0 + unit);
            let bound = resolveTextureAs(gl, state, gen, source, "lightmap の絵", lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace));
            gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
            gl.bindSampler(unit, materialSampler(gl, state, Scene3d.Wrap.Clamp, ShaderDoc.FilterMode.Linear, bound#levels > 1));
            gl.uniform1f(d#entry#locs#lightmapLevels, RenderUtil.f32(Int32.toFloat64(Int32.min(bound#levels, lm#maxLevels))));
            gl.uniform1i(d#entry#locs#lightmapSrgb, if (lm#colorSpace == Texture3d.ColorSpace.Srgb) 1 else 0);
            gl.uniform1f(d#entry#locs#lightmapIntensity, RenderUtil.f32(lm#intensity))
        })

    /// 法線マップを法線マップの unit に貼る（材質の wrap・Linear で読む）。法線マップを当てないプログラムは何もしない。
    def bindNormalMap(gl: GlContext, state: State, gen: Int64, source: TextureSource, d: MaterialBatch[MeshBatch]): Unit \ IO =
        match (d#entry#normalMapped, d#material#normalMap) {
            case (true, Some(n)) =>
                let unit = normalMapTextureUnit();
                gl.activeTexture(GlConst.TEXTURE0 + unit);
                let bound = resolveMaterialTexture(gl, state, gen, source, n#texture, Texture3d.TextureUse.NormalMap);
                gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
                gl.bindSampler(unit, materialSampler(gl, state, d#material#wrap, ShaderDoc.FilterMode.Linear, bound#levels > 1));
                gl.uniform1f(d#entry#locs#normalStrength, RenderUtil.f32(n#strength));
                gl.uniform1f(d#entry#locs#normalFlip, if (bound#flipped) 1.0f32 else 0.0f32);
                gl.uniform1f(d#entry#locs#normalLevels, RenderUtil.f32(Int32.toFloat64(bound#levels)))
            case _ => ()
        }

    /// 材質の絵を unit 0〜 に貼り、読み方（wrap と補間）の sampler を付けて、貼った数を返す。
    /// 名前は描く材質から引き直す（eqSpec は tex の名前を並びの番号で比べるので、名前だけ違う材質が同じプログラムを使う）。
    def bindMaterialTextures(gl: GlContext, state: State, gen: Int64, source: TextureSource, d: MaterialBatch[MeshBatch]): Int32 \ IO =
        if (List.isEmpty(d#entry#texReads)) 0
        else {
            let reads = ShaderDoc.materialTexReads(d#material#spec, d#material#emission, d#material#metallicRoughnessShade) |> List.take(Scene3d.maxMaterialTextures());
            List.zip(reads, List.zip(d#entry#locs#texFlips, d#entry#locs#texLevels)) |> List.forEachWithIndex((unit, pair) -> {
                let ((name, filter), (flipLoc, levelsLoc)) = pair;
                // WhyNot: 引いてから unit を選ばない — 初めての絵は引く時に上げて今の unit に貼るので、前の unit に貼った絵を外してしまう。
                gl.activeTexture(GlConst.TEXTURE0 + unit);
                let bound = resolveMaterialTexture(gl, state, gen, source, name, Texture3d.TextureUse.MaterialTexture);
                gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
                gl.bindSampler(unit, materialSampler(gl, state, d#material#wrap, filter, bound#levels > 1));
                gl.uniform1f(flipLoc, if (bound#flipped) 1.0f32 else 0.0f32);
                gl.uniform1f(levelsLoc, RenderUtil.f32(Int32.toFloat64(bound#levels)))
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
        match findTexture(source, name) {
            case Some(TextureHit.Own(t))                  => texture3dBound(gl, state, gen, average, t)
            case Some(TextureHit.Registered(t)) if t#flipped => { texId = t#texId, flipped = true, levels = 1 }
            case Some(TextureHit.Registered(t))           => mipCopyOf(gl, state, gen, name, average, t)
            case None =>
                warnSceneOnce(state, "missing:" + name, "scene3d: ${label} '${name}' が見つからない — 0（黒・透明）で読む"
                    + "（tex3d: の名前は場面の textures に、ほかは project.json の textures に同名の宣言があるか確認）");
                { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
        }

    /// 名前で引いた絵。Own = 場面の textures の絵・Registered = 全体の登録の絵。
    enum TextureHit {
        case Own(Texture3d.Texture3d)
        case Registered(RegisteredTexture)
    }

    /// 名前 name の絵を引く。"tex3d:" は source#own・ほかは全体の登録から。無ければ None。
    def findTexture(source: TextureSource, name: String): Option[TextureHit] \ IO =
        if (String.startsWith(prefix = Texture3d.namePrefix(), name)) Map.get(name, source#own) |> Option.map(TextureHit.Own)
        else (source#textureOf)(name) |> Option.map(TextureHit.Registered)

    /// 全体の登録の絵 t の段つきの写し（average で平均した段。置き場の鍵は名前と平均の仕方。
    /// 無いか、元の絵が作り直されていたら、元の段 0 を読み戻して段を作り、上げ直す）。
    // WhyNot: 登録の絵の画素を Java の側に持ち続けない — STB で直に上げているので持っておらず、全部の絵をヒープに二重に持つことになる。
    def mipCopyOf(gl: GlContext, state: State, gen: Int64, name: String, average: Mip.Average, t: RegisteredTexture): BoundTexture \ IO =
        let copies = Ref.get(state#mipCopiesRef);
        let key = mipCopyKey(gl, name, average);
        let copy = match Map.get(key, copies) {
            case Some(c) if c#sourceId == t#texId and c#version == t#version => { lastUsed = gen | c }
            case old =>
                old |> Option.forEach(c -> gl.deleteTexture(c#texId));
                count(state, Counter.MipCopies, 1);
                let w = Float64.tryToInt32(Float64.round(t#width)) |> Option.getWithDefault(1);
                let h = Float64.tryToInt32(Float64.round(t#height)) |> Option.getWithDefault(1);
                let up = mipCopyUpload(gl, state, average, t#texId, w, h);
                { sourceId = t#texId, version = t#version, texId = up#texId, levels = up#levels, bytes = up#bytes, lastUsed = gen }
        };
        Ref.put(Map.insert(key, copy, copies), state#mipCopiesRef);
        { texId = copy#texId, flipped = false, levels = copy#levels }

    /// 登録の絵 source（width × height）の段つきの写しを上げる。GPU が段を作る機種は GPU の中で写し、写せなければ読み戻して上げる。
    def mipCopyUpload(gl: GlContext, state: State, average: Mip.Average, source: Int32, width: Int32, height: Int32): MippedUpload \ IO =
        let copied = if (gl.prefersGpuMipmap()) uploadGpuMipped(gl, state, width, height, () -> gl.copyTextureLevel0(source, width, height)) else None;
        match copied {
            case Some(up) => up
            case None     =>
                let pixels = Array.repeat(Static, Int32.max(1, width * height), 0);
                gl.readTextureArgb(source, width, height, pixels);
                uploadArgbMipped(gl, state, average, width, height, Array.toVector(pixels))
        }

    def mipCopyKey(gl: GlContext, name: String, average: Mip.Average): String \ IO = name + ":" + mipKeyOf(gl, average)

    /// 置き場の鍵の、段の作り方の部分。
    // WhyNot: GPU が段を作る機種で平均の仕方を鍵に入れない — generateMipmap は平均の仕方を選べないので、色と法線に貼った同じ絵が同じ段の 2 枚になる。
    def mipKeyOf(gl: GlContext, average: Mip.Average): String \ IO =
        if (gl.prefersGpuMipmap()) "gpu" else ToString.toString(average)

    /// 段つきで上げた絵 1 枚。levels = 段の数・bytes = 段を合わせた置き場の大きさ。
    type alias MippedUpload = { texId = Int32, levels = Int32, bytes = Int64 }

    /// ARGB の絵（行 0 が絵の上）を段つきで上げる。GPU が段を作る機種（GlContext.prefersGpuMipmap）は段 0 だけを上げて残りを GPU に作らせ、
    /// ほかは average で平均した CPU の段（Mip.build）を上げる。
    def uploadArgbMipped(gl: GlContext, state: State, average: Mip.Average, width: Int32, height: Int32, pixels: Vector[Int32]): MippedUpload \ IO =
        if (gl.prefersGpuMipmap()) {
            let texId = gl.createTexture();
            gl.bindTexture(GlConst.TEXTURE_2D, texId);
            RenderTexture.uploadArgbLevel(gl, 0, width, height, pixels);
            finishGpuMipped(gl, state, texId, width, height)
        } else {
            let chain = timed(state, Phase.Mip, () -> Mip.build(average, { width = width, height = height, pixels = pixels }));
            { texId = uploadMipChain(gl, chain), levels = List.length(chain), bytes = chainBytes(chain) }
        }

    /// 新しいテクスチャの段 0 を uploadBase で上げ、残りの段を GPU に作らせる。uploadBase が偽（上げられない）ならテクスチャを捨てて None。
    def uploadGpuMipped(gl: GlContext, state: State, width: Int32, height: Int32, uploadBase: Unit -> Bool \ IO): Option[MippedUpload] \ IO =
        let texId = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, texId);
        if (uploadBase()) Some(finishGpuMipped(gl, state, texId, width, height))
        else { gl.deleteTexture(texId); None }

    /// bind 中の texId の段 0 から残りの段を GPU に作らせる（段の辺は Mip.build と同じ floor(n / 2)・1 × 1 まで）。
    def finishGpuMipped(gl: GlContext, state: State, texId: Int32, width: Int32, height: Int32): MippedUpload \ IO =
        timed(state, Phase.Mip, () -> gl.generateMipmap(GlConst.TEXTURE_2D));
        let sizes = mipSizesOf(width, height);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_BASE_LEVEL, 0);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAX_LEVEL, List.length(sizes) - 1);
        { texId = texId, levels = List.length(sizes),
          bytes = sizes |> List.foldLeft((acc, wh) -> acc + Int32.toInt64(fst(wh)) * Int32.toInt64(snd(wh)) * 4i64, 0i64) }

    /// width × height の絵の段の辺の列（段 0 から 1 × 1 まで）。
    def mipSizesOf(width: Int32, height: Int32): List[(Int32, Int32)] =
        if (width <= 1 and height <= 1) (width, height) :: Nil
        else (width, height) :: mipSizesOf(Int32.max(1, width / 2), Int32.max(1, height / 2))

    /// 場面の絵 t を段つきで上げる。機種の側の絵を機種が持っていなければ None。
    def uploadTexture3d(gl: GlContext, state: State, average: Mip.Average, t: Texture3d.Texture3d): Option[MippedUpload] \ IO =
        let (width, height) = (Texture3d.width(t), Texture3d.height(t));
        match Texture3d.sourceOf(t) {
            case Texture3d.Source.Argb(pixels)       => Some(uploadArgbMipped(gl, state, average, width, height, pixels))
            case Texture3d.Source.PlatformImage(key) => uploadGpuMipped(gl, state, width, height, () -> gl.texImagePlatform(key))
        }

    /// 段の列を 1 枚のテクスチャの段 0〜 に上げる（行 0 が絵の上・ARGB）。
    def uploadMipChain(gl: GlContext, chain: List[ShaderEval.TexData]): Int32 \ IO =
        let texId = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, texId);
        chain |> List.forEachWithIndex((level, td) -> RenderTexture.uploadArgbLevel(gl, level, td#width, td#height, td#pixels));
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_BASE_LEVEL, 0);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAX_LEVEL, Int32.max(0, List.length(chain) - 1));
        texId

    /// 見つからない絵の代わりに貼る 1 × 1 の透明な黒（初めて要る時に作る）。
    // WhyNot: テクスチャ 0 を貼らない — 完全でないテクスチャの読みはドライバ次第で α が 1 になり、CPU の 0 と食い違う。
    pub def blankTextureId(gl: GlContext, state: State): Int32 \ IO =
        let held = Array.get(0, state#blankTexture);
        if (held != 0) held
        else {
            let made = GpuHandle.textureIdInt(RenderTexture.loadTextureFromPixels(gl, 1, 1, Vector#{0})#id);
            Array.put(made, 0, state#blankTexture);
            made
        }

    /// wrap と補間と段の有無の組の sampler（初めて要る時に作る）。段つきの Nearest は NEAREST_MIPMAP_LINEAR（段の切り替わりの筋を出さない）・
    /// Linear は LINEAR_MIPMAP_LINEAR（CPU の Mip の読み方と同じ）。段の無い絵（レンダーターゲット・代わりの絵）は段なしで読む。
    def materialSampler(gl: GlContext, state: State, wrap: Scene3d.Wrap, filter: ShaderDoc.FilterMode, mipped: Bool): Int32 \ IO =
        let linear = filter == ShaderDoc.FilterMode.Linear;
        let index = (if (mipped) 4 else 0) + (if (wrap == Scene3d.Wrap.Clamp) 2 else 0) + (if (linear) 1 else 0);
        let held = Array.get(index, state#materialSamplers);
        if (held != 0) held
        else {
            let sampler = gl.createSampler();
            let glFilter = if (linear) GlConst.LINEAR else GlConst.NEAREST;
            let minFilter = match (mipped, linear) {
                case (true, true)  => GlConst.LINEAR_MIPMAP_LINEAR
                case (true, false) => GlConst.NEAREST_MIPMAP_LINEAR
                case (false, _)    => glFilter
            };
            let glWrap = if (wrap == Scene3d.Wrap.Clamp) GlConst.CLAMP_TO_EDGE else GlConst.REPEAT;
            gl.samplerParameteri(sampler, GlConst.TEXTURE_MIN_FILTER, minFilter);
            gl.samplerParameteri(sampler, GlConst.TEXTURE_MAG_FILTER, glFilter);
            gl.samplerParameteri(sampler, GlConst.TEXTURE_WRAP_S, glWrap);
            gl.samplerParameteri(sampler, GlConst.TEXTURE_WRAP_T, glWrap);
            Array.put(sampler, index, state#materialSamplers);
            sampler
        }

    // ── 場面の絵の置き場 ──

    /// 場面の絵を contentHash と段の作り方で引き、無ければ段つきで上げる（uploadTexture3d）。どちらでも lastUsed を今の世代にする。
    def texture3dBound(gl: GlContext, state: State, gen: Int64, average: Mip.Average, t: Texture3d.Texture3d): BoundTexture \ IO =
        let key = sceneTextureKey(gl, t, average);
        let held = Ref.get(state#textures3dRef);
        let retryWaiting = isPlatformRetryWaiting(state, gen, key);
        match Map.get(key, held) {
            case Some(found) =>
                Ref.put(Map.insert(key, { lastUsed = gen | found }, held), state#textures3dRef);
                { texId = found#texId, flipped = false, levels = found#levels }
            case None if retryWaiting => { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
            case None =>
                count(state, Counter.Texture3dUploads, 1);
                uploadSceneTexture(gl, state, gen, key, average, t)
        }

    /// 機種の側から上げられなかった絵を試し直すまでのコマの数。
    // WhyNot: 毎コマ試し直さない — 機種が絵を持つまでの間、毎コマ GPU のテクスチャを作っては捨てる。
    def platformRetryFrames(): Int64 = 60i64

    /// 鍵 key の絵を、上げられなかった後の待ちの間で試さないコマか。
    def isPlatformRetryWaiting(state: State, gen: Int64, key: String): Bool \ IO =
        Map.get(key, Ref.get(state#platformRetryRef)) |> Option.exists(tried -> gen - tried < platformRetryFrames())

    /// 置き場に無い場面の絵 t を上げて鍵 key で控える。上げられなければ控えず、透明な黒を貼る（絵ごとに 1 回知らせ、platformRetryFrames の後に試し直す）。
    // WhyNot: 上げられなかった絵を控えない — 控えると機種が後から絵を持っても、置き場から落ちるまで黒いまま。
    def uploadSceneTexture(gl: GlContext, state: State, gen: Int64, key: String, average: Mip.Average, t: Texture3d.Texture3d): BoundTexture \ IO =
        match uploadTexture3d(gl, state, average, t) {
            case Some(up) =>
                Ref.put(Map.insert(key, { texId = up#texId, levels = up#levels, bytes = up#bytes, lastUsed = gen }, Ref.get(state#textures3dRef)), state#textures3dRef);
                Ref.put(Map.remove(key, Ref.get(state#platformRetryRef)), state#platformRetryRef);
                { texId = up#texId, flipped = false, levels = up#levels }
            case None =>
                Ref.put(Map.insert(key, gen, Ref.get(state#platformRetryRef)), state#platformRetryRef);
                warnSceneOnce(state, "platform:" + key, "scene3d: 場面の絵 '${Texture3d.name(t)}' を機種の側から上げられない — 0（黒・透明）で読む");
                { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
        }

    def sceneTextureKey(gl: GlContext, t: Texture3d.Texture3d, average: Mip.Average): String \ IO = Texture3d.contentHash(t) + ":" + mipKeyOf(gl, average)

    /// 名前 name の絵を使い方 textureUse で gl に貼る時の置き場の鍵。source のどこにも無い名前は None。
    pub def textureSlotOf(gl: GlContext, source: TextureSource, name: String, textureUse: Texture3d.TextureUse): Option[TextureSlot] \ IO =
        let average = Texture3d.mipAverageOf(Texture3d.mipSpaceOf(textureUse));
        findTexture(source, name) |> Option.map(hit -> match hit {
            case TextureHit.Own(t)        => TextureSlot.Scene(sceneTextureKey(gl, t, average))
            case TextureHit.Registered(_) => TextureSlot.Copy(mipCopyKey(gl, name, average))
        })

    /// 段の列を GPU に置いた時の大きさ（バイト）。
    def chainBytes(chain: List[ShaderEval.TexData]): Int64 =
        chain |> List.foldLeft((acc, td) -> acc + Int32.toInt64(td#width) * Int32.toInt64(td#height) * 4i64, 0i64)

    /// 置き場の上限で捨てる物を選ぶ時の 1 つ。size = 大きさ（絵はバイト・形は頂点の数）・
    /// counted = 枚数の上限に数える（場面の絵は数え、段つきの写しは大きさにだけ数える）・preloaded = 先に上げた物。
    pub type alias BudgetEntry = { lastUsed = Int64, size = Int64, counted = Bool, preloaded = Bool }

    /// 置き場の上限。count = 枚数（counted の物だけ）・size = 大きさの合計。
    pub type alias Budget = { count = Int32, size = Int64 }

    /// entries が budget を超えているか。
    pub def isOverBudget(budget: Budget, entries: List[(k, BudgetEntry)]): Bool =
        let (n, size) = budgetTotals(entries);
        n > budget#count or size > budget#size

    def budgetTotals(entries: List[(k, BudgetEntry)]): (Int32, Int64) =
        entries |> List.foldLeft((acc, ke) -> {
            let (n, size) = acc;
            let e = snd(ke);
            (if (e#counted) n + 1 else n, size + e#size)
        }, (0, 0i64))

    /// entries を budget に収めるために捨てる物の鍵（捨てる順）。最後に使った世代が keepFrom より前の物だけを、先に上げていない物から、
    /// 古い物から選ぶ（同じ世代は鍵の順）。大きさが収まっていて枚数だけが超えている間は、枚数に数えない物を飛ばす。収まっていれば Nil。
    pub def budgetEvictions(budget: Budget, keepFrom: Int64, entries: List[(k, BudgetEntry)]): List[k] with Order[k] =
        let (n, size) = budgetTotals(entries);
        if (n <= budget#count and size <= budget#size) Nil
        else {
            let inDropOrder = entries |> List.filter(ke -> snd(ke)#lastUsed < keepFrom)
                |> List.map(ke -> ((snd(ke)#preloaded, snd(ke)#lastUsed, fst(ke)), ke)) |> List.sortBy(fst) |> List.map(snd);
            let (victims, _, _) = inDropOrder |> List.foldLeft((acc, ke) -> {
                let (picked, leftN, leftSize) = acc;
                let (k, e) = ke;
                if (leftSize > budget#size or (leftN > budget#count and e#counted))
                    (k :: picked, if (e#counted) leftN - 1 else leftN, leftSize - e#size)
                else acc
            }, (Nil, n, size));
            List.reverse(victims)
        }

    /// 場面の絵と段つきの写しを、置き場の上限を超えた時だけ、今と前のコマで使っていない古い物から捨てる（画面のコマの終わりに 1 回）。
    /// 今と前のコマで使う物だけで上限を超えていたら 1 回だけ知らせる（Pass の場面は画面のコマの 1 つ前の世代で描かれる）。
    // WhyNot: しばらく使わなかった絵を捨てない — たまにしか出ない物の絵を出すたびに CPU で段を作り直し、そのコマが跳ねる。
    pub def sweepTextures3d(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        let held = Ref.get(state#textures3dRef);
        let copies = Ref.get(state#mipCopiesRef);
        let preloaded = Ref.get(state#preloadRef)#textures;
        let entryOf = (slot, lastUsed, bytes, counted) -> (slot, { lastUsed = lastUsed, size = bytes, counted = counted, preloaded = Set.memberOf(slot, preloaded) });
        let entries = List.append(
            Map.toList(held) |> List.map(ke -> entryOf(TextureSlot.Scene(fst(ke)), snd(ke)#lastUsed, snd(ke)#bytes, true)),
            Map.toList(copies) |> List.map(ke -> entryOf(TextureSlot.Copy(fst(ke)), snd(ke)#lastUsed, snd(ke)#bytes, false)));
        let budget = { count = state#textureCountBudget, size = state#textureByteBudget };
        let victims = budgetEvictions(budget, gen - 1i64, entries);
        if (List.isEmpty(victims)) () else dropTextures(gl, state, victims);
        warnDroppedTextures(state, victims, preloaded);
        let victimSet = List.toSet(victims);
        // WhyNot: 捨てる物を選べたかで知らせを決めない — 今と前のコマで使う物だけで超えている時は、捨てる物が無くても超えたまま。
        if (isOverBudget(budget, List.filter(ke -> not Set.memberOf(fst(ke), victimSet), entries)))
            warnSceneOnce(state, "@budget", "scene3d: 場面の絵（Texture3d と材質の段つきの写し）が ${state#textureCountBudget} 枚か"
                + " ${Int64.toString(state#textureByteBudget / 1048576i64)} MB を超えて使われている — 絵を減らすか小さくするか、project.json の scene3dTextureBudgetCount / scene3dTextureBudgetMB を上げる")
        else ()

    /// 置き場から victims の絵を GPU ごと捨てる。
    def dropTextures(gl: GlContext, state: State, victims: List[TextureSlot]): Unit \ IO =
        let (held, copies) = victims |> List.foldLeft((acc, slot) -> {
            let (h, c) = acc;
            match slot {
                case TextureSlot.Scene(key) =>
                    Map.get(key, h) |> Option.forEach(e -> gl.deleteTexture(e#texId));
                    (Map.remove(key, h), c)
                case TextureSlot.Copy(key) =>
                    Map.get(key, c) |> Option.forEach(e -> gl.deleteTexture(e#texId));
                    (h, Map.remove(key, c))
            }
        }, (Ref.get(state#textures3dRef), Ref.get(state#mipCopiesRef)));
        Ref.put(held, state#textures3dRef);
        Ref.put(copies, state#mipCopiesRef)

    // ── 材質のプログラムの置き場 ──


    /// 材質のプログラムを引く。無いか、同じ鍵で中身が違えば組み直す。組めなかった材質は None（頂点の色で描く）。
    def materialEntry(gl: GlContext, state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind): Option[MaterialEntry] \ IO =
        let key = materialKey(m, kind);
        let cache = Ref.get(state#materialsRef);
        let entry = match Map.get(key, cache) {
            case Some(found) => reuseOrRebuild(gl, state, gen, { key = key, kind = kind }, found, m)
            case None        => rebuildMaterial(gl, state, gen, { key = key, kind = kind }, None, m)
        };
        Ref.put(Map.insert(key, entry, Ref.get(state#materialsRef)), state#materialsRef);
        if (entry#locs#mesh#program == 0) None else Some(entry)

    def sameMaterial(entry: MaterialEntry, m: Scene3d.MaterialFields): Bool =
        ShaderGen.eqMaterial(entry#spec, entry#emission, entry#metallicRoughness, m#spec, m#emission, m#metallicRoughnessShade)

    /// 同じ鍵の found を使い続けるか組み直すか。前に同じと確かめた参照なら木を比べない。
    def reuseOrRebuild(gl: GlContext, state: State, gen: Int64, slot: { key = String, kind = ProgramKind }, found: MaterialEntry,
                       m: Scene3d.MaterialFields): MaterialEntry \ IO =
        match knownAfterHit(m, found#known) {
            case Some(known)                    => { known = known, lastUsed = gen | found }
            case None if sameMaterial(found, m) => { known = List.take(knownMaterialLimit(), (m#spec, m#emission, m#metallicRoughnessShade) :: found#known), lastUsed = gen | found }
            case None                           => rebuildMaterial(gl, state, gen, slot, Some(found), m)
        }

    /// m の参照が known にあれば、それを頭へ動かした known（頭なら並べ直さない）。無ければ None。
    def knownAfterHit(m: Scene3d.MaterialFields, known: List[(ShaderDoc.Spec, Option[ShaderDoc.Shade], Option[ShaderDoc.Shade])]): Option[List[(ShaderDoc.Spec, Option[ShaderDoc.Shade], Option[ShaderDoc.Shade])]] =
        match known {
            case k :: _ if isSameRef(m, k) => Some(known)
            case _                         =>
                let (hit, rest) = List.partition(isSameRef(m), known);
                if (List.isEmpty(hit)) None else Some(List.append(hit, rest))
        }

    def isSameRef(m: Scene3d.MaterialFields, k: (ShaderDoc.Spec, Option[ShaderDoc.Shade], Option[ShaderDoc.Shade])): Bool =
        let (spec, emission, metallicRoughness) = k;
        ShaderGen.isSameSpec(spec, m#spec) and ShaderGen.isSameEmission(emission, m#emission) and ShaderGen.isSameEmission(metallicRoughness, m#metallicRoughnessShade)

    /// 鍵ごとに覚えておく、同じと確かめた材質の参照の数。
    // WhyNot: 最後に来た 1 つだけを覚えない — 同じプログラムを使う別の材質（絵の名前だけ違う物）が交互に来ると、1 つごとに木を比べ直す。
    // WhyNot: 数を限らずに覚えない — 毎コマ材質を作り直すゲームでは、古い材質を持ち続けて増え続ける。
    def knownMaterialLimit(): Int32 = 8

    /// 鍵 key の材質を組み直す。古いプログラムはすぐ消さず引退させる（同じコマの先の物がまだ使う）。
    def rebuildMaterial(gl: GlContext, state: State, gen: Int64, slot: { key = String, kind = ProgramKind }, old: Option[MaterialEntry],
                        m: Scene3d.MaterialFields): MaterialEntry \ IO =
        old |> Option.forEach(e -> {
            if (e#lastUsed == gen) warnMaterialThrash(state, slot#key, m#spec#name) else ();
            retireMaterial(state, e)
        });
        let reason = if (Option.isEmpty(old)) FrameDiagnostics.BuildReason.First else FrameDiagnostics.BuildReason.Changed("spec か emission か metallicRoughness の木");
        buildMaterial(gl, state, gen, m, slot#kind, reason)

    /// 材質のプログラムを組み、組んだ理由 reason と一緒に診断へ控える。読む絵の組が Scene3d.maxMaterialTextures() を超える材質は、
    /// 後ろの組を 0 にして組み、1 回知らせる。
    def buildMaterial(gl: GlContext, state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind,
                      reason: FrameDiagnostics.BuildReason): MaterialEntry \ IO =
        Array.put(1, 2, state#materialStreak);
        let readCount = List.length(ShaderDoc.materialTexReads(m#spec, m#emission, m#metallicRoughnessShade));
        if (readCount > Scene3d.maxMaterialTextures())
            warnSceneOnce(state, "limit:" + m#spec#name, "scene3d: 材質 '${m#spec#name}' が読む絵の組が ${readCount} 組ある"
                + " — ${Scene3d.maxMaterialTextures()} 組目より後ろは 0 で描く")
        else ();
        let (spec, emission, metallicRoughness) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), m#spec, m#emission, m#metallicRoughnessShade);
        let glsl = ShaderGen.compile3d(spec, emission, metallicRoughness);
        let label = "scene3d:material" + (if (kind#skinned) ":skin" else "") + (if (kind#uv) ":uv" else "")
            + (if (kind#normalMap) ":nm" else "") + (if (kind#lightmap) ":lm" else "") + (if (kind#blend) ":bl" else "")
            + (if (kind#doubleSided) ":ds" else "") + (if (kind#coverage) ":cov" else "") + (if (kind#metallicRoughness) ":mr" else "") + ":${m#spec#name}";
        noteMaterialBuild(state, label, reason);
        let vertex = materialVertexSource({ skinned = kind#skinned, uv = kind#uv, lightmap = kind#lightmap });
        let fragment = materialFragmentSource(glsl, kind);
        let program = match RenderShader.tryCreateProgram(gl, vertex, fragment, label) {
            case Some(p) => p
            case None    =>
                Log.warnThen("scene3d: 材質 '${m#spec#name}' のプログラムが組めなかった — この材質の物は頂点の色で描く", 0)
        };
        bindDataTextureUnits(gl, program);
        bindTextureUnits(gl, program, List.length(glsl#texReads), kind#normalMap, kind#lightmap);
        { spec = m#spec, emission = m#emission, metallicRoughness = m#metallicRoughnessShade,
          known = (m#spec, m#emission, m#metallicRoughnessShade) :: Nil, paramNames = glsl#paramNames, texReads = glsl#texReads, normalMapped = kind#normalMap,
          lightmapped = kind#lightmap, coverage = kind#coverage,
          locs = materialLocsOf(gl, program, glsl#paramNames, List.length(glsl#texReads)), lastUsed = gen }

    /// uTexN を unit N へ、uNormalMap を法線マップの unit へ向ける（プログラムごとに 1 回。組めなかったプログラムと、
    /// 絵も法線マップも無い材質は何もしない）。
    def bindTextureUnits(gl: GlContext, program: Int32, count: Int32, normalMap: Bool, lightmap: Bool): Unit \ IO =
        if (program == 0 or (count == 0 and not normalMap and not lightmap)) ()
        else {
            gl.useProgram(program);
            List.range(0, count) |> List.forEach(unit -> gl.uniform1i(loc(gl, program, "uTex${unit}"), unit));
            if (normalMap) gl.uniform1i(loc(gl, program, "uNormalMap"), normalMapTextureUnit()) else ();
            if (lightmap) gl.uniform1i(loc(gl, program, "uLightmap"), lightmapTextureUnit()) else ();
            gl.useProgram(0)
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

    def materialLocsOf(gl: GlContext, program: Int32, paramNames: List[String], texCount: Int32): MaterialLocs \ IO =
        { mesh = meshLocsOf(gl, program), light = lightLocsOf(gl, program), shadow = shadowLocsOf(gl, program),
          time = loc(gl, program, "uTime"), cutout = loc(gl, program, "uCutout"),
          depthOut = loc(gl, program, "uDepthOut"), depthRange = loc(gl, program, "uDepthRange"),
          params = paramNames |> List.mapWithIndex((i, _) -> loc(gl, program, "uParam${i}")),
          texFlips = List.range(0, texCount) |> List.map(i -> loc(gl, program, "uTexFlip${i}")),
          normalStrength = loc(gl, program, "uNormalStrength"), normalFlip = loc(gl, program, "uNormalFlip"),
          texLevels = List.range(0, texCount) |> List.map(i -> loc(gl, program, "uTexLevels${i}")), normalLevels = loc(gl, program, "uNormalLevels"),
          lightmapLevels = loc(gl, program, "uLightmapLevels"), lightmapSrgb = loc(gl, program, "uLightmapSrgb"),
          lightmapIntensity = loc(gl, program, "uLightmapIntensity") }

    /// 引退した材質のプログラムを消し、使われない材質を LRU で追い出す（画面のコマの終わりに 1 回。捨てる物は materialEvictions）。
    pub def sweepMaterials(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        Ref.get(state#retiredMaterialsRef) |> List.forEach(program -> gl.deleteProgram(program));
        Ref.put(Nil, state#retiredMaterialsRef);
        let cache = Ref.get(state#materialsRef);
        let victims = materialEvictions(gen, Ref.get(state#preloadRef)#programs,
            Map.toList(cache) |> List.map(ke -> (fst(ke), snd(ke)#locs#mesh#program, snd(ke)#lastUsed)));
        if (List.isEmpty(victims)) ()
        else {
            victims |> List.forEach(key -> Map.get(key, cache) |> Option.forEach(e ->
                if (e#locs#mesh#program == 0) () else gl.deleteProgram(e#locs#mesh#program)));
            Ref.put(List.foldLeft((acc, key) -> Map.remove(key, acc), cache, victims), state#materialsRef)
        }

    /// entries = (鍵, プログラムの番号, 最後に使った世代)。追い出す材質の鍵。今と前のコマで使った材質
    /// （Pass の場面は画面のコマの 1 つ前の世代で描かれる）と、先に上げた preloaded は選ばない。
    pub def materialEvictions(gen: Int64, preloaded: Set[Int32], entries: List[(String, Int32, Int64)]): List[String] =
        let live = entries |> List.filterMap(e -> { let (_, program, lastUsed) = e; if (lastUsed >= gen - 1i64) Some(program) else None }) |> List.toSet;
        let pinned = Set.union(live, preloaded);
        // WhyNot: 上限を固定の数にしない — 材質の数はゲームが決めるので、多いゲームで毎コマ作っては捨てるだけになる。
        RenderShaderCache.computeEvictions({ entries = entries, pinned = pinned, cap = Int32.max(64, Set.size(pinned) * 2) })
}
