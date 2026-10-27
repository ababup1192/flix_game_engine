// YarnRunner のルビ（マークアップ）と読んでいる所のブックマーク（セーブ・ロード）のテスト。
// シナリオは testdata/yarn/runner/novel.yarn（Go の build が書いた novel.yarn.json を読む）。
// ルビの範囲が {式} を値にした後の字で数えられること・ブックマークから戻すと同じ台詞と同じ変数になること
// （選んだ枝の中の <<set>> も 1 回だけ通る）・JSON を行き来しても同じブックマークに戻ることを見る。

mod TestYarnNovel {

    def program(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), "../../testdata/yarn/runner/novel.yarn.json")

    def at(seconds: Float64): Clock.Time[Clock.Real] = Clock.after(seconds, Clock.zero())

    def shownLine(runner: YarnRunner.Runner[Clock.Real]): Option[Yarn.Line] = match YarnRunner.shownOf(runner) {
        case YarnRunner.Shown.Line(line) => Some(line)
        case _                           => None
    }

    def shownText(runner: YarnRunner.Runner[Clock.Real]): String =
        shownLine(runner) |> Option.map(line -> line#text) |> Option.getWithDefault("")

    def ruby(line: Option[Yarn.Line]): List[(String, Int32, Int32)] =
        line |> Option.map(Yarn.markupOf) |> Option.getWithDefault(Nil)
             |> List.map(markup -> (markup#value, markup#start, markup#length))

    def advance(runner: YarnRunner.Runner[Clock.Real]): YarnRunner.Runner[Clock.Real] =
        fst(YarnRunner.step(YarnRunner.Action.Advance, at(0.0), runner))

    def pick(i: Int32, runner: YarnRunner.Runner[Clock.Real]): YarnRunner.Runner[Clock.Real] =
        fst(YarnRunner.step(YarnRunner.Action.Choose(i), at(0.0), runner))

    def number(name: String, runner: YarnRunner.Runner[Clock.Real]): Option[Yarn.Value] = YarnRunner.valueOf(name, runner)

    /// 台詞の字には [ ] が入らず、ルビは親字の位置と長さで読める。
    @Test
    def testRubyIsReadAsARangeOfThePlainText(): Unit \ Assert + Fs.FileRead =
        let first = fst(YarnRunner.start(program(), "Field", at(0.0)));
        let second = advance(first);
        Assert.assertEq(expected = ("蜩が2匹鳴く", List#{("ひぐらし", 0, 1)}, "川と畑", List#{("かわ", 0, 1), ("はたけ", 2, 1)}),
                        (shownText(first), ruby(shownLine(first)), shownText(second), ruby(shownLine(second))))

    /// 選択肢の字もルビを抜いた字で並ぶ。
    @Test
    def testChoicesHaveThePlainText(): Unit \ Assert + Fs.FileRead =
        let asking = fst(YarnRunner.start(program(), "Field", at(0.0))) |> advance;
        let texts = match YarnRunner.shownOf(asking) {
            case YarnRunner.Shown.Line(_) => YarnRunner.step(YarnRunner.Action.Advance, at(0.0), asking) |> fst |> YarnRunner.shownOf |> Some
            case _                        => None
        };
        let options = match texts {
            case Some(YarnRunner.Shown.Choices(os)) => os |> List.map(o -> o#line#text)
            case _                                  => Nil
        };
        Assert.assertEq(expected = List#{"川へ行く", "畑へ行く"}, options)

    /// 枝の中の台詞でブックマークを取って戻すと、同じ台詞・同じ変数（枝の <<set>> を 1 回だけ通った値）になる。
    @Test
    def testResumeInsideAChoiceRestoresTheLineAndValues(): Unit \ Assert + Fs.FileRead =
        let inBranch = fst(YarnRunner.start(program(), "Field", at(0.0))) |> advance |> advance |> pick(0);
        let restored = YarnRunner.bookmarkOf(inBranch) |> Option.map(mark -> fst(YarnRunner.resume(program(), mark, at(0.0))));
        Assert.assertEq(expected = Some(("水の音", Some(Yarn.Value.Number(1.0)), Some(Yarn.Value.Number(12.0)))),
                        restored |> Option.map(r -> (shownText(r), number("$kind", r), number("$n", r))))

    /// <<wait>> を越えた所のブックマークは、待たずに同じ台詞へ戻る。
    @Test
    def testResumeSkipsAWait(): Unit \ Assert + Fs.FileRead =
        let waiting = fst(YarnRunner.start(program(), "Field", at(0.0))) |> advance |> advance |> pick(1) |> advance;
        let after = fst(YarnRunner.step(YarnRunner.Action.Tick, at(5.0), waiting));
        let restored = YarnRunner.bookmarkOf(after) |> Option.map(mark -> fst(YarnRunner.resume(program(), mark, at(0.0))));
        Assert.assertEq(expected = Some("数は2"), restored |> Option.map(shownText))

    /// jump の先では、ブックマークはその先のノードに入った時の値から数える。
    @Test
    def testBookmarkStartsOverAfterAJump(): Unit \ Assert + Fs.FileRead =
        let night = fst(YarnRunner.start(program(), "Field", at(0.0))) |> advance |> advance |> pick(1) |> advance;
        let second = fst(YarnRunner.step(YarnRunner.Action.Tick, at(5.0), night)) |> advance |> advance;
        let mark = YarnRunner.bookmarkOf(second);
        Assert.assertEq(expected = (Some("Night"), Some(1), Some("夜の二行目"), Some(Yarn.Value.Number(102.0))),
                        (mark |> Option.map(m -> m#node), mark |> Option.map(m -> List.length(m#steps)),
                         mark |> Option.map(m -> shownText(fst(YarnRunner.resume(program(), m, at(0.0))))),
                         mark |> Option.flatMap(m -> number("$n", fst(YarnRunner.resume(program(), m, at(0.0)))))))

    /// ブックマークは JSON を行き来しても同じ所へ戻る。
    @Test
    def testBookmarkJsonRoundTrips(): Unit \ Assert + Fs.FileRead =
        let inBranch = fst(YarnRunner.start(program(), "Field", at(0.0))) |> advance |> advance |> pick(0);
        let back = YarnRunner.bookmarkOf(inBranch) |> Option.flatMap(mark -> YarnRunner.bookmarkFromJson(YarnRunner.bookmarkToJson(mark)));
        Assert.assertEq(expected = Some("水の音"),
                        back |> Option.map(mark -> shownText(fst(YarnRunner.resume(program(), mark, at(0.0))))))

    /// 閉じた実行器にはブックマークが無い。
    @Test
    def testClosedRunnerHasNoBookmark(): Unit \ Assert =
        let closed: YarnRunner.Runner[Clock.Real] = YarnRunner.closed();
        Assert.assertEq(expected = true, Option.isEmpty(YarnRunner.bookmarkOf(closed)))
}
