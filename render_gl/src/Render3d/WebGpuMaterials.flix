// Render3d.WebGpuMaterials — WebGPU の 3D の材質の分（材質の program・材質の絵の置き場・draw ごとの値の buffer・材質の pipeline と group 1）。
// Render3d.WebGpuRenderer が 1 つ持つ。材質は計画の問い合わせ（Render3d.ScenePlan.MaterialRequest）ごとに resolve で答え、行の values と reads
// （並びは Render3d.MaterialValues の頭）を、値の buffer の区画と絵の表（Render3d.TextureTable3d）の番号で group 1 に付ける。
// 描く材質: alpha to coverage でない材質（半透明・骨つき・uv・法線マップ・lightmap・両面・cutout・metallic と roughness を含む）。
// 描かない版は順の番号 0 で答え、計画は頂点の色の道へ回す（知らせるのは Render3d.WebGpuRenderer.skipsOf）。
// WhyNot: alpha to coverage の版を描かない — render_gl/java の RenderPipelineDesc に alphaToCoverage の口が無い（足すと GL の層の jar のハッシュが動く）。
//   計画には描き先の能力として「alpha to one が無い」と答え、cutout は discard で抜く（ブラウザの GL と同じ）。
// WhyNot: pub を外さない — 値の binding の形（ValuesBinding）を bench/webgpu_v2 の比べが選ぶ（親の Render3d が pub でないので、別のパッケージのゲームからは見えない）。
pub mod Render3d.WebGpuMaterials {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BlendFactor
    import fge.webgpu.BlendOperation
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FilterMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderCommands
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Sampler
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.util.HashSet
    use Render3d.{MeshDraw, ProgramKind, TextureSlot, TextureSource, materialKey}
    use Render3d.MaterialValues
    use Render3d.ScenePlan.{MaterialRequest}
    use Render3d.SceneList.{SceneList, SceneRowKind, flagLightmap, flagNormalMap, flagSameBinding, hasFlag, headAt, kindAt, materialAt, materialHandleAt, readAt, readCountAt, rowCountOf, valuesAt}
    use Render3d.TextureTable3d
    use Render3d.TextureTable3d.{TextureHit}
    use Render3d.WebGpuRows.{MeshBuffers}
    use RenderPaint.Internal.WebGpuPipelines

    /// 材質の値（sg と r3dDraw）の binding の形。Uniform = uniform の buffer の 256 バイトの区画・Storage = 読むだけの storage の buffer の同じ区画（比べ用・12.28）。
    // WhyNot: Storage の版を消さない — 行ごとに group を作らず group 1 つで区画を引く形（storage が効く形）を P9・P10 の前に測る時の比べ相手にする。
    //   ShaderGen の宣言の字を置き換える形は比べにだけ使い、本番は Uniform。
    pub enum ValuesBinding with Eq {
        case Uniform
        case Storage
    }

    /// 組んだ材質の program 1 つ。id = 順の番号（計画へ返す・0 でない）・fragment = 材質の frag・layout = group 1 の layout・
    /// slotCount = sg の欄の数（ShaderGen.Wgsl.compile3d の slots）・texCount = 材質の絵の数。
    pub type alias Program = { id = Int32, kind = ProgramKind, fragment = ShaderModule, layout = BindGroupLayout, slotCount = Int32, texCount = Int32 }

    /// GPU に置いた材質の絵 1 枚（場面の絵と、全体の登録の絵の mip つきの写し）。
    type alias GpuTexture = { texture = Texture, levels = Int32 }

    /// 全体の登録の絵の読み方。textureById = 登録の絵の番号 → 2D の描き手の texture・encoding = mip つきの写しを作る pass を積む encoder・
    /// noteCopy = 写しを 1 枚作ったと数える（診断の mipCopies）。
    pub type alias Registered = { textureById = Int32 -> Option[Texture] \ IO, encoding = Render3d.WebGpuMipmaps.Encoding, noteCopy = Unit -> Unit \ IO }

    /// 機種の側に持つ絵（Texture3d.Source.PlatformImage の key）を GPU へ写す口。
    /// has(key, 幅, 高さ) = その大きさの絵を今写せるか・copy(key, texture) = texture のレベル 0 の左上へ写す（写せたら真）。
    /// texture は RGBA8・usage に COPY_DST と RENDER_ATTACHMENT を持ち、絵と同じ大きさ。写した値は色の変換も α の前乗算もせず、行 0 が絵の上。
    pub type alias PlatformImages = { has = (String, Int32, Int32) -> Bool \ IO, copy = (String, Texture) -> Bool \ IO }

    /// 状態。programs = materialKey → 組んだ program（組めなければ None）・current = 今の prepare の問い合わせの順の program（行の欄 1 が引く）・
    /// vertexModules = (uv つきか, lightmap つきか, 骨つきか, PS1 風か) → 材質の頂点シェーダー・pipelines = MaterialPipelineKey → pipeline・
    /// textures = 絵の表・store = 絵の表の番号 → 絵・samplers = [Repeat Nearest, Repeat Linear, Clamp Nearest, Clamp Linear]・blank = 無い絵の代わり（1 × 1 の透明な黒）・
    /// values = 値の buffer（要素 1 つ・足りなければ作り直す）・valuesUsed = 今の encoder で使ったバイト数・groups = 今の encoder の group 1（submit の後に手放す）・
    /// bound = 今の pass で最後に付けた (pipeline の鍵の番号, 行の値の位置)・warned = 知らせ済みの材質の名前。
    enum MaterialsData {
        case MaterialsData({
            gpu = WebGpu,
            binding = ValuesBinding,
            programs = Ref[Map[String, Option[Program]], Static],
            nextId = Array[Int32, Static],
            current = Ref[Vector[Option[Program]], Static],
            vertexModules = Ref[Map[(Bool, Bool, Bool, Bool), ShaderModule], Static],
            pipelines = Ref[Map[MaterialPipelineSlot, RenderPipeline], Static],
            textures = TextureTable3d.Table,
            store = Ref[Map[Int32, GpuTexture], Static],
            samplers = Array[Sampler, Static],
            blank = Texture,
            values = Array[Buffer, Static],
            valuesUsed = Array[Int32, Static],
            groups = Ref[List[BindGroup], Static],
            warned = Ref[Set[String], Static],
            textureEpoch = Array[Int64, Static],
            mipmaps = Render3d.WebGpuMipmaps.Mipmaps,
            platformImages = Ref[Option[PlatformImages], Static]
        })
    }

