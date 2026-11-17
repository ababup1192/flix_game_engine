// Render3d.MaterialValues — 不透明の材質の行の draw ごとの値（Render3d.SceneList の values）と絵の組（reads）を計画の側で書く所。
// 値の並びは材質ごとに 2 つの区画: 頭の drawValueFloats() 個 = 物ごとの値（Render3dWgsl の R3dDraw: cutout・法線マップの強さ・法線マップの段の数・lightmap の段の数・
// lightmap の色空間（sRGB なら 1）・lightmap の強さ）、
// 続く区画 = ShaderGen.Wgsl.compile3d の slots の並び（uTime・uTexLevelsN・uParamN）。どちらの区画の頭も valueAlign() 個（256 バイト）の倍数の位置。
// 絵の組は 1 つ readStride() 個: 0 = 絵の表の番号（Render3d.TextureTable3d。無い絵・上下を返して読む全体の登録の絵は -1）・1 = 補間（0 Nearest・1 Linear）・2 = 読み方（0 Repeat・1 Clamp）。
// 並びは材質の絵（ShaderDoc.materialTexReads を上限で切った物）→ 法線マップ（法線マップの版だけ）→ lightmap（lightmap の版だけ・Clamp と段つきの Linear で読む）。
// lightmap の行は 1 行 1 体（Render3d.Batch が lightmap つきを batch にしない）で、値と絵の組は行の頭の物の lightmap。
// WhyNot: 区画を 256 バイトにそろえずに詰めない — WebGPU は uniform の binding を 256 バイト（core の minUniformBufferOffsetAlignment の上限）の倍数の位置でしか付けられない（2D の面の values と同じ・12.22）。
// WhyNot: 値の並びを backend が材質の program を組んだ時に決めない — 計画が backend に聞かずに書け、GL と WebGPU が同じ値を読む（並びは ShaderGen が決め、ここは同じ数え方で写す）。
mod Render3d.MaterialValues {
    use Render3d.{ProgramKind, TextureSource}
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.TextureTable3d

    /// 材質の値の並びの元。readCount = 読む絵の組の数（Scene3d.maxMaterialTextures() で切った後）・paramNames = uParamN の名前の並び。
    pub type alias Layout = { readCount = Int32, paramNames = List[String] }

    /// 材質の木の鍵（MaterialFields#shaderHash）→ 並びの元。
    pub type alias Layouts = Ref[Map[Int64, Layout], Static]

    pub def freshLayouts(): Layouts \ IO = Ref.fresh(Static, Map.empty())

    /// 絵の名前を表の番号へ引く元。source = 場面の textures と全体の登録・gpuMip = 段を GPU に作らせる backend か（鍵の作り方）・
    /// textures = 絵の表・gen = 番号を振る時の世代。
    pub type alias Naming = { source = TextureSource, gpuMip = Bool, textures = TextureTable3d.Table, gen = Int64 }

    /// 区画の頭をそろえる個数（Float32 で 256 バイト）。
    pub def valueAlign(): Int32 = 64

    /// 物ごとの値の区画の個数。
    pub def drawValueFloats(): Int32 = valueAlign()

    /// 絵の組 1 つの個数。
    pub def readStride(): Int32 = 3

