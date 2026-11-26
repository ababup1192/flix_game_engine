// Render3dShaders — 3D の描き手のシェーダーの関数を ShaderAst で 1 回だけ書いた物（GLSL は Render3dGlsl・WGSL は Render3dWgsl が print する）。
// 式の約束（色の空間・法線マップ・PS1 風の丸め）は Render3d.flix の頭と Render3dGlsl の doc。CPU の描き手（SoftRaster3d）が 3 本目で、gl-parity が同じ値かを確かめる。
pub mod Render3dShaders {
    use ShaderAst.{Expr, Definition, Float, Vec2, Vec3, Vec4, IVec2, Int, Boolean, Tex, DepthTex, Mat4, Body, Layout}
    use Render3d.Uniforms.R3dUniform
    use ShaderAst.{f, i, add, sub, mul, div, addS, mulS, divS, lt, le, or_, neg, paren, ternary, at,
                   x, y, z, w, r, g, b, xyz, vec2Of, vec3Of, vec4Of, ivec2Of, floor, abs, normalize, asin, dot, cross, distance, atan2,
                   clamp, clampS, let_, var_, assign, ifInline, ret, param, call, arg, uniform, bitAnd}

    // ── uniform ──

    /// handle u の uniform を、型のマーカー w1 で読む。
    def u(w1: ShaderAst.TyWitness[t], h: R3dUniform): Expr[t] with ShaderAst.Marker[t] = uniform(w1, Render3d.Uniforms.refOf(h))

    /// 目の位置。
    pub def eye(): Expr[Vec3] = u(Vec3.Vec3, R3dUniform.Eye)

    /// Output.Depth の灰色の (near, range)。
    pub def depthRange(): Expr[Vec2] = u(Vec2.Vec2, R3dUniform.DepthRange)

    /// PS1 風の (色のレベルの数, 表の番号, ディザの強さ, アフィンの割合)。
    pub def psx(): Expr[Vec4] = u(Vec4.Vec4, R3dUniform.Psx)

    /// 場面の描き先の矩形 (左下の x, y, 幅, 高さ)（GLSL だけ。WGSL の画素の位置は場面の描き先の左上が 0）。
    pub def psxTargetRect(): ShaderAst.UniformRef = Render3d.Uniforms.refOf(R3dUniform.PsxTarget)

    /// 頂点を丸める格子の大きさ（画素。0 で丸めない）。
    pub def vertexSnapGrid(): Expr[Float] = u(Float.Float, R3dUniform.VertexSnap)

    /// 言語ごとに置き場の違う値を読む uniform（GLSL は glslBase の glslSwizzle・宣言の型 glslType、WGSL は wgslBase の wgslSwizzle）。
    // WhyNot: handle の表（Render3d.Uniforms）に足さない — 同じ GLSL の uniform を WGSL では別の struct の別の欄の w などに詰めてあり、表の 1 行が 1 つの読み方しか持てない。
    def pairedRef(ty: ShaderAst.Ty, glslBase: String, glslSwizzle: String, glslType: String, wgslBase: String, wgslSwizzle: String): ShaderAst.UniformRef =
        { name = glslBase, ty = ty, glsl = Some({ base = glslBase, swizzle = glslSwizzle }), wgsl = Some({ base = wgslBase, swizzle = wgslSwizzle }),
          glslType = glslType, length = None }

    /// 場面の描き先の幅と高さ（画素。GLSL は描き先の矩形の zw・WGSL はカメラの値の uSnap の xy）。
    pub def vertexSnapTarget(): Expr[Vec2] = uniform(Vec2.Vec2, pairedRef(ShaderAst.Ty.Vec2, "uPsxTarget", "zw", "vec4", "r3dCamera.uSnap", "xy"))

    // ── 色の空間 ──

