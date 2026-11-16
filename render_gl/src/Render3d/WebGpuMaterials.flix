// Render3d.WebGpuMaterials — WebGPU の 3D の材質の分（材質の program・材質の絵の置き場・draw ごとの値の buffer・材質の pipeline と group 1）。
// Render3d.WebGpuRenderer が 1 つ持つ。材質は計画の問い合わせ（Render3d.ScenePlan.MaterialRequest）ごとに resolve で答え、行の values と reads
// （並びは Render3d.MaterialValues の頭）を、値の buffer の区画と絵の表（Render3d.TextureTable3d）の番号で group 1 に付ける。
// 描く材質: lightmap の無い・半透明でない・alpha to coverage でない材質（骨つき・uv・法線マップ・両面・cutout・metallic と roughness を含む）。
// 描かない版は順の番号 0 で答え、計画は頂点の色の道へ回す（知らせるのは Render3d.WebGpuRenderer.skipsOf）。
// WhyNot: alpha to coverage の版を描かない — render_gl/java の RenderPipelineDesc に alphaToCoverage の口が無い（足すと GL の層の jar のハッシュが動く）。
//   計画には描き先の能力として「alpha to one が無い」と答え、cutout は discard で抜く（ブラウザの GL と同じ）。
// WhyNot: lightmap の版をここで描かない — lightmap の段の数・色空間・強さは物ごとの値で、今の WGSL は色空間と強さを場面の値（R3dScene）に置いている。
//   物ごとの値の区画へ移す時に lightmap の絵の bind と一緒に入れる（(5)）。
// WhyNot: pub を外さない — 値の binding の形（ValuesBinding）を bench/webgpu_v2 の比べが選ぶ（親の Render3d が pub でないので、別のパッケージのゲームからは見えない）。
pub mod Render3d.WebGpuMaterials {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FilterMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderPass
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
    use Render3d.{ProgramKind, TextureSource, materialKey}
    use Render3d.MaterialValues
    use Render3d.ScenePlan.{MaterialRequest}
    use Render3d.SceneList.{SceneList, flagNormalMap, flagSameBinding, hasFlag, kindMaterial, materialAt, readAt, rowAt, rowCountOf, valuesAt}
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
    type alias Program = { id = Int32, kind = ProgramKind, fragment = ShaderModule, layout = BindGroupLayout, slotCount = Int32, texCount = Int32 }

    /// GPU に置いた材質の絵 1 枚。borrowed = 2D の描き手の絵を借りている（全体の登録の絵。捨てるのは 2D の描き手）。
    type alias GpuTexture = { texture = Texture, levels = Int32, borrowed = Bool }

