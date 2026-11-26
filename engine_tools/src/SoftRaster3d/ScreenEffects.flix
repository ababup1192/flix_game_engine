// SoftRaster3d.ScreenEffects — CPU の描き手の画面の上の技（SSAO の mask）。式と表の値は ScreenEffects3d の頭で、GPU の Render3d.ScreenPasses と同じ並びで書く
// （GPU は f32・こちらは Float64 で、gl-parity の許す画素の数でそろえる）。mask の各回の後で R8 の描き先と同じく 1/255 に丸める。

/// SSAO の mask を CPU で作る中身（ゲームは呼ばない）。
pub mod SoftRaster3d.ScreenEffects {

    /// 場面 1 つの SSAO の入力。depth = 奥行きの Pass（R32Float。赤が目からの距離 / depthRange）・rect = その中の場面の矩形（左上・幅・高さ）・
    /// layer = 場面の描き先の大きさ（mask はこれに scale を掛けた大きさ）。
    pub type alias Input = { depth = ShaderEval.HdrTexture, rect = (Int32, Int32, Int32, Int32), layer = (Int32, Int32), scene = Scene3d.Scene3dCmd,
                             depthRange = Float64, ao = ScreenEffects3d.AmbientOcclusion }

    /// 作った mask。width × height の値（行優先・左上から）・layer = 場面の描き先の大きさ・lightAffect = 直接光に掛ける割合。
    pub type alias Mask = { width = Int32, height = Int32, values = Vector[Float64], layer = (Int32, Int32), lightAffect = Float64 }

