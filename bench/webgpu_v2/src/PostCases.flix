// 後がけの場面（R2b・P8 の (6b)）: 3D の場面を 2D の Pass に描き、面（ShaderDoc）で画面全体を加工する鎖を GL と WebGPU で比べる。
// 鎖はゲームの後がけ（奥行きのぼかし・ブルーム・トーンマップ・ビネット・FXAA）と同じ並び: 場面（ウィンドウの画素の HDR・標本は呼ぶ側）→ 奥行き（半分）→
// ぼかした場面（半分）→ 明るい所 → ぼかし 2 回 → 本編の面（ウィンドウの画素の Rgba8Unorm）→ FXAA の面で画面へ。
mod V2Post {
    use ShaderDoc.{BinOp, Field, Shade, Out, TexChan}

    /// 鎖の Pass の名前（ほかの場面の Pass と描き先の表を取り合わないよう頭に pp_）。
    def scenePass(): String = "pp_scene"
    def depthPass(): String = "pp_depth"
    def softPass(): String = "pp_soft"
    def brightPass(): String = "pp_bright"
    def bloomPassA(): String = "pp_bloomA"
    def bloomPassB(): String = "pp_bloomB"
    def postPass(): String = "pp_post"

    /// 鎖の Pass・描き先・画面の描き物。samples = 場面の Pass の標本の数・op = トーンマップの曲線・scene = 場面（奥行きの Pass は同じ場面の奥行きの書き出し）。
    pub def chain(design: Vec2.Vec2, samples: Int32, op: PostProcess.Tonemap, scene: Scene3d.Scene3dCmd, depthOut: Scene3d.Output):
            { passes = List[Render.Pass], targets = Map[String, RenderTarget.Descriptor], items = List[Render.PlacedItem] } =
        let black = RenderTarget.LoadOp.Clear(Color.rgb(0.0, 0.0, 0.0));
        let fill = spec -> fullFill(design, spec);
        let aspect = design#x / design#y;
        let depthScene = { output = depthOut, environment = { background = None | scene#environment } | scene };
        let passes =
            { name = scenePass(), clear = RenderTarget.LoadOp.Clear(Color.rgb(0.02, 0.02, 0.04)), items = Render.scene3d(Vec2.zero(), scene) :: Nil }
                :: { name = depthPass(), clear = RenderTarget.LoadOp.Clear(Color.rgb(1.0, 1.0, 1.0)), items = Render.scene3d(Vec2.zero(), depthScene) :: Nil }
                :: { name = softPass(), clear = black, items = fill(blurOf(aspect, softPass(), scenePass(), 0.012, 16)) :: Nil }
                :: { name = brightPass(), clear = black, items = fill(brightSpec()) :: Nil }
                :: { name = bloomPassA(), clear = black, items = fill(blurOf(aspect, bloomPassA(), brightPass(), 0.03, 24)) :: Nil }
                :: { name = bloomPassB(), clear = black, items = fill(blurOf(aspect, bloomPassB(), bloomPassA(), 0.015, 24)) :: Nil }
                :: { name = postPass(), clear = black, items = fill(mainSpec(aspect, op)) :: Nil }
                :: Nil;
        let at = s -> RenderTarget.withHdr({ scale = s | RenderTarget.defaultDescriptor() });
        { passes = passes,
          targets = Map#{ scenePass() => RenderTarget.withMsaa(samples, RenderTarget.withHdr(RenderTarget.windowDescriptor())),
                          depthPass() => at(0.5),
                          softPass() => at(0.5),
                          brightPass() => at(0.5),
                          bloomPassA() => at(0.25),
                          bloomPassB() => at(0.25),
                          postPass() => RenderTarget.windowDescriptor() },
          items = fill(PostProcess.fxaaSpec(postPass())) :: Nil }

    def fullFill(design: Vec2.Vec2, spec: ShaderDoc.Spec): Render.PlacedItem =
        Render.shaderFill(spec, { position = Vec2.zero(), size = design }, 0.0, 0)

    def k(v: Float64): Field = Field.Const(v)
    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })
    def sub(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Sub, a = a, b = b })
    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })
    def linear(f: Field): Field = Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = f })

    /// くっきりした場面とぼかした場面を奥行きの灰色の 0.5 からの離れ具合で混ぜ、ブルームを足してビネットを掛け、トーンマップして彩度を足す。
    def mainSpec(aspect: Float64, op: PostProcess.Tonemap): ShaderDoc.Spec =
        let away = mul(k(2.0), Field.Un({ op = ShaderDoc.UnOp.Abs, of = sub(Field.Ref("depth"), k(0.5)) }));
        let tilt = Field.Smoothstep({ lo = 0.15, hi = 0.55, of = away });
        let sharp = chan -> Field.Blend({ a = Field.Tex({ name = scenePass(), chan = chan }), b = linear(Field.Tex({ name = softPass(), chan = chan })), by = Field.Ref("tilt") });
        let bloom = chan -> linear(Field.Tex({ name = bloomPassB(), chan = chan }));
        let vig = sub(k(1.0), mul(k(0.45), Field.Smoothstep({ lo = 0.35, hi = 1.05, of = Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = aspect }) })));
        let base = chan -> mul(add(sharp(chan), mul(k(0.8), bloom(chan))), Field.Ref("vig"));
        let hdr = { name = "pp_main", cycleRate = 0.0,
                    bindings = ("depth", linear(Field.Tex({ name = depthPass(), chan = TexChan.R }))) :: ("tilt", tilt) :: ("vig", vig)
                               :: ("r0", base(TexChan.R)) :: ("g0", base(TexChan.G)) :: ("b0", base(TexChan.B)) :: Nil,
                    out = Out.Fill({ shade = Shade.Rgb({ r = Field.Ref("r0"), g = Field.Ref("g0"), b = Field.Ref("b0") }), alpha = k(1.0) }) };
        PostProcess.tonemappedWith(op, 0.6, 4.0, saturate, hdr)

    def saturate(r: Field, g: Field, b: Field): Shade =
        let lum = PostProcess.luma709(r, g, b);
        let graded = (c: Field) -> add(lum, mul(sub(c, lum), k(1.25)));
        Shade.Rgb({ r = graded(r), g = graded(g), b = graded(b) })

    /// 場面の明るい所だけを残す（HDR の目盛りで 0.6 から 0.9 へ立ち上がる）。
    def brightSpec(): ShaderDoc.Spec =
        let read = chan -> linear(Field.Tex({ name = scenePass(), chan = chan }));
        let over = Field.Smoothstep({ lo = 0.6, hi = 0.9, of = PostProcess.luma709(read(TexChan.R), read(TexChan.G), read(TexChan.B)) });
        let chan = c -> mul(read(c), Field.Ref("over"));
        { name = "pp_bright", cycleRate = 0.0, bindings = ("over", over) :: Nil,
          out = Out.Fill({ shade = Shade.Rgb({ r = chan(TexChan.R), g = chan(TexChan.G), b = chan(TexChan.B) }), alpha = k(1.0) }) }

    /// src の Pass を Linear で読んでぼかして写す面（半径 radius は design の高さに対する割合・taps 個の標本）。
    def blurOf(aspect: Float64, name: String, src: String, radius: Float64, taps: Int32): ShaderDoc.Spec =
        let b = chan -> linear(Field.TexBlur({ name = src, chan = chan, radius = { x = radius / aspect, y = radius },
                                               taps = ShaderDoc.blurTaps(taps), amount = k(1.0) }));
        { name = "pp_blur_${name}", cycleRate = 0.0, bindings = Nil,
          out = Out.Fill({ shade = Shade.Rgb({ r = b(TexChan.R), g = b(TexChan.G), b = b(TexChan.B) }), alpha = k(1.0) }) }
}
