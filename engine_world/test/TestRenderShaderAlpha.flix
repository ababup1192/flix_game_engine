// TestRenderShaderAlpha — シェーダー面の濃さ（Item.Shader の alpha）: fade が面に効き、
// GL の無い道（shaderSurfaces）へは場の alpha への掛け算として畳まれる。濃さ 1.0 の面の Spec は元のまま。

mod TestRenderShaderAlpha {

    def spec(): ShaderDoc.Spec =
        { name = "fill", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 1.0 }), alpha = ShaderDoc.Field.Const(0.8) }) }

    def surface(): Render.PlacedItem =
        Render.shaderFill(spec(), { position = Vec2.zero(), size = { x = 8.0, y = 8.0 } }, 0.0, 0)

    def alphaOf(placed: Render.PlacedItem): Option[Float64] = match placed#item {
        case Render.Item.Shader(s) => Some(s#alpha)
        case _                     => None
    }

    @Test
    def testFadeSetsSurfaceAlpha(): Unit \ Assert =
        Assert.assertEq(expected = Some(0.5), alphaOf(Render.overItem(Render.fade(0.5), surface())))

    @Test
    def testFullAlphaKeepsSpecForCpuPath(): Unit \ Assert =
        let kept = Render.shaderSurfaces(surface() :: Nil) |> List.head |> Option.map(s -> ShaderGen.eqSpec(spec(), s#spec));
        Assert.assertEq(expected = Some(true), kept)

    @Test
    def testFadedSurfaceFoldsIntoFieldAlpha(): Unit \ Assert =
        let wanted = { out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 1.0 }),
            alpha = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = ShaderDoc.Field.Const(0.8), b = ShaderDoc.Field.Const(0.5) }) }) | spec() };
        let folded = Render.shaderSurfaces(Render.overItem(Render.fade(0.5), surface()) :: Nil) |> List.head
            |> Option.map(s -> ShaderGen.eqSpec(wanted, s#spec));
        Assert.assertEq(expected = Some(true), folded)
}