    /// 状態。programs = materialKey → 組んだ program（組めなければ None）・current = 今の prepare の問い合わせの順の program（行の欄 1 が引く）・
    /// vertexModules = (uv つきか, 骨つきか) → 材質の頂点シェーダー・pipelines = (program, 形式の番号, 標本, 頂点のバイト数) → pipeline・
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
            vertexModules = Ref[Map[(Bool, Bool), ShaderModule], Static],
            pipelines = Ref[Map[(Int32, Int32, Int32, Int32), RenderPipeline], Static],
            textures = TextureTable3d.Table,
            store = Ref[Map[Int32, GpuTexture], Static],
            samplers = Array[Sampler, Static],
            blank = Texture,
            values = Array[Buffer, Static],
            valuesUsed = Array[Int32, Static],
            groups = Ref[List[BindGroup], Static],
            warned = Ref[Set[String], Static]
        })
    }

    pub type alias Materials = MaterialsData

    /// 値の buffer の始めの大きさ（バイト）。
    def initialValueBytes(): Int32 = 65536

    /// 値の区画のそろえ（バイト。core の minUniformBufferOffsetAlignment と minStorageBufferOffsetAlignment の上限）。
    def valueAlignBytes(): Int32 = 4 * MaterialValues.valueAlign()

    /// r3dDraw の binding の大きさ（Render3dWgsl の R3dDraw: f32 が 4 つ）。
    def drawValueBytes(): Int64 = 16i64

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
            groups = Ref.fresh(Static, Nil), warned = Ref.fresh(Static, Set.empty())
        })

    def createValueBuffer(gpu: WebGpu, bytes: Int32): Buffer \ IO =
        gpu.createBuffer("fge material values", Int32.toInt64(bytes), Int32.bitwiseOr(Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.STORAGE), BufferUsage.COPY_DST))

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
        Array.get(0, s#values).destroy()

    /// 2D の描き手が encoder を submit した後に呼ぶ（group 1 を手放し、値の buffer を頭から書き直せる）。
    pub def afterSubmit(m: Materials): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        Ref.get(s#groups) |> List.forEach(g -> g.release());
        Ref.put(Nil, s#groups);
        Array.put(0, 0, s#valuesUsed)

    /// 画面のコマの終わりに、材質の絵を置き場の上限（GameEngine の既定）で捨てる。
    // WhyNot: project.json の scene3dTextureBudgetMB・Count を読まない — WebGPU の描き手を作る所（WebGpuPaint）に config が届いていない。届けるのは engine の口に触れる時（持ち越し）。
    pub def endFrame(m: Materials, gen: Int64): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let budget = { count = GameEngine.defaultScene3dTextureBudgetCount(), size = Int32.toInt64(GameEngine.defaultScene3dTextureBudgetMB()) * 1048576i64 };
        discard TextureTable3d.sweep(s#textures, destroyTexture(s#store), gen, budget, Set.empty())

    // ── 材質の program ──

    /// 版 kind の材質をこの描き手が描けるか。
    pub def isDrawable(kind: ProgramKind): Bool = not kind#lightmap and not kind#blend and not kind#coverage

    /// 問い合わせ requests に順の番号で答える（描けない版と組めない材質は 0）。答えた表は current に控え、行の欄 1（問い合わせの番号）で引く。
    /// 初めての材質はここで組み、noteBuild(名前) を呼ぶ。
    pub def resolve(m: Materials, noteBuild: String -> Unit \ IO, requests: Vector[MaterialRequest]): Vector[Int32] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let programs = requests |> Vector.map(match (fields, kind) -> if (isDrawable(kind)) programOf(m, noteBuild, fields, kind) else None);
        Ref.put(programs, s#current);
        Vector.map(p -> p |> Option.map(x -> x#id) |> Option.getWithDefault(0), programs)

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
        let errors = String.lines(s#gpu.getCompilationInfo(module)) |> List.filter(l -> String.startsWith({ prefix = "Error" }, l));
        match errors {
            case first :: _ =>
                module.release();
                warnOnce(m, spec#name, () -> Log.fellBack("scene3d", spec#name, "頂点の色", "材質の WGSL を組めない（${first}）"));
                None
            case Nil =>
                let id = Array.get(0, s#nextId);
                Array.put(id + 1, 0, s#nextId);
                let texCount = List.length(wgsl#texReads);
                Some({ id = id, kind = kind, fragment = module, layout = createLayout(m, texCount, kind#uv and kind#normalMap),
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

    /// group 1 の layout: 0 = sg・1 + 2k と 2 + 2k = 材質の絵と sampler・Render3dWgsl.drawBinding() = r3dDraw・その次の 2 つ = 法線マップと sampler。
    def createLayout(m: Materials, texCount: Int32, normalMapped: Bool): BindGroupLayout \ IO =
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
        s#gpu.createBindGroupLayout(desc)

    // ── 材質の絵 ──

    /// 行 list の材質の行が読む絵を作る（無ければ）。source = 場面の textures と全体の登録・textureById = 登録の絵の番号 → 2D の描き手の texture・
    /// gen = 今の世代。描き始める前に呼ぶ。
    pub def uploadTextures(m: Materials, source: TextureSource, textureById: Int32 -> Option[Texture] \ IO, gen: Int64, list: SceneList): Unit \ IO =
        uploadTexturesFrom(m, { source = source, textureById = textureById, gen = gen }, list, 0, rowCountOf(list))

    def uploadTexturesFrom(m: Materials, up: TextureUploads, list: SceneList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            if (rowAt(list, row, 0) == kindMaterial() and valuesAt(list, row) >= 0) materialAt(list, row) |> Option.forEach(f -> uploadRowTextures(m, up, list, row, f))
            else ();
            uploadTexturesFrom(m, up, list, row + 1, n)
        }

    /// uploadTextures の 1 回で行をまたいで変わらない物。
    type alias TextureUploads = { source = TextureSource, textureById = Int32 -> Option[Texture] \ IO, gen = Int64 }

    def uploadRowTextures(m: Materials, up: TextureUploads, list: SceneList, row: Int32, f: Scene3d.MaterialFields): Unit \ IO =
        let normal = if (hasFlag(list, row, flagNormalMap())) f#normalMap |> Option.map(n -> (n#texture, Texture3d.TextureUse.NormalMap)) |> Option.toList else Nil;
        let count = rowAt(list, row, 10) - List.length(normal);
        let colors = ShaderDoc.materialTexReads(f#spec, f#emission, f#metallicRoughnessShade) |> List.take(count) |> List.map(nf -> (fst(nf), Texture3d.TextureUse.MaterialTexture));
        List.append(colors, normal) |> List.forEach(match (name, textureUse) -> ensureTexture(m, up, name, textureUse))

    /// 絵 name を表の番号で作る。場面の絵は段つきで上げ、全体の登録の絵は 2D の描き手の texture を段 1 つのまま借りる（元の絵が作り直されたら借り直す）。
    // WhyNot: 全体の登録の絵の段つきの写しを作らない — 2D の texture から段を作る道（読み戻すか GPU で縮める）が WebGPU にまだ無い。遠くの面は GL より細かくちらつく（持ち越し）。
    def ensureTexture(m: Materials, up: TextureUploads, name: String, textureUse: Texture3d.TextureUse): Unit \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let average = Texture3d.mipAverageOf(Texture3d.mipSpaceOf(textureUse));
        let hit = TextureTable3d.findTexture(up#source, name);
        match (TextureTable3d.readOf(false, up#source, name, textureUse), hit) {
            case (Some((slot, _)), Some(TextureHit.Own(t))) =>
                discard TextureTable3d.ensure(s#textures, destroyTexture(s#store), up#gen, slot, "", handle -> uploadTexture3d(m, handle, average, t))
            case (Some((slot, _)), Some(TextureHit.Registered(t))) =>
                discard TextureTable3d.ensure(s#textures, destroyTexture(s#store), up#gen, slot, "${t#texId}:${t#version}", handle -> borrowTexture(m, up, handle, t#texId))
            case _ => ()
        }

    /// 2D の描き手の絵 texId を番号 handle で借りる（段 1 つ・置き場の大きさに数えない）。
    def borrowTexture(m: Materials, up: TextureUploads, handle: Int32, texId: Int32): Option[{ levels = Int32, bytes = Int64 }] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        (up#textureById)(texId) |> Option.map(texture -> {
            Ref.put(Map.insert(handle, { texture = texture, levels = 1, borrowed = true }, Ref.get(s#store)), s#store);
            { levels = 1, bytes = 0i64 }
        })

    /// 場面の絵 t を CPU で段を作って上げ、番号 handle で控える（機種の側の絵は上げられないので None）。
    // WhyNot: 段を GPU に作らせない — WebGPU に generateMipmap は無く、CPU の描き出しと同じ Mip.build の段にそろえる（GL の CPU の段と同じ鍵）。
    def uploadTexture3d(m: Materials, handle: Int32, average: Mip.Average, t: Texture3d.Texture3d): Option[{ levels = Int32, bytes = Int64 }] \ IO =
        let MaterialsData.MaterialsData(s) = m;
        match Texture3d.sourceOf(t) {
            case Texture3d.Source.PlatformImage(_) => None
            case Texture3d.Source.Argb(pixels) =>
                let chain = Mip.build(average, { width = Texture3d.width(t), height = Texture3d.height(t), pixels = pixels });
                let levels = List.length(chain);
                let texture = s#gpu.createTexture("fge material ${Texture3d.name(t)}", Texture3d.width(t), Texture3d.height(t), TextureFormat.BGRA8_UNORM,
                                                  Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), levels, 1);
                chain |> List.forEachWithIndex((level, td) -> s#gpu.writeTexture(texture, level, 0, 0, td#width, td#height, argbBytes(td#pixels), 0, td#width * 4));
                Ref.put(Map.insert(handle, { texture = texture, levels = levels, borrowed = false }, Ref.get(s#store)), s#store);
                Some({ levels = levels, bytes = List.foldLeft((acc, td) -> acc + Int32.toInt64(td#width * td#height * 4), 0i64, chain) })
        }

    /// ARGB の int の列を little-endian のバイト（B・G・R・A）にする。
    // WhyNot: 1 要素ずつ put しない — Flix の Vector は JVM の int[] のままで、1 回で写せる（WebGpuPaint.argbBytes と同じ）。
    def argbBytes(argb: Vector[Int32]): ByteBuffer \ IO =
        let arr = unchecked_cast(argb as Array[Int32, Static]);
        let bytes = ByteBuffer.allocateDirect(Int32.max(4, Vector.length(argb) * 4)).order(ByteOrder.LITTLE_ENDIAN);
        discard bytes.asIntBuffer().put(arr);
        bytes

    def destroyTexture(store: Ref[Map[Int32, GpuTexture], Static]): Int32 -> Unit \ IO = handle -> {
        Map.get(handle, Ref.get(store)) |> Option.forEach(g -> if (g#borrowed) () else g#texture.destroy());
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
        let data = ByteBuffer.allocateDirect(Int32.max(4, bytes)).order(ByteOrder.LITTLE_ENDIAN);
        discard data.asFloatBuffer().put(list#values);
        s#gpu.writeBuffer(Array.get(0, s#values), Int32.toInt64(at), data, 0, bytes);
        Array.put(at + bytes, 0, s#valuesUsed);
        at

    def roundUp(n: Int32, step: Int32): Int32 = ((n + step - 1) / step) * step

    // ── 描く ──

    /// pass の中で今付けている pipeline（同じ物を付け直さないための鍵）。Shape(pass の番号, 頂点のバイト数, 骨つきか) = 頂点の色の pipeline・
    /// Material(program の順の番号, 頂点のバイト数) = 材質の pipeline。
    pub enum BoundPipeline with Eq {
        case Unbound
        case Shape(Int32, Int32, Bool)
        case Material(Int32, Int32)
    }

    /// 材質の行を描く pass の付け方の材料。base = 行の values を送った位置（バイト）・format・samples = 描き先・sceneLayout = group 0 の layout・
    /// poseLayout = group 2（姿勢）の layout・bound = 今の pipeline・groupRow = 最後に group 1 を付けた行（要素 1 つ・-1 = 付けていないか、付けた物が材質の group でない）。
    pub type alias MaterialPass = {
        base = Int32, format = RenderTarget.Format, samples = Int32, sceneLayout = BindGroupLayout, poseLayout = BindGroupLayout,
        bound = Ref[BoundPipeline, Static], groupRow = Array[Int32, Static]
    }

    /// 行 row の材質の pipeline と group 1 を pass に付ける（描けない行は偽）。前の材質の行と同じ付け方（flagSameBinding）の行は group を付け直さない。
    pub def bindRow(m: Materials, mp: MaterialPass, pass: RenderPass, list: SceneList, row: Int32, mesh: MeshBuffers): Bool \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let handle = rowAt(list, row, 1);
        let current = Ref.get(s#current);
        let program = if (handle >= 0 and handle < Vector.length(current)) Vector.get(handle, current) else None;
        let valuesOk = valuesAt(list, row) >= 0;
        match program {
            case Some(p) if valuesOk and (not p#kind#skinned or Option.nonEmpty(mesh#skinAt)) =>
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

    /// 行 row の group 1（値の区画 2 つと、reads の絵と sampler）。submit の後に手放す。
    def buildGroup(m: Materials, mp: MaterialPass, p: Program, list: SceneList, row: Int32): BindGroup \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let buffer = Array.get(0, s#values);
        let at = mp#base + 4 * valuesAt(list, row);
        let desc = new BindGroupDesc("fge material", p#layout);
        discard desc.buffer(Render3dWgsl.drawBinding(), buffer, Int32.toInt64(at), drawValueBytes());
        discard desc.buffer(0, buffer, Int32.toInt64(at + valueAlignBytes()), Int32.toInt64(roundUp(4 * p#slotCount, 16)));
        let store = Ref.get(s#store);
        let textureAt = (k: Int32) -> Map.get(readAt(list, row, k, 0), store) |> Option.map(g -> g#texture) |> Option.getWithDefault(s#blank);
        let samplerAt = (k: Int32) -> Array.get(2 * readAt(list, row, k, 2) + readAt(list, row, k, 1), s#samplers);
        putTexturesFrom(desc, textureAt, samplerAt, 0, p#texCount);
        if (p#kind#uv and p#kind#normalMap) {
            let draw = Render3dWgsl.drawBinding();
            discard desc.textureView(draw + 1, textureAt(p#texCount).defaultView()).sampler(draw + 2, samplerAt(p#texCount))
        } else ();
        let group = s#gpu.createBindGroup(desc);
        Ref.put(group :: Ref.get(s#groups), s#groups);
        group

    /// 材質の絵の k 番目から n の前までを desc の 1 + 2k（絵）と 2 + 2k（sampler）へ。
    def putTexturesFrom(desc: BindGroupDesc, textureAt: Int32 -> Texture \ IO, samplerAt: Int32 -> Sampler \ IO, k: Int32, n: Int32): Unit \ IO =
        if (k >= n) ()
        else {
            discard desc.textureView(1 + 2 * k, textureAt(k).defaultView()).sampler(2 + 2 * k, samplerAt(k));
            putTexturesFrom(desc, textureAt, samplerAt, k + 1, n)
        }

    /// program p で形 mesh を mp の描き先へ描く pipeline（無ければ作る）。表の面は時計回りで、両面の材質だけ裏を間引かない。深度は LESS で書く。
    /// 骨つきの版は group 2（姿勢）と、形の版のジョイントの番号と重み（location 14・15）を読む（呼ぶ側が mesh#skinAt のある形だけを渡す）。
    def pipelineOf(m: Materials, mp: MaterialPass, p: Program, mesh: MeshBuffers): RenderPipeline \ IO =
        let MaterialsData.MaterialsData(s) = m;
        let key = (p#id, WebGpuPipelines.formatCode(mp#format), mp#samples, mesh#stride);
        match Map.get(key, Ref.get(s#pipelines)) {
            case Some(found) => found
            case None =>
                let desc = new RenderPipelineDesc("fge material");
                let skinned = p#kind#skinned;
                discard desc.bindGroupLayout(mp#sceneLayout).bindGroupLayout(p#layout).vertex(vertexModuleOf(m, p#kind#uv, skinned), "vs_main").fragment(p#fragment, "fs_main");
                if (skinned) discard desc.bindGroupLayout(mp#poseLayout) else ();
                discard desc.vertexBuffer(mesh#stride, false).attribute(VertexFormat.FLOAT32X3, 0, 0).attribute(VertexFormat.FLOAT32X3, 12, 1).attribute(VertexFormat.FLOAT32X3, 24, 2);
                if (p#kind#uv) discard desc.attribute(VertexFormat.FLOAT32X2, 36, 11).attribute(VertexFormat.FLOAT32X4, 44, 12) else ();
                if (skinned) mesh#skinAt |> Option.forEach(at -> discard desc.attribute(VertexFormat.FLOAT32X4, at, 14).attribute(VertexFormat.FLOAT32X4, at + 16, 15)) else ();
                discard desc.vertexBuffer(Render3dWgsl.instanceBytes(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 3).attribute(VertexFormat.FLOAT32X4, 16, 4);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 5).attribute(VertexFormat.FLOAT32X4, 48, 6);
                discard desc.attribute(VertexFormat.FLOAT32X4, 64, 7).attribute(VertexFormat.FLOAT32X4, 80, 8);
                discard desc.attribute(VertexFormat.FLOAT32X4, 96, 9).attribute(VertexFormat.FLOAT32X4, 112, 10);
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(mp#format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, if (p#kind#doubleSided) CullMode.NONE else CullMode.BACK);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, true, CompareFunction.LESS).multisample(mp#samples);
                let made = s#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(s#pipelines)), s#pipelines);
                made
        }

    /// 材質の頂点シェーダー（uv つきの版か・骨つきの版か。無ければ作る）。
    def vertexModuleOf(m: Materials, uv: Bool, skinned: Bool): ShaderModule \ IO =
        let MaterialsData.MaterialsData(s) = m;
        match Map.get((uv, skinned), Ref.get(s#vertexModules)) {
            case Some(found) => found
            case None =>
                let made = s#gpu.createShaderModule("fge material vs", Render3dWgsl.materialVertexSource(uv, false, skinned));
                Ref.put(Map.insert((uv, skinned), made, Ref.get(s#vertexModules)), s#vertexModules);
                made
        }
}