    pub type alias Materials = MaterialsData

    /// 値の buffer の始めの大きさ（バイト）。
    def initialValueBytes(): Int32 = 65536

    /// 値の区画のそろえ（バイト。core の minUniformBufferOffsetAlignment と minStorageBufferOffsetAlignment の上限）。
    def valueAlignBytes(): Int32 = 4 * MaterialValues.valueAlign()

    /// r3dDraw の binding の大きさ（Render3dWgsl の R3dDraw: f32 が 6 つを 16 バイトの倍数へ切り上げ）。
    def drawValueBytes(): Int64 = 32i64

    pub def create(gpu: WebGpu, binding: ValuesBinding): Materials \ IO =
        let blank = gpu.createTexture("fge material blank", 1, 1, TextureFormat.RGBA8_UNORM, Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        gpu.writeTexture(blank, 0, 0, 0, 1, 1, ByteBuffer.allocateDirect(4), 0, 4);
        let sampler = (label, filter, address) -> gpu.createSampler(label, filter, FilterMode.LINEAR, address);
        MaterialsData.MaterialsData({
            gpu = gpu, binding = binding, programs = Ref.fresh(Static, Map.empty()), nextId = Array#{1} @ Static,
            current = Ref.fresh(Static, Vector.empty()), vertexModules = Ref.fresh(Static, Map.empty()), pipelines = Ref.fresh(Static, Map.empty()),
            textures = TextureTable3d.fresh(), store = Ref.fresh(Static, Map.empty()),
            samplers = Array#{sampler("fge material repeat nearest", FilterMode.NEAREST, AddressMode.REPEAT),
                              sampler("fge material repeat linear", FilterMode.LINEAR, AddressMode.REPEAT),
                              sampler("fge material clamp nearest", FilterMode.NEAREST, AddressMode.CLAMP_TO_EDGE),
                              sampler("fge material clamp linear", FilterMode.LINEAR, AddressMode.CLAMP_TO_EDGE)} @ Static,
            blank = blank, values = Array#{createValueBuffer(gpu, initialValueBytes())} @ Static, valuesUsed = Array#{0} @ Static,
            groups = Ref.fresh(Static, Nil), warned = Ref.fresh(Static, Set.empty()), textureEpoch = Array#{0i64} @ Static,
            mipmaps = Render3d.WebGpuMipmaps.create(gpu),
            platformImages = Ref.fresh(Static, None)
        })

