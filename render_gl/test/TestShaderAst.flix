// ShaderAst の 2 つの printer と、定義を集める所・一様さの検査。
mod TestShaderAst {
    use ShaderAst.{Expr, Float, Vec3, Body, Layout}
    use ShaderAst.{f, i, add, sub, mul, mulS, lt, gt, eq, or_, ternary, paren, x, ref, let_, var_, assign, ifInline, ifBlock, for_, ret, param, call, arg,
                   function, externFunction, constArray, at, uniform, clampS, fwidth, incr}

    def v3(name: String): Expr[Vec3] = ref(ShaderAst.vec3(), name)

    def s(name: String): Expr[Float] = ref(ShaderAst.float(), name)

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
        Assert.assertEq(expected = "(a + b) & c", wgsl(ShaderAst.bitAnd(add(ref(ShaderAst.int(), "a"), ref(ShaderAst.int(), "b")), ref(ShaderAst.int(), "c"))))

    @Test
    def testWgslMixedLogicalOperatorsGetParentheses(): Unit \ Assert =
        Assert.assertEq(expected = "a > b || (a < b && a == b)",
            wgsl(or_(gt(s("a"), s("b")), ShaderAst.and_(lt(s("a"), s("b")), eq(s("a"), s("b"))))))

    def snapUniform(): Expr[ShaderAst.Vec2] =
        uniform(ShaderAst.vec2(), { name = "uSize", ty = ShaderAst.Ty.Vec2, glsl = Some({ base = "uTarget", swizzle = "zw" }), wgsl = Some({ base = "cam.uSnap", swizzle = "xy" }) })

    @Test
    def testUniformSwizzleComposesInGlsl(): Unit \ Assert =
        Assert.assertEq(expected = "uTarget.w", glsl(ShaderAst.y(snapUniform())))

    @Test
    def testUniformSwizzleComposesInWgsl(): Unit \ Assert =
        Assert.assertEq(expected = "cam.uSnap.y", wgsl(ShaderAst.y(snapUniform())))

    // ── 文と定義 ──

    def fogLike(): ShaderAst.Definition =
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let (pb, on) = param(ShaderAst.boolean(), "on");
        let (declV, v) = var_("v", c);
        function("tint", ShaderAst.Ty.Vec3, pc :: pb :: Nil, declV :: ifInline(on, assign(v, mulS(v, f("0.5")))) :: ret(v) :: Nil)

    @Test
    def testGlslFunctionUsesTypedDeclarationAndInlineIf(): Unit \ Assert =
        Assert.assertEq(expected = "vec3 tint(vec3 c, bool on) {\n    vec3 v = c;\n    if (on) v = v * 0.5;\n    return v;\n}\n",
            ShaderAst.Glsl.printOnly(fogLike() :: Nil))

    @Test
    def testWgslFunctionUsesVarAndBracedIf(): Unit \ Assert =
        Assert.assertEq(expected = "fn tint(c: vec3f, on: bool) -> vec3f {\n    var v = c;\n    if (on) { v = v * 0.5; }\n    return v;\n}\n",
            ShaderAst.Wgsl.printOnly(fogLike() :: Nil))

    def counting(): ShaderAst.Definition =
        let (pn, n) = param(ShaderAst.int(), "n");
        let (declT, total) = var_("total", i(0));
        function("count", ShaderAst.Ty.I32, pn :: Nil,
            declT :: for_("k", i(0), k -> lt(k, n), Layout.Block, _ -> incr(total) :: Nil) :: ret(total) :: Nil)

    @Test
    def testGlslForBlock(): Unit \ Assert =
        Assert.assertEq(expected = "int count(int n) {\n    int total = 0;\n    for (int k = 0; k < n; k++) {\n        total++;\n    }\n    return total;\n}\n",
            ShaderAst.Glsl.printOnly(counting() :: Nil))

    @Test
    def testWgslForBlock(): Unit \ Assert =
        Assert.assertEq(expected = "fn count(n: i32) -> i32 {\n    var total = 0;\n    for (var k = 0; k < n; k++) {\n        total++;\n    }\n    return total;\n}\n",
            ShaderAst.Wgsl.printOnly(counting() :: Nil))

    def table(): ShaderAst.Definition = constArray({ name = "tbl", elem = ShaderAst.Ty.F32, values = "1.0" :: "2.0" :: Nil })

    def readsTable(): ShaderAst.Definition =
        let (pi, k) = param(ShaderAst.int(), "k");
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
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let once = call(ShaderAst.vec3(), fogLike(), arg(c) :: arg(ShaderAst.bool(true)) :: Nil);
        let twice = call(ShaderAst.vec3(), fogLike(), arg(once) :: arg(ShaderAst.bool(false)) :: Nil);
        function("caller", ShaderAst.Ty.Vec3, pc :: Nil, ret(twice) :: Nil)

    @Test
    def testCollectPlacesCalleeOnceBeforeCaller(): Unit \ Assert =
        Assert.assertEq(expected = "tint" :: "caller" :: Nil, ShaderAst.collectOrBug(caller() :: fogLike() :: Nil) |> List.map(ShaderAst.nameOf))