    def scalarColor(name: String, glsl: String -> String, wgsl: String -> String): Definition =
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.F32, params = ShaderAst.Ty.F32 :: Nil, glsl = Body.Text(glsl(name)), wgsl = Body.Text(wgsl(name)),
                           deps = Nil, derivative = false })

    /// sRGB の値 1 つを線形へ（式は Texture3d が両方の言語で作る）。
    pub def srgbToLinear(): Definition = scalarColor("r3d_srgbToLinear", Texture3d.srgbToLinearGlsl, Texture3d.srgbToLinearWgsl)

    /// 線形の値 1 つを sRGB へ。
    pub def linearToSrgb(): Definition = scalarColor("r3d_linearToSrgb", Texture3d.linearToSrgbGlsl, Texture3d.linearToSrgbWgsl)

    def perChannel(name: String, scalar: Definition): Definition =
        let (pc, c) = param(Vec3.Vec3, "c");
        let one = (v: Expr[Float]) -> call(Float.Float, scalar, arg(v) :: Nil);
        ShaderAst.function(name, ShaderAst.Ty.Vec3, pc :: Nil, ret(vec3Of(one(r(c)), one(g(c)), one(b(c)))) :: Nil)

    /// vec3 の sRGB → 線形。
    pub def srgbToLinear3(): Definition = perChannel("r3d_srgbToLinear3", srgbToLinear())

    /// vec3 の線形 → sRGB。
    pub def linearToSrgb3(): Definition = perChannel("r3d_linearToSrgb3", linearToSrgb())

    /// 色の空間の 4 つの関数（スカラーの 2 つ → vec3 の 2 つの順）。
    pub def colorSpace(): List[Definition] = srgbToLinear() :: linearToSrgb() :: srgbToLinear3() :: linearToSrgb3() :: Nil

    // ── 色を作る最後の組み立て ──

    /// LightModel3d の生成した字 text の本文。読む定義は reads のうち名前が字に出てくる物・GLSL の uniform は字に出てくる handle の表の名前。
    // WhyNot: 木が読む uniform と定義を手で並べない — 木の変種（+pu・+sh・+ps）と木の種類ごとに読む物が違い、並べ忘れは GLSL のコンパイルまで気づけない。
    def generatedBody(key: String, lang: ShaderAst.Lang, text: Lazy[String], reads: List[Definition]): Body =
        Body.Generated(key, lazy ShaderAst.generatedText(force text, reads, if (lang == ShaderAst.Lang.Glsl) Render3d.Uniforms.namedRefs() else Nil))

    /// LightModel3d の木から作った関数 name（引数は inputs・返り値は vec3）。本文は LightModel3d.Codegen が両方の言語で、print する時に作る。
    /// key = 木を見分ける字（同じ名前で木の違う定義を見分ける。木の変種を入れる）・reads = 木の字が読みうる定義（スポットの影・影の割合の大域の値・色の空間）。
    def treeFunction(name: String, key: String, inputs: List[LightModel3d.Vec3Input], tree: LightModel3d.Vec3Expr, reads: List[Definition]): Definition =
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.Vec3, params = inputs |> List.map(_ -> ShaderAst.Ty.Vec3),
                                   glsl = generatedBody(name + key, ShaderAst.Lang.Glsl, lazy LightModel3d.Codegen.toGlsl(name, inputs, tree), reads),
                                   wgsl = generatedBody(name + key, ShaderAst.Lang.Wgsl, lazy LightModel3d.Codegen.toWgsl(name, inputs, tree), reads),
                                   deps = Nil, derivative = false })

    /// 光の式の木の字が読みうる定義（spot = スポット i の光に掛ける割合の関数）。
    def lightReads(spot: Definition): List[Definition] = spot :: sunLit() :: pointLit() :: colorSpace()

    /// 変種 v の光の式の木を見分ける字（光の式の木を変える欄の +ps・+pu・+sh だけで決める）。
    def lightKeyOf(v: Render3d.ProgramKey.ShaderVariant): String =
        "/ps=${v#pointShadows}/pu=${v#physicalUnits}/sh=${v#skyIrradiance}"

    /// 変種 v の光の式 lightAt(点, 法線)（spot = スポットの影の割合の関数）。
    pub def lightAt(v: Render3d.ProgramKey.ShaderVariant, spot: Definition): Definition =
        treeFunction("lightAt", lightKeyOf(v), LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: Nil,
                     LightModel3d.lightingModelFor(Render3d.ProgramKey.lightVariantOf(v)), lightReads(spot))

    /// かすみの式 fogAt(点, 色)。
    pub def fogAt(): Definition =
        treeFunction("fogAt", "", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Color :: Nil, LightModel3d.fogModel(), Nil)

    /// 空の色の式 skyAt(向き)。
    pub def skyAt(): Definition =
        treeFunction("skyAt", "", LightModel3d.Vec3Input.SkyDirection :: Nil, LightModel3d.skyModel(), Nil)

    /// かすみ fogged(色, 点)（uFogOn = 0 なら色のまま）。
    pub def fogged(): Definition =
        let (pc, c) = param(Vec3.Vec3, "c");
        let (pp, p) = param(Vec3.Vec3, "p");
        ShaderAst.function("fogged", ShaderAst.Ty.Vec3, pc :: pp :: Nil,
            ifInline(ShaderAst.eq(u(Int.Int, R3dUniform.FogOn), i(0)), ret(c)) ::
            ret(call(Vec3.Vec3, fogAt(), arg(p) :: arg(c) :: Nil)) :: Nil)

    def toLinear3(v: Expr[Vec3]): Expr[Vec3] = call(Vec3.Vec3, srgbToLinear3(), arg(v) :: Nil)

    def toSrgb3(v: Expr[Vec3]): Expr[Vec3] = call(Vec3.Vec3, linearToSrgb3(), arg(v) :: Nil)

    /// 色 = albedoLinear × tint × light（fogOn ならかすみ）+ 線形へ戻した emission × intensity を、画面の値へ戻した物（Render3dGlsl.surfaceOutSource の doc）。
    pub def surfaceOut(): Definition =
        let (pa, albedo) = param(Vec3.Vec3, "albedoLinear");
        let (pt, tint) = param(Vec3.Vec3, "tint");
        let (pl, light) = param(Vec3.Vec3, "light");
        let (pe, emission) = param(Vec3.Vec3, "emission");
        let (pi, intensity) = param(Float.Float, "intensity");
        let (pp, p) = param(Vec3.Vec3, "p");
        let (pf, fogOn) = param(Boolean.Boolean, "fogOn");
        let (declC, c) = var_("c", mul(mul(albedo, tint), light));
        ShaderAst.function("r3d_surfaceOut", ShaderAst.Ty.Vec3, pa :: pt :: pl :: pe :: pi :: pp :: pf :: Nil,
            declC ::
            ifInline(fogOn, assign(c, call(Vec3.Vec3, fogged(), arg(c) :: arg(p) :: Nil))) ::
            ret(toSrgb3(add(c, mulS(toLinear3(emission), intensity)))) :: Nil)

    /// PBR の色をかすみに通してから emission を足して画面の値へ戻す（Render3dGlsl.metallicRoughnessSource の doc）。
    pub def surfaceOutLit(): Definition =
        let (pl, lit) = param(Vec3.Vec3, "lit");
        let (pe, emission) = param(Vec3.Vec3, "emission");
        let (pi, intensity) = param(Float.Float, "intensity");
        let (pp, p) = param(Vec3.Vec3, "p");
        let (declC, c) = let_("c", call(Vec3.Vec3, fogged(), arg(lit) :: arg(p) :: Nil));
        ShaderAst.function("r3d_surfaceOutLit", ShaderAst.Ty.Vec3, pl :: pe :: pi :: pp :: Nil,
            declC :: ret(toSrgb3(add(c, mulS(toLinear3(emission), intensity)))) :: Nil)

    // ── 法線マップ・環境マップ・奥行き ──

    /// 外向きの法線 n をタンジェントと法線マップの rgb c で傾ける（Render3dGlsl.applyNormalMapSource の doc）。
    // WhyNot: 最後の normalize を If の文にしない — select は両側を計算するが、長さ 0 の側の NaN は捨てられる。
    pub def applyNormalMap(): Definition =
        let (pn, n) = param(Vec3.Vec3, "n");
        let (pt, tangent) = param(Vec4.Vec4, "tangent");
        let (ps, strength) = param(Float.Float, "strength");
        let (pc, c) = param(Vec3.Vec3, "c");
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
        let (pd, d) = param(Vec3.Vec3, "d");
        let pole = paren(lt(add(abs(x(d)), abs(z(d))), f("1e-12")));
        let (declA, azimuth) = let_("azimuth", ternary(pole, f("0.0"), atan2(x(d), neg(z(d)))));
        ShaderAst.function("environmentUv", ShaderAst.Ty.Vec2, pd :: Nil,
            declA ::
            ret(vec2Of(add(f("0.5"), div(azimuth, f("6.283185307179586"))),
                       sub(f("0.5"), div(asin(clamp(y(d), f("-1.0"), f("1.0"))), f("3.141592653589793"))))) :: Nil)

    /// Output.Depth の灰色（目からの距離で near が黒・near + range が白）。
    pub def depthGray(): Definition =
        let (pp, p) = param(Vec3.Vec3, "p");
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
        let (pp, p) = param(IVec2.IVec2, "p");
        let (declI, idx) = let_("i", add(mul(paren(bitAnd(y(p), i(3))), i(4)), paren(bitAnd(x(p), i(3)))));
        ShaderAst.function("r3d_psxDither", ShaderAst.Ty.F32, pp :: Nil,
            declI ::
            ifInline(lt(y(psx()), f("0.5")), ret(div(at(psxTable(), idx), f("8.0")))) ::
            ifInline(lt(y(psx()), f("1.5")), ret(sub(div(paren(add(at(bayerTable(), idx), f("0.5"))), f("16.0")), f("0.5")))) ::
            ret(f("0.0")) :: Nil)

    /// PS1 風の色の丸め r3d_colorDepth(画面の値の色)（式は Scene3d.Psx.quantize・CPU の描き手は SoftRaster3d.Psx.quantized）。
    pub def colorDepth(): Definition =
        let (pc, c) = param(Vec3.Vec3, "c");
        let (declP, p) = let_("p", ShaderAst.pixelFromTopLeft(psxTargetRect()));
        let (declS, step) = let_("step", div(f("256.0"), paren(add(x(psx()), f("1.0")))));
        let dither = call(Float.Float, psxDither(), arg(p) :: Nil);
        let (declV, v) = let_("v", addS(floor(addS(mulS(clampS(c, f("0.0"), f("1.0")), f("255.0")), f("0.5"))), mul(mul(dither, z(psx())), step)));
        ShaderAst.function("r3d_colorDepth", ShaderAst.Ty.Vec3, pc :: Nil,
            ifInline(le(x(psx()), f("0.0")), ret(c)) ::
            declP :: declS :: declV ::
            ret(divS(floor(divS(clampS(v, f("0.0"), f("255.0")), step)), x(psx()))) :: Nil)

    /// PS1 風の頂点を丸める式 r3d_vertexSnap(clip の位置)（CPU の描き手は SoftRaster3d.Psx.snapVertex）。
    /// x・y を描き先の左上を 0 とする画素へ写して格子の一番近い点へ丸め、clip へ戻す（z と w は変えない）。
    // WhyNot: w が 0 以下（目の後ろ）の頂点を丸めない — 画素へ写せず、GPU が手前の面で切る前の形を壊す。
    pub def vertexSnap(): Definition =
        let (pp, p) = param(Vec4.Vec4, "p");
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

    /// 影の地図 map の PCF で、点 p（法線 n の向きへ shift ずらす）が光を受ける割合（Scene3d.shadowMatrix の doc の約束 1〜5）。
    // WhyNot: 周りの画素を返した後の行で端にそろえない — 端にそろえる（clamp）のを GL の行で済ませてから返せば、CPU の描き手と同じ画素の組を読む。
    pub def shadowLitFraction(): Definition =
        let (pm, map) = param(DepthTex.DepthTex, "map");
        let (pl, lightMatrix) = param(Mat4.Mat4, "lightMatrix");
        let (pb, bias) = param(Float.Float, "bias");
        let (pk, pcf) = param(Int.Int, "pcf");
        let (ps, shift) = param(Float.Float, "shift");
        let (pn, n) = param(Vec3.Vec3, "n");
        let (pp, p) = param(Vec3.Vec3, "p");
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
        let (pi, index) = param(Int.Int, "i");
        let (pp, p) = param(Vec3.Vec3, "p");
        let fraction = call(Float.Float, shadowLitFraction(),
            arg(u(DepthTex.DepthTex, R3dUniform.ShadowMap)) :: arg(u(Mat4.Mat4, R3dUniform.ShadowMatrix)) :: arg(u(Float.Float, R3dUniform.ShadowBias)) ::
            arg(u(Int.Int, R3dUniform.ShadowPcf)) :: arg(f("0.0")) :: arg(ShaderAst.vec3Splat(f("0.0"))) :: arg(p) :: Nil);
        ShaderAst.function("spotShadow", ShaderAst.Ty.F32, pi :: pp :: Nil,
            ifInline(or_(ShaderAst.eq(u(Int.Int, R3dUniform.ShadowOn), i(0)), ShaderAst.ne(index, u(Int.Int, R3dUniform.ShadowSpot))), ret(f("1.0"))) ::
            ret(sub(f("1.0"), mul(u(Float.Float, R3dUniform.ShadowStrength), paren(sub(f("1.0"), fraction))))) :: Nil)

    /// 光の式の木が読む太陽の影の割合（frag の main が先に代入する。ビルボードは 1 のまま）。
    pub def sunLit(): Definition = ShaderAst.privateVar("r3d_sunLit", Float.Float, None, Some(f("1.0")), None)

    /// 太陽の影の割合 sunLitAt(p, g, n)（Scene3d.directionalShadowOf の doc の約束。CPU の描き手は SoftRaster3d.Sun.litAt）。
    // WhyNot: 太陽へ背を向けた点（n·l ≤ 0）で地図を引かない — facing が 0 なので結果は同じで、pcf の (2r+1)² 回が無駄になる。
    pub def sunLitAt(): Definition =
        let (pp, p) = param(Vec3.Vec3, "p");
        let (pg, g1) = param(Vec3.Vec3, "g");
        let (pn, n) = param(Vec3.Vec3, "n");
        let sunDir = u(Vec3.Vec3, R3dUniform.SunDir);
        let sunFade = u(Vec2.Vec2, R3dUniform.SunFade);
        let (declF, fade) = let_("fade", clamp(div(paren(sub(x(sunFade), dot(sub(p, eye()), u(Vec3.Vec3, R3dUniform.SunForward)))), y(sunFade)), f("0.0"), f("1.0")));
        let fraction = call(Float.Float, shadowLitFraction(),
            arg(u(DepthTex.DepthTex, R3dUniform.SunMap)) :: arg(u(Mat4.Mat4, R3dUniform.SunMatrix)) :: arg(u(Float.Float, R3dUniform.SunBias)) ::
            arg(u(Int.Int, R3dUniform.SunPcf)) :: arg(u(Float.Float, R3dUniform.SunNormalShift)) :: arg(g1) :: arg(p) :: Nil);
        ShaderAst.function("sunLitAt", ShaderAst.Ty.F32, pp :: pg :: pn :: Nil,
            ifInline(or_(ShaderAst.eq(u(Int.Int, R3dUniform.SunShadowOn), i(0)), le(dot(n, sunDir), f("0.0"))), ret(f("1.0"))) ::
            declF ::
            ifInline(le(fade, f("0.0")), ret(f("1.0"))) ::
            ret(sub(f("1.0"), mul(mul(u(Float.Float, R3dUniform.SunStrength), fade), paren(sub(f("1.0"), fraction))))) :: Nil)

    /// 光の式の木が読む点光源ごとの影の割合（frag の main が r3d_pointShadowsAt で埋める）。
    pub def pointLit(): Definition = ShaderAst.privateVar("r3d_pointLit", Float.Float, Some(Scene3d.maxPointLights()), None, None)

    /// 点光源 i の影の割合 r3d_pointShadowLit(i, p, g, n)（本文は LightModel3d.PointShadowCodegen が両方の言語で作る）。
    pub def pointShadowLit(): Definition =
        ShaderAst.externFunction({ name = "r3d_pointShadowLit", ret = ShaderAst.Ty.F32,
                                   params = ShaderAst.Ty.I32 :: ShaderAst.Ty.Vec3 :: ShaderAst.Ty.Vec3 :: ShaderAst.Ty.Vec3 :: Nil,
                                   glsl = generatedBody("r3d_pointShadowLit", ShaderAst.Lang.Glsl, lazy LightModel3d.PointShadowCodegen.toGlsl(), Nil),
                                   wgsl = generatedBody("r3d_pointShadowLit", ShaderAst.Lang.Wgsl, lazy LightModel3d.PointShadowCodegen.toWgsl(), Nil),
                                   deps = Nil, derivative = false })

    /// 点光源の数だけ r3d_pointLit を埋める r3d_pointShadowsAt(p, g, n)。
    // WhyNot: 光の式の木の中で地図を引かない — PBR の材質は拡散と鏡面の 2 つのループを回し、1 本につき 2 回引くことになる。
    pub def pointShadowsAt(): Definition =
        let (pp, p) = param(Vec3.Vec3, "p");
        let (pg, g1) = param(Vec3.Vec3, "g");
        let (pn, n) = param(Vec3.Vec3, "n");
        ShaderAst.function("r3d_pointShadowsAt", ShaderAst.Ty.Void, pp :: pg :: pn :: Nil,
            ShaderAst.for_("i", i(0), k -> lt(k, i(Scene3d.maxPointLights())), Layout.Inline, k ->
                ShaderAst.assign(ShaderAst.readGlobalAt(Float.Float, pointLit(), k),
                                 call(Float.Float, pointShadowLit(), arg(k) :: arg(p) :: arg(g1) :: arg(n) :: Nil)) :: Nil) :: Nil)

    // ── 材質の frag の部品（法線マップ・lightmap・環境マップ・光の式） ──

    /// 段つきの読み sg_texMip（本文は ShaderGen が両方の言語で作る）。絵を読む材質は部品 part#definition が定義している（置かず、部品を先に並べる）。
    // WhyNot: 引数の型を持たせない — GLSL は (絵, 上下の返し, 段の数, 座標)・WGSL は (絵, sampler, 段の数, 座標) で並びが違い、呼ぶ所は texMipRead の字で書く。
    def texMip(part: MaterialPart): Definition =
        ShaderAst.externFunction({ name = "sg_texMip", ret = ShaderAst.Ty.Vec4, params = Nil,
                                   glsl = if (part#readsTextures) Body.Outside else Body.Text(ShaderGen.texMipSource()),
                                   wgsl = if (part#readsTextures) Body.Outside else Body.Text(ShaderGen.Wgsl.texMipSource()),
                                   deps = if (part#readsTextures) part#definition :: Nil else Nil, derivative = true })

    /// 絵 map を sg_texMip で段つきに読む式。glslFlip = GLSL の上下の返し（1 で v を返す）・wgslSampler = WGSL の sampler の名前・levels = 段の数・c = 座標。
    def texMipRead(part: MaterialPart, map: R3dUniform, glslFlip: Expr[Float], wgslSampler: String, levels: Expr[Float], c: Expr[Vec2]): Expr[Vec4] =
        let tex = arg(u(Tex.Tex, map));
        ShaderAst.callIn(Vec4.Vec4, "sg_texMip", tex :: arg(glslFlip) :: arg(levels) :: arg(c) :: Nil,
                         "sg_texMip", tex :: ShaderAst.samplerArg(wgslSampler) :: arg(levels) :: arg(c) :: Nil, texMip(part) :: Nil, true)

    /// 外向きの法線 n を、uv で読んだ法線マップとタンジェント tangent で傾けた n'（applyNormalMap）。法線マップは段つきの Linear で読む。
    /// GLSL の uNormalFlip = 1 はレンダーターゲット（行 0 が下）で、v を上下反転して読む。part = 材質の部品（sg_texMip を定義しているか）。
    // WhyNot: 絵を読むのをタンジェントの長さを見た後にしない — 読みの段を選ぶ微分（dFdx）は、画素ごとに分かれる if の中では値が決まらない。
    pub def normalMapped(part: MaterialPart): Definition =
        let (pn, n) = param(Vec3.Vec3, "n");
        let (pu, uv) = param(Vec2.Vec2, "uv");
        let (pt, tangent) = param(Vec4.Vec4, "tangent");
        let texel = texMipRead(part, R3dUniform.NormalMap, u(Float.Float, R3dUniform.NormalFlip), "uNormalMapSampler",
                               u(Float.Float, R3dUniform.NormalLevels), uv);
        ShaderAst.function("normalMapped", ShaderAst.Ty.Vec3, pn :: pu :: pt :: Nil,
            ret(call(Vec3.Vec3, applyNormalMap(), arg(n) :: arg(tangent) :: arg(u(Float.Float, R3dUniform.NormalStrength)) :: arg(ShaderAst.rgb(texel)) :: Nil)) :: Nil)

    /// lightmap の色 lightmapColor(2 本目の uv)。段つきの Linear で読む（段は Lightmap の maxLevels まで）。2 本目の uv の絵は場面の textures だけから引くので上下の反転は無い。
    /// 読む uv = uv2 × uLightmapUvRect.zw + uLightmapUvRect.xy（Lightmap の uvRect）。
    // WhyNot: 矩形を頂点の式で当てない — WebGPU の物ごとの値（R3dDraw）は FRAGMENT からだけ見え、頂点で読むと layout の可視範囲と全部の材質の WGSL が変わる。GL も同じ所で当ててそろえる。
    pub def lightmapColor(part: MaterialPart): Definition =
        let (pu, uv2) = param(Vec2.Vec2, "uv2");
        let rect = u(Vec4.Vec4, R3dUniform.LightmapUvRect);
        let texel = texMipRead(part, R3dUniform.Lightmap, f("0.0"), "uLightmapSampler", u(Float.Float, R3dUniform.LightmapLevels),
                               add(mul(uv2, ShaderAst.zw(rect)), ShaderAst.xy(rect)));
        ShaderAst.function("lightmapColor", ShaderAst.Ty.Vec3, pu :: Nil, ret(ShaderAst.rgb(texel)) :: Nil)

    /// lightmap のある面の光の式 lightmapLightAt(p, n, lightmap の色)（変種 v の LightModel3d の木から作る。spot = スポットの影の割合の関数）。
    pub def lightmapLightAt(v: Render3d.ProgramKey.ShaderVariant, spot: Definition): Definition =
        treeFunction("lightmapLightAt", lightKeyOf(v), LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.LightmapColor :: Nil,
                     LightModel3d.lightmapLightingModelFor(Render3d.ProgramKey.lightVariantOf(v)), lightReads(spot))

    /// 跳ね返りの向き environmentDirectionAt(p, n, albedo, metalRough)（LightModel3d.environmentDirection の木から作る）。
    pub def environmentDirectionAt(): Definition =
        treeFunction("environmentDirectionAt", "", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.Albedo ::
                                               LightModel3d.Vec3Input.MetallicRoughness :: Nil,
                     LightModel3d.environmentDirection(), Nil)

    /// metallic と roughness を持つ材質の色 pbrAt(p, n, albedo × tint, 拡散の光, vec3(metallic, roughness, 0), 映り込み)（変種 v の LightModel3d.pbrModel の木から作る。
    /// spot = スポットの影の割合の関数）。
    pub def pbrAt(v: Render3d.ProgramKey.ShaderVariant, spot: Definition): Definition =
        treeFunction("pbrAt", lightKeyOf(v), LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.Albedo :: LightModel3d.Vec3Input.Light ::
                              LightModel3d.Vec3Input.MetallicRoughness :: LightModel3d.Vec3Input.EnvironmentColor :: Nil,
                     LightModel3d.pbrModelFor(Render3d.ProgramKey.lightVariantOf(v)), lightReads(spot))

    /// 跳ね返りの向きで環境マップの絵を読む environmentColorAt(p, n, albedo × tint, vec3(metallic, roughness, 0))（線形の量・強さを掛けた色。
    /// CPU の描き手は SoftRaster3d.Internal.environmentColorAt）。絵は向き → 座標（environmentUv）で、段は roughness × (段の数 − 1)（LightModel3d.environmentLodOf）を明示して読む。
    /// uEnvOn = 0 のプログラムは読まない（呼ぶ側が分ける）。
    // WhyNot: sg_texMip（微分で段を選ぶ読み）を使わない — 向きの atan2 は継ぎ目（u = 0 と 1）で値が 1 跳び、その画素だけ段が最大になって縦の筋が出る。
    pub def environmentColorAt(): Definition =
        let (pp, p) = param(Vec3.Vec3, "p");
        let (pn, n) = param(Vec3.Vec3, "n");
        let (pa, albedo) = param(Vec3.Vec3, "albedo");
        let (pm, metalRough) = param(Vec3.Vec3, "metalRough");
        let (declD, d) = let_("d", call(Vec3.Vec3, environmentDirectionAt(), arg(p) :: arg(n) :: arg(albedo) :: arg(metalRough) :: Nil));
        let (declL, lod) = let_("lod", mul(y(metalRough), paren(sub(u(Float.Float, R3dUniform.EnvLevels), f("1.0")))));
        let map = u(Tex.Tex, R3dUniform.EnvMap);
        let uvOf = call(Vec2.Vec2, environmentUv(), arg(d) :: Nil);
        let texel = ShaderAst.callIn(Vec4.Vec4, "textureLod", arg(map) :: arg(uvOf) :: arg(lod) :: Nil,
                                     "textureSampleLevel", arg(map) :: ShaderAst.samplerArg("uEnvSampler") :: arg(uvOf) :: arg(lod) :: Nil, Nil, false);
        let (declC, c) = let_("c", ShaderAst.rgb(texel));
        ShaderAst.function("environmentColorAt", ShaderAst.Ty.Vec3, pp :: pn :: pa :: pm :: Nil,
            declD :: declL :: declC ::
            ret(mulS(ternary(ShaderAst.eq(u(Int.Int, R3dUniform.EnvSrgb), i(1)), toLinear3(c), c), u(Float.Float, R3dUniform.EnvIntensity))) :: Nil)

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

    /// 材質の部品: definition = 部品の字（GLSL は uniform と関数・WGSL は binding の宣言と関数。片方の言語の本文だけを持つ）・
    /// cutoutAlpha = cutout の判定の α（部品の字。materialEval の albedo を albedo の名前で読む）・readsTextures = 部品が sg_texMip を定義するか（絵を読む材質）。
    pub type alias MaterialPart = { definition = Definition, cutoutAlpha = Expr[Float], readsTextures = Bool }

    /// 片方の言語 lang だけの本文 text の定義（もう片方の言語では print すると止める）。deps = 先に並べる定義。
    def partIn(lang: ShaderAst.Lang, name: String, text: String, deps: List[Definition]): Definition =
        let (glsl, wgsl) = if (lang == ShaderAst.Lang.Glsl) (Body.Text(text), Body.Missing) else (Body.Missing, Body.Text(text));
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.Void, params = Nil, glsl = glsl, wgsl = wgsl, deps = deps, derivative = false })

    /// WGSL だけの宣言の字 text の定義（GLSL では何も置かない）。WebGPU の binding の宣言。
    pub def wgslDeclarations(name: String, text: String): Definition =
        ShaderAst.externFunction({ name = name, ret = ShaderAst.Ty.Void, params = Nil, glsl = Body.Outside, wgsl = Body.Text(text), deps = Nil, derivative = false })

    /// GLSL の材質の部品が名前で読む大域の vUv（uv つきの形は in の varying なので置かない・PS1 風の uv つきは main の頭で代入する変数・uv の無い形は (0, 0)）。
    def glslUvGlobal(surface: Render3d.ProgramKey.ProgramKind): List[Definition] =
        if (surface#uv and surface#variant#psx) partIn(ShaderAst.Lang.Glsl, "vUv", "vec2 vUv;\n", Nil) :: Nil
        else if (surface#uv) Nil
        else partIn(ShaderAst.Lang.Glsl, "vUv", "const vec2 vUv = vec2(0.0, 0.0);\n", Nil) :: Nil

    def materialPartOf(lang: ShaderAst.Lang, text: String, cutoutAlpha: String, readsTextures: Bool, deps: List[Definition]): MaterialPart =
        let definition = partIn(lang, "r3d_material", text, deps);
        { definition = definition, cutoutAlpha = ShaderAst.rawExprIn(Float.Float, lang, cutoutAlpha, definition :: Nil, false), readsTextures = readsTextures }

    /// GLSL の材質の部品 m の MaterialPart（surface の vUv の置き方を部品の前に置く）。
    pub def glslMaterialPart(m: ShaderGen.MaterialGlsl, surface: Render3d.ProgramKey.ProgramKind): MaterialPart =
        materialPartOf(ShaderAst.Lang.Glsl, m#uniforms + m#functions, m#cutoutAlpha, not List.isEmpty(m#texReads), glslUvGlobal(surface))

    /// WGSL の材質の部品 m の MaterialPart。
    pub def wgslMaterialPart(m: ShaderGen.Wgsl.MaterialWgsl): MaterialPart =
        materialPartOf(ShaderAst.Lang.Wgsl, m#declarations + m#functions, m#cutoutAlpha, not List.isEmpty(m#texReads), Nil)

    /// uv つきで法線マップを当てる版か（uv の無い形は法線マップを読まない）。
    pub def isNormalMapped(surface: Render3d.ProgramKey.ProgramKind): Bool = surface#uv and surface#normalMap

    /// 材質の frag が受ける varying（uv・2 本目の uv・タンジェントは使う版だけ）。
    pub def materialInputs(surface: Render3d.ProgramKey.ProgramKind): List[ShaderAst.Varying] =
        let psxUv = surface#uv and surface#variant#psx;
        (worldVarying() :: normalVarying() :: colorVarying() :: tintVarying() :: emissionIntensityVarying() :: Nil) :::
        (if (psxUv) uvPerspectiveVarying() :: Nil else if (surface#uv) uvVarying() :: Nil else Nil) :::
        (if (surface#lightmap) uv2Varying() :: Nil else Nil) :::
        (if (isNormalMapped(surface)) tangentVarying() :: Nil else Nil) :::
        (if (psxUv) uvAffineVarying() :: Nil else Nil)

    /// 頂点の色のプログラムの frag が受ける varying。
    pub def litInputs(): List[ShaderAst.Varying] = worldVarying() :: normalVarying() :: colorVarying() :: tintVarying() :: Nil

    // ── feature の関数（変種のフラグが名前のある点に差し込む物） ──

    /// 光の計算の前の点: point = 点・shift = 点をずらす向きの法線（法線マップを当てる前・裏の面は裏返した物）・normal = 光の計算の法線。
    pub type alias LightPoint = { point = Expr[Vec3], shift = Expr[Vec3], normal = Expr[Vec3] }

    /// シェーダーの名前のある点ごとの差し込み（木 → 木）。declarations = 光の式の定義の並びを差し替える・beforeLight = 光の計算の前の文を差し替える・
    /// colorOut = 画面の値の色を出す前に通す式・spotShadow = スポットの影の割合の関数を差し替える・clipOut = vertex が出す clip の位置（GL の clip）を通す式。
    pub type alias ShaderFeature = { declarations = List[Definition] -> List[Definition], beforeLight = (LightPoint, List[ShaderAst.Statement]) -> List[ShaderAst.Statement],
                                     colorOut = Expr[Vec3] -> Expr[Vec3], spotShadow = Definition -> Definition, clipOut = Expr[Vec4] -> Expr[Vec4] }

    /// 何も差し込まない feature。
    pub def noFeature(): ShaderFeature =
        { declarations = ds -> ds, beforeLight = (_, ss) -> ss, colorOut = c -> c, spotShadow = d -> d, clipOut = c -> c }

    /// 点光源の影（+ps）: 光の計算の前に r3d_pointShadowsAt で r3d_pointLit を埋める。
    pub def pointShadowsFeature(): ShaderFeature =
        { declarations = ds -> ds ::: pointShadowsAt() :: Nil,
          beforeLight = (at, ss) -> ss ::: ShaderAst.callStmt(pointShadowsAt(), arg(at#point) :: arg(at#shift) :: arg(at#normal) :: Nil) :: Nil | noFeature() }

    /// PS1 風（+psx）: 出す色を r3d_colorDepth で丸め、clip の位置を r3d_vertexSnap で丸める。
    pub def psxFeature(): ShaderFeature =
        { declarations = ds -> ds ::: colorDepth() :: Nil, colorOut = c -> call(Vec3.Vec3, colorDepth(), arg(c) :: Nil),
          clipOut = c -> call(Vec4.Vec4, vertexSnap(), arg(c) :: Nil) | noFeature() }

    /// スポットの影を受けない（ビルボード）: spotShadow をいつも 1 の spotShadowUnlit に差し替える。
    // WhyNot: スポットの影の on の uniform を 0 にしてスポットの影を切らない — WebGPU の場面の group 0 は同じ場面の物の影の地図と on を持ち、ビルボードだけ値を替える binding が無い。
    pub def noSpotShadowFeature(): ShaderFeature = { spotShadow = _ -> spotShadowUnlit() | noFeature() }

    /// a の後に b を当てる feature。
    def andThen(a1: ShaderFeature, b1: ShaderFeature): ShaderFeature =
        { declarations = ds -> b1#declarations(a1#declarations(ds)), beforeLight = (at, ss) -> b1#beforeLight(at, a1#beforeLight(at, ss)),
          colorOut = c -> b1#colorOut(a1#colorOut(c)), spotShadow = d -> b1#spotShadow(a1#spotShadow(d)), clipOut = c -> b1#clipOut(a1#clipOut(c)) }

    /// 変種 v の feature（表の行の順に当てる）。
    pub def featureOf(v: Render3d.ProgramKey.ShaderVariant): ShaderFeature =
        Render3d.ProgramKey.rowsOf(v) |> List.foldLeft((acc, row) -> andThen(acc, row#feature), noFeature())

    /// スポットの影を受けないプログラムの spotShadow（いつも 1）。
    pub def spotShadowUnlit(): Definition =
        let (pi, _) = param(Int.Int, "i");
        let (pp, _) = param(Vec3.Vec3, "p");
        ShaderAst.function("spotShadow", ShaderAst.Ty.F32, pi :: pp :: Nil, ret(f("1.0")) :: Nil)

    /// 光の式と、それと一緒に置く定義（太陽の影の割合 sunLitAt・かすみ・色を作る最後の組み立て。feature の declarations を足す）。
    pub def lightDefinitions(v: Render3d.ProgramKey.ShaderVariant, feature: ShaderFeature): List[Definition] =
        feature#declarations(sunLitAt() :: lightAt(v, feature#spotShadow(spotShadow())) :: fogged() :: surfaceOut() :: Nil)

    /// metallic と roughness を持つ材質の色 pbrAt と、それと一緒に置く定義（環境マップの読み・かすみ → emission の組み立て）。
    pub def metallicRoughnessDefinitions(v: Render3d.ProgramKey.ShaderVariant, feature: ShaderFeature): List[Definition] =
        environmentColorAt() :: pbrAt(v, feature#spotShadow(spotShadow())) :: surfaceOutLit() :: Nil

    /// 光の計算の前に影の割合を埋める文（r3d_sunLit と feature の beforeLight）。
    def shadowsBeforeLight(feature: ShaderFeature, at: LightPoint): List[ShaderAst.Statement] =
        feature#beforeLight(at, assign(ShaderAst.readGlobal(Float.Float, sunLit()), call(Float.Float, sunLitAt(), arg(at#point) :: arg(at#shift) :: arg(at#normal) :: Nil)) :: Nil)

    /// 点 p の Output.Depth の灰色を出す文（andReturn なら出して抜ける）。
    def depthGrayOut(p: Expr[Vec3], andReturn: Bool): List[ShaderAst.Statement] =
        let (declG, gray) = let_("g", call(Float.Float, depthGray(), arg(p) :: Nil));
        let color = vec4Of(gray, gray, gray, f("1.0"));
        declG :: (if (andReturn) ShaderAst.emitAndReturn(color) else ShaderAst.emit(color)) :: Nil

    /// 材質の部品が名前で読む値（vWorld・vNormal・vColor・vUv）を置く文。psx の uv つきは、遠近で補正する uv と画面の上でまっすぐつなぐ uv を
    /// uPsx.w で混ぜた vUv（GLSL は大域の vUv へ代入・WGSL は局所の値。uv の無い形の GLSL は大域の const）。
    def materialNames(surface: Render3d.ProgramKey.ProgramKind): List[ShaderAst.Statement] =
        let named = (worldVarying() :: normalVarying() :: colorVarying() :: Nil) |> List.map(ShaderAst.varyingAsLocal);
        let uv =
            if (surface#uv and surface#variant#psx)
                ShaderAst.headed("vUv = ", "let vUv = ",
                    ShaderAst.mixS(ShaderAst.varying(Vec2.Vec2, uvPerspectiveVarying()), ShaderAst.varying(Vec2.Vec2, uvAffineVarying()), w(psx())))
            else if (surface#uv) ShaderAst.varyingAsLocal(uvVarying())
            else ShaderAst.onlyIn(ShaderAst.Lang.Wgsl, fst(let_("vUv", vec2Of(f("0.0"), f("0.0")))) :: Nil);
        named ::: uv :: Nil

    /// 材質の部品の materialEval を呼び、albedo・emission（metallicRoughness なら metalRough も）を局所の値に置く文（GLSL は out の引数・WGSL は struct を返す）。
    // WhyNot: 木の call で書かない — ShaderGen の部品の materialEval は GLSL では out の引数で返し、WGSL では struct を返すので、1 つの呼び方の形にならない。
    def materialEval(metallicRoughness: Bool): ShaderAst.Statement =
        if (metallicRoughness)
            ShaderAst.rawStatement("vec4 albedo;\nvec3 emission;\nvec2 metalRough;\nmaterialEval(albedo, emission, metalRough);",
                                   "let material = materialEval(vUv, vWorld, vNormal, vColor);\nlet albedo = material.albedo;\nlet emission = material.emission;\nlet metalRough = material.metalRough;")
        else
            ShaderAst.rawStatement("vec4 albedo;\nvec3 emission;\nmaterialEval(albedo, emission);",
                                   "let material = materialEval(vUv, vWorld, vNormal, vColor);\nlet albedo = material.albedo;\nlet emission = material.emission;")

    /// 材質の frag の main の本文（材質の値 → cutout の discard → uDepthOut の枝 → 表裏 → 法線 → 影 → 光 → PBR → 出口）。
    /// 光の式は頂点の色のプログラムと同じで、頂点の色の代わりに materialEval の albedo を使う（頂点の色は材質の Spec が VertexColor で読む）。
    /// uDepthOut = 1 なら cutout で抜いた後の奥行きの灰色を書く（Output.Depth の cutout の材質）。
    /// surface#blend = 出す α を材質の α に（半透明）・surface#doubleSided = 裏の面は光の計算の法線を裏返す・surface#coverage = cutout を discard でなく alpha to coverage の α で抜く・
    /// surface#lightmap = ベイクした光を 2 本目の uv で読み、環境光と hemisphere の代わりに足す。
    pub def materialFragmentBody(surface: Render3d.ProgramKey.ProgramKind, part: MaterialPart): List[ShaderAst.Statement] =
        let v = surface#variant;
        let feature = featureOf(v);
        let spot = feature#spotShadow(spotShadow());
        let world = ShaderAst.varying(Vec3.Vec3, worldVarying());
        let outward = normalize(ShaderAst.varying(Vec3.Vec3, normalVarying()));
        let alpha = part#cutoutAlpha;
        let albedo = ShaderAst.ref(Vec4.Vec4, "albedo");
        let emission = ShaderAst.ref(Vec3.Vec3, "emission");
        let tint = ShaderAst.varying(Vec3.Vec3, tintVarying());
        let intensity = ShaderAst.varying(Float.Float, emissionIntensityVarying());
        let cutout = if (surface#coverage) Nil else ifInline(ShaderAst.and_(u(Boolean.Boolean, R3dUniform.Cutout), lt(alpha, f("0.5"))), ShaderAst.discard_()) :: Nil;
        let depthOut = ShaderAst.ifBlock(ShaderAst.eq(u(Int.Int, R3dUniform.DepthOut), i(1)), depthGrayOut(world, true));
        let (declFacing, facing) = let_("facingNormal", ternary(ShaderAst.frontFacing(), outward, neg(outward)));
        let faceNormal = if (surface#doubleSided) facing else outward;
        let bent =
            if (isNormalMapped(surface))
                call(Vec3.Vec3, normalMapped(part),
                     arg(faceNormal) :: arg(ShaderAst.ref(Vec2.Vec2, "vUv")) :: arg(ShaderAst.varying(Vec4.Vec4, tangentVarying())) :: Nil)
            else faceNormal;
        let (declN, n) = let_("n", bent);
        let lightOf =
            if (surface#lightmap)
                call(Vec3.Vec3, lightmapLightAt(v, spot),
                     arg(world) :: arg(n) :: arg(call(Vec3.Vec3, lightmapColor(part), arg(ShaderAst.varying(Vec2.Vec2, uv2Varying())) :: Nil)) :: Nil)
            else call(Vec3.Vec3, lightAt(v, spot), arg(world) :: arg(n) :: Nil);
        let (declLight, light) = let_("light", lightOf);
        // WhyNot: alpha to coverage に絵の α をそのまま渡さない — ぼけた α の絵では縁が数画素の幅で透け、cutout の固い縁に見えない。
        let outAlpha =
            if (surface#coverage) clamp(add(div(paren(sub(alpha, f("0.5"))), ShaderAst.max(ShaderAst.fwidth(alpha), f("1e-4"))), f("0.5")), f("0.0"), f("1.0"))
            else if (surface#blend) ShaderAst.a(albedo)
            else f("1.0");
        let toScreen = (c: Expr[Vec3]) -> ShaderAst.emit(ShaderAst.vec4FromVec3(feature#colorOut(c), outAlpha));
        let shade =
            if (surface#metallicRoughness) {
                let (declBase, base) = let_("base", mul(toLinear3(ShaderAst.rgb(albedo)), tint));
                let metalRough = ShaderAst.vec3FromVec2(ShaderAst.ref(Vec2.Vec2, "metalRough"), f("0.0"));
                let (declEnv, env) = var_("envColor", ShaderAst.vec3Splat(f("0.0")));
                let readEnv = ifInline(ShaderAst.eq(u(Int.Int, R3dUniform.EnvOn), i(1)),
                                       assign(env, call(Vec3.Vec3, environmentColorAt(), arg(world) :: arg(n) :: arg(base) :: arg(metalRough) :: Nil)));
                let (declLit, lit) = let_("lit", call(Vec3.Vec3, pbrAt(v, spot), arg(world) :: arg(n) :: arg(base) :: arg(light) :: arg(metalRough) :: arg(env) :: Nil));
                declBase :: declEnv :: readEnv :: declLit ::
                toScreen(call(Vec3.Vec3, surfaceOutLit(), arg(lit) :: arg(emission) :: arg(intensity) :: arg(world) :: Nil)) :: Nil
            }
            else
                toScreen(call(Vec3.Vec3, surfaceOut(),
                              arg(toLinear3(ShaderAst.rgb(albedo))) :: arg(tint) :: arg(light) :: arg(emission) :: arg(intensity) :: arg(world) :: arg(ShaderAst.bool(true)) :: Nil)) :: Nil;
        materialNames(surface) ::: (materialEval(surface#metallicRoughness) :: Nil) ::: cutout ::: (depthOut :: Nil) :::
        (if (surface#doubleSided) declFacing :: Nil else Nil) ::: (declN :: Nil) ::: shadowsBeforeLight(feature, { point = world, shift = faceNormal, normal = n }) :::
        (declLight :: Nil) ::: shade

    /// 頂点の色のプログラムの frag の main の本文（vColor は頂点シェーダーが線形へ戻し済み）。
    pub def litFragmentBody(v: Render3d.ProgramKey.ShaderVariant): List[ShaderAst.Statement] =
        let feature = featureOf(v);
        let world = ShaderAst.varying(Vec3.Vec3, worldVarying());
        let (declN, n) = let_("n", normalize(ShaderAst.varying(Vec3.Vec3, normalVarying())));
        let color = call(Vec3.Vec3, surfaceOut(),
                         arg(ShaderAst.varying(Vec3.Vec3, colorVarying())) :: arg(ShaderAst.varying(Vec3.Vec3, tintVarying())) ::
                         arg(call(Vec3.Vec3, lightAt(v, feature#spotShadow(spotShadow())), arg(world) :: arg(n) :: Nil)) :: arg(ShaderAst.vec3Splat(f("0.0"))) :: arg(f("1.0")) ::
                         arg(world) :: arg(ShaderAst.bool(true)) :: Nil);
        (declN :: Nil) ::: shadowsBeforeLight(feature, { point = world, shift = n, normal = n }) :::
        (ShaderAst.emit(ShaderAst.vec4FromVec3(feature#colorOut(color), f("1.0"))) :: Nil)

    /// 材質の frag の入口。bindings = WGSL の binding の宣言（wgslDeclarations。GL の描き手は空）。
    pub def materialFragment(surface: Render3d.ProgramKey.ProgramKind, part: MaterialPart, bindings: List[Definition]): ShaderAst.FragmentEntry =
        { inputName = "R3dIn", declarations = bindings ::: part#definition :: Nil, inputs = materialInputs(surface), body = materialFragmentBody(surface, part), writesColor = true }

    /// 頂点の色のプログラムの frag の入口。
    pub def litFragment(v: Render3d.ProgramKey.ShaderVariant, bindings: List[Definition]): ShaderAst.FragmentEntry =
        { inputName = "R3dLitIn", declarations = bindings, inputs = litInputs(), body = litFragmentBody(v), writesColor = true }

    /// 奥行きの書き出し（Output.Depth）の形だけの frag の入口（読む varying は vWorld だけ）。
    pub def depthFragment(bindings: List[Definition]): ShaderAst.FragmentEntry =
        { inputName = "R3dDepthIn", declarations = bindings, inputs = worldVarying() :: Nil, body = depthGrayOut(ShaderAst.varying(Vec3.Vec3, worldVarying()), false),
          writesColor = true }

    // ── ビルボード ──

    /// 貼る絵 uImage を uv で読む式（GLSL は texture・WGSL は 2D の描き手の絵の sampler uImageSampler で textureSample）。
    def imageTexel(uv: Expr[Vec2]): Expr[Vec4] =
        let image = arg(u(Tex.Tex, R3dUniform.Image));
        ShaderAst.callIn(Vec4.Vec4, "texture", image :: arg(uv) :: Nil, "textureSample", image :: ShaderAst.samplerArg("uImageSampler") :: arg(uv) :: Nil, Nil, true)

    /// 板ごとの値の属性 index 番目（並びは Render3d.SceneList.billboardValueFloats。GLSL は四角の角が location 0 なので 1 から・WGSL は角を頂点の番号で引くので 0 から）。
    def billboardAttribute(name: String, index: Int32): ShaderAst.Attribute =
        { name = name, ty = ShaderAst.Ty.Vec4, glslLocation = Some(index + 1), wgslLocation = Some(index) }

    // ビルボードの varying の表（vertex と frag で共有。location は WGSL の @location）。

    /// 貼る範囲の uv。
    pub def billboardUvVarying(): ShaderAst.Varying = varyingOf("vUv", ShaderAst.Ty.Vec2, 1, ShaderAst.Interp.Smooth)

    /// 板の tint。
    def billboardTintVarying(): ShaderAst.Varying = varyingOf("vTint", ShaderAst.Ty.Vec3, 2, ShaderAst.Interp.Flat)

    /// 光の当て方（Render3d.SceneList.billboardValueFloats の 0 = 当てない・1 = 当てる・2 = 当てて太陽の影も受ける）。
    // WhyNot: WGSL だけ f32 で送って 0.5・1.5 と比べない — 整数の flat な varying は両方の言語にあり、同じ型にそろえると比べ方を言語で分けずに済む。
    def billboardLitVarying(): ShaderAst.Varying = varyingOf("vLit", ShaderAst.Ty.I32, 3, ShaderAst.Interp.Flat)

    /// 板の向き（カメラへ向く向き・光の計算の法線）。
    // WhyNot: GL だけ frag の uniform で読まない — WebGPU のカメラの値はvertex shader だけから見え、frag で読むと layout の可視範囲が変わる。GL も同じ varying にそろえる。
    def billboardFacingVarying(): ShaderAst.Varying = varyingOf("vFacing", ShaderAst.Ty.Vec3, 4, ShaderAst.Interp.Flat)

    /// 太陽の影を受ける点を太陽の方へ進める前の点（Scene3d.billboardShadowPointOf）。
    def billboardShadowBaseVarying(): ShaderAst.Varying = varyingOf("vShadowBase", ShaderAst.Ty.Vec3, 5, ShaderAst.Interp.Smooth)

    /// 太陽の影を受ける点を板から水平に離す長さ。
    def billboardShadowOffsetVarying(): ShaderAst.Varying = varyingOf("vShadowOffset", ShaderAst.Ty.F32, 6, ShaderAst.Interp.Flat)

    /// ビルボードの varying の表。
    pub def billboardVaryings(): List[ShaderAst.Varying] =
        worldVarying() :: billboardUvVarying() :: billboardTintVarying() :: billboardLitVarying() :: billboardFacingVarying() ::
        billboardShadowBaseVarying() :: billboardShadowOffsetVarying() :: Nil

    /// 板の横の向き: Camera = カメラの right・PerBillboard = 板ごとの値の tint の欄（点光源の影の面）・ByUniform = uRightPerBillboard が 1 なら板ごとの値・0 ならカメラの right。
    // WhyNot: GL も板ごとの横の向きを別のプログラムにしない — GL は色の pass と影の地図の pass で 1 つのビルボードのプログラムを共有し、分けるとプログラムと location の表が 1 組増える。
    // WhyNot: WebGPU で uniform の欄を足して切り替えない — 影の地図の pass ごとに別の pipeline を持ち、別のシェーダーにすればカメラの値の struct の並びを変えずに済む。
    pub enum BillboardRight with Eq { case Camera, PerBillboard, ByUniform }

    /// ビルボードの vertex の入口（四角の角 quadCorner を、カメラの up と right の向き（right）で立てる。v の feature の clipOut で clip の位置を通す）。
    /// bindings = WGSL のカメラの値の宣言（GL の描き手は空）。
    pub def billboardVertex(v: Render3d.ProgramKey.ShaderVariant, right: BillboardRight, bindings: List[Definition]): ShaderAst.VertexEntry =
        let centerLit = billboardAttribute("aCenterLit", 0);
        let anchorSize = billboardAttribute("aAnchorSize", 1);
        let uvRect = billboardAttribute("aUvRect", 2);
        let tintOffset = billboardAttribute("aTintOffset", 3);
        let centerLitIn = ShaderAst.attribute(Vec4.Vec4, centerLit);
        let anchorSizeIn = ShaderAst.attribute(Vec4.Vec4, anchorSize);
        let uvRectIn = ShaderAst.attribute(Vec4.Vec4, uvRect);
        let tintOffsetIn = ShaderAst.attribute(Vec4.Vec4, tintOffset);
        let perBillboard = xyz(tintOffsetIn);
        let cameraRight = u(Vec3.Vec3, R3dUniform.Right);
        let (declCorner, corner) = let_("corner", ShaderAst.quadCorner());
        let (declCenter, center) = let_("center", xyz(centerLitIn));
        let (declAnchor, anchor) = let_("anchor", ShaderAst.xy(anchorSizeIn));
        let (declSize, size) = let_("size", ShaderAst.zw(anchorSizeIn));
        let sideOf = match right {
            case BillboardRight.Camera       => cameraRight
            case BillboardRight.PerBillboard => perBillboard
            case BillboardRight.ByUniform    => ternary(ShaderAst.eq(u(Int.Int, R3dUniform.RightPerBillboard), i(1)), perBillboard, cameraRight)
        };
        let (declRight, side) = let_("right", sideOf);
        let height = mul(sub(y(anchor), y(corner)), y(size));
        let (declWorld, world) = let_("world", add(add(center, mulS(side, mul(sub(x(corner), x(anchor)), x(size)))), mulS(u(Vec3.Vec3, R3dUniform.Up), height)));
        let clip = ShaderAst.mulMV(ShaderAst.mulMM(u(Mat4.Mat4, R3dUniform.Proj), u(Mat4.Mat4, R3dUniform.View)), ShaderAst.vec4FromVec3(world, f("1.0")));
        { inputName = "R3dBillboardIn", outputName = "R3dBillboardOut", declarations = bindings,
          attributes = centerLit :: anchorSize :: uvRect :: tintOffset :: Nil, outputs = billboardVaryings(),
          body = declCorner :: declCenter :: declAnchor :: declSize :: declRight :: declWorld ::
                 ShaderAst.output(worldVarying(), world) ::
                 ShaderAst.output(billboardUvVarying(), add(ShaderAst.xy(uvRectIn), mul(corner, ShaderAst.zw(uvRectIn)))) ::
                 ShaderAst.output(billboardShadowBaseVarying(), add(center, vec3Of(f("0.0"), height, f("0.0")))) ::
                 ShaderAst.output(billboardTintVarying(), perBillboard) ::
                 ShaderAst.output(billboardLitVarying(), ShaderAst.toInt(add(w(centerLitIn), f("0.5")))) ::
                 ShaderAst.output(billboardShadowOffsetVarying(), w(tintOffsetIn)) ::
                 ShaderAst.output(billboardFacingVarying(), u(Vec3.Vec3, R3dUniform.Facing)) ::
                 ShaderAst.clipOut(featureOf(v)#clipOut(clip)) :: Nil }

    /// ビルボードの frag の入口（billboardVariantOf(v) の変種。点光源の影とスポットの影は受けない）。光の当て方が 2 なら太陽の影を受け、受ける点は vShadowBase を
    /// 太陽の方へ vShadowOffset / max(太陽への向きの水平の長さ, Scene3d.billboardShadowMinFlat()) だけ進めた点。
    /// 影の地図に描く時（GL の Render3d.Shadow）は uDepthOut = 1 で、α で捨てた後に灰色を出して返る（影の地図の描き先に色は無い）。bindings = WGSL の binding の宣言（GL の描き手は空）。
    pub def billboardFragment(v: Render3d.ProgramKey.ShaderVariant, bindings: List[Definition]): ShaderAst.FragmentEntry =
        let bv = Render3d.ProgramKey.billboardVariantOf(v);
        let feature = andThen(featureOf(bv), noSpotShadowFeature());
        let world = ShaderAst.varying(Vec3.Vec3, worldVarying());
        let lit = ShaderAst.varying(Int.Int, billboardLitVarying());
        let facing = normalize(ShaderAst.varying(Vec3.Vec3, billboardFacingVarying()));
        let sunDir = u(Vec3.Vec3, R3dUniform.SunDir);
        let (declTexel, texel) = let_("texel", imageTexel(ShaderAst.varying(Vec2.Vec2, billboardUvVarying())));
        let shift = div(ShaderAst.varying(Float.Float, billboardShadowOffsetVarying()), ShaderAst.max(ShaderAst.length(ShaderAst.xz(sunDir)), f("${Scene3d.billboardShadowMinFlat()}")));
        let shadowPoint = add(ShaderAst.varying(Vec3.Vec3, billboardShadowBaseVarying()), mulS(sunDir, shift));
        let (declLit, litOn) = let_("lit", ShaderAst.ge(lit, i(1)));
        let (declLight, light) = var_("light", ShaderAst.vec3Splat(f("1.0")));
        let color = call(Vec3.Vec3, surfaceOut(), arg(toLinear3(ShaderAst.rgb(texel))) :: arg(ShaderAst.varying(Vec3.Vec3, billboardTintVarying())) :: arg(light) ::
                         arg(ShaderAst.vec3Splat(f("0.0"))) :: arg(f("1.0")) :: arg(world) :: arg(litOn) :: Nil);
        { inputName = "R3dBillboardIn", declarations = bindings, inputs = billboardVaryings(), writesColor = true,
          body = declTexel ::
                 ifInline(lt(ShaderAst.a(texel), f("0.5")), ShaderAst.discard_()) ::
                 ShaderAst.ifBlock(ShaderAst.eq(u(Int.Int, R3dUniform.DepthOut), i(1)), depthGrayOut(world, true)) ::
                 declLit ::
                 ifInline(ShaderAst.eq(lit, i(2)), assign(ShaderAst.readGlobal(Float.Float, sunLit()), call(Float.Float, sunLitAt(), arg(shadowPoint) :: arg(sunDir) :: arg(facing) :: Nil))) ::
                 declLight ::
                 ifInline(litOn, assign(light, call(Vec3.Vec3, lightAt(bv, feature#spotShadow(spotShadow())), arg(world) :: arg(facing) :: Nil))) ::
                 ShaderAst.emit(ShaderAst.vec4FromVec3(feature#colorOut(color), f("1.0"))) :: Nil }

    /// ビルボードを影の地図へ描く frag の入口（色を出さず、絵の α < 0.5 の画素を捨てるだけ。WGSL だけ。GL は billboardFragment の uDepthOut の枝で同じ事をする）。
    pub def billboardShadowFragment(bindings: List[Definition]): ShaderAst.FragmentEntry =
        { inputName = "R3dBillboardShadowIn", declarations = bindings, inputs = billboardUvVarying() :: Nil, writesColor = false,
          body = ifInline(lt(ShaderAst.a(imageTexel(ShaderAst.varying(Vec2.Vec2, billboardUvVarying()))), f("0.5")), ShaderAst.discard_()) :: Nil }

    // ── 空・blit ──

    /// 空の vertex の入口（頂点の buffer を読まず、描き先いっぱいを覆う三角形）。
    pub def skyVertex(): ShaderAst.VertexEntry =
        { inputName = "R3dSkyIn", outputName = "R3dSkyOut", declarations = Nil, attributes = Nil, outputs = Nil,
          body = ShaderAst.clipOut(ShaderAst.fullscreenPosition()) :: Nil }

    /// 空の frag の入口（式は LightModel3d.skyModel・向きは Scene3d.skyDirectionOf。NDC は画素の真ん中と描き先の大きさから・y は上へ）。
    /// 景色を背景に描く場面（GLSL は uEnvOn・WGSL は uSkyUp.w）は空の代わりに環境マップの絵を mip のレベル 0 で読む（Scene3d.backgroundEnvironmentOf。
    /// CPU の描き手は SoftRaster3d.Internal.environmentBackgroundAt）。bindings = WGSL の binding の宣言（GL の描き手は空）。
    // WhyNot: 奥行きの書き出しの枝（uDepthOut）を WGSL に置かない — WebGPU の奥行きの書き出しの pass は空を描かず、地の色の白で消す（WebGpuRenderer.clearOf）。
    pub def skyFragment(bindings: List[Definition]): ShaderAst.FragmentEntry =
        let white = vec4Of(f("1.0"), f("1.0"), f("1.0"), f("1.0"));
        let width = uniform(Float.Float, pairedRef(ShaderAst.Ty.F32, "uViewport", "z", "vec4", "r3d.uSkyForward", "w"));
        let height = uniform(Float.Float, pairedRef(ShaderAst.Ty.F32, "uViewport", "w", "vec4", "r3d.uSkyRight", "w"));
        let (declNdc, ndc) = let_("ndc", ShaderAst.pixelNdc(Render3d.Uniforms.refOf(R3dUniform.Viewport), width, height));
        let axis = (glslBase: String, wgslBase: String) -> uniform(Vec3.Vec3, pairedRef(ShaderAst.Ty.Vec3, glslBase, "", "vec3", wgslBase, "xyz"));
        let (declD, d) = let_("d", normalize(add(add(axis("uForward", "r3d.uSkyForward"), mulS(axis("uRight", "r3d.uSkyRight"), x(ndc))), mulS(axis("uUp", "r3d.uSkyUp"), y(ndc)))));
        let background = uniform(Boolean.Boolean, pairedRef(ShaderAst.Ty.Bool, "uEnvOn", "", "int", "r3d.uSkyUp", "w"));
        let map = u(Tex.Tex, R3dUniform.EnvMap);
        let uvOf = call(Vec2.Vec2, environmentUv(), arg(d) :: Nil);
        let texel = ShaderAst.callIn(Vec4.Vec4, "textureLod", arg(map) :: arg(uvOf) :: arg(f("0.0")) :: Nil,
                                     "textureSampleLevel", arg(map) :: ShaderAst.samplerArg("uEnvSampler") :: arg(uvOf) :: arg(f("0.0")) :: Nil, Nil, false);
        let (declC, c) = let_("c", ShaderAst.rgb(texel));
        let environment = mulS(ternary(ShaderAst.eq(u(Int.Int, R3dUniform.EnvSrgb), i(1)), toLinear3(c), c), u(Float.Float, R3dUniform.EnvIntensity));
        { inputName = "R3dSkyIn", declarations = bindings, inputs = Nil, writesColor = true,
          body = ShaderAst.onlyIn(ShaderAst.Lang.Glsl, ShaderAst.ifBlock(ShaderAst.eq(u(Int.Int, R3dUniform.DepthOut), i(1)), ShaderAst.emitAndReturn(white) :: Nil) :: Nil) ::
                 declNdc :: declD ::
                 ShaderAst.ifBlock(background, declC :: ShaderAst.emitAndReturn(ShaderAst.vec4FromVec3(toSrgb3(environment), f("1.0"))) :: Nil) ::
                 ShaderAst.emit(ShaderAst.vec4FromVec3(toSrgb3(call(Vec3.Vec3, skyAt(), arg(d) :: Nil)), f("1.0"))) :: Nil }

    /// blit の uv（四角の上を v = 1 に当てる）。
    def blitUvVarying(): ShaderAst.Varying = varyingOf("vUv", ShaderAst.Ty.Vec2, 0, ShaderAst.Interp.Smooth)

    /// Design の FBO を viewport 全面へ貼る vertex の入口（FBO は行 0 が下なので、四角の上を v = 1 に当てる。GL だけ）。
    // WhyNot: 空と同じ描き先いっぱいの三角形にしない — 最も近い画素で読む blit は、大きな三角形で uv をつなぎ直すと丸めが変わり、描き先と FBO の大きさが違う時に画素の境目で読む画素が替わりうる。
    pub def blitVertex(): ShaderAst.VertexEntry =
        let c = ShaderAst.quadCorner();
        { inputName = "R3dBlitIn", outputName = "R3dBlitOut", declarations = Nil, attributes = Nil, outputs = blitUvVarying() :: Nil,
          body = ShaderAst.output(blitUvVarying(), vec2Of(x(c), sub(f("1.0"), y(c)))) ::
                 ShaderAst.clipOut(vec4Of(sub(mul(x(c), f("2.0")), f("1.0")), sub(f("1.0"), mul(y(c), f("2.0"))), f("0.0"), f("1.0"))) :: Nil }

    /// blit の frag の入口（FBO の絵をそのまま出す。GL だけ）。
    pub def blitFragment(): ShaderAst.FragmentEntry =
        { inputName = "R3dBlitIn", declarations = Nil, inputs = blitUvVarying() :: Nil, writesColor = true,
          body = ShaderAst.emit(imageTexel(ShaderAst.varying(Vec2.Vec2, blitUvVarying()))) :: Nil }
}
