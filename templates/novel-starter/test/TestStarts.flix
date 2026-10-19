// 始まりの登録簿（Starts.all を App.startOrBug / App.buildStart で引く）と、台本 novel.story.json との橋渡し。
// startOrBug は新しく作った初期の World（assets の Doc を読み直した物）から組む。
mod TestStarts {
    use fge::{App, Vec2}

    def app(): App.App[World.World, {}] \ Fs.FileRead = Game.app(Controls.loadDocs(), NovelKit.spawnAssets())

    /// choice の既定: 台本の start の節を読み終えて、選択肢が開いている（物語の中）。
    @Test
    def testChoiceOpensTheStartSectionsQuestion(): Unit \ Assert + Fs.FileRead =
        let w = App.startOrBug(app(), "choice", Map.empty());
        Assert.assertEq(expected = (World.Phase.Story, StoryDoc.rec(w#story)#start, true),
            (w#phase, w#section, NovelKit.isAsking(w#kit)))

    /// section id=clock: その節の 1 行目を読んでいる（選択肢はまだ開いていない）。
    @Test
    def testSectionStartsAtTheFirstLine(): Unit \ Assert + Fs.FileRead =
        let w = App.startOrBug(app(), "section", Map#{"id" => "clock"});
        Assert.assertEq(expected = ("clock", 0, false), (w#section, w#idx, NovelKit.isAsking(w#kit)))

    /// 台本に無い節は組まずに、近い名前の案つきで断る。
    @Test
    def testUnknownSectionSuggestsANearName(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("始まり 'section': 節 'clok' は台本に無い（もしかして: clock）"),
            App.buildStart(app(), Vec2.zero(), "section", Map#{"id" => "clok"}) |> Result.map(w -> w#section))
}
