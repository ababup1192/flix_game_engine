// eqSpec・eqMaterial のテクスチャ名の比べ（たどりながら作る名前の対応）が、texNames の番号で比べる形と同じ答えを返すこと。
// 名前を 1 対 1 で付け替えた組は等しく、2 つの名前を 1 つに潰した組は等しくない。
mod ShaderGen.TestPairing {
    use ShaderDoc.Field
    use ShaderDoc.Shade
    use ShaderDoc.Out
    use ShaderDoc.Axis
    use ShaderDoc.TexChan
    use ShaderDoc.BinOp
    use ShaderDoc.FilterMode

    def tex(name: String): Field = Field.Tex({ name = name, chan = TexChan.R })

    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })

    def specWith(bindings: List[(String, Field)], shade: Shade, alpha: Field): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = bindings, out = Out.Fill({ shade = shade, alpha = alpha }) }

    def solid(): Shade = Shade.Solid({ r = 0.1, g = 0.2, b = 0.3 })

    /// 名前 2 つ（a・b）で組む Spec の型紙。
    def fixtures(): List[(String, (String, String) -> ShaderDoc.Spec)] =
        ("2 つの Tex", (a, b) -> specWith(Nil, solid(), add(tex(a), tex(b))))
        :: ("TexSize だけで読む名前は後ろへ回る", (a, b) -> specWith(Nil, solid(), add(Field.TexSize({ name = a, axis = Axis.U }), tex(b))))
        :: ("Tex と同じ名前の TexSize はまとまる", (a, b) -> specWith(Nil, solid(), add(add(tex(a), Field.TexSize({ name = a, axis = Axis.V })), tex(b))))
        :: ("同じ名前を Nearest と Linear で読む", (a, b) -> specWith(Nil, solid(),
                add(add(tex(a), Field.Sampler({ filter = FilterMode.Linear, of = tex(a) })), tex(b))))
        :: ("bindings と out の両方で読む", (a, b) -> specWith(("k", tex(a)) :: Nil,
                Shade.Rgb({ r = tex(b), g = Field.Ref("k"), b = tex(a) }), Field.Const(1.0)))
        :: ("TexBlur と Tex", (a, b) -> specWith(Nil, solid(),
                add(Field.TexBlur({ name = b, chan = TexChan.G, radius = { x = 1.0, y = 1.0 }, taps = 4, amount = Field.Const(1.0) }), tex(a))))
        :: Nil

    /// texNames の正典順の番号で名前を比べる形（名前の対応を作る前の比べ方）。
    def byIndex(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool =
        let indexOf = spec -> ShaderDoc.texNames(spec) |> List.zipWithIndex |> List.map(e -> { let (i, n) = e; (n, i) }) |> List.toMap;
        let (ia, ib) = (indexOf(a), indexOf(b));
        ShaderGen.eqSpecWith((na, nb) -> Map.get(na, ia) == Map.get(nb, ib), a, b)

    /// 各型紙を (a, b) で組んだ物と、names の組で組んだ物の (名前, eqSpec, 番号の比べ)。
    def answers(names: (String, String)): List[(String, Bool, Bool)] =
        fixtures() |> List.map(entry -> {
            let (label, make) = entry;
            let (x, y) = names;
            let left = make("a", "b");
            let right = make(x, y);
            (label, ShaderGen.eqSpec(left, right), byIndex(left, right))
        })

    def agrees(rows: List[(String, Bool, Bool)]): List[String] =
        rows |> List.filter(r -> { let (_, now, before) = r; now != before }) |> List.map(r -> { let (label, _, _) = r; label })

    def verdicts(rows: List[(String, Bool, Bool)]): List[Bool] =
        rows |> List.map(r -> { let (_, now, _) = r; now })

    @Test
    def testRenamedOneToOneAgreesWithIndex(): Unit \ Assert =
        Assert.assertEq(expected = Nil, agrees(answers(("p", "q"))))

    @Test
    def testSwappedNamesAgreeWithIndex(): Unit \ Assert =
        Assert.assertEq(expected = Nil, agrees(answers(("b", "a"))))

    @Test
    def testCollapsedNamesAgreeWithIndex(): Unit \ Assert =
        Assert.assertEq(expected = Nil, agrees(answers(("z", "z"))))

    @Test
    def testRenamedOneToOneIsEqual(): Unit \ Assert =
        Assert.assertEq(expected = List.map(_ -> true, fixtures()), verdicts(answers(("p", "q"))))

    @Test
    def testCollapsedNamesAreNotEqual(): Unit \ Assert =
        Assert.assertEq(expected = List.map(_ -> false, fixtures()), verdicts(answers(("z", "z"))))

    // ── eqMaterial（spec と emission を通して 1 本の対応）──

    def specReading(name: String): ShaderDoc.Spec = specWith(Nil, solid(), tex(name))

    def glow(name: String): Option[Shade] = Some(Shade.Rgb({ r = tex(name), g = Field.Const(0.0), b = Field.Const(0.0) }))

    @Test
    def testEmissionReadingAnotherNameIsNotEqual(): Unit \ Assert =
        Assert.assertFalse(ShaderGen.eqMaterial(specReading("a"), glow("a"), None, specReading("a"), glow("g"), None))

    @Test
    def testSameSpecValueWithAnotherEmissionNameIsNotEqual(): Unit \ Assert =
        let spec = specReading("a");
        Assert.assertFalse(ShaderGen.eqMaterial(spec, glow("a"), None, spec, glow("g"), None))

    @Test
    def testMaterialRenamedTogetherIsEqual(): Unit \ Assert =
        Assert.assertTrue(ShaderGen.eqMaterial(specReading("a"), glow("e"), None, specReading("p"), glow("q"), None))

    @Test
    def testSpecTexSizeOnlyAndEmissionTexRenamedIsEqual(): Unit \ Assert =
        let sized = n -> specWith(Nil, solid(), Field.TexSize({ name = n, axis = Axis.U }));
        Assert.assertTrue(ShaderGen.eqMaterial(sized("s"), glow("e"), None, sized("x"), glow("y"), None))

    @Test
    def testEmissionOnOneSideOnlyIsNotEqual(): Unit \ Assert =
        Assert.assertFalse(ShaderGen.eqMaterial(specReading("a"), glow("a"), None, specReading("a"), None, None))

    // ── hashMaterial は名前の対応で eqSpec・eqMaterial と同じ答え（真の組は同じ鍵・偽の組は違う鍵）──

    def hashAgrees(names: (String, String)): List[String] =
        fixtures() |> List.filterMap(entry -> {
            let (label, make) = entry;
            let (x, y) = names;
            let left = make("a", "b");
            let right = make(x, y);
            let sameKey = ShaderGen.hashMaterial(left, None, None) == ShaderGen.hashMaterial(right, None, None);
            if (sameKey == ShaderGen.eqSpec(left, right)) None else Some(label)
        })

    @Test
    def testHashAgreesWithEqSpecOnRenamedNames(): Unit \ Assert =
        Assert.assertEq(expected = Nil, hashAgrees(("p", "q")) ::: hashAgrees(("b", "a")) ::: hashAgrees(("z", "z")))

    @Test
    def testHashAgreesWithEqMaterial(): Unit \ Assert =
        let pairs = (specReading("a"), glow("a"), specReading("a"), glow("g"))
            :: (specReading("a"), glow("e"), specReading("p"), glow("q"))
            :: (specReading("a"), glow("a"), specReading("a"), None) :: Nil;
        let disagree = pairs |> List.filter(t -> {
            let (sa, ea, sb, eb) = t;
            (ShaderGen.hashMaterial(sa, ea, None) == ShaderGen.hashMaterial(sb, eb, None)) != ShaderGen.eqMaterial(sa, ea, None, sb, eb, None)
        });
        Assert.assertEq(expected = 0, List.length(disagree))
}
