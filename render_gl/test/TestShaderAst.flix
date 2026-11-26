// ShaderAst の 2 つの printer と、定義を集める所・一様さの検査。
mod TestShaderAst {
    import java.lang.Throwable
    import java.lang.System
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    use ShaderAst.{Expr, Float, Vec3, Body, Layout}
    use ShaderAst.{f, i, add, sub, mul, mulS, lt, gt, eq, or_, ternary, paren, x, ref, let_, var_, assign, ifInline, ifBlock, for_, ret, param, call, arg,
                   function, externFunction, constArray, at, uniform, clampS, fwidth, incr}

    def v3(name: String): Expr[Vec3] = ref(ShaderAst.Vec3.Vec3, name)

    def s(name: String): Expr[Float] = ref(ShaderAst.Float.Float, name)

    def glsl(e: Expr[t]): String = ShaderAst.Glsl.expression(e)

    def wgsl(e: Expr[t]): String = ShaderAst.Wgsl.expression(e)

    // ── 式 ──

    @Test
    def testLowerPrecedenceChildGetsParentheses(): Unit \ Assert =
        Assert.assertEq(expected = "(a + b) * c", glsl(mul(add(s("a"), s("b")), s("c"))))

    @Test
    def testLeftAssociativeChainHasNoParentheses(): Unit \ Assert =
        Assert.assertEq(expected = "a - b - c", glsl(sub(sub(s("a"), s("b")), s("c"))))

    @Test
    def testRightNestedSameOperatorKeepsParentheses(): Unit \ Assert =
        Assert.assertEq(expected = "a - (b - c)", glsl(sub(s("a"), sub(s("b"), s("c")))))

    @Test
    def testExplicitParenIsKept(): Unit \ Assert =
        Assert.assertEq(expected = "(a < b) ? a : b", glsl(ternary(paren(lt(s("a"), s("b"))), s("a"), s("b"))))

    @Test
    def testTernaryIsSelectInWgsl(): Unit \ Assert =
        Assert.assertEq(expected = "select(b, a, a < b)", wgsl(ternary(lt(s("a"), s("b")), s("a"), s("b"))))

    @Test
    def testGlslVectorConstructorName(): Unit \ Assert =
        Assert.assertEq(expected = "vec3(a, a, a)", glsl(ShaderAst.vec3Of(s("a"), s("a"), s("a"))))

    @Test
    def testWgslVectorConstructorName(): Unit \ Assert =
        Assert.assertEq(expected = "vec3f(a, a, a)", wgsl(ShaderAst.vec3Of(s("a"), s("a"), s("a"))))

    @Test
    def testDoubleNegationIsParenthesized(): Unit \ Assert =
        Assert.assertEq(expected = "-(-a)", glsl(ShaderAst.neg(ShaderAst.neg(s("a")))))

    @Test
    def testNegatedNegativeLiteralIsParenthesized(): Unit \ Assert =
        Assert.assertEq(expected = "-(-1.0)", wgsl(ShaderAst.neg(f("-1.0"))))

    @Test
    def testWgslClampSplatsScalarBounds(): Unit \ Assert =
        Assert.assertEq(expected = "clamp(c, vec3f(0.0), vec3f(1.0))", wgsl(clampS(v3("c"), f("0.0"), f("1.0"))))

    @Test
    def testWgslBitAndWrapsBinaryOperands(): Unit \ Assert =
        Assert.assertEq(expected = "(a + b) & c", wgsl(ShaderAst.bitAnd(add(ref(ShaderAst.Int.Int, "a"), ref(ShaderAst.Int.Int, "b")), ref(ShaderAst.Int.Int, "c"))))

    @Test
    def testWgslMixedLogicalOperatorsGetParentheses(): Unit \ Assert =
        Assert.assertEq(expected = "a > b || (a < b && a == b)",
            wgsl(or_(gt(s("a"), s("b")), ShaderAst.and_(lt(s("a"), s("b")), eq(s("a"), s("b"))))))

