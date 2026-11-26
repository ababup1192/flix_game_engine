// Render3dShaders — 3D の描き手のシェーダーの関数を ShaderAst で 1 回だけ書いた物（GLSL は Render3dGlsl・WGSL は Render3dWgsl が print する）。
// 式の約束（色の空間・法線マップ・PS1 風の丸め）は Render3d.flix の頭と Render3dGlsl の doc。CPU の描き手（SoftRaster3d）が 3 本目で、gl-parity が同じ値かを確かめる。
pub mod Render3dShaders {
    use ShaderAst.{Expr, Definition, Float, Vec2, Vec3, Vec4, IVec2, Int, Boolean, DepthTex, Mat4, Body, Layout}
    use Render3d.Uniforms.R3dUniform
    use ShaderAst.{f, i, add, sub, mul, div, addS, subS, mulS, divS, sMul, sSub, lt, le, or_, neg, paren, ternary, at,
                   x, y, z, w, r, g, b, xyz, vec2Of, vec3Of, vec4Of, ivec2Of, floor, abs, normalize, asin, dot, cross, distance, atan2,
                   clamp, clampS, let_, var_, assign, ifInline, ret, param, call, arg, uniform, bitAnd}

    // ── uniform ──

    /// handle u の uniform を、型のマーカー w1 で読む。
    def u(w1: ShaderAst.TyWitness[t], h: R3dUniform): Expr[t] = uniform(w1, Render3d.Uniforms.refOf(h))

    /// 目の位置。
    pub def eye(): Expr[Vec3] = u(ShaderAst.vec3(), R3dUniform.Eye)

    /// Output.Depth の灰色の (near, range)。
    pub def depthRange(): Expr[Vec2] = u(ShaderAst.vec2(), R3dUniform.DepthRange)

    /// PS1 風の (色のレベルの数, 表の番号, ディザの強さ, アフィンの割合)。
    pub def psx(): Expr[Vec4] = u(ShaderAst.vec4(), R3dUniform.Psx)

    /// 場面の描き先の矩形 (左下の x, y, 幅, 高さ)（GLSL だけ。WGSL の画素の位置は場面の描き先の左上が 0）。
    pub def psxTargetRect(): ShaderAst.UniformRef = Render3d.Uniforms.refOf(R3dUniform.PsxTarget)

    /// 頂点を丸める格子の大きさ（画素。0 で丸めない）。
    pub def vertexSnapGrid(): Expr[Float] = u(ShaderAst.float(), R3dUniform.VertexSnap)

    /// 場面の描き先の幅と高さ（画素。GLSL は描き先の矩形の zw・WGSL はカメラの値の uSnap の xy）。
    pub def vertexSnapTarget(): Expr[Vec2] =
        uniform(ShaderAst.vec2(), { name = "uPsxTarget", ty = ShaderAst.Ty.Vec2, glsl = Some({ base = "uPsxTarget", swizzle = "zw" }),
                                    wgsl = Some({ base = "r3dCamera.uSnap", swizzle = "xy" }) })

    // ── 色の空間 ──

