// Pass の計画（Render.resolvePassReads / passSpecsOf）を具体値で固定する。
// 読みの書き換えは GL と描き出しが同じ結果を使う決まりの芯なので、名前の行き先を 1 本ずつ見る。
mod TestPassPlan {

    /// 名前のテクスチャを r で読むだけの全面の面（4×4）。
    def readsFill(name: String): Render.PlacedItem =
        let spec: ShaderDoc.Spec = { name = "reads_" + name, cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
                                       alpha = ShaderDoc.Field.Tex({ name = name, chan = ShaderDoc.TexChan.R }) }) };
        Render.shaderFill(spec, { position = { x = 0.0, y = 0.0 }, size = { x = 4.0, y = 4.0 } }, 0.0, 0)

    def spriteOf(name: String): Render.PlacedItem =
        { at = { x = 2.0, y = 2.0 }, item = Render.sprite(name, 1) }

    def pass(name: String, items: List[Render.PlacedItem]): Render.Pass =
        { name = name, clear = RenderTarget.LoadOp.ClearTransparent, items = items }

    /// a → b → c の 3 本。a は後ろの c を読み、b は前の a と自分の b を読む。
    def chainPlan(): Render.PassPlan =
        Render.passPlan(pass("a", readsFill("c") :: Nil)
            :: pass("b", readsFill("a") :: readsFill("b") :: Nil)
            :: pass("c", Nil) :: Nil)

    /// Pass の中の読みの名前（面の tex 名と sprite の texture 名を、置いた順に）。
    def readsIn(p: Render.Pass): List[String] =
        p#items |> List.flatMap(placed -> match placed#item {
            case Render.Item.Shader(sh) => ShaderDoc.texNames(sh#spec)
            case Render.Item.Sprite(sp) => sp#texture :: Nil
            case _                      => Nil
        })

    // まだ描いていない Pass を読むのだけが問題になる（前の Pass と自分の名前は問題ではない）。
    @Test
    def testLaterPassReadIsTheOnlyIssue(): Unit \ Assert =
        Assert.assertEq(expected = Render.PassPlanIssue.ReadsLaterPass("a", "c") :: Nil,
                        Render.resolvePassReads(Set.empty(), chainPlan())#issues)

    // 後ろの c は見つからない名前へ・前の a はそのまま・自分の b は history の別名へ。
    @Test
    def testReadsAreRenamed(): Unit \ Assert =
        let passes = Render.resolvePassReads(Set.empty(), chainPlan())#plan#passes;
        Assert.assertEq(expected = ("@missing:c" :: Nil) :: ("a" :: "b@history" :: Nil) :: Nil :: Nil,
                        List.map(readsIn, passes))

    // 同じ面（同じ Spec の物）を 2 つの Pass に置いても、読み替えは Pass ごと（a の中では自分の history・b の中では前の a）。
    @Test
    def testSharedSurfaceIsRenamedPerPass(): Unit \ Assert =
        let shared = readsFill("a");
        let plan = Render.passPlan(pass("a", shared :: shared :: Nil) :: pass("b", shared :: readsFill("b") :: Nil) :: Nil);
        let passes = Render.resolvePassReads(Set.empty(), plan)#plan#passes;
        Assert.assertEq(expected = ("a@history" :: "a@history" :: Nil) :: ("a" :: "b@history" :: Nil) :: Nil,
                        List.map(readsIn, passes))

    /// 名前のテクスチャの幅（TexSize）だけを読む全面の面（4×4）。
    def sizeFill(name: String): Render.PlacedItem =
        let spec: ShaderDoc.Spec = { name = "size_" + name, cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
                                       alpha = ShaderDoc.Field.TexSize({ name = name, axis = ShaderDoc.Axis.U }) }) };
        Render.shaderFill(spec, { position = { x = 0.0, y = 0.0 }, size = { x = 4.0, y = 4.0 } }, 0.0, 0)

    // TexSize も読みとして書き換わる: 自分の名前は history・後ろの Pass は見つからない名前（寸法 0）へ・後ろを読んだことを知らせる。
    @Test
    def testTexSizeReadsAreRenamedLikeTex(): Unit \ Assert =
        let plan = Render.passPlan(pass("a", sizeFill("a") :: sizeFill("b") :: Nil) :: pass("b", Nil) :: Nil);
        let resolved = Render.resolvePassReads(Set.empty(), plan);
        Assert.assertEq(expected = (Render.PassPlanIssue.ReadsLaterPass("a", "b") :: Nil, ("a@history" :: "@missing:b" :: Nil) :: Nil :: Nil),
                        (resolved#issues, List.map(readsIn, resolved#plan#passes)))

    // sprite で貼る名前も面と同じに書き換わる（GL で後ろの Pass の古い中身が貼られない）。
    @Test
    def testSpriteReadIsRenamedLikeSurface(): Unit \ Assert =
        let plan = Render.passPlan(pass("a", spriteOf("b") :: spriteOf("a") :: Nil) :: pass("b", Nil) :: Nil);
        let passes = Render.resolvePassReads(Set.empty(), plan)#plan#passes;
        Assert.assertEq(expected = ("@missing:b" :: "a@history" :: Nil) :: Nil :: Nil, List.map(readsIn, passes))

    // 同じ名前の 2 回目は列から外れ、'@' を含む名前も外れる。
    @Test
    def testDuplicateAndReservedNamesAreDropped(): Unit \ Assert =
        let plan = Render.passPlan(pass("a", Nil) :: pass("a", Nil) :: pass("x@y", Nil) :: Nil);
        let resolved = Render.resolvePassReads(Set.empty(), plan);
        Assert.assertEq(expected = ("a" :: Nil,
                                    Render.PassPlanIssue.DuplicatePass("a") :: Render.PassPlanIssue.ReservedPassName("x@y") :: Nil),
                        (resolved#plan#passes |> List.map(p -> p#name), resolved#issues))

    // これまでに描いた古いターゲットはこのコマで宣言していなければ黒・普通のテクスチャ名はそのまま。
    @Test
    def testUndeclaredOldTargetIsMissingButPlainTextureIsKept(): Unit \ Assert =
        let plan = Render.passPlan(pass("a", readsFill("old") :: readsFill("tiles") :: Nil) :: Nil);
        let resolved = Render.resolvePassReads(Set#{"old"}, plan);
        Assert.assertEq(expected = (Render.PassPlanIssue.ReadsUndeclaredTarget("a", "old") :: Nil,
                                    ("@missing:old" :: "tiles" :: Nil) :: Nil),
                        (resolved#issues, List.map(readsIn, resolved#plan#passes)))

    // targets に書いて Pass に無い名前は知らせる（綴り違いで倍率が効いていないのに気づけるように）。
    @Test
    def testUnknownDescriptorIsReported(): Unit \ Assert =
        let plan = { targets = Map#{ "ghost" => { scale = 0.5 | RenderTarget.defaultDescriptor() } }
                     | Render.passPlan(pass("a", Nil) :: Nil) };
        Assert.assertEq(expected = Render.PassPlanIssue.UnknownDescriptor("ghost") :: Nil,
                        Render.resolvePassReads(Set.empty(), plan)#issues)

    // targets の scale が範囲（0 より大きく 1 以下）の外なら、Pass の名前と書いた値つきで知らせる（黙って 1 に直さない）。
    @Test
    def testScaleOutOfRangeIsReported(): Unit \ Assert =
        let plan = { targets = Map#{ "a" => { scale = 2.0 | RenderTarget.defaultDescriptor() } }
                     | Render.passPlan(pass("a", Nil) :: Nil) };
        Assert.assertEq(expected = Render.PassPlanIssue.ScaleOutOfRange("a", 2.0) :: Nil,
                        Render.resolvePassReads(Set.empty(), plan)#issues)

    // Window の作り方は passSpecsOf の target に届き、targetDescriptorOf で引ける（書かない名前は Design）。
    @Test
    def testWindowDescriptorReachesPassSpec(): Unit \ Assert =
        let plan = { targets = Map#{ "a" => { scale = 0.5 | RenderTarget.windowDescriptor() } }
                     | Render.passPlan(pass("a", Nil) :: pass("b", Nil) :: Nil) };
        let specs = Render.passSpecsOf(_ -> None, plan)#specs;
        Assert.assertEq(expected = ((RenderTarget.Basis.Window, 0.5) :: (RenderTarget.Basis.Design, 1.0) :: Nil, RenderTarget.Basis.Design),
                        (specs |> List.map(sp -> (sp#target#basis, sp#target#scale)), Render.targetDescriptorOf(plan, "b")#basis))

    // passSpecsOf は面を surfaces に・残りを drawables に分け、倍率を targets から読む（書かない名前は 1.0）。
    @Test
    def testPassSpecsOfSplitsSurfacesAndReadsScale(): Unit \ Assert =
        let plan = { targets = Map#{ "a" => { scale = 0.5 | RenderTarget.defaultDescriptor() } }
                     | Render.passPlan(pass("a", readsFill("tiles") :: { at = { x = 0.0, y = 0.0 },
                                                   item = RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 0.0, b = 0.0 }, 0) } :: Nil)
                                       :: pass("b", Nil) :: Nil) };
        let specs = Render.passSpecsOf(_ -> None, plan)#specs;
        Assert.assertEq(expected = (1, 1, 0.5) :: (0, 0, 1.0) :: Nil,
                        specs |> List.map(sp -> (List.length(sp#surfaces), List.length(sp#drawables), sp#target#scale)))

    /// GL の無い所で App.Internal.Paint.drawPassPlan を 1 回流す（描く命令は全部捨てる）。
    def drawPassPlanStubbed(known: Set[String], plan: Render.PassPlan): Set[String] =
        RenderTarget.runNoop(() -> run {
            App.Internal.Paint.drawPassPlan(_ -> (), { x = 8.0, y = 8.0 }, known, plan)
        } with handler Platform.Draw2d {
            def renderCommands(_sprites, _tileMaps, _polygons, _staticLayer, k) = k(())
            def drawSurface(_cmd, k) = k(())
        } with handler Platform.Draw3d {
            def drawScene3d(_cmd, k) = k(())
        } with handler Platform.GpuResources {
            def initTileBuffer(_instances, _k) = bug!("unused")
            def updateTileBuffer(_vaoId, _instances, _k) = bug!("unused")
            def ensureTexture(_name, _key, _w, _h, _argb, k) = k(())
            def ensureGlyphs(_textureName, _codepoints, k) = k(())
            def getFontAtlas(_name, _k) = bug!("unused")
            def getTextureInfo(_name, k) = k(None)
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
        })

    // 返す known は前の known にこのコマの Pass の名前を足した物（コマをまたいで減らない）。
    @Test
    def testDrawPassPlanGrowsKnownTargets(): Unit \ Assert =
        let plan = Render.passPlan(pass("a", Nil) :: pass("b", readsFill("a") :: Nil) :: Nil);
        Assert.assertEq(expected = Set#{"old", "a", "b"}, drawPassPlanStubbed(Set#{"old"}, plan))
}