    /// 機種の側に持つ絵を写す口を images にする（作った時は口が無く、その絵は上げない）。
    // WhyNot: create の引数にしない — create を呼ぶ所（bench と Dawn の門）は機種の側の絵を持たず、全部に「口が無い」を書き足すことになる。
    pub def setPlatformImages(images: PlatformImages, m: Materials): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Ref.put(Some(images), s#platformImages)

    /// 値の buffer（uniform と storage と、ビルボードの値を読む頂点の buffer として bind する）。
    def createValueBuffer(gpu: WebGpu, bytes: Int32): Buffer \ IO =
        gpu.createBuffer("fge material values", Int32.toInt64(bytes), Int32.bitwiseOr(Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.STORAGE), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST)))

    /// values を頭から書いた、値の buffer と同じ使い方の buffer（持ち越した行の値・Render3d.WebGpuStatic。手放すのは呼ぶ側）。
    pub def createValuesOf(m: Materials, label: String, values: Array[Float32, Static]): Buffer \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let bytes = 4 * Array.length(values);
        let buffer = s#gpu.createBuffer(label, Int32.toInt64(Int32.max(valueAlignBytes(), bytes)),
                                        Int32.bitwiseOr(Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.STORAGE), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST)));
        let data = ByteBuffer.allocateDirect(Int32.max(4, bytes)).order(ByteOrder.LITTLE_ENDIAN);
        discard data.asFloatBuffer().put(values);
        s#gpu.writeBuffer(buffer, 0i64, data, 0, bytes);
        buffer

    /// 今の値の buffer（sendValues が書いた位置はこの buffer の中。sendValues が作り直すので、描く時に引く）。
    pub def valuesBufferOf(m: Materials): Buffer \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Array.get(0, s#values)

    /// 絵の表（行の reads の番号を振る表）。
    pub def texturesOf(m: Materials): TextureTable3d.Table =
        let MaterialsData.MaterialsData(s) = m;
        s#textures

    /// device の上に作った物を全部手放す。
    pub def release(m: Materials): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        afterSubmit(m);
        Map.forEach((_, p) -> p.release(), Ref.get(s#pipelines));
        Map.forEach((_, op) -> Option.forEach((p: Program) -> { p#fragment.release(); p#layout.release() }, op), Ref.get(s#programs));
        Map.forEach((_, v) -> v.release(), Ref.get(s#vertexModules));
        TextureTable3d.release(s#textures, destroyTexture(s#store));
        Array.forEach(x -> x.release(), s#samplers);
        s#blank.destroy();
        Array.get(0, s#values).destroy();
        Render3d.WebGpuMipmaps.release(s#mipmaps)

    /// 2D の描き手が encoder を submit した後に呼ぶ（group 1 を手放し、値の buffer を頭から書き直せる）。
    pub def afterSubmit(m: Materials): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Ref.get(s#groups) |> List.forEach(g -> g.release());
        Ref.put(Nil, s#groups);
        Array.put(0, 0, s#valuesUsed);
        Render3d.WebGpuMipmaps.afterSubmit(s#mipmaps)

    /// 画面のコマの終わりに、材質の絵を置き場の上限 budget で捨て、捨てた鍵を返す。先に上げた絵 preloaded は捨てる順を後へ回す。
    pub def endFrame(m: Materials, gen: Int64, budget: Render3d.Material.Budget, preloaded: Set[TextureSlot]): List[TextureSlot] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        fst(TextureTable3d.sweep(s#textures, destroyTexture(s#store), gen, budget, preloaded))

    // ── 材質の program ──

    /// 版 kind の材質をこの描き手が描けるか。
    pub def isDrawable(kind: ProgramKind): Bool = not kind#coverage

    /// 問い合わせ requests に順の番号で答える（描けない版と組めない材質は 0）。答えた表は current に控え、行の欄 1（問い合わせの番号）で引く。
    /// 初めての材質はここで組み、noteBuild(名前) を呼ぶ。
    pub def resolve(m: Materials, noteBuild: String -> Unit \ IO, requests: Vector[MaterialRequest]): Vector[Int32] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let programs = programsFor(m, noteBuild, requests);
        Ref.put(programs, s#current);
        ordersOf(programs)

    /// 問い合わせ requests の program の並び（描けない版と組めない材質は None。current には控えない — 持ち越した行が自分の並びを持つ・Render3d.StaticRows）。
    pub def programsFor(m: Materials, noteBuild: String -> Unit \ IO, requests: Vector[MaterialRequest]): Vector[Option[Program]] \ IO =
        requests |> Vector.map(match (fields, kind) -> if (isDrawable(kind)) programOf(m, noteBuild, fields, kind) else None)

    /// program の並びの順の番号（無ければ 0）。
    pub def ordersOf(programs: Vector[Option[Program]]): Vector[Int32] =
        Vector.map(p -> p |> Option.map(x -> x#id) |> Option.getWithDefault(0), programs)

    /// 今の prepare の問い合わせの順の program（resolve が控えた物）。
    pub def currentPrograms(m: Materials): Vector[Option[Program]] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Ref.get(s#current)

    def programOf(m: Materials, noteBuild: String -> Unit \ IO, fields: Scene3d.MaterialFields, kind: ProgramKind): Option[Program] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let key = materialKey(fields, kind);
        match Map.get(key, Ref.get(s#programs)) {
            case Some(found) => found
            case None =>
                noteBuild("scene3d:material:wgsl:" + key);
                let made = compileProgram(m, fields, kind);
                Ref.put(Map.insert(key, made, Ref.get(s#programs)), s#programs);
                made
        }

    /// 材質の frag を組む（読む絵の組は GL と同じく上限で切る）。組めなければ名前ごとに 1 回知らせて None。
    // WhyNot: 同じ鍵で中身の違う材質（木の鍵のぶつかり）を見分けない — GL の Render3d.Material.reuseOrRebuild の比べは、WebGPU の材質の LRU と一緒に入れる（持ち越し）。
    def compileProgram(m: Materials, fields: Scene3d.MaterialFields, kind: ProgramKind): Option[Program] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let (spec, emission, metallicRoughness) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), fields#spec, fields#emission, fields#metallicRoughnessShade);
        let wgsl = ShaderGen.Wgsl.compile3d(spec, emission, metallicRoughness, 1);
        let source = valuesDeclared(s#binding, Render3dWgsl.materialFragmentSource(wgsl, kind));
        let module = s#gpu.createShaderModule("fge material ${spec#name}", source);
        let errors = TextSplit.lines(s#gpu.getCompilationInfo(module)) |> List.filter(l -> String.startsWith({ prefix = "Error" }, l));
        match errors {
            case first :: _ =>
                module.release();
                warnOnce(m, spec#name, () -> Log.fellBack("scene3d", spec#name, "頂点の色", "材質の WGSL を組めない（${first}）"));
                None
            case Nil =>
                let id = Array.get(0, s#nextId);
                Array.put(id + 1, 0, s#nextId);
                let texCount = List.length(wgsl#texReads);
                Some({ id = id, kind = kind, fragment = module, layout = createLayout(m, texCount, kind#uv and kind#normalMap, kind#lightmap),
                       slotCount = List.length(wgsl#slots), texCount = texCount })
        }

    def warnOnce(m: Materials, name: String, say: Unit -> Unit \ ef): Unit \ ef + IO =
        let MaterialsData.MaterialsData(s) = m;
        if (Set.memberOf(name, Ref.get(s#warned))) ()
        else {
            Ref.put(Set.insert(name, Ref.get(s#warned)), s#warned);
            say()
        }

    /// 値の宣言を binding の形に合わせる（Storage の時だけ uniform を読むだけの storage に替える）。
    def valuesDeclared(binding: ValuesBinding, wgsl: String): String = match binding {
        case ValuesBinding.Uniform => wgsl
        case ValuesBinding.Storage =>
            wgsl |> String.replace(src = "var<uniform> sg:", dst = "var<storage, read> sg:")
                 |> String.replace(src = "var<uniform> r3dDraw:", dst = "var<storage, read> r3dDraw:")
    }

    /// group 1 の layout: 0 = sg・1 + 2k と 2 + 2k = 材質の絵と sampler・Render3dWgsl.drawBinding() = r3dDraw・その次の 2 つ = 法線マップと sampler・
    /// その次の 2 つ = lightmap と sampler（Render3dWgsl.drawDeclarations と同じ番号）。
    def createLayout(m: Materials, texCount: Int32, normalMapped: Bool, lightmapped: Bool): BindGroupLayout \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let kind = match s#binding {
            case ValuesBinding.Uniform => BufferBindingType.UNIFORM
            case ValuesBinding.Storage => BufferBindingType.READ_ONLY_STORAGE
        };
        let desc = new BindGroupLayoutDesc("fge material");
        let draw = Render3dWgsl.drawBinding();
        discard desc.buffer(0, ShaderStage.FRAGMENT, kind).buffer(draw, ShaderStage.FRAGMENT, kind);
        List.range(0, texCount) |> List.forEach(k ->
            discard desc.texture(1 + 2 * k, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(2 + 2 * k, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING));
        if (normalMapped) discard desc.texture(draw + 1, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(draw + 2, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING) else ();
        if (lightmapped) discard desc.texture(draw + 3, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(draw + 4, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING) else ();
        s#gpu.createBindGroupLayout(desc)

    // ── 材質の絵 ──

    /// 行 list の材質の行が読む絵を作る（無ければ）。source = 場面の textures と全体の登録・textureById = 登録の絵の番号 → 2D の描き手の texture・
    /// gen = 今の世代。描き始める前に呼ぶ。
    pub def uploadTextures(m: Materials, source: TextureSource, registered: Registered, gen: Int64, list: SceneList): Unit \ IO =
        uploadTexturesFrom(m, uploadsOf(source, registered, gen), list, 0, rowCountOf(list))

    def uploadTexturesFrom(m: Materials, up: TextureUploads, list: SceneList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            if (kindAt(list, row) == SceneRowKind.Material and valuesAt(list, row) >= 0) materialAt(list, row) |> Option.forEach(f -> uploadRowTextures(m, up, list, row, f))
            else ();
            uploadTexturesFrom(m, up, list, row + 1, n)
        }

    /// uploadTextures の、行 rows の材質の絵だけを作る形（持ち越した行のうち、値を分け合わない行・Render3d.StaticRows）。
    pub def uploadTexturesAt(m: Materials, source: TextureSource, registered: Registered, gen: Int64, list: SceneList, rows: Vector[Int32]): Unit \ IO =
        let up = uploadsOf(source, registered, gen);
        rows |> Vector.forEach(row -> materialAt(list, row) |> Option.forEach(f -> uploadRowTextures(m, up, list, row, f)))

    /// uploadTextures の 1 回で行をまたいで変わらない物。srgbSeen・linearSeen = この 1 回で作り終えた絵の名前（mip のレベルを平均する色空間ごと。
    /// 同じ名前で同じ色空間なら表の鍵も同じ）。
    // WhyNot: 作り終えた名前を回をまたいで控えない — source（場面の textures）は回ごとに違い、別の場面では同じ名前が見つからない事がある。
    // WhyNot: 控えを Flix の Set にしない — 鍵の比べと木の道で、引くたびに割り当てる。名前の String は材質の値が持つ物で、HashSet は引くだけなら割り当てない。
    type alias TextureUploads = { source = TextureSource, registered = Registered, gen = Int64, srgbSeen = HashSet[String], linearSeen = HashSet[String] }

    def uploadsOf(source: TextureSource, registered: Registered, gen: Int64): TextureUploads \ IO =
        { source = source, registered = registered, gen = gen, srgbSeen = new HashSet(), linearSeen = new HashSet() }

    /// 行 row の reads と同じ並び（材質の絵 → 法線マップ → lightmap）で絵を作る。材質の絵の枚数は reads の数から法線マップと lightmap を引いた数。
    def uploadRowTextures(m: Materials, up: TextureUploads, list: SceneList, row: Int32, f: Scene3d.MaterialFields): Unit \ IO =
        let normal = if (hasFlag(list, row, flagNormalMap())) f#normalMap else None;
        let baked = if (hasFlag(list, row, flagLightmap())) Scene3d.lightmapOfFields(headAt(list, row)#fields) else None;
        let colorCount = readCountAt(list, row) - (if (Option.isEmpty(normal)) 0 else 1) - (if (Option.isEmpty(baked)) 0 else 1);
        Scene3d.materialTexReadsOf(f) |> List.forEachWithIndex((k, nf) ->
            if (k < colorCount) ensureTexture(m, up, fst(nf), Texture3d.TextureUse.MaterialTexture) else ());
        normal |> Option.forEach(n -> ensureTexture(m, up, n#texture, Texture3d.TextureUse.NormalMap));
        baked |> Option.forEach(lm -> ensureTexture(m, up, lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace)))

    /// 材質 f で頭の物 head を描く時に読む絵の (名前, 使い方)（並びは材質の絵 colorCount 枚 → 法線マップ → lightmap。行の reads と同じ）。
    def textureReadsOf(f: Scene3d.MaterialFields, colorCount: Int32, normalMapped: Bool, lightmapped: Bool, head: MeshDraw): List[(String, Texture3d.TextureUse)] =
        let normal = if (normalMapped) f#normalMap |> Option.map(n -> (n#texture, Texture3d.TextureUse.NormalMap)) |> Option.toList else Nil;
        let baked = if (lightmapped)
                        Scene3d.lightmapOfFields(head#fields) |> Option.map(lm -> (lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace))) |> Option.toList
                    else Nil;
        let colors = Scene3d.materialTexReadsOf(f) |> List.take(colorCount) |> List.map(nf -> (fst(nf), Texture3d.TextureUse.MaterialTexture));
        List.flatten(colors :: normal :: baked :: Nil)

    /// 先に上げる材質 request（頭の物 head・形の buffer mesh）の program を組み、mp の描き先の pipeline を作り、読む絵を作って、絵の置き場の鍵を返す
    /// （描けない版と組めない材質は何もせず Nil・pipeline は形に要る頂点の属性（2 本目の uv・ジョイント）がある時だけ）。
    /// source・registered・gen は uploadTextures と同じ。初めての材質は noteBuild(名前) を呼び、source に無い "tex3d:" の絵は missing(名前) を呼ぶ。
    pub def preloadMaterial(m: Materials, noteBuild: String -> Unit \ IO, missing: String -> Unit \ IO, mp: MaterialPass, source: TextureSource, registered: Registered, gen: Int64,
                            request: MaterialRequest, head: MeshDraw, mesh: Option[MeshBuffers]): List[TextureSlot] \ IO =
        let (fields, kind) = request;
        let program = if (isDrawable(kind)) programOf(m, noteBuild, fields, kind) else None;
        program |> Option.toList |> List.flatMap(p -> {
            mesh |> Option.filter(b -> (not p#kind#skinned or Option.nonEmpty(b#skinAt)) and (not p#kind#lightmap or Option.nonEmpty(b#uv2At)))
                 |> Option.forEach(b -> discard pipelineOf(m, mp, p, b));
            let reads = textureReadsOf(fields, p#texCount, p#kind#normalMap, p#kind#lightmap, head);
            let up = uploadsOf(source, registered, gen);
            reads |> List.forEach(match (name, textureUse) -> ensureTexture(m, up, name, textureUse));
            let found = reads |> List.map(match (name, textureUse) -> (name, TextureTable3d.readOf(false, source, name, textureUse) |> Option.map(fst)));
            found |> List.forEach(match (name, slot) -> if (Option.isEmpty(slot) and String.startsWith(prefix = Texture3d.namePrefix(), name)) missing(name) else ());
            found |> List.filterMap(snd)
        })

    /// 絵 name を表の番号で作る。場面の絵は CPU で mip のレベルを作って上げ、全体の登録の絵は 2D の描き手の texture から mip つきの写しを GPU で作る（元の絵が作り直されたら作り直す）。
    /// up の 1 回で同じ名前と色空間を作り終えていれば何もしない。
    def ensureTexture(m: Materials, up: TextureUploads, name: String, textureUse: Texture3d.TextureUse): Unit \ IO =
        let space = Texture3d.mipSpaceOf(textureUse);
        let seen = if (space == Texture3d.ColorSpace.Srgb) up#srgbSeen else up#linearSeen;
        if (seen.add(name)) ensureTextureNow(m, up, name, textureUse) else ()

    def ensureTextureNow(m: Materials, up: TextureUploads, name: String, textureUse: Texture3d.TextureUse): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let average = Texture3d.mipAverageOf(Texture3d.mipSpaceOf(textureUse));
        let hit = TextureTable3d.findTexture(up#source, name);
        match (hit |> Option.flatMap(TextureTable3d.readOfHit(false, name, textureUse)), hit) {
            case (Some((slot, _)), Some(TextureHit.Own(t))) =>
                discard TextureTable3d.ensure(s#textures, destroyTexture(s#store), up#gen, slot, "", handle -> { noteTextureMade(m); uploadTexture3d(m, up, handle, average, t) })
            case (Some((slot, _)), Some(TextureHit.Registered(t))) =>
                discard TextureTable3d.ensure(s#textures, destroyTexture(s#store), up#gen, slot, "${t#texId}:${t#version}", handle -> { noteTextureMade(m); mipCopyTexture(m, up, handle, average, t) })
            case _ => ()
        }

    def noteTextureMade(m: Materials): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Array.put(Array.get(0, s#textureEpoch) + 1i64, 0, s#textureEpoch)

    /// 材質の絵を作った（作り直した）回数。group 1 を持ち越す所（Render3d.WebGpuStatic の bundle）が、作り直した絵を読み続けないために見る。
    pub def textureEpochOf(m: Materials): Int64 \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Array.get(0, s#textureEpoch)

    /// 今の encoder の group 1 の置き場（submit の後に手放す）。
    pub def frameGroupsOf(m: Materials): Ref[List[BindGroup], Static] =
        let MaterialsData.MaterialsData(s) = m;
        s#groups

    /// 場面の環境マップの絵 name を、材質の絵と同じ置き場と mip の作り方で作り（無ければ）、その絵と mip のレベルの数を返す。
    /// 場面の textures に無い・作れない絵は None。
    // WhyNot: 上下を返して読む全体の登録の絵（レンダーターゲット）を借りて貼る道を持たない — 環境マップの絵の名前は Scene3d.environmentMap が Texture3d から作る "tex3d:" の名前だけで、全体の登録の絵は来ない。
    pub def ensureEnvironmentTexture(m: Materials, source: TextureSource, registered: Registered, gen: Int64, name: String): Option[(Texture, Int32)] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        ensureTexture(m, uploadsOf(source, registered, gen), name, Texture3d.TextureUse.MaterialTexture);
        TextureTable3d.readOf(false, source, name, Texture3d.TextureUse.MaterialTexture)
            |> Option.flatMap(read -> Map.get(TextureTable3d.numberOf(s#textures, gen, fst(read)), Ref.get(s#store)))
            |> Option.map(g -> (g#texture, g#levels))

    /// 2D の描き手の絵 t の mip つきの写し（平均の仕方 average）を GPU で作り、番号 handle で控える（2D の描き手が絵を持っていなければ None）。
    // WhyNot: 2D の描き手の絵を mip のレベル 1 つのまま借りて貼らない — 遠くの面がレベルを選べず、mip つきの写しを読む GL より細かくちらつく。
    def mipCopyTexture(m: Materials, up: TextureUploads, handle: Int32, average: Mip.Average, t: Scene3dRenderer.RegisteredTexture): Option[{ levels = Int32, bytes = Int64 }] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        (up#registered#textureById)(t#texId) |> Option.map(source -> {
            (up#registered#noteCopy)();
            let copy = Render3d.WebGpuMipmaps.copyOf(s#mipmaps, up#registered#encoding, "fge material mip copy ${t#texId}", source, average);
            Ref.put(Map.insert(handle, { texture = copy#texture, levels = copy#levels }, Ref.get(s#store)), s#store);
            { levels = copy#levels, bytes = copy#bytes }
        })

    /// 場面の絵 t を上げて番号 handle で控える。ARGB の絵は CPU で段を作って上げ、機種の側の絵はレベル 0 へ写して上の段を GPU で作る
    /// （写せなければ None）。
    // WhyNot: ARGB の絵の段を GPU に作らせない — WebGPU に generateMipmap は無く、CPU の描き出しと同じ Mip.build の段にそろえる（GL の CPU の段と同じ鍵）。
    def uploadTexture3d(m: Materials, up: TextureUploads, handle: Int32, average: Mip.Average, t: Texture3d.Texture3d): Option[{ levels = Int32, bytes = Int64 }] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        match Texture3d.sourceOf(t) {
            case Texture3d.Source.PlatformImage(key) => uploadPlatformImage(m, up, handle, average, key, t)
            case Texture3d.Source.Argb(pixels) =>
                let chain = Mip.build(average, { width = Texture3d.width(t), height = Texture3d.height(t), pixels = pixels });
                let levels = List.length(chain);
                let texture = s#gpu.createTexture("fge material ${Texture3d.name(t)}", Texture3d.width(t), Texture3d.height(t), TextureFormat.BGRA8_UNORM,
                                                  Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), levels, 1);
                chain |> List.forEachWithIndex((level, td) -> s#gpu.writeTexture(texture, level, 0, 0, td#width, td#height, argbBytes(td#pixels), 0, td#width * 4));
                Ref.put(Map.insert(handle, { texture = texture, levels = levels }, Ref.get(s#store)), s#store);
                Some({ levels = levels, bytes = List.foldLeft((acc, td) -> acc + Int32.toInt64(td#width * td#height * 4), 0i64, chain) })
            case Texture3d.Source.Rgba16Float(halves) =>
                let chain = Mip.buildRgba16Float(Texture3d.width(t), Texture3d.height(t), halves);
                let levels = List.length(chain);
                let texture = s#gpu.createTexture("fge material ${Texture3d.name(t)}", Texture3d.width(t), Texture3d.height(t), TextureFormat.RGBA16_FLOAT,
                                                  Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), levels, 1);
                chain |> List.forEachWithIndex((level, entry) -> {
                    let (w, h, bits) = entry;
                    s#gpu.writeTexture(texture, level, 0, 0, w, h, halfBytes(bits), 0, w * 8)
                });
                Ref.put(Map.insert(handle, { texture = texture, levels = levels }, Ref.get(s#store)), s#store);
                Some({ levels = levels, bytes = List.foldLeft((acc, entry) -> { let (w, h, _) = entry; acc + Int32.toInt64(w * h * 8) }, 0i64, chain) })
        }

    /// half の bit の列を little-endian のバイトにする（rgba16float の 1 画素 8 バイト）。
    def halfBytes(bits: Vector[Int16]): ByteBuffer \ IO =
        let arr = unchecked_cast(bits as Array[Int16, Static]);
        let bytes = ByteBuffer.allocateDirect(Int32.max(8, Vector.length(bits) * 2)).order(ByteOrder.LITTLE_ENDIAN);
        discard bytes.asShortBuffer().put(arr);
        bytes

    /// 機種の側の絵 key（大きさは t の物）を段つきの texture のレベル 0 へ写し、上の段を作る pass を up の encoder へ積んで、番号 handle で控える（写せなければ texture を捨てて None）。
    // WhyNot: GL のように段を素の値のまま平均しない — 同じ置き場の ARGB の絵と全体の登録の絵の写しは average（Mip.build と同じ決まり）で作っていて、絵の出どころで遠くの面の色がずれる。
    // WhyNot: 写した後に頁の ImageBitmap を手放さない — 2 つの部屋が同じ絵を貼ると後の部屋が同じ key でまた写す（GL の texImagePlatform も手放さない）。
    // WhyNot: 口が無い（デスクトップ）時に知らせない — デスクトップの ImageDecoder は機種の側の絵を作らず、来るのは bench が手で作った時だけ。
    def uploadPlatformImage(m: Materials, up: TextureUploads, handle: Int32, average: Mip.Average, key: String, t: Texture3d.Texture3d): Option[{ levels = Int32, bytes = Int64 }] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Ref.get(s#platformImages) |> Option.flatMap(images -> uploadPlatformImageWith(m, images, up, handle, average, key, t))

    /// uploadPlatformImage の、写す口 images がある時。今写せない絵は texture を作らずに None（作り直しを待つ間のコマごとに段つきの texture を作って捨てない）。
    // WhyNot: usage から COPY_SRC を外さない — Dawn の門が段を読み戻して Mip.build と比べる（全体の登録の絵の写しも同じ usage）。
    def uploadPlatformImageWith(m: Materials, images: PlatformImages, up: TextureUploads, handle: Int32, average: Mip.Average, key: String, t: Texture3d.Texture3d): Option[{ levels = Int32, bytes = Int64 }] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let (width, height) = (Texture3d.width(t), Texture3d.height(t));
        if (not images#has(key, width, height)) {
            warnPlatformImageOnce(m, key, "頁に ${Int32.toString(width)} × ${Int32.toString(height)} の ImageBitmap が無い");
            None
        } else {
            let levels = TextureTable3d.levelsOf(width, height);
            let usage = Int32.bitwiseOr(Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST),
                                        Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.COPY_SRC));
            let texture = s#gpu.createTexture("fge material ${Texture3d.name(t)}", width, height, TextureFormat.RGBA8_UNORM, usage, levels, 1);
            if (images#copy(key, texture)) {
                let bytes = Render3d.WebGpuMipmaps.buildMipLevels(s#mipmaps, up#registered#encoding, texture, levels, average);
                Ref.put(Map.insert(handle, { texture = texture, levels = levels }, Ref.get(s#store)), s#store);
                Some({ levels = levels, bytes = bytes })
            } else {
                texture.destroy();
                warnPlatformImageOnce(m, key, "copyExternalImageToTexture で写せない");
                None
            }
        }

    /// 機種の側の絵 key を上げられなかった事を、key ごとに初回 1 回だけ知らせる。
    def warnPlatformImageOnce(m: Materials, key: String, reason: String): Unit \ IO =
        warnOnce(m, "@platform:${key}", () -> Log.fellBack("scene3d", "機種の側の絵 ${key}", "絵なし（黒）", reason))

    /// ARGB の int の列を little-endian のバイト（B・G・R・A）にする。
    // WhyNot: 1 要素ずつ put しない — Flix の Vector は JVM の int[] のままで、1 回で写せる（WebGpuPaint.argbBytes と同じ）。
    def argbBytes(argb: Vector[Int32]): ByteBuffer \ IO =
        let arr = unchecked_cast(argb as Array[Int32, Static]);
        let bytes = ByteBuffer.allocateDirect(Int32.max(4, Vector.length(argb) * 4)).order(ByteOrder.LITTLE_ENDIAN);
        discard bytes.asIntBuffer().put(arr);
        bytes

    def destroyTexture(store: Ref[Map[Int32, GpuTexture], Static]): Int32 -> Unit \ IO = handle -> {
        Map.get(handle, Ref.get(store)) |> Option.forEach(g -> g#texture.destroy());
        Ref.put(Map.remove(handle, Ref.get(store)), store)
    }

    // ── 値 ──

    /// 値 bytes（区画のそろえの余りを含めて呼ぶ側が見積もる）が今の encoder の値の buffer の空きに入るか。
    pub def hasRoom(m: Materials, bytes: Int32): Bool \ IO =
        let MaterialsData.MaterialsData(s) = m;
        roundUp(Array.get(0, s#valuesUsed), valueAlignBytes()) + bytes <= capacityOf(m)

    def capacityOf(m: Materials): Int32 \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Int64.tryToInt32(Array.get(0, s#values).size()) |> Option.getWithDefault(Int32.maxValue())

    /// 行 list の values を値の buffer の空きへ書き、書いた位置（バイト）を返す。呼ぶ前に hasRoom で確かめ、入らなければ submit しておく。
    /// それでも入らない（buffer を使っていない時に 1 つの場面で足りない）なら、buffer を要る大きさか倍の大きい方へ作り直す。
    // WhyNot: ここで submit しない — 同じ場面の 1 体ごとの値を先に送ってあり、submit すると次の場面がそれを頭から上書きする（Render3d.WebGpuRenderer.stageScene）。
    pub def sendValues(m: Materials, list: SceneList): Int32 \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let floats = Array.length(list#values);
        let bytes = 4 * floats;
        let capacity = capacityOf(m);
        if (Array.get(0, s#valuesUsed) == 0 and bytes > capacity) {
            Array.get(0, s#values).destroy();
            Array.put(createValueBuffer(s#gpu, Int32.max(bytes, 2 * capacity)), 0, s#values)
        } else ();
        let at = roundUp(Array.get(0, s#valuesUsed), valueAlignBytes());
        if (at + bytes > capacityOf(m)) {
            warnValuesOnce(m, "scene3d: 材質の値（${Int32.toString(at + bytes)} バイト）が値の buffer（${Int32.toString(capacityOf(m))} バイト）に入らない — この行の材質は書かずに描く（呼ぶ側が reserveValues で場面の分を先に取る）");
            at
        } else {
            let data = ByteBuffer.allocateDirect(Int32.max(4, bytes)).order(ByteOrder.LITTLE_ENDIAN);
            discard data.asFloatBuffer().put(list#values);
            s#gpu.writeBuffer(Array.get(0, s#values), Int32.toInt64(at), data, 0, bytes);
            Array.put(at + bytes, 0, s#valuesUsed);
            at
        }

    /// 場面 1 つの材質の値 bytes（そろえの余りを含めて呼ぶ側が見積もる）を、空の値の buffer に入るようにする（入らなければ要る大きさか倍の大きい方へ作り直す）。
    /// 呼ぶ前に hasRoom が偽なら submit しておく（buffer を使っていない時だけ作り直す）。
    // WhyNot: 行ごとの sendValues の作り直しだけに任せない — 作り直せるのは buffer が空の時だけで、点光源の影の面ごとの行が続くと 2 本目から先は空でなく、
    //   場面の合計が buffer を超えた所から書けずに材質が黒くなる。場面の合計で先に取る。
    pub def reserveValues(m: Materials, bytes: Int32): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let capacity = capacityOf(m);
        if (Array.get(0, s#valuesUsed) == 0 and bytes > capacity) {
            Array.get(0, s#values).destroy();
            Array.put(createValueBuffer(s#gpu, Int32.max(bytes, 2 * capacity)), 0, s#values)
        } else ()

    /// 値の buffer の知らせを 1 回だけ出す。
    def warnValuesOnce(m: Materials, line: String): Unit \ IO = warnOnce(m, "@values", () -> Log.warn(line))

    def roundUp(n: Int32, step: Int32): Int32 = ((n + step - 1) / step) * step

    // ── 描く ──

    /// pass の中で今付けている pipeline（同じ物を付け直さないための鍵）。Shape(pass の番号, 頂点のバイト数, 骨つきか) = 頂点の色の pipeline・
    /// Material(program の順の番号, 頂点のバイト数) = 材質の pipeline・Billboard = ビルボードの pipeline（group 1 は 2D の描き手の絵の group）。
    pub enum BoundPipeline with Eq {
        case Unbound
        case Shape(Int32, Int32, Bool)
        case Material(Int32, Int32)
        case Billboard
    }

    /// 材質の行を描く pass の付け方の材料。base = 行の values を送った位置（バイト）・values = その buffer・programs = 行の欄 1 が引く program の並び・
    /// format・samples = 描き先・sceneLayout = group 0 の layout・poseLayout = group 2（姿勢）の layout・hasPoses = pass の頭で group 2 を付けたか・
    /// bound = 今の pipeline・groupRow = 最後に group 1 を付けた行（要素 1 つ・-1 = 付けていないか、付けた物が材質の group でない）・
    /// groups = 作った group 1 の置き場（今の encoder の物は frameGroupsOf・bundle に積む物は bundle の持ち主の置き場）。
    pub type alias MaterialPass = {
        base = Int32, values = Buffer, programs = Vector[Option[Program]], format = RenderTarget.Format, samples = Int32, sceneLayout = BindGroupLayout,
        poseLayout = BindGroupLayout, hasPoses = Bool, bound = Ref[BoundPipeline, Static], groupRow = Array[Int32, Static], groups = Ref[List[BindGroup], Static]
    }

    /// 行 row の材質の pipeline と group 1 を pass に付ける（描けない行は偽。骨つきの材質は pass に姿勢の group が無いか、形にジョイントが無ければ偽・
    /// lightmap の材質は形に 2 本目の uv が無ければ偽）。前の材質の行と同じ付け方（flagSameBinding）の行は group を付け直さない。
    pub def bindRow(m: Materials, mp: MaterialPass, pass: RenderCommands, list: SceneList, row: Int32, mesh: MeshBuffers): Bool \ IO =
        let handle = materialHandleAt(list, row);
        let current = mp#programs;
        let program = if (handle >= 0 and handle < Vector.length(current)) Vector.get(handle, current) else None;
        let valuesOk = valuesAt(list, row) >= 0;
        match program {
            case Some(p) if valuesOk and (not p#kind#skinned or (mp#hasPoses and Option.nonEmpty(mesh#skinAt))) and (not p#kind#lightmap or Option.nonEmpty(mesh#uv2At)) =>
                let key = BoundPipeline.Material(p#id, mesh#stride);
                if (Ref.get(mp#bound) == key) () else {
                    pass.setPipeline(pipelineOf(m, mp, p, mesh));
                    Ref.put(key, mp#bound);
                    Array.put(-1, 0, mp#groupRow)
                };
                let reuse = hasFlag(list, row, flagSameBinding()) and Array.get(0, mp#groupRow) >= 0;
                if (reuse) () else {
                    pass.setBindGroup(1, buildGroup(m, mp, p, list, row));
                    Array.put(row, 0, mp#groupRow)
                };
                true
            case _ => false
        }

    /// 行 row の group 1（値の区画 2 つと、reads の絵と sampler。並びは材質の絵 → 法線マップ → lightmap）。submit の後に手放す。
    def buildGroup(m: Materials, mp: MaterialPass, p: Program, list: SceneList, row: Int32): BindGroup \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let buffer = mp#values;
        let at = mp#base + 4 * valuesAt(list, row);
        let desc = new BindGroupDesc("fge material", p#layout);
        discard desc.buffer(Render3dWgsl.drawBinding(), buffer, Int32.toInt64(at), drawValueBytes());
        discard desc.buffer(0, buffer, Int32.toInt64(at + valueAlignBytes()), Int32.toInt64(roundUp(4 * p#slotCount, 16)));
        let store = Ref.get(s#store);
        let textureAt = (k: Int32) -> Map.get(readAt(list, row, k, 0), store) |> Option.map(g -> g#texture) |> Option.getWithDefault(s#blank);
        let samplerAt = (k: Int32) -> Array.get(2 * readAt(list, row, k, 2) + readAt(list, row, k, 1), s#samplers);
        putTexturesFrom(desc, textureAt, samplerAt, 0, p#texCount);
        let normalMapped = p#kind#uv and p#kind#normalMap;
        let draw = Render3dWgsl.drawBinding();
        if (normalMapped) discard desc.textureView(draw + 1, textureAt(p#texCount).defaultView()).sampler(draw + 2, samplerAt(p#texCount)) else ();
        if (p#kind#lightmap) {
            let k = MaterialValues.lightmapReadAt(p#texCount, normalMapped);
            discard desc.textureView(draw + 3, textureAt(k).defaultView()).sampler(draw + 4, samplerAt(k))
        } else ();
        let group = s#gpu.createBindGroup(desc);
        Ref.put(group :: Ref.get(mp#groups), mp#groups);
        group

    /// 材質の絵の k 番目から n の前までを desc の 1 + 2k（絵）と 2 + 2k（sampler）へ。
    def putTexturesFrom(desc: BindGroupDesc, textureAt: Int32 -> Texture \ IO, samplerAt: Int32 -> Sampler \ IO, k: Int32, n: Int32): Unit \ IO =
        if (k >= n) ()
        else {
            discard desc.textureView(1 + 2 * k, textureAt(k).defaultView()).sampler(2 + 2 * k, samplerAt(k));
            putTexturesFrom(desc, textureAt, samplerAt, k + 1, n)
        }

    /// 材質の pipeline の鍵。program = program の番号・format = 描き先の形式の番号・samples = 標本の数・stride = 頂点のバイト数。
    type alias MaterialPipelineKey = { program = Int32, format = Int32, samples = Int32, stride = Int32 }

    // WhyNot: レコードを Map の鍵に直に使わない — レコードは Order を持てない。並べ方は materialPipelineSlotOf の 1 か所だけにして、呼ぶ側は欄の名前で書く。
    enum MaterialPipelineSlot with Eq, Order {
        case MaterialPipelineSlot(Int32, Int32, Int32, Int32)
    }

    def materialPipelineSlotOf(k: MaterialPipelineKey): MaterialPipelineSlot =
        MaterialPipelineSlot.MaterialPipelineSlot(k#program, k#format, k#samples, k#stride)

    /// program p で形 mesh を mp の描き先へ描く pipeline（無ければ作る）。表の面は時計回りで、両面の材質だけ裏を間引かない。深度は LESS で書く。
    /// 半透明の版は深度を読むが書かず、GL の Render3d.GlRows.drawBlendedRows と同じ混ぜ方（色は SRC_ALPHA・ONE_MINUS_SRC_ALPHA、α は ONE・ONE_MINUS_SRC_ALPHA）で重ねる。
    /// 骨つきの版は group 2（姿勢）と、形の版のジョイントの番号と重み（location 14・15）を読む（呼ぶ側が mesh#skinAt のある形だけを渡す）。
    /// lightmap の版は 2 本目の uv（location 13）を読む（呼ぶ側が mesh#uv2At のある形だけを渡す）。
    def pipelineOf(m: Materials, mp: MaterialPass, p: Program, mesh: MeshBuffers): RenderPipeline \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let key = materialPipelineSlotOf({ program = p#id, format = WebGpuPipelines.formatCode(mp#format), samples = mp#samples, stride = mesh#stride });
        match Map.get(key, Ref.get(s#pipelines)) {
            case Some(found) => found
            case None =>
                let desc = new RenderPipelineDesc("fge material");
                let skinned = p#kind#skinned;
                discard desc.bindGroupLayout(mp#sceneLayout).bindGroupLayout(p#layout).vertex(vertexModuleOf(m, p#kind#uv, p#kind#lightmap, skinned, p#kind#psx), "vs_main").fragment(p#fragment, "fs_main");
                if (skinned) discard desc.bindGroupLayout(mp#poseLayout) else ();
                discard desc.vertexBuffer(mesh#stride, false).attribute(VertexFormat.FLOAT32X3, 0, 0).attribute(VertexFormat.FLOAT32X3, 12, 1).attribute(VertexFormat.FLOAT32X3, 24, 2);
                if (p#kind#uv) discard desc.attribute(VertexFormat.FLOAT32X2, 36, 11).attribute(VertexFormat.FLOAT32X4, 44, 12) else ();
                if (p#kind#lightmap and not skinned) mesh#uv2At |> Option.forEach(at -> discard desc.attribute(VertexFormat.FLOAT32X2, at, 13)) else ();
                if (skinned) mesh#skinAt |> Option.forEach(at -> discard desc.attribute(VertexFormat.FLOAT32X4, at, 14).attribute(VertexFormat.FLOAT32X4, at + 16, 15)) else ();
                discard desc.vertexBuffer(Render3dWgsl.instanceBytes(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 3).attribute(VertexFormat.FLOAT32X4, 16, 4);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 5).attribute(VertexFormat.FLOAT32X4, 48, 6);
                discard desc.attribute(VertexFormat.FLOAT32X4, 64, 7).attribute(VertexFormat.FLOAT32X4, 80, 8);
                discard desc.attribute(VertexFormat.FLOAT32X4, 96, 9).attribute(VertexFormat.FLOAT32X4, 112, 10);
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(mp#format));
                if (p#kind#blend)
                    discard desc.blend(BlendFactor.SRC_ALPHA, BlendFactor.ONE_MINUS_SRC_ALPHA, BlendOperation.ADD, BlendFactor.ONE, BlendFactor.ONE_MINUS_SRC_ALPHA, BlendOperation.ADD)
                else ();
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, if (p#kind#doubleSided) CullMode.NONE else CullMode.BACK);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, not p#kind#blend, CompareFunction.LESS).multisample(mp#samples);
                let made = s#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(s#pipelines)), s#pipelines);
                made
        }

    /// 材質の頂点シェーダー（uv つきの版か・lightmap つきの版か・骨つきの版か・PS1 風の版か。無ければ作る）。
    def vertexModuleOf(m: Materials, uv: Bool, lightmap: Bool, skinned: Bool, psx: Bool): ShaderModule \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let baked = lightmap and not skinned;
        let key = (uv, baked, skinned, psx);
        match Map.get(key, Ref.get(s#vertexModules)) {
            case Some(found) => found
            case None =>
                let made = s#gpu.createShaderModule("fge material vs", Render3dWgsl.materialVertexSourceFor(uv, baked, skinned, psx));
                Ref.put(Map.insert(key, made, Ref.get(s#vertexModules)), s#vertexModules);
                made
        }
}
