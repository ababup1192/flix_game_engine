// ブラウザ版のシェーダーの記録（web/shader-variants.json）が、描き出しの全部の場面と各階の 3D の場面で使う鍵を全部持つこと。
// 漏れると、その場面の物がブラウザで描かれない（書き出しは記録の分だけシェーダーの字を作る）。
// 環境変数 FLIX_GE_SHADER_VARIANTS（記録の道）があれば、足りない鍵を記録へ書き足してから比べる。
mod TestShaderVariants {
    use fge::ShaderVariants

    @Test
    def testRecordCoversEveryShotAndFloor(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, ShaderVariants.missingFrom("web/shader-variants.json", SceneRender.shaderScenes()))
}
