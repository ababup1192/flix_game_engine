// 3D のシェーダーの字を全部の版で組めることと、版の数を確かめる。
// 環境変数 FLIX_GE_SHADER_DUMP にフォルダの絶対パスがあれば、版ごとに 1 ファイルずつ書き出し、組んだ時間（ms）を 1 行出す
// （直す前と後の書き出しを diff -r で比べる。make shader-dump）。
mod TestShaderDump {
    import java.io.File
    import java.lang.System
    import java.io.FileOutputStream
    use ShaderDoc.{Field, Shade, TexChan, BinOp}

    def flags(): List[Bool] = false :: true :: Nil

    def allVariants(): List[Render3d.ProgramKey.ShaderVariant] =
        flags() |> List.flatMap(ps -> flags() |> List.flatMap(pu -> flags() |> List.flatMap(psx -> flags() |> List.map(sh ->
            { pointShadows = ps, physicalUnits = pu, psx = psx, skyIrradiance = sh }))))

    def variantLabel(v: Render3d.ProgramKey.ShaderVariant): String =
        let bit = (b: Bool, ch: String) -> if (b) ch else "-";
        bit(v#pointShadows, "s") + bit(v#physicalUnits, "p") + bit(v#psx, "x") + bit(v#skyIrradiance, "h")

    /// 材質の frag の字を変える ProgramKind の正しい組（skinned は頂点だけ・法線マップは uv つきの時だけ）。変種は v。
    def surfaceKinds(v: Render3d.ProgramKey.ShaderVariant): List[Render3d.ProgramKey.ProgramKind] =
        let surfaces = (false, false) :: (true, false) :: (true, true) :: Nil;
        surfaces |> List.flatMap(un -> {
            let (uv, normalMap) = un;
            flags() |> List.flatMap(lightmap -> flags() |> List.flatMap(blend -> flags() |> List.flatMap(doubleSided ->
                flags() |> List.flatMap(coverage -> flags() |> List.map(metallic ->
                    { skinned = false, uv = uv, normalMap = normalMap, lightmap = lightmap, blend = blend, doubleSided = doubleSided,
                      coverage = coverage, metallicRoughness = metallic, variant = { pointShadows = v#pointShadows, physicalUnits = v#physicalUnits, psx = v#psx, skyIrradiance = v#skyIrradiance } })))))
        })

    def kindLabel(k: Render3d.ProgramKey.ProgramKind): String =
        let bit = (b: Bool, ch: String) -> if (b) ch else "-";
        bit(k#uv, "u") + bit(k#normalMap, "n") + bit(k#lightmap, "l") + bit(k#blend, "b") + bit(k#doubleSided, "d") + bit(k#coverage, "c")
            + bit(k#metallicRoughness, "m") + "_" + variantLabel(Render3d.ProgramKey.shaderVariantOfKind(k))

    def fill(name: String, shade: Shade, alpha: Field): ShaderDoc.Spec =
        { name = name, cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = shade, alpha = alpha }) }

    /// 絵を読まない材質（頂点の色 × param）と、絵を読む材質（sg_texMip を持つ）。
    def materials(): List[(String, ShaderDoc.Spec)] =
        let tint = (chan: TexChan, name: String) -> Field.Bin({ op = BinOp.Mul, a = Field.VertexColor({ chan = chan }), b = Field.Param({ name = name }) });
        let tex = (chan: TexChan) -> Field.Tex({ name = "albedo", chan = chan });
        ("field", fill("field", Shade.Rgb({ r = tint(TexChan.R, "r"), g = tint(TexChan.G, "g"), b = tint(TexChan.B, "b") }), Field.Param({ name = "a" }))) ::
        ("textured", fill("textured", Shade.Rgb({ r = tex(TexChan.R), g = tex(TexChan.G), b = tex(TexChan.B) }), tex(TexChan.A))) :: Nil

    def metalOf(k: Render3d.ProgramKey.ProgramKind): Option[Shade] =
        if (k#metallicRoughness) Some(Shade.Rgb({ r = Field.Param({ name = "metal" }), g = Field.Param({ name = "rough" }), b = Field.Const(0.0) })) else None

    def glowOf(): Option[Shade] = Some(Shade.Rgb({ r = Field.Param({ name = "glow" }), g = Field.Const(0.0), b = Field.Const(0.0) }))

    /// 全部の変種を回す時の材質の組（全部の組 × 全部の変種は数千になるので、代表の 8 組）。
    def representativeKinds(v: Render3d.ProgramKey.ShaderVariant): List[Render3d.ProgramKey.ProgramKind] =
        surfaceKinds(v) |> List.filter(k ->
            (not k#blend and not k#coverage and not k#doubleSided) or (k#uv and k#normalMap and k#lightmap and k#doubleSided and k#metallicRoughness and not k#coverage))

    def materialFragments(): List[(String, String)] =
        let d = Render3d.ProgramKey.defaultShaderVariant();
        let kinds = surfaceKinds(d) ::: (allVariants() |> List.filter(v -> variantLabel(v) != variantLabel(d)) |> List.flatMap(representativeKinds));
        materials() |> List.flatMap(nm -> {
            let (name, spec) = nm;
            kinds |> List.flatMap(k -> {
                let glsl = ShaderGen.compile3d(spec, glowOf(), metalOf(k));
                let wgsl = ShaderGen.Wgsl.compile3d(spec, glowOf(), metalOf(k), 1);
                ("glsl/frag-material-${name}-${kindLabel(k)}.frag", Render3dGlsl.materialFragmentSource(glsl, k)) ::
                ("wgsl/frag-material-${name}-${kindLabel(k)}.wgsl", Render3dWgsl.materialFragmentSource(wgsl, k)) :: Nil
            })
        })

    def materialVertices(): List[(String, String)] =
        flags() |> List.flatMap(skinned -> flags() |> List.flatMap(uv -> flags() |> List.flatMap(lightmap -> flags() |> List.flatMap(psx -> {
            let label = (if (skinned) "s" else "-") + (if (uv) "u" else "-") + (if (lightmap) "l" else "-") + (if (psx) "x" else "-");
            ("glsl/vertex-material-${label}.vert", Render3dGlsl.materialVertexSourceFor({ skinned = skinned, uv = uv, lightmap = lightmap }, psx)) ::
            ("wgsl/vertex-material-${label}.wgsl", Render3dWgsl.materialVertexSourceFor(uv, lightmap, skinned, psx)) :: Nil
        }))))

    def perVariant(): List[(String, String)] =
        allVariants() |> List.flatMap(v -> {
            let l = variantLabel(v);
            ("glsl/light-${l}.glsl", Render3dGlsl.lightSourceFor(v)) ::
            ("wgsl/light-${l}.wgsl", Render3dWgsl.lightSourceFor(v)) ::
            ("glsl/frag-lit-${l}.frag", Render3dGlsl.litFragmentSourceFor(v)) ::
            ("wgsl/frag-lit-${l}.wgsl", Render3dWgsl.litFragmentSourceFor(v)) ::
            ("glsl/vertex-lit-${l}.vert", Render3dGlsl.litVertexSourceFor(false, v)) ::
            ("glsl/vertex-lit-skinned-${l}.vert", Render3dGlsl.litVertexSourceFor(true, v)) ::
            ("glsl/vertex-billboard-${l}.vert", Render3dGlsl.billboardVertexSourceFor(v)) ::
            ("wgsl/vertex-billboard-${l}.wgsl", Render3dWgsl.billboardVertexSourceFor(v)) ::
            ("glsl/frag-billboard-${l}.frag", Render3dGlsl.billboardFragmentSourceFor(v)) ::
            ("wgsl/frag-billboard-${l}.wgsl", Render3dWgsl.billboardFragmentSourceFor(v)) ::
            ("glsl/metallic-${l}.glsl", Render3dGlsl.metallicRoughnessSourceFor(v)) ::
            ("wgsl/metallic-${l}.wgsl", Render3dWgsl.metallicRoughnessSourceFor(v)) ::
            ("glsl/lightmap-light-${l}.glsl", Render3dGlsl.lightmapLightSourceFor(v)) ::
            ("wgsl/variant-decl-${l}.wgsl", Render3dWgsl.variantDeclarations(v)) :: Nil
        })

    def litVertices(): List[(String, String)] =
        flags() |> List.flatMap(skinned -> flags() |> List.map(psx ->
            ("wgsl/vertex-lit-${if (skinned) "s" else "-"}${if (psx) "x" else "-"}.wgsl", Render3dWgsl.litVertexSourceFor(skinned, psx))))

    def singles(): List[(String, String)] =
        ("glsl/vertex-mesh.vert", Render3dGlsl.meshVertexSource()) ::
        ("glsl/vertex-mesh-skinned.vert", Render3dGlsl.skinnedMeshVertexSource()) ::
        ("glsl/frag-depth.frag", Render3dGlsl.depthFragmentSource()) ::
        ("wgsl/frag-depth.wgsl", Render3dWgsl.depthFragmentSource()) ::
        ("glsl/frag-sky.frag", Render3dGlsl.skyFragmentSource()) ::
        ("wgsl/frag-sky.wgsl", Render3dWgsl.skyFragmentSource()) ::
        ("wgsl/vertex-sky.wgsl", Render3dWgsl.skyVertexSource()) ::
        ("glsl/sky-light.glsl", Render3dGlsl.skyLightSource()) ::
        ("wgsl/sky-light.wgsl", Render3dWgsl.skyLightSource()) ::
        ("glsl/vertex-blit.vert", Render3dGlsl.blitVertexSource()) ::
        ("glsl/frag-blit.frag", Render3dGlsl.blitFragmentSource()) ::
        ("wgsl/vertex-billboard-row-right.wgsl", Render3dWgsl.billboardRowRightVertexSource()) ::
        ("wgsl/frag-billboard-shadow.wgsl", Render3dWgsl.billboardShadowFragmentSource()) ::
        ("glsl/apply-normal-map.glsl", Render3dGlsl.applyNormalMapSource()) ::
        ("wgsl/apply-normal-map.wgsl", Render3dWgsl.applyNormalMapSource()) ::
        ("glsl/color-space.glsl", Render3dGlsl.colorSpaceSource()) ::
        ("wgsl/color-space.wgsl", Render3dWgsl.colorSpaceSource()) ::
        ("glsl/surface-out.glsl", Render3dGlsl.surfaceOutSource()) ::
        ("wgsl/surface-out.wgsl", Render3dWgsl.surfaceOutSource()) ::
        ("wgsl/scene-decl.wgsl", Render3dWgsl.sceneDeclarations()) ::
        ("wgsl/camera-decl.wgsl", Render3dWgsl.cameraDeclarations()) ::
        ("wgsl/shadow.wgsl", Render3dWgsl.shadowSource()) :: Nil

    /// 全部の版の (ファイルの名前, 字)。
    def allSources(): List[(String, String)] =
        singles() ::: perVariant() ::: litVertices() ::: materialVertices() ::: materialFragments()

    def write(dir: String, name: String, text: String): Unit \ IO =
        let file = new File(dir, name);
        discard file.getParentFile().mkdirs();
        let out = new FileOutputStream(file);
        out.write(String.toBytes(text));
        out.close()

    @Test
    def testEverySourceIsBuiltAndCounted(): Unit \ {Assert, IO} =
        let start = System.currentTimeMillis();
        let sources = allSources();
        let total = sources |> List.foldLeft((acc, s) -> acc + String.length(snd(s)), 0);
        let elapsed: Int64 = System.currentTimeMillis() - start;
        match Object.toOption(System.getenv("FLIX_GE_SHADER_DUMP")) {
            case Some(dir) =>
                sources |> List.forEach(s -> write(dir, fst(s), snd(s)));
                println("[shader-dump] ${List.length(sources)} 本・${total} 字・組んだ時間 ${elapsed} ms → ${dir}")
            case None => ()
        };
        Assert.assertEq(expected = 1506, List.length(sources))

    /// GLSL の全部の版が宣言する uniform は、どれも handle の表（Render3d.Uniforms）にある（GL の location を handle で引くため）。
    @Test
    def testEveryGlslUniformIsInTheHandleTable(): Unit \ Assert =
        let glsl = allSources() |> List.filter(s -> String.startsWith(prefix = "glsl/", fst(s))) |> List.map(snd);
        Assert.assertEq(expected = Nil, snd(Render3d.Uniforms.handlesOf(glsl)))
}
