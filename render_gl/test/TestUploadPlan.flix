// WebGPU の 3 本の Stream（instance・頂点・values）を 1 つの pass ぶん送る時に、submit するか・送る位置・buffer を伸ばす大きさを決める所（planUpload）を固定する。
// Stream ごとに (GPU の buffer の bytes, 使った bytes, 送る bytes) を渡し、(submit するか, (送った後の GPU の buffer の bytes, 送る位置の bytes)) を読む。
// WhyNot: mod TestUploadPlan にしない — planUpload は WebGpuPaint の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderPaint.Internal.WebGpuPaint.TestUploadPlan {
    use RenderPaint.Internal.WebGpuPaint.planUpload

    /// 3 本とも空きに入れば submit せず、使った所の後ろへ送る（大きさはそのまま）。
    @Test
    def testAllFitSendAfterUsed(): Unit \ Assert =
        Assert.assertEq(expected = (false, (1000, 100), (2000, 300), (400, 40)),
                        planUpload((1000, 100, 200), (2000, 300, 500), (400, 40, 24)))

    /// 1 本（頂点）だけが空きに入らなくても submit し、3 本とも頭から送る。
    @Test
    def testOneOverflowSendsAllFromHead(): Unit \ Assert =
        Assert.assertEq(expected = (true, (1000, 0), (2000, 0), (400, 0)),
                        planUpload((1000, 100, 200), (2000, 1900, 500), (400, 40, 24)))

    /// 頭からでも入らない本は、要る大きさと倍の大きい方へ伸ばす（2000 → 4000・400 → 1000）。
    @Test
    def testTooLargeGrowsToNeedOrDouble(): Unit \ Assert =
        Assert.assertEq(expected = (true, (1000, 0), (4000, 0), (1000, 0)),
                        planUpload((1000, 0, 200), (2000, 0, 2500), (400, 0, 1000)))

    /// ちょうど入る（800 + 200 = 1000）時は submit しない。
    @Test
    def testExactFitDoesNotSubmit(): Unit \ Assert =
        let (submit, _, _, _) = planUpload((1000, 800, 200), (2000, 0, 0), (400, 0, 0));
        Assert.assertFalse(submit)

    /// ちょうど入る時は、使った所の後ろ（800）へ送り、大きさは 1000 のまま。
    @Test
    def testExactFitSendsAfterUsedWithSameSize(): Unit \ Assert =
        let (_, instances, _, _) = planUpload((1000, 800, 200), (2000, 0, 0), (400, 0, 0));
        Assert.assertEq(expected = (1000, 800), instances)

    /// 1 バイト溢れる（801 + 200 = 1001）時は submit する。
    @Test
    def testOneByteOverSubmits(): Unit \ Assert =
        let (submit, _, _, _) = planUpload((1000, 801, 200), (2000, 0, 0), (400, 0, 0));
        Assert.assertTrue(submit)
}
