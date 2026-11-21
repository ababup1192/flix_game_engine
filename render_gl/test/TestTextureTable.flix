// 絵の CPU の側の表（TextureTable）が ensureTexture で backend の上げる関数をどう呼ぶかを固定する。
// GPU を呼ばない Uploads（呼ばれた順に "create 8x8"・"write 5"・"drop 5" を控える）で表を育て、控えと表を読む。

mod TestTextureTable {
    import java.nio.ByteBuffer
    use RenderPaint.Internal.TextureTable.{Tables, Uploads, ensureRadialBuiltins, ensureTexture, isRadialBuiltinName, putRadialBuiltins, putTexture}
    use RenderPaint.Internal.TextureTable.{opaqueRgbaOf}

    // ── 組み立て ──

    /// 呼ばれた順を控える Uploads。作る絵の番号は 100 から。
    def recordingUploads(log: Ref[List[String], Static]): Uploads =
        { createArgb = (width, height, _) -> {
              Ref.put("create ${Int32.toString(width)}x${Int32.toString(height)}" :: Ref.get(log), log);
              { id = GpuHandle.wrapTextureId(100), width = Int32.toFloat64(width), height = Int32.toFloat64(height) }
          },
          createImage = (width, height, _, _) -> {
              Ref.put("image ${Int32.toString(width)}x${Int32.toString(height)}" :: Ref.get(log), log);
              { id = GpuHandle.wrapTextureId(100), width = Int32.toFloat64(width), height = Int32.toFloat64(height) }
          },
          writeArgb = (info, _, _, _) -> Ref.put("write ${Int32.toString(GpuHandle.textureIdInt(info#id))}" :: Ref.get(log), log),
          drop = info -> Ref.put("drop ${Int32.toString(GpuHandle.textureIdInt(info#id))}" :: Ref.get(log), log) }

    def freshTables(): Tables \ IO =
        { registryRef = Ref.fresh(Static, Map.empty()), textureKeyRef = Ref.fresh(Static, Map.empty()) }

    def pixels(n: Int32): Vector[Int32] = Vector.repeat(n, 0)

