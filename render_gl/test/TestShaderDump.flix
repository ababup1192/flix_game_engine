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
        flags() |> List.flatMap(ao -> flags() |> List.flatMap(ps -> flags() |> List.flatMap(pu -> flags() |> List.flatMap(psx -> flags() |> List.map(sh ->
            { pointShadows = ps, physicalUnits = pu, psx = psx, skyIrradiance = sh, ambientOcclusion = ao })))))

    def variantLabel(v: Render3d.ProgramKey.ShaderVariant): String =
        let bit = (b: Bool, ch: String) -> if (b) ch else "-";
        bit(v#pointShadows, "s") + bit(v#physicalUnits, "p") + bit(v#psx, "x") + bit(v#skyIrradiance, "h") + (if (v#ambientOcclusion) "a" else "")

    /// 材質の frag の字を変える ProgramKind の正しい組（skinned は頂点だけ・法線マップは uv つきの時だけ）。変種は v。
    def surfaceKinds(v: Render3d.ProgramKey.ShaderVariant): List[Render3d.ProgramKey.ProgramKind] =
        let surfaces = (false, false) :: (true, false) :: (true, true) :: Nil;
        surfaces |> List.flatMap(un -> {
            let (uv, normalMap) = un;
            flags() |> List.flatMap(lightmap -> flags() |> List.flatMap(blend -> flags() |> List.flatMap(doubleSided ->
                flags() |> List.flatMap(coverage -> flags() |> List.map(metallic ->
                    { skinned = false, uv = uv, normalMap = normalMap, lightmap = lightmap, blend = blend, doubleSided = doubleSided,
                      coverage = coverage, metallicRoughness = metallic, variant = { pointShadows = v#pointShadows, physicalUnits = v#physicalUnits, psx = v#psx, skyIrradiance = v#skyIrradiance, ambientOcclusion = v#ambientOcclusion } })))))
        })

    def kindLabel(k: Render3d.ProgramKey.ProgramKind): String =
        let bit = (b: Bool, ch: String) -> if (b) ch else "-";
        bit(k#uv, "u") + bit(k#normalMap, "n") + bit(k#lightmap, "l") + bit(k#blend, "b") + bit(k#doubleSided, "d") + bit(k#coverage, "c")
            + bit(k#metallicRoughness, "m") + "_" + variantLabel(k#variant)

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
        ("glsl/vertex-sky.vert", Render3dGlsl.skyVertexSource()) ::
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
        Assert.assertEq(expected = 2627, List.length(sources))

    /// vertex と frag の入口の全部の組（ビルボードの変種と横の向き・影の地図の frag・空・blit）で、frag が受ける varying が vertex の表に同じ形であり、location が重ならない。
    @Test
    def testEveryStagePairLinks(): Unit \ Assert =
        let rights = Render3dShaders.BillboardRight.Camera :: Render3dShaders.BillboardRight.PerBillboard :: Render3dShaders.BillboardRight.ByUniform :: Nil;
        let billboards = allVariants() |> List.flatMap(v -> rights |> List.flatMap(r -> {
            let vertex = Render3dShaders.billboardVertex(v, r, Nil);
            (vertex, Render3dShaders.billboardFragment(v, Nil)) :: (vertex, Render3dShaders.billboardShadowFragment(Nil)) :: Nil
        }));
        let pairs = billboards ::: (Render3dShaders.skyVertex(), Render3dShaders.skyFragment(Nil)) :: (Render3dShaders.blitVertex(), Render3dShaders.blitFragment()) :: Nil;
        Assert.assertEq(expected = Nil, pairs |> List.flatMap(vf -> ShaderAst.linkErrors(fst(vf), snd(vf))))

    /// 手書きの頂点（MeshVertex）の (GLSL の字, WGSL の字) と、つなぐ frag の入口の inputs の組（材質は skinned・uv と法線マップ・lightmap の正しい組 × psx・
    /// 頂点の色・奥行き）。骨つきの版は lightmap を付けない。
    def meshStagePairs(): List[(String, String, List[ShaderAst.Varying])] =
        let surfaces = (false, false) :: (true, false) :: (true, true) :: Nil;
        let d = Render3d.ProgramKey.defaultShaderVariant();
        flags() |> List.flatMap(psx -> {
            let v = { pointShadows = d#pointShadows, physicalUnits = d#physicalUnits, psx = psx, skyIrradiance = d#skyIrradiance, ambientOcclusion = d#ambientOcclusion };
            let materials = flags() |> List.flatMap(skinned -> surfaces |> List.flatMap(un -> {
                let (uv, normalMap) = un;
                (if (skinned) false :: Nil else flags()) |> List.map(lightmap -> {
                    let k = { skinned = skinned, uv = uv, normalMap = normalMap, lightmap = lightmap, blend = false, doubleSided = false,
                              coverage = false, metallicRoughness = false, variant = v };
                    (Render3dGlsl.materialVertexSourceFor({ skinned = skinned, uv = uv, lightmap = lightmap }, psx),
                     Render3dWgsl.materialVertexSourceFor(uv, lightmap, skinned, psx), Render3dShaders.materialInputs(k))
                })
            }));
            let lits = flags() |> List.map(skinned ->
                (Render3dGlsl.litVertexSourceFor(skinned, v), Render3dWgsl.litVertexSourceFor(skinned, psx), Render3dShaders.litInputs()));
            let depth = materials |> List.map(t -> { let (glsl, wgsl, _) = t; (glsl, wgsl, Render3dShaders.depthFragment(Nil)#inputs) });
            materials ::: lits ::: depth
        })

    /// 字 text の行（頭と尾の空白を除く）。
    def trimmedLines(text: String): Set[String] = TextSplit.lines(text) |> List.map(String.trim) |> List.toSet

    /// varying v を受けるために GLSL の頂点が書く out の行（Affine は w を足した vec3 で送る）。
    def glslOutLine(v: ShaderAst.Varying): String =
        let ty = if (v#interp == ShaderAst.Interp.Affine) ShaderAst.Ty.Vec3 else v#ty;
        (if (v#interp == ShaderAst.Interp.Flat) "flat " else "") + "out " + ShaderAst.Glsl.tyName(ty) + " " + v#name + ";"

    def wgslInterpolate(i: ShaderAst.Interp): String = match i {
        case ShaderAst.Interp.Flat   => " @interpolate(flat)"
        case ShaderAst.Interp.Affine => " @interpolate(linear)"
        case _                       => ""
    }

    /// varying v を受けるために WGSL の頂点の struct に要る欄の、名前を除いた形（@location(n) [@interpolate(..)] 型,）。
    def wgslSlotOf(v: ShaderAst.Varying): String =
        "@location(${v#location})" + wgslInterpolate(v#interp) + " " + ShaderAst.Wgsl.tyName(v#ty) + ","

    /// WGSL の struct の欄の行 line（@location(n) [@interpolate(..)] 名前: 型,）の、名前を除いた形。
    def wgslSlotOfLine(line: String): Option[String] = match TextSplit.split(": ", line) {
        case head :: ty :: Nil if String.startsWith(prefix = "@location(", head) =>
            let tokens = TextSplit.split(" ", head);
            Some(String.intercalate(" ", List.take(List.length(tokens) - 1, tokens)) + " " + ty)
        case _ => None
    }

    /// WGSL の字 text の、名前が Out で終わる struct の中の行（頭と尾の空白を除く。属性の struct の location と混ぜない）。
    def outStructLines(text: String): List[String] =
        let step = (acc: (Bool, List[String]), line: String) -> {
            let (inside, found) = acc;
            if (String.startsWith(prefix = "struct ", line) and String.endsWith(suffix = "Out {", line)) (true, found)
            else if (inside and line == "};") (false, found)
            else if (inside) (true, line :: found)
            else acc
        };
        snd(TextSplit.lines(text) |> List.map(String.trim) |> List.foldLeft(step, (false, Nil)))

    /// 手書きの GLSL の頂点は、つなぐ frag の inputs の全部を同じ名前・型・flat で out に書く（GLSL は名前でつなぐ）。
    @Test
    def testGlslMeshVertexWritesEveryFragmentInput(): Unit \ Assert =
        let missing = meshStagePairs() |> List.flatMap(t -> {
            let (glsl, _, inputs) = t;
            let lines = trimmedLines(glsl);
            inputs |> List.map(glslOutLine) |> List.filter(l -> not Set.memberOf(l, lines))
        });
        Assert.assertEq(expected = Nil, List.distinct(missing))

    /// 手書きの WGSL の頂点の出口の struct は、つなぐ frag の inputs の全部を同じ location・補間・型で持つ。
    // WhyNot: 名前までは照らさない — WGSL は location でつなぎ、psx の uv つきの頂点は location 5 を vUv と呼ぶ（frag は vUvPerspective）。
    @Test
    def testWgslMeshVertexWritesEveryFragmentInput(): Unit \ Assert =
        let missing = meshStagePairs() |> List.flatMap(t -> {
            let (_, wgsl, inputs) = t;
            let slots = outStructLines(wgsl) |> List.filterMap(wgslSlotOfLine) |> List.toSet;
            inputs |> List.filter(v -> not Set.memberOf(wgslSlotOf(v), slots)) |> List.map(v -> v#name + " " + wgslSlotOf(v))
        });
        Assert.assertEq(expected = Nil, List.distinct(missing))

    /// GLSL の全部の版が宣言する uniform は、どれも handle の表（Render3d.Uniforms）にある（GL の location を handle で引くため）。
    @Test
    def testEveryGlslUniformIsInTheHandleTable(): Unit \ Assert =
        let glsl = allSources() |> List.filter(s -> String.startsWith(prefix = "glsl/", fst(s))) |> List.map(snd);
        Assert.assertEq(expected = Nil, snd(Render3d.Uniforms.handlesOf(glsl)))

    /// 字 text の、英数字と _ と . の続き（r3d.uEye のような欄の読みを 1 つに数える）。
    def tokensOf(text: String): List[String] =
        let isPart = (c: Char) -> Char.isLetter(c) or Char.isDigit(c) or c == '_' or c == '.';
        let (done, word) = String.foldLeft((acc, c) -> {
            let (found, current) = acc;
            if (isPart(c)) (found, current + Char.toString(c))
            else if (String.isEmpty(current)) acc
            else (current :: found, "")
        }, (Nil, ""), text);
        (if (String.isEmpty(word)) done else word :: done) |> List.distinct

    /// LightModel3d の生成物の本文（全部の変種の光の式・lightmap の光・PBR・かすみ・跳ね返りの向き・空・点光源の影）を言語 lang で。
    def generatedBodies(print: ShaderAst.Definition -> String): List[String] =
        let spot = Render3dShaders.spotShadow();
        let perVariant = allVariants() |> List.flatMap(v ->
            Render3dShaders.lightAt(v, spot) :: Render3dShaders.lightmapLightAt(v, spot) :: Render3dShaders.pbrAt(v, spot) :: Nil);
        (perVariant ::: Render3dShaders.fogAt() :: Render3dShaders.environmentDirectionAt() :: Render3dShaders.skyAt() :: Render3dShaders.pointShadowLit() :: Nil)
            |> List.map(print)

    /// LightModel3d.Codegen の生成物の中の uniform の名前（GLSL の u で始まる名前・WGSL の r3d・r3dLight・r3dDraw の欄）は、どれも handle の表にある。
    @Test
    def testCodegenUniformNamesAreInTheHandleTable(): Unit \ Assert =
        let table = Render3d.Uniforms.nameTable();
        let wgslNames = Render3d.Uniforms.namedRefs() |> List.filterMap(u -> u#wgsl |> Option.map(a -> a#base)) |> List.toSet;
        let isUniformName = (n: String) -> String.length(n) > 1 and String.startsWith(prefix = "u", n) and Char.isUpperCase(String.charAt(1, n));
        let glslUnknown = generatedBodies(ShaderAst.Glsl.definition) |> List.flatMap(tokensOf)
            |> List.filterMap(t -> List.head(TextSplit.split(".", t))) |> List.filter(isUniformName)
            |> List.filter(n -> Option.isEmpty(Render3d.Uniforms.handleIn(table, n)));
        let fieldOf = (t: String) -> match TextSplit.split(".", t) {
            case owner :: field :: _ if owner == "r3d" or owner == "r3dLight" or owner == "r3dDraw" => Some(owner + "." + field)
            case _ => None
        };
        let wgslUnknown = generatedBodies(ShaderAst.Wgsl.definition) |> List.flatMap(tokensOf) |> List.filterMap(fieldOf)
            |> List.filter(n -> not Set.memberOf(n, wgslNames));
        Assert.assertEq(expected = Nil, List.distinct(glslUnknown ::: wgslUnknown))

    def fieldNames(fields: List[Render3d.UniformLayout.Field[f]]): Set[String] = fields |> List.map(fd -> { let (_, n, _) = fd; n }) |> List.toSet

    /// handle の表の、場面の値（r3d）と光の値（r3dLight）の欄の名前は、どれも UniformLayout の sceneFields・lightFields にある。
    @Test
    def testHandleTableWgslFieldsAreInTheLayout(): Unit \ Assert =
        let scene = fieldNames(Render3d.UniformLayout.sceneFields());
        let light = fieldNames(Render3d.UniformLayout.lightFields());
        let missing = Render3d.Uniforms.namedRefs() |> List.filterMap(u -> u#wgsl) |> List.filterMap(a -> match TextSplit.split(".", a#base) {
            case "r3d" :: field :: Nil      => if (Set.memberOf(field, scene)) None else Some(a#base)
            case "r3dLight" :: field :: Nil => if (Set.memberOf(field, light)) None else Some(a#base)
            case _                          => None
        });
        Assert.assertEq(expected = Nil, missing)

    /// 番号つきの uniform は表の番号の上限を超えても名前から handle を引く（uParam40）。
    @Test
    def testNumberedUniformBeyondTheTableIsFound(): Unit \ Assert =
        Assert.assertTrue(Render3d.Uniforms.handleIn(Render3d.Uniforms.nameTable(), "uParam40") == Some(Render3d.Uniforms.R3dUniform.Param(40)))

    /// 番号つきの名前は長い頭から読む（uTexLevels3 は uTex の 3 でない）。
    @Test
    def testNumberedUniformReadsTheLongestPrefix(): Unit \ Assert =
        Assert.assertTrue(Render3d.Uniforms.handleIn(Render3d.Uniforms.nameTable(), "uTexLevels3") == Some(Render3d.Uniforms.R3dUniform.TexLevels(3)))

    /// 頭の後が数字でない名前は表に無い（uTexture）。
    @Test
    def testPrefixWithoutNumberIsNotFound(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(Render3d.Uniforms.handleIn(Render3d.Uniforms.nameTable(), "uTexture")))
}
