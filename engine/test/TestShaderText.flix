// ShaderText.isAtomText の形の判定と、ShaderGen の材質の部品の cutout の α がいつも atom であること（ブラウザ版の材質の frag が部品を字のまま入れる約束）。
mod TestShaderText {
    use ShaderDoc.{Field, Shade, Out, TexChan}

    def fill(alpha: Field): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = Nil, out = Out.Fill({ shade = Shade.Solid({ r = 0.1, g = 0.2, b = 0.3 }), alpha = alpha }) }

    def specs(): List[ShaderDoc.Spec] =
        fill(Field.Const(1.0)) :: fill(Field.Param({ name = "a" })) :: fill(Field.Tex({ name = "albedo", chan = TexChan.A })) ::
        fill(Field.VertexColor({ chan = TexChan.R })) :: Nil

    def shades(): List[Option[Shade]] = None :: Some(Shade.Solid({ r = 0.5, g = 0.5, b = 0.0 })) :: Nil

    @Test
    def testCallIsAtom(): Unit \ Assert = Assert.assertTrue(ShaderText.isAtomText("materialCutoutAlpha(vUv, vWorld)"))

    @Test
    def testFieldReadIsAtom(): Unit \ Assert = Assert.assertTrue(ShaderText.isAtomText("albedo.a"))

    @Test
    def testOperatorIsNotAtom(): Unit \ Assert = Assert.assertFalse(ShaderText.isAtomText("albedo.a * 0.5"))

    @Test
    def testEmptyIsNotAtom(): Unit \ Assert = Assert.assertFalse(ShaderText.isAtomText(""))

    @Test
    def testGlslCutoutAlphaIsAlwaysAtom(): Unit \ Assert =
        let alphas = specs() |> List.flatMap(spec -> shades() |> List.flatMap(emission -> shades() |> List.map(metal ->
            ShaderGen.compile3d(spec, emission, metal, false)#cutoutAlpha)));
        Assert.assertEq(expected = Nil, alphas |> List.filter(a -> not ShaderText.isAtomText(a)))

    @Test
    def testWgslCutoutAlphaIsAlwaysAtom(): Unit \ Assert =
        let alphas = specs() |> List.flatMap(spec -> shades() |> List.flatMap(emission -> shades() |> List.map(metal ->
            ShaderGen.Wgsl.compile3d(spec, emission, metal, false, 1)#cutoutAlpha)));
        Assert.assertEq(expected = Nil, alphas |> List.filter(a -> not ShaderText.isAtomText(a)))
}
