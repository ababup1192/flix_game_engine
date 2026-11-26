// Render3d.Material — 3D の描き手（Render3d）の材質のある置いた物（材質のプログラムと鍵・場面の絵の置き場・描き方）。約束は Render3d.flix の頭。
mod Render3d.Material {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import java.nio.{ByteBuffer, ByteOrder}
    use Render3d.Shadow.{putPointShadow, putShadow, putSunShadow}
    use Render3d.ShaderSourceKey
    use Render3d.Light.{putLights}
    use Render3d.Uniforms.{R3dUniform, put1f, put1i, put4f}
    use Render3d.{BoundTexture, CameraData, MaterialEntry, MaterialPass, MeshDraw, ProgramUniforms, State, TextureSlot, TextureSource, bindDataTextureUnits, bindUnits, ensureTangents, environmentTextureUnit, lightmapTextureUnit, normalMapTextureUnit, programUniformsOf, putDepthRange, useMeshProgram, warnDroppedTextures, warnSceneOnce}
    use Render3d.ProgramKey.{materialKey, ProgramKind}
    use Render3d.Batch.{MaterialBatch, SpanBatch}
    use Scene3dRenderer.{RegisteredTexture}
    use Render3d.Counts.{Counter, Phase, count, noteMaterialBuild, timed}
    use Render3d.ScenePlan.{MaterialRequest, groupInstances, splitGroups}
    use Render3d.TextureTable3d
    use Render3d.TextureTable3d.{TextureHit, findTexture}

    // ── 材質の表 ──

    /// 1 回の prepare の材質の表（GL の backend の持ち物）。entries = 聞かれた順の材質のプログラム（組めなかった物は program が 0）・
    /// orders = 計画へ返す順の番号（entries と同じ並び・0 = 使えないので頂点の色で描く）。
    // WhyNot: 描く時に材質の鍵の字で materialsRef から引き直さない — 計画は同じプログラムの材質を 1 つの問い合わせにまとめ（ScenePlan.requestOf）、
    //   木の鍵がぶつかった材質だけを別の問い合わせにする。字で引くと、その 2 つが同じ鍵の 1 つの控えを指し、後で組み直した方のプログラムで両方を描く。
    pub type alias MaterialTable = { entries = Vector[MaterialEntry], orders = Vector[Int32] }

