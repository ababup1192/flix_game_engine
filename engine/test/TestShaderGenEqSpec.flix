// ShaderGen.eqSpec の網羅テスト。eqSpec は program キャッシュの正当性の中核で、
// payload のフィールドを 1 本でも比べ忘れると「違う Spec を同じ」と誤答し、
// 古い program の絵が何も知らせずに出続ける。headless の描き出しは GL の program キャッシュを
// 通らないため、この取り違えはバイト一致では捕まらない — ここが唯一の網。
// 形式: 全コンストラクタについて「payload を 1 フィールドだけ変えた組は等しくない」
// 「同じ中身を 2 回組んだら等しい」を pin する。
mod TestShaderGenEqSpec {
    use ShaderDoc.Field
    use ShaderDoc.Shade
    use ShaderDoc.Out
    use ShaderDoc.Axis
    use ShaderDoc.WorleyOut
    use ShaderDoc.TexChan
    use ShaderDoc.BinOp
    use ShaderDoc.UnOp

    // ── 素材 ──────────────────────────────────────────────

    def f0(): Field = Field.Const(0.25)
    def g0(): Field = Field.Const(0.75)
    def h0(): Field = Field.Const(0.875)

    def col1(): Color = { r = 0.1, g = 0.2, b = 0.3 }
    def col2(): Color = { r = 0.4, g = 0.5, b = 0.6 }
    def col3(): Color = { r = 0.7, g = 0.8, b = 0.9 }
    def col4(): Color = { r = 0.15, g = 0.25, b = 0.35 }