    /// 場面 scene の mask（+ao の Native の場面で、奥行きの Pass が floatPasses にある時だけ）。rect = 奥行きの Pass の中の場面の矩形（左上・幅・高さ）・
    /// layer = 場面の描き先の大きさ。
    pub def maskFor(floatPasses: Map[String, ShaderEval.HdrTexture], scene: Scene3d.Scene3dCmd, rect: (Int32, Int32, Int32, Int32),
                    layer: (Int32, Int32)): Option[Mask] \ IO =
        let found = if (scene#resolution != Scene3d.Resolution.Native or not Scene3d.preloadVariantOf(scene)#ambientOcclusion) None
                    else scene#screenInputs |> Option.flatMap(inputs -> {
                        let fields = Scene3d.screenInputsFieldsOf(inputs);
                        forM (ao <- fields#ambientOcclusion; depth <- Map.get(fields#depth, floatPasses))
                        yield { depth = depth, rect = rect, layer = layer, scene = scene, depthRange = fields#depthRange, ao = ao }
                    });
        match found {
            case Some(input) => Some(maskOf(input))
            case None        => None
        }

    /// 場面の描き先の画素 (x, y)（m#layer の中）の SSAO の値（mask の画素の真ん中が乗る画素を読む。GPU の Render3d.ScreenPasses.screenMaskAt と同じ）。
    pub def valueAt(m: Mask, x: Int32, y: Int32): Float64 =
        let (lw, lh) = m#layer;
        let mx = clampInt(floorInt((Int32.toFloat64(x) + 0.5) * Int32.toFloat64(m#width) / Int32.toFloat64(lw)), 0, m#width - 1);
        let my = clampInt(floorInt((Int32.toFloat64(y) + 0.5) * Int32.toFloat64(m#height) / Int32.toFloat64(lh)), 0, m#height - 1);
        Vector.get(my * m#width + mx, m#values)

    /// 直接光に掛ける値 1 − lightAffect × (1 − ao)。
    pub def directOf(m: Mask, ao: Float64): Float64 = 1.0 - m#lightAffect * (1.0 - ao)

    def floorInt(v: Float64): Int32 = Float64.tryToInt32(Float64.floor(v)) |> Option.getWithDefault(0)

    def clampInt(v: Int32, lo: Int32, hi: Int32): Int32 = Int32.max(lo, Int32.min(hi, v))

    /// R8 の描き先へ書いた値（0..1 を 1/255 に丸める）。
    def quantized(v: Float64): Float64 = Float64.floor(Num.clamp01(v) * 255.0 + 0.5) / 255.0

    /// 場面の値（Render3d.ScreenPasses.valuesOf と同じ値を Float64 で）。
    type alias Frame = { eye = Vec3.Vec3, forward = Vec3.Vec3, right = Vec3.Vec3, up = Vec3.Vec3, range = Float64, radius = Float64, thickness = Float64,
                         projScale = Float64, intensity = Float64, power = Float64, taps = Int32, maxRadius = Float64 }

    def frameOf(input: Input): Frame =
        let scene = input#scene;
        let (_, _, _, rh) = input#rect;
        let (forward, right, up) = Scene3d.Internal.ScreenInputs.rayBasisOf(scene#camera, scene#size);
        let ao = input#ao;
        { eye = scene#camera#eye, forward = forward, right = right, up = up, range = input#depthRange,
          radius = ao#radius * scene#unitsPerMeter, thickness = ao#thickness * scene#unitsPerMeter,
          projScale = Scene3d.Internal.ScreenInputs.projScaleOf(scene#camera, rh), intensity = ao#intensity, power = ScreenEffects3d.powerOf(ao),
          taps = ScreenEffects3d.tapsOf(ao), maxRadius = Int32.toFloat64(rh) * ScreenEffects3d.maxRadiusFraction() }

    /// 場面の矩形の中の画素 (qx, qy)（矩形に収める）の奥行きの値。
    def depthAt(input: Input, qx: Int32, qy: Int32): Float64 =
        let (rx, ry, rw, rh) = input#rect;
        let x = rx + clampInt(qx, 0, rw - 1);
        let y = ry + clampInt(qy, 0, rh - 1);
        ShaderEval.hdrChannelOf(input#depth, (y * ShaderEval.hdrWidthOf(input#depth) + x) * 4)

    /// 場面の矩形の中の画素 (qx, qy) の、奥行き d の点。
    def pointAt(input: Input, f: Frame, qx: Int32, qy: Int32, d: Float64): Vec3.Vec3 =
        let (_, _, rw, rh) = input#rect;
        let ndcX = (Int32.toFloat64(qx) + 0.5) / Int32.toFloat64(rw) * 2.0 - 1.0;
        let ndcY = 1.0 - (Int32.toFloat64(qy) + 0.5) / Int32.toFloat64(rh) * 2.0;
        let ray = Vec3.normalized(Vec3.add(Vec3.add(f#forward, Vec3.mul(f#right, ndcX)), Vec3.mul(f#up, ndcY)));
        Vec3.add(f#eye, Vec3.mul(ray, d * f#range))

    def pointOf(input: Input, f: Frame, qx: Int32, qy: Int32): Vec3.Vec3 = pointAt(input, f, qx, qy, depthAt(input, qx, qy))

    /// mask の画素 (mx, my) の真ん中が乗る、場面の矩形の中の奥行きの画素。
    def centerOf(input: Input, mw: Int32, mh: Int32, mx: Int32, my: Int32): (Int32, Int32) =
        let (_, _, rw, rh) = input#rect;
        (clampInt(floorInt((Int32.toFloat64(mx) + 0.5) * Int32.toFloat64(rw) / Int32.toFloat64(mw)), 0, rw - 1),
         clampInt(floorInt((Int32.toFloat64(my) + 0.5) * Int32.toFloat64(rh) / Int32.toFloat64(mh)), 0, rh - 1))

    def shorter(a: Vec3.Vec3, b: Vec3.Vec3): Vec3.Vec3 = if (Vec3.dot(a, a) < Vec3.dot(b, b)) a else b

    /// mask の画素 (mx, my) の SSAO の値（ScreenEffects3d の頭の式）。
    def occlusionAt(input: Input, f: Frame, mw: Int32, mh: Int32, mx: Int32, my: Int32): Float64 =
        let (cx, cy) = centerOf(input, mw, mh, mx, my);
        let d0 = depthAt(input, cx, cy);
        if (d0 >= 1.0) 1.0
        else {
            let p = pointAt(input, f, cx, cy, d0);
            let dx = shorter(Vec3.sub(p, pointOf(input, f, cx - 1, cy)), Vec3.sub(pointOf(input, f, cx + 1, cy), p));
            let dy = shorter(Vec3.sub(p, pointOf(input, f, cx, cy - 1)), Vec3.sub(pointOf(input, f, cx, cy + 1), p));
            let nn = Vec3.cross(dy, dx);
            let toEye = Vec3.sub(f#eye, p);
            let n0 = if (Vec3.dot(nn, nn) < 1.0e-20) Vec3.normalized(toEye) else Vec3.normalized(nn);
            let n = if (Vec3.dot(n0, toEye) < 0.0) Vec3.mul(n0, -1.0) else n0;
            let rPix = Float64.min(f#radius * f#projScale / Float64.max(d0 * f#range, 1.0e-6), f#maxRadius);
            let fract = (v: Float64) -> v - Float64.floor(v);
            let ign = fract(ScreenEffects3d.noiseC() * fract(ScreenEffects3d.noiseA() * Int32.toFloat64(mx) + ScreenEffects3d.noiseB() * Int32.toFloat64(my)));
            let tapsF = Int32.toFloat64(f#taps);
            let sum = List.range(0, f#taps) |> List.foldLeft((acc, ti) -> {
                let t = (Int32.toFloat64(ti) + 0.5) / tapsF;
                let a = 6.283185307179586 * (ign + t * ScreenEffects3d.spiralTurns());
                let rr = rPix * t;
                let qx = cx + floorInt(Num.cos(a) * rr + 0.5);
                let qy = cy + floorInt(Num.sin(a) * rr + 0.5);
                let dq = depthAt(input, qx, qy);
                if (dq >= 1.0) acc
                else {
                    let v = Vec3.sub(pointAt(input, f, qx, qy, dq), p);
                    let vv = Vec3.dot(v, v);
                    let fall = Num.clamp01(1.0 - vv / (f#thickness * f#thickness));
                    acc + Float64.max(Vec3.dot(v, n) / Num.sqrt(vv + ScreenEffects3d.epsilon()) - ScreenEffects3d.bias(), 0.0) * fall
                }
            }, 0.0);
            Float64.pow(base = Num.clamp01(1.0 - f#intensity * sum / tapsF), f#power)
        }

    /// mask の画素 (mx, my) を (sx, sy) の向きに奥行きを見てぼかした値（src = 前の回の mask）。
    def blurAt(input: Input, mw: Int32, mh: Int32, src: Array[Float64, Static], sx: Int32, sy: Int32, mx: Int32, my: Int32): Float64 \ IO =
        let maskAt = (x: Int32, y: Int32) -> Array.get(clampInt(y, 0, mh - 1) * mw + clampInt(x, 0, mw - 1), src);
        let depthOfMask = (x: Int32, y: Int32) -> { let (cx, cy) = centerOf(input, mw, mh, x, y); depthAt(input, cx, cy) };
        let c = depthOfMask(mx, my);
        if (c >= 1.0) maskAt(mx, my)
        else {
            let start = (ScreenEffects3d.blurCenterWeight() * maskAt(mx, my), ScreenEffects3d.blurCenterWeight());
            let (sum, total) = (-2 :: -1 :: 1 :: 2 :: Nil) |> List.foldLeft((acc, k) -> {
                let (s, w) = acc;
                let qx = clampInt(mx + k * sx, 0, mw - 1);
                let qy = clampInt(my + k * sy, 0, mh - 1);
                let wk = if (Int32.abs(k) == 1) ScreenEffects3d.blurNearWeight() else ScreenEffects3d.blurFarWeight();
                let dq = depthOfMask(qx, qy);
                if (Float64.abs(dq - c) <= ScreenEffects3d.blurDepthTolerance() * c) (s + wk * maskAt(qx, qy), w + wk) else acc
            }, start);
            sum / total
        }

    /// 場面の SSAO の mask（mask → 横 → 縦。各回の後で 1/255 に丸める）。
    pub def maskOf(input: Input): Mask \ IO =
        let (lw, lh) = input#layer;
        let (mw, mh) = ScreenEffects3d.maskSizeOf(input#ao, lw, lh);
        let f = frameOf(input);
        let n = mw * mh;
        let first: Array[Float64, Static] = Array.repeat(Static, n, 1.0);
        let second: Array[Float64, Static] = Array.repeat(Static, n, 1.0);
        List.range(0, n) |> List.forEach(i -> Array.put(quantized(occlusionAt(input, f, mw, mh, Int32.remainder(i, mw), i / mw)), i, first));
        List.range(0, n) |> List.forEach(i -> Array.put(quantized(blurAt(input, mw, mh, first, 1, 0, Int32.remainder(i, mw), i / mw)), i, second));
        List.range(0, n) |> List.forEach(i -> Array.put(quantized(blurAt(input, mw, mh, second, 0, 1, Int32.remainder(i, mw), i / mw)), i, first));
        { width = mw, height = mh, values = Array.toVector(first), layer = input#layer, lightAffect = ScreenEffects3d.lightAffectOf(input#ao) }
}
