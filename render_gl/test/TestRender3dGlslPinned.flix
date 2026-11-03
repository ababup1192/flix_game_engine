// lightmap を付けない時の 3D の GLSL の字が 1 字も変わらないことを、今の字の SHA-256 で固定する。
// 材質の frag は sg_texMip を持たない材質と持つ材質のそれぞれで、uv と法線マップの 4 通り。
mod Render3d.TestGlslPinned {
    import java.security.MessageDigest
    import java.util.HexFormat

    def sha256(text: String): String = unsafe IO {
        HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(String.toBytes(text)))
    }

    def solidGlsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n", functions = "void materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def mipGlsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n", functions = "vec4 sg_texMip(sampler2D t, float f, float l, vec2 uv) { return vec4(0.0); }\nvoid materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def fragments(glsl: ShaderGen.MaterialGlsl): List[String] =
        ((false, false) :: (false, true) :: (true, false) :: (true, true) :: Nil)
            |> List.map(k -> { let (uv, nm) = k; sha256(Render3d.materialFragmentSource(glsl, { skinned = false, uv = uv, normalMap = nm, lightmap = false, blend = false, doubleSided = false, coverage = false })) })

    @Test
    def testLightSourceIsUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "20358d09a52bfbd1c742a020101ce01e949ff05875c2328f1792540326fea041", sha256(Render3d.lightSource()))

    @Test
    def testSolidMaterialFragmentsAreUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "51799671d78a9df65c086fcf0be5ba11d3b31b698fe6226542fee10a3f1ebd27" :: "51799671d78a9df65c086fcf0be5ba11d3b31b698fe6226542fee10a3f1ebd27" :: "3673b42bd23e178e82f03c9e6f991700a5f331a7ad5bab18777b15079de43f9a" :: "dd685b606855d4fcb4e2b286596e142725fca09ab791055fc80974564d2d6442" :: Nil, fragments(solidGlsl()))

    @Test
    def testMipMaterialFragmentsAreUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "640831acd79a35766b30e1da685a98db3e39cc9cb068321cd481e97253da1c1c" :: "640831acd79a35766b30e1da685a98db3e39cc9cb068321cd481e97253da1c1c" :: "6e2401df4a8985d4157a8c2c7a029db1feef5620f6cc08eab22235d95f596f5b" :: "9a83bdb8664ba810cc1aca2886865816581de73cda36fa07b37e8aaf03c764c3" :: Nil, fragments(mipGlsl()))

    @Test
    def testMaterialVertexSourcesAreUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "a5a28ff25b65c8f6ffdfc85e52c79f70310fd9835d0d36210a0329df4cc3adca" :: "c441d0e276dc7aa5856de8919b70095ef7732b79b2ff8b051c7cd2d726fb4df5" :: "394f4f81d4b8544c79cc32faf02bc11446e005a511184afc383c81b4286012cf" :: "fdbc4f8adbe60381c4b0f6a3a10df874d970d320e134313b7a77feeb58f2ed19" :: Nil,
            ((false, false) :: (true, false) :: (false, true) :: (true, true) :: Nil)
                |> List.map(k -> { let (skinned, uv) = k; sha256(Render3d.materialVertexSource({ skinned = skinned, uv = uv, lightmap = false })) }))

    // ── lightmap の版 ──

    def count(part: String, s: String): Int32 =
        match String.indexOf(substr = part, s) {
            case None    => 0
            case Some(i) => 1 + count(part, String.dropLeft(i + String.length(part), s))
        }

    /// 材質が sg_texMip を持つ時も、法線マップと lightmap の版で sg_texMip の定義は 1 回だけ。
    @Test
    def testTexMipOnceWhenTheMaterialHasIt(): Unit \ Assert =
        Assert.assertEq(expected = 1, count("vec4 sg_texMip(", Render3d.materialFragmentSource(mipGlsl(), { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false })))

    /// uv の無い形の lightmap の版の頂点シェーダーも、location 7 の 2 本目の uv を vUv2 へ渡す。
    @Test
    def testUvLessLightmapVertexPassesUv2(): Unit \ Assert =
        let source = Render3d.materialVertexSource({ skinned = false, uv = false, lightmap = true });
        Assert.assertEq(expected = (1, 1), (count("layout (location = 7) in vec2 aUv2;", source), count("vUv2 = aUv2;", source)))

    /// lightmap の版の材質のプログラムの鍵は、lightmap の無い版と分かれる。
    @Test
    def testLightmapKeyDiffers(): Unit \ Assert =
        let m = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("t", ShaderDoc.FilterMode.Linear));
        Assert.assertFalse(Render3d.materialKey(m, { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })
                           == Render3d.materialKey(m, { skinned = false, uv = true, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false }))

    /// lightmap の GLSL の sRGB の式は、Texture3d の 1 か所の関数から組まれる。
    @Test
    def testSrgbGlslComesFromTexture3d(): Unit \ Assert =
        let source = Render3d.materialFragmentSource(solidGlsl(), { skinned = false, uv = false, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false });
        Assert.assertEq(expected = (1, 1),
            (count(Texture3d.srgbToLinearGlsl("r3d_srgbToLinear"), source), count(Texture3d.linearToSrgbGlsl("r3d_linearToSrgb"), source)))
}