    def scalarColor(name: String, glsl: String -> String, wgsl: String -> String): Definition =
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.F32, params = ShaderAst.Ty.F32 :: Nil, glsl = Body.Text(glsl(name)), wgsl = Body.Text(wgsl(name)),
                           deps = Nil, derivative = false })

    /// sRGB の値 1 つを線形へ（式は Texture3d が両方の言語で作る）。
    pub def srgbToLinear(): Definition = scalarColor("r3d_srgbToLinear", Texture3d.srgbToLinearGlsl, Texture3d.srgbToLinearWgsl)

    /// 線形の値 1 つを sRGB へ。
    pub def linearToSrgb(): Definition = scalarColor("r3d_linearToSrgb", Texture3d.linearToSrgbGlsl, Texture3d.linearToSrgbWgsl)

    def perChannel(name: String, scalar: Definition): Definition =
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let one = (v: Expr[Float]) -> call(ShaderAst.float(), scalar, arg(v) :: Nil);
        ShaderAst.function(name, ShaderAst.Ty.Vec3, pc :: Nil, ret(vec3Of(one(r(c)), one(g(c)), one(b(c)))) :: Nil)

    /// vec3 の sRGB → 線形。
    pub def srgbToLinear3(): Definition = perChannel("r3d_srgbToLinear3", srgbToLinear())

    /// vec3 の線形 → sRGB。
    pub def linearToSrgb3(): Definition = perChannel("r3d_linearToSrgb3", linearToSrgb())

    /// 色の空間の 4 つの関数（スカラーの 2 つ → vec3 の 2 つの順）。
    pub def colorSpace(): List[Definition] = srgbToLinear() :: linearToSrgb() :: srgbToLinear3() :: linearToSrgb3() :: Nil

    // ── 色を作る最後の組み立て ──

    /// LightModel3d の木から作った関数 name（引数は inputs・返り値は vec3）。本文は LightModel3d.Codegen が両方の言語で作る。
    def treeFunction(name: String, inputs: List[LightModel3d.Vec3Input], tree: LightModel3d.Vec3Expr): Definition =
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.Vec3, params = inputs |> List.map(_ -> ShaderAst.Ty.Vec3),
                                   glsl = Body.Text(LightModel3d.Codegen.toGlsl(name, inputs, tree)), wgsl = Body.Text(LightModel3d.Codegen.toWgsl(name, inputs, tree)),
                                   deps = Nil, derivative = false })

    /// 変種 v の光の式 lightAt(点, 法線)。
    pub def lightAt(v: Render3d.ProgramKey.ShaderVariant): Definition =
        treeFunction("lightAt", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: Nil,
                     LightModel3d.lightingModelFor(Render3d.ProgramKey.lightVariantOf(v)))

    /// かすみの式 fogAt(点, 色)。
    pub def fogAt(): Definition =
        treeFunction("fogAt", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Color :: Nil, LightModel3d.fogModel())

    /// かすみ fogged(色, 点)（uFogOn = 0 なら色のまま）。
    pub def fogged(): Definition =
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let (pp, p) = param(ShaderAst.vec3(), "p");
        ShaderAst.function("fogged", ShaderAst.Ty.Vec3, pc :: pp :: Nil,
            ifInline(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.FogOn), i(0)), ret(c)) ::
            ret(call(ShaderAst.vec3(), fogAt(), arg(p) :: arg(c) :: Nil)) :: Nil)

    def toLinear3(v: Expr[Vec3]): Expr[Vec3] = call(ShaderAst.vec3(), srgbToLinear3(), arg(v) :: Nil)

    def toSrgb3(v: Expr[Vec3]): Expr[Vec3] = call(ShaderAst.vec3(), linearToSrgb3(), arg(v) :: Nil)

    /// 色 = albedoLinear × tint × light（fogOn ならかすみ）+ 線形へ戻した emission × intensity を、画面の値へ戻した物（Render3dGlsl.surfaceOutSource の doc）。
    pub def surfaceOut(): Definition =
        let (pa, albedo) = param(ShaderAst.vec3(), "albedoLinear");
        let (pt, tint) = param(ShaderAst.vec3(), "tint");
        let (pl, light) = param(ShaderAst.vec3(), "light");
        let (pe, emission) = param(ShaderAst.vec3(), "emission");
        let (pi, intensity) = param(ShaderAst.float(), "intensity");
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let (pf, fogOn) = param(ShaderAst.boolean(), "fogOn");
        let (declC, c) = var_("c", mul(mul(albedo, tint), light));
        ShaderAst.function("r3d_surfaceOut", ShaderAst.Ty.Vec3, pa :: pt :: pl :: pe :: pi :: pp :: pf :: Nil,
            declC ::
            ifInline(fogOn, assign(c, call(ShaderAst.vec3(), fogged(), arg(c) :: arg(p) :: Nil))) ::
            ret(toSrgb3(add(c, mulS(toLinear3(emission), intensity)))) :: Nil)

    /// PBR の色をかすみに通してから emission を足して画面の値へ戻す（Render3dGlsl.metallicRoughnessSource の doc）。
    pub def surfaceOutLit(): Definition =
        let (pl, lit) = param(ShaderAst.vec3(), "lit");
        let (pe, emission) = param(ShaderAst.vec3(), "emission");
        let (pi, intensity) = param(ShaderAst.float(), "intensity");
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let (declC, c) = let_("c", call(ShaderAst.vec3(), fogged(), arg(lit) :: arg(p) :: Nil));
        ShaderAst.function("r3d_surfaceOutLit", ShaderAst.Ty.Vec3, pl :: pe :: pi :: pp :: Nil,
            declC :: ret(toSrgb3(add(c, mulS(toLinear3(emission), intensity)))) :: Nil)

    // ── 法線マップ・環境マップ・奥行き ──

    /// 外向きの法線 n をタンジェントと法線マップの rgb c で傾ける（Render3dGlsl.applyNormalMapSource の doc）。
    // WhyNot: 最後の normalize を If の文にしない — select は両側を計算するが、長さ 0 の側の NaN は捨てられる。
    pub def applyNormalMap(): Definition =
        let (pn, n) = param(ShaderAst.vec3(), "n");
        let (pt, tangent) = param(ShaderAst.vec4(), "tangent");
        let (ps, strength) = param(ShaderAst.float(), "strength");
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let (declT, t) = var_("t", sub(xyz(tangent), mulS(n, dot(n, xyz(tangent)))));
        let (declB, bitangent) = let_("b", mulS(cross(n, t), w(tangent)));
        let axis = (v: Expr[Float]) -> sub(mul(v, f("2.0")), f("1.0"));
        let (declM, m) = let_("m", vec3Of(mul(axis(x(c)), strength), mul(axis(y(c)), strength), axis(z(c))));
        let (declP, p) = let_("p", add(add(mulS(t, x(m)), mulS(bitangent, y(m))), mulS(n, z(m))));
        ShaderAst.function("applyNormalMap", ShaderAst.Ty.Vec3, pn :: pt :: ps :: pc :: Nil,
            declT ::
            ifInline(lt(dot(t, t), f("1e-12")), ret(n)) ::
            assign(t, normalize(t)) ::
            declB :: declM :: declP ::
            ret(ternary(lt(dot(p, p), f("1e-12")), n, normalize(p))) :: Nil)

    /// 向き d（長さ 1）で環境マップを読む座標（LightModel3d.environmentUvOf と同じ式）。
    // WhyNot: 極で atan2 を選ばない形を If の文にしない — select は両側を計算するが、atan2(0, 0) の値は捨てられる（Flix の atan2 と同じ 0 を選ぶ）。
    pub def environmentUv(): Definition =
        let (pd, d) = param(ShaderAst.vec3(), "d");
        let pole = paren(lt(add(abs(x(d)), abs(z(d))), f("1e-12")));
        let (declA, azimuth) = let_("azimuth", ternary(pole, f("0.0"), atan2(x(d), neg(z(d)))));
        ShaderAst.function("environmentUv", ShaderAst.Ty.Vec2, pd :: Nil,
            declA ::
            ret(vec2Of(add(f("0.5"), div(azimuth, f("6.283185307179586"))),
                       sub(f("0.5"), div(asin(clamp(y(d), f("-1.0"), f("1.0"))), f("3.141592653589793"))))) :: Nil)

    /// Output.Depth の灰色（目からの距離で near が黒・near + range が白）。
    pub def depthGray(): Definition =
        let (pp, p) = param(ShaderAst.vec3(), "p");
        ShaderAst.function("depthGray", ShaderAst.Ty.F32, pp :: Nil,
            ret(clamp(div(sub(distance(p, eye()), x(depthRange())), y(depthRange())), f("0.0"), f("1.0"))) :: Nil)

    // ── PS1 風 ──

    def table(name: String, xs: List[Int32]): Definition =
        ShaderAst.constArray({ name = name, elem = ShaderAst.Ty.F32, values = xs |> List.map(v -> "${v}.0") })

    /// PS1 の 4×4 のディザの表（Scene3d.Psx.psxTable）。
    pub def psxTable(): Definition = table("r3d_psxTable", Scene3d.Psx.psxTable())

    /// Bayer の 4×4 の表（Scene3d.Psx.bayer4Table）。
    pub def bayerTable(): Definition = table("r3d_bayerTable", Scene3d.Psx.bayer4Table())

    /// 描き先の左上を 0 とする画素 p のディザの量（uPsx.y = 表の番号 Scene3d.Psx.patternCode）。
    pub def psxDither(): Definition =
        let (pp, p) = param(ShaderAst.ivec2(), "p");
        let (declI, idx) = let_("i", add(mul(paren(bitAnd(y(p), i(3))), i(4)), paren(bitAnd(x(p), i(3)))));
        ShaderAst.function("r3d_psxDither", ShaderAst.Ty.F32, pp :: Nil,
            declI ::
            ifInline(lt(y(psx()), f("0.5")), ret(div(at(psxTable(), idx), f("8.0")))) ::
            ifInline(lt(y(psx()), f("1.5")), ret(sub(div(paren(add(at(bayerTable(), idx), f("0.5"))), f("16.0")), f("0.5")))) ::
            ret(f("0.0")) :: Nil)

    /// PS1 風の色の丸め r3d_colorDepth(画面の値の色)（式は Scene3d.Psx.quantize・CPU の描き手は SoftRaster3d.Psx.quantized）。
    pub def colorDepth(): Definition =
        let (pc, c) = param(ShaderAst.vec3(), "c");
        let (declP, p) = let_("p", ShaderAst.pixelFromTopLeft(psxTargetRect()));
        let (declS, step) = let_("step", div(f("256.0"), paren(add(x(psx()), f("1.0")))));
        let dither = call(ShaderAst.float(), psxDither(), arg(p) :: Nil);
        let (declV, v) = let_("v", addS(floor(addS(mulS(clampS(c, f("0.0"), f("1.0")), f("255.0")), f("0.5"))), mul(mul(dither, z(psx())), step)));
        ShaderAst.function("r3d_colorDepth", ShaderAst.Ty.Vec3, pc :: Nil,
            ifInline(le(x(psx()), f("0.0")), ret(c)) ::
            declP :: declS :: declV ::
            ret(divS(floor(divS(clampS(v, f("0.0"), f("255.0")), step)), x(psx()))) :: Nil)

    /// PS1 風の頂点を丸める式 r3d_vertexSnap(clip の位置)（CPU の描き手は SoftRaster3d.Psx.snapVertex）。
    /// x・y を描き先の左上を 0 とする画素へ写して格子の一番近い点へ丸め、clip へ戻す（z と w は変えない）。
    // WhyNot: w が 0 以下（目の後ろ）の頂点を丸めない — 画素へ写せず、GPU が手前の面で切る前の形を壊す。
    pub def vertexSnap(): Definition =
        let (pp, p) = param(ShaderAst.vec4(), "p");
        let grid = vertexSnapGrid();
        let size = vertexSnapTarget();
        let toPixel = vec2Of(mul(mul(add(div(x(p), w(p)), f("1.0")), f("0.5")), x(size)),
                             mul(mul(sub(f("1.0"), div(y(p), w(p))), f("0.5")), y(size)));
        let (declS, s) = let_("s", mulS(floor(addS(divS(toPixel, grid), f("0.5"))), grid));
        ShaderAst.function("r3d_vertexSnap", ShaderAst.Ty.Vec4, pp :: Nil,
            ifInline(or_(le(grid, f("0.0")), le(w(p), f("0.0"))), ret(p)) ::
            declS ::
            ret(vec4Of(mul(paren(sub(mul(div(x(s), x(size)), f("2.0")), f("1.0"))), w(p)),
                       mul(paren(sub(f("1.0"), mul(div(y(s), y(size)), f("2.0")))), w(p)), z(p), w(p))) :: Nil)

    // ── 影 ──

    /// 影の地図 map の PCF で、点 p（法線 n の向きへ shift ずらす）が光を受ける割合（Render3dGlsl.shadowSource の doc の約束 1〜5）。
    // WhyNot: 周りの画素を返した後の行で端にそろえない — 端にそろえる（clamp）のを GL の行で済ませてから返せば、CPU の描き手と同じ画素の組を読む。
    pub def shadowLitFraction(): Definition =
        let (pm, map) = param(ShaderAst.depthTexture(), "map");
        let (pl, lightMatrix) = param(ShaderAst.mat4(), "lightMatrix");
        let (pb, bias) = param(ShaderAst.float(), "bias");
        let (pk, pcf) = param(ShaderAst.int(), "pcf");
        let (ps, shift) = param(ShaderAst.float(), "shift");
        let (pn, n) = param(ShaderAst.vec3(), "n");
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let (declC, c) = let_("c", ShaderAst.mulMV(lightMatrix, ShaderAst.vec4FromVec3(add(p, mulS(n, shift)), f("1.0"))));
        let (declN, ndc) = let_("ndc", divS(xyz(c), w(c)));
        let outside = or_(or_(or_(lt(x(ndc), f("-1.0")), ShaderAst.gt(x(ndc), f("1.0"))), lt(y(ndc), f("-1.0"))), ShaderAst.gt(y(ndc), f("1.0")));
        let (declZ, depth) = let_("z", sub(paren(add(mul(z(ndc), f("0.5")), f("0.5"))), bias));
        let (declS, size) = let_("size", ShaderAst.textureSize(map));
        let (declL, last) = let_("last", sub(size, ShaderAst.ivec2Splat(i(1))));
        let cell = ShaderAst.ivec2FromVec2(floor(mul(addS(mulS(ShaderAst.xy(ndc), f("0.5")), f("0.5")), ShaderAst.vec2FromIVec2(size))));
        let (declCenter, center) = let_("center", ShaderAst.clampI(cell, ShaderAst.ivec2Splat(i(0)), last));
        let (declLit, lit) = var_("lit", i(0));
        let (declTotal, total) = var_("total", i(0));
        let inner = (dy: Expr[Int]) -> (dx: Expr[Int]) -> {
            let (declT, t) = let_("t", ShaderAst.clampI(add(center, ivec2Of(dx, dy)), ShaderAst.ivec2Splat(i(0)), last));
            declT :: ifInline(le(depth, ShaderAst.targetDepthTexel(map, t)), ShaderAst.incr(lit)) :: ShaderAst.incr(total) :: Nil
        };
        ShaderAst.function("shadowLitFraction", ShaderAst.Ty.F32, pm :: pl :: pb :: pk :: ps :: pn :: pp :: Nil,
            declC ::
            ifInline(le(w(c), f("0.0")), ret(f("1.0"))) ::
            declN ::
            ifInline(outside, ret(f("1.0"))) ::
            declZ :: declS :: declL :: declCenter :: declLit :: declTotal ::
            ShaderAst.for_("dy", neg(pcf), k -> le(k, pcf), Layout.Block, dy ->
                ShaderAst.for_("dx", neg(pcf), k -> le(k, pcf), Layout.Block, inner(dy)) :: Nil) ::
            ret(div(ShaderAst.toFloat(lit), ShaderAst.toFloat(total))) :: Nil)

    /// スポット i の光に掛ける割合（uShadowOn = 0 のプログラムは 1）。
    pub def spotShadow(): Definition =
        let (pi, index) = param(ShaderAst.int(), "i");
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let fraction = call(ShaderAst.float(), shadowLitFraction(),
            arg(u(ShaderAst.depthTexture(), R3dUniform.ShadowMap)) :: arg(u(ShaderAst.mat4(), R3dUniform.ShadowMatrix)) :: arg(u(ShaderAst.float(), R3dUniform.ShadowBias)) ::
            arg(u(ShaderAst.int(), R3dUniform.ShadowPcf)) :: arg(f("0.0")) :: arg(ShaderAst.vec3Splat(f("0.0"))) :: arg(p) :: Nil);
        ShaderAst.function("spotShadow", ShaderAst.Ty.F32, pi :: pp :: Nil,
            ifInline(or_(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.ShadowOn), i(0)), ShaderAst.ne(index, u(ShaderAst.int(), R3dUniform.ShadowSpot))), ret(f("1.0"))) ::
            ret(sub(f("1.0"), mul(u(ShaderAst.float(), R3dUniform.ShadowStrength), paren(sub(f("1.0"), fraction))))) :: Nil)

    /// 光の式の木が読む太陽の影の割合（frag の main が先に代入する。ビルボードは 1 のまま）。
    pub def sunLit(): Definition = ShaderAst.privateVar("r3d_sunLit", ShaderAst.float(), None, Some(f("1.0")), None)

    /// 太陽の影の割合 sunLitAt(p, g, n)（Render3dGlsl.sunShadowSource の doc。CPU の描き手は SoftRaster3d.Sun.litAt）。
    // WhyNot: 太陽へ背を向けた点（n·l ≤ 0）で地図を引かない — facing が 0 なので結果は同じで、pcf の (2r+1)² 回が無駄になる。
    pub def sunLitAt(): Definition =
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let (pg, g1) = param(ShaderAst.vec3(), "g");
        let (pn, n) = param(ShaderAst.vec3(), "n");
        let sunDir = u(ShaderAst.vec3(), R3dUniform.SunDir);
        let sunFade = u(ShaderAst.vec2(), R3dUniform.SunFade);
        let (declF, fade) = let_("fade", clamp(div(paren(sub(x(sunFade), dot(sub(p, eye()), u(ShaderAst.vec3(), R3dUniform.SunForward)))), y(sunFade)), f("0.0"), f("1.0")));
        let fraction = call(ShaderAst.float(), shadowLitFraction(),
            arg(u(ShaderAst.depthTexture(), R3dUniform.SunMap)) :: arg(u(ShaderAst.mat4(), R3dUniform.SunMatrix)) :: arg(u(ShaderAst.float(), R3dUniform.SunBias)) ::
            arg(u(ShaderAst.int(), R3dUniform.SunPcf)) :: arg(u(ShaderAst.float(), R3dUniform.SunNormalShift)) :: arg(g1) :: arg(p) :: Nil);
        ShaderAst.function("sunLitAt", ShaderAst.Ty.F32, pp :: pg :: pn :: Nil,
            ifInline(or_(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.SunShadowOn), i(0)), le(dot(n, sunDir), f("0.0"))), ret(f("1.0"))) ::
            declF ::
            ifInline(le(fade, f("0.0")), ret(f("1.0"))) ::
            ret(sub(f("1.0"), mul(mul(u(ShaderAst.float(), R3dUniform.SunStrength), fade), paren(sub(f("1.0"), fraction))))) :: Nil)

    /// 光の式の木が読む点光源ごとの影の割合（frag の main が r3d_pointShadowsAt で埋める）。
    pub def pointLit(): Definition = ShaderAst.privateVar("r3d_pointLit", ShaderAst.float(), Some(Scene3d.maxPointLights()), None, None)

    /// 点光源 i の影の割合 r3d_pointShadowLit(i, p, g, n)（本文は LightModel3d.PointShadowCodegen が両方の言語で作る）。
    pub def pointShadowLit(): Definition =
        ShaderAst.externFunction({ name = "r3d_pointShadowLit", ret = ShaderAst.Ty.F32,
                                   params = ShaderAst.Ty.I32 :: ShaderAst.Ty.Vec3 :: ShaderAst.Ty.Vec3 :: ShaderAst.Ty.Vec3 :: Nil,
                                   glsl = Body.Text(LightModel3d.PointShadowCodegen.toGlsl()), wgsl = Body.Text(LightModel3d.PointShadowCodegen.toWgsl()),
                                   deps = Nil, derivative = false })

    /// 点光源の数だけ r3d_pointLit を埋める r3d_pointShadowsAt(p, g, n)。
    // WhyNot: 光の式の木の中で地図を引かない — PBR の材質は拡散と鏡面の 2 つのループを回し、1 本につき 2 回引くことになる。
    pub def pointShadowsAt(): Definition =
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let (pg, g1) = param(ShaderAst.vec3(), "g");
        let (pn, n) = param(ShaderAst.vec3(), "n");
        ShaderAst.function("r3d_pointShadowsAt", ShaderAst.Ty.Void, pp :: pg :: pn :: Nil,
            ShaderAst.for_("i", i(0), k -> lt(k, i(Scene3d.maxPointLights())), Layout.Inline, k ->
                ShaderAst.assign(ShaderAst.readGlobalAt(ShaderAst.float(), pointLit(), k),
                                 call(ShaderAst.float(), pointShadowLit(), arg(k) :: arg(p) :: arg(g1) :: arg(n) :: Nil)) :: Nil) :: Nil)
}