    /// 名前 "gen" を key で 1 回ずつ上げ、呼ばれた順の控え（古い順）を返す。
    def callsOf(steps: List[(String, Int32)]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        let tables = freshTables();
        let uploads = recordingUploads(log);
        List.forEach(step -> ensureTexture(uploads, tables, () -> (), "gen", fst(step), snd(step), snd(step), pixels(snd(step) * snd(step))), steps);
        List.reverse(Ref.get(log))

    // ── ensureTexture ──

    /// 同じ key の 2 回目は何も上げない。
    @Test
    def testSameKeyUploadsOnce(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 8x8" :: Nil, callsOf(("k1", 8) :: ("k1", 8) :: Nil))

    /// key が変わって大きさが同じなら、作った絵（番号 100）の画素を差し替えるだけ。
    @Test
    def testSameSizeRewritesPixels(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 8x8" :: "write 100" :: Nil, callsOf(("k1", 8) :: ("k2", 8) :: Nil))

    /// 大きさが変われば古い絵を捨ててから作り直す。
    @Test
    def testSizeChangeDropsThenCreates(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 8x8" :: "drop 100" :: "create 16x16" :: Nil, callsOf(("k1", 8) :: ("k2", 16) :: Nil))

    /// マニフェストで読んだ絵（key を持たない名前・番号 5）と同じ名前には上げない（表の絵もそのまま）。
    @Test
    def testManifestNameIsNotOverwritten(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let tables = freshTables();
        let manifest = { id = GpuHandle.wrapTextureId(5), width = 8.0, height = 8.0 };
        putTexture(tables, "gen", manifest);
        ensureTexture(recordingUploads(log), tables, () -> (), "gen", "k1", 8, 8, pixels(64));
        let kept = Map.get("gen", Ref.get(tables#registryRef)) |> Option.map(info -> GpuHandle.textureIdInt(info#id));
        Assert.assertEq(expected = (Nil, Some(5)), (Ref.get(log), kept))

    /// 組み込みの放射の絵は、光と闇の 2 枚を RadialBuiltin の辺の長さで作って名前で置く。
    @Test
    def testRadialBuiltinsPutsLightAndDark(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let tables = freshTables();
        putRadialBuiltins(recordingUploads(log), tables);
        let side = Int32.toString(RadialBuiltin.size());
        let named = (Map.memberOf(RadialBuiltin.lightName(), Ref.get(tables#registryRef)), Map.memberOf(RadialBuiltin.darkName(), Ref.get(tables#registryRef)));
        Assert.assertEq(expected = (("create ${side}x${side}" :: "create ${side}x${side}" :: Nil), (true, true)), (List.reverse(Ref.get(log)), named))

    /// 描く物が引かないうちは、組み込みの放射の絵を作らない。
    @Test
    def testRadialBuiltinsWaitUntilRead(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let tables = freshTables();
        ensureRadialBuiltins(recordingUploads(log), tables, () -> false);
        Assert.assertEq(expected = (Nil, false), (Ref.get(log), Map.memberOf(RadialBuiltin.lightName(), Ref.get(tables#registryRef))))

    /// 引いた最初のコマで 2 枚を作り、次のコマからは作り直さない。
    @Test
    def testRadialBuiltinsAreMadeOnceWhenRead(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let tables = freshTables();
        let uploads = recordingUploads(log);
        ensureRadialBuiltins(uploads, tables, () -> true);
        ensureRadialBuiltins(uploads, tables, () -> true);
        Assert.assertEq(expected = 2, List.length(Ref.get(log)))

    /// 作った後は、描く物を調べ直さない（毎コマの列を回さない）。
    @Test
    def testRadialBuiltinsSkipTheCheckAfterMade(): Unit \ {Assert, IO} =
        let asked = Ref.fresh(Static, 0);
        let tables = freshTables();
        let uploads = recordingUploads(Ref.fresh(Static, Nil));
        let reads = () -> { Ref.put(Ref.get(asked) + 1, asked); true };
        ensureRadialBuiltins(uploads, tables, reads);
        ensureRadialBuiltins(uploads, tables, reads);
        Assert.assertEq(expected = 1, Ref.get(asked))

    /// 組み込みの名前は光と闇の 2 つだけ。
    @Test
    def testRadialBuiltinNames(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, false),
            (isRadialBuiltinName(RadialBuiltin.lightName()), isRadialBuiltinName(RadialBuiltin.darkName()), isRadialBuiltinName("atlas")))

    /// 上げた時だけ診断へ知らせる（同じ key の 2 回目は知らせない）。
    @Test
    def testNotesOnlyUploads(): Unit \ {Assert, IO} =
        let noted = Ref.fresh(Static, 0);
        let tables = freshTables();
        let uploads = recordingUploads(Ref.fresh(Static, Nil));
        let note = () -> Ref.put(Ref.get(noted) + 1, noted);
        ensureTexture(uploads, tables, note, "gen", "k1", 8, 8, pixels(64));
        ensureTexture(uploads, tables, note, "gen", "k1", 8, 8, pixels(64));
        Assert.assertEq(expected = 1, Ref.get(noted))

    // ── opaqueRgbaOf（3 バイトの形式を持たない backend が alpha の無い絵を広げる所）──

    /// RGB の 2 画素は、色をそのままに alpha を 255（-1 のバイト）にした RGBA の 8 バイトになる。
    @Test
    def testOpaqueRgbaKeepsColorAndFillsAlpha(): Unit \ {Assert, IO} =
        let rgb = ByteBuffer.allocateDirect(6);
        List.forEachWithIndex((i, b) -> discard rgb.put(i, b), 1i8 :: 2i8 :: 3i8 :: 4i8 :: 5i8 :: 6i8 :: Nil);
        let rgba = opaqueRgbaOf(rgb, 2);
        Assert.assertEq(expected = 1i8 :: 2i8 :: 3i8 :: -1i8 :: 4i8 :: 5i8 :: 6i8 :: -1i8 :: Nil, List.map(i -> rgba.get(i), List.range(0, 8)))
}