    /// 材質 m の並びの元（木の鍵ごとに 1 回だけ求める）。
    // WhyNot: 毎コマ木から uParamN の並びを数え直さない — 材質の行は物の数だけあり、木を回すのが行の数だけ増える。
    pub def layoutOf(layouts: Layouts, m: Scene3d.MaterialFields): Layout \ IO =
        let key = force m#shaderHash;
        match Map.get(key, Ref.get(layouts)) {
            case Some(found) => found
            case None =>
                let (spec, emission, metallicRoughness) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), m#spec, m#emission, m#metallicRoughnessShade);
                let made = { readCount = List.length(ShaderDoc.materialTexReads(spec, emission, metallicRoughness)),
                             paramNames = ShaderDoc.materialParamNames(spec, emission, metallicRoughness) };
                Ref.put(Map.insert(key, made, Ref.get(layouts)), layouts);
                made
        }

    /// layout の材質 1 つが values に取る個数（2 つの区画）。
    pub def valueSizeOf(layout: Layout): Int32 =
        drawValueFloats() + roundUp(1 + layout#readCount + List.length(layout#paramNames), valueAlign())

    /// layout と版 kind の材質 1 つが reads に取る組の数。
    pub def readCountOf(layout: Layout, kind: ProgramKind): Int32 = layout#readCount + (if (kind#normalMap) 1 else 0) + (if (kind#lightmap) 1 else 0)

    /// 絵の組の中の lightmap の番号（readCount = 材質の絵の数・normalMapped = 法線マップの版。並びは材質の絵 → 法線マップ → lightmap）。
    pub def lightmapReadAt(readCount: Int32, normalMapped: Bool): Int32 = readCount + (if (normalMapped) 1 else 0)

    /// lightmap lm を段の数 textureLevels の絵で読む時の段の数（GL の uniform と WebGPU の values の両方がこの数を使う）。
    pub def lightmapLevelsOf(lm: Scene3d.Lightmap, textureLevels: Int32): Int32 = Int32.min(textureLevels, lm#maxLevels)

    def roundUp(n: Int32, step: Int32): Int32 = ((n + step - 1) / step) * step

    /// 材質の batch d（並びの元 layout）の値を values の at から、絵の組を reads の readAt から書く。time = 場面の時刻（uTime）。
    pub def put(naming: Naming, layout: Layout, d: MaterialBatch[MeshBatch], time: Float64, values: Array[Float32, Static], at: Int32,
                reads: Array[Int32, Static], readAt: Int32): Unit \ IO =
        let m = d#material;
        let wrap = if (m#wrap == Scene3d.Wrap.Clamp) 1 else 0;
        let names = ShaderDoc.materialTexReads(m#spec, m#emission, m#metallicRoughnessShade) |> List.take(layout#readCount);
        let sg = at + drawValueFloats();
        Array.put(RenderUtil.f32(time), sg, values);
        names |> List.forEachWithIndex((k, nf) -> {
            let (name, filter) = nf;
            let levels = putRead(naming, name, Texture3d.TextureUse.MaterialTexture, (filterCodeOf(filter), wrap), reads, readAt + readStride() * k);
            Array.put(Int32.toFloat32(Scene3d.materialMipLevelsOf(m, levels)), sg + 1 + k, values)
        });
        layout#paramNames |> List.forEachWithIndex((i, name) ->
            Array.put(RenderUtil.f32(Map.getWithDefault(name, 0.0, m#params)), sg + 1 + layout#readCount + i, values));
        Array.put(if (m#cutout) 1.0f32 else 0.0f32, at, values);
        if (d#kind#normalMap) m#normalMap |> Option.forEach(n -> {
            let levels = putRead(naming, n#texture, Texture3d.TextureUse.NormalMap, (1, wrap), reads, readAt + readStride() * layout#readCount);
            Array.put(RenderUtil.f32(n#strength), at + 1, values);
            Array.put(Int32.toFloat32(levels), at + 2, values)
        }) else ();
        if (d#kind#lightmap) Scene3d.lightmapOfFields(d#batch#head#fields) |> Option.forEach(lm -> {
            let k = lightmapReadAt(layout#readCount, d#kind#normalMap);
            let levels = putRead(naming, lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace), (1, 1), reads, readAt + readStride() * k);
            Array.put(Int32.toFloat32(lightmapLevelsOf(lm, levels)), at + 3, values);
            Array.put(if (lm#colorSpace == Texture3d.ColorSpace.Srgb) 1.0f32 else 0.0f32, at + 4, values);
            Array.put(RenderUtil.f32(lm#intensity), at + 5, values)
        }) else ()

    /// 絵 name の組を reads の at へ書き、段の数を返す（無い絵は番号 -1・段 1）。how = (補間, 読み方)。
    def putRead(naming: Naming, name: String, textureUse: Texture3d.TextureUse, how: (Int32, Int32), reads: Array[Int32, Static], at: Int32): Int32 \ IO =
        let (filter, wrap) = how;
        let found = TextureTable3d.readOf(naming#gpuMip, naming#source, name, textureUse);
        let handle = found |> Option.map(sl -> TextureTable3d.numberOf(naming#textures, naming#gen, fst(sl))) |> Option.getWithDefault(-1);
        Array.put(handle, at, reads);
        Array.put(filter, at + 1, reads);
        Array.put(wrap, at + 2, reads);
        found |> Option.map(snd) |> Option.getWithDefault(1)

    def filterCodeOf(f: ShaderDoc.FilterMode): Int32 = match f {
        case ShaderDoc.FilterMode.Nearest => 0
        case ShaderDoc.FilterMode.Linear  => 1
    }
}
