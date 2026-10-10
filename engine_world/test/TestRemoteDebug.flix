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
        let request = RemoteDebug.parseRequest("POST /step?view=status&max=90\npress Z\nidle 5");
        Assert.assertEq(
            expected = ("POST", "/step", Some("status"), Some("90"), "press Z\nidle 5"),
            (request#method, request#path,
             Map.get("view", request#params), Map.get("max", request#params), request#body))

    // クエリ無し・ボディ無し（GET /help のような形）でも安全に空へ落ちる。
    @Test
    def testParseRequestBareGet(): Unit \ Assert =
        let request = RemoteDebug.parseRequest("GET /help\n");
        Assert.assertEq(
            expected = ("GET", "/help", 0, ""),
            (request#method, request#path, Map.size(request#params), request#body))

    // クエリ値は最小限の URL デコード（+ と %20 → 空白）だけを行う。
    @Test
    def testParseRequestDecodesSpacesInQueryValues(): Unit \ Assert =
        let request = RemoteDebug.parseRequest("POST /save?name=girl+in%20rain\n");
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
            (RemoteDebug.findRoute("/save", routes),
             RemoteDebug.findRoute("/save2", routes),
             RemoteDebug.findRoute("/nope", routes)))

    // ========================================================================
    // parseParams: クエリの解釈
    // ========================================================================

    /// Rect2 は record で ToString が無いので、比較用に (x, y, w, h) のタプルへ射影する。
    def rectTuple(rect: Rect2.Rect2): (Float64, Float64, Float64, Float64) =
        (rect#position#x, rect#position#y, rect#size#x, rect#size#y)

    // 何も指定しなければ既定値（status / 全画面 / 止めない / 1200 コマ / trace 無し / 1/60 秒）。
    @Test
    def testParseParamsDefaults(): Unit \ Assert =
        let actual = RemoteDebug.parseParams(Map.empty())
            |> Result.map(p -> (p#view, p#rect |> Option.map(rectTuple),
                                p#stopWhen, p#maxFrames, p#traceEvery, p#dtSeconds));
        Assert.assertEq(
            expected = Ok((RemoteDebug.View.Status, None, RemoteDebug.Until.Always, 1200, None, 1.0 / 60.0)),
            actual)

    // rect は "x,y,w,h" の 4 値をデザイン座標の矩形として読む。
    @Test
    def testParseParamsRect(): Unit \ Assert =
        let actual = RemoteDebug.parseParams(Map#{"rect" => "96.0,40.0,80.0,30.0"})
            |> Result.map(p -> p#rect |> Option.map(rectTuple));
        Assert.assertEq(
            expected = Ok(Some((96.0, 40.0, 80.0, 30.0))),
            actual)

    // until は音イベント名の集合（sfx:break,miss）へ展開される。
    @Test
    def testParseParamsUntilSfxNames(): Unit \ Assert =
        let actual = RemoteDebug.parseParams(Map#{"until" => "sfx:break,miss"})
            |> Result.map(p -> p#stopWhen);
        Assert.assertEq(
            expected = Ok(RemoteDebug.Until.SfxNamed(Set#{"break", "miss"})),
            actual)

    // until=quiet:N は「N フレーム連続無音で停止」。dt はミリ秒指定を秒へ変換する。
    @Test
    def testParseParamsQuietAndDt(): Unit \ Assert =
        let actual = RemoteDebug.parseParams(Map#{"until" => "quiet:30", "dt" => "4.0"})
            |> Result.map(p -> (p#stopWhen, p#dtSeconds));
        Assert.assertEq(
            expected = Ok((RemoteDebug.Until.Quiet(30), 0.004)),
            actual)

    // 未知の view 名は理由つきの Err（応答へそのまま載せられる文言）で弾く。
    @Test
    def testParseParamsRejectsUnknownView(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            RemoteDebug.parseParams(Map#{"view" => "verbose"}) |> Result.isErr)

    // max は 1..3600 の範囲外を弾く（1 リクエスト暴走の安全弁）。
    @Test
    def testParseParamsRejectsHugeMax(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            RemoteDebug.parseParams(Map#{"max" => "9999"}) |> Result.isErr)

    // ========================================================================
    // parseScript: 台本 DSL の展開
    // ========================================================================

    // press は「押す 1 コマ + 離す 1 コマ」= 1 押下 1 発火（エッジ検出と噛み合う形）。
    @Test
    def testParseScriptPressMakesEdge(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(Set#{GameEngine.Key.Z} :: Set#{} :: Nil),
            RemoteDebug.parseScript("press Z"))

    // hold は同じキー集合を N コマ。カンマ区切りで同時押しになる。
    @Test
    def testParseScriptHoldTogether(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(List.repeat(3, Set#{GameEngine.Key.Left, GameEngine.Key.Z})),
            RemoteDebug.parseScript("hold Left,Z 3"))

    // 複数行は上から順に連結され、# 以降のコメントと空行は無視される。
    //   press Enter   → [Enter], []
    //   idle 2        → [], []
    //   hold Right 2  → [Right], [Right]
    @Test
    def testParseScriptMultiLine(): Unit \ Assert =
        let script = "press Enter  # タイトルを抜ける\n\nidle 2\nhold Right 2";
        Assert.assertEq(
            expected = Ok(Set#{GameEngine.Key.Enter} :: Set#{} :: Set#{} :: Set#{}
                          :: Set#{GameEngine.Key.Right} :: Set#{GameEngine.Key.Right} :: Nil),
            RemoteDebug.parseScript(script))

    // キー名は大文字小文字を区別しない（"z" でも "Z" でも同じキー）。
    @Test
    def testKeyOfIsCaseInsensitive(): Unit \ Assert =
        Assert.assertEq(
            expected = (Some(GameEngine.Key.Z), Some(GameEngine.Key.LeftShift)),
            (RemoteDebug.keyOf("z"), RemoteDebug.keyOf("leftshift")))

    // 知らないキー名は行の文言ごと Err になる（応答でそのまま教えられる）。
    @Test
    def testParseScriptRejectsUnknownKey(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            RemoteDebug.parseScript("press NoSuchKey") |> Result.isErr)

    // ========================================================================
    // 応答の整形
    // ========================================================================

    // ヘッダ 1 行に「何コマ進み・現在フレーム・なぜ止まったか・消化率」が全部載る。
    @Test
    def testStepHeaderFormat(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok stepped=40 frame=1307 mode=halted stopped=until:sfx consumed=40/160\n",
            RemoteDebug.stepHeader({ stepped = 40, total = 160, frame = 1307i64,
                                     stoppedBy = "until:sfx", quit = false }))

    // 音イベントは「f=フレーム番号 sfx=音名」で時系列に並ぶ。無ければブロックごと消える。
    @Test
    def testEventsBlockFormat(): Unit \ Assert =
        Assert.assertEq(
            expected = ("[events]\nf=1246 sfx=paddle\nf=1307 sfx=wall\n", ""),
            (RemoteDebug.eventsBlock((1246i64, "paddle") :: (1307i64, "wall") :: Nil),
             RemoteDebug.eventsBlock(Nil)))

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
            RemoteDebug.sceneBlock(rect, hits))

    // /render の成功応答: 1 行目に枚数と所要 ms、[rendered] ブロックに描き出した順のパス 1 行 1 枚。
    @Test
    def testRenderDoneTextListsPathsInOrder(): Unit \ Assert =
        Assert.assertEq(
            expected = "ok rendered=2 ms=845\n[rendered]\ngallery/title.png\ngallery/ending.png\n",
            RemoteDebug.renderDoneText(845i64, "gallery/title.png" :: "gallery/ending.png" :: Nil))

    // 描き出しの実体が未登録なら error 応答（Studio はこの 1 行目を見て自前の描き出しへフォールバック）。
    @Test
    def testRenderUnsupportedTextIsError(): Unit \ Assert =
        Assert.assertEq(
            expected = true,
            String.startsWith(prefix = "error:", RemoteDebug.renderUnsupportedText()))

    // 依頼番号の付け外し: 本文のタブや改行はそのまま戻る（依頼と答えを番号で対にする）。
    @Test
    def testTaggedRoundTripKeepsBody(): Unit \ Assert =
        Assert.assertEq(expected = Some((42i64, "POST /step\nidle 1\tx")),
            RemoteDebug.untagged(RemoteDebug.tagged(42i64, "POST /step\nidle 1\tx")))

    // 番号の無い形は番号付きとして読まない（取り違えた答えを渡さない）。
    @Test
    def testUntaggedRejectsMissingId(): Unit \ Assert =
        Assert.assertEq(expected = None, RemoteDebug.untagged("ok rendered=3\tx"))
}
