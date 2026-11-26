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

    /// LightModel3d の木から作った関数 name（引数は inputs・返り値は vec3）。本文は LightModel3d.Codegen が両方の言語で、print する時に作る。
    /// key = 木を見分ける字（同じ名前で木の違う定義を見分ける。木の変種を入れる）。
    def treeFunction(name: String, key: String, inputs: List[LightModel3d.Vec3Input], tree: LightModel3d.Vec3Expr): Definition =
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.Vec3, params = inputs |> List.map(_ -> ShaderAst.Ty.Vec3),
                                   glsl = Body.Generated(name + key, lazy LightModel3d.Codegen.toGlsl(name, inputs, tree)),
                                   wgsl = Body.Generated(name + key, lazy LightModel3d.Codegen.toWgsl(name, inputs, tree)),
                                   deps = Nil, derivative = false })

    /// 変種 v の光の式の木を見分ける字（光の式の木を変える欄の +ps・+pu・+sh だけで決める）。
    def lightKeyOf(v: Render3d.ProgramKey.ShaderVariant): String =
        "/ps=${v#pointShadows}/pu=${v#physicalUnits}/sh=${v#skyIrradiance}"

    /// 変種 v の光の式 lightAt(点, 法線)。
    pub def lightAt(v: Render3d.ProgramKey.ShaderVariant): Definition =
        treeFunction("lightAt", lightKeyOf(v), LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: Nil,
                     LightModel3d.lightingModelFor(Render3d.ProgramKey.lightVariantOf(v)))

    /// かすみの式 fogAt(点, 色)。
    pub def fogAt(): Definition =
        treeFunction("fogAt", "", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Color :: Nil, LightModel3d.fogModel())

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
    // WhyNot: 極（向きが真上・真下）の atan を言語に任せない — 引数が両方 0 の atan は値が決まらない。Flix の atan2 は 0 を返すので、同じ 0 にそろえる。
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
                                   glsl = Body.Generated("r3d_pointShadowLit", lazy LightModel3d.PointShadowCodegen.toGlsl()), wgsl = Body.Generated("r3d_pointShadowLit", lazy LightModel3d.PointShadowCodegen.toWgsl()),
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

    // ── 材質の frag の部品（法線マップ・lightmap・環境マップ・光の式） ──

    def glslOf(e: Expr[t]): String = ShaderAst.Glsl.expression(e)

    def wgslOf(e: Expr[t]): String = ShaderAst.Wgsl.expression(e)

    /// 段つきの読み sg_texMip（本文は ShaderGen が両方の言語で作る）。inMaterial = 材質の部品が既に定義している（置かない）。
    // WhyNot: 引数の型を持たせない — GLSL は (絵, 上下の返し, 段の数, 座標)・WGSL は (絵, sampler, 段の数, 座標) で並びが違い、呼ぶ所は texMipRead の字で書く。
    def texMip(inMaterial: Bool): Definition =
        ShaderAst.externFunction({ name = "sg_texMip", ret = ShaderAst.Ty.Vec4, params = Nil,
                                   glsl = if (inMaterial) Body.Outside else Body.Text(ShaderGen.texMipSource()),
                                   wgsl = if (inMaterial) Body.Outside else Body.Text(ShaderGen.Wgsl.texMipSource()),
                                   deps = Nil, derivative = true })

    /// 絵 map を sg_texMip で段つきに読む式。glslFlip = GLSL の上下の返し（1 で v を返す）・wgslSampler = WGSL の sampler の名前・levels = 段の数・c = 座標。
    def texMipRead(inMaterial: Bool, map: R3dUniform, glslFlip: Expr[Float], wgslSampler: String, levels: Expr[Float], c: Expr[Vec2]): Expr[Vec4] =
        let tex = u(ShaderAst.texture(), map);
        let glsl = "sg_texMip(" + String.intercalate(", ", glslOf(tex) :: glslOf(glslFlip) :: glslOf(levels) :: glslOf(c) :: Nil) + ")";
        let wgsl = "sg_texMip(" + String.intercalate(", ", wgslOf(tex) :: wgslSampler :: wgslOf(levels) :: wgslOf(c) :: Nil) + ")";
        ShaderAst.rawExpr(ShaderAst.vec4(), glsl, wgsl, texMip(inMaterial) :: Nil, true)

    /// 外向きの法線 n を、uv で読んだ法線マップとタンジェント tangent で傾けた n'（applyNormalMap）。法線マップは段つきの Linear で読む。
    /// GLSL の uNormalFlip = 1 はレンダーターゲット（行 0 が下）で、v を上下反転して読む。inMaterial = 材質の部品が sg_texMip を定義しているか。
    // WhyNot: 絵を読むのをタンジェントの長さを見た後にしない — 読みの段を選ぶ微分（dFdx）は、画素ごとに分かれる if の中では値が決まらない。
    pub def normalMapped(inMaterial: Bool): Definition =
        let (pn, n) = param(ShaderAst.vec3(), "n");
        let (pu, uv) = param(ShaderAst.vec2(), "uv");
        let (pt, tangent) = param(ShaderAst.vec4(), "tangent");
        let texel = texMipRead(inMaterial, R3dUniform.NormalMap, u(ShaderAst.float(), R3dUniform.NormalFlip), "uNormalMapSampler",
                               u(ShaderAst.float(), R3dUniform.NormalLevels), uv);
        ShaderAst.function("normalMapped", ShaderAst.Ty.Vec3, pn :: pu :: pt :: Nil,
            ret(call(ShaderAst.vec3(), applyNormalMap(), arg(n) :: arg(tangent) :: arg(u(ShaderAst.float(), R3dUniform.NormalStrength)) :: arg(ShaderAst.rgb(texel)) :: Nil)) :: Nil)

    /// lightmap の色 lightmapColor(2 本目の uv)。段つきの Linear で読む（段は Lightmap の maxLevels まで）。2 本目の uv の絵は場面の textures だけから引くので上下の反転は無い。
    /// 読む uv = uv2 × uLightmapUvRect.zw + uLightmapUvRect.xy（Lightmap の uvRect）。
    // WhyNot: 矩形を頂点の式で当てない — WebGPU の物ごとの値（R3dDraw）は FRAGMENT からだけ見え、頂点で読むと layout の可視範囲と全部の材質の WGSL が変わる。GL も同じ所で当ててそろえる。
    pub def lightmapColor(inMaterial: Bool): Definition =
        let (pu, uv2) = param(ShaderAst.vec2(), "uv2");
        let rect = u(ShaderAst.vec4(), R3dUniform.LightmapUvRect);
        let texel = texMipRead(inMaterial, R3dUniform.Lightmap, f("0.0"), "uLightmapSampler", u(ShaderAst.float(), R3dUniform.LightmapLevels),
                               add(mul(uv2, ShaderAst.zw(rect)), ShaderAst.xy(rect)));
        ShaderAst.function("lightmapColor", ShaderAst.Ty.Vec3, pu :: Nil, ret(ShaderAst.rgb(texel)) :: Nil)

    /// lightmap のある面の光の式 lightmapLightAt(p, n, lightmap の色)（変種 v の LightModel3d の木から作る）。
    pub def lightmapLightAt(v: Render3d.ProgramKey.ShaderVariant): Definition =
        treeFunction("lightmapLightAt", lightKeyOf(v), LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.LightmapColor :: Nil,
                     LightModel3d.lightmapLightingModelFor(Render3d.ProgramKey.lightVariantOf(v)))

    /// 跳ね返りの向き environmentDirectionAt(p, n, albedo, metalRough)（LightModel3d.environmentDirection の木から作る）。
    pub def environmentDirectionAt(): Definition =
        treeFunction("environmentDirectionAt", "", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.Albedo ::
                                               LightModel3d.Vec3Input.MetallicRoughness :: Nil,
                     LightModel3d.environmentDirection())

    /// metallic と roughness を持つ材質の色 pbrAt(p, n, albedo × tint, 拡散の光, vec3(metallic, roughness, 0), 映り込み)（変種 v の LightModel3d.pbrModel の木から作る）。
    pub def pbrAt(v: Render3d.ProgramKey.ShaderVariant): Definition =
        treeFunction("pbrAt", lightKeyOf(v), LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.Albedo :: LightModel3d.Vec3Input.Light ::
                              LightModel3d.Vec3Input.MetallicRoughness :: LightModel3d.Vec3Input.EnvironmentColor :: Nil,
                     LightModel3d.pbrModelFor(Render3d.ProgramKey.lightVariantOf(v)))

    /// 跳ね返りの向きで環境マップの絵を読む environmentColorAt(p, n, albedo × tint, vec3(metallic, roughness, 0))（線形の量・強さを掛けた色。
    /// CPU の描き手は SoftRaster3d.Internal.environmentColorAt）。絵は向き → 座標（environmentUv）で、段は roughness × (段の数 − 1)（LightModel3d.environmentLodOf）を明示して読む。
    /// uEnvOn = 0 のプログラムは読まない（呼ぶ側が分ける）。
    // WhyNot: sg_texMip（微分で段を選ぶ読み）を使わない — 向きの atan2 は継ぎ目（u = 0 と 1）で値が 1 跳び、その画素だけ段が最大になって縦の筋が出る。
    pub def environmentColorAt(): Definition =
        let (pp, p) = param(ShaderAst.vec3(), "p");
        let (pn, n) = param(ShaderAst.vec3(), "n");
        let (pa, albedo) = param(ShaderAst.vec3(), "albedo");
        let (pm, metalRough) = param(ShaderAst.vec3(), "metalRough");
        let (declD, d) = let_("d", call(ShaderAst.vec3(), environmentDirectionAt(), arg(p) :: arg(n) :: arg(albedo) :: arg(metalRough) :: Nil));
        let (declL, lod) = let_("lod", mul(y(metalRough), paren(sub(u(ShaderAst.float(), R3dUniform.EnvLevels), f("1.0")))));
        let map = u(ShaderAst.texture(), R3dUniform.EnvMap);
        let uvOf = call(ShaderAst.vec2(), environmentUv(), arg(d) :: Nil);
        let texel = ShaderAst.rawExpr(ShaderAst.vec4(),
            "textureLod(" + String.intercalate(", ", glslOf(map) :: glslOf(uvOf) :: glslOf(lod) :: Nil) + ")",
            "textureSampleLevel(" + String.intercalate(", ", wgslOf(map) :: "uEnvSampler" :: wgslOf(uvOf) :: wgslOf(lod) :: Nil) + ")",
            environmentUv() :: Nil, false);
        let (declC, c) = let_("c", ShaderAst.rgb(texel));
        ShaderAst.function("environmentColorAt", ShaderAst.Ty.Vec3, pp :: pn :: pa :: pm :: Nil,
            declD :: declL :: declC ::
            ret(mulS(ternary(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.EnvSrgb), i(1)), toLinear3(c), c), u(ShaderAst.float(), R3dUniform.EnvIntensity))) :: Nil)

    // ── frag の入口（材質・頂点の色・奥行き） ──

    /// varying 1 つ。
    // WhyNot: flat の値を最後の頂点から取る形（GL の既定）にそろえない — WGSL の flat は最初の頂点を取るが、vTint と vEmissionIntensity は置いた物 1 つで同じ値。
    def varyingOf(name: String, ty: ShaderAst.Ty, location: Int32, interp: ShaderAst.Interp): ShaderAst.Varying =
        { name = name, ty = ty, location = location, interp = interp }

    // varying の表（location は WGSL の @location・頂点シェーダーの出口と同じ並び。GLSL は名前でつなぐ）。

    /// 画素の world の点。
    pub def worldVarying(): ShaderAst.Varying = varyingOf("vWorld", ShaderAst.Ty.Vec3, 0, ShaderAst.Interp.Smooth)

    /// 外向きの法線（長さは問わない）。
    pub def normalVarying(): ShaderAst.Varying = varyingOf("vNormal", ShaderAst.Ty.Vec3, 1, ShaderAst.Interp.Smooth)

    /// 頂点の色（材質は sRGB のまま・lit は線形へ戻し済み）。
    pub def colorVarying(): ShaderAst.Varying = varyingOf("vColor", ShaderAst.Ty.Vec3, 2, ShaderAst.Interp.Smooth)

    /// 1 体ごとの tint。
    pub def tintVarying(): ShaderAst.Varying = varyingOf("vTint", ShaderAst.Ty.Vec3, 3, ShaderAst.Interp.Flat)

    /// 1 体ごとの emission の強さ。
    pub def emissionIntensityVarying(): ShaderAst.Varying = varyingOf("vEmissionIntensity", ShaderAst.Ty.F32, 4, ShaderAst.Interp.Flat)

    /// uv（PS1 風でない uv つきの形）。
    pub def uvVarying(): ShaderAst.Varying = varyingOf("vUv", ShaderAst.Ty.Vec2, 5, ShaderAst.Interp.Smooth)

    /// PS1 風の uv つきの形の、遠近で補正する uv（uvVarying と同じ location）。
    pub def uvPerspectiveVarying(): ShaderAst.Varying = varyingOf("vUvPerspective", ShaderAst.Ty.Vec2, 5, ShaderAst.Interp.Smooth)

    /// 2 本目の uv（lightmap）。
    pub def uv2Varying(): ShaderAst.Varying = varyingOf("vUv2", ShaderAst.Ty.Vec2, 6, ShaderAst.Interp.Smooth)

    /// タンジェント（xyz と鏡写しの符号 w）。
    pub def tangentVarying(): ShaderAst.Varying = varyingOf("vTangent", ShaderAst.Ty.Vec4, 7, ShaderAst.Interp.Smooth)

    /// PS1 風の uv つきの形の、画面の上でまっすぐつなぐ uv。
    pub def uvAffineVarying(): ShaderAst.Varying = varyingOf("vUvAffine", ShaderAst.Ty.Vec2, 8, ShaderAst.Interp.Affine)

    /// 材質の部品のうち frag の本文が読む物: cutoutAlpha = cutout の判定の α（部品の字。materialEval の albedo を albedo の名前で読む）・
    /// readsTextures = 部品が sg_texMip を定義するか（絵を読む材質）。
    pub type alias MaterialPart = { cutoutAlpha = Expr[Float], readsTextures = Bool }

    /// GLSL の材質の部品 m の MaterialPart。
    pub def glslMaterialPart(m: ShaderGen.MaterialGlsl): MaterialPart =
        { cutoutAlpha = ShaderAst.rawExprIn(ShaderAst.float(), ShaderAst.Lang.Glsl, m#cutoutAlpha, Nil, false), readsTextures = not List.isEmpty(m#texReads) }

    /// WGSL の材質の部品 m の MaterialPart。
    pub def wgslMaterialPart(m: ShaderGen.Wgsl.MaterialWgsl): MaterialPart =
        { cutoutAlpha = ShaderAst.rawExprIn(ShaderAst.float(), ShaderAst.Lang.Wgsl, m#cutoutAlpha, Nil, false), readsTextures = not List.isEmpty(m#texReads) }

    /// uv つきで法線マップを当てる版か（uv の無い形は法線マップを読まない）。
    pub def isNormalMapped(surface: Render3d.ProgramKey.ProgramKind): Bool = surface#uv and surface#normalMap

    /// 材質の frag の本文が呼び、宣言の字が置く材質ごとの関数（法線マップの normalMapped・lightmap の lightmapColor）。
    pub def materialHelpers(surface: Render3d.ProgramKey.ProgramKind, part: MaterialPart): List[Definition] =
        (if (isNormalMapped(surface)) normalMapped(part#readsTextures) :: Nil else Nil) :::
        (if (surface#lightmap) lightmapColor(part#readsTextures) :: Nil else Nil)

    /// 材質の frag が受ける varying（uv・2 本目の uv・タンジェントは使う版だけ）。
    pub def materialInputs(surface: Render3d.ProgramKey.ProgramKind): List[ShaderAst.Varying] =
        let psxUv = surface#uv and Render3d.ProgramKey.shaderVariantOfKind(surface)#psx;
        (worldVarying() :: normalVarying() :: colorVarying() :: tintVarying() :: emissionIntensityVarying() :: Nil) :::
        (if (psxUv) uvPerspectiveVarying() :: Nil else if (surface#uv) uvVarying() :: Nil else Nil) :::
        (if (surface#lightmap) uv2Varying() :: Nil else Nil) :::
        (if (isNormalMapped(surface)) tangentVarying() :: Nil else Nil) :::
        (if (psxUv) uvAffineVarying() :: Nil else Nil)

    /// 頂点の色のプログラムの frag が受ける varying。
    pub def litInputs(): List[ShaderAst.Varying] = worldVarying() :: normalVarying() :: colorVarying() :: tintVarying() :: Nil

    /// 変種 v の frag の色の出口（v#psx なら r3d_colorDepth に通す）。
    def colorOut(v: Render3d.ProgramKey.ShaderVariant, c: Expr[Vec3]): Expr[Vec3] =
        if (v#psx) call(ShaderAst.vec3(), colorDepth(), arg(c) :: Nil) else c

    /// 光の計算の前に影の割合を埋める文（r3d_sunLit と、v#pointShadows なら r3d_pointLit）。p = 点・g1 = 点をずらす向きの法線・n = 光の計算の法線。
    def shadowsBeforeLight(v: Render3d.ProgramKey.ShaderVariant, p: Expr[Vec3], g1: Expr[Vec3], n: Expr[Vec3]): List[ShaderAst.Statement] =
        let args = arg(p) :: arg(g1) :: arg(n) :: Nil;
        assign(ShaderAst.readGlobal(ShaderAst.float(), sunLit()), call(ShaderAst.float(), sunLitAt(), args)) ::
        (if (v#pointShadows) ShaderAst.callStmt(pointShadowsAt(), args) :: Nil else Nil)

    /// 点 p の Output.Depth の灰色を出す文（andReturn なら出して抜ける）。
    def depthGrayOut(p: Expr[Vec3], andReturn: Bool): List[ShaderAst.Statement] =
        let (declG, gray) = let_("g", call(ShaderAst.float(), depthGray(), arg(p) :: Nil));
        let color = vec4Of(gray, gray, gray, f("1.0"));
        declG :: (if (andReturn) ShaderAst.emitAndReturn(color) else ShaderAst.emit(color)) :: Nil

    /// 材質の部品が名前で読む値（vWorld・vNormal・vColor・vUv）を置く文。psx の uv つきは、遠近で補正する uv と画面の上でまっすぐつなぐ uv を
    /// uPsx.w で混ぜた vUv（GLSL は大域の vec2 vUv へ代入し、uv の無い形は大域の const。どちらの宣言も周りの字）。
    def materialNames(surface: Render3d.ProgramKey.ProgramKind, v: Render3d.ProgramKey.ShaderVariant): List[ShaderAst.Statement] =
        let named = (worldVarying() :: normalVarying() :: colorVarying() :: Nil) |> List.map(ShaderAst.varyingAsLocal);
        let uv =
            if (surface#uv and v#psx) {
                let mixed = ShaderAst.mixS(ShaderAst.varying(ShaderAst.vec2(), uvPerspectiveVarying()), ShaderAst.varying(ShaderAst.vec2(), uvAffineVarying()), w(psx()));
                ShaderAst.rawStatement("vUv = " + glslOf(mixed) + ";", "let vUv = " + wgslOf(mixed) + ";")
            }
            else if (surface#uv) ShaderAst.varyingAsLocal(uvVarying())
            else ShaderAst.rawStatement("", "let vUv = " + wgslOf(vec2Of(f("0.0"), f("0.0"))) + ";");
        named ::: uv :: Nil

    /// 材質の部品の materialEval を呼び、albedo・emission（metallicRoughness なら metalRough も）を局所の値に置く文（GLSL は out の引数・WGSL は struct を返す）。
    def materialEval(metallicRoughness: Bool): ShaderAst.Statement =
        if (metallicRoughness)
            ShaderAst.rawStatement("vec4 albedo;\nvec3 emission;\nvec2 metalRough;\nmaterialEval(albedo, emission, metalRough);",
                                   "let material = materialEval(vUv, vWorld, vNormal, vColor);\nlet albedo = material.albedo;\nlet emission = material.emission;\nlet metalRough = material.metalRough;")
        else
            ShaderAst.rawStatement("vec4 albedo;\nvec3 emission;\nmaterialEval(albedo, emission);",
                                   "let material = materialEval(vUv, vWorld, vNormal, vColor);\nlet albedo = material.albedo;\nlet emission = material.emission;")

    /// cutout の材質か。
    // WhyNot: uniform の handle で読まない — GL の uCutout は int・WebGPU は物ごとの値の f32 で、比べ方が言語で違う。
    def cutoutOn(): Expr[Boolean] =
        ShaderAst.rawExpr(ShaderAst.boolean(), glslOf(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.Cutout), i(1))), "r3dDraw.uCutout > 0.5", Nil, false)

    /// 材質の frag の main の本文（材質の値 → cutout の discard → uDepthOut の枝 → 表裏 → 法線 → 影 → 光 → PBR → 出口）。
    /// 光の式は頂点の色のプログラムと同じで、頂点の色の代わりに materialEval の albedo を使う（頂点の色は材質の Spec が VertexColor で読む）。
    /// uDepthOut = 1 なら cutout で抜いた後の奥行きの灰色を書く（Output.Depth の cutout の材質）。
    /// surface#blend = 出す α を材質の α に（半透明）・surface#doubleSided = 裏の面は光の計算の法線を裏返す・surface#coverage = cutout を discard でなく alpha to coverage の α で抜く・
    /// surface#lightmap = ベイクした光を 2 本目の uv で読み、環境光と hemisphere の代わりに足す。
    pub def materialFragmentBody(surface: Render3d.ProgramKey.ProgramKind, part: MaterialPart): List[ShaderAst.Statement] =
        let v = Render3d.ProgramKey.shaderVariantOfKind(surface);
        let world = ShaderAst.varying(ShaderAst.vec3(), worldVarying());
        let outward = normalize(ShaderAst.varying(ShaderAst.vec3(), normalVarying()));
        let alpha = part#cutoutAlpha;
        let albedo = ShaderAst.ref(ShaderAst.vec4(), "albedo");
        let emission = ShaderAst.ref(ShaderAst.vec3(), "emission");
        let tint = ShaderAst.varying(ShaderAst.vec3(), tintVarying());
        let intensity = ShaderAst.varying(ShaderAst.float(), emissionIntensityVarying());
        let cutout = if (surface#coverage) Nil else ifInline(ShaderAst.and_(cutoutOn(), lt(alpha, f("0.5"))), ShaderAst.discard_()) :: Nil;
        let depthOut = ShaderAst.ifBlock(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.DepthOut), i(1)), depthGrayOut(world, true));
        let (declFacing, facing) = let_("facingNormal", ternary(ShaderAst.frontFacing(), outward, neg(outward)));
        let faceNormal = if (surface#doubleSided) facing else outward;
        let bent =
            if (isNormalMapped(surface))
                call(ShaderAst.vec3(), normalMapped(part#readsTextures),
                     arg(faceNormal) :: arg(ShaderAst.ref(ShaderAst.vec2(), "vUv")) :: arg(ShaderAst.varying(ShaderAst.vec4(), tangentVarying())) :: Nil)
            else faceNormal;
        let (declN, n) = let_("n", bent);
        let lightOf =
            if (surface#lightmap)
                call(ShaderAst.vec3(), lightmapLightAt(v),
                     arg(world) :: arg(n) :: arg(call(ShaderAst.vec3(), lightmapColor(part#readsTextures), arg(ShaderAst.varying(ShaderAst.vec2(), uv2Varying())) :: Nil)) :: Nil)
            else call(ShaderAst.vec3(), lightAt(v), arg(world) :: arg(n) :: Nil);
        let (declLight, light) = let_("light", lightOf);
        // WhyNot: alpha to coverage に絵の α をそのまま渡さない — ぼけた α の絵では縁が数画素の幅で透け、cutout の固い縁に見えない。
        let outAlpha =
            if (surface#coverage) clamp(add(div(paren(sub(alpha, f("0.5"))), ShaderAst.max(ShaderAst.fwidth(alpha), f("1e-4"))), f("0.5")), f("0.0"), f("1.0"))
            else if (surface#blend) ShaderAst.a(albedo)
            else f("1.0");
        let toScreen = (c: Expr[Vec3]) -> ShaderAst.emit(ShaderAst.vec4FromVec3(colorOut(v, c), outAlpha));
        let shade =
            if (surface#metallicRoughness) {
                let (declBase, base) = let_("base", mul(toLinear3(ShaderAst.rgb(albedo)), tint));
                let metalRough = ShaderAst.vec3FromVec2(ShaderAst.ref(ShaderAst.vec2(), "metalRough"), f("0.0"));
                let (declEnv, env) = var_("envColor", ShaderAst.vec3Splat(f("0.0")));
                let readEnv = ifInline(ShaderAst.eq(u(ShaderAst.int(), R3dUniform.EnvOn), i(1)),
                                       assign(env, call(ShaderAst.vec3(), environmentColorAt(), arg(world) :: arg(n) :: arg(base) :: arg(metalRough) :: Nil)));
                let (declLit, lit) = let_("lit", call(ShaderAst.vec3(), pbrAt(v), arg(world) :: arg(n) :: arg(base) :: arg(light) :: arg(metalRough) :: arg(env) :: Nil));
                declBase :: declEnv :: readEnv :: declLit ::
                toScreen(call(ShaderAst.vec3(), surfaceOutLit(), arg(lit) :: arg(emission) :: arg(intensity) :: arg(world) :: Nil)) :: Nil
            }
            else
                toScreen(call(ShaderAst.vec3(), surfaceOut(),
                              arg(toLinear3(ShaderAst.rgb(albedo))) :: arg(tint) :: arg(light) :: arg(emission) :: arg(intensity) :: arg(world) :: arg(ShaderAst.bool(true)) :: Nil)) :: Nil;
        materialNames(surface, v) ::: (materialEval(surface#metallicRoughness) :: Nil) ::: cutout ::: (depthOut :: Nil) :::
        (if (surface#doubleSided) declFacing :: Nil else Nil) ::: (declN :: Nil) ::: shadowsBeforeLight(v, world, faceNormal, n) ::: (declLight :: Nil) ::: shade

    /// 頂点の色のプログラムの frag の main の本文（vColor は頂点シェーダーが線形へ戻し済み）。
    pub def litFragmentBody(v: Render3d.ProgramKey.ShaderVariant): List[ShaderAst.Statement] =
        let world = ShaderAst.varying(ShaderAst.vec3(), worldVarying());
        let (declN, n) = let_("n", normalize(ShaderAst.varying(ShaderAst.vec3(), normalVarying())));
        let color = call(ShaderAst.vec3(), surfaceOut(),
                         arg(ShaderAst.varying(ShaderAst.vec3(), colorVarying())) :: arg(ShaderAst.varying(ShaderAst.vec3(), tintVarying())) ::
                         arg(call(ShaderAst.vec3(), lightAt(v), arg(world) :: arg(n) :: Nil)) :: arg(ShaderAst.vec3Splat(f("0.0"))) :: arg(f("1.0")) ::
                         arg(world) :: arg(ShaderAst.bool(true)) :: Nil);
        (declN :: Nil) ::: shadowsBeforeLight(v, world, n, n) ::: (ShaderAst.emit(ShaderAst.vec4FromVec3(colorOut(v, color), f("1.0"))) :: Nil)

    /// 材質の frag の入口（宣言の字は言語ごと。GL の描き手は GLSL・WebGPU の描き手は WGSL だけを渡す）。
    pub def materialFragment(surface: Render3d.ProgramKey.ProgramKind, part: MaterialPart, glslDeclarations: String, wgslDeclarations: String): ShaderAst.FragmentEntry =
        { inputName = "R3dIn", glslDeclarations = glslDeclarations, wgslDeclarations = wgslDeclarations,
          inputs = materialInputs(surface), body = materialFragmentBody(surface, part) }

    /// 頂点の色のプログラムの frag の入口。
    pub def litFragment(v: Render3d.ProgramKey.ShaderVariant, glslDeclarations: String, wgslDeclarations: String): ShaderAst.FragmentEntry =
        { inputName = "R3dLitIn", glslDeclarations = glslDeclarations, wgslDeclarations = wgslDeclarations, inputs = litInputs(), body = litFragmentBody(v) }

    /// 奥行きの書き出し（Output.Depth）の形だけの frag の入口（読む varying は vWorld だけ）。
    pub def depthFragment(glslDeclarations: String, wgslDeclarations: String): ShaderAst.FragmentEntry =
        { inputName = "R3dDepthIn", glslDeclarations = glslDeclarations, wgslDeclarations = wgslDeclarations,
          inputs = worldVarying() :: Nil, body = depthGrayOut(ShaderAst.varying(ShaderAst.vec3(), worldVarying()), false) }
}