    // ── 一様さ ──

    def derivativeAfter(condition: ShaderAst.Expr[ShaderAst.Boolean]): ShaderAst.Definition =
        let (pa, a) = param(ShaderAst.float(), "a");
        function("edge", ShaderAst.Ty.F32, pa :: Nil, ifInline(condition, ret(a)) :: ret(fwidth(a)) :: Nil)

    @Test
    def testDerivativeAfterNonUniformReturnIsAnError(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(derivativeAfter(lt(s("a"), f("0.5"))))))

    @Test
    def testDerivativeAfterUniformReturnIsAllowed(): Unit \ Assert =
        let u = uniform(ShaderAst.float(), { name = "uOn", ty = ShaderAst.Ty.F32, glsl = Some({ base = "uOn", swizzle = "" }), wgsl = Some({ base = "r3d.uOn", swizzle = "" }) });
        Assert.assertEq(expected = 0, List.length(ShaderAst.errorsOf(derivativeAfter(lt(u, f("0.5"))))))

    @Test
    def testDerivativeInsideNonUniformIfIsAnError(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.float(), "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil, ifBlock(lt(a, f("0.5")), ret(fwidth(a)) :: Nil) :: ret(a) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testDerivativeThroughExternIsFollowed(): Unit \ Assert =
        let mip = externFunction({ name = "sample", ret = ShaderAst.Ty.F32, params = ShaderAst.Ty.F32 :: Nil, glsl = Body.Outside, wgsl = Body.Outside, deps = Nil, derivative = true });
        let (pa, a) = param(ShaderAst.float(), "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil, ifInline(lt(a, f("0.5")), ret(a)) :: ret(call(ShaderAst.float(), mip, arg(a) :: Nil)) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testNonUniformReturnInsideUniformIfIsFollowed(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.float(), "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil,
            ifBlock(ShaderAst.bool(true), ifInline(lt(a, f("0.5")), ret(a)) :: Nil) :: ret(fwidth(a)) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testNonUniformReturnInsideLoopIsFollowed(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.float(), "a");
        let d = function("edge", ShaderAst.Ty.F32, pa :: Nil,
            for_("k", i(0), k -> lt(k, i(2)), Layout.Block, _ -> ifInline(lt(a, f("0.5")), ret(a)) :: Nil) :: ret(fwidth(a)) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testAssigningToLetIsAnError(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.float(), "a");
        let (declK, k) = let_("k", a);
        let d = function("bad", ShaderAst.Ty.F32, pa :: Nil, declK :: assign(k, a) :: ret(k) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    @Test
    def testReturningWrongTypeIsAnError(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.float(), "a");
        let d = function("bad", ShaderAst.Ty.Vec3, pa :: Nil, ret(a) :: Nil);
        Assert.assertEq(expected = 1, List.length(ShaderAst.errorsOf(d)))

    def other(): ShaderAst.Definition =
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let (pb, _) = param(ShaderAst.boolean(), "on");
        function("tint", ShaderAst.Ty.Vec3, pc :: pb :: Nil, ret(c) :: Nil)

    @Test
    def testSameNameWithDifferentBodyIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(ShaderAst.collect(fogLike() :: other() :: Nil)))

    @Test
    def testGlslPrivateWithInitAndLength(): Unit \ Assert =
        Assert.assertEq(expected = "float lit[4];\n",
            ShaderAst.Glsl.definition(ShaderAst.privateVar("lit", ShaderAst.float(), Some(4), None, None)))

    @Test
    def testWgslPrivateWithInit(): Unit \ Assert =
        Assert.assertEq(expected = "var<private> sun: f32 = 1.0;\n",
            ShaderAst.Wgsl.definition(ShaderAst.privateVar("sun", ShaderAst.float(), None, Some(f("1.0")), None)))

    @Test
    def testWgslOnlyPrivateIsEmptyInGlsl(): Unit \ Assert =
        Assert.assertEq(expected = "", ShaderAst.Glsl.definition(ShaderAst.fragCoord()))

    @Test
    def testGlslIfElse(): Unit \ Assert =
        let (pa, a) = param(ShaderAst.float(), "a");
        let d = function("pick", ShaderAst.Ty.F32, pa :: Nil, ShaderAst.ifElse(lt(a, f("0.5")), ret(a) :: Nil, ret(f("1.0")) :: Nil) :: Nil);
        Assert.assertEq(expected = "float pick(float a) {\n    if (a < 0.5) {\n        return a;\n    } else {\n        return 1.0;\n    }\n}\n",
            ShaderAst.Glsl.printOnly(d :: Nil))

    @Test
    def testWgslInlineFor(): Unit \ Assert =
        let (declT, total) = var_("total", i(0));
        let d = function("count", ShaderAst.Ty.I32, Nil, declT :: for_("k", i(0), k -> lt(k, i(3)), Layout.Inline, _ -> incr(total) :: Nil) :: ret(total) :: Nil);
        Assert.assertEq(expected = "fn count() -> i32 {\n    var total = 0;\n    for (var k = 0; k < 3; k++) { total++; }\n    return total;\n}\n",
            ShaderAst.Wgsl.printOnly(d :: Nil))
}