    /// Field 1 本を alpha の席に載せた最小 Spec（eqField を eqSpec 経由で試す口）。
    def specOf(f: Field): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = Nil,
          out = Out.Fill({ shade = Shade.Solid(col1()), alpha = f }) }

    /// Shade 1 本を shade の席に載せた最小 Spec（eqShade を eqSpec 経由で試す口）。
    def specOfShade(s: Shade): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = Nil,
          out = Out.Fill({ shade = s, alpha = Field.Const(1.0) }) }

    def eqF(a: Field, b: Field): Bool = ShaderGen.eqSpec(specOf(a), specOf(b))
    def eqSh(a: Shade, b: Shade): Bool = ShaderGen.eqSpec(specOfShade(a), specOfShade(b))

    // ── 各コンストラクタの基準値 ─────────────────────────────

    def cUv(): Field = Field.Uv({ axis = Axis.U })
    def cWorley(): Field = Field.Worley({ scale = 1.0, seed = 1, out = WorleyOut.F1 })
    def cFbm(): Field = Field.Fbm({ octaves = 2, scale = 1.0, seed = 1 })
    def cFbmTile(): Field = Field.FbmTile({ octaves = 2, scale = 1.0, period = { x = 1.0, y = 2.0 }, seed = 1 })
    def cSmooth(): Field = Field.Smoothstep({ lo = 0.0, hi = 1.0, of = f0() })
    def cScaled(): Field = Field.Scaled({ factor = 1.0, scroll = { x = 0.1, y = 0.2 }, of = f0() })
    def cWarp(): Field = Field.Warp({ amount = 0.1, scale = 1.0, seed = 1, of = f0() })
    def cMix(): Field = Field.Mix({ a = f0(), b = g0(), t = 0.5 })
    def cBlend(): Field = Field.Blend({ a = f0(), b = g0(), by = f0() })
    def cDisk(): Field = Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.1 })
    def cRadial(): Field = Field.Radial({ cx = 0.5, cy = 0.5 })
    def cRadialAspect(): Field = Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 1.5 })
    def cQuantize(): Field = Field.Quantize({ of = f0(), steps = 2 })
    def cScales(): Field = Field.Scales({ scale = 1.0, stagger = 0.5 })
    def cGlints(): Field = Field.Glints({ scale = 1.0, rate = 1.0, density = 0.5, seed = 1 })
    def cRipples(): Field = Field.Ripples({ freq = 1.0, amp = 0.1, speed = 1.0, seed = 1 })
    def cSparkle(): Field = Field.Sparkle({ scale = 1.0, rate = 1.0, density = 0.5, seed = 1 })
    def cBin(): Field = Field.Bin({ op = BinOp.Add, a = f0(), b = g0() })
    def cHash1(): Field = Field.Hash1({ scale = 1.0, seed = 1, bucket = None })
    def cHash1B(): Field = Field.Hash1({ scale = 1.0, seed = 1, bucket = Some(f0()) })
    def cHash2(): Field = Field.Hash2({ scale = 1.0, seed = 1, comp = Axis.U, bucket = None })
    def cHash2B(): Field = Field.Hash2({ scale = 1.0, seed = 1, comp = Axis.U, bucket = Some(f0()) })
    def cUn(): Field = Field.Un({ op = UnOp.Neg, of = f0() })
    def cPow(): Field = Field.Pow({ of = f0(), p = 2.0 })
    def cTime(): Field = Field.Time({ scale = 1.0, offset = f0() })
    def cTiling(): Field = Field.Tiling({ tiles = { x = 2.0, y = 3.0 }, of = f0() })
    def cSnap(): Field = Field.Snap({ cells = { x = 2.0, y = 3.0 }, of = f0() })
    def cSwirl(): Field = Field.Swirl({ cx = 0.5, cy = 0.5, strength = 1.0, rate = 0.1, of = f0() })
    def cAngle(): Field = Field.Angle({ cx = 0.5, cy = 0.5 })
    def cRotate(): Field = Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.25, rate = 0.1, of = f0() })
    def cRef(): Field = Field.Ref("a")
    def cTex(): Field = Field.Tex({ name = "a", chan = TexChan.R })
    def cSampler(): Field = Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = cTex() })
    def cShift(): Field = Field.Shift({ dx = f0(), dy = g0(), of = f0() })

    def sSolid(): Shade = Shade.Solid(col1())
    def sRamp(): Shade = Shade.Ramp({ lo = col1(), hi = col2(), field = f0() })
    def sGrad(): Shade = Shade.Gradient({ stops = (0.0, col1()) :: (1.0, col2()) :: Nil, field = f0() })
    def sCos(): Shade = Shade.Cosine({ a = col1(), b = col2(), c = col3(), d = col4(), field = f0() })
    def sRgb(): Shade = Shade.Rgb({ r = f0(), g = g0(), b = h0() })

    def baseSpec(): ShaderDoc.Spec =
        { name = "s", cycleRate = 0.5, bindings = ("n", f0()) :: Nil,
          out = Out.Fill({ shade = sSolid(), alpha = f0() }) }

    // ── Field: payload を 1 フィールドだけ変えた組は等しくない ──

    def fieldDiffPairs(): List[(String, Field, Field)] =
           ("Const.value",        Field.Const(0.25), Field.Const(0.5))
        :: ("Uv.axis",            cUv(), Field.Uv({ axis = Axis.V }))
        :: ("Worley.scale",       cWorley(), Field.Worley({ scale = 2.0, seed = 1, out = WorleyOut.F1 }))
        :: ("Worley.seed",        cWorley(), Field.Worley({ scale = 1.0, seed = 2, out = WorleyOut.F1 }))
        :: ("Worley.out",         cWorley(), Field.Worley({ scale = 1.0, seed = 1, out = WorleyOut.F2mF1 }))
        :: ("Fbm.octaves",        cFbm(), Field.Fbm({ octaves = 3, scale = 1.0, seed = 1 }))
        :: ("Fbm.scale",          cFbm(), Field.Fbm({ octaves = 2, scale = 2.0, seed = 1 }))
        :: ("Fbm.seed",           cFbm(), Field.Fbm({ octaves = 2, scale = 1.0, seed = 2 }))
        :: ("FbmTile.octaves",    cFbmTile(), Field.FbmTile({ octaves = 3, scale = 1.0, period = { x = 1.0, y = 2.0 }, seed = 1 }))
        :: ("FbmTile.scale",      cFbmTile(), Field.FbmTile({ octaves = 2, scale = 2.0, period = { x = 1.0, y = 2.0 }, seed = 1 }))
        :: ("FbmTile.period.x",   cFbmTile(), Field.FbmTile({ octaves = 2, scale = 1.0, period = { x = 3.0, y = 2.0 }, seed = 1 }))
        :: ("FbmTile.period.y",   cFbmTile(), Field.FbmTile({ octaves = 2, scale = 1.0, period = { x = 1.0, y = 3.0 }, seed = 1 }))
        :: ("FbmTile.seed",       cFbmTile(), Field.FbmTile({ octaves = 2, scale = 1.0, period = { x = 1.0, y = 2.0 }, seed = 2 }))
        :: ("Smoothstep.lo",      cSmooth(), Field.Smoothstep({ lo = 0.1, hi = 1.0, of = f0() }))
        :: ("Smoothstep.hi",      cSmooth(), Field.Smoothstep({ lo = 0.0, hi = 0.9, of = f0() }))
        :: ("Smoothstep.of",      cSmooth(), Field.Smoothstep({ lo = 0.0, hi = 1.0, of = g0() }))
        :: ("Scaled.factor",      cScaled(), Field.Scaled({ factor = 2.0, scroll = { x = 0.1, y = 0.2 }, of = f0() }))
        :: ("Scaled.scroll.x",    cScaled(), Field.Scaled({ factor = 1.0, scroll = { x = 0.3, y = 0.2 }, of = f0() }))
        :: ("Scaled.scroll.y",    cScaled(), Field.Scaled({ factor = 1.0, scroll = { x = 0.1, y = 0.3 }, of = f0() }))
        :: ("Scaled.of",          cScaled(), Field.Scaled({ factor = 1.0, scroll = { x = 0.1, y = 0.2 }, of = g0() }))
        :: ("Warp.amount",        cWarp(), Field.Warp({ amount = 0.2, scale = 1.0, seed = 1, of = f0() }))
        :: ("Warp.scale",         cWarp(), Field.Warp({ amount = 0.1, scale = 2.0, seed = 1, of = f0() }))
        :: ("Warp.seed",          cWarp(), Field.Warp({ amount = 0.1, scale = 1.0, seed = 2, of = f0() }))
        :: ("Warp.of",            cWarp(), Field.Warp({ amount = 0.1, scale = 1.0, seed = 1, of = g0() }))
        :: ("Mix.a",              cMix(), Field.Mix({ a = h0(), b = g0(), t = 0.5 }))
        :: ("Mix.b",              cMix(), Field.Mix({ a = f0(), b = h0(), t = 0.5 }))
        :: ("Mix.t",              cMix(), Field.Mix({ a = f0(), b = g0(), t = 0.6 }))
        :: ("Blend.a",            cBlend(), Field.Blend({ a = h0(), b = g0(), by = f0() }))
        :: ("Blend.b",            cBlend(), Field.Blend({ a = f0(), b = h0(), by = f0() }))
        :: ("Blend.by",           cBlend(), Field.Blend({ a = f0(), b = g0(), by = h0() }))
        :: ("Disk.cx",            cDisk(), Field.Disk({ cx = 0.6, cy = 0.5, radius = 0.3, feather = 0.1 }))
        :: ("Disk.cy",            cDisk(), Field.Disk({ cx = 0.5, cy = 0.6, radius = 0.3, feather = 0.1 }))
        :: ("Disk.radius",        cDisk(), Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.4, feather = 0.1 }))
        :: ("Disk.feather",       cDisk(), Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.2 }))
        :: ("Radial.cx",          cRadial(), Field.Radial({ cx = 0.6, cy = 0.5 }))
        :: ("Radial.cy",          cRadial(), Field.Radial({ cx = 0.5, cy = 0.6 }))
        :: ("RadialAspect.cx",    cRadialAspect(), Field.RadialAspect({ cx = 0.6, cy = 0.5, aspect = 1.5 }))
        :: ("RadialAspect.cy",    cRadialAspect(), Field.RadialAspect({ cx = 0.5, cy = 0.6, aspect = 1.5 }))
        :: ("RadialAspect.aspect", cRadialAspect(), Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 2.0 }))
        :: ("Quantize.of",        cQuantize(), Field.Quantize({ of = g0(), steps = 2 }))
        :: ("Quantize.steps",     cQuantize(), Field.Quantize({ of = f0(), steps = 3 }))
        :: ("Scales.scale",       cScales(), Field.Scales({ scale = 2.0, stagger = 0.5 }))
        :: ("Scales.stagger",     cScales(), Field.Scales({ scale = 1.0, stagger = 0.6 }))
        :: ("Glints.scale",       cGlints(), Field.Glints({ scale = 2.0, rate = 1.0, density = 0.5, seed = 1 }))
        :: ("Glints.rate",        cGlints(), Field.Glints({ scale = 1.0, rate = 2.0, density = 0.5, seed = 1 }))
        :: ("Glints.density",     cGlints(), Field.Glints({ scale = 1.0, rate = 1.0, density = 0.6, seed = 1 }))
        :: ("Glints.seed",        cGlints(), Field.Glints({ scale = 1.0, rate = 1.0, density = 0.5, seed = 2 }))
        :: ("Ripples.freq",       cRipples(), Field.Ripples({ freq = 2.0, amp = 0.1, speed = 1.0, seed = 1 }))
        :: ("Ripples.amp",        cRipples(), Field.Ripples({ freq = 1.0, amp = 0.2, speed = 1.0, seed = 1 }))
        :: ("Ripples.speed",      cRipples(), Field.Ripples({ freq = 1.0, amp = 0.1, speed = 2.0, seed = 1 }))
        :: ("Ripples.seed",       cRipples(), Field.Ripples({ freq = 1.0, amp = 0.1, speed = 1.0, seed = 2 }))
        :: ("Sparkle.scale",      cSparkle(), Field.Sparkle({ scale = 2.0, rate = 1.0, density = 0.5, seed = 1 }))
        :: ("Sparkle.rate",       cSparkle(), Field.Sparkle({ scale = 1.0, rate = 2.0, density = 0.5, seed = 1 }))
        :: ("Sparkle.density",    cSparkle(), Field.Sparkle({ scale = 1.0, rate = 1.0, density = 0.6, seed = 1 }))
        :: ("Sparkle.seed",       cSparkle(), Field.Sparkle({ scale = 1.0, rate = 1.0, density = 0.5, seed = 2 }))
        :: ("Bin.op",             cBin(), Field.Bin({ op = BinOp.Sub, a = f0(), b = g0() }))
        :: ("Bin.a",              cBin(), Field.Bin({ op = BinOp.Add, a = h0(), b = g0() }))
        :: ("Bin.b",              cBin(), Field.Bin({ op = BinOp.Add, a = f0(), b = h0() }))
        :: ("Hash1.scale",        cHash1(), Field.Hash1({ scale = 2.0, seed = 1, bucket = None }))
        :: ("Hash1.seed",         cHash1(), Field.Hash1({ scale = 1.0, seed = 2, bucket = None }))
        :: ("Hash1.bucket None/Some", cHash1(), cHash1B())
        :: ("Hash1.bucket Some/Some", cHash1B(), Field.Hash1({ scale = 1.0, seed = 1, bucket = Some(g0()) }))
        :: ("Hash2.scale",        cHash2(), Field.Hash2({ scale = 2.0, seed = 1, comp = Axis.U, bucket = None }))
        :: ("Hash2.seed",         cHash2(), Field.Hash2({ scale = 1.0, seed = 2, comp = Axis.U, bucket = None }))
        :: ("Hash2.comp",         cHash2(), Field.Hash2({ scale = 1.0, seed = 1, comp = Axis.V, bucket = None }))
        :: ("Hash2.bucket None/Some", cHash2(), cHash2B())
        :: ("Hash2.bucket Some/Some", cHash2B(), Field.Hash2({ scale = 1.0, seed = 1, comp = Axis.U, bucket = Some(g0()) }))
        :: ("Un.op",              cUn(), Field.Un({ op = UnOp.Abs, of = f0() }))
        :: ("Un.of",              cUn(), Field.Un({ op = UnOp.Neg, of = g0() }))
        :: ("Pow.of",             cPow(), Field.Pow({ of = g0(), p = 2.0 }))
        :: ("Pow.p",              cPow(), Field.Pow({ of = f0(), p = 3.0 }))
        :: ("Time.scale",         cTime(), Field.Time({ scale = 2.0, offset = f0() }))
        :: ("Time.offset",        cTime(), Field.Time({ scale = 1.0, offset = g0() }))
        :: ("Tiling.tiles.x",     cTiling(), Field.Tiling({ tiles = { x = 4.0, y = 3.0 }, of = f0() }))
        :: ("Tiling.tiles.y",     cTiling(), Field.Tiling({ tiles = { x = 2.0, y = 4.0 }, of = f0() }))
        :: ("Tiling.of",          cTiling(), Field.Tiling({ tiles = { x = 2.0, y = 3.0 }, of = g0() }))
        :: ("Snap.cells.x",       cSnap(), Field.Snap({ cells = { x = 4.0, y = 3.0 }, of = f0() }))
        :: ("Snap.cells.y",       cSnap(), Field.Snap({ cells = { x = 2.0, y = 4.0 }, of = f0() }))
        :: ("Snap.of",            cSnap(), Field.Snap({ cells = { x = 2.0, y = 3.0 }, of = g0() }))
        :: ("Swirl.cx",           cSwirl(), Field.Swirl({ cx = 0.6, cy = 0.5, strength = 1.0, rate = 0.1, of = f0() }))
        :: ("Swirl.cy",           cSwirl(), Field.Swirl({ cx = 0.5, cy = 0.6, strength = 1.0, rate = 0.1, of = f0() }))
        :: ("Swirl.strength",     cSwirl(), Field.Swirl({ cx = 0.5, cy = 0.5, strength = 2.0, rate = 0.1, of = f0() }))
        :: ("Swirl.rate",         cSwirl(), Field.Swirl({ cx = 0.5, cy = 0.5, strength = 1.0, rate = 0.2, of = f0() }))
        :: ("Swirl.of",           cSwirl(), Field.Swirl({ cx = 0.5, cy = 0.5, strength = 1.0, rate = 0.1, of = g0() }))
        :: ("Angle.cx",           cAngle(), Field.Angle({ cx = 0.6, cy = 0.5 }))
        :: ("Angle.cy",           cAngle(), Field.Angle({ cx = 0.5, cy = 0.6 }))
        :: ("Rotate.cx",          cRotate(), Field.Rotate({ cx = 0.6, cy = 0.5, turns = 0.25, rate = 0.1, of = f0() }))
        :: ("Rotate.cy",          cRotate(), Field.Rotate({ cx = 0.5, cy = 0.6, turns = 0.25, rate = 0.1, of = f0() }))
        :: ("Rotate.turns",       cRotate(), Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.5, rate = 0.1, of = f0() }))
        :: ("Rotate.rate",        cRotate(), Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.25, rate = 0.2, of = f0() }))
        :: ("Rotate.of",          cRotate(), Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.25, rate = 0.1, of = g0() }))
        :: ("Ref.name",           cRef(), Field.Ref("b"))
        :: ("Tex.name の並び",    Field.Bin({ op = BinOp.Add, a = cTex(), b = cTex() }),
                                  Field.Bin({ op = BinOp.Add, a = cTex(), b = Field.Tex({ name = "b", chan = TexChan.R }) }))
        :: ("Tex.chan",           cTex(), Field.Tex({ name = "a", chan = TexChan.G }))
        :: ("Shift.dx",           cShift(), Field.Shift({ dx = h0(), dy = g0(), of = f0() }))
        :: ("Shift.dy",           cShift(), Field.Shift({ dx = f0(), dy = h0(), of = f0() }))
        :: ("Shift.of",           cShift(), Field.Shift({ dx = f0(), dy = g0(), of = h0() }))
        :: ("Sampler.filter",     cSampler(), Field.Sampler({ filter = ShaderDoc.FilterMode.Nearest, of = cTex() }))
        :: ("Sampler.of",         cSampler(), Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = f0() }))
        :: ("Param.name",         Field.Param({ name = "a" }), Field.Param({ name = "b" }))
        :: ("World.axis",         Field.World({ axis = ShaderDoc.Axis3.X }), Field.World({ axis = ShaderDoc.Axis3.Y }))
        :: ("Normal.axis",        Field.Normal({ axis = ShaderDoc.Axis3.X }), Field.Normal({ axis = ShaderDoc.Axis3.Z }))
        :: ("ctor World/Normal",  Field.World({ axis = ShaderDoc.Axis3.X }), Field.Normal({ axis = ShaderDoc.Axis3.X }))
        :: ("ctor Const/Uv",      f0(), cUv())
        :: Nil

    /// テクスチャの名前だけを別名に替えた Spec は等しい（GLSL に出るのは番号だけ）。Pass の中で読みを
    /// `x@history` / `@missing:c` に書き換えた Spec と元の Spec が、同じ program を使い回せることの証拠。
    @Test
    def testRenamedTexStillEqual(): Unit \ Assert =
        let spec: ShaderDoc.Spec = { name = "s", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = cTex(), g = Field.Tex({ name = "c", chan = TexChan.G }),
                                                                     b = cTex() }),
                                       alpha = Field.Const(1.0) }) };
        let renamed = ShaderDoc.renameTex(n -> if (n == "a") "a@history" else "@missing:" + n, spec);
        Assert.assertEq(expected = true, ShaderGen.eqSpec(spec, renamed))

    @Test
    def testFieldChangesBreakEquality(): Unit \ Assert =
        let wrongEqual = fieldDiffPairs() |> List.filterMap(entry -> {
            let (label, a, b) = entry;
            if (eqF(a, b)) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), wrongEqual)

    // ── Shade: payload を 1 フィールドだけ変えた組は等しくない ──

    def shadeDiffPairs(): List[(String, Shade, Shade)] =
           ("Solid.r",         sSolid(), Shade.Solid({ r = 0.9, g = 0.2, b = 0.3 }))
        :: ("Solid.g",         sSolid(), Shade.Solid({ r = 0.1, g = 0.9, b = 0.3 }))
        :: ("Solid.b",         sSolid(), Shade.Solid({ r = 0.1, g = 0.2, b = 0.9 }))
        :: ("Ramp.lo",         sRamp(), Shade.Ramp({ lo = col3(), hi = col2(), field = f0() }))
        :: ("Ramp.hi",         sRamp(), Shade.Ramp({ lo = col1(), hi = col3(), field = f0() }))
        :: ("Ramp.field",      sRamp(), Shade.Ramp({ lo = col1(), hi = col2(), field = g0() }))
        :: ("Gradient.stop.pos",   sGrad(), Shade.Gradient({ stops = (0.5, col1()) :: (1.0, col2()) :: Nil, field = f0() }))
        :: ("Gradient.stop.color", sGrad(), Shade.Gradient({ stops = (0.0, col3()) :: (1.0, col2()) :: Nil, field = f0() }))
        :: ("Gradient.stops.length", sGrad(), Shade.Gradient({ stops = (0.0, col1()) :: Nil, field = f0() }))
        :: ("Gradient.field",  sGrad(), Shade.Gradient({ stops = (0.0, col1()) :: (1.0, col2()) :: Nil, field = g0() }))
        :: ("Cosine.a",        sCos(), Shade.Cosine({ a = col2(), b = col2(), c = col3(), d = col4(), field = f0() }))
        :: ("Cosine.b",        sCos(), Shade.Cosine({ a = col1(), b = col3(), c = col3(), d = col4(), field = f0() }))
        :: ("Cosine.c",        sCos(), Shade.Cosine({ a = col1(), b = col2(), c = col4(), d = col4(), field = f0() }))
        :: ("Cosine.d",        sCos(), Shade.Cosine({ a = col1(), b = col2(), c = col3(), d = col1(), field = f0() }))
        :: ("Cosine.field",    sCos(), Shade.Cosine({ a = col1(), b = col2(), c = col3(), d = col4(), field = g0() }))
        :: ("Rgb.r",           sRgb(), Shade.Rgb({ r = h0(), g = g0(), b = h0() }))
        :: ("Rgb.g",           sRgb(), Shade.Rgb({ r = f0(), g = h0(), b = h0() }))
        :: ("Rgb.b",           sRgb(), Shade.Rgb({ r = f0(), g = g0(), b = f0() }))
        :: ("ctor Solid/Rgb",  sSolid(), sRgb())
        :: Nil

    @Test
    def testShadeChangesBreakEquality(): Unit \ Assert =
        let wrongEqual = shadeDiffPairs() |> List.filterMap(entry -> {
            let (label, a, b) = entry;
            if (eqSh(a, b)) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), wrongEqual)

    // ── Spec: 4 フィールドそれぞれ（と bindings の中身）を 1 つだけ変えた組は等しくない ──

    def specDiffPairs(): List[(String, ShaderDoc.Spec)] =
           ("name",           { name = "s2" | baseSpec() })
        :: ("cycleRate",      { cycleRate = 1.0 | baseSpec() })
        :: ("bindings.name",  { bindings = ("m", f0()) :: Nil | baseSpec() })
        :: ("bindings.field", { bindings = ("n", g0()) :: Nil | baseSpec() })
        :: ("bindings.length", { bindings = Nil | baseSpec() })
        :: ("out.alpha",      { out = Out.Fill({ shade = sSolid(), alpha = g0() }) | baseSpec() })
        :: ("out.shade",      { out = Out.Fill({ shade = sRgb(), alpha = f0() }) | baseSpec() })
        :: Nil

    @Test
    def testSpecChangesBreakEquality(): Unit \ Assert =
        let wrongEqual = specDiffPairs() |> List.filterMap(entry -> {
            let (label, variant) = entry;
            if (ShaderGen.eqSpec(baseSpec(), variant)) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), wrongEqual)

    // ── 同じ中身を 2 回組んだら等しい ──

    def samePairs(): List[(String, Bool)] =
           ("Const",        eqF(f0(), f0()))
        :: ("Uv",           eqF(cUv(), cUv()))
        :: ("Worley",       eqF(cWorley(), cWorley()))
        :: ("Fbm",          eqF(cFbm(), cFbm()))
        :: ("FbmTile",      eqF(cFbmTile(), cFbmTile()))
        :: ("Smoothstep",   eqF(cSmooth(), cSmooth()))
        :: ("Scaled",       eqF(cScaled(), cScaled()))
        :: ("Warp",         eqF(cWarp(), cWarp()))
        :: ("Mix",          eqF(cMix(), cMix()))
        :: ("Blend",        eqF(cBlend(), cBlend()))
        :: ("Disk",         eqF(cDisk(), cDisk()))
        :: ("Radial",       eqF(cRadial(), cRadial()))
        :: ("RadialAspect", eqF(cRadialAspect(), cRadialAspect()))
        :: ("Quantize",     eqF(cQuantize(), cQuantize()))
        :: ("Scales",       eqF(cScales(), cScales()))
        :: ("Glints",       eqF(cGlints(), cGlints()))
        :: ("Ripples",      eqF(cRipples(), cRipples()))
        :: ("Sparkle",      eqF(cSparkle(), cSparkle()))
        :: ("Bin",          eqF(cBin(), cBin()))
        :: ("Hash1",        eqF(cHash1(), cHash1()))
        :: ("Hash1 Some",   eqF(cHash1B(), cHash1B()))
        :: ("Hash2",        eqF(cHash2(), cHash2()))
        :: ("Hash2 Some",   eqF(cHash2B(), cHash2B()))
        :: ("Un",           eqF(cUn(), cUn()))
        :: ("Pow",          eqF(cPow(), cPow()))
        :: ("Time",         eqF(cTime(), cTime()))
        :: ("Tiling",       eqF(cTiling(), cTiling()))
        :: ("Snap",         eqF(cSnap(), cSnap()))
        :: ("Swirl",        eqF(cSwirl(), cSwirl()))
        :: ("Angle",        eqF(cAngle(), cAngle()))
        :: ("Rotate",       eqF(cRotate(), cRotate()))
        :: ("Ref",          eqF(cRef(), cRef()))
        :: ("Tex",          eqF(cTex(), cTex()))
        :: ("Shift",        eqF(cShift(), cShift()))
        :: ("Sampler",      eqF(cSampler(), cSampler()))
        :: ("World",        eqF(Field.World({ axis = ShaderDoc.Axis3.Y }), Field.World({ axis = ShaderDoc.Axis3.Y })))
        :: ("Normal",       eqF(Field.Normal({ axis = ShaderDoc.Axis3.Y }), Field.Normal({ axis = ShaderDoc.Axis3.Y })))
        :: ("Solid",        eqSh(sSolid(), sSolid()))
        :: ("Ramp",         eqSh(sRamp(), sRamp()))
        :: ("Gradient",     eqSh(sGrad(), sGrad()))
        :: ("Cosine",       eqSh(sCos(), sCos()))
        :: ("Rgb",          eqSh(sRgb(), sRgb()))
        :: ("baseSpec",     ShaderGen.eqSpec(baseSpec(), baseSpec()))
        :: ("demoSurface",  ShaderGen.eqSpec(ShaderDoc.demoSurface(), ShaderDoc.demoSurface()))
        :: ("waterVeins",   ShaderGen.eqSpec(ShaderDoc.waterVeins(), ShaderDoc.waterVeins()))
        :: Nil

    @Test
    def testSameContentIsEqual(): Unit \ Assert =
        let wrongUnequal = samePairs() |> List.filterMap(entry -> {
            let (label, isEqual) = entry;
            if (isEqual) None else Some(label)
        });
        Assert.assertEq(expected = (Nil: List[String]), wrongUnequal)

    /// 同じ物を 2 回渡したら木を辿らずに等しい。NaN の Const は中身の比べでは自分とも等しくないので、
    /// 同じ物（真）と、同じ中身で組み直した物（偽）の差が、参照で抜けたことを示す。
    @Test
    def testSameObjectIsEqualWithoutWalkingTheTree(): Unit \ Assert =
        let spec = specOf(Field.Const(Float64.nan()));
        Assert.assertEq(expected = (true, false),
                        (ShaderGen.eqSpec(spec, spec), ShaderGen.eqSpec(spec, specOf(Field.Const(Float64.nan())))))

    // ── hashMaterial: eqSpec が偽になる組は鍵も違う（1 欄の違いを鍵が落とすと、GL が違う材質に同じプログラムを引きに行く）──

    def hashOf(spec: ShaderDoc.Spec): Int64 = ShaderGen.hashMaterial(spec, None, None)

    @Test
    def testFieldChangesChangeHash(): Unit \ Assert =
        let sameKey = fieldDiffPairs() |> List.filterMap(entry -> {
            let (label, a, b) = entry;
            if (hashOf(specOf(a)) == hashOf(specOf(b))) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), sameKey)

    @Test
    def testShadeChangesChangeHash(): Unit \ Assert =
        let sameKey = shadeDiffPairs() |> List.filterMap(entry -> {
            let (label, a, b) = entry;
            if (hashOf(specOfShade(a)) == hashOf(specOfShade(b))) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), sameKey)

    @Test
    def testSpecChangesChangeHash(): Unit \ Assert =
        let sameKey = specDiffPairs() |> List.filterMap(entry -> {
            let (label, variant) = entry;
            if (hashOf(baseSpec()) == hashOf(variant)) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), sameKey)

    /// テクスチャの名前だけを別名に替えた Spec は eqSpec が真なので、鍵も同じ。
    @Test
    def testRenamedTexKeepsHash(): Unit \ Assert =
        let spec: ShaderDoc.Spec = { name = "s", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = cTex(), g = Field.Tex({ name = "c", chan = TexChan.G }),
                                                                     b = cTex() }),
                                       alpha = Field.Const(1.0) }) };
        let renamed = ShaderDoc.renameTex(n -> if (n == "a") "a@history" else "@missing:" + n, spec);
        Assert.assertEq(expected = hashOf(spec), hashOf(renamed))

    /// -0.0 と 0.0 は == で等しい（eqSpec が真）ので、鍵も同じ。
    @Test
    def testNegativeZeroKeepsHash(): Unit \ Assert =
        Assert.assertEq(expected = hashOf(specOf(Field.Const(0.0))), hashOf(specOf(Field.Const(-0.0))))

    /// emission の有無と中身も鍵に入る。
    @Test
    def testEmissionChangesHash(): Unit \ Assert =
        let glow = c -> Some(Shade.Solid(c));
        Assert.assertEq(expected = (false, false),
                        (ShaderGen.hashMaterial(baseSpec(), None, None) == ShaderGen.hashMaterial(baseSpec(), glow(col1()), None),
                         ShaderGen.hashMaterial(baseSpec(), glow(col1()), None) == ShaderGen.hashMaterial(baseSpec(), glow(col2()), None)))
}
