// lightmap を付けない時の 3D の GLSL の字が 1 字も変わらないことを、今の字の SHA-256 で固定する（3D の色の変換 colorSpaceSource と
// 色の組み立て r3d_surfaceOut を含む字）。
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
            |> List.map(k -> { let (uv, nm) = k; sha256(Render3dGlsl.materialFragmentSource(glsl, { skinned = false, uv = uv, normalMap = nm, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) })

    @Test
    def testLightSourceIsUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "90699414cb72c9a2cf2e609545746e7b89e9bf373ed4de4ab1c8775d1617629a", sha256(Render3dGlsl.lightSource()))

    @Test
    def testSolidMaterialFragmentsAreUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "12f61f9e17bee72fc634fce6c3a3c344de0530c905dabc763690ad1f7d94942c" :: "12f61f9e17bee72fc634fce6c3a3c344de0530c905dabc763690ad1f7d94942c" :: "2bd66490fb86bc917dec60d9404400378277e1ed3a5867382ecb2fccd20dd578" :: "d66fbc5c116ee3dd0b3a7af8ed2255cda82d14c1e85bae3bb8700fc3c4e03024" :: Nil, fragments(solidGlsl()))

    @Test
    def testMipMaterialFragmentsAreUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "e281f7dabdeadbc03f33f48c8612067e90da001c6d285aaa1bff9cb17c05b307" :: "e281f7dabdeadbc03f33f48c8612067e90da001c6d285aaa1bff9cb17c05b307" :: "5b641e74b209df0731f3a8dbb151936607ea087dc8676b0da39da54ab3984eaa" :: "7dad972e397e8d8583ba6e2d1c99d20aa743448cf1eb48ef241644a5cf480942" :: Nil, fragments(mipGlsl()))

    @Test
    def testMaterialVertexSourcesAreUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "b0849156f20e2286a70a2ce98f2c7e32bca8c363ce2b89a1ad920cad962266dd" :: "6a48a7e726fcc7cf20600037627e7cd81ddc85fa8444b2416d510b7b425f3c2b" :: "b0ece99f6547ef3115177642db6ffcda482e8c2b56cf6d6cde8d401b9aa5514e" :: "fb100e12ba86de0ad9f71c84e10c4eb69c75a1487b1b2ec8fdb864f365134446" :: Nil,
            ((false, false) :: (true, false) :: (false, true) :: (true, true) :: Nil)
                |> List.map(k -> { let (skinned, uv) = k; sha256(Render3dGlsl.materialVertexSource({ skinned = skinned, uv = uv, lightmap = false })) }))

    // ── lightmap の版 ──

    def count(part: String, s: String): Int32 =
        match String.indexOf(substr = part, s) {
            case None    => 0
            case Some(i) => 1 + count(part, String.dropLeft(i + String.length(part), s))
        }

    /// 材質が sg_texMip を持つ時も、法線マップと lightmap の版で sg_texMip の定義は 1 回だけ。
    @Test
    def testTexMipOnceWhenTheMaterialHasIt(): Unit \ Assert =
        Assert.assertEq(expected = 1, count("vec4 sg_texMip(", Render3dGlsl.materialFragmentSource(mipGlsl(), { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })))

    /// uv の無い形の lightmap の版の頂点シェーダーも、location 7 の 2 本目の uv を vUv2 へ渡す。
    @Test
    def testUvLessLightmapVertexPassesUv2(): Unit \ Assert =
        let source = Render3dGlsl.materialVertexSource({ skinned = false, uv = false, lightmap = true });
        Assert.assertEq(expected = (1, 1), (count("layout (location = 7) in vec2 aUv2;", source), count("vUv2 = aUv2;", source)))

    /// lightmap の版の材質のプログラムの鍵は、lightmap の無い版と分かれる。
    @Test
    def testLightmapKeyDiffers(): Unit \ Assert =
        let m = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("t", ShaderDoc.FilterMode.Linear));
        Assert.assertFalse(Render3d.materialKey(m, { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })
                           == Render3d.materialKey(m, { skinned = false, uv = true, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false }))

    /// lightmap の GLSL の sRGB の式は、Texture3d の 1 か所の関数から組まれる。
    @Test
    def testSrgbGlslComesFromTexture3d(): Unit \ Assert =
        let source = Render3dGlsl.materialFragmentSource(solidGlsl(), { skinned = false, uv = false, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertEq(expected = (1, 1),
            (count(Texture3d.srgbToLinearGlsl("r3d_srgbToLinear"), source), count(Texture3d.linearToSrgbGlsl("r3d_linearToSrgb"), source)))

    // ── 3D の色の変換 ──

    /// lit・材質・ビルボード・空の frag は色の変換の部品（r3d_srgbToLinear3 の定義）を 1 回だけ持つ。
    @Test
    def testFragmentsDeclareColorSpaceOnce(): Unit \ Assert =
        let material = Render3dGlsl.materialFragmentSource(mipGlsl(), { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertEq(expected = 1 :: 1 :: 1 :: 1 :: Nil,
            (Render3dGlsl.litFragmentSource() :: material :: Render3dGlsl.billboardFragmentSource() :: Render3dGlsl.skyFragmentSource() :: Nil)
                |> List.map(count("vec3 r3d_srgbToLinear3(vec3 c)")))

    /// lightmap の版の材質の frag でも、vec3 の変換の関数は 1 回だけ定義される。
    @Test
    def testVec3ConversionDefinedOnce(): Unit \ Assert =
        let source = Render3dGlsl.materialFragmentSource(mipGlsl(), { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertEq(expected = (1, 1), (count("vec3 r3d_srgbToLinear3(vec3 c)", source), count("vec3 r3d_linearToSrgb3(vec3 c)", source)))

    /// 頂点の色を線形へ戻すのは lit の頂点シェーダー（骨なし・骨つき）だけ。
    @Test
    def testOnlyLitVertexSourcesLinearizeVertexColor(): Unit \ Assert =
        let converts = (source: String) -> count("vColor = r3d_srgbToLinear3(aColor);", source);
        Assert.assertEq(expected = (1, 1, 0, 0, 0),
            (converts(Render3dGlsl.litVertexSource(false)), converts(Render3dGlsl.litVertexSource(true)), converts(Render3dGlsl.meshVertexSource()),
             converts(Render3dGlsl.skinnedMeshVertexSource()), converts(Render3dGlsl.materialVertexSource({ skinned = false, uv = false, lightmap = false }))))

    /// 空の frag は空の色を画面の値へ戻してから書く。
    @Test
    def testSkyConvertsToScreenValue(): Unit \ Assert =
        Assert.assertEq(expected = 1, count("fragColor = vec4(r3d_linearToSrgb3(skyAt(d)), 1.0);", Render3dGlsl.skyFragmentSource()))

    /// ビルボードの frag は絵の rgb を線形へ戻して r3d_surfaceOut に渡す。
    @Test
    def testBillboardLinearizesTexel(): Unit \ Assert =
        Assert.assertEq(expected = 1, count("r3d_surfaceOut(r3d_srgbToLinear3(texel.rgb), uTint, light", Render3dGlsl.billboardFragmentSource()))
}
