// TestAppSustain — 鳴り続ける音（App.withSustained）の仕分けを固定する。
// 確かめるのは規約だけ: 新しく出た宣言だけ鳴らし始める・続いている宣言は鳴らし直さない・
// 消えた宣言は止める・同じ名前の重複は 1 本にまとめる。
mod TestAppSustain {

    def hum(name: String, volume: Float64, pitch: Float64): App.Sustain =
        { name = name, volume = volume, pitch = pitch }

    def names(items: List[App.Sustain]): List[String] =
        List.map(s -> s#name, items)

    /// 何も鳴っていない所へ宣言が現れたら、それは鳴らし始める側に入る。
    @Test
    def testNewDeclarationStarts(): Unit \ Assert =
        let ops = App.sustainOps(Nil, hum("engine", 0.5, 1.0) :: Nil);
        Assert.assertEq(expected = ("engine" :: Nil, Nil, Nil),
            (names(ops#start), names(ops#keep), ops#stop))

    /// すでに鳴っている音は「続ける」側へ入る（鳴らし直さないので音が途切れない）。
    @Test
    def testLivingDeclarationIsKeptNotRestarted(): Unit \ Assert =
        let ops = App.sustainOps("engine" :: Nil, hum("engine", 0.5, 1.4) :: Nil);
        Assert.assertEq(expected = (Nil, "engine" :: Nil, Nil),
            (names(ops#start), names(ops#keep), ops#stop))

    /// 続ける側にも毎フレームの音量と高さが載る（速度で唸りが変わる音のため）。
    @Test
    def testKeptDeclarationCarriesVolumeAndPitch(): Unit \ Assert =
        let ops = App.sustainOps("engine" :: Nil, hum("engine", 0.25, 1.7) :: Nil);
        let got = List.head(ops#keep) |> Option.map(s -> (s#volume, s#pitch));
        Assert.assertEq(expected = Some((0.25, 1.7)), got)

    /// 宣言が消えた音は止める（宣言が続く間だけ鳴る、が規約）。
    @Test
    def testDroppedDeclarationStops(): Unit \ Assert =
        let ops = App.sustainOps("engine" :: "wind" :: Nil, hum("engine", 0.5, 1.0) :: Nil);
        Assert.assertEq(expected = (Nil, "engine" :: Nil, "wind" :: Nil),
            (names(ops#start), names(ops#keep), ops#stop))

    /// 何も宣言しなければ全部止まる。
    @Test
    def testEmptyDeclarationStopsEverything(): Unit \ Assert =
        let ops = App.sustainOps("engine" :: "wind" :: Nil, Nil);
        Assert.assertEq(expected = ("engine" :: "wind" :: Nil, 0, 0),
            (ops#stop, List.length(ops#start), List.length(ops#keep)))

    /// 同じ名前を 2 回宣言しても 1 本にまとめる（先勝ち）。二重に鳴らすと同じ音源を
    /// 頭から鳴らし直して途切れる。
    @Test
    def testDuplicateNamesFoldToTheFirst(): Unit \ Assert =
        let ops = App.sustainOps(Nil,
            hum("wind", 0.2, 1.0) :: hum("wind", 0.9, 2.0) :: Nil);
        let got = List.map(s -> (s#name, s#volume), ops#start);
        Assert.assertEq(expected = ("wind", 0.2) :: Nil, got)

    /// 止める側は名前の重複もまとめる（同じ音を 2 回止めに行かない）。
    @Test
    def testStopListHasNoDuplicates(): Unit \ Assert =
        let ops = App.sustainOps("wind" :: "wind" :: Nil, Nil);
        Assert.assertEq(expected = "wind" :: Nil, ops#stop)

    /// 鳴らし始めた音と続けた音の合計が「次のフレームで鳴っている名前」になる
    /// （この列がそのまま次の prev になるので、止め忘れ・鳴らし直しが起きない）。
    @Test
    def testStartAndKeepCoverEveryDeclaredName(): Unit \ Assert =
        let ops = App.sustainOps("engine" :: Nil,
            hum("engine", 0.5, 1.0) :: hum("wind", 0.3, 1.0) :: Nil);
        Assert.assertEq(expected = "wind" :: "engine" :: Nil,
            List.append(names(ops#start), names(ops#keep)))

    /// 鳴り続ける音として使った名前を、止めた後に一発で鳴らすときはループを外す
    /// （外さないと短い効果音がループし続ける）。
    @Test
    def testOneShotOfFormerHumIsUnlooped(): Unit \ Assert =
        Assert.assertEq(expected = "crtOff" :: Nil, App.unloopedOneShots("crtOff" :: Nil, Nil))

    /// いま鳴り続けている名前はループを外さない（鳴り続ける側が切れないように）。
    @Test
    def testLivingHumKeepsItsLoop(): Unit \ Assert =
        Assert.assertEq(expected = "hit" :: Nil,
            App.unloopedOneShots("hit" :: "engine" :: Nil, "engine" :: Nil))
}