    def snapUniform(): Expr[ShaderAst.Vec2] =
        uniform(ShaderAst.Vec2.Vec2, { name = "uSize", ty = ShaderAst.Ty.Vec2, glsl = Some({ base = "uTarget", swizzle = "zw" }), wgsl = Some({ base = "cam.uSnap", swizzle = "xy" }), glslType = "vec4", length = None })

    @Test
    def testUniformSwizzleComposesInGlsl(): Unit \ Assert =
        Assert.assertEq(expected = "uTarget.w", glsl(ShaderAst.y(snapUniform())))

    @Test
    def testUniformSwizzleComposesInWgsl(): Unit \ Assert =
        Assert.assertEq(expected = "cam.uSnap.y", wgsl(ShaderAst.y(snapUniform())))

    // ── 文と定義 ──

    def fogLike(): ShaderAst.Definition =
        let (pc, c) = param(ShaderAst.Vec3.Vec3, "c");
        let (pb, on) = param(ShaderAst.Boolean.Boolean, "on");
        let (declV, v) = var_("v", c);
        function("tint", ShaderAst.Ty.Vec3, pc :: pb :: Nil, declV :: ifInline(on, assign(v, mulS(v, f("0.5")))) :: ret(v) :: Nil)

    @Test
    def testGlslFunctionUsesTypedDeclarationAndInlineIf(): Unit \ Assert =
        Assert.assertEq(expected = "vec3 tint(vec3 c, bool on) {\n    vec3 v = c;\n    if (on) v = v * 0.5;\n    return v;\n}\n",
            ShaderAst.Glsl.print(fogLike() :: Nil))

    @Test
    def testWgslFunctionUsesVarAndBracedIf(): Unit \ Assert =
        Assert.assertEq(expected = "fn tint(c: vec3f, on: bool) -> vec3f {\n    var v = c;\n    if (on) { v = v * 0.5; }\n    return v;\n}\n",
            ShaderAst.Wgsl.print(fogLike() :: Nil))

    def counting(): ShaderAst.Definition =
        let (pn, n) = param(ShaderAst.Int.Int, "n");
        let (declT, total) = var_("total", i(0));
        function("count", ShaderAst.Ty.I32, pn :: Nil,
            declT :: for_("k", i(0), k -> lt(k, n), Layout.Block, _ -> incr(total) :: Nil) :: ret(total) :: Nil)

    @Test
    def testGlslForBlock(): Unit \ Assert =
        Assert.assertEq(expected = "int count(int n) {\n    int total = 0;\n    for (int k = 0; k < n; k++) {\n        total++;\n    }\n    return total;\n}\n",
            ShaderAst.Glsl.print(counting() :: Nil))

    @Test
    def testWgslForBlock(): Unit \ Assert =
        Assert.assertEq(expected = "fn count(n: i32) -> i32 {\n    var total = 0;\n    for (var k = 0; k < n; k++) {\n        total++;\n    }\n    return total;\n}\n",
            ShaderAst.Wgsl.print(counting() :: Nil))

    def table(): ShaderAst.Definition = constArray({ name = "tbl", elem = ShaderAst.Ty.F32, values = "1.0" :: "2.0" :: Nil })

    def readsTable(): ShaderAst.Definition =
        let (pi, k) = param(ShaderAst.Int.Int, "k");
        function("pick", ShaderAst.Ty.F32, pi :: Nil, ret(at(table(), k)) :: Nil)

    @Test
    def testGlslConstArrayIsGlobalBeforeUser(): Unit \ Assert =
        Assert.assertEq(expected = "const float tbl[2] = float[2](1.0, 2.0);\nfloat pick(int k) {\n    return tbl[k];\n}\n",
            ShaderAst.Glsl.print(readsTable() :: Nil))

    @Test
    def testWgslConstArrayIsLocalVar(): Unit \ Assert =
        Assert.assertEq(expected = "fn pick(k: i32) -> f32 {\n    var tbl = array<f32, 2>(1.0, 2.0);\n    return tbl[k];\n}\n",
            ShaderAst.Wgsl.print(readsTable() :: Nil))

