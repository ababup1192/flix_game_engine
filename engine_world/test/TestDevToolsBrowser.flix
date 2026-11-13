// ブラウザ版の組（App.DevTools.startOfQuery）が、URL のクエリを始まりの名前と引数に変えること。
mod App.DevTools.TestBrowser {

    @Test
    def testFirstKeyNamesTheStartAndEveryPairIsAnArg(): Unit \ Assert =
        let start = App.DevTools.startOfQuery(("talk", "Lair") :: ("line", "46") :: Nil);
        Assert.assertEq(expected = Some(("talk", Map#{"talk" => "Lair", "line" => "46"})), start)

    @Test
    def testPageKeysAreLeftOut(): Unit \ Assert =
        let start = App.DevTools.startOfQuery(("input", "touch") :: ("talk", "Lair") :: ("size", "small") :: ("line", "46") :: Nil);
        Assert.assertEq(expected = Some(("talk", Map#{"talk" => "Lair", "line" => "46"})), start)

    @Test
    def testEmptyQueryHasNoStart(): Unit \ Assert =
        Assert.assertEq(expected = None, App.DevTools.startOfQuery(Nil))

    @Test
    def testOnlyPageKeysHaveNoStart(): Unit \ Assert =
        let start = App.DevTools.startOfQuery(("glcheck", "1") :: ("orientation", "portrait") :: ("capture", "30") :: Nil);
        Assert.assertEq(expected = None, start)

    @Test
    def testKeyWithoutNameIsLeftOut(): Unit \ Assert =
        let start = App.DevTools.startOfQuery(("", "x") :: ("talk", "Lair") :: Nil);
        Assert.assertEq(expected = Some(("talk", Map#{"talk" => "Lair"})), start)

    @Test
    def testValuesKeepSpacesAndNewlines(): Unit \ Assert =
        let start = App.DevTools.startOfQuery(("talk", "Lair") :: ("edit.38", "おや、\nそう だね") :: Nil);
        Assert.assertEq(expected = Some(("talk", Map#{"talk" => "Lair", "edit.38" => "おや、\nそう だね"})), start)

    @Test
    def testLaterDuplicateKeyWins(): Unit \ Assert =
        let start = App.DevTools.startOfQuery(("talk", "Lair") :: ("line", "1") :: ("line", "46") :: Nil);
        Assert.assertEq(expected = Some(("talk", Map#{"talk" => "Lair", "line" => "46"})), start)
}
