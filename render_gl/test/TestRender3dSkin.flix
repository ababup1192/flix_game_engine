// Render3d の骨つきの頂点シェーダーの約束（位置と法線を joint 行列の重みつきの和で曲げてから world を掛ける・
// ジョイントの番号は整数の属性・joint 行列は texelFetch で joint texture から読む）を固定するテスト。GL は呼ばず、GLSL の字だけを見る。

mod TestRender3dSkin {

    def indexOf(part: String, s: String): Int32 =
        String.indexOf(substr = part, s) |> Option.getWithDefault(-1)

    /// 骨の無い版は joint texture を宣言しない。
    @Test
    def testPlainSourceHasNoJointTexture(): Unit \ Assert =
        Assert.assertEq(expected = -1, indexOf("uJointTexture", Render3dGlsl.meshVertexSource()))

    /// 骨の無い版の位置は形の座標にそのまま uModel を掛ける。
    @Test
    def testPlainPositionIsModelTimesPos(): Unit \ Assert =
        Assert.assertTrue(indexOf("vec4 world = uModel * vec4(aPos, 1.0);", Render3dGlsl.meshVertexSource()) >= 0)

    /// 骨つきの版は joint 行列を uPoseRow の行の 4 texel（joint × 4 から）を列にした mat4 として読む。
    @Test
    def testSkinnedReadsJointMatrixFromTexels(): Unit \ Assert =
        Assert.assertTrue(indexOf("texelFetch(uJointTexture, ivec2(x + 3, uPoseRow), 0)", Render3dGlsl.skinnedMeshVertexSource()) >= 0)

    /// ジョイントの番号は整数の属性（location 3）。
    @Test
    def testJointIndicesAreIntegerAttribute(): Unit \ Assert =
        Assert.assertTrue(indexOf("layout (location = 3) in ivec4 aJoints;", Render3dGlsl.skinnedMeshVertexSource()) >= 0)

    /// 骨つきの位置は skin で曲げてから uModel を掛ける。
    @Test
    def testSkinnedPositionBentBeforeModel(): Unit \ Assert =
        Assert.assertTrue(indexOf("vec4 world = uModel * skin * vec4(aPos, 1.0);", Render3dGlsl.skinnedMeshVertexSource()) >= 0)

    /// 骨つきの法線は skin の左上 3×3 で曲げてから uNormal を掛ける。
    @Test
    def testSkinnedNormalBentBeforeNormalMatrix(): Unit \ Assert =
        Assert.assertTrue(indexOf("vNormal = (uNormal * vec4(mat3(skin) * aNormal, 0.0)).xyz;", Render3dGlsl.skinnedMeshVertexSource()) >= 0)

    /// skin は 4 つの重みと 4 つのジョイントの番号の組の和。
    @Test
    def testSkinSumsFourWeightedJoints(): Unit \ Assert =
        Assert.assertTrue(indexOf("aWeights.w * jointMatrix(aJoints.w)", Render3dGlsl.skinnedMeshVertexSource()) >= 0)

}
