// PostStack.Internal.Fog — 高さの霧（HeightFog）の面。奥行きの絵（目からの距離）と、画素を通る目からの向きから、
// 霧の濃さを高さで指数に減らしながら目から面まで積み、場面の色を霧の色へ寄せる（Unreal の Exponential Height Fog と同じ式）。
// ゲームからは呼ばない（PostStack の中身。入口は PostStack.withHeightFog）。
//
// 目からの向きは画面の 3 つの角の向きを CPU で出して Param で渡し、画素の間は 1 次でつなぐ（透視の向きは像の面の上で 1 次なので正しい）。
// 毎コマ変わる数（カメラ・時刻・色・濃さ・灯りの位置）は全部 Param で、カメラが動いても program は作り直さない。
pub mod PostStack.Internal.Fog {

    use PostStack.{HeightFog, FogNoise}
    use PostStack.Internal.Waves
    use PostStack.Internal.Waves.Wave
    use ShaderDoc.{Axis, BinOp, Field, Out, Shade, TexChan, UnOp}

    /// 霧ににじませる灯りの数の上限（Scene3d が計算する点光源の数と同じ）。
    pub def maxGlowLights(): Int32 = 8

    /// むらの波（長さは noise.size に掛ける倍率）。
    def noiseWaves(): List[Wave] =
        let pi = Waves.pi();
        { angle = 0.13 * pi, length = 1.0, weight = 0.4, phase0 = 0.0 } :: { angle = 0.58 * pi, length = 0.71, weight = 0.3, phase0 = 1.9 }
            :: { angle = 0.86 * pi, length = 0.47, weight = 0.2, phase0 = 3.3 } :: { angle = 0.34 * pi, length = 0.31, weight = 0.1, phase0 = 4.7 } :: Nil

    def noisePhaseNames(): List[String] = List.range(0, 4) |> List.map(i -> "ps_fnph${i}")