    def caller(): ShaderAst.Definition =
        let (pc, c) = param(ShaderAst.Vec3.Vec3, "c");
        let once = call(ShaderAst.Vec3.Vec3, fogLike(), arg(c) :: arg(ShaderAst.bool(true)) :: Nil);
        let twice = call(ShaderAst.Vec3.Vec3, fogLike(), arg(once) :: arg(ShaderAst.bool(false)) :: Nil);
        function("caller", ShaderAst.Ty.Vec3, pc :: Nil, ret(twice) :: Nil)

    @Test
    def testCollectPlacesCalleeOnceBeforeCaller(): Unit \ Assert =
        Assert.assertEq(expected = "tint" :: "caller" :: Nil, ShaderAst.collectOrBug(ShaderAst.Lang.Glsl, caller() :: fogLike() :: Nil) |> List.map(ShaderAst.nameOf))

    // ── 一様さ ──

    def derivativeAfter(condition: ShaderAst.Expr[ShaderAst.Boolean]): ShaderAst.Definition =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        function("edge", ShaderAst.Ty.F32, pa :: Nil, ifInline(condition, ret(a)) :: ret(fwidth(a)) :: Nil)

    @Test
    def testDerivativeAfterNonUniformReturnIsAnError(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(derivativeAfter(lt(s("a"), f("0.5"))))))

    @Test
    def testDerivativeAfterUniformReturnIsAllowed(): Unit \ Assert =
        let u = uniform(ShaderAst.Float.Float, { name = "uOn", ty = ShaderAst.Ty.F32, glsl = Some({ base = "uOn", swizzle = "" }), wgsl = Some({ base = "r3d.uOn", swizzle = "" }), glslType = "float", length = None });
        Assert.assertEq(expected = 0, List.length(ShaderAst.errorsOf(derivativeAfter(lt(u, f("0.5"))))))

    @Test
    def testDerivativeInsideNonUniformIfIsAnError(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil, ifBlock(lt(a, f("0.5")), ret(fwidth(a)) :: Nil) :: ret(a) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testDerivativeThroughExternIsFollowed(): Unit \ Assert =
        let mip = externFunction({ name = "sample", ret = ShaderAst.Ty.F32, params = ShaderAst.Ty.F32 :: Nil, glsl = Body.Outside, wgsl = Body.Outside, deps = Nil, derivative = true });
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil, ifInline(lt(a, f("0.5")), ret(a)) :: ret(call(ShaderAst.Float.Float, mip, arg(a) :: Nil)) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testNonUniformReturnInsideUniformIfIsFollowed(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil,
            ifBlock(ShaderAst.bool(true), ifInline(lt(a, f("0.5")), ret(a)) :: Nil) :: ret(fwidth(a)) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testNonUniformReturnInsideLoopIsFollowed(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil,
            for_("k", i(0), k -> lt(k, i(2)), Layout.Block, _ -> ifInline(lt(a, f("0.5")), ret(a)) :: Nil) :: ret(fwidth(a)) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testAssigningToLetIsAnError(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let (declK, k) = let_("k", a);
        let d = function("bad", ShaderAst.Ty.F32, pa :: Nil, declK :: assign(k, a) :: ret(k) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testReturningWrongTypeIsAnError(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let d = function("bad", ShaderAst.Ty.Vec3, pa :: Nil, ret(a) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    def other(): ShaderAst.Definition =
        let (pc, c) = param(ShaderAst.Vec3.Vec3, "c");
        let (pb, _) = param(ShaderAst.Boolean.Boolean, "on");
        function("tint", ShaderAst.Ty.Vec3, pc :: pb :: Nil, ret(c) :: Nil)

    @Test
    def testSameNameWithDifferentBodyIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(ShaderAst.collect(ShaderAst.Lang.Glsl, fogLike() :: other() :: Nil)))

    @Test
    def testGlslPrivateWithInitAndLength(): Unit \ Assert =
        Assert.assertEq(expected = "float lit[4];\n",
            ShaderAst.Glsl.definition(ShaderAst.privateVar("lit", ShaderAst.Float.Float, Some(4), None, None)))

    @Test
    def testWgslPrivateWithInit(): Unit \ Assert =
        Assert.assertEq(expected = "var<private> sun: f32 = 1.0;\n",
            ShaderAst.Wgsl.definition(ShaderAst.privateVar("sun", ShaderAst.Float.Float, None, Some(f("1.0")), None)))

    @Test
    def testWgslOnlyPrivateIsEmptyInGlsl(): Unit \ Assert =
        Assert.assertEq(expected = "", ShaderAst.Glsl.definition(ShaderAst.fragCoord()))

    @Test
    def testGlslIfElse(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.Float.Float, "a");
        let d = function("pick", ShaderAst.Ty.F32, pa :: Nil, ShaderAst.ifElse(lt(a, f("0.5")), ret(a) :: Nil, ret(f("1.0")) :: Nil) :: Nil);
        Assert.assertEq(expected = "float pick(float a) {\n    if (a < 0.5) {\n        return a;\n    } else {\n        return 1.0;\n    }\n}\n",
            ShaderAst.Glsl.print(d :: Nil))

    @Test
    def testWgslInlineFor(): Unit \ Assert =
        let (declT, total) = var_("total", i(0));
        let d = function("count", ShaderAst.Ty.I32, Nil, declT :: for_("k", i(0), k -> lt(k, i(3)), Layout.Inline, _ -> incr(total) :: Nil) :: ret(total) :: Nil);
        Assert.assertEq(expected = "fn count() -> i32 {\n    var total = 0;\n    for (var k = 0; k < 3; k++) { total++; }\n    return total;\n}\n",
            ShaderAst.Wgsl.print(d :: Nil))

    // ── 入口・varying・言語ごとの式 ──

    def red(): Expr[ShaderAst.Vec4] = ShaderAst.vec4Of(f("1.0"), f("0.0"), f("0.0"), f("1.0"))

    def entryOf(inputs: List[ShaderAst.Varying], body: List[ShaderAst.Statement]): ShaderAst.FragmentEntry =
        { inputName = "In", declarations = Nil, inputs = inputs, body = body, writesColor = true }

    def varyingOf(name: String, ty: ShaderAst.Ty, location: Int32, interp: ShaderAst.Interp): ShaderAst.Varying =
        { name = name, ty = ty, location = location, interp = interp }

    def affineUv(): ShaderAst.Varying = varyingOf("vUvAffine", ShaderAst.Ty.Vec2, 8, ShaderAst.Interp.Affine)

    def onUniform(): Expr[ShaderAst.Boolean] =
        uniform(ShaderAst.Boolean.Boolean, { name = "uCut", ty = ShaderAst.Ty.Bool, glsl = Some({ base = "uCut", swizzle = "" }), wgsl = Some({ base = "d.uCut", swizzle = "" }),
                                       glslType = "int", length = None })

    def strength(): Expr[Float] =
        uniform(ShaderAst.Float.Float, { name = "uStrength", ty = ShaderAst.Ty.F32, glsl = Some({ base = "uStrength", swizzle = "" }), wgsl = Some({ base = "r3d.uStrength", swizzle = "" }),
                                     glslType = "float", length = None })

    def rect(): ShaderAst.UniformRef =
        { name = "uRect", ty = ShaderAst.Ty.Vec4, glsl = Some({ base = "uRect", swizzle = "" }), wgsl = None, glslType = "vec4", length = None }

    /// f が組む時の誤りで止まるか（止まった時の知らせは標準エラーへ出さない）。
    def stops(f1: Unit -> String): Bool \ IO =
        let saved = System.err;
        System.setErr(new PrintStream(new ByteArrayOutputStream(), true, "UTF-8"));
        let stopped = try { f1() == "" and false } catch { case _: Throwable => true };
        System.setErr(saved);
        stopped

    @Test
    def testGlslEmitAssignsFragColor(): Unit \ Assert =
        Assert.assertTrue(String.endsWith(suffix = "void main() {\n    fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n}\n",
            ShaderAst.Glsl.fragment(entryOf(Nil, ShaderAst.emit(red()) :: Nil))))

    @Test
    def testWgslEmitReturns(): Unit \ Assert =
        Assert.assertTrue(String.endsWith(suffix = "{\n    return vec4f(1.0, 0.0, 0.0, 1.0);\n}\n",
            ShaderAst.Wgsl.fragment(entryOf(Nil, ShaderAst.emit(red()) :: Nil))))

    @Test
    def testGlslEmitAndReturnInInlineIfIsBlock(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    if (gl_FrontFacing) {\n        fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n        return;\n    }\n",
            ShaderAst.Glsl.fragment(entryOf(Nil, ifInline(ShaderAst.frontFacing(), ShaderAst.emitAndReturn(red())) :: ShaderAst.emit(red()) :: Nil))))

    @Test
    def testWgslFrontFacingAddsBuiltin(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    @builtin(front_facing) frontFacing: bool,\n",
            ShaderAst.Wgsl.fragment(entryOf(Nil, ifInline(ShaderAst.frontFacing(), ShaderAst.emitAndReturn(red())) :: ShaderAst.emit(red()) :: Nil))))

    @Test
    def testWgslPixelPositionCopiesFragPos(): Unit \ Assert =
        let (declP, _) = let_("p", ShaderAst.pixelFromTopLeft(rect()));
        Assert.assertTrue(String.contains(substr = "    r3d_fragCoord = i.fragPos;\n", ShaderAst.Wgsl.fragment(entryOf(Nil, declP :: ShaderAst.emit(red()) :: Nil))))

    @Test
    def testGlslPixelPositionDeclaresTargetRect(): Unit \ Assert =
        let (declP, _) = let_("p", ShaderAst.pixelFromTopLeft(rect()));
        Assert.assertTrue(String.contains(substr = "uniform vec4 uRect;\n", ShaderAst.Glsl.fragment(entryOf(Nil, declP :: ShaderAst.emit(red()) :: Nil))))

    @Test
    def testGlslFlatVaryingIsDeclaredFlat(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "flat in vec3 vTint;\n",
            ShaderAst.Glsl.fragment(entryOf(varyingOf("vTint", ShaderAst.Ty.Vec3, 3, ShaderAst.Interp.Flat) :: Nil, ShaderAst.emit(red()) :: Nil))))

    @Test
    def testGlslAffineVaryingIsDeclaredVec3(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "in vec3 vUvAffine;\n", ShaderAst.Glsl.fragment(entryOf(affineUv() :: Nil, ShaderAst.emit(red()) :: Nil))))

    @Test
    def testWgslAffineVaryingIsLinear(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    @location(8) @interpolate(linear) vUvAffine: vec2f,\n",
            ShaderAst.Wgsl.fragment(entryOf(affineUv() :: Nil, ShaderAst.emit(red()) :: Nil))))

    @Test
    def testGlslAffineVaryingIsParenthesizedUnderSwizzle(): Unit \ Assert =
        Assert.assertEq(expected = "(vUvAffine.xy / vUvAffine.z).x", glsl(x(ShaderAst.varying(ShaderAst.Vec2.Vec2, affineUv()))))

    @Test
    def testGlslUniformReadInEntryIsDeclared(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "out vec4 fragColor;\nuniform float uStrength;\n",
            ShaderAst.Glsl.fragment(entryOf(Nil, ShaderAst.emit(ShaderAst.vec4Of(strength(), f("0.0"), f("0.0"), f("1.0"))) :: Nil))))

    @Test
    def testGlslBoolUniformComparesInt(): Unit \ Assert =
        Assert.assertEq(expected = "uCut == 1 && a < 0.5", glsl(ShaderAst.and_(onUniform(), lt(s("a"), f("0.5")))))

    @Test
    def testWgslBoolUniformComparesFloat(): Unit \ Assert =
        Assert.assertEq(expected = "d.uCut > 0.5 && a < 0.5", wgsl(ShaderAst.and_(onUniform(), lt(s("a"), f("0.5")))))

    @Test
    def testRawExprWithOperatorIsParenthesized(): Unit \ Assert =
        Assert.assertEq(expected = "(a + b) * 2.0", glsl(mulS(ShaderAst.rawExpr(ShaderAst.Vec3.Vec3, "a + b", "a + b", Nil, false), f("2.0"))))

    @Test
    def testRawCallIsNotParenthesized(): Unit \ Assert =
        Assert.assertEq(expected = "f(a + b).x * 2.0", glsl(mulS(ShaderAst.rawExpr(ShaderAst.Float.Float, "f(a + b).x", "f(a + b).x", Nil, false), f("2.0"))))

    @Test
    def testGlslCallInUsesGlslArguments(): Unit \ Assert =
        Assert.assertEq(expected = "textureLod(a, 0.0)",
            glsl(ShaderAst.callIn(ShaderAst.Vec4.Vec4, "textureLod", arg(s("a")) :: arg(f("0.0")) :: Nil, "textureSampleLevel", arg(s("a")) :: ShaderAst.samplerArg("smp") :: arg(f("0.0")) :: Nil, Nil, false)))

    @Test
    def testWgslCallInUsesWgslArguments(): Unit \ Assert =
        Assert.assertEq(expected = "textureSampleLevel(a, smp, 0.0)",
            wgsl(ShaderAst.callIn(ShaderAst.Vec4.Vec4, "textureLod", arg(s("a")) :: arg(f("0.0")) :: Nil, "textureSampleLevel", arg(s("a")) :: ShaderAst.samplerArg("smp") :: arg(f("0.0")) :: Nil, Nil, false)))

    def depthMap(): Expr[ShaderAst.DepthTex] = ref(ShaderAst.DepthTex.DepthTex, "map")

    @Test
    def testGlslTargetDepthTexelReadsRed(): Unit \ Assert =
        Assert.assertEq(expected = "texelFetch(map, t, 0).r", glsl(ShaderAst.targetDepthTexel(depthMap(), ref(ShaderAst.IVec2.IVec2, "t"))))

    @Test
    def testWgslTargetDepthTexelFlipsRow(): Unit \ Assert =
        Assert.assertEq(expected = "textureLoad(map, vec2i(t.x, i32(textureDimensions(map, 0).y) - 1 - t.y), 0)",
            wgsl(ShaderAst.targetDepthTexel(depthMap(), ref(ShaderAst.IVec2.IVec2, "t"))))

    @Test
    def testGlslTextureSizeOfLevelZero(): Unit \ Assert =
        Assert.assertEq(expected = "textureSize(map, 0)", glsl(ShaderAst.textureSize(depthMap())))

    @Test
    def testWgslTextureSizeIsSigned(): Unit \ Assert =
        Assert.assertEq(expected = "vec2i(textureDimensions(map, 0))", wgsl(ShaderAst.textureSize(depthMap())))

    @Test
    def testRawExprInOtherLanguageStops(): Unit \ {Assert, IO} =
        let only = ShaderAst.rawExprIn(ShaderAst.Float.Float, ShaderAst.Lang.Glsl, "a", Nil, false);
        Assert.assertTrue(stops(_ -> wgsl(only)))

    @Test
    def testVaryingOfWrongTypeStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> glsl(ShaderAst.varying(ShaderAst.Vec3.Vec3, affineUv()))))

    @Test
    def testEmitBeforeTheLastStatementStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.fragment(entryOf(Nil, ShaderAst.emit(red()) :: ShaderAst.emit(red()) :: Nil))))

    @Test
    def testEmitInsideIfStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.fragment(entryOf(Nil, ifBlock(ShaderAst.frontFacing(), ShaderAst.emit(red()) :: Nil) :: Nil))))

    @Test
    def testFrontFacingInHelperStops(): Unit \ {Assert, IO} =
        let helper = function("facing", ShaderAst.Ty.Bool, Nil, ret(ShaderAst.frontFacing()) :: Nil);
        let (declF, _) = let_("f", call(ShaderAst.Boolean.Boolean, helper, Nil));
        Assert.assertTrue(stops(_ -> ShaderAst.Wgsl.fragment(entryOf(Nil, declF :: ShaderAst.emit(red()) :: Nil))))

    @Test
    def testVaryingInHelperStops(): Unit \ {Assert, IO} =
        let helper = function("uv", ShaderAst.Ty.Vec2, Nil, ret(ShaderAst.varying(ShaderAst.Vec2.Vec2, affineUv())) :: Nil);
        let (declU, _) = let_("u", call(ShaderAst.Vec2.Vec2, helper, Nil));
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.fragment(entryOf(affineUv() :: Nil, declU :: ShaderAst.emit(red()) :: Nil))))

    // ── vertex の入口・vertex と frag の組 ──

    def sizeAttribute(): ShaderAst.Attribute = { name = "aSize", ty = ShaderAst.Ty.Vec4, glslLocation = Some(2), wgslLocation = Some(5) }

    def wgslOnly(): ShaderAst.Attribute = { name = "aModel0", ty = ShaderAst.Ty.Vec4, glslLocation = None, wgslLocation = Some(3) }

    def tintOut(): ShaderAst.Varying = varyingOf("vTint", ShaderAst.Ty.Vec3, 3, ShaderAst.Interp.Flat)

    def origin(): Expr[ShaderAst.Vec4] = ShaderAst.vec4Of(f("0.0"), f("0.0"), f("0.0"), f("1.0"))

    def vertexOf(attributes: List[ShaderAst.Attribute], outputs: List[ShaderAst.Varying], body: List[ShaderAst.Statement]): ShaderAst.VertexEntry =
        { inputName = "VIn", outputName = "VOut", declarations = Nil, attributes = attributes, outputs = outputs, body = body }

    def sized(): Expr[ShaderAst.Vec4] = ShaderAst.attribute(ShaderAst.Vec4.Vec4, sizeAttribute())

    @Test
    def testGlslVertexDeclaresAttributeAtItsLocation(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "layout (location = 2) in vec4 aSize;\n",
            ShaderAst.Glsl.vertex(vertexOf(sizeAttribute() :: Nil, Nil, ShaderAst.clipOut(sized()) :: Nil))))

    @Test
    def testGlslVertexSkipsAttributeOfTheOtherLanguage(): Unit \ Assert =
        Assert.assertFalse(String.contains(substr = "aModel0", ShaderAst.Glsl.vertex(vertexOf(wgslOnly() :: Nil, Nil, ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testWgslVertexReadsAttributeFromTheInput(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    o.position = sg_clipFromGl(v.aSize);\n",
            ShaderAst.Wgsl.vertex(vertexOf(sizeAttribute() :: Nil, Nil, ShaderAst.clipOut(sized()) :: Nil))))

    @Test
    def testWgslVertexDeclaresAttributeAtItsLocation(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    @location(5) aSize: vec4f,\n",
            ShaderAst.Wgsl.vertex(vertexOf(sizeAttribute() :: Nil, Nil, ShaderAst.clipOut(sized()) :: Nil))))

    @Test
    def testGlslClipOutAssignsGlPosition(): Unit \ Assert =
        Assert.assertTrue(String.endsWith(suffix = "void main() {\n    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n}\n",
            ShaderAst.Glsl.vertex(vertexOf(Nil, Nil, ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testGlslOutputIsDeclaredFlat(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "flat out vec3 vTint;\n",
            ShaderAst.Glsl.vertex(vertexOf(Nil, tintOut() :: Nil, ShaderAst.output(tintOut(), v3("c")) :: ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testWgslOutputWritesTheOutputStruct(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    o.vTint = c;\n",
            ShaderAst.Wgsl.vertex(vertexOf(Nil, tintOut() :: Nil, ShaderAst.output(tintOut(), v3("c")) :: ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testGlslQuadCornerDeclaresCornerAttribute(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "layout (location = 0) in vec2 aCorner;\n",
            ShaderAst.Glsl.vertex(vertexOf(Nil, Nil, ShaderAst.clipOut(ShaderAst.vec4Of(x(ShaderAst.quadCorner()), f("0.0"), f("0.0"), f("1.0"))) :: Nil))))

    @Test
    def testWgslFullscreenCopiesVertexIndex(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    r3d_vertexIndex = v.vertexIndex;\n",
            ShaderAst.Wgsl.vertex(vertexOf(Nil, Nil, ShaderAst.clipOut(ShaderAst.fullscreenPosition()) :: Nil))))

    @Test
    def testGlslAffineOutputCarriesW(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "    vUvAffine = vec3(uv * gl_Position.w, gl_Position.w);\n",
            ShaderAst.Glsl.vertex(vertexOf(Nil, affineUv() :: Nil, ShaderAst.clipOut(origin()) :: ShaderAst.output(affineUv(), ref(ShaderAst.Vec2.Vec2, "uv")) :: Nil))))

    @Test
    def testAffineOutputBeforeClipOutStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.vertex(vertexOf(Nil, affineUv() :: Nil, ShaderAst.output(affineUv(), ref(ShaderAst.Vec2.Vec2, "uv")) :: ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testSecondClipOutStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Wgsl.vertex(vertexOf(Nil, Nil, ShaderAst.clipOut(origin()) :: ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testOutputMissingFromTheTableStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.vertex(vertexOf(Nil, Nil, ShaderAst.output(tintOut(), v3("c")) :: ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testFragmentReadingVaryingMissingFromInputsStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.fragment(entryOf(Nil, ShaderAst.emit(ShaderAst.vec4FromVec3(ShaderAst.varying(ShaderAst.Vec3.Vec3, tintOut()), f("1.0"))) :: Nil))))

    @Test
    def testWgslFragmentWithoutColorHasNoOutput(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "@fragment fn fs_main(i: In) {\n",
            ShaderAst.Wgsl.fragment({ writesColor = false, body = ifInline(lt(s("a"), f("0.5")), ShaderAst.discard_()) :: Nil | entryOf(tintOut() :: Nil, Nil) })))

    @Test
    def testColorFragmentNotEndingWithEmitStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Wgsl.fragment(entryOf(Nil, ifInline(lt(s("a"), f("0.5")), ShaderAst.discard_()) :: Nil))))

    @Test
    def testOutputDeclaredButNotWrittenStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.vertex(vertexOf(Nil, tintOut() :: Nil, ShaderAst.clipOut(origin()) :: Nil))))

    @Test
    def testFragmentWithoutColorEmittingStops(): Unit \ {Assert, IO} =
        Assert.assertTrue(stops(_ -> ShaderAst.Glsl.fragment({ writesColor = false | entryOf(Nil, ShaderAst.emit(red()) :: Nil) })))

    @Test
    def testOnlyInLeavesOutTheOtherLanguage(): Unit \ Assert =
        let body = ShaderAst.onlyIn(ShaderAst.Lang.Glsl, ShaderAst.discard_() :: Nil) :: ShaderAst.emit(red()) :: Nil;
        Assert.assertFalse(String.contains(substr = "discard", ShaderAst.Wgsl.fragment(entryOf(Nil, body))))

    @Test
    def testLinkFindsVaryingTheVertexDoesNotWrite(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(ShaderAst.linkErrors(vertexOf(Nil, Nil, Nil), entryOf(tintOut() :: Nil, Nil))))

    @Test
    def testLinkFindsOverlappingLocations(): Unit \ Assert =
        let same = varyingOf("vOther", ShaderAst.Ty.Vec3, 3, ShaderAst.Interp.Smooth);
        Assert.assertEq(expected = 1, List.length(ShaderAst.linkErrors(vertexOf(Nil, tintOut() :: same :: Nil, Nil), entryOf(Nil, Nil))))

    @Test
    def testGlslPixelNdcCountsFromTheBottom(): Unit \ Assert =
        Assert.assertEq(expected = "(gl_FragCoord.xy - uRect.xy) / vec2(w, h) * 2.0 - 1.0", glsl(ShaderAst.pixelNdc(rect(), s("w"), s("h"))))

    @Test
    def testWgslPixelNdcFlipsTheRow(): Unit \ Assert =
        Assert.assertEq(expected = "vec2f(r3d_fragCoord.x / w * 2.0 - 1.0, 1.0 - r3d_fragCoord.y / h * 2.0)", wgsl(ShaderAst.pixelNdc(rect(), s("w"), s("h"))))
}
