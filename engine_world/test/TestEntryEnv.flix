// TestEntryEnv — 入口の頭で読んだ env の表を引数で受ける口（Flow.Cli.getEnvOr・RemoteDebug.portToOpenOf・
// App.debugOf・Flow.Record.pathOf）が、プロセスの env を読んでいた口と同じ値を返すこと。

mod TestEntryEnv {

    /// 無い鍵は既定値。
    @Test
    def testGetEnvOrMissingIsFallback(): Unit \ Assert =
        Assert.assertEq(expected = "e2e/vocab.json", Flow.Cli.getEnvOr(Map.empty(), "FLOW_VOCAB", "e2e/vocab.json"))

    /// 空の値も既定値。
    @Test
    def testGetEnvOrEmptyIsFallback(): Unit \ Assert =
        Assert.assertEq(expected = "run", Flow.Cli.getEnvOr(Map#{ "FLOW_MODE" => "" }, "FLOW_MODE", "run"))

    /// 値があればその値。
    @Test
    def testGetEnvOrPresentIsValue(): Unit \ Assert =
        Assert.assertEq(expected = "check", Flow.Cli.getEnvOr(Map#{ "FLOW_MODE" => "check" }, "FLOW_MODE", "run"))

    /// DEBUG_HTTP_PORT が無ければ 0（OS に選ばせる）・off なら開かない・数ならその番号。
    @Test
    def testPortToOpenOfThreeCases(): Unit \ Assert =
        Assert.assertEq(expected = (Some(0), None, Some(7777)),
            (App.RemoteDebug.portToOpenOf(Map.empty()),
             App.RemoteDebug.portToOpenOf(Map#{ "DEBUG_HTTP_PORT" => "off" }),
             App.RemoteDebug.portToOpenOf(Map#{ "DEBUG_HTTP_PORT" => "7777" })))

    /// DEBUG は空でない値のときだけ真。
    @Test
    def testDebugOfNeedsNonEmptyValue(): Unit \ Assert =
        Assert.assertEq(expected = (false, false, true),
            (App.debugOf(Map.empty()), App.debugOf(Map#{ "DEBUG" => "" }), App.debugOf(Map#{ "DEBUG" => "1" })))

    /// FLOW_RECORD: 無し = 既定の置き場・"0" = 書かない・それ以外 = そのパス。
    @Test
    def testRecordPathOfThreeCases(): Unit \ Assert =
        Assert.assertEq(expected = (Some("debug/flow-record/latest.flow"), None, Some("x.flow")),
            (Flow.Record.pathOf(Map.empty()),
             Flow.Record.pathOf(Map#{ "FLOW_RECORD" => "0" }),
             Flow.Record.pathOf(Map#{ "FLOW_RECORD" => "x.flow" })))
}
