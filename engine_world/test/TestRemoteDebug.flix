// TestRemoteDebug — HTTP リモートデバッグ口の純粋な芯を具体値で固定する:
// リクエスト分解（1 行目 = メソッドとパス、2 行目以降 = 台本）、クエリの解釈
// （view / rect / until / max / trace / dt）、台本 DSL の 1 フレーム 1 コマ展開
// （press = 押す 1 コマ + 離す 1 コマ、hold = 同じ集合を N 個）、応答ブロックの整形。

mod TestRemoteDebug {

    // ========================================================================
    // parseRequest: 生文字列の分解
    // ========================================================================

    // メソッド・パス・クエリ・ボディが 4 つに割れる。ボディの複数行は保たれる。
    @Test
    def testParseRequestSplitsAllParts(): Unit \ Assert =
        let request = App.RemoteDebug.parseRequest("POST /step?view=status&max=90\npress Z\nidle 5");
        Assert.assertEq(
            expected = ("POST", "/step", Some("status"), Some("90"), "press Z\nidle 5"),
            (request#method, request#path,
             Map.get("view", request#params), Map.get("max", request#params), request#body))

    // クエリ無し・ボディ無し（GET /help のような形）でも安全に空へ落ちる。
    @Test
    def testParseRequestBareGet(): Unit \ Assert =
        let request = App.RemoteDebug.parseRequest("GET /help\n");
        Assert.assertEq(
            expected = ("GET", "/help", 0, ""),
            (request#method, request#path, Map.size(request#params), request#body))

    // クエリ値は最小限の URL デコード（+ と %20 → 空白）だけを行う。
    @Test
    def testParseRequestDecodesSpacesInQueryValues(): Unit \ Assert =
        let request = App.RemoteDebug.parseRequest("POST /save?name=girl+in%20rain\n");
        Assert.assertEq(
            expected = Some("girl in rain"),
            Map.get("name", request#params))

    // ========================================================================
    // findRoute: 任意ルート（App.onRequest）の照合
    // ========================================================================

    // クエリを外した後のパスの完全一致で照合し、同じパスは先に登録した方が勝つ。
    // 前方一致ではない（"/save2" は "/save" に食われない）し、未登録パスは None。
    @Test
    def testFindRouteMatchesExactPathFirstWins(): Unit \ Assert =
        let routes = ("/save", 1) :: ("/save2", 2) :: ("/save", 3) :: Nil;
        Assert.assertEq(
            expected = (Some(1), Some(2), None),
            (App.RemoteDebug.findRoute("/save", routes),
             App.RemoteDebug.findRoute("/save2", routes),
             App.RemoteDebug.findRoute("/nope", routes)))

    // ========================================================================
    // parseParams: クエリの解釈
    // ========================================================================

    /// Rect2 は record で ToString が無いので、比較用に (x, y, w, h) のタプルへ射影する。
    def rectTuple(rect: Rect2.Rect2): (Float64, Float64, Float64, Float64) =
        (rect#position#x, rect#position#y, rect#size#x, rect#size#y)

    // 何も指定しなければ既定値（status / 全画面 / 止めない / 1200 コマ / trace 無し / 1/60 秒）。
    @Test
    def testParseParamsDefaults(): Unit \ Assert =
        let actual = App.RemoteDebug.parseParams(Map.empty())
            |> Result.map(p -> (p#view, p#rect |> Option.map(rectTuple),
                                p#stopWhen, p#maxFrames, p#traceEvery, p#dtSeconds));
        Assert.assertEq(
            expected = Ok((App.RemoteDebug.View.Status, None, App.RemoteDebug.Until.Always, 1200, None, 1.0 / 60.0)),
            actual)

    // rect は "x,y,w,h" の 4 値をデザイン座標の矩形として読む。
    @Test
    def testParseParamsRect(): Unit \ Assert =
        let actual = App.RemoteDebug.parseParams(Map#{"rect" => "96.0,40.0,80.0,30.0"})
            |> Result.map(p -> p#rect |> Option.map(rectTuple));
        Assert.assertEq(
            expected = Ok(Some((96.0, 40.0, 80.0, 30.0))),
            actual)

    // until は音イベント名の集合（sfx:break,miss）へ展開される。
    @Test
    def testParseParamsUntilSfxNames(): Unit \ Assert =
        let actual = App.RemoteDebug.parseParams(Map#{"until" => "sfx:break,miss"})
            |> Result.map(p -> p#stopWhen);
        Assert.assertEq(
            expected = Ok(App.RemoteDebug.Until.SfxNamed(Set#{"break", "miss"})),
            actual)

    // until=quiet:N は「N フレーム連続無音で停止」。dt はミリ秒指定を秒へ変換する。
    @Test
    def testParseParamsQuietAndDt(): Unit \ Assert =
        let actual = App.RemoteDebug.parseParams(Map#{"until" => "quiet:30", "dt" => "4.0"})
            |> Result.map(p -> (p#stopWhen, p#dtSeconds));
        Assert.assertEq(
            expected = Ok((App.RemoteDebug.Until.Quiet(30), 0.004)),
            actual)

    // 未知の view 名は理由つきの Err（応答へそのまま載せられる文言）で弾く。
    @Test
    def testParseParamsRejectsUnknownView(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            App.RemoteDebug.parseParams(Map#{"view" => "verbose"}) |> Result.isErr)

    // max は 1..3600 の範囲外を弾く（1 リクエスト暴走の安全弁）。
    @Test
    def testParseParamsRejectsHugeMax(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            App.RemoteDebug.parseParams(Map#{"max" => "9999"}) |> Result.isErr)

    // ========================================================================
    // 応答の整形
    // ========================================================================

    // ヘッダ 1 行に「何コマ進み・現在フレーム・なぜ止まったか」が全部載る。
    @Test
    def testStepHeaderFormat(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok stepped=40 frame=1307 mode=halted stopped=until:sfx\n",
            App.RemoteDebug.stepHeader({ stepped = 40, frame = 1307i64, stoppedBy = "until:sfx", quit = false }))

    // 音イベントは「f=フレーム番号 sfx=音名」で時系列に並ぶ。無ければブロックごと消える。
    @Test
    def testEventsBlockFormat(): Unit \ Assert =
        Assert.assertEq(
            expected = ("[events]\nf=1246 sfx=paddle\nf=1307 sfx=wall\n", ""),
            (App.RemoteDebug.eventsBlock((1246i64, "paddle") :: (1307i64, "wall") :: Nil),
             App.RemoteDebug.eventsBlock(Nil)))

    // scene は矩形と件数のヘッダ + z 昇順の 1 行ずつ。座標は小数第 1 位へ丸める。
    @Test
    def testSceneBlockSortsAndRounds(): Unit \ Assert =
        let rect = { position = { x = 0.0, y = 0.0 }, size = { x = 100.0, y = 50.0 } };
        let hits =
            { kind = "sprite", name = "ball", position = { x = 148.94, y = 44.27 }, zIndex = 30,
              aabb = { position = { x = 145.9, y = 41.2 }, size = { x = 6.0, y = 6.0 } } }
            :: { kind = "box", name = "", position = { x = 10.0, y = 20.0 }, zIndex = 5,
                 aabb = { position = { x = 10.0, y = 20.0 }, size = { x = 32.0, y = 12.0 } } }
            :: Nil;
        Assert.assertEq(
            expected = "[scene] rect=(0.0,0.0,100.0,50.0) items=2\n"
                     + "box pos=(10.0,20.0) size=(32.0,12.0) z=5\n"
                     + "sprite ball pos=(148.9,44.3) size=(6.0,6.0) z=30",
            App.RemoteDebug.sceneBlock(rect, hits))

    // /render の成功応答: 1 行目に枚数と所要 ms、[rendered] ブロックに描き出した順のパス 1 行 1 枚。
    @Test
    def testRenderDoneTextListsPathsInOrder(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok rendered=2 ms=845\n[rendered]\ngallery/title.png\ngallery/ending.png\n",
            App.RemoteDebug.renderDoneText(845i64, "gallery/title.png" :: "gallery/ending.png" :: Nil))

    // 1 回の描き出しの応答は、1 行目の末尾にその回の番号が付き、パスの並びはそのまま。
    @Test
    def testRenderJobDoneTextAppendsJobToFirstLine(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok rendered=1 ms=12 job=3\n[rendered]\ngallery/title.png\n",
            App.RemoteDebug.renderJobDoneText(3i64, 12i64, "gallery/title.png" :: Nil))

    // 描き出しが落ちた回は error 応答になり、理由の改行は 1 行に潰れる（Studio が 1 行目で読めるように）。
    @Test
    def testRenderFailedTextIsOneErrorLine(): Unit \ Assert =
        Assert.assertEq(
            expected = "error: render failed job=4: boom at x\n",
            App.RemoteDebug.renderFailedText(4i64, "boom\nat x"))

    // 描いている間に何件来ても、次の 1 回は最後に頼まれた番号まで（まとめて 1 回で描く）。
    @Test
    def testNextRenderTargetFoldsPendingRequests(): Unit \ Assert =
        Assert.assertEq(expected = Some(7i64), App.RemoteDebug.nextRenderTarget(7i64, 3i64))

    // 頼まれた番号まで描き終えていれば、起こされても描かない（余った起こしの印で回り続けない）。
    @Test
    def testNextRenderTargetIsNoneWhenCaughtUp(): Unit \ Assert =
        Assert.assertEq(expected = None, App.RemoteDebug.nextRenderTarget(7i64, 7i64))

    // 後の番号の回でまとめて描き終えていれば、前の番号の依頼も済んだ扱い。
    @Test
    def testRenderSettledByLaterJob(): Unit \ Assert =
        Assert.assertEq(expected = true, App.RemoteDebug.isRenderSettled(5i64, 7i64))

    // 走っている途中の回が終わっただけでは、その後に頼んだ番号は済んでいない（描きかけを完了と言わない）。
    @Test
    def testRenderNotSettledByEarlierJob(): Unit \ Assert =
        Assert.assertEq(expected = false, App.RemoteDebug.isRenderSettled(8i64, 7i64))

    // まだ 1 回も描き終えていない間の状態は、番号の行だけ。
    @Test
    def testRenderStatusTextBeforeFirstJob(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok render requested=1 done=0 running=1\n",
            App.RemoteDebug.renderStatusText(1i64, 0i64, 1i64, ""))

    // 描き終えた回があれば、[last] にその回の応答をそのまま載せる。
    @Test
    def testRenderStatusTextCarriesLastResult(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok render requested=2 done=2 running=0\n[last]\nok rendered=0 ms=5 job=2\n",
            App.RemoteDebug.renderStatusText(2i64, 2i64, 0i64, "ok rendered=0 ms=5 job=2\n"))

    // すぐ返すのは async=1 のときだけ（クエリ無しは古い Studio のために待つ）。
    @Test
    def testWantsAsyncRenderOnlyWithAsyncOne(): Unit \ Assert =
        Assert.assertEq(expected = (true, false),
            (App.RemoteDebug.wantsAsyncRender(Map#{"async" => "1"}), App.RemoteDebug.wantsAsyncRender(Map.empty())))

    // 描き終わらなかったときの文面は、古い Studio が「描いている途中」と読む 1 行目のまま。
    @Test
    def testBusyTextKeepsOldStudioPrefix(): Unit \ Assert =
        Assert.assertEq(expected = true,
            String.startsWith(prefix = "error: game loop did not answer", App.RemoteDebug.busyText()))

    // 描き出しの実体が未登録なら error 応答（Studio はこの 1 行目を見て自前の描き出しへフォールバック）。
    @Test
    def testRenderUnsupportedTextIsError(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            String.startsWith(prefix = "error:", App.RemoteDebug.renderUnsupportedText()))

    // 依頼番号の付け外し: 本文のタブや改行はそのまま戻る（依頼と答えを番号で対にする）。
    @Test
    def testTaggedRoundTripKeepsBody(): Unit \ Assert =
        Assert.assertEq(expected = Some((42i64, "POST /step\nidle 1\tx")),
            App.RemoteDebug.untagged(App.RemoteDebug.tagged(42i64, "POST /step\nidle 1\tx")))

    // 番号の無い形は番号付きとして読まない（取り違えた答えを渡さない）。
    @Test
    def testUntaggedRejectsMissingId(): Unit \ Assert =
        Assert.assertEq(expected = None, App.RemoteDebug.untagged("ok rendered=3\tx"))

    // 書き置き（~/.flix_ge_studio/games.json）: 同じ dir の古い行は上書きし、閉じる時は自分の pid の行だけ消す。
    @Test
    def testGameRegistryReplacesSameDirAndRemovesOnlyOwnPid(): Unit \ Assert =
        let before = App.GameRegistry.textOf(
            { dir = "/g", pid = "1", port = "100" } :: { dir = "/h", pid = "2", port = "200" } :: Nil);
        let added = App.GameRegistry.withEntry({ dir = "/g", pid = "3", port = "300" }, App.GameRegistry.entriesOf(before));
        let removedOld = App.GameRegistry.withoutEntry("/g", "1", added);
        Assert.assertEq(
            expected = (List#{"/h:200", "/g:300"}, List#{"/h:200", "/g:300"}),
            (added |> List.map(e -> "${e#dir}:${e#port}"), removedOld |> List.map(e -> "${e#dir}:${e#port}")))

    // 壊れた書き置きは空として読む（ゲームは止めない）。
    @Test
    def testGameRegistryBrokenTextIsEmpty(): Unit \ Assert =
        Assert.assertEq(expected = 0, List.length(App.GameRegistry.entriesOf("{ broken")))

    // view=shot は App.onShotRequest を繋いでいなければ [shot] の下に error 行（Studio はそれを理由に出す）。
    @Test
    def testShotBlockWithoutWiringIsError(): Unit \ Assert + IO =
        let app = App.game({ init = 0, update = (_, w) -> w, view = (_, _) -> Nil, reloads = Nil });
        Assert.assertEq(expected = "[shot]\nerror: shot not supported (game does not wire App.onShotRequest)\n",
                        App.RemoteDebug.shotBlock(app, 0))

    // view=shot の答えは /render と同じ ok png=<パス>。
    @Test
    def testShotBlockAnswersThePath(): Unit \ Assert + IO =
        let app = App.game({ init = 7, update = (_, w) -> w, view = (_, _) -> Nil, reloads = Nil })
            |> App.onShotRequest(w -> checked_ecast("debug/shot/${Int32.toString(w)}.png"));
        Assert.assertEq(expected = "[shot]\nok png=debug/shot/7.png\n", App.RemoteDebug.shotBlock(app, 7))

    /// 1 枚撮り（view=shot）の要求は、橋が主の糸の答えを 60 秒待つ。
    @Test
    def testAnswerWaitIsLongForShot(): Unit \ Assert =
        Assert.assertEq(expected = 60i64, App.RemoteDebug.answerWaitSecs(Map#{ "view" => "shot" }))

    /// それ以外の要求は 10 秒のまま（主の糸が固まったら 10 秒で気づく）。
    @Test
    def testAnswerWaitStaysShortForStatus(): Unit \ Assert =
        Assert.assertEq(expected = 10i64, App.RemoteDebug.answerWaitSecs(Map#{ "view" => "status" }))

    /// wait=<秒> があれば、それを使う。
    @Test
    def testAnswerWaitTakesWaitParam(): Unit \ Assert =
        Assert.assertEq(expected = 120i64, App.RemoteDebug.answerWaitSecs(Map#{ "view" => "shot", "wait" => "120" }))

    /// 範囲の外（1〜600 の外）の wait= は使わない。
    @Test
    def testAnswerWaitIgnoresOutOfRangeWait(): Unit \ Assert =
        Assert.assertEq(expected = 10i64, App.RemoteDebug.answerWaitSecs(Map#{ "wait" => "0" }))
}
