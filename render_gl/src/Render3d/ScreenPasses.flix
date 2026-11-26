// Render3d.ScreenPasses — 3D の描き手の中の、画面の上の pass（SSAO の mask → 横のぼかし → 縦のぼかし → DebugView の表示）の表と frag の AST。
// GL（Render3d.GlScreenPasses）と WebGPU（Render3d.WebGpuScreenPasses）はこの表を回して描き先を作り・bind し・全部の画面の三角形を描くだけ。
// 式と表の値は ScreenEffects3d の頭（CPU の描き手は SoftRaster3d.ScreenEffects が同じ並びで書く）。
// 画素の座標はどれも「描き先の左上が 0」。奥行きと mask の絵は GL の行の数え方（行 0 が下）で読む（ShaderAst.targetTexel。WGSL は読む直前に行を返す）。
//
// uniform（GLSL は vec4 の uniform・WGSL は group 0 の binding 0 の `ss: SsaoValues`）:
//   eye = (目の位置, depthRange)・forward = (F', 半径（場面の長さ）)・right = (X', thickness（場面の長さ）)・up = (U', projScale)・
//   params = (intensity, power, taps, 半径の画素の上限)・rect = 奥行きの絵の中の場面の矩形 (x, 下からの y, 幅, 高さ)・
//   target = 描く絵の矩形 (x, 下からの y, 幅, 高さ。mask とぼかしは (0, 0, mask の幅, 高さ))・dir = ぼかしの向き (1, 0) か (0, 1)。
pub mod Render3d.ScreenPasses {
    use ShaderAst.{Expr, Definition, Float, Vec2, Vec3, Vec4, IVec2, Int, Tex, Layout}
    use ShaderAst.{f, i, add, sub, mul, div, addS, mulS, lt, le, gt, ge, ne, and_, neg, paren, ternary,
                   x, y, z, w, xyz, xy, zw, vec2Of, vec4Of, ivec2Of, floor, abs, normalize, dot, cross, clamp, clampI,
                   let_, var_, assign, ifInline, ifBlock, ret, param, call, arg, uniform, toFloat, toInt}

    /// 画面の上の pass の種類（並べる順）。AoMask = 奥行きから mask を作る・AoBlurH と AoBlurV = 奥行きを見て mask をぼかす・
    /// ShowAo = mask を場面の色として出す（PostStack.DebugView.AmbientOcclusion）。
    pub enum ScreenPassKind with Eq, Order, ToString {
        case AoMask, AoBlurH, AoBlurV, ShowAo
    }

    /// 画面の上の pass が描く内側の絵の形式（GL は R8・WebGPU は R8_UNORM。形式の字は 2 つの描き手がこの case から 1 か所で決める）。
    pub enum ScreenTargetFormat with Eq, ToString {
        case R8
    }

    /// 画面の上の pass の 1 行。kind = 種類・scaled = mask の大きさの描き先へ描くか（偽なら場面の描き先へ）・
    /// readsMask = 前の pass の mask を読むか・dir = ぼかしの向き・format = 描く内側の絵の形式（scaled の時だけ読む）。
    pub type alias ScreenPass = { kind = ScreenPassKind, scaled = Bool, readsMask = Bool, dir = (Float32, Float32), format = ScreenTargetFormat }

