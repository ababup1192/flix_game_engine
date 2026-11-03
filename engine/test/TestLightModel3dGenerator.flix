// 光の式の木の書き下し（CPU の Flix の字・GLSL の字）が、今の 4 本の式で通らない形（1 成分だけ使う Let・文のある枝の Select・
// 1 成分だけ使う光の輪・入口の引数の並び）でも組める字を出すこと。
mod LightModel3d.Codegen.TestGenerator {
    use LightModel3d.{ScalarExpr, Vec3Expr, Cond, Vec3Input, Vec3LightField}

    def hooksForTest(): LightModel3d.Codegen.CpuHooks = { shadowType = "ShadowForTest", shadowFunction = "shadowForTest" }

    def flixOf(params: List[LightModel3d.Codegen.Param], e: Vec3Expr): String =
        LightModel3d.Codegen.generateFlixOf(hooksForTest(), { module = "M", origin = "", about = "" }, { name = "f", model = e, doc = "", params = params } :: Nil)

    def normal(): Vec3Expr = Vec3Expr.In(Vec3Input.Normal)

    def splat(s: ScalarExpr): Vec3Expr = Vec3Expr.Make(s, s, s)

    /// y だけ使う vec3 の Let は、x と z を束ねない（使わない局所変数を Flix は止める）。
    @Test
    def testLetUsingOneComponentDropsTheOthers(): Unit \ Assert =
        let e = Vec3Expr.Let("v", Vec3Expr.Add(normal(), normal()), splat(ScalarExpr.Y(Vec3Expr.Ref("v"))));
        let text = flixOf(LightModel3d.Codegen.Param.Vec3Param(Vec3Input.Normal) :: Nil, e);
        Assert.assertTrue(String.contains(substr = "let v_0Y = ", text) and not String.contains(substr = "let v_0X = ", text))

    /// x だけ使う光の輪の受け手は、使わない成分に _ を付ける。
    @Test
    def testLoopUsingOneComponentMarksTheOthersUnused(): Unit \ Assert =
        let e = splat(ScalarExpr.X(Vec3Expr.SumPoints(Vec3Expr.LightField(Vec3LightField.Color))));
        let text = flixOf(LightModel3d.Codegen.Param.Points :: Nil, e);
        Assert.assertTrue(String.contains(substr = "let (points_0X, _points_0Y, _points_0Z) = fPoints(points, 0, 0.0, 0.0, 0.0);", text))

    /// 同じ入口の中身の違う 2 つの輪は、別の名前の関数になる。
    @Test
    def testTwoDifferentLoopsGetDifferentNames(): Unit \ Assert =
        let color = Vec3Expr.LightField(Vec3LightField.Color);
        let e = Vec3Expr.Add(Vec3Expr.SumPoints(Vec3Expr.Scale(color, ScalarExpr.Num(2.0))), Vec3Expr.SumPoints(color));
        let text = flixOf(LightModel3d.Codegen.Param.Points :: Nil, e);
        Assert.assertTrue(String.contains(substr = "    def fPoints(", text) and String.contains(substr = "    def fPoints2(", text))

    /// 枝に Let のある Select は、枝の中で文を流す（選ばない側を計算しない）。
    def branchWithLet(): Vec3Expr =
        let y = ScalarExpr.Y(normal());
        splat(ScalarExpr.Select(Cond.Greater(y, ScalarExpr.Num(0.0)),
                                ScalarExpr.Let("a", ScalarExpr.Mul(y, y), ScalarExpr.Add(ScalarExpr.Ref("a"), ScalarExpr.Ref("a"))),
                                ScalarExpr.Num(0.0)))

    @Test
    def testFlixSelectKeepsBranchStatementsInsideTheBranch(): Unit \ Assert =
        let text = flixOf(LightModel3d.Codegen.Param.Vec3Param(Vec3Input.Normal) :: Nil, branchWithLet());
        Assert.assertTrue(String.contains(substr = "let t_1 = if ((nY > 0.0)) {\n            let a_0 = (nY * nY);\n", text))

    @Test
    def testGlslSelectKeepsBranchStatementsInsideTheBranch(): Unit \ Assert =
        let text = LightModel3d.Codegen.toGlsl("f", Vec3Input.Normal :: Nil, branchWithLet());
        Assert.assertTrue(String.contains(substr = "    float t_1;\n    if ((n.y > 0.0)) {\n        float a_0 = (n.y * n.y);\n", text))

    /// 引数の順は入口に書いた並びのまま（enum の宣言の順に頼らない）。
    @Test
    def testEntryParamsFollowTheDeclaredOrder(): Unit \ Assert =
        let e = Vec3Expr.Add(Vec3Expr.In(Vec3Input.Position), normal());
        let text = flixOf(LightModel3d.Codegen.Param.Vec3Param(Vec3Input.Normal) :: LightModel3d.Codegen.Param.Vec3Param(Vec3Input.Position) :: Nil, e);
        Assert.assertTrue(String.contains(substr = "pub def f(nX: Float64, nY: Float64, nZ: Float64, pX: Float64, pY: Float64, pZ: Float64)", text))
}
