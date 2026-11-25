// デスクトップの GL では通るが GLSL ES 3.00（WebGL2）では予約語でコンパイルが落ちる語が、render_gl の組み立てる GLSL のどの版にも入っていないこと。
// 版は ShaderVariant（点の影・物理の明るさ・PS1 風）と ProgramKind の全部の組み合わせ・2D のシェーダー・空と blit。
mod Render3d.TestGlslEsKeywords {
    import java.util.regex.Pattern

    /// GLSL ES 3.00 の仕様の「予約語」（将来のための予約）の節から、デスクトップの GLSL（330 以上・ドライバが緩い時を含む）では使える語。
    def esReserved(): List[String] = List#{
        "noperspective", "sample", "patch", "subroutine",
        "attribute", "varying",
        "double", "dvec2", "dvec3", "dvec4", "dmat2", "dmat3", "dmat4",
        "coherent", "volatile", "restrict", "readonly", "writeonly", "atomic_uint",
        "sampler1D", "sampler1DShadow", "sampler1DArray", "sampler1DArrayShadow", "isampler1D", "isampler1DArray", "usampler1D", "usampler1DArray",
        "sampler2DRect", "sampler2DRectShadow", "isampler2DRect", "usampler2DRect",
        "samplerBuffer", "isamplerBuffer", "usamplerBuffer",
        "sampler2DMS", "isampler2DMS", "usampler2DMS", "sampler2DMSArray", "isampler2DMSArray", "usampler2DMSArray",
        "image1D", "image2D", "image3D", "imageCube", "imageBuffer"
    }

    /// source の中で esReserved() の語に丸ごと当たる所（識別子の一部は数えない）。
    def reservedWordsIn(pattern: Pattern, source: String): List[String] = unsafe IO {
        let m = pattern.matcher(source);
        def loop(acc) = if (m.find()) loop(m.group() :: acc) else List.reverse(acc);
        loop(Nil)
    }

    def bools(): List[Bool] = true :: false :: Nil

    def flagsName(flags: List[(String, Bool)]): String =
        flags |> List.filter(snd) |> List.map(fst) |> List.join("+")

    def variantName(v: Render3d.ShaderVariant): String =
        "[" + flagsName(("pointShadows", v#pointShadows) :: ("physicalUnits", v#physicalUnits) :: ("psx", v#psx) :: Nil) + "]"

    def kindName(k: Render3d.ProgramKind): String =
        "[" + flagsName(("skinned", k#skinned) :: ("uv", k#uv) :: ("normalMap", k#normalMap) :: ("lightmap", k#lightmap) :: ("blend", k#blend) ::
                        ("doubleSided", k#doubleSided) :: ("coverage", k#coverage) :: ("metallicRoughness", k#metallicRoughness) ::
                        ("pointShadows", k#pointShadows) :: ("physicalUnits", k#physicalUnits) :: ("psx", k#psx) :: Nil) + "]"

    def variants(): List[Render3d.ShaderVariant] =
        List.flatMap(ps -> List.flatMap(pu -> List.map(px -> { pointShadows = ps, physicalUnits = pu, psx = px }, bools()), bools()), bools())

    def kindsOf(v: Render3d.ShaderVariant): List[Render3d.ProgramKind] =
        List.flatMap(sk -> List.flatMap(uv -> List.flatMap(nm -> List.flatMap(lm -> List.flatMap(bl -> List.flatMap(ds -> List.flatMap(cv -> List.map(mr ->
            { skinned = sk, uv = uv, normalMap = nm, lightmap = lm, blend = bl, doubleSided = ds, coverage = cv, metallicRoughness = mr,
              pointShadows = v#pointShadows, physicalUnits = v#physicalUnits, psx = v#psx },
            bools()), bools()), bools()), bools()), bools()), bools()), bools()), bools())

    def solidGlsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n", functions = "void materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def sources(): List[(String, String)] =
        let fixed =
            ("meshVertex", Render3dGlsl.meshVertexSource()) ::
            ("skinnedMeshVertex", Render3dGlsl.skinnedMeshVertexSource()) ::
            ("depthFragment", Render3dGlsl.depthFragmentSource()) ::
            ("skyFragment", Render3dGlsl.skyFragmentSource()) ::
            ("blitVertex", Render3dGlsl.blitVertexSource()) ::
            ("blitFragment", Render3dGlsl.blitFragmentSource()) ::
            ("tileVertex", RenderShader.tileVertexShaderSource()) ::
            ("tileFragment", RenderShader.tileFragmentShaderSource()) ::
            ("spriteInstancedVertex", RenderShader.spriteInstancedVertexShaderSource()) ::
            ("spriteInstancedFragment", RenderShader.spriteInstancedFragmentShaderSource()) ::
            ("polyBatchVertex", RenderShader.polyBatchVertexShaderSource()) ::
            ("polyBatchFragment", RenderShader.polyBatchFragmentShaderSource()) ::
            ("fallbackFragment", RenderShader.fallbackFragmentSource()) :: Nil;
        let perVariant = variants() |> List.flatMap(v ->
            ("litVertex ${variantName(v)}", Render3dGlsl.litVertexSourceFor(false, v)) ::
            ("litVertex skinned ${variantName(v)}", Render3dGlsl.litVertexSourceFor(true, v)) ::
            ("litFragment ${variantName(v)}", Render3dGlsl.litFragmentSourceFor(v)) ::
            ("billboardVertex ${variantName(v)}", Render3dGlsl.billboardVertexSourceFor(v)) ::
            ("billboardFragment ${variantName(v)}", Render3dGlsl.billboardFragmentSourceFor(v)) :: Nil);
        let materialVertex = bools() |> List.flatMap(sk -> bools() |> List.flatMap(uv -> bools() |> List.flatMap(lm -> bools() |> List.map(px ->
            ("materialVertex skinned=${sk} uv=${uv} lightmap=${lm} psx=${px}", Render3dGlsl.materialVertexSourceFor({ skinned = sk, uv = uv, lightmap = lm }, px))))));
        let materialFragment = variants() |> List.flatMap(kindsOf) |> List.map(k ->
            ("materialFragment ${kindName(k)}", Render3dGlsl.materialFragmentSource(solidGlsl(), k)));
        fixed ::: perVariant ::: materialVertex ::: materialFragment

    @Test
    def testNoShaderUsesWordsReservedInGlslEs300(): Unit \ Assert =
        let pattern = Pattern.compile("\\b(" + String.intercalate("|", esReserved()) + ")\\b");
        let found = sources() |> List.flatMap(entry -> {
            let (name, source) = entry;
            reservedWordsIn(pattern, source) |> List.distinct |> List.map(w -> "${name}: ${w}")
        });
        Assert.assertEq(expected = Nil, List.take(10, found))
}