    /// 場面の技の値 inputs の pass の並び（技の無い物は出さない。show なら最後に ShowAo）。
    pub def passesOf(inputs: Scene3d.ScreenInputs): List[ScreenPass] =
        let fields = Scene3d.screenInputsFieldsOf(inputs);
        let r8 = ScreenTargetFormat.R8;
        match fields#ambientOcclusion {
            case None    => Nil
            case Some(_) =>
                { kind = ScreenPassKind.AoMask, scaled = true, readsMask = false, dir = (0.0f32, 0.0f32), format = r8 } ::
                { kind = ScreenPassKind.AoBlurH, scaled = true, readsMask = true, dir = (1.0f32, 0.0f32), format = r8 } ::
                { kind = ScreenPassKind.AoBlurV, scaled = true, readsMask = true, dir = (0.0f32, 1.0f32), format = r8 } ::
                (if (fields#show == Some(ScreenEffects3d.ScreenDebug.AmbientOcclusion)) showPass() :: Nil else Nil)
        }

    /// mask を場面の色として出す pass（PostStack.DebugView.AmbientOcclusion）。
    pub def showPass(): ScreenPass =
        { kind = ScreenPassKind.ShowAo, scaled = false, readsMask = true, dir = (0.0f32, 0.0f32), format = ScreenTargetFormat.R8 }

    /// 場面 scene が色の代わりに mask を出すか。
    pub def isShown(scene: Scene3d.Scene3dCmd): Bool =
        scene#screenInputs |> Option.exists(s -> Scene3d.screenInputsFieldsOf(s)#show == Some(ScreenEffects3d.ScreenDebug.AmbientOcclusion))

    /// 場面 scene の技の入力と SSAO の値（どちらかが無ければ None）。
    pub def ambientOcclusionOf(scene: Scene3d.Scene3dCmd): Option[(Scene3d.ScreenInputs, ScreenEffects3d.AmbientOcclusion)] =
        scene#screenInputs |> Option.flatMap(i -> Scene3d.screenInputsFieldsOf(i)#ambientOcclusion |> Option.map(ao -> (i, ao)))

    /// ScreenEffects3d の表の値の字（ShaderAst.f に渡す。CPU と同じ桁）。
    pub def floatText(v: Float64): String =
        let s = Float64.toString(v);
        if (String.contains(substr = ".", s) or String.contains(substr = "E", s) or String.contains(substr = "e", s)) s else s + ".0"

    def constant(v: Float64): Expr[Float] = f(floatText(v))

    // ── uniform と絵 ──

    def vec4Ref(name: String, field: String): ShaderAst.UniformRef =
        { name = name, ty = ShaderAst.Ty.Vec4, glsl = Some({ base = name, swizzle = "" }), wgsl = Some({ base = "ss." + field, swizzle = "" }),
          glslType = "vec4", length = None }

    def texRef(name: String): ShaderAst.UniformRef =
        { name = name, ty = ShaderAst.Ty.Texture2d, glsl = Some({ base = name, swizzle = "" }), wgsl = Some({ base = name, swizzle = "" }),
          glslType = "sampler2D", length = None }

    /// uniform の GLSL の名前（GL の描き手が location を引く。並びは SsaoValues の欄と同じ）。
    pub def uniformNames(): List[String] =
        "uSsaoEye" :: "uSsaoForward" :: "uSsaoRight" :: "uSsaoUp" :: "uSsaoParams" :: "uSsaoRect" :: "uSsaoTarget" :: "uSsaoDir" :: Nil

    /// 奥行きの絵（R32Float）の GLSL の名前。
    pub def depthName(): String = "uSsaoDepth"

    /// 前の pass の mask の絵の GLSL の名前。
    pub def maskName(): String = "uSsaoMask"

    def eye(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoEye", "eye"))
    def forward(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoForward", "forward"))
    def right(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoRight", "right"))
    def up(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoUp", "up"))
    def params(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoParams", "params"))
    def rect(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoRect", "rect"))
    def targetRef(): ShaderAst.UniformRef = vec4Ref("uSsaoTarget", "frame")
    def target(): Expr[Vec4] = uniform(Vec4.Vec4, targetRef())
    def dir(): Expr[Vec4] = uniform(Vec4.Vec4, vec4Ref("uSsaoDir", "dir"))
    def depthTex(): Expr[Tex] = uniform(Tex.Tex, texRef(depthName()))
    def maskTex(): Expr[Tex] = uniform(Tex.Tex, texRef(maskName()))

    /// WGSL の group 0 の宣言（binding 0 = 値・1 = 奥行きの絵（unfilterable-float）・2 = 前の pass の mask）。
    pub def wgslBindings(): Definition =
        Render3dShaders.wgslDeclarations("ssao_bindings",
            "struct SsaoValues { eye: vec4f, forward: vec4f, right: vec4f, up: vec4f, params: vec4f, rect: vec4f, frame: vec4f, dir: vec4f };\n" +
            "@group(0) @binding(0) var<uniform> ss: SsaoValues;\n" +
            "@group(0) @binding(1) var uSsaoDepth: texture_2d<f32>;\n" +
            "@group(0) @binding(2) var uSsaoMask: texture_2d<f32>;\n")

    /// SsaoValues のバイト数（vec4 が 8 つ）。
    pub def valueBytes(): Int32 = 8 * 16

    /// 場面ごとの uniform の値（頭の並び。target と dir は pass ごとに描き手が足す）。
    pub type alias Values = { eye = (Float32, Float32, Float32, Float32), forward = (Float32, Float32, Float32, Float32),
                              right = (Float32, Float32, Float32, Float32), up = (Float32, Float32, Float32, Float32),
                              params = (Float32, Float32, Float32, Float32), rect = (Float32, Float32, Float32, Float32) }

    /// 場面 scene・技の入力 inputs・SSAO の値 ao・奥行きの Pass の中の場面の矩形 rect（GL の左下が原点の x・y・幅・高さ）の uniform の値
    /// （CPU の描き手は SoftRaster3d.ScreenEffects.frameOf が同じ値を Float64 で組む）。
    pub def valuesOf(scene: Scene3d.Scene3dCmd, inputs: Scene3d.ScreenInputs, ao: ScreenEffects3d.AmbientOcclusion,
                     rect: (Int32, Int32, Int32, Int32)): Values =
        let (rx, ry, rw, rh) = rect;
        let fields = Scene3d.screenInputsFieldsOf(inputs);
        let (forward, right, up) = Scene3d.Internal.ScreenInputs.rayBasisOf(scene#camera, scene#size);
        let upm = scene#unitsPerMeter;
        let f = RenderUtil.f32;
        let v4 = (v, s) -> (f(v#x), f(v#y), f(v#z), f(s));
        { eye = v4(scene#camera#eye, fields#depthRange), forward = v4(forward, ao#radius * upm), right = v4(right, ao#thickness * upm),
          up = v4(up, Scene3d.Internal.ScreenInputs.projScaleOf(scene#camera, rh)),
          params = (f(ao#intensity), f(ScreenEffects3d.powerOf(ao)), Int32.toFloat32(ScreenEffects3d.tapsOf(ao)),
                    f(Int32.toFloat64(rh) * ScreenEffects3d.maxRadiusFraction())),
          rect = (Int32.toFloat32(rx), Int32.toFloat32(ry), Int32.toFloat32(rw), Int32.toFloat32(rh)) }

    // ── 式 ──

    def ivec(v: Expr[Vec2]): Expr[IVec2] = ShaderAst.ivec2FromVec2(v)

    /// 場面の矩形の中の画素 q（左上が 0・矩形に収める）の奥行きの値。
    def depthAt(): Definition =
        let (pq, q) = param(IVec2.IVec2, "q");
        let size = ivec(zw(rect()));
        let (declC, c) = let_("c", clampI(q, ShaderAst.ivec2Splat(i(0)), sub(size, ShaderAst.ivec2Splat(i(1)))));
        let (declT, texel) = let_("t", ivec2Of(add(toInt(x(rect())), x(c)), sub(sub(add(toInt(y(rect())), y(size)), i(1)), y(c))));
        let whole = ShaderAst.textureSizeOf(depthTex());
        let outside = ShaderAst.or_(ShaderAst.or_(lt(x(texel), i(0)), lt(y(texel), i(0))), ShaderAst.or_(ge(x(texel), x(whole)), ge(y(texel), y(whole))));
        // WhyNot: 奥行きの絵の外（描き先からはみ出した場面）を読まない — GPU の texelFetch は外で値が決まらない。CPU と同じく何も無い（1）にそろえる。
        ShaderAst.function("ssao_depthAt", ShaderAst.Ty.F32, pq :: Nil,
            declC :: declT :: ifInline(outside, ret(f("1.0"))) :: ret(ShaderAst.targetTexel(depthTex(), texel)) :: Nil)

    /// 場面の矩形の中の画素 q の、奥行き d の点（world）。
    def pointAt(): Definition =
        let (pq, q) = param(IVec2.IVec2, "q");
        let (pd, d) = param(Float.Float, "d");
        let ndcX = sub(mul(div(add(toFloat(x(q)), f("0.5")), z(rect())), f("2.0")), f("1.0"));
        let ndcY = sub(f("1.0"), mul(div(add(toFloat(y(q)), f("0.5")), w(rect())), f("2.0")));
        let (declD, ray) = let_("ray", normalize(add(add(xyz(forward()), mulS(xyz(right()), ndcX)), mulS(xyz(up()), ndcY))));
        ShaderAst.function("ssao_pointAt", ShaderAst.Ty.Vec3, pq :: pd :: Nil,
            declD :: ret(add(xyz(eye()), mulS(ray, mul(d, w(eye()))))) :: Nil)

    /// mask の画素 m の真ん中が乗る、場面の矩形の中の奥行きの画素。
    def centerOf(): Definition =
        let (pm, m) = param(IVec2.IVec2, "m");
        let at = floor(div(mul(addS(ShaderAst.vec2FromIVec2(m), f("0.5")), zw(rect())), zw(target())));
        ShaderAst.function("ssao_centerOf", ShaderAst.Ty.IVec2, pm :: Nil,
            ret(clampI(ivec(at), ShaderAst.ivec2Splat(i(0)), sub(ivec(zw(rect())), ShaderAst.ivec2Splat(i(1))))) :: Nil)

    def depthCall(q: Expr[IVec2]): Expr[Float] = call(Float.Float, depthAt(), arg(q) :: Nil)

    def pointCall(q: Expr[IVec2], d: Expr[Float]): Expr[Vec3] = call(Vec3.Vec3, pointAt(), arg(q) :: arg(d) :: Nil)

    def pointOf(q: Expr[IVec2]): Expr[Vec3] = pointCall(q, depthCall(q))

    /// 2 つの差の短い方（同じ長さなら b）。
    def shorter(a: Expr[Vec3], b: Expr[Vec3]): Expr[Vec3] = ternary(lt(dot(a, a), dot(b, b)), a, b)

    /// mask の画素 m の SSAO の値（式は ScreenEffects3d の頭）。
    def occlusionAt(): Definition =
        let (pm, m) = param(IVec2.IVec2, "m");
        let (declC, c) = let_("c", call(IVec2.IVec2, centerOf(), arg(m) :: Nil));
        let (declD0, d0) = let_("d0", depthCall(c));
        let (declP, p) = let_("p", pointCall(c, d0));
        let step = (dx: Int32, dy: Int32) -> pointOf(add(c, ivec2Of(i(dx), i(dy))));
        let (declDx, dxv) = let_("dx", shorter(sub(p, step(-1, 0)), sub(step(1, 0), p)));
        let (declDy, dyv) = let_("dy", shorter(sub(p, step(0, -1)), sub(step(0, 1), p)));
        let (declNn, nn) = let_("nn", cross(dyv, dxv));
        let toEye = sub(xyz(eye()), p);
        let (declN, n) = var_("n", ternary(lt(dot(nn, nn), f("1e-20")), normalize(toEye), normalize(nn)));
        let (declR, rPix) = let_("rPix", ShaderAst.minOf(div(mul(w(forward()), w(up())), ShaderAst.max(mul(d0, w(eye())), f("1e-6"))), w(params())));
        let (declIgn, ign) = let_("ign", ShaderAst.fract(mul(constant(ScreenEffects3d.noiseC()),
            ShaderAst.fract(add(mul(constant(ScreenEffects3d.noiseA()), toFloat(x(m))), mul(constant(ScreenEffects3d.noiseB()), toFloat(y(m))))))));
        let (declTaps, taps) = let_("taps", toInt(z(params())));
        let (declSum, sum) = var_("sum", f("0.0"));
        let thick = w(right());
        let tap = (ix: Expr[Int]) -> {
            let (declT, t) = let_("t", div(add(toFloat(ix), f("0.5")), z(params())));
            let (declA, a) = let_("a", mul(f("6.283185307179586"), add(ign, mul(t, constant(ScreenEffects3d.spiralTurns())))));
            let (declRr, rr) = let_("rr", mul(rPix, t));
            let off = (v: Expr[Float]) -> toInt(floor(add(mul(v, rr), f("0.5"))));
            let (declQ, q) = let_("q", add(c, ivec2Of(off(ShaderAst.cos(a)), off(ShaderAst.sin(a)))));
            let (declDq, dq) = let_("dq", depthCall(q));
            let (declV, v) = let_("v", sub(pointCall(q, dq), p));
            let (declVv, vv) = let_("vv", dot(v, v));
            let (declFall, fall) = let_("fall", clamp(sub(f("1.0"), div(vv, mul(thick, thick))), f("0.0"), f("1.0")));
            let contribution = mul(ShaderAst.max(sub(div(dot(v, n), ShaderAst.sqrt(add(vv, constant(ScreenEffects3d.epsilon())))), constant(ScreenEffects3d.bias())), f("0.0")), fall);
            declT :: declA :: declRr :: declQ :: declDq ::
            ifBlock(lt(dq, f("1.0")), declV :: declVv :: declFall :: assign(sum, add(sum, contribution)) :: Nil) :: Nil
        };
        ShaderAst.function("ssao_occlusionAt", ShaderAst.Ty.F32, pm :: Nil,
            declC :: declD0 ::
            ifInline(ge(d0, f("1.0")), ret(f("1.0"))) ::
            declP :: declDx :: declDy :: declNn :: declN ::
            ifInline(lt(dot(n, toEye), f("0.0")), assign(n, neg(n))) ::
            declR :: declIgn :: declTaps :: declSum ::
            ShaderAst.for_("ti", i(0), ix -> lt(ix, taps), Layout.Block, tap) ::
            ret(ShaderAst.pow(clamp(sub(f("1.0"), div(mul(x(params()), sum), z(params()))), f("0.0"), f("1.0")), y(params()))) :: Nil)

    /// mask の画素 m（mask の大きさ = target の zw の中に収める）の値。
    def maskAt(): Definition =
        let (pm, m) = param(IVec2.IVec2, "m");
        let size = ivec(zw(target()));
        let (declC, c) = let_("c", clampI(m, ShaderAst.ivec2Splat(i(0)), sub(size, ShaderAst.ivec2Splat(i(1)))));
        ShaderAst.function("ssao_maskAt", ShaderAst.Ty.F32, pm :: Nil,
            declC :: ret(ShaderAst.targetTexel(maskTex(), ivec2Of(x(c), sub(sub(y(size), i(1)), y(c))))) :: Nil)

    /// mask の画素 m を dir の向きに奥行きを見てぼかした値。
    def blurAt(): Definition =
        let (pm, m) = param(IVec2.IVec2, "m");
        let maskOf = (q: Expr[IVec2]) -> call(Float.Float, maskAt(), arg(q) :: Nil);
        let (declC, c) = let_("c", depthCall(call(IVec2.IVec2, centerOf(), arg(m) :: Nil)));
        let (declSum, sum) = var_("sum", mul(constant(ScreenEffects3d.blurCenterWeight()), maskOf(m)));
        let (declW, total) = var_("total", constant(ScreenEffects3d.blurCenterWeight()));
        let step = ivec(xy(dir()));
        let tap = (ix: Expr[Int]) -> {
            let (declQ, q) = let_("q", add(m, ShaderAst.mulIS(step, ix)));
            let (declMq, mq) = let_("mq", clampI(q, ShaderAst.ivec2Splat(i(0)), sub(ivec(zw(target())), ShaderAst.ivec2Splat(i(1)))));
            let (declWk, wk) = let_("wk", ternary(ShaderAst.eq(abs(toFloat(ix)), f("1.0")), constant(ScreenEffects3d.blurNearWeight()), constant(ScreenEffects3d.blurFarWeight())));
            let (declDq, dq) = let_("dq", depthCall(call(IVec2.IVec2, centerOf(), arg(mq) :: Nil)));
            declQ :: declMq :: declWk :: declDq ::
            ifBlock(and_(ne(ix, i(0)), le(abs(sub(dq, c)), mul(constant(ScreenEffects3d.blurDepthTolerance()), c))),
                    assign(sum, add(sum, mul(wk, maskOf(mq)))) :: assign(total, add(total, wk)) :: Nil) :: Nil
        };
        ShaderAst.function("ssao_blurAt", ShaderAst.Ty.F32, pm :: Nil,
            declC ::
            ifInline(ge(c, f("1.0")), ret(maskOf(m))) ::
            declSum :: declW ::
            ShaderAst.for_("bi", i(-2), ix -> le(ix, i(2)), Layout.Block, tap) ::
            ret(div(sum, total)) :: Nil)

    /// 場面の描き先の画素 p（場面の描き先 size の中）が読む mask の画素（mask の大きさは絵の大きさ）の値。
    /// mask と場面の描き先の大きさが違う（scale < 1）時は、場面の画素の真ん中が乗る mask の画素を読む。
    pub def screenMaskAt(mask: Expr[Tex], p: Expr[IVec2], size: Expr[Vec2]): Expr[Float] =
        let maskSize = ShaderAst.textureSizeOf(mask);
        let at = ivec(floor(div(mul(addS(ShaderAst.vec2FromIVec2(p), f("0.5")), ShaderAst.vec2FromIVec2(maskSize)), size)));
        let c = clampI(at, ShaderAst.ivec2Splat(i(0)), sub(maskSize, ShaderAst.ivec2Splat(i(1))));
        ShaderAst.targetTexel(mask, ivec2Of(x(c), sub(sub(y(maskSize), i(1)), y(c))))

    /// 灰色 v を出す文。
    def emitGray(v: Expr[Float]): ShaderAst.Statement = ShaderAst.emit(vec4Of(v, v, v, f("1.0")))

    /// pass kind の frag の入口（GL は declarations を空・WebGPU は wgslBindings）。
    pub def fragment(kind: ScreenPassKind, bindings: List[Definition]): ShaderAst.FragmentEntry =
        let p = ShaderAst.pixelFromTopLeft(targetRef());
        let body = match kind {
            case ScreenPassKind.AoMask  => emitGray(call(Float.Float, occlusionAt(), arg(p) :: Nil)) :: Nil
            case ScreenPassKind.AoBlurH => emitGray(call(Float.Float, blurAt(), arg(p) :: Nil)) :: Nil
            case ScreenPassKind.AoBlurV => emitGray(call(Float.Float, blurAt(), arg(p) :: Nil)) :: Nil
            case ScreenPassKind.ShowAo  => emitGray(screenMaskAt(maskTex(), p, zw(target()))) :: Nil
        };
        { inputName = "SsaoIn", declarations = bindings, inputs = Nil, body = body, writesColor = true }
}
