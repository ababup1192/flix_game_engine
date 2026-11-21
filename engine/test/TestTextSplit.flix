// Tests for TextSplit — 正規表現を使わない区切りが、Flix 標準の String.split・String.lines と同じ答えを返す

mod TestTextSplit {

    def splitInputs(): List[String] =
        "" :: "," :: ",," :: "a" :: "a," :: ",a" :: "a,b" :: "a,,b" :: "a,b,," :: ",a,,b,," :: "a b" :: Nil

    def lineInputs(): List[String] =
        "" :: "a" :: "a\n" :: "a\nb" :: "a\r\nb" :: "a\rb" :: "\n" :: "\r\n" :: "\n\na" :: "a\n\n" ::
        "a\n\nb" :: "a\r\n\r\n" :: "a\n\rb" :: "\r\r\n" :: "  x \n y" :: Nil

    @Test
    def testSplitMatchesStandardSplitForOneCharSeparator(): Unit \ Assert =
        Assert.assertEq(
            expected = splitInputs() |> List.map(s -> String.split(regex = ",", s)),
            splitInputs() |> List.map(s -> TextSplit.split(",", s)))

    @Test
    def testSplitMatchesStandardSplitForNewline(): Unit \ Assert =
        Assert.assertEq(
            expected = lineInputs() |> List.map(s -> String.split(regex = "\n", s)),
            lineInputs() |> List.map(s -> TextSplit.split("\n", s)))

    @Test
    def testSplitMatchesStandardSplitForSeveralCharSeparator(): Unit \ Assert =
        let inputs = "" :: "::" :: "a::b" :: "a::b::" :: "::a" :: "a:b" :: "a:::b" :: Nil;
        Assert.assertEq(
            expected = inputs |> List.map(s -> String.split(regex = "::", s)),
            inputs |> List.map(s -> TextSplit.split("::", s)))

    @Test
    def testSplitTakesSeparatorAsPlainText(): Unit \ Assert =
        Assert.assertEq(expected = "a" :: "b" :: Nil, TextSplit.split(".", "a.b"))

    @Test
    def testSplitWithEmptySeparatorReturnsWhole(): Unit \ Assert =
        Assert.assertEq(expected = "abc" :: Nil, TextSplit.split("", "abc"))

    @Test
    def testLinesMatchesStandardLines(): Unit \ Assert =
        Assert.assertEq(
            expected = lineInputs() |> List.map(String.lines),
            lineInputs() |> List.map(TextSplit.lines))
}