    /// 霧の面 1 枚（Param つき）。source = 場面の Pass・depth = 目からの距離を range で割った奥行きの絵（camera の far か、SSAO の奥行きの Pass の遠い隅までの距離）・
    /// toLin = 画面の値を線形へ戻してから混ぜるか。
    pub def surface(fog: HeightFog, size: Vec2.Vec2, time: Float64, scene: (Vec2.Vec2, Scene3d.Scene3dCmd),
                    source: String, depth: String, range: Float64, toLin: Bool): Render.PlacedItem =
        let (_, cmd) = scene;
        let lights = glowLightsOf(fog, cmd);
        let spec = specOf(fog, size#x / size#y, range, source, depth, toLin, List.length(lights));
        Render.withShaderParams(paramsOf(fog, size, time, scene, lights),
            Render.shaderFill(spec, { position = Vec2.zero(), size = size }, 0.0, 0))

    // ── 面に渡す数 ──

    def srgbToLinear(c: Float64): Float64 =
        if (c <= 0.04045) c / 12.92 else Float64.pow(base = (c + 0.055) / 1.055, 2.4)

    /// 高さ y での霧の濃さ（長さ 1 あたり）。
    def densityAt(fog: HeightFog, y: Float64): Float64 =
        fog#density * Float64.exp(Float64.min(80.0, 0.0 - fog#heightFalloff * (y - fog#baseHeight)))

    /// 画面の (u, v) を通る目からの向き（forward との内積が 1 になる長さ）を、u と v の 1 次の式の 3 つの係数で（uv = 0 の向き・u 方向・v 方向）。
    def rayBasis(size: Vec2.Vec2, scene: (Vec2.Vec2, Scene3d.Scene3dCmd)): (Vec3.Vec3, Vec3.Vec3, Vec3.Vec3) =
        let (at, cmd) = scene;
        let cam = cmd#camera;
        let sw = Float64.max(1.0, cmd#size#x);
        let sh = Float64.max(1.0, cmd#size#y);
        let tanHalf = Num.sin(cam#fovY / 2.0) / Num.cos(cam#fovY / 2.0);
        let right = Vec3.mul(Camera3d.right(cam), tanHalf * sw / sh);
        let up = Vec3.mul(Camera3d.up(cam), tanHalf);
        let ndcX = (x: Float64) -> (x - at#x) / sw * 2.0 - 1.0;
        let ndcY = (y: Float64) -> 1.0 - (y - at#y) / sh * 2.0;
        let origin = Vec3.add(Camera3d.forward(cam), Vec3.add(Vec3.mul(right, ndcX(0.0)), Vec3.mul(up, ndcY(0.0))));
        (origin, Vec3.mul(right, 2.0 * size#x / sw), Vec3.mul(up, 0.0 - 2.0 * size#y / sh))

    type alias GlowLight = { u = Float64, v = Float64, invRadius2 = Float64, distance = Float64, range = Float64, r = Float64, g = Float64, b = Float64 }

    /// 霧ににじませる灯り（目の前にある物を先に、目に近い順に maxGlowLights まで）。lightGlow ≤ 0 なら空。
    // WhyNot: 目の後ろの灯りを列から外さない — 列の長さが変わると Spec の形が変わり、歩くたびに描き手が program を作り直す。後ろの灯りは色 0 で枠だけ使う。
    def glowLightsOf(fog: HeightFog, cmd: Scene3d.Scene3dCmd): List[Scene3d.PointLight] =
        if (fog#lightGlow <= 0.0) Nil
        else {
            let fwd = Camera3d.forward(cmd#camera);
            cmd#pointLights
                |> List.map(l -> {
                    let toward = Vec3.sub(l#position, cmd#camera#eye);
                    ((if (Vec3.dot(toward, fwd) > 0.0) 0 else 1, Vec3.length(toward)), l)
                })
                |> Sort.sortStableBy(fst) |> List.map(snd) |> List.take(maxGlowLights())
        }

    /// 灯り 1 つの、画面の上の真ん中・にじみの半径・届く距離・色（線形・霧の濃さ込み）。目の後ろなら色 0。
    def glowOf(fog: HeightFog, size: Vec2.Vec2, scene: (Vec2.Vec2, Scene3d.Scene3dCmd), l: Scene3d.PointLight): GlowLight =
        let (at, cmd) = scene;
        let cam = cmd#camera;
        let distance = Vec3.length(Vec3.sub(l#position, cam#eye));
        let tanHalf = Num.sin(cam#fovY / 2.0) / Num.cos(cam#fovY / 2.0);
        // にじみの半径（画面の高さ = 1）: 届く距離の 0.2 倍を、その距離で画面へ写した長さ（届く距離いっぱいにすると画面ごと染まる）。
        let radius = 0.2 * l#range / Float64.max(0.001, distance) / (2.0 * tanHalf) * cmd#size#y / size#y;
        let thick = 1.0 - Float64.exp(0.0 - densityAt(fog, l#position#y) * l#range);
        let amp = fog#lightGlow * l#intensity * thick;
        match Camera3d.worldToScreen(cam, cmd#size, l#position) {
            case Some(px) =>
                { u = (at#x + px#x) / size#x, v = (at#y + px#y) / size#y, invRadius2 = 1.0 / Float64.max(0.000001, radius * radius),
                  distance = distance, range = Float64.max(0.001, l#range),
                  r = amp * srgbToLinear(l#color#r), g = amp * srgbToLinear(l#color#g), b = amp * srgbToLinear(l#color#b) }
            case None =>
                { u = 0.0, v = 0.0, invRadius2 = 1.0, distance = distance, range = 1.0, r = 0.0, g = 0.0, b = 0.0 }
        }

    def paramsOf(fog: HeightFog, size: Vec2.Vec2, time: Float64, scene: (Vec2.Vec2, Scene3d.Scene3dCmd), lights: List[Scene3d.PointLight]): Map[String, Float64] =
        let (at, cmd) = scene;
        let eye = cmd#camera#eye;
        let (r0, ru, rv) = rayBasis(size, scene);
        let base = Map#{
            "ps_fogEye" => densityAt(fog, eye#y), "ps_fogFalloff" => fog#heightFalloff, "ps_fogStart" => fog#startDistance,
            "ps_fogMax" => Float64.max(0.0, Float64.min(1.0, fog#maxOpacity)),
            "ps_fogR" => srgbToLinear(fog#color#r), "ps_fogG" => srgbToLinear(fog#color#g), "ps_fogB" => srgbToLinear(fog#color#b),
            "ps_fr0x" => r0#x, "ps_fr0y" => r0#y, "ps_fr0z" => r0#z, "ps_frux" => ru#x, "ps_fruy" => ru#y, "ps_fruz" => ru#z,
            "ps_frvx" => rv#x, "ps_frvy" => rv#y, "ps_frvz" => rv#z, "ps_fex" => eye#x, "ps_fez" => eye#z,
            "ps_fsx0" => at#x / size#x, "ps_fsy0" => at#y / size#y,
            "ps_fsx1" => (at#x + cmd#size#x) / size#x, "ps_fsy1" => (at#y + cmd#size#y) / size#y };
        let withNoise = match fog#noise {
            case Some(n) =>
                List.zip(noiseWaves(), noisePhaseNames())
                    |> List.foldLeft((m, e) -> { let (w, name) = e; Map.insert(name, Waves.phaseAt(n#size, n#speed, time, w), m) },
                                     Map.insert("ps_fnAmt", Float64.max(0.0, Float64.min(1.0, n#amount)), base))
            case None => base
        };
        lights |> List.zipWithIndex |> List.foldLeft((m, e) -> {
            let (i, l) = e;
            let g = glowOf(fog, size, scene, l);
            m |> Map.insert("ps_fg${i}u", g#u) |> Map.insert("ps_fg${i}v", g#v) |> Map.insert("ps_fg${i}k", g#invRadius2)
              |> Map.insert("ps_fg${i}d", g#distance) |> Map.insert("ps_fg${i}s", g#range)
              |> Map.insert("ps_fg${i}r", g#r) |> Map.insert("ps_fg${i}g", g#g) |> Map.insert("ps_fg${i}b", g#b)
        }, withNoise)

    // ── 面の式 ──

    def k(v: Float64): Field = Field.Const(v)
    def p(name: String): Field = Field.Param({ name = name })
    def ref(name: String): Field = Field.Ref(name)
    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })
    def sub(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Sub, a = a, b = b })
    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })
    def div(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Div, a = a, b = b })
    def maxF(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Max, a = a, b = b })
    def minF(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Min, a = a, b = b })
    def sat(a: Field): Field = Field.Un({ op = UnOp.Sat, of = a })

    /// e^(|x|/32) を 3 次までの式で（y = |x|/32 として 1 + y + y²/2 + y³/6）。32 乗すると e^|x| に近づく（|x| = 20 で 1% ほどの差）。
    // WhyNot: Field に e^x の節を足さない — 3 つの描き手の生成器に式を足すのは S2（式の木）の仕事。Pow の定数の指数で足りる。
    def expRoot(x: Field): Field =
        let y = mul(Field.Un({ op = UnOp.Abs, of = x }), k(1.0 / 32.0));
        add(k(1.0), mul(y, add(k(1.0), mul(y, add(k(0.5), mul(y, k(1.0 / 6.0)))))))

    /// e^(−x)（x ≥ 0）。
    def expNeg(x: Field): Field = Field.Pow({ of = expRoot(x), p = -32.0 })

    /// e^(−a)（a の符号はどちらでも）。
    def expSigned(a: Field): Field =
        let m = expRoot(a);
        Field.Blend({ a = Field.Pow({ of = m, p = -32.0 }), b = Field.Pow({ of = m, p = 32.0 }), by = Field.Bin({ op = BinOp.Step, a = a, b = k(0.0) }) })

    /// Uv が 3D の場面の矩形の中なら 1（奥行きの絵は矩形の中にしか無い）。
    def insideScene(): Field =
        let u = Field.Uv({ axis = Axis.U });
        let v = Field.Uv({ axis = Axis.V });
        let step = (lo: Field, x: Field) -> Field.Bin({ op = BinOp.Step, a = lo, b = x });
        mul(mul(step(p("ps_fsx0"), u), step(u, p("ps_fsx1"))), mul(step(p("ps_fsy0"), v), step(v, p("ps_fsy1"))))

    def sceneChan(source: String, toLin: Bool, chan: TexChan): Field =
        let t = Field.Tex({ name = source, chan = chan });
        if (toLin) PostStack.Internal.Passes.toLinear(t) else t

    def backTo(toLin: Bool, x: Field): Field = if (toLin) PostStack.Internal.Passes.toSrgb(x) else x

    def axisRay(c: String): Field =
        add(add(p("ps_fr0${c}"), mul(Field.Uv({ axis = Axis.U }), p("ps_fru${c}"))), mul(Field.Uv({ axis = Axis.V }), p("ps_frv${c}")))

    def specOf(fog: HeightFog, aspect: Float64, far: Float64, source: String, depth: String, toLin: Bool, glowCount: Int32): ShaderDoc.Spec =
        let noiseBindings = match fog#noise {
            case Some(n) =>
                let px = add(p("ps_fex"), mul(ref("ps_fdx"), ref("ps_ft")));
                let pz = add(p("ps_fez"), mul(ref("ps_fdz"), ref("ps_ft")));
                // 遠くの細かい波は画素より細くなってちらつくので、粒の 24 倍の距離で消す。
                let fade = sat(sub(k(1.0), mul(ref("ps_ft"), k(1.0 / (24.0 * Float64.max(0.001, n#size))))));
                ("ps_fn", add(k(1.0), mul(mul(p("ps_fnAmt"), fade), Waves.field(px, pz, n#size, noiseWaves(), noisePhaseNames())))) :: Nil
            case None => ("ps_fn", k(1.0)) :: Nil
        };
        let a = mul(mul(p("ps_fogFalloff"), ref("ps_fdy")), ref("ps_fs"));
        let clampedA = maxF(k(-400.0), minF(k(400.0), a));
        let small = Field.Bin({ op = BinOp.Step, a = Field.Un({ op = UnOp.Abs, of = ref("ps_fa") }), b = k(0.01) });
        let integral = Field.Blend({ a = div(sub(k(1.0), expSigned(ref("ps_fa"))), ref("ps_fa")), b = sub(k(1.0), mul(ref("ps_fa"), k(0.5))), by = small });
        let glowSum = (c: String) -> List.range(0, glowCount) |> List.map(i -> mul(p("ps_fg${i}${c}"), ref("ps_fgw${i}")))
            |> List.reduceLeft(add) |> Option.getWithDefault(k(0.0));
        let glowBindings = List.range(0, glowCount) |> List.map(i -> {
            let du = mul(sub(Field.Uv({ axis = Axis.U }), p("ps_fg${i}u")), k(aspect));
            let dv = sub(Field.Uv({ axis = Axis.V }), p("ps_fg${i}v"));
            let r2 = mul(add(mul(du, du), mul(dv, dv)), p("ps_fg${i}k"));
            let halo = mul(div(k(1.0), add(k(1.0), r2)), sat(sub(k(1.0), mul(r2, k(1.0 / 16.0)))));
            // 面が灯りより手前にあれば、霧の中の灯りは見えない。
            let behind = sat(add(div(sub(ref("ps_ft"), p("ps_fg${i}d")), p("ps_fg${i}s")), k(1.0)));
            ("ps_fgw${i}", mul(halo, behind))
        });
        let mixChan = (c: TexChan, fogName: String, glowName: String) ->
            backTo(toLin, add(add(mul(sceneChan(source, toLin, c), sub(k(1.0), ref("ps_fo"))), mul(p(fogName), ref("ps_fo"))), glowSum(glowName)));
        let bindings = List.flatten(
            (("ps_ft", mul(Field.Tex({ name = depth, chan = TexChan.R }), k(far)))
                :: ("ps_frx", axisRay("x")) :: ("ps_fry", axisRay("y")) :: ("ps_frz", axisRay("z"))
                :: ("ps_fl", Field.Un({ op = UnOp.Sqrt, of = add(add(mul(ref("ps_frx"), ref("ps_frx")), mul(ref("ps_fry"), ref("ps_fry"))), mul(ref("ps_frz"), ref("ps_frz"))) }))
                :: ("ps_fdx", div(ref("ps_frx"), ref("ps_fl"))) :: ("ps_fdy", div(ref("ps_fry"), ref("ps_fl"))) :: ("ps_fdz", div(ref("ps_frz"), ref("ps_fl")))
                :: ("ps_fs", maxF(k(0.0), sub(ref("ps_ft"), p("ps_fogStart"))))
                :: Nil)
            :: noiseBindings
            // 積み始めの点（目から startDistance 先）の高さの濃さから積む。tau は float32 で inf にならないよう 1e4 で切る（e^−1e4 は 0 と同じ）。
            :: (("ps_fa", clampedA)
                :: ("ps_fstart", expSigned(maxF(k(-400.0), minF(k(400.0), mul(mul(p("ps_fogFalloff"), ref("ps_fdy")), p("ps_fogStart"))))))
                :: ("ps_ftau", minF(k(10000.0), mul(mul(mul(mul(p("ps_fogEye"), ref("ps_fstart")), integral), ref("ps_fs")), maxF(k(0.0), ref("ps_fn")))))
                :: ("ps_fo", mul(mul(sub(k(1.0), expNeg(ref("ps_ftau"))), p("ps_fogMax")), insideScene())) :: Nil)
            :: glowBindings
            :: Nil);
        { name = "ps_fog", cycleRate = 0.0, bindings = bindings,
          out = Out.Fill({ shade = Shade.Rgb({ r = mixChan(TexChan.R, "ps_fogR", "r"), g = mixChan(TexChan.G, "ps_fogG", "g"), b = mixChan(TexChan.B, "ps_fogB", "b") }), alpha = k(1.0) }) }
}
