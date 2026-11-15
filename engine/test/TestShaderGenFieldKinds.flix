// ShaderGen.eqMaterial と hashMaterial を Field の全部の種類で確かめる。
// 形式: 全部の種類を 1 つずつ持つ材質の鍵の値を固定する・深く写した物どうしは等しい・
// TexBlur・TexSize・VertexColor の欄を 1 つ変えた組は等しくなく、鍵も違う。
mod TestShaderGenFieldKinds {
    use ShaderDoc.Field
    use ShaderDoc.Shade
    use ShaderDoc.Out
    use ShaderDoc.Axis
    use ShaderDoc.Axis3
    use ShaderDoc.WorleyOut
    use ShaderDoc.TexChan
    use ShaderDoc.BinOp
    use ShaderDoc.UnOp
    use ShaderDoc.FilterMode

    def specOf(f: Field): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = Nil,
          out = Out.Fill({ shade = Shade.Solid({ r = 0.1, g = 0.2, b = 0.3 }), alpha = f }) }

    def eqM(a: Field, b: Field): Bool = ShaderGen.eqMaterial(specOf(a), None, None, specOf(b), None, None)

    def hashOf(f: Field): Int64 = ShaderGen.hashMaterial(specOf(f), None, None)

    def c(v: Float64): Field = Field.Const(v)

    /// Field の全部の種類を 1 つずつ（呼ぶたびに新しく組む）。
    def allKinds(): List[Field] =
           Field.Const(0.25)
        :: Field.Uv({ axis = Axis.V })
        :: Field.Worley({ scale = 1.5, seed = 3, out = WorleyOut.F1 })
        :: Field.Fbm({ octaves = 2, scale = 1.25, seed = 4 })
        :: Field.FbmTile({ octaves = 3, scale = 1.0, period = { x = 1.0, y = 2.0 }, seed = 5 })
        :: Field.Smoothstep({ lo = 0.1, hi = 0.9, of = c(0.5) })
        :: Field.Scaled({ factor = 2.0, scroll = { x = 0.1, y = 0.2 }, of = c(0.3) })
        :: Field.Warp({ amount = 0.2, scale = 1.0, seed = 6, of = c(0.4) })
        :: Field.Mix({ a = c(0.1), b = c(0.2), t = 0.5 })
        :: Field.Blend({ a = c(0.1), b = c(0.2), by = c(0.3) })
        :: Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.1 })
        :: Field.Radial({ cx = 0.4, cy = 0.6 })
        :: Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 1.5 })
        :: Field.Quantize({ of = c(0.7), steps = 4 })
        :: Field.Scales({ scale = 1.0, stagger = 0.5 })
        :: Field.Glints({ scale = 1.0, rate = 2.0, density = 0.5, seed = 7 })
        :: Field.Ripples({ freq = 3.0, amp = 0.1, speed = 1.0, seed = 8 })
        :: Field.Sparkle({ scale = 1.0, rate = 1.5, density = 0.4, seed = 9 })
        :: Field.Bin({ op = BinOp.Add, a = c(0.1), b = c(0.2) })
        :: Field.Hash1({ scale = 1.0, seed = 10, bucket = Some(c(0.5)) })
        :: Field.Hash2({ scale = 2.0, seed = 11, comp = Axis.U, bucket = Some(c(0.25)) })
        :: Field.Un({ op = UnOp.Neg, of = c(0.6) })
        :: Field.Pow({ of = c(0.5), p = 2.0 })
        :: Field.Time({ scale = 1.0, offset = c(0.1) })
        :: Field.Tiling({ tiles = { x = 2.0, y = 3.0 }, of = c(0.2) })
        :: Field.Snap({ cells = { x = 4.0, y = 5.0 }, of = c(0.3) })
        :: Field.Swirl({ cx = 0.5, cy = 0.5, strength = 1.0, rate = 0.1, of = c(0.4) })
        :: Field.Angle({ cx = 0.5, cy = 0.4 })
        :: Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.25, rate = 0.1, of = c(0.5) })
        :: Field.Ref("r")
        :: Field.Tex({ name = "a", chan = TexChan.G })
        :: Field.Shift({ dx = c(0.01), dy = c(0.02), of = Field.Tex({ name = "a", chan = TexChan.R }) })
        :: Field.TexBlur({ name = "b", chan = TexChan.B, radius = { x = 1.0, y = 2.0 }, taps = 5, amount = c(0.5) })
        :: Field.TexSize({ name = "b", axis = Axis.U })
        :: Field.Sampler({ filter = FilterMode.Linear, of = Field.Tex({ name = "c", chan = TexChan.A }) })
        :: Field.Param({ name = "p" })
        :: Field.World({ axis = Axis3.Y })
        :: Field.Normal({ axis = Axis3.Z })
        :: Field.VertexColor({ chan = TexChan.R })
        :: Nil

    /// 全部の種類を bindings に並べた材質（鍵の値を固定する相手）。
    def allKindsSpec(): ShaderDoc.Spec =
        { name = "all", cycleRate = 0.5,
          bindings = List.zipWithIndex(allKinds()) |> List.map(p -> ("k${fst(p)}", snd(p))),
          out = Out.Fill({ shade = Shade.Solid({ r = 0.1, g = 0.2, b = 0.3 }), alpha = c(1.0) }) }

    def texDiffPairs(): List[(String, Field, Field)] =
        let blur = (chan, rx, ry, taps, amount) -> Field.TexBlur({ name = "b", chan = chan, radius = { x = rx, y = ry }, taps = taps, amount = amount });
        let base = blur(TexChan.B, 1.0, 2.0, 5, c(0.5));
           ("TexBlur.chan",     base, blur(TexChan.G, 1.0, 2.0, 5, c(0.5)))
        :: ("TexBlur.radius.x", base, blur(TexChan.B, 1.5, 2.0, 5, c(0.5)))
        :: ("TexBlur.radius.y", base, blur(TexChan.B, 1.0, 2.5, 5, c(0.5)))
        :: ("TexBlur.taps",     base, blur(TexChan.B, 1.0, 2.0, 7, c(0.5)))
        :: ("TexBlur.amount",   base, blur(TexChan.B, 1.0, 2.0, 5, c(0.75)))
        :: ("TexSize.axis",     Field.TexSize({ name = "b", axis = Axis.U }), Field.TexSize({ name = "b", axis = Axis.V }))
        :: ("VertexColor.chan", Field.VertexColor({ chan = TexChan.R }), Field.VertexColor({ chan = TexChan.A }))
        :: Nil

    @Test
    def testTexFieldChangesAreNotEqual(): Unit \ Assert =
        let wrongEqual = texDiffPairs() |> List.filterMap(entry -> {
            let (label, a, b) = entry;
            if (eqM(a, b)) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), wrongEqual)

    @Test
    def testTexFieldChangesChangeHash(): Unit \ Assert =
        let sameKey = texDiffPairs() |> List.filterMap(entry -> {
            let (label, a, b) = entry;
            if (hashOf(a) == hashOf(b)) Some(label) else None
        });
        Assert.assertEq(expected = (Nil: List[String]), sameKey)

    /// 深く写した物どうし（別々に組んだ同じ中身）は、どの種類でも等しい。
    @Test
    def testDeepCopiesOfEveryKindAreEqual(): Unit \ Assert =
        let wrongUnequal = List.zip(List.zipWithIndex(allKinds()), allKinds()) |> List.filterMap(pair -> {
            let ((i, a), b) = pair;
            if (eqM(a, b)) None else Some(i)
        });
        Assert.assertEq(expected = (Nil: List[Int32]), wrongUnequal)

    /// 全部の種類を持つ材質の鍵の値（ShaderGen の書き方を替えても変わらない事を見る）。
    @Test
    def testAllKindsHashIsPinned(): Unit \ Assert =
        Assert.assertEq(expected = -4558135234618744269i64, ShaderGen.hashMaterial(allKindsSpec(), None, None))
}
