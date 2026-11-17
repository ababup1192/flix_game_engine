// PostStack.Internal.Passes — PostStack の欄を Render.PassPlan と画面へ置く面に展開する（純粋）。
// ゲームからは呼ばない（PostStack の中身。入口は PostStack.build）。
//
// Pass の並び（無い効果の Pass は作らない）:
//   ps_scene（View の絵・窓の画素・HDR）→ 自分の BeforeBloom → ps_distort（歪めた場面）→ ps_depth（奥行きの絵・半分）→ ps_soft（ぼかした場面・半分）
//   → ps_bright（明るい所）→ ps_bloomA → ps_bloomB（ぼかし 2 回）→ ps_post（本編の面・窓の画素の Rgba8）→ 自分の AfterViewTransform。
// 画面へ置くのは、FXAA があれば最後の Pass をならした面・無ければ本編の面（ps_post を作らない）か最後の Pass の写し。
pub mod PostStack.Internal.Passes {

    use PostStack.{Fields, Issue, Bloom, Vignette, ColorGrade, ViewTransform, DepthOfField, Quality, Msaa, CustomAt, CustomPass, Read, DebugView, Distortion, DistortionMask}
    use ShaderDoc.{Axis, BinOp, Field, Shade, Out, TexChan, UnOp}

    def depthPass(): String = PostStack.depthName()
    def softPass(): String = "ps_soft"
    def brightPass(): String = "ps_bright"
    def bloomPassA(): String = "ps_bloomA"
    def bloomPassB(): String = "ps_bloomB"
    def linearPass(): String = "ps_linear"
    def distortPass(): String = "ps_distort"

    /// 読む点の数と縮み（Quality から）。basis = 縮んだ Pass の倍率の基準。
    type alias Tuning = { bloomTaps = Int32, bloomScale = Float64, blurTaps = Int32, basis = RenderTarget.Basis }

