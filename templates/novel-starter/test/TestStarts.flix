// 始まりの登録簿（Starts.all を App.startOrBug / App.buildStart で引く）と、シナリオ assets/talk/novel.yarn との橋渡し。
// startOrBug は新しく作った初期の World（assets の Doc とシナリオを読み直した物）から組む。
mod TestStarts {
    use fge::{App, Vec2}

    def app(): App.App[World.World, {}] \ Fs.FileRead = Game.app(Controls.loadDocs(), NovelKit.spawnAssets())

    /// choice の既定: コードが最初に開くノードを読み終えて、選択肢が開いている（物語の中）。
    @Test
    def testChoiceOpensTheFirstNodesQuestion(): Unit \ Assert + Fs.FileRead =
        let w = App.startOrBug(app(), "choice", Map.empty());
        Assert.assertEq(expected = (World.Phase.Story, Talk.nodeName(Talk.Node.Arrival), true),
            (w#phase, World.talkNodeOf(w), NovelKit.isAsking(w#kit)))

    /// talk node=clock: そのノードの 1 行目を読んでいる（選択肢はまだ開いていない）。
    @Test
    def testTalkStartsAtTheFirstLine(): Unit \ Assert + Fs.FileRead =
        let w = App.startOrBug(app(), "talk", Map#{"node" => "clock"});
        Assert.assertEq(expected = ("clock", false), (World.talkNodeOf(w), NovelKit.isAsking(w#kit)))

    /// シナリオに無いノードは組まずに、近い名前の案つきで断る。
    @Test
    def testUnknownNodeSuggestsANearName(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("始まり 'talk': ノード 'clok' はシナリオに無い（もしかして: clock）"),
            App.buildStart(app(), Vec2.zero(), "talk", Map#{"node" => "clok"}) |> Result.map(World.talkNodeOf))
}
