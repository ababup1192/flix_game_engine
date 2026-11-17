// スプライト・字・箱の run が RenderList の行になる所（GL を呼ばない前半）を固定する。
// 描き物を emitSprite へ順に渡して run を閉じ、行の欄と instances の値を読む。
// WhyNot: mod TestRenderList にしない — 行を作る関数は RenderFrame の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderFrame.TestRenderList {
    import java.nio.FloatBuffer
    use RenderFrame.{blendCode, calcViewport, closeSpriteRun, emitSprite, pushSpriteKeyed, stateSize, writeInstAt}
    use RenderFrame.Internal.RenderList.{DepthStencil, Letterbox, PassHistory, PassSpec, RenderList, drawSamplesOf, resolveTargetOf, clearRenderList, glViewportOf, hasLetterbox, instanceFloats, kindSprite,
                                         withLetterboxKept, letterboxOf, loadOpOf, newRenderList, nextInstanceOf, rowAt, rowCountOf, rowsOf, screenClearColorOf, screenPass,
                                         targetFormatOf, targetPass, targetTextureOf, fullTargetPass}

    // ── 組み立て ──

    def spriteWith(spec: { texture = String, x = Float64, blend = DrawCmd.BlendMode, clip = Option[Rect2.Rect2] }): DrawCmd.Drawable =
        DrawCmd.make({
          texture = spec#texture, position = { x = spec#x, y = 2.0 }, scale = { x = 1.0, y = 1.0 },
          rotation = 0.0, color = { r = 1.0, g = 0.5, b = 0.25 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = None, clip = spec#clip, blend = spec#blend, mask = Nil })

    /// 絵 texture（"" は絵の無い箱）を x に置いたスプライト。
    def sprite(texture: String, x: Float64): DrawCmd.Drawable =
        spriteWith({ texture = texture, x = x, blend = DrawCmd.BlendMode.Normal, clip = None })

    def clipRect(): Rect2.Rect2 = { position = { x = 1.0, y = 2.0 }, size = { x = 30.0, y = 20.0 } }

    /// 絵 "a" と "b" を登録した表。
    def registry(): RenderAsset.TextureRegistry =
        Map#{"a" => { id = GpuHandle.wrapTextureId(5), width = 8.0, height = 8.0 },
             "b" => { id = GpuHandle.wrapTextureId(6), width = 8.0, height = 8.0 }}

    def textureIdOf(name: String): Int32 =
        Map.get(name, registry()) |> Option.map(t -> GpuHandle.textureIdInt(t#id)) |> Option.getWithDefault(-1)

    /// 描き物を順に積んで run を閉じた RenderList（倍率 1・Pass の絵は無し・"missing" は知らせ済み）。
    def listOf(drawables: List[DrawCmd.Drawable]): RenderList \ IO =
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        let list = newRenderList(FloatBuffer.allocate(instanceFloats() * Int32.max(1, List.length(drawables))), FloatBuffer.allocate(0));
        let warnLog = Ref.fresh(Static, Set#{"missing"});
        List.forEach(d -> emitSprite(st, list, 1.0, 1.0, registry(), Set.empty(), warnLog, d), drawables);
        closeSpriteRun(st, list);
        list

    /// 行 row の欄 col。
    def cell(list: RenderList, row: Int32, col: Int32): Int32 \ IO = rowAt(rowsOf(list), row, col)

    /// 行 row の instances（1 体 38 個）の n 体目。
    def instanceFloatsAt(list: RenderList, row: Int32, n: Int32): List[Float32] \ IO =
        let base = (cell(list, row, 1) + n) * instanceFloats();
        List.range(0, instanceFloats()) |> List.map(i -> list#instances.get(base + i))

    /// writeInstAt が 1 体を頭に書いた 38 個（行を作る道とは別の道）。
    def writtenAlone(posX: Float64, sizeX: Float64, d: DrawCmd.Drawable, useTex: Bool): List[Float32] \ IO =
        let buf = FloatBuffer.allocate(instanceFloats());
        writeInstAt(buf, 0, posX, 2.0, sizeX, 8.0, d, useTex, false);
        List.range(0, instanceFloats()) |> List.map(i -> buf.get(i))

    def alternating(n: Int32): List[DrawCmd.Drawable] =
        List.range(0, n) |> List.map(i -> sprite(if (Int32.remainder(i, 2) == 0) "a" else "b", Int32.toFloat64(i)))

    // ── run と行 ──

    /// 同じ絵のスプライト 3 個は 1 行。
    @Test
    def testSameTextureIsOneRow(): Unit \ {Assert, IO} =
        let list = listOf(sprite("a", 0.0) :: sprite("a", 1.0) :: sprite("a", 2.0) :: Nil);
        Assert.assertEq(expected = 1, rowCountOf(list))

    /// 同じ絵の 3 個の行は 3 体ぶん。
    @Test
    def testRowCountsSpritesOfRun(): Unit \ {Assert, IO} =
        let sprites = sprite("a", 0.0) :: sprite("a", 1.0) :: sprite("a", 2.0) :: Nil;
        Assert.assertEq(expected = List.length(sprites), cell(listOf(sprites), 0, 2))

    /// 行の種類はスプライトの run。
    @Test
    def testRowKindIsSprite(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = kindSprite(), cell(listOf(sprite("a", 0.0) :: Nil), 0, 0))

    /// 絵が交互の 3 個は 3 行。
    @Test
    def testTextureChangeStartsRow(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 3, rowCountOf(listOf(alternating(3))))

    /// 行の絵の番号は、表に登録した絵の番号。
    @Test
    def testRowTextureIsRegisteredId(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = textureIdOf("b"), cell(listOf(alternating(2)), 1, 3))

    /// 絵の無い箱の行の絵の番号は 0。
    @Test
    def testBoxRowHasNoTexture(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0, cell(listOf(sprite("", 0.0) :: Nil), 0, 3))

    /// 2 行目の先頭の instance は、1 行目の後ろ。
    @Test
    def testNextRowStartsAfterPrevious(): Unit \ {Assert, IO} =
        let list = listOf(sprite("a", 0.0) :: sprite("a", 1.0) :: sprite("b", 2.0) :: Nil);
        Assert.assertEq(expected = cell(list, 0, 1) + cell(list, 0, 2), cell(list, 1, 1))

    /// 同じ絵で blend だけ替わると次の行になり、その行の blend は Add。
    @Test
    def testBlendChangeStartsRow(): Unit \ {Assert, IO} =
        let added = spriteWith({ texture = "a", x = 1.0, blend = DrawCmd.BlendMode.Add, clip = None });
        Assert.assertEq(expected = blendCode(DrawCmd.BlendMode.Add), cell(listOf(sprite("a", 0.0) :: added :: Nil), 1, 4))

    /// 切り抜きの矩形を持つ行は、DrawCmd.clipPixels の画素の矩形を持つ。
    @Test
    def testClippedRowKeepsClipPixels(): Unit \ {Assert, IO} =
        let clipped = spriteWith({ texture = "a", x = 0.0, blend = DrawCmd.BlendMode.Normal, clip = Some(clipRect()) });
        let list = listOf(clipped :: Nil);
        Assert.assertEq(expected = (1, DrawCmd.clipPixels({ scaleX = 1.0, scaleY = 1.0 }, clipRect())),
                        (cell(list, 0, 5), (cell(list, 0, 6), cell(list, 0, 7), cell(list, 0, 8), cell(list, 0, 9))))

    /// 表に無い絵のスプライトは行を作らない。
    @Test
    def testUnregisteredTextureMakesNoRow(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0, rowCountOf(listOf(sprite("missing", 0.0) :: Nil)))

    /// 初めに取った行の数（16）を超えても、行は描き物の数だけできる。
    @Test
    def testRowsGrowPastFirstRoom(): Unit \ {Assert, IO} =
        let sprites = alternating(40);
        Assert.assertEq(expected = List.length(sprites), rowCountOf(listOf(sprites)))

    /// 倍に広げた後も、16 番目の行（絵 "b"）の絵の番号は表の番号のまま。
    @Test
    def testGrownRowsKeepContents(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = textureIdOf("b"), cell(listOf(alternating(40)), 15, 3))

    /// 絵も blend も同じで、切り抜きの矩形だけが替わると次の行になる。
    @Test
    def testClipChangeStartsRow(): Unit \ {Assert, IO} =
        let other = { position = { x = 5.0, y = 5.0 }, size = { x = 10.0, y = 10.0 } };
        let first = spriteWith({ texture = "a", x = 0.0, blend = DrawCmd.BlendMode.Normal, clip = Some(clipRect()) });
        let second = spriteWith({ texture = "a", x = 1.0, blend = DrawCmd.BlendMode.Normal, clip = Some(other) });
        Assert.assertEq(expected = 2, rowCountOf(listOf(first :: second :: Nil)))

    /// 切り抜きが無いどうしは、run の鍵に残った矩形の数が違っても 1 行のまま。
    @Test
    def testNoClipIgnoresLeftoverRect(): Unit \ {Assert, IO} =
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        let list = newRenderList(FloatBuffer.allocate(2 * instanceFloats()), FloatBuffer.allocate(0));
        let d = sprite("a", 0.0);
        pushSpriteKeyed(st, list, 5, 0, 1, 2, 30, 40, 0, 0.0, 0.0, 8.0, 8.0, d, true, false);
        pushSpriteKeyed(st, list, 5, 0, 7, 8, 9, 10, 0, 1.0, 0.0, 8.0, 8.0, d, true, false);
        closeSpriteRun(st, list);
        Assert.assertEq(expected = 1, rowCountOf(list))

    // ── instances ──

    /// 2 行目の 1 体目の値は、同じスプライトを writeInstAt で 1 体だけ書いた値と同じ。
    @Test
    def testRowInstanceMatchesWriteInstAt(): Unit \ {Assert, IO} =
        let b = sprite("b", 2.0);
        let list = listOf(sprite("a", 0.0) :: sprite("a", 1.0) :: b :: Nil);
        Assert.assertEq(expected = writtenAlone(2.0, 8.0, b, true), instanceFloatsAt(list, 1, 0))

    /// 2 行目の 2 体目の値は、同じスプライトを writeInstAt で 1 体だけ書いた値と同じ。
    @Test
    def testSecondInstanceOfRowMatchesWriteInstAt(): Unit \ {Assert, IO} =
        let last = sprite("b", 2.0);
        let list = listOf(sprite("a", 0.0) :: sprite("b", 1.0) :: last :: Nil);
        Assert.assertEq(expected = writtenAlone(2.0, 8.0, last, true), instanceFloatsAt(list, 1, 1))

    // ── 空にする ──

    /// 空にした列は行が 0。
    @Test
    def testClearDropsRows(): Unit \ {Assert, IO} =
        let list = listOf(alternating(3));
        clearRenderList(list);
        Assert.assertEq(expected = 0, rowCountOf(list))

    /// 空にした列の次の run は instances の頭から書く。
    @Test
    def testClearRewindsInstances(): Unit \ {Assert, IO} =
        let list = listOf(alternating(3));
        clearRenderList(list);
        Assert.assertEq(expected = 0, nextInstanceOf(list))

    // ── pass の指定 ──

    def clearColor(): Color = { r = 51.0 / 255.0, g = 102.0 / 255.0, b = 153.0 / 255.0 }

    /// 320 × 200 に design 320 × 180 を収めた画面の pass（上下に 10 px ずつの黒帯）。
    def letterboxedScreen(): PassSpec =
        screenPass((320, 200), (320.0, 180.0), clearColor(), DepthStencil.NoDepthStencil)

    /// 番号 7 の絵へ op で描く Pass の pass。
    def passTo(op: RenderTarget.LoadOp): PassSpec = passSampled(op, 1)

    /// 番号 7 の絵へ標本 samples で描く Pass の pass（history は番号 9 へ写す）。
    def passSampled(op: RenderTarget.LoadOp, samples: Int32): PassSpec =
        targetPass((64, 32), { texture = 7, format = RenderTarget.Format.Rgba16Float, load = op }, DepthStencil.NoDepthStencil, samples, PassHistory.CopyTo(9))

    /// LoadOp を比べられる形に（Clear は色の 8 bit・ClearTransparent は -1・Keep は -2）。
    def opOf(op: RenderTarget.LoadOp): (Int32, Int32, Int32) = match op {
        case RenderTarget.LoadOp.Clear(c)         => (Float64.round(c#r * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                                      Float64.round(c#g * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                                      Float64.round(c#b * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0))
        case RenderTarget.LoadOp.ClearTransparent => (-1, -1, -1)
        case RenderTarget.LoadOp.Keep             => (-2, -2, -2)
    }

    /// 画面の pass の viewport は左上が原点で、上の黒帯 10 px の下から始まる。
    @Test
    def testScreenViewportIsTopLeftOrigin(): Unit \ Assert =
        Assert.assertEq(expected = (0, 10, 320, 180), letterboxedScreen()#viewport)

    /// 横に広い描き先（400 × 180 に design 320 × 180）は左右に 40 px ずつの黒帯で、viewport は x = 40 から。
    @Test
    def testPillarboxViewportStartsAfterLeftBand(): Unit \ Assert =
        let wide = screenPass((400, 180), (320.0, 180.0), clearColor(), DepthStencil.NoDepthStencil);
        Assert.assertEq(expected = ((40, 0, 320, 180), true), (wide#viewport, hasLetterbox(wide)))

    /// 形式の比べられる名前（無ければ "none"）。
    def formatName(format: Option[RenderTarget.Format]): String = match format {
        case Some(RenderTarget.Format.Rgba8Unorm)  => "rgba8"
        case Some(RenderTarget.Format.Rgba16Float) => "rgba16f"
        case None                                  => "none"
    }

    /// Pass の形式と地の色: 画面は形式を持たず地の色を持ち、Pass は頭の attachment の形式（Rgba16Float）を持ち地の色を持たない。
    @Test
    def testFormatAndClearColorOfScreenAndPass(): Unit \ Assert =
        let pass = passTo(RenderTarget.LoadOp.Keep);
        Assert.assertEq(expected = ("none", false, "rgba16f", true),
                        (formatName(targetFormatOf(letterboxedScreen())), Option.isEmpty(screenClearColorOf(letterboxedScreen())),
                         formatName(targetFormatOf(pass)), Option.isEmpty(screenClearColorOf(pass))))

    /// GL の左下が原点の viewport へ戻すと calcViewport と同じ（下の黒帯が 11 px の 201 px の高さでも）。
    @Test
    def testGlViewportMatchesCalcViewport(): Unit \ Assert =
        let odd = screenPass((320, 201), (320.0, 180.0), clearColor(), DepthStencil.NoDepthStencil);
        Assert.assertEq(expected = calcViewport(320, 201, 320.0, 180.0), glViewportOf(odd))

    /// 黒帯が要るのは design の矩形が描き先の全面でない画面だけ（Pass は持たない）。
    @Test
    def testLetterboxOnlyWhenViewportIsSmaller(): Unit \ Assert =
        let full = screenPass((320, 180), (320.0, 180.0), clearColor(), DepthStencil.NoDepthStencil);
        Assert.assertEq(expected = (true, false, false),
                        (hasLetterbox(letterboxedScreen()), hasLetterbox(full), hasLetterbox(passTo(RenderTarget.LoadOp.Keep))))

    /// 画面は黒帯があれば黒・無ければ clearColor で始め、Pass は頼まれた op のまま。
    @Test
    def testLoadOpOfScreenAndPass(): Unit \ Assert =
        let full = screenPass((320, 180), (320.0, 180.0), clearColor(), DepthStencil.NoDepthStencil);
        Assert.assertEq(expected = ((0, 0, 0), (51, 102, 153), (-2, -2, -2), (-1, -1, -1)),
                        (opOf(loadOpOf(letterboxedScreen())), opOf(loadOpOf(full)),
                         opOf(loadOpOf(passTo(RenderTarget.LoadOp.Keep))), opOf(loadOpOf(passTo(RenderTarget.LoadOp.ClearTransparent)))))

    /// 余りを先に塗った本編の pass は、余りを残す（前の中身のまま始める）。余りの無い画面の pass は clearColor のまま。
    @Test
    def testKeepingLetterboxLoadsWhatWasPaintedOutside(): Unit \ Assert =
        let full = screenPass((320, 180), (320.0, 180.0), clearColor(), DepthStencil.NoDepthStencil);
        Assert.assertEq(expected = ((-2, -2, -2), (51, 102, 153)),
                        (opOf(loadOpOf(withLetterboxKept(letterboxedScreen()))), opOf(loadOpOf(withLetterboxKept(full)))))

    /// 余りを広げて塗る pass は、描き先の全面を viewport にして余りを持たない。
    @Test
    def testWindowPassCoversTheWholeTarget(): Unit \ Assert =
        let window = fullTargetPass((400, 180), clearColor(), DepthStencil.NoDepthStencil);
        Assert.assertEq(expected = ((0, 0, 400, 180), false), (window#viewport, hasLetterbox(window)))

    /// 余りを残す pass も design の矩形は余りの内側のまま（viewport は替えない）。
    @Test
    def testKeepingLetterboxKeepsTheViewport(): Unit \ Assert =
        Assert.assertEq(expected = ((0, 10, 320, 180), Letterbox.Kept),
                        (withLetterboxKept(letterboxedScreen())#viewport, letterboxOf(withLetterboxKept(letterboxedScreen()))))

    /// 1e-6 の桁に丸めた (x, y)。
    def rounded(v: { x = Float64, y = Float64 }): (Int64, Int64) =
        (Float64.round(v#x * 1000000.0) |> Float64.tryToInt64 |> Option.getWithDefault(0i64),
         Float64.round(v#y * 1000000.0) |> Float64.tryToInt64 |> Option.getWithDefault(0i64))

    /// 横長の窓（1280 × 720）に縦の design（540 × 1170）: 絵は横いっぱいに広げ、上下は真ん中で切る（uv の高さ = design の比 ÷ 窓の比）。
    @Test
    def testLetterboxFillCropsTopAndBottomInWideWindow(): Unit \ Assert =
        let spec = DrawCmd.toSpec(RenderFrame.letterboxFillOf((1280, 720), (540.0, 1170.0), "fge_letterbox", (540.0, 1170.0)));
        let h = (540.0 / 1170.0) / (1280.0 / 720.0);
        Assert.assertEq(expected = (rounded({ x = 1.0, y = h }), rounded({ x = 0.0, y = (1.0 - h) / 2.0 }), rounded({ x = 1.0, y = 1.0 })),
                        (rounded(spec#uvScale), rounded(spec#uvOffset), rounded(spec#scale)))

    /// 縦長の窓（400 × 900）に横の design（320 × 180）: 絵は縦いっぱいに広げ、左右を真ん中で切る。絵の表の大きさが design と違えば倍率で合わせる。
    @Test
    def testLetterboxFillCropsSidesInTallWindow(): Unit \ Assert =
        let spec = DrawCmd.toSpec(RenderFrame.letterboxFillOf((400, 900), (320.0, 180.0), "fge_letterbox", (640.0, 360.0)));
        let w = (400.0 / 900.0) / (320.0 / 180.0);
        Assert.assertEq(expected = (rounded({ x = w, y = 1.0 }), rounded({ x = (1.0 - w) / 2.0, y = 0.0 }), rounded({ x = 0.5, y = 0.5 })),
                        (rounded(spec#uvScale), rounded(spec#uvOffset), rounded(spec#scale)))

    /// 描き先の絵の番号: 画面は -1・Pass は色の attachment の番号。
    @Test
    def testTargetTextureOfScreenAndPass(): Unit \ Assert =
        Assert.assertEq(expected = (-1, 7), (targetTextureOf(letterboxedScreen()), targetTextureOf(passTo(RenderTarget.LoadOp.Keep))))

    /// 標本 4 の Pass は、pass の終わりに描き先と同じ番号の絵へ resolve する。
    @Test
    def testSampledPassResolvesIntoItsTexture(): Unit \ Assert =
        Assert.assertEq(expected = Some(7), resolveTargetOf(passSampled(RenderTarget.LoadOp.Keep, 4)))

    /// 標本 1 の Pass は resolve しない。
    @Test
    def testSingleSamplePassDoesNotResolve(): Unit \ Assert =
        Assert.assertEq(expected = None, resolveTargetOf(passSampled(RenderTarget.LoadOp.Keep, 1)))

    /// 画面の pass は resolve しない。
    @Test
    def testScreenPassDoesNotResolve(): Unit \ Assert =
        Assert.assertEq(expected = None, resolveTargetOf(letterboxedScreen()))

    /// 画面の pass は history を読まない。
    @Test
    def testScreenPassHasNoHistory(): Unit \ Assert =
        Assert.assertEq(expected = PassHistory.NoHistory, letterboxedScreen()#history)

    /// Pass の pass は渡した history の始末を持つ。
    @Test
    def testTargetPassCarriesHistory(): Unit \ Assert =
        Assert.assertEq(expected = PassHistory.CopyTo(9), passTo(RenderTarget.LoadOp.Keep)#history)

    // ── 標本の数（RenderList.drawSamplesOf）──

    /// WebGPU（1 と 4）は 8 を 4 に。
    @Test
    def testEightBecomesFourOnWebGpu(): Unit \ Assert =
        Assert.assertEq(expected = 4, drawSamplesOf(8, 1 :: 4 :: Nil))

    /// WebGPU（1 と 4）は 2 を 4 に上げる（1 へは下げない）。
    @Test
    def testTwoBecomesFourOnWebGpu(): Unit \ Assert =
        Assert.assertEq(expected = 4, drawSamplesOf(2, 1 :: 4 :: Nil))

    /// 描ける数に頼んだ数があればそのまま。
    @Test
    def testSupportedCountIsKept(): Unit \ Assert =
        Assert.assertEq(expected = 2, drawSamplesOf(2, 1 :: 2 :: 4 :: 8 :: Nil))

    /// GL の上限で頭打ち（上限 4 で 8 を頼むと 4）。
    @Test
    def testCappedByMaxSamples(): Unit \ Assert =
        Assert.assertEq(expected = 4, drawSamplesOf(8, 1 :: 2 :: 4 :: Nil))

    /// 1 標本しか描けなければ 1。
    @Test
    def testOnlySingleSampleStaysOne(): Unit \ Assert =
        Assert.assertEq(expected = 1, drawSamplesOf(4, 1 :: Nil))

    /// 1 未満を頼まれたら 1。
    @Test
    def testBelowOneBecomesOne(): Unit \ Assert =
        Assert.assertEq(expected = 1, drawSamplesOf(0, 1 :: 4 :: Nil))
}