    /// Fixed は縮みを design の解像度に対して取る（今までのゲームの手書きの Pass と同じ大きさ）。ほかは窓の画素に対して。
    def tuningOf(q: Quality): Tuning = match q {
        case Quality.Low      => { bloomTaps = 8, bloomScale = 0.25, blurTaps = 8, basis = RenderTarget.Basis.Window }
        case Quality.High     => { bloomTaps = 16, bloomScale = 0.5, blurTaps = 16, basis = RenderTarget.Basis.Window }
        case Quality.Fixed(t) => { bloomTaps = t#bloomTaps, bloomScale = t#bloomScale, blurTaps = t#blurTaps, basis = RenderTarget.Basis.Design }
        case _                => { bloomTaps = 12, bloomScale = 0.5, blurTaps = 12, basis = RenderTarget.Basis.Window }
    }

    /// 奥行きのぼかしの、場面から作る奥行きの絵と、本編の面が読む離れ具合（0 = くっきり・1 = ぼかし切る）。
    type alias Focus = { depthItem = Render.PlacedItem, amount = Field, blur = Float64, params = Map[String, Float64] }

    /// ぼかした場面の半径（Physical の F 値から出すぼけは、この半径を 1 とした割合で混ぜる）。
    def physicalBlur(): Float64 = 0.012

    /// センサーの高さ（mm・Blender の Camera の既定の 24 mm を縦に合わせた物）。
    def sensorHeightMm(): Float64 = 24.0

    // ── 組む ──

    pub def build(input: PostStack.BuildInput, f: Fields): { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[Issue] } =
        let tune = tuningOf(f#quality);
        let aspect = input#size#x / input#size#y;
        let fill = (spec: ShaderDoc.Spec) -> fullFill(input#size, spec);
        let black = RenderTarget.LoadOp.Clear(Color.rgb(0.0, 0.0, 0.0));
        let hdrAt = (sc: Float64) -> RenderTarget.withHdr({ scale = sc | RenderTarget.windowDescriptor() });
        let shrunk = (sc: Float64) -> RenderTarget.withHdr({ scale = sc, basis = tune#basis | RenderTarget.windowDescriptor() });
        let reserved = f#custom |> List.filter(c -> String.startsWith(prefix = PostStack.reservedPrefix(), c#name));
        let customs = f#custom |> List.filter(c -> not String.startsWith(prefix = PostStack.reservedPrefix(), c#name));
        let before = customs |> List.filter(c -> c#at == CustomAt.BeforeBloom);
        let after = customs |> List.filter(c -> c#at == CustomAt.AfterViewTransform);
        let scenes = scenesOf(input#world);
        let largest = largestScene(scenes);
        let customDepth = List.exists(c -> List.memberOf(Read.SceneDepth, c#reads), customs);
        let wantsDepth = Option.nonEmpty(f#depthOfField) or customDepth;
        let afterCustom = before |> List.map(c -> c#name) |> List.last |> Option.getWithDefault(PostStack.sceneName());
        let distortion = f#distortion |> Option.filter(isDistortionVisible);
        let distortTarget = if (isHdrNeeded(f)) RenderTarget.withHdr(RenderTarget.windowDescriptor()) else RenderTarget.windowDescriptor();
        let distortPasses = distortion |> Option.map(d ->
            ({ name = distortPass(), clear = black,
               items = Render.withShaderParams(distortParams(input#size, f#time, d), fill(distortSpec(aspect, input#size, afterCustom, d))) :: Nil },
             distortTarget) :: Nil)
            |> Option.getWithDefault(Nil);
        let current = if (Option.isEmpty(distortion)) afterCustom else distortPass();
        let focus = forM (d <- f#depthOfField; s <- largest; fo <- focusOf(d, s)) yield fo;
        let depthOnly = if (Option.isEmpty(focus) and customDepth) largest |> Option.map(s -> depthItemOf(s, 0.0, cameraFar(s))) else None;
        let issues = List.flatten(
            (reserved |> List.map(c -> Issue.ReservedPassName(c#name)))
                :: (if (wantsDepth and Option.isEmpty(largest)) Issue.NoScene3d :: Nil else Nil)
                :: (if (wantsDepth and List.length(scenes) > 1) Issue.SeveralScenes(List.length(scenes)) :: Nil else Nil)
                :: Nil);
        let sceneTarget = RenderTarget.withMsaa(samplesOf(f#msaa),
            if (isHdrNeeded(f)) RenderTarget.withHdr(RenderTarget.windowDescriptor()) else RenderTarget.windowDescriptor());
        let scenePass = ({ name = PostStack.sceneName(), clear = RenderTarget.LoadOp.Clear(input#clear), items = input#world }, sceneTarget);
        let beforePasses = before |> List.map(c ->
            ({ name = c#name, clear = black, items = fill(c#spec) :: Nil }, hdrAt(c#scale)));
        let depthItem = match focus {
            case Some(fo) => Some(fo#depthItem)
            case None     => depthOnly
        };
        let depthPasses = depthItem |> Option.map(item ->
            ({ name = depthPass(), clear = RenderTarget.LoadOp.Clear(Color.rgb(1.0, 1.0, 1.0)), items = item :: Nil }, shrunk(0.5)) :: Nil)
            |> Option.getWithDefault(Nil);
        let toLinear = isLinear(f#viewTransform);
        // WhyNot: ぼかしの中で線形へ戻さない — TexBlur は読む点ごとに式を挟めず、画面の値をぼかしてから戻すと明るい縁が細る。
        let softSource = if (toLinear) linearPass() else current;
        let softPasses = focus |> Option.map(fo ->
            List.append(if (toLinear) ({ name = linearPass(), clear = black, items = fill(linearSpec(current)) :: Nil }, hdrAt(1.0)) :: Nil else Nil,
                        ({ name = softPass(), clear = black, items = fill(blurSpec(aspect, softPass(), softSource, fo#blur, tune#blurTaps)) :: Nil }, shrunk(0.5)) :: Nil))
            |> Option.getWithDefault(Nil);
        let bloomPasses = f#bloom |> Option.map(b ->
            ({ name = brightPass(), clear = black, items = fill(brightSpec(current, toLinear, b)) :: Nil }, shrunk(tune#bloomScale))
                :: ({ name = bloomPassA(), clear = black, items = fill(blurSpec(aspect, bloomPassA(), brightPass(), b#size, tune#bloomTaps)) :: Nil }, shrunk(tune#bloomScale * 0.5))
                :: ({ name = bloomPassB(), clear = black, items = fill(blurSpec(aspect, bloomPassB(), bloomPassA(), b#size * 0.5, tune#bloomTaps)) :: Nil }, shrunk(tune#bloomScale * 0.5))
                :: Nil)
            |> Option.getWithDefault(Nil);
        let focusParams = focus |> Option.map(fo -> fo#params) |> Option.getWithDefault(Map.empty());
        let main = Render.withShaderParams(Map.union(paramsOf(f), focusParams), fill(mainSpec(aspect, current, f, focus)));
        let finishing = finishingOf(input#size, f#fxaa, main, after);
        let all = List.flatten((scenePass :: beforePasses) :: distortPasses :: depthPasses :: softPasses :: bloomPasses :: finishing#passes :: Nil);
        { plan = { targets = List.toMap(List.map(e -> (fst(e)#name, snd(e)), all)) | Render.passPlan(List.map(fst, all)) },
          present = finishing#present, issues = issues }

    /// 本編の面の後ろ: ps_post と自分の AfterViewTransform の Pass、画面へ置く面。
    def finishingOf(size: Vec2.Vec2, fxaa: Bool, main: Render.PlacedItem, after: List[CustomPass]):
            { passes = List[(Render.Pass, RenderTarget.Descriptor)], present = Render.PlacedItem } =
        let black = RenderTarget.LoadOp.Clear(Color.rgb(0.0, 0.0, 0.0));
        if (not fxaa and List.isEmpty(after)) { passes = Nil, present = main }
        else {
            let post = ({ name = PostStack.postName(), clear = black, items = main :: Nil }, RenderTarget.windowDescriptor());
            let afterPasses = after |> List.map(c ->
                ({ name = c#name, clear = black, items = fullFill(size, c#spec) :: Nil }, { scale = c#scale | RenderTarget.windowDescriptor() }));
            let last = after |> List.map(c -> c#name) |> List.last |> Option.getWithDefault(PostStack.postName());
            let present = if (fxaa) fullFill(size, PostProcess.fxaaSpec(last)) else fullFill(size, copySpec(last));
            { passes = post :: afterPasses, present = present }
        }

    /// 場面の Pass を 1 を超える値を持てる形にするか（ブルーム・露出・曲線が 1 を超える値を読む時と、自分の Spec がある時）。
    def isHdrNeeded(f: Fields): Bool =
        Option.nonEmpty(f#bloom) or not isStandard(f#viewTransform) or f#exposure != 0.0 or not List.isEmpty(f#custom)

    def isStandard(v: ViewTransform): Bool = match v {
        case ViewTransform.Standard => true
        case _                      => false
    }

    /// 場面の値を線形へ戻してから掛けるか（Blender の view transform の物）。
    def isLinear(v: ViewTransform): Bool = match v {
        case ViewTransform.AcesNarkowicz(_) => false
        case _                              => true
    }

    def samplesOf(m: Msaa): Int32 = match m {
        case Msaa.Off => 1
        case Msaa.X4  => 4
    }

    /// 本編の面に渡す数（毎コマ動かしても Spec の形は変わらない物）。
    def paramsOf(f: Fields): Map[String, Float64] =
        let satAfter = match f#viewTransform {
            case ViewTransform.AcesNarkowicz(a) => 1.0 + a#saturationAfter
            case _                              => 1.0
        };
        Map#{ "ps_exposure" => Float64.pow(base = 2.0, f#exposure),
              "ps_bloom" => f#bloom |> Option.map(b -> b#strength) |> Option.getWithDefault(0.0),
              "ps_vignette" => f#vignette |> Option.map(v -> v#strength) |> Option.getWithDefault(0.0),
              "ps_saturation" => f#colorGrade |> Option.map(c -> c#saturation) |> Option.getWithDefault(1.0),
              "ps_satAfter" => satAfter }

    // ── 3D の場面と奥行きの絵 ──

    /// View の絵の中の 3D の場面（一番上と、切り抜きの中）。置き場所つき。
    def scenesOf(items: List[Render.PlacedItem]): List[(Vec2.Vec2, Scene3d.Scene3dCmd)] =
        items |> List.filterMap(p -> sceneIn(p#at, p#item))

    def sceneIn(at: Vec2.Vec2, item: Render.Item): Option[(Vec2.Vec2, Scene3d.Scene3dCmd)] = match item {
        case Render.Item.Scene3d(cmd) => Some((at, cmd))
        case Render.Item.Clipped(c)   => sceneIn(at, c#inner)
        case _                        => None
    }

    def largestScene(scenes: List[(Vec2.Vec2, Scene3d.Scene3dCmd)]): Option[(Vec2.Vec2, Scene3d.Scene3dCmd)] =
        scenes |> List.foldLeft((best, s) -> match best {
            case Some(b) if area(snd(b)) >= area(snd(s)) => best
            case _                                       => Some(s)
        }, None)

    def area(cmd: Scene3d.Scene3dCmd): Float64 = cmd#size#x * cmd#size#y

    def cameraFar(s: (Vec2.Vec2, Scene3d.Scene3dCmd)): Float64 = snd(s)#camera#far

    /// 場面 s の奥行きの絵（目からの距離が near で黒・near + range で白）。光・空・景色は持たない（奥行きに要らない）。
    def depthItemOf(s: (Vec2.Vec2, Scene3d.Scene3dCmd), near: Float64, range: Float64): Render.PlacedItem =
        let (at, cmd) = s;
        Render.scene3d(at, { instances = cmd#instances, groups = cmd#groups, billboards = cmd#billboards, textures = cmd#textures,
                             time = cmd#time, resolution = cmd#resolution, zIndex = cmd#zIndex, unitsPerMeter = cmd#unitsPerMeter,
                             output = Scene3d.Output.Depth({ near = near, range = range }) | Scene3d.scene(cmd#camera, cmd#size) })

    /// 奥行きのぼかしの奥行きの絵と離れ具合。ぼかさない値（blur ≤ 0・F 値 ≤ 0・ピントが目の前）なら None。
    def focusOf(d: DepthOfField, s: (Vec2.Vec2, Scene3d.Scene3dCmd)): Option[Focus] = match d {
        case DepthOfField.DepthBand(b) =>
            if (b#blur <= 0.0) None
            else {
                // ピントの奥行き（灰色の 0.5）からの離れ具合（0 = ピント・1 = 帯の端）。
                let away = mul(k(2.0), Field.Un({ op = UnOp.Abs, of = sub(Field.Ref("ps_depth"), k(0.5)) }));
                Some({ depthItem = depthItemOf(s, b#focusDistance - b#range, 2.0 * b#range),
                       amount = Field.Smoothstep({ lo = b#band, hi = b#band + b#soft, of = away }), blur = b#blur, params = Map.empty() })
            }
        case DepthOfField.Physical(cam) =>
            let cmd = snd(s);
            let unit = cmd#unitsPerMeter;
            let focusMm = cam#focusDistance * 1000.0;
            let focalMm = sensorHeightMm() / 2.0 * Num.cos(cmd#camera#fovY / 2.0) / Num.sin(cmd#camera#fovY / 2.0);
            if (cam#fStop <= 0.0 or focusMm <= focalMm or unit <= 0.0) None
            else {
                // 薄いレンズのぼけの径 c = f² / (N (s − f)) × |d − s| / d（mm）を、画面の高さの割合の半径にし、ぼかした場面の半径で割る。
                let gain = focalMm * focalMm / (cam#fStop * (focusMm - focalMm)) / sensorHeightMm() / 2.0 / physicalBlur();
                let far = cmd#camera#far;
                let dist = mul(Field.Ref("ps_depth"), k(far));
                let ratio = Field.Bin({ op = BinOp.Div, a = Field.Un({ op = UnOp.Abs, of = sub(dist, p("ps_focus")) }), b = dist });
                Some({ depthItem = depthItemOf(s, 0.0, far), amount = Field.Un({ op = UnOp.Sat, of = mul(ratio, p("ps_cocGain")) }), blur = physicalBlur(),
                       params = Map#{ "ps_focus" => cam#focusDistance * unit, "ps_cocGain" => gain } })
            }
    }

    // ── 画面の歪み ──

    def isDistortionVisible(d: Distortion): Bool =
        d#noiseSize > 0.0 and (d#strength#x != 0.0 or d#strength#y != 0.0)

    /// ノイズを折り返すマスの数（FbmTile の period）。画面に並ぶ粒の数より十分大きく、繰り返しが見えない数。
    /// 横に並ぶ粒の数を 2 の累乗へ切り上げた数（下限 64）。
    def distortPeriod(size: Vec2.Vec2, d: Distortion): Float64 =
        let across = size#x / d#noiseSize;
        def grow(p: Float64): Float64 = if (p >= across) p else grow(p * 2.0);
        grow(64.0)

    def distortOctaves(): Int32 = 3

    /// FbmTile の値の真ん中（振れ幅 0.5 から半分ずつ足すので 0..2c に入り、平均が c）。
    def distortCenter(): Float64 = 0.5 * (1.0 - Float64.pow(base = 0.5, Int32.toFloat64(distortOctaves())))

    /// 面に渡す数: ps_distortX・Y = ずらす最大の量（uv）・ps_distortPhaseU・V = 時刻ぶん模様を流した読む位置のずれ（uv）。
    // WhyNot: 時刻を Field.Time（面の t）で掛けない — 時刻 × 速さが増え続けると GL の float32 の hash が崩れて模様が出る。流した量を period で折り返してから渡す。
    def distortParams(size: Vec2.Vec2, time: Float64, d: Distortion): Map[String, Float64] =
        let cells = size#y / d#noiseSize;
        let period = distortPeriod(size, d);
        let wrap = (x: Float64) -> x - period * Float64.floor(x / period);
        let phase = (speed: Float64) -> 0.0 - wrap(speed * time / d#noiseSize) / cells;
        Map#{ "ps_distortX" => d#strength#x / size#x, "ps_distortY" => d#strength#y / size#y,
              "ps_distortPhaseU" => phase(d#speed#x), "ps_distortPhaseV" => phase(d#speed#y) }

    /// 歪みを掛ける重み（0..1・画素の位置で読む）。
    def distortWeight(m: DistortionMask): Field = match m {
        case DistortionMask.Full          => k(1.0)
        // WhyNot: soft = 0 をそのまま渡さない — GLSL の smoothstep は lo ≥ hi の答えが決まっていない。
        case DistortionMask.BottomBand(b) => Field.Smoothstep({ lo = b#top, hi = b#top + Float64.max(0.001, b#soft), of = Field.Uv({ axis = Axis.V }) })
        case DistortionMask.Texture(name) => linear(Field.Tex({ name = name, chan = TexChan.R }))
    }

    /// 画素ごとの読む位置のずれ（uv）を ps_du・ps_dv に置く binding。
    /// Fbm は uv を 1 つの倍率でしか掛けないので、Shift の dx に u × (aspect − 1) を足して (aspect·u, v) で読ませ、粒を丸くする。
    def distortOffsetBindings(aspect: Float64, size: Vec2.Vec2, d: Distortion): List[(String, Field)] =
        let cells = size#y / d#noiseSize;
        let period = distortPeriod(size, d);
        let noise = (seed: Int32) -> Field.Shift({
            dx = add(mul(Field.Uv({ axis = Axis.U }), k(aspect - 1.0)), p("ps_distortPhaseU")),
            dy = p("ps_distortPhaseV"),
            of = Field.FbmTile({ octaves = distortOctaves(), scale = cells, period = { x = period, y = period }, seed = seed }) });
        let c = distortCenter();
        let signed = (ref: String) -> mul(sub(Field.Ref(ref), k(c)), k(1.0 / c));
        ("ps_dn_u", noise(11)) :: ("ps_dn_v", noise(23)) :: ("ps_dw", distortWeight(d#mask))
            :: ("ps_du", mul(signed("ps_dn_u"), mul(p("ps_distortX"), Field.Ref("ps_dw"))))
            :: ("ps_dv", mul(signed("ps_dn_v"), mul(p("ps_distortY"), Field.Ref("ps_dw")))) :: Nil

    /// source をずらして読み、そのまま写す面。
    // WhyNot: 奥行きの絵（ps_depth）は歪めない — 3D の場面から直に作るので、ぼかしの縁が strength px ほど歪んだ場面とずれる。数 px なので、
    // 本編の面でノイズをもう 1 回組んで奥行きを同じずれで読む値段を払わない。
    def distortSpec(aspect: Float64, size: Vec2.Vec2, source: String, d: Distortion): ShaderDoc.Spec =
        let read = chan -> Field.Shift({ dx = Field.Ref("ps_du"), dy = Field.Ref("ps_dv"), of = linear(Field.Tex({ name = source, chan = chan })) });
        { name = "ps_distort", cycleRate = 0.0, bindings = distortOffsetBindings(aspect, size, d),
          out = rgbOf(read(TexChan.R), read(TexChan.G), read(TexChan.B)) }

    // ── 面 ──

    def fullFill(size: Vec2.Vec2, spec: ShaderDoc.Spec): Render.PlacedItem =
        Render.shaderFill(spec, { position = Vec2.zero(), size = size }, 0.0, 0)

    def k(v: Float64): Field = Field.Const(v)
    def p(name: String): Field = Field.Param({ name = name })
    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })
    def sub(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Sub, a = a, b = b })
    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })
    def maxF(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Max, a = a, b = b })
    def minF(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Min, a = a, b = b })
    def linear(f: Field): Field = Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = f })
    def rgbOf(r: Field, g: Field, b: Field): Out = Out.Fill({ shade = Shade.Rgb({ r = r, g = g, b = b }), alpha = k(1.0) })

    def copySpec(source: String): ShaderDoc.Spec =
        let t = chan -> Field.Tex({ name = source, chan = chan });
        { name = "ps_copy:${source}", cycleRate = 0.0, bindings = Nil, out = rgbOf(t(TexChan.R), t(TexChan.G), t(TexChan.B)) }

    /// 場面の値を線形へ戻して写す面（ぼかした場面の元）。
    def linearSpec(source: String): ShaderDoc.Spec =
        let t = chan -> toLinear(Field.Tex({ name = source, chan = chan }));
        { name = "ps_linear", cycleRate = 0.0, bindings = Nil, out = rgbOf(t(TexChan.R), t(TexChan.G), t(TexChan.B)) }

    /// 場面の明るい所だけを残す（明るさが threshold から threshold + smoothness の間でなめらかに 0 → 1）。toLin = 線形へ戻してから比べる。
    def brightSpec(source: String, toLin: Bool, b: Bloom): ShaderDoc.Spec =
        let read = chan -> {
            let t = linear(Field.Tex({ name = source, chan = chan }));
            if (toLin) toLinear(t) else t
        };
        let luma = PostProcess.luma709(read(TexChan.R), read(TexChan.G), read(TexChan.B));
        let over = Field.Smoothstep({ lo = b#threshold, hi = b#threshold + Float64.max(0.01, b#smoothness), of = luma });
        let chan = c -> mul(read(c), Field.Ref("over"));
        { name = "ps_bright", cycleRate = 0.0, bindings = ("over", over) :: Nil, out = rgbOf(chan(TexChan.R), chan(TexChan.G), chan(TexChan.B)) }

    /// 前の Pass を Linear で読んでぼかし、そのまま写す面（ぼかした場面とブルームの 2 段で共用）。
    def blurSpec(aspect: Float64, name: String, src: String, radius: Float64, taps: Int32): ShaderDoc.Spec =
        let b = chan -> linear(Field.TexBlur({ name = src, chan = chan, radius = { x = radius / aspect, y = radius },
                                               taps = ShaderDoc.blurTaps(taps), amount = k(1.0) }));
        { name = "ps_blur_${name}", cycleRate = 0.0, bindings = Nil, out = rgbOf(b(TexChan.R), b(TexChan.G), b(TexChan.B)) }

    /// 本編の面: 場面（奥行きでぼかした物）にブルームを足し、色を仕上げ、ビネットを掛け、露出と曲線で表示の値にする。
    def mainSpec(aspect: Float64, current: String, f: Fields, focus: Option[Focus]): ShaderDoc.Spec =
        let scene = (chan: TexChan) -> if (isLinear(f#viewTransform)) toLinear(Field.Tex({ name = current, chan = chan })) else Field.Tex({ name = current, chan = chan });
        let sharp = (chan: TexChan) -> match focus {
            case Some(_) => Field.Blend({ a = scene(chan), b = linear(Field.Tex({ name = softPass(), chan = chan })), by = Field.Ref("ps_blurAmount") })
            case None    => scene(chan)
        };
        let bloomed = (chan: TexChan) -> match f#bloom {
            case Some(_) => add(sharp(chan), mul(p("ps_bloom"), linear(Field.Tex({ name = bloomPassB(), chan = chan }))))
            case None    => sharp(chan)
        };
        let vignetted = (x: Field) -> match f#vignette {
            case Some(_) => mul(x, Field.Ref("ps_vig"))
            case None    => x
        };
        let focusBindings = focus |> Option.map(fo -> ("ps_depth", linear(Field.Tex({ name = depthPass(), chan = TexChan.R }))) :: ("ps_blurAmount", fo#amount) :: Nil)
            |> Option.getWithDefault(Nil);
        let vigBindings = f#vignette |> Option.map(v -> ("ps_vig", vignetteField(aspect, v)) :: Nil) |> Option.getWithDefault(Nil);
        let colorBindings = match f#colorGrade {
            case Some(c) =>
                ("ps_r0", bloomed(TexChan.R)) :: ("ps_g0", bloomed(TexChan.G)) :: ("ps_b0", bloomed(TexChan.B))
                    :: List.append(gradeBindings(c, Field.Ref("ps_r0"), Field.Ref("ps_g0"), Field.Ref("ps_b0")),
                                   ("ps_r", vignetted(Field.Ref("ps_cr"))) :: ("ps_g", vignetted(Field.Ref("ps_cg"))) :: ("ps_b", vignetted(Field.Ref("ps_cb"))) :: Nil)
            case None =>
                ("ps_r", vignetted(bloomed(TexChan.R))) :: ("ps_g", vignetted(bloomed(TexChan.G))) :: ("ps_b", vignetted(bloomed(TexChan.B))) :: Nil
        };
        let mapped = mappedBindings(f#viewTransform);
        { name = "ps_main", cycleRate = 0.0,
          bindings = List.flatten(focusBindings :: vigBindings :: colorBindings :: mapped :: Nil),
          out = outOf(f, focus) }

    /// ビネットの重み（1 = そのまま）。
    def vignetteField(aspect: Float64, v: Vignette): Field =
        sub(k(1.0), mul(p("ps_vignette"), Field.Smoothstep({ lo = v#inner, hi = v#outer,
            of = Field.RadialAspect({ cx = v#center#x, cy = v#center#y, aspect = aspect }) })))

    /// ps_tr・ps_tg・ps_tb に、露出を掛けて曲線で表示の値にした色を置く。
    // WhyNot: PostProcess.tonemappedWith を使わない — 露出を Const で書き込むので、毎コマ露出を動かすと描き手が program を作り直す。
    def mappedBindings(v: ViewTransform): List[(String, Field)] =
        let ref = Field.Ref;
        let exposed = (ch: String) -> mul(ref(ch), p("ps_exposure"));
        match v {
            case ViewTransform.Standard =>
                ("ps_tr", toSrgb(exposed("ps_r"))) :: ("ps_tg", toSrgb(exposed("ps_g"))) :: ("ps_tb", toSrgb(exposed("ps_b"))) :: Nil
            case ViewTransform.KhronosNeutral =>
                ("ps_er", exposed("ps_r")) :: ("ps_eg", exposed("ps_g")) :: ("ps_eb", exposed("ps_b"))
                    :: List.append(neutralBindings(), ("ps_tr", toSrgb(ref("ps_nr"))) :: ("ps_tg", toSrgb(ref("ps_ng"))) :: ("ps_tb", toSrgb(ref("ps_nb"))) :: Nil)
            case ViewTransform.AgX =>
                ("ps_agx_exposed_r", exposed("ps_r")) :: ("ps_agx_exposed_g", exposed("ps_g")) :: ("ps_agx_exposed_b", exposed("ps_b"))
                    :: List.append(agxBindings(), ("ps_tr", toSrgb(ref("ps_agx_out_r"))) :: ("ps_tg", toSrgb(ref("ps_agx_out_g"))) :: ("ps_tb", toSrgb(ref("ps_agx_out_b"))) :: Nil)
            case ViewTransform.AcesNarkowicz(a) =>
                let curve = (ch: String) -> PostProcess.tonemapCurve(PostProcess.Tonemap.AcesFitted, a#whitePoint, maxF(exposed(ch), k(0.0)));
                ("ps_tr", curve("ps_r")) :: ("ps_tg", curve("ps_g")) :: ("ps_tb", curve("ps_b")) :: Nil
        }

    /// 3 つの binding（ps_<stage>_r・_g・_b）に、行列 m（行ごと）を ps_<source>_r・_g・_b に掛けた値を置く。
    def matrixBindings(stage: String, source: String, m: List[(Float64, Float64, Float64)]): List[(String, Field)] =
        let ref = Field.Ref;
        let row = (r: (Float64, Float64, Float64)) -> {
            let (a, b, c) = r;
            add(add(mul(k(a), ref("${source}_r")), mul(k(b), ref("${source}_g"))), mul(k(c), ref("${source}_b")))
        };
        List.zip("r" :: "g" :: "b" :: Nil, m) |> List.map(e -> ("${stage}_${fst(e)}", row(snd(e))))

    /// 3 つの binding に、ps_<source> の成分ごとに f を掛けた値を置く。
    def perChannel(stage: String, source: String, f: Field -> Field): List[(String, Field)] =
        ("r" :: "g" :: "b" :: Nil) |> List.map(ch -> ("${stage}_${ch}", f(Field.Ref("${source}_${ch}"))))

    /// AgX の Base。ps_agx_exposed_r・_g・_b（露出を掛けた線形の sRGB）から ps_agx_out_r・_g・_b（線形の sRGB）を作る。
    /// Rec.2020 へ移し、色を少し内へ寄せ（inset）、log2 で中間の灰色の −10〜+6.5 stop を 0..1 に詰め、S 字の曲線（中間の灰色で傾き 2.4・
    /// 両端は 1.5 乗の双曲線で 0 と 1 に寄る）を掛け、2.4 乗で線形へ戻し、色を外へ戻して（outset）sRGB へ戻す。
    /// inset・outset の行列は three.js（MIT）と Filament（Apache-2.0）が公開している AgX の行列。
    def agxBindings(): List[(String, Field)] =
        let lo = -12.47393;
        let hi = 4.026069;
        List.flatten(
            matrixBindings("ps_agx_rec2020", "ps_agx_exposed", agxFromSrgb())
                :: matrixBindings("ps_agx_inset", "ps_agx_rec2020", agxInset())
                :: perChannel("ps_agx_log", "ps_agx_inset", x -> Field.Un({ op = UnOp.Sat, of = mul(sub(Field.Un({ op = UnOp.Log2, of = x }), k(lo)), k(1.0 / (hi - lo))) }))
                :: perChannel("ps_agx_curve", "ps_agx_log", agxCurve(lo, hi))
                :: perChannel("ps_agx_linear", "ps_agx_curve", x -> Field.Pow({ of = x, p = 2.4 }))
                :: matrixBindings("ps_agx_outset", "ps_agx_linear", agxOutset())
                :: matrixBindings("ps_agx_out", "ps_agx_outset", agxToSrgb())
                :: Nil)

    /// AgX の S 字の曲線（0..1 → 0..1）。中間の灰色（0.18）の位置で 0.18^(1/2.4) を通り、そこでの傾きが 2.4。
    /// 両側は t / (1 + |t|^1.5)^(1/1.5) の形で、0 と 1 にちょうど届くよう倍率を決める。
    def agxCurve(lo: Float64, hi: Float64): Field -> Field = x -> {
        let slope = 2.4;
        let power = 1.5;
        let xp = (Num.log(0.18) / Num.log(2.0) - lo) / (hi - lo);
        let yp = Float64.pow(base = 0.18, 1.0 / 2.4);
        let side = (xs: Float64, ys: Float64) -> {
            let u = Float64.pow(base = Float64.pow(base = slope * xs / ys, power) - 1.0, 1.0 / power);
            let scale = slope * xs / u;
            let w = mul(sub(x, k(xp)), k(slope / scale));
            add(k(yp), mul(k(scale), Field.Bin({ op = BinOp.Div, a = w,
                b = Field.Pow({ of = add(k(1.0), Field.Pow({ of = Field.Un({ op = UnOp.Abs, of = w }), p = power })), p = 1.0 / power }) })))
        };
        Field.Blend({ a = side(xp, yp), b = side(1.0 - xp, 1.0 - yp), by = Field.Bin({ op = BinOp.Step, a = k(xp), b = x }) })
    }

    def agxFromSrgb(): List[(Float64, Float64, Float64)] =
        (0.6274040, 0.3292820, 0.0433136) :: (0.0690970, 0.9195400, 0.0113612) :: (0.0163916, 0.0880132, 0.8955950) :: Nil

    def agxToSrgb(): List[(Float64, Float64, Float64)] =
        (1.6604910, -0.5876411, -0.0728499) :: (-0.1245505, 1.1328999, -0.0083494) :: (-0.0181508, -0.1005789, 1.1187297) :: Nil

    def agxInset(): List[(Float64, Float64, Float64)] =
        (0.856627153315983, 0.0951212405381588, 0.0482516061458583)
            :: (0.137318972929847, 0.761241990602591, 0.101439036467562)
            :: (0.11189821299995, 0.0767994186031903, 0.811302368396859) :: Nil

    def agxOutset(): List[(Float64, Float64, Float64)] =
        (1.1271005818144368, -0.11060664309660323, -0.016493938717834573)
            :: (-0.1413297634984383, 1.157823702216272, -0.016493938717834257)
            :: (-0.14132976349843826, -0.11060664309660294, 1.2519364065950405) :: Nil

    /// Khronos PBR Neutral（Khronos の仕様の式）。ps_er・ps_eg・ps_eb（露出を掛けた線形の値）から ps_nr・ps_ng・ps_nb（線形の値）を作る。
    /// 一番暗い成分で暗い所を少し沈め、一番明るい成分が 0.76 を超えたら肩で 1 へ寄せ、寄せた分だけ白へ近づける。
    def neutralBindings(): List[(String, Field)] =
        let ref = Field.Ref;
        let start = 0.8 - 0.04;
        let d = 1.0 - start;
        let lo = minF(ref("ps_er"), minF(ref("ps_eg"), ref("ps_eb")));
        let offset = Field.Blend({ a = k(0.04), b = sub(ref("ps_lo"), mul(k(6.25), mul(ref("ps_lo"), ref("ps_lo")))),
                                   by = Field.Bin({ op = BinOp.Step, a = ref("ps_lo"), b = k(0.08) }) });
        let peak = maxF(ref("ps_kr"), maxF(ref("ps_kg"), ref("ps_kb")));
        let newPeak = sub(k(1.0), Field.Bin({ op = BinOp.Div, a = k(d * d), b = add(ref("ps_pk"), k(d - start)) }));
        let toWhite = sub(k(1.0), Field.Bin({ op = BinOp.Div, a = k(1.0), b = add(mul(k(0.15), sub(ref("ps_pk"), ref("ps_np"))), k(1.0)) }));
        let compressed = (ch: String) -> Field.Blend({ a = mul(ref(ch), Field.Bin({ op = BinOp.Div, a = ref("ps_np"), b = ref("ps_pk") })), b = ref("ps_np"), by = ref("ps_wh") });
        let pick = (ch: String) -> Field.Blend({ a = ref(ch), b = compressed(ch), by = Field.Bin({ op = BinOp.Step, a = k(start), b = ref("ps_pk") }) });
        ("ps_lo", lo) :: ("ps_off", offset)
            :: ("ps_kr", sub(ref("ps_er"), ref("ps_off"))) :: ("ps_kg", sub(ref("ps_eg"), ref("ps_off"))) :: ("ps_kb", sub(ref("ps_eb"), ref("ps_off")))
            :: ("ps_pk", peak) :: ("ps_np", newPeak) :: ("ps_wh", toWhite)
            :: ("ps_nr", pick("ps_kr")) :: ("ps_ng", pick("ps_kg")) :: ("ps_nb", pick("ps_kb")) :: Nil

    /// 面の出力（途中の絵を見る時はその絵）。
    def outOf(f: Fields, focus: Option[Focus]): Out =
        let ref = Field.Ref;
        match (f#debugView, f#bloom, focus) {
            case (DebugView.Scene, _, _)       => rgbOf(ref("ps_r"), ref("ps_g"), ref("ps_b"))
            case (DebugView.Bloom, Some(_), _) =>
                let t = chan -> linear(Field.Tex({ name = bloomPassB(), chan = chan }));
                rgbOf(t(TexChan.R), t(TexChan.G), t(TexChan.B))
            case (DebugView.Depth, _, Some(_)) => rgbOf(ref("ps_depth"), ref("ps_depth"), ref("ps_depth"))
            case _                             => finalOut(f#viewTransform)
        }

    /// 仕上がりの色（AcesNarkowicz は曲線の後に 0..1 の色の彩度を足す）。
    def finalOut(v: ViewTransform): Out =
        let (r, g, b) = (Field.Ref("ps_tr"), Field.Ref("ps_tg"), Field.Ref("ps_tb"));
        match v {
            case ViewTransform.AcesNarkowicz(a) if a#saturationAfter != 0.0 =>
                let lum = PostProcess.luma709(r, g, b);
                let graded = (c: Field) -> add(lum, mul(sub(c, lum), p("ps_satAfter")));
                rgbOf(graded(r), graded(g), graded(b))
            case _ => rgbOf(r, g, b)
        }

    // ── 色の仕上げ（Blender の Color Balance の Lift / Gamma / Gain と、Hue/Saturation/Value の Saturation） ──

    /// 線形の値 → sRGB の曲線で縮めた値（負は 0）。
    pub def toSrgb(c: Field): Field =
        let lin = mul(c, k(12.92));
        let curved = sub(mul(k(1.055), Field.Pow({ of = c, p = 1.0 / 2.4 })), k(0.055));
        Field.Blend({ a = maxF(lin, k(0.0)), b = curved, by = Field.Bin({ op = BinOp.Step, a = k(0.0031308), b = c }) })

    /// sRGB の曲線で縮めた値 → 線形の値（負は 0）。
    pub def toLinear(c: Field): Field =
        let lin = mul(c, k(1.0 / 12.92));
        let curved = Field.Pow({ of = mul(add(c, k(0.055)), k(1.0 / 1.055)), p = 2.4 });
        Field.Blend({ a = maxF(lin, k(0.0)), b = curved, by = Field.Bin({ op = BinOp.Step, a = k(0.04045), b = c }) })

    /// ps_cr・ps_cg・ps_cb に仕上げた色を置く。lift・gain は sRGB の曲線の上で掛け（Blender の式どおり 1 往復する）、gamma は線形へ戻した後の累乗。
    /// saturation は HSV の S への掛け算と同じ（一番明るい成分を保ち、ほかを近づける・遠ざける。S が 1 を超える所で止める）。
    def gradeBindings(c: ColorGrade, r: Field, g: Field, b: Field): List[(String, Field)] =
        let white = (x: Color) -> x#r == 1.0 and x#g == 1.0 and x#b == 1.0;
        // WhyNot: lift・gamma・gain が全部 1 の時も 1 往復の式を通さない — 画素ごとに sRGB の曲線を 2 回と累乗を 3 回払い、saturation だけの preset でスマホが重い。
        let neutralBalance = white(c#lift) and white(c#gamma) and white(c#gain);
        let one = (x: Field, lift: Float64, gamma: Float64, gain: Float64) -> if (neutralBalance) x else {
            let y = maxF(mul(add(mul(sub(toSrgb(x), k(1.0)), k(2.0 - lift)), k(1.0)), k(gain)), k(0.0));
            Field.Pow({ of = toLinear(y), p = if (gamma <= 0.0) 1000000.0 else 1.0 / gamma })
        };
        let mx = maxF(Field.Ref("ps_lr"), maxF(Field.Ref("ps_lg"), Field.Ref("ps_lb")));
        let mn = minF(Field.Ref("ps_lr"), minF(Field.Ref("ps_lg"), Field.Ref("ps_lb")));
        let limit = Field.Bin({ op = BinOp.Div, a = Field.Ref("ps_mx"), b = maxF(sub(Field.Ref("ps_mx"), mn), k(0.000001)) });
        let toward = (ch: String) -> sub(Field.Ref("ps_mx"), mul(Field.Ref("ps_sk"), sub(Field.Ref("ps_mx"), Field.Ref(ch))));
        ("ps_lr", one(r, c#lift#r, c#gamma#r, c#gain#r)) :: ("ps_lg", one(g, c#lift#g, c#gamma#g, c#gain#g)) :: ("ps_lb", one(b, c#lift#b, c#gamma#b, c#gain#b))
            :: ("ps_mx", mx) :: ("ps_sk", minF(p("ps_saturation"), limit))
            :: ("ps_cr", toward("ps_lr")) :: ("ps_cg", toward("ps_lg")) :: ("ps_cb", toward("ps_lb")) :: Nil
}