    /// requests の材質のプログラムを聞かれた順に 1 回ずつ引き、初めての材質はここで組む（3D を使わないゲームと、材質を使わない場面は GLSL のコンパイルを払わない）。
    /// 間引く物の材質も組む（間引くのは描く段の手前）。
    // WhyNot: 間引いた物を材質の組み立ての前に除かない — 初めて振り向いたコマで GLSL を組んで止まる（読み込み中に先に組ませる作りが効かない）。
    pub def resolveMaterials(gl: GlContext, state: State, gen: Int64, requests: Vector[MaterialRequest]): MaterialTable \ IO =
        let entries = requests |> Vector.map(r -> lookupMaterial(gl, state, gen, fst(r), snd(r)));
        { entries = entries, orders = Vector.map(e -> e#uniforms#program, entries) }

    /// 表の handle 番の材質のプログラム。
    pub def entryAt(table: MaterialTable, handle: Int32): MaterialEntry = Vector.get(handle, table#entries)

    /// 置いた物を候補に分け、材質を引き、batch に分けるまでを 1 回で通す（GL を持つ側の形。表は材質の batch が貼る絵の名前を引くのに要る）。
    pub def splitByMaterial(gl: GlContext, state: State, gen: Int64, outside: Scene3d.Instance3d -> Bool, wants: Scene3d.MaterialFields -> Bool, coverage: Bool,
                            instances: List[Scene3d.Instance3d]): ((List[SpanBatch], List[MaterialBatch[SpanBatch]]), MaterialTable) \ IO =
        timed(state, Phase.Split, () -> {
            let (groups, requests) = groupInstances(state#planner, Render3d.ProgramKey.defaultShaderVariant(), outside, wants, coverage, instances);
            let table = resolveMaterials(gl, state, gen, requests);
            (splitGroups(groups, table#orders), table)
        })

    /// 材質を描く間に付けた物の控え。0 = 今のプログラム・1 = 貼った材質の絵の unit の数・2 = 法線マップを貼ったら 1・3 = lightmap を貼ったら 1。
    pub def freshBound(): Array[Int32, Static] \ IO = Array#{0, 0, 0, 0} @ Static

    /// entry のプログラムが今の物と違えば付け替え、場面の値（目・光・影・時刻・出す物）を入れる。
    pub def useMaterial(gl: GlContext, state: State, camera: CameraData, pass: MaterialPass, bound: Array[Int32, Static], entry: MaterialEntry): Unit \ IO =
        let program = entry#uniforms#program;
        if (program == Array.get(0, bound)) ()
        else {
            Array.put(program, 0, bound);
            useMaterialProgram(gl, state, camera, pass, entry#uniforms)
        }

    /// 材質 m（頭の物 head）の cutout・params・絵・法線マップ・lightmap を、今付いている entry のプログラムへ入れ、貼った unit を bound に控える。
    pub def bindMaterial(gl: GlContext, state: State, gen: Int64, source: TextureSource, bound: Array[Int32, Static], entry: MaterialEntry,
                         m: Scene3d.MaterialFields, head: MeshDraw): Unit \ IO =
        let locs = entry#uniforms#locs;
        put1i(gl, locs, R3dUniform.Cutout, if (m#cutout) 1 else 0);
        // WhyNot: ShaderDoc.materialParamValues で並べない — あちらは上限を超えた tex を 0 にする前の Spec から名前を拾い、
        //   compile3d が uParamN に割り当てた並び（0 にした後）と食い違う余地がある。uniform を宣言した側の並びで引く。
        entry#paramNames |> List.forEachWithIndex((i, name) ->
            put1f(gl, locs, R3dUniform.Param(i), RenderUtil.f32(Map.getWithDefault(name, 0.0, m#params))));
        let units = bindMaterialTextures(gl, state, gen, source, entry, m);
        bindNormalMap(gl, state, gen, source, entry, m);
        bindLightmap(gl, state, gen, source, entry, head);
        if (entry#normalMapped) ensureTangents(gl, state, gen, head#fields#mesh) else ();
        Array.put(Int32.max(units, Array.get(1, bound)), 1, bound);
        if (entry#normalMapped) Array.put(1, 2, bound) else ();
        if (entry#lightmapped) Array.put(1, 3, bound) else ()

    /// drawMesh を、look#coverage なら alpha to coverage を付けて（cutout を discard でなく出す α を標本の数に使って抜き、書く α は 1。GL_SAMPLE_ALPHA_TO_ONE）・
    /// look#doubleSided ならカリングを切って呼ぶ（呼んだ後に戻す）。
    pub def drawWithLook(gl: GlContext, look: { coverage = Bool, doubleSided = Bool }, drawMesh: Unit -> Unit \ IO): Unit \ IO =
        if (look#coverage) {
            gl.enable(GlConst.SAMPLE_ALPHA_TO_COVERAGE);
            gl.enable(GlConst.SAMPLE_ALPHA_TO_ONE)
        } else ();
        if (look#doubleSided) {
            gl.disable(GlConst.CULL_FACE);
            drawMesh();
            gl.enable(GlConst.CULL_FACE)
        } else drawMesh();
        if (look#coverage) {
            gl.disable(GlConst.SAMPLE_ALPHA_TO_COVERAGE);
            gl.disable(GlConst.SAMPLE_ALPHA_TO_ONE)
        } else ()

    /// bound に控えた、絵を貼った unit の sampler を外して unit 0 へ戻す。
    pub def releaseBound(gl: GlContext, bound: Array[Int32, Static]): Unit \ IO =
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

    def useMaterialProgram(gl: GlContext, state: State, camera: CameraData, pass: MaterialPass, p: ProgramUniforms): Unit \ IO =
        let locs = p#locs;
        useMeshProgram(gl, p, camera#view, camera#proj);
        putLights(gl, locs, camera#lights);
        putShadow(gl, locs, camera#shadows#spot);
        putSunShadow(gl, locs, camera#shadows#sun);
        putPointShadow(gl, locs, camera#shadows#point);
        put1f(gl, locs, R3dUniform.Time, RenderUtil.f32(Array.get(0, state#timeHolder)));
        match pass {
            case MaterialPass.Color     => put1i(gl, locs, R3dUniform.DepthOut, 0)
            case MaterialPass.Depth(dr) =>
                put1i(gl, locs, R3dUniform.DepthOut, 1);
                putDepthRange(gl, locs, dr)
        }

    /// lightmap を lightmap の unit に貼り、段の数・色空間・強さ・atlas の矩形を入れる（Clamp・段つきの Linear で読む）。lightmap を読まないプログラムは何もしない。
    /// 名前が場面の textures に無い絵は 0（黒）で読み、名前ごとに 1 回知らせる（材質の絵と同じ道）。
    // WhyNot: プログラムごとに 1 回だけ入れない — 同じ形と材質で lightmap だけ違う物は同じプログラムで続けて描かれ、前の物の絵と強さを引き継ぐ。
    def bindLightmap(gl: GlContext, state: State, gen: Int64, source: TextureSource, entry: MaterialEntry, head: MeshDraw): Unit \ IO =
        if (not entry#lightmapped) ()
        else Scene3d.lightmapOfFields(head#fields) |> Option.forEach(lm -> {
            let unit = lightmapTextureUnit();
            gl.activeTexture(GlConst.TEXTURE0 + unit);
            let bound = resolveTextureAs(gl, state, gen, source, "lightmap の絵", lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace));
            gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
            gl.bindSampler(unit, materialSampler(gl, state, Scene3d.Wrap.Clamp, ShaderDoc.FilterMode.Linear, bound#levels > 1));
            let locs = entry#uniforms#locs;
            put1f(gl, locs, R3dUniform.LightmapLevels, RenderUtil.f32(Int32.toFloat64(Render3d.MaterialValues.lightmapLevelsOf(lm, bound#levels))));
            put1i(gl, locs, R3dUniform.LightmapSrgb, if (Render3d.MaterialValues.lightmapSrgbOf(source, lm)) 1 else 0);
            put1f(gl, locs, R3dUniform.LightmapIntensity, RenderUtil.f32(lm#intensity));
            put4f(gl, locs, R3dUniform.LightmapUvRect, RenderUtil.f32(lm#uvRect#position#x), RenderUtil.f32(lm#uvRect#position#y),
                  RenderUtil.f32(lm#uvRect#size#x), RenderUtil.f32(lm#uvRect#size#y))
        })

    /// 場面の環境マップを環境マップの unit に貼り、絵の段の数を返す（無ければ 0・何も貼らない）。名前が場面の textures に無い絵は 0（黒）の 1 段で読み、
    /// 名前ごとに 1 回知らせる。Repeat・段つきの Linear で読む（横の継ぎ目を回り込んで混ぜる）。場面を描く前に 1 回呼ぶ（絵を上げる時に今の unit へ貼るので、unit を選んでから引く）。
    // WhyNot: 場面の材質ごとに貼らない — 絵は場面に 1 枚で、材質のプログラムが何本あっても同じ unit を読む。
    pub def bindEnvironmentMap(gl: GlContext, state: State, gen: Int64, source: TextureSource, scene: Scene3d.Scene3dCmd): Int32 \ IO =
        match scene#environmentMap {
            case None    => 0
            case Some(e) =>
                let unit = environmentTextureUnit();
                gl.activeTexture(GlConst.TEXTURE0 + unit);
                let bound = resolveTextureAs(gl, state, gen, source, "環境マップの絵", Scene3d.environmentMapFieldsOf(e)#texture, Texture3d.TextureUse.MaterialTexture);
                gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
                gl.bindSampler(unit, materialSampler(gl, state, Scene3d.Wrap.Repeat, ShaderDoc.FilterMode.Linear, bound#levels > 1));
                gl.activeTexture(GlConst.TEXTURE0);
                bound#levels
        }

    /// 環境マップの unit の sampler を外す（ビルボードと 2D の面は貼り直さず unit の物を読む）。貼っていなければ何もしない。
    pub def releaseEnvironmentMap(gl: GlContext, scene: Scene3d.Scene3dCmd): Unit \ IO =
        if (Option.isEmpty(scene#environmentMap)) () else gl.bindSampler(environmentTextureUnit(), 0)

    /// 法線マップを法線マップの unit に貼る（材質の wrap・Linear で読む）。法線マップを当てないプログラムは何もしない。
    def bindNormalMap(gl: GlContext, state: State, gen: Int64, source: TextureSource, entry: MaterialEntry, m: Scene3d.MaterialFields): Unit \ IO =
        match (entry#normalMapped, m#normalMap) {
            case (true, Some(n)) =>
                let unit = normalMapTextureUnit();
                gl.activeTexture(GlConst.TEXTURE0 + unit);
                let bound = resolveMaterialTexture(gl, state, gen, source, n#texture, Texture3d.TextureUse.NormalMap);
                gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
                gl.bindSampler(unit, materialSampler(gl, state, m#wrap, ShaderDoc.FilterMode.Linear, bound#levels > 1));
                let locs = entry#uniforms#locs;
                put1f(gl, locs, R3dUniform.NormalStrength, RenderUtil.f32(n#strength));
                put1f(gl, locs, R3dUniform.NormalFlip, if (bound#flipped) 1.0f32 else 0.0f32);
                put1f(gl, locs, R3dUniform.NormalLevels, RenderUtil.f32(Int32.toFloat64(bound#levels)))
            case _ => ()
        }

    /// 材質の絵を unit 0〜 に貼り、読み方（wrap と補間）の sampler を付けて、貼った数を返す。
    /// 名前は描く材質から引き直す（eqSpec は tex の名前を並びの番号で比べるので、名前だけ違う材質が同じプログラムを使う）。
    def bindMaterialTextures(gl: GlContext, state: State, gen: Int64, source: TextureSource, entry: MaterialEntry, m: Scene3d.MaterialFields): Int32 \ IO =
        if (List.isEmpty(entry#texReads)) 0
        else {
            let locs = entry#uniforms#locs;
            let reads = Scene3d.materialTexReadsOf(m) |> List.take(Scene3d.maxMaterialTextures());
            reads |> List.take(List.length(entry#texReads)) |> List.forEachWithIndex((unit, read) -> {
                let (name, filter) = read;
                // WhyNot: 引いてから unit を選ばない — 初めての絵は引く時に上げて今の unit に貼るので、前の unit に貼った絵を外してしまう。
                gl.activeTexture(GlConst.TEXTURE0 + unit);
                let bound = resolveMaterialTexture(gl, state, gen, source, name, Texture3d.TextureUse.MaterialTexture);
                gl.bindTexture(GlConst.TEXTURE_2D, bound#texId);
                gl.bindSampler(unit, materialSampler(gl, state, m#wrap, filter, bound#levels > 1));
                put1f(gl, locs, R3dUniform.TexFlip(unit), if (bound#flipped) 1.0f32 else 0.0f32);
                put1f(gl, locs, R3dUniform.TexLevels(unit), RenderUtil.f32(Int32.toFloat64(Scene3d.materialMipLevelsOf(m, bound#levels))))
            });
            List.length(reads)
        }

    /// 材質の Tex の名前を、貼る GPU のテクスチャ・上下を反転して読むか（レンダーターゲット）・段の数へ引く。
    /// "tex3d:" は場面の textures（置き場に無ければ段ごと上げる）・ほかは全体の登録（段つきの写しを作る。レンダーターゲットは
    /// 毎コマ書き換わるので段を作らず、そのまま読む）・どちらにも無ければ透明な黒（名前ごとに 1 回知らせる）。
    /// half の絵（Texture3d.Format.Rgba16Float）は環境マップと lightmap の絵の約束なので、材質の絵としては透明な黒を貼る（絵ごとに 1 回知らせる。CPU の描き手と同じ 0）。
    def resolveMaterialTexture(gl: GlContext, state: State, gen: Int64, source: TextureSource, name: String, textureUse: Texture3d.TextureUse): BoundTexture \ IO =
        match findTexture(source, name) {
            case Some(TextureHit.Own(t)) if Texture3d.formatOf(t) == Texture3d.Format.Rgba16Float =>
                warnSceneOnce(state, "@hdr-texture-in-material:" + name, Texture3d.Internal.hdrInMaterialLine(name));
                { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
            case _ => resolveTextureAs(gl, state, gen, source, "材質の絵", name, textureUse)
        }

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

    /// 全体の登録の絵 t の段つきの写し（average で平均した段。置き場の鍵は名前と平均の仕方。
    /// 無いか、元の絵が作り直されていたら、元の段 0 を読み戻して段を作り、上げ直す）。
    // WhyNot: 登録の絵の画素を Java の側に持ち続けない — STB で直に上げているので持っておらず、全部の絵をヒープに二重に持つことになる。
    def mipCopyOf(gl: GlContext, state: State, gen: Int64, name: String, average: Mip.Average, t: RegisteredTexture): BoundTexture \ IO =
        let slot = TextureSlot.Copy(mipCopyKey(gl, name, average));
        let make = (handle: Int32) -> {
            count(state, Counter.MipCopies, 1);
            let w = Float64.tryToInt32(Float64.round(t#width)) |> Option.getWithDefault(1);
            let h = Float64.tryToInt32(Float64.round(t#height)) |> Option.getWithDefault(1);
            let up = mipCopyUpload(gl, state, average, t#texId, w, h);
            Ref.put(Map.insert(handle, up#texId, Ref.get(state#textureIdsRef)), state#textureIdsRef);
            Some({ levels = up#levels, bytes = up#bytes })
        };
        match TextureTable3d.ensure(state#textures3d, destroyTexture(gl, state), gen, slot, copyStamp(t), make) {
            case Some((handle, c)) => { texId = textureIdOf(gl, state, handle), flipped = false, levels = c#levels }
            case None              => { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
        }

    /// 段つきの写しを作り直す鍵（元の絵の番号と版。どちらかが変われば元の絵が作り直された）。
    def copyStamp(t: RegisteredTexture): String = "${t#texId}:${t#version}"

    /// 表の番号 handle の GL のテクスチャ（作ってあれば。無ければ透明な黒）。
    def textureIdOf(gl: GlContext, state: State, handle: Int32): Int32 \ IO =
        Map.get(handle, Ref.get(state#textureIdsRef)) |> Option.getWithDefault(blankTextureId(gl, state))

    /// 絵の表（Render3d.TextureTable3d）へ渡す、GL のテクスチャを捨てる関数。
    def destroyTexture(gl: GlContext, state: State): Int32 -> Unit \ IO = handle -> {
        Map.get(handle, Ref.get(state#textureIdsRef)) |> Option.forEach(texId -> gl.deleteTexture(texId));
        Ref.put(Map.remove(handle, Ref.get(state#textureIdsRef)), state#textureIdsRef)
    }

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

    def mipKeyOf(gl: GlContext, average: Mip.Average): String \ IO = TextureTable3d.mipKeyOf(gl.prefersGpuMipmap(), average)

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
            case Texture3d.Source.Rgba16Float(halves) => Some(uploadHalfMipped(gl, state, width, height, halves))
        }

    /// half の絵を CPU で作った段（Mip.buildRgba16Float）ごと RGBA16F で上げる（1 画素 8 バイト）。
    // WhyNot: half の段を GPU に作らせない — 8bit の絵の Mip.build と同じく、CPU の描き出しと段の中身がそろわない。
    def uploadHalfMipped(gl: GlContext, state: State, width: Int32, height: Int32, halves: Vector[Int16]): MippedUpload \ IO =
        let chain = timed(state, Phase.Mip, () -> Mip.buildRgba16Float(width, height, halves));
        let texId = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, texId);
        chain |> List.forEachWithIndex((level, entry) -> {
            let (w, h, bits) = entry;
            let direct = ByteBuffer.allocateDirect(Int32.max(8, Vector.length(bits) * 2)).order(ByteOrder.nativeOrder()).asShortBuffer();
            discard direct.put(unchecked_cast(bits as Array[Int16, Static]));
            discard direct.flip();
            gl.texImageRgba16fLevel(level, w, h, direct)
        });
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_BASE_LEVEL, 0);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAX_LEVEL, Int32.max(0, List.length(chain) - 1));
        { texId = texId, levels = List.length(chain),
          bytes = chain |> List.foldLeft((acc, entry) -> { let (w, h, _) = entry; acc + Int32.toInt64(w) * Int32.toInt64(h) * 8i64 }, 0i64) }

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
    /// 上げられなかった絵は透明な黒を貼る（絵ごとに 1 回知らせ、Render3d.TextureTable3d.retryFrames の後に試し直す）。
    def texture3dBound(gl: GlContext, state: State, gen: Int64, average: Mip.Average, t: Texture3d.Texture3d): BoundTexture \ IO =
        let key = sceneTextureKey(gl, t, average);
        let make = (handle: Int32) -> {
            count(state, Counter.Texture3dUploads, 1);
            match uploadTexture3d(gl, state, average, t) {
                case Some(up) =>
                    Ref.put(Map.insert(handle, up#texId, Ref.get(state#textureIdsRef)), state#textureIdsRef);
                    Some({ levels = up#levels, bytes = up#bytes })
                case None =>
                    warnSceneOnce(state, "platform:" + key, "scene3d: 場面の絵 '${Texture3d.name(t)}' を機種の側から上げられない — 0（黒・透明）で読む");
                    None
            }
        };
        match TextureTable3d.ensure(state#textures3d, destroyTexture(gl, state), gen, TextureSlot.Scene(key), "", make) {
            case Some((handle, c)) => { texId = textureIdOf(gl, state, handle), flipped = false, levels = c#levels }
            case None              => { texId = blankTextureId(gl, state), flipped = false, levels = 1 }
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
                |> Sort.sortStableBy(ke -> (snd(ke)#preloaded, snd(ke)#lastUsed, fst(ke)));
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
        let preloaded = Ref.get(state#preloadRef)#textures;
        let budget = { count = state#textureCountBudget, size = state#textureByteBudget };
        let (victims, over) = TextureTable3d.sweep(state#textures3d, destroyTexture(gl, state), gen, budget, preloaded);
        warnDroppedTextures(state#planner, victims, preloaded);
        // WhyNot: 捨てる物を選べたかで知らせを決めない — 今と前のコマで使う物だけで超えている時は、捨てる物が無くても超えたまま。
        if (over)
            warnSceneOnce(state, "@budget", "scene3d: 場面の絵（Texture3d と材質の段つきの写し）が ${state#textureCountBudget} 枚か"
                + " ${Int64.toString(state#textureByteBudget / 1048576i64)} MB を超えて使われている — 絵を減らすか小さくするか、project.json の scene3dTextureBudgetCount / scene3dTextureBudgetMB を上げる")
        else ()


    // ── 材質のプログラムの置き場 ──


    /// 材質のプログラムを引く。無いか、同じ鍵で中身が違えば組み直す。組めなかった材質は uniforms#program が 0（頂点の色で描く）。
    def lookupMaterial(gl: GlContext, state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind): MaterialEntry \ IO =
        let key = materialKey(m, kind);
        let cache = Ref.get(state#materialsRef);
        let entry = match Map.get(key, cache) {
            case Some(found) => reuseOrRebuild(gl, state, gen, { key = key, kind = kind }, found, m)
            case None        => rebuildMaterial(gl, state, gen, { key = key, kind = kind }, None, m)
        };
        Ref.put(Map.insert(key, entry, Ref.get(state#materialsRef)), state#materialsRef);
        entry

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
        let readCount = List.length(Scene3d.materialTexReadsOf(m));
        if (readCount > Scene3d.maxMaterialTextures())
            warnSceneOnce(state, "limit:" + m#spec#name, "scene3d: 材質 '${m#spec#name}' が読む絵の組が ${readCount} 組ある"
                + " — ${Scene3d.maxMaterialTextures()} 組目より後ろは 0 で描く")
        else ();
        let (spec, emission, metallicRoughness) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), m#spec, m#emission, m#metallicRoughnessShade);
        let glsl = ShaderGen.compile3d(spec, emission, metallicRoughness);
        let label = "scene3d:material" + (if (kind#skinned) ":skin" else "") + (if (kind#uv) ":uv" else "")
            + (if (kind#normalMap) ":nm" else "") + (if (kind#lightmap) ":lm" else "") + (if (kind#blend) ":bl" else "")
            + (if (kind#doubleSided) ":ds" else "") + (if (kind#coverage) ":cov" else "") + (if (kind#metallicRoughness) ":mr" else "")
            + String.replace(src = "+", dst = ":", Render3d.ProgramKey.variantKeyOf(kind#variant)) + ":${m#spec#name}";
        noteMaterialBuild(state, label, reason);
        let fragment = Render3d.ShaderLibrary.materialGlsl(state#shaders, kind, m#cutout, glsl);
        let vertex = Render3d.ShaderLibrary.optionalGlsl(state#shaders,
            ShaderSourceKey.MaterialVertex({ skinned = kind#skinned, uv = kind#uv, lightmap = kind#lightmap, psx = kind#variant#psx }));
        let (program, sources) = match (vertex, fragment) {
            case (Some(vs), Some(fs)) => match RenderShader.tryCreateProgram(gl, vs, fs, label) {
                case Some(p) => (p, vs :: fs :: Nil)
                case None    =>
                    (Log.warnThen("scene3d: 材質 '${m#spec#name}' のプログラムが組めなかった — この材質の物は頂点の色で描く", 0), Nil)
            }
            case _ => (0, Nil)
        };
        let uniforms = programUniformsOf(gl, program, sources);

        bindDataTextureUnits(gl, uniforms);
        bindTextureUnits(gl, uniforms, List.length(glsl#texReads), kind#normalMap, kind#lightmap, kind#metallicRoughness);
        { spec = m#spec, emission = m#emission, metallicRoughness = m#metallicRoughnessShade,
          known = (m#spec, m#emission, m#metallicRoughnessShade) :: Nil, paramNames = glsl#paramNames, texReads = glsl#texReads, normalMapped = kind#normalMap,
          lightmapped = kind#lightmap, coverage = kind#coverage,
          uniforms = uniforms, lastUsed = gen }

    /// uTexN を unit N へ、uNormalMap を法線マップの unit へ向ける（プログラムごとに 1 回。組めなかったプログラムと、
    /// 絵も法線マップも無い材質は何もしない）。
    def bindTextureUnits(gl: GlContext, p: ProgramUniforms, count: Int32, normalMap: Bool, lightmap: Bool, environment: Bool): Unit \ IO =
        if (count == 0 and not normalMap and not lightmap and not environment) ()
        else bindUnits(gl, p, List.flatten(
            (if (environment) (R3dUniform.EnvMap, environmentTextureUnit()) :: Nil else Nil) ::
            (List.range(0, count) |> List.map(unit -> (R3dUniform.Tex(unit), unit))) ::
            (if (normalMap) (R3dUniform.NormalMap, normalMapTextureUnit()) :: Nil else Nil) ::
            (if (lightmap) (R3dUniform.Lightmap, lightmapTextureUnit()) :: Nil else Nil) :: Nil))

    def retireMaterial(state: State, e: MaterialEntry): Unit \ IO =
        if (e#uniforms#program == 0) ()
        else Ref.put(e#uniforms#program :: Ref.get(state#retiredMaterialsRef), state#retiredMaterialsRef)

    def warnMaterialThrash(state: State, key: String, name: String): Unit \ IO =
        let warned = Ref.get(state#thrashWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), state#thrashWarnedRef);
            Log.warn("scene3d: 中身の違う材質の鍵（ShaderGen.hashMaterial）が同じコマにぶつかった（'${name}'）"
                + " — 毎コマ組み直している。spec か emission の数に NaN があれば直す（NaN は自分とも等しくない）。無ければ engine の不具合")
        }

    /// 引退した材質のプログラムを消し、使われない材質を LRU で追い出す（画面のコマの終わりに 1 回。捨てる物は materialEvictions）。
    pub def sweepMaterials(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        Ref.get(state#retiredMaterialsRef) |> List.forEach(program -> gl.deleteProgram(program));
        Ref.put(Nil, state#retiredMaterialsRef);
        let cache = Ref.get(state#materialsRef);
        let victims = materialEvictions(gen, Ref.get(state#preloadRef)#programs,
            Map.toList(cache) |> List.map(ke -> (fst(ke), snd(ke)#uniforms#program, snd(ke)#lastUsed)));
        if (List.isEmpty(victims)) ()
        else {
            victims |> List.forEach(key -> Map.get(key, cache) |> Option.forEach(e ->
                if (e#uniforms#program == 0) () else gl.deleteProgram(e#uniforms#program)));
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
