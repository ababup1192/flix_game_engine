// Flow — 1 行 1 手の手順書 e2e/<名前>.flow を、実機と同じ 1 フレーム（App.traceFrame）で流す実行器。
// e2e のテスト・動画の手順・遊んだ記録の再生（DEBUG の起動が debug/flow-record/latest.flow に書く）が同じ物を通る。
// 形は Maestro の flow に合わせた（手の語は閉じた一覧・別の flow は run で入れる）。設計のメモは docs/flow.md。
//
//   fps 60                          先頭の設定（fps・ready on|off・ゲームが宣言した設定 look night など）
//   start stack gap=0               始まりの登録簿（App.withStarts）の名前と引数。start のたびに World を作り直す
//   tap confirm                     1 フレーム押して離す（役の名前・キー Z,Enter・点 120,80 = クリック）
//   hold soft 0.5                   押しっぱなし（長さは秒か 30f。書かなければ release まで）
//   release soft
//   wait 0.8                        何も触らない（押しっぱなしの物はそのまま）
//   until lines>=4 max 10           問いが立つまで待つ（max 秒は必須。当たったら失敗）
//   drive reader until choice max 60   名前付きの操作に任せて問いが立つまで
//   expect phase=GameOver           ここで立っていなければ失敗（フレームは使わない）
//   mark cleared                    ここのフレームに名前を付ける（動画の切り出しの印）
//   run open_menu.flow              別の flow をここに入れる（同じフォルダ・8 段まで）
//
// ゲームが出す表（App.withFlow）:
//   roles   = 役の名前 → キーの表（InputMap.Table[String]。表の先頭のキーを押す）
//   probes  = 問いの名前 → World から読む関数（Num・Text・Flag）
//   drives  = 名前付きの操作（待った秒と World → Tap(役)・Idle・Restart）
//   ready   = 入力を受けられるか（Ready・Busy(理由)）。宣言すると tap・hold の前に自動で待つ（ready off で止まる）
//   replies = 返事の通し番号（押した後に進まなければ、押した行の番号つきで失敗。ready off で止まる）
//   options = ヘッダの設定の名前と値の候補（値はこの実行器では使わず、動画を撮るゲームが読む）
//
// 読む順: 表（Table）→ 手順（Script・Step）→ play（Outcome か Failure）。読み手は Flow.Parse、headless の入口は Flow.Cli。
pub mod Flow {
    use GameEngine.Key

    import java.util.{Base64 => JBase64}
    import java.lang.{String => JString}
    import java.lang.IllegalArgumentException

    // ── ゲームが出す表 ──

    /// 問い 1 つの読み方。Num は < <= = >= > != で比べ、Text は = と != で比べ、Flag はそのまま（!名前 で否定）。
    pub enum Probe[w] {
        case Num(w -> Float64)
        case Text(w -> String)
        case Flag(w -> Bool)
    }

    /// 入力を受けられるか。Busy の理由は、待ちが 10 秒に当たった時の知らせに載る。
    pub enum Ready with Eq, ToString {
        case Ready
        case Busy(String)
    }

    /// 名前付きの操作の 1 フレームの決め事。Tap = その役を 1 フレーム押す（待った秒は 0 に戻る）・
    /// Idle = 押さずに待つ（待った秒は増え続ける）・Restart = 押さずに待った秒を 0 に戻す（読み始めを数え直す）。
    pub enum DriveAct with Eq, ToString {
        case Tap(String)
        case Idle
        case Restart
    }

    pub type alias ProbeRow[w] = { name = String, doc = String, read = Probe[w] }

    /// act の引数は (drive の始まりか最後の Tap・Restart から待った秒, いまの World)。
    pub type alias DriveRow[w] = { name = String, doc = String, act = (Float64, w) -> DriveAct }

    /// ゲームが出す表。ready と replies を宣言しないゲームは、自動の待ちと返事の確かめをしない。
    pub type alias Table[w] = {
        roles = w -> InputMap.Table[String],
        probes = List[ProbeRow[w]],
        drives = List[DriveRow[w]],
        ready = Option[w -> Ready],
        replies = Option[w -> Int64],
        options = List[(String, List[String])]
    }

    /// 何も宣言しない表（{ probes = … | Flow.emptyTable() } で要る欄だけ書く）。
    pub def emptyTable(): Table[w] =
        { roles = _ -> Nil, probes = Nil, drives = Nil, ready = None, replies = None, options = Nil }

    /// ゲームの役の enum の表（InputMap.Table[a]）を、名前の表にする。
    pub def rolesOf(name: a -> String, table: InputMap.Table[a]): InputMap.Table[String] =
        table |> List.map(entry -> { let (key, role) = entry; (key, name(role)) })

    // ── 語彙（読み手・check・e2e/vocab.json が使う名前の一覧）──

    pub enum Kind with Eq, ToString {
        case Num
        case Text
        case Flag
    }

    /// 名前の一覧。roles は World から読むので、語彙は World を 1 つ決めて作る（ふつうは新しく作った初期の World）。
    pub type alias Vocab = {
        roles = List[String],
        probes = List[(String, Kind, String)],
        drives = List[(String, String)],
        starts = List[(String, String, Map[String, String])],
        options = List[(String, List[String])],
        keys = List[String],
        ready = Bool,
        replies = Bool,
        fingerprint = Bool
    }

    /// 手の語（閉じた一覧）。記録が書く語（reload・request・close・rewind）も同じ文法で読める。
    pub def verbs(): List[String] =
        "start" :: "tap" :: "hold" :: "release" :: "wait" :: "until" :: "drive" :: "expect" :: "mark" :: "run" ::
        "reload" :: "request" :: "close" :: "rewind" :: Nil

    /// エンジンが持つ設定の語（ゲームの設定は Table#options）。
    pub def settings(): List[String] = "fps" :: "ready" :: Nil

    /// 指紋の問いの名前（App.withFingerprint を繋いだゲームだけ）。
    pub def fingerprintProbe(): String = "fp"

    pub def vocabOf(app: App.App[w, ef], world: w): Vocab =
        let table = app#flow;
        let roles = table#roles;
        { roles = roles(world) |> List.map(snd) |> List.distinct,
          probes = table#probes |> List.map(row -> (row#name, kindOf(row#read), row#doc)),
          drives = table#drives |> List.map(row -> (row#name, row#doc)),
          starts = app#starts |> List.map(start -> (start#name, start#doc, start#args)),
          options = table#options,
          keys = GameEngine.allKeys() |> List.map(key -> "${key}"),
          ready = Option.nonEmpty(table#ready),
          replies = Option.nonEmpty(table#replies),
          fingerprint = Option.nonEmpty(app#fingerprint) }

    def kindOf(probe: Probe[w]): Kind = match probe {
        case Probe.Num(_)  => Kind.Num
        case Probe.Text(_) => Kind.Text
        case Probe.Flag(_) => Kind.Flag
    }

    /// 語彙を e2e/vocab.json の形にする（bin/fge flow check が読む。キーの順は固定）。
    pub def vocabJson(vocab: Vocab): String =
        let quote = text -> "\"" + escape(text) + "\"";
        let list = xs -> "[" + (xs |> List.map(quote) |> String.intercalate(", ")) + "]";
        let argsJson = args -> "{" + (args |> Map.toList |> List.map(entry -> { let (k, v) = entry; "${quote(k)}: ${quote(v)}" }) |> String.intercalate(", ")) + "}";
        let probes = vocab#probes |> List.map(row -> { let (name, kind, doc) = row;
            "    {\"name\": ${quote(name)}, \"kind\": ${quote(String.toLowerCase("${kind}"))}, \"doc\": ${quote(doc)}}" });
        let drives = vocab#drives |> List.map(row -> { let (name, doc) = row; "    {\"name\": ${quote(name)}, \"doc\": ${quote(doc)}}" });
        let starts = vocab#starts |> List.map(row -> { let (name, doc, args) = row;
            "    {\"name\": ${quote(name)}, \"doc\": ${quote(doc)}, \"args\": ${argsJson(args)}}" });
        let options = vocab#options |> List.map(row -> { let (name, values) = row; "    ${quote(name)}: ${list(values)}" });
        let block = rows -> if (List.isEmpty(rows)) "[]" else "[\n" + String.intercalate(",\n", rows) + "\n  ]";
        "{\n" +
        "  \"verbs\": ${list(verbs())},\n" +
        "  \"settings\": ${list(settings())},\n" +
        "  \"options\": " + (if (List.isEmpty(options)) "{}" else "{\n" + String.intercalate(",\n", options) + "\n  }") + ",\n" +
        "  \"roles\": ${list(vocab#roles)},\n" +
        "  \"probes\": ${block(probes)},\n" +
        "  \"drives\": ${block(drives)},\n" +
        "  \"starts\": ${block(starts)},\n" +
        "  \"keys\": ${list(vocab#keys)},\n" +
        "  \"ready\": ${vocab#ready},\n" +
        "  \"replies\": ${vocab#replies},\n" +
        "  \"fingerprint\": ${vocab#fingerprint}\n" +
        "}\n"

    def escape(text: String): String =
        text |> String.replace(src = "\\", dst = "\\\\") |> String.replace(src = "\"", dst = "\\\"")
             |> String.replace(src = "\n", dst = "\\n")

    // ── 手順（読み手が作る形）──

    /// 押す物: 役の名前・キーの集合・画面の点（design 座標。クリック）。
    pub enum Target with Eq, ToString {
        case Role(String)
        case Keys(Set[Key])
        case Point(Float64, Float64)
    }

    /// 長さ: 秒（fps でフレーム数に丸める）かフレーム数。
    pub enum Span with Eq, ToString {
        case Secs(Float64)
        case Frames(Int32)
    }

    /// フレームの手の付け足し（ほとんどは記録が書く）。ns = フレームごとの経過ナノ秒（数がフレーム数）・dt = 経過秒・
    /// at = マウスの位置・mouse = 左ボタンを押している・wheel = ホイール・pad = パッドに触っている・
    /// keys = 押しているキーの丸ごと・pressed / click / moved = 前のフレームとの差分から出ない押した瞬間・クリック・動き。
    pub type alias Opt = {
        ns = List[Int64], dt = Option[Float64], at = Option[Vec2.Vec2], mouse = Bool, wheel = Float64, pad = Bool,
        keys = Option[Set[Key]], pressed = Option[Set[Key]], click = Option[Bool], moved = Option[Bool]
    }

    pub def noOpt(): Opt =
        { ns = Nil, dt = None, at = None, mouse = false, wheel = 0.0, pad = false,
          keys = None, pressed = None, click = None, moved = None }

    pub enum Cmp with Eq, ToString {
        case Lt
        case Le
        case Same
        case Ge
        case Gt
        case Differ
    }

    /// 問いの式。Name は真偽の問い・Compare は (名前, 比べ方, 書いた値の文字)。
    pub enum Expr with Eq, ToString {
        case Name(String)
        case Not(Expr)
        case Both(Expr, Expr)
        case Compare(String, Cmp, String)
    }

    /// 記録が書いたファイルの中身（再生はこの中身を読ませる）。Missing = 読めなかった（無いセーブ）。
    pub enum File with Eq, ToString {
        case Text(String)
        case Missing
    }

    /// 手 1 つ。tap・hold・release・wait はフレームを使い、expect・mark は使わない。
    pub enum Step {
        case Start(String, Map[String, String], Map[String, File])
        case Tap(Target, Opt)
        case Hold(Target, Option[Span], Opt)
        case Release(Target, Opt)
        case Wait(Span, Opt)
        case Until(Expr, Float64)
        case Drive(String, Expr, Float64)
        case Expect(Expr)
        case Mark(String)
        case Reload(String, Map[String, File])          // "key" = reloadOn の関数（F1）・それ以外 = watchFile のパス
        case Request(String, Map[String, String], Map[String, File]) // onRequest のパスとクエリ
        case Close                                      // 窓の閉じるボタン（withCloseRequest）
        case Rewind(Int32)                              // F8 の巻き戻しから再開した（N フレーム前の World へ）
    }

    /// 手 1 つと、その書いてある所（失敗の知らせに載せる）。
    pub type alias Line = { file = String, number = Int32, text = String, step = Step }

    /// 読んだ手順。ready = None は on と同じ（ready off だけが待ちと返事の確かめを止める）。
    pub type alias Script = { fps = Float64, ready = Option[Bool], options = Map[String, String], lines = List[Line] }

    // ── 流した結果 ──

    /// 1 フレームとその後の固定刻みの持ち越し（/step が途中で止める時に要る）。
    pub type alias Played[w] = { step = App.TraceStep[w], state = App.StepState }

    /// 流し終えた結果。frames は先頭から。marks = 名前 → その時までのフレーム数・starts = (その時までのフレーム数, 始まりの名前)。
    pub type alias Outcome[w] = { frames = List[Played[w]], marks = Map[String, Int32], starts = List[(Int32, String)],
                                  last = w, state = App.StepState }

    /// 止まった所。frame = それまでのフレーム数・why = 理由・seen = 使った問いの今の値と statusLine・upTo = そこまで。
    pub type alias Failure[w] = { at = Line, frame = Int32, why = String, seen = String, upTo = Outcome[w] }

    /// play の設定: design = 解像度（Frame#viewport）・limit = フレーム数の上限（超えたら失敗）。
    pub type alias Setup = { design = Vec2.Vec2, limit = Int32 }

    /// フレームの列（World の列。動画が描く物）。
    pub def worldsOf(outcome: Outcome[w]): List[w] = outcome#frames |> List.map(played -> played#step#after)

    // ── 実行器 ──

    /// フレームをまたいで持つ手の様子。held = 押しっぱなしのキー・button = 左ボタンを押しっぱなし・cursor = マウスの位置・
    /// prev* = 前のフレームで実際に押していた物（押した瞬間・クリック・動きを出す）。
    type alias Hand = { held = Set[Key], button = Bool, cursor = Vec2.Vec2,
                        prevDown = Set[Key], prevButton = Bool, prevCursor = Option[Vec2.Vec2] }

    def freshHand(): Hand =
        { held = Set.empty(), button = false, cursor = { x = -100.0, y = -100.0 },
          prevDown = Set.empty(), prevButton = false, prevCursor = None }

    /// 流している途中の物。frames と history は新しい順。awaiting = 返事を待っている tap（行と押す前の番号）。
    type alias Cursor[w] = {
        world = w, state = App.StepState, hand = Hand, frames = List[Played[w]], count = Int32,
        marks = Map[String, Int32], starts = List[(Int32, String)], history = List[w],
        awaiting = Option[(Line, Int64)], served = Map[String, File]
    }

    /// 止まる理由（行と、そこまでの Cursor）。
    type alias Stop[w] = { cursor = Cursor[w], at = Line, why = String, seen = String }

    /// 手順を流す。start = 最初の手が start でない時に使う World と持ち越し（/step は走っている World、
    /// ファイルの flow は先頭の始まり）。tap・hold は ready on なら入力を受けられるまで待ち、返事を確かめる。
    pub def play(app: App.App[w, ef], setup: Setup, script: Script,
                 start: { world = w, state = App.StepState }): Result[Failure[w], Outcome[w]] \ ef + Fs.FileRead =
        // ready off だけが「書いたフレームでそのまま押し、確かめない」。待つのは ready を、確かめるのは replies を宣言したゲームだけ。
        let readyOn = script#ready |> Option.getWithDefault(true);
        let dt = wholeNanos(if (script#fps > 0.0) 1.0 / script#fps else 1.0 / 60.0);
        let ctx = { app = app, setup = setup, dt = dt, readyOn = readyOn };
        let begin = { world = start#world, state = start#state, hand = freshHand(), frames = Nil, count = 0,
                      marks = Map.empty(), starts = Nil, history = start#world :: Nil, awaiting = None,
                      served = Map.empty() };
        let finish = (c: Cursor[w]) -> { frames = List.reverse(c#frames), marks = c#marks,
                                         starts = List.reverse(c#starts), last = c#world, state = c#state };
        let stepped = script#lines |> List.foldLeft((acc, line) -> match acc {
            case Err(stop) => Err(stop)
            case Ok(c)     => runLine(ctx, line, c)
        }, Ok(begin));
        let settled = stepped |> Result.flatMap(c -> match c#awaiting {
            case Some((line, _)) if not answered(ctx, c) =>
                Err({ cursor = c, at = line, why = "押したが受け付けられなかった（返事の番号が進まない）", seen = "" })
            case _ => Ok(c)
        });
        match settled {
            case Ok(c)     => Ok(finish(c))
            case Err(stop) => Err({ at = stop#at, frame = stop#cursor#count, why = stop#why,
                                    seen = seenOf(ctx, stop#seen, stop#cursor#world), upTo = finish(stop#cursor) })
        }

    type alias Ctx[w: Type, ef: Eff] = { app = App.App[w, ef], setup = Setup, dt = Float64, readyOn = Bool }

    def runLine(ctx: Ctx[w, ef], line: Line, c: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef + Fs.FileRead =
        match line#step {
            case Step.Start(name, args, files) =>
                match served(files, () -> App.buildStart(ctx#app, ctx#setup#design, name, args)) {
                    case Err(why)  => Err({ cursor = c, at = line, why = why, seen = "" })
                    case Ok(world) =>
                        Ok({ world = world, state = App.freshStepState(), hand = freshHand(), history = world :: Nil,
                             awaiting = None, starts = (c#count, name) :: c#starts | c })
                }
            case Step.Tap(target, opt)        => press(ctx, line, target, None, opt, c)
            case Step.Hold(target, span, opt) => press(ctx, line, target, Some(span), opt, c)
            case Step.Release(target, opt)    =>
                let hand = match target {
                    case Target.Point(_, _) => { button = false | c#hand }
                    case _                  => { held = Set.difference(c#hand#held, keysOf(ctx, target, c#world)) | c#hand }
                };
                frames(ctx, line, countOf(ctx, Span.Frames(1), opt), Set.empty(), opt, { hand = hand | c })
            case Step.Wait(span, opt)   => frames(ctx, line, countOf(ctx, span, opt), Set.empty(), opt, c)
            case Step.Until(expr, max)  => waitFor(ctx, line, None, expr, framesIn(ctx, max), c)
            case Step.Drive(name, expr, max) =>
                match ctx#app#flow#drives |> List.find(row -> row#name == name) {
                    case None      => Err({ cursor = c, at = line, why = "操作 '${name}' は表に無い", seen = "" })
                    case Some(row) => waitFor(ctx, line, Some(row), expr, framesIn(ctx, max), c)
                }
            case Step.Expect(expr) =>
                if (holds(ctx#app, expr, c#world)) Ok(c)
                else Err({ cursor = c, at = line, why = "expect が立たない: ${showExpr(expr)}", seen = showExpr(expr) })
            case Step.Mark(name) => Ok({ marks = Map.insert(name, c#count, c#marks) | c })
            case Step.Reload(target, files) =>
                let app = ctx#app;
                let reloaded = served(files, () -> match target {
                    case "key" => match app#reload {
                        case Some((_, reloadAll)) => reloadAll(c#world)
                        case None                 => c#world
                    }
                    case path => app#watch |> List.foldLeft((acc, entry) -> {
                        let (watched, f) = entry;
                        if (watched == path) f(acc) else acc
                    }, c#world)
                });
                Ok({ world = reloaded, history = reloaded :: List.drop(1, c#history) | c })
            case Step.Request(path, params, files) =>
                match App.RemoteDebug.findRoute(path, ctx#app#remoteHandlers) {
                    case None => Err({ cursor = c, at = line, why = "onRequest のルート '${path}' が無い", seen = "" })
                    case Some(apply) => match served(files, () -> apply(params, c#world)) {
                        case Ok(changed) => Ok({ world = changed, history = changed :: List.drop(1, c#history) | c })
                        case Err(why)    => Err({ cursor = c, at = line, why = "onRequest '${path}': ${why}", seen = "" })
                    }
                }
            case Step.Close => match ctx#app#closeRequest {
                case Some(f) => {
                    let closed = f(c#world);
                    Ok({ world = closed, history = closed :: List.drop(1, c#history) | c })
                }
                case None    => Ok(c)
            }
            case Step.Rewind(back) =>
                match List.nth(back, c#history) {
                    case Some(world) => Ok({ world = world, history = List.drop(back, c#history) | c })
                    case None => Err({ cursor = c, at = line, why = "rewind ${Int32.toString(back)}: そこまでの履歴が無い", seen = "" })
                }
        }

    /// tap（span = None）と hold（span = Some(長さか release まで)）。ready on なら入力を受けられるまで待ち（10 秒まで）、
    /// 押したフレームの後に返事の番号が進んだかを見る（固定刻みで押した瞬間が取り置かれている間は、消化されるまで待つ）。
    def press(ctx: Ctx[w, ef], line: Line, target: Target, span: Option[Option[Span]], opt: Opt,
              c0: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef =
        let raw = not List.isEmpty(opt#ns);
        let checked = ctx#readyOn and not raw;
        let readied = if (checked) untilReady(ctx, line, c0) else Ok(c0);
        readied |> Result.flatMap(c -> {
            let replies = ctx#app#flow#replies;
            let before = replies |> Option.map(f -> f(c#world));
            let keys = keysOf(ctx, target, c#world);
            let clicking = match target { case Target.Point(x, y) => Some({ x = x, y = y }) case _ => None };
            if (Option.isEmpty(clicking) and Set.isEmpty(keys))
                Err({ cursor = c, at = line, why = "${showTarget(target)} にキーが無い（表の役か、キーの名前）", seen = "" })
            else {
                let pressOpt = match clicking {
                    case Some(point) => { at = Some(point), mouse = true | opt }
                    case None        => opt
                };
                let first = countOf(ctx, Span.Frames(1), opt);
                // 前のフレームで押していた物をもう一度押すなら、間に離すフレームを 1 つ挟む（実機でも離さずに 2 回は押せない）。
                let downBefore = not Set.isEmpty(Set.intersection(keys, c#hand#prevDown))
                                 or (Option.nonEmpty(clicking) and c#hand#prevButton);
                let released = if (raw or not downBefore) Ok(c)
                               else frames(ctx, line, 1, Set.empty(), noOpt(),
                                           { hand = { held = Set.difference(c#hand#held, keys),
                                                      button = c#hand#button and Option.isEmpty(clicking) | c#hand } | c });
                let pressed = released |> Result.flatMap(gap -> frames(ctx, line, first, keys, pressOpt, gap));
                let held = pressed |> Result.flatMap(after -> match span {
                    case None => Ok(after)
                    case Some(None) =>
                        Ok({ hand = { held = Set.union(after#hand#held, keys),
                                      button = after#hand#button or Option.nonEmpty(clicking) | after#hand } | after })
                    case Some(Some(length)) =>
                        let holding = { held = Set.union(after#hand#held, keys),
                                        button = after#hand#button or Option.nonEmpty(clicking) | after#hand };
                        frames(ctx, line, countOf(ctx, length, noOpt()) - 1, Set.empty(), { at = None | noOpt() },
                               { hand = holding | after })
                            |> Result.map(done -> { hand = { held = c#hand#held, button = c#hand#button | done#hand } | done })
                });
                held |> Result.flatMap(after -> match before {
                    case Some(seq) if checked =>
                        if (Some(seq) != (replies |> Option.map(f -> f(after#world)))) Ok(after)
                        else if (isSettled(after#state))
                            Err({ cursor = after, at = line, why = "押したが受け付けられなかった（返事の番号が進まない）", seen = "" })
                        else Ok({ awaiting = Some((line, seq)) | after })
                    case _ => Ok(after)
                })
            }
        })

    /// 入力を受けられるまで（ready が Ready になるまで）何も触らずに待つ。今の World で問う（1 フレーム遅れてよい）。
    def untilReady(ctx: Ctx[w, ef], line: Line, c0: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef =
        match ctx#app#flow#ready {
            case None => Ok(c0)
            case Some(readyOf) =>
                def loop(left: Int32, c: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef = match readyOf(c#world) {
                    case Ready.Ready => Ok(c)
                    case Ready.Busy(why) =>
                        if (left <= 0) Err({ cursor = c, at = line, why = "押せるようにならなかった（10 秒・${why}）", seen = "" })
                        else frames(ctx, line, 1, Set.empty(), noOpt(), c) |> Result.flatMap(next -> loop(left - 1, next))
                };
                loop(framesIn(ctx, 10.0), c0)
        }

    /// 問いが立つまで回す（立っていれば 1 フレームも使わない）。drive があれば毎フレーム押すかを決めさせる。
    def waitFor(ctx: Ctx[w, ef], line: Line, drive: Option[DriveRow[w]], expr: Expr, max: Int32,
                c0: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef =
        def loop(left: Int32, waited: Float64, c: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef =
            if (holds(ctx#app, expr, c#world)) Ok(c)
            else if (left <= 0)
                Err({ cursor = c, at = line, why = "待ちが max（${Int32.toString(max)} フレーム）に当たった: ${showExpr(expr)}",
                      seen = showExpr(expr) })
            else {
                let act = match drive {
                    case None      => DriveAct.Idle
                    case Some(row) => let decide = row#act; decide(waited, c#world)
                };
                match act {
                    case DriveAct.Tap(role) =>
                        frames(ctx, line, 1, keysOf(ctx, Target.Role(role), c#world), noOpt(), c)
                            |> Result.flatMap(next -> loop(left - 1, 0.0, next))
                    case DriveAct.Restart =>
                        frames(ctx, line, 1, Set.empty(), noOpt(), c) |> Result.flatMap(next -> loop(left - 1, 0.0, next))
                    case DriveAct.Idle =>
                        frames(ctx, line, 1, Set.empty(), noOpt(), c) |> Result.flatMap(next -> loop(left - 1, waited + ctx#dt, next))
                }
            };
        loop(max, 0.0, c0)

    /// n フレーム進める。1 フレーム目だけ extra（押す物）を足し、opt の ns があればフレームごとの経過秒にする。
    def frames(ctx: Ctx[w, ef], line: Line, n: Int32, extra: Set[Key], opt: Opt, c: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef =
        List.range(0, n) |> List.foldLeft((acc, index) -> acc |> Result.flatMap(cur -> {
            let dt = match List.nth(index, opt#ns) {
                case Some(nanos) => Int64.toFloat64(nanos) / 1000000000.0
                case None        => opt#dt |> Option.map(wholeNanos) |> Option.getWithDefault(ctx#dt)
            };
            let thisOpt = if (index == 0) opt else { pressed = None, click = None, moved = None | opt };
            advance(ctx, line, dt, if (index == 0) extra else Set.empty(), thisOpt, cur)
        }), Ok(c))

    /// 1 フレーム: 手の様子と opt から Frame を組み、App.traceFrame（実機と同じ 1 フレーム）で進める。
    def advance(ctx: Ctx[w, ef], line: Line, dt: Float64, extra: Set[Key], opt: Opt, c: Cursor[w]): Result[Stop[w], Cursor[w]] \ ef =
        if (c#count >= ctx#setup#limit)
            Err({ cursor = c, at = line, why = "フレームの上限（${Int32.toString(ctx#setup#limit)}）に当たった", seen = "" })
        else {
            let hand = c#hand;
            let down = opt#keys |> Option.getWithDefault(Set.union(hand#held, extra));
            let cursor = opt#at |> Option.getWithDefault(hand#cursor);
            let button = opt#mouse or hand#button;
            let moved = hand#prevCursor |> Option.exists(p -> p#x != cursor#x or p#y != cursor#y);
            let frame = { down = down,
                          justPressed = opt#pressed |> Option.getWithDefault(Set.difference(down, hand#prevDown)),
                          dt = dt, viewport = ctx#setup#design, cursor = cursor,
                          mouseDown = button,
                          mouseClicked = opt#click |> Option.getWithDefault(button and not hand#prevButton),
                          mouseMoved = opt#moved |> Option.getWithDefault(moved),
                          wheel = opt#wheel, realNow = Clock.zero(), padTouched = opt#pad };
            let (step, state) = App.traceFrame(ctx#app, frame, c#state, c#world);
            let nextHand = { cursor = cursor, prevDown = down, prevButton = button, prevCursor = Some(cursor),
                             held = opt#keys |> Option.getWithDefault(hand#held) | hand };
            let next = { world = step#after, state = state, hand = nextHand, count = c#count + 1,
                         frames = { step = step, state = state } :: c#frames,
                         history = List.take(App.historyLimit(), step#after :: c#history) | c };
            match next#awaiting {
                case Some((pressLine, _)) =>
                    if (answered(ctx, next)) Ok({ awaiting = None | next })
                    else if (isSettled(state))
                        Err({ cursor = next, at = pressLine, why = "押したが受け付けられなかった（返事の番号が進まない）", seen = "" })
                    else Ok(next)
                case None => Ok(next)
            }
        }

    /// 経過秒をナノ秒の整数に丸める。実機の経過秒もナノ秒から来るので、flow で流したフレームを記録して
    /// 再生しても同じ秒になる（1/60 秒のまま流すと、記録のナノ秒と時計が少しずつずれて指紋が合わない）。
    pub def wholeNanos(secs: Float64): Float64 =
        Float64.round(secs * 1000000000.0) / 1000000000.0

    /// 返事を待っている tap の番号が進んだか。
    def answered(ctx: Ctx[w, ef], c: Cursor[w]): Bool =
        match (c#awaiting, ctx#app#flow#replies) {
            case (Some((_, seq)), Some(f)) => f(c#world) != seq
            case _                         => true
        }

    /// 固定刻みで取り置いた押した瞬間が残っていないか（残っている間は、次のフレームで系に届く）。
    def isSettled(state: App.StepState): Bool =
        Set.isEmpty(state#pending#justPressed) and not state#pending#mouseClicked

    def countOf(ctx: Ctx[w, ef], span: Span, opt: Opt): Int32 =
        if (not List.isEmpty(opt#ns)) List.length(opt#ns)
        else match span {
            case Span.Secs(secs) => framesIn(ctx, secs)
            case Span.Frames(n)  => n
        }

    def framesIn(ctx: Ctx[w, ef], secs: Float64): Int32 =
        Float64.tryToInt32(Float64.round(secs / ctx#dt)) |> Option.getWithDefault(0)

    /// 押すキー: 役なら表の先頭のキー（いまの World の表）・キーならそのまま・点なら無し。
    def keysOf(ctx: Ctx[w, ef], target: Target, world: w): Set[Key] =
        match target {
            case Target.Role(name) =>
                let roles = ctx#app#flow#roles;
                roles(world) |> List.find(entry -> snd(entry) == name) |> Option.map(entry -> Set#{fst(entry)})
                    |> Option.getWithDefault(Set.empty())
            case Target.Keys(keys)  => keys
            case Target.Point(_, _) => Set.empty()
        }

    /// files を読ませる Fs.FileRead で f を流す（記録の再生。載っていないパスは本物のファイルを読む）。
    def served(files: Map[String, File], f: Unit -> a \ ef): a \ ef + Fs.FileRead =
        if (Map.isEmpty(files)) f()
        else run { f() } with handler Fs.FileRead {
            def read(path, k) = match Map.get(path, files) {
                case Some(File.Text(text)) => k(Ok(text))
                case Some(File.Missing)    => k(Err(IoError.IoError(IoError.ErrorKind.NotFound, path)))
                case None                  => k(Fs.FileRead.read(path))
            }
            def readLines(path, k) = match Map.get(path, files) {
                case Some(File.Text(text)) => k(Ok(String.lines(text)))
                case Some(File.Missing)    => k(Err(IoError.IoError(IoError.ErrorKind.NotFound, path)))
                case None                  => k(Fs.FileRead.readLines(path))
            }
            def readBytes(path, k) = match Map.get(path, files) {
                case Some(File.Text(text)) => k(Ok(String.toBytes(text)))
                case Some(File.Missing)    => k(Err(IoError.IoError(IoError.ErrorKind.NotFound, path)))
                case None                  => k(Fs.FileRead.readBytes(path))
            }
        }

    // ── 問い ──

    /// 問いの式が今の World で立っているか。表に無い名前・型の違う比べは立たない（読み手と check が先に止める）。
    pub def holds(app: App.App[w, ef], expr: Expr, world: w): Bool =
        match expr {
            case Expr.Not(inner)    => not holds(app, inner, world)
            case Expr.Both(a, b)    => holds(app, a, world) and holds(app, b, world)
            case Expr.Name(name)    => match valueOf(app, name, world) {
                case Some(Value.Flag(on)) => on
                case _                    => false
            }
            case Expr.Compare(name, cmp, text) => match valueOf(app, name, world) {
                case Some(Value.Num(x)) => match Float64.fromString(text) {
                    case Some(y) => compareNum(cmp, x, y)
                    case None    => false
                }
                case Some(Value.Text(x)) => match cmp {
                    case Cmp.Same   => x == text
                    case Cmp.Differ => x != text
                    case _          => false
                }
                case Some(Value.Flag(on)) => match cmp {
                    case Cmp.Same   => "${on}" == text
                    case Cmp.Differ => "${on}" != text
                    case _          => false
                }
                case None => false
            }
        }

    def compareNum(cmp: Cmp, x: Float64, y: Float64): Bool = match cmp {
        case Cmp.Lt     => x < y
        case Cmp.Le     => x <= y
        case Cmp.Same   => x == y
        case Cmp.Ge     => x >= y
        case Cmp.Gt     => x > y
        case Cmp.Differ => x != y
    }

    /// 問いの今の値。
    pub enum Value with Eq, ToString {
        case Num(Float64)
        case Text(String)
        case Flag(Bool)
    }

    pub def valueOf(app: App.App[w, ef], name: String, world: w): Option[Value] =
        if (name == fingerprintProbe()) app#fingerprint |> Option.map(f -> Value.Text(fingerprintOf(f(world))))
        else app#flow#probes |> List.find(row -> row#name == name) |> Option.map(row -> match row#read {
            case Probe.Num(f)  => Value.Num(f(world))
            case Probe.Text(f) => Value.Text(f(world))
            case Probe.Flag(f) => Value.Flag(f(world))
        })

    /// 指紋の元の文字を 8 字の 16 進の指紋にする（記録の expect fp= と同じ物）。
    pub def fingerprintOf(text: String): String =
        let hash = Hash.hash(text);
        let unsigned = Int32.toInt64(hash) + (if (hash < 0) 4294967296i64 else 0i64);
        let (_, digits) = List.range(0, 8) |> List.foldLeft((acc, _) -> {
            let (rest, out) = acc;
            let digit = Int64.modulo(rest, 16i64) |> Int64.tryToInt32 |> Option.getWithDefault(0);
            (rest / 16i64, String.charAt(digit, "0123456789abcdef") :: out)
        }, (unsigned, Nil));
        digits |> List.map(Char.toString) |> String.intercalate("")

    /// 記録の行に載せるファイルの中身（UTF-8 の Base64。改行や空白を 1 語に収める）。
    pub def base64Encode(text: String): String =
        unsafe IO { JBase64.getEncoder().encodeToString(text.getBytes("UTF-8")) }

    /// base64Encode の逆（戻せなければ None）。
    pub def base64Decode(text: String): Option[String] =
        unsafe IO {
            try { Some(new JString(JBase64.getDecoder().decode(text), "UTF-8")) }
            catch { case _: IllegalArgumentException => None }
        }

    /// 式に出てくる名前の今の値（失敗の知らせ）と statusLine。
    def seenOf(ctx: Ctx[w, ef], exprText: String, world: w): String \ ef =
        let names = namesIn(exprText);
        let values = names |> List.map(name -> match valueOf(ctx#app, name, world) {
            case Some(Value.Num(x))   => "${name}=${x}"
            case Some(Value.Text(x))  => "${name}=${x}"
            case Some(Value.Flag(on)) => "${name}=${on}"
            case None                 => "${name}=?"
        }) |> String.intercalate(" ");
        let status = match ctx#app#statusLine {
            case Some(line) => line(world)
            case None       => ""
        };
        String.trim(values + (if (values != "" and status != "") " / " else "") + status)

    /// 式の文字から問いの名前を拾う（!・&・比べの記号の前）。
    def namesIn(text: String): List[String] =
        if (text == "") Nil
        else String.splitOn({substr = "&"}, text)
            |> List.map(part -> { let trimmed = String.trim(part); if (String.startsWith(prefix = "!", trimmed)) String.dropLeft(1, trimmed) else trimmed })
            |> List.map(part -> splitCompare(part) |> Option.map(match (name, _, _) -> name) |> Option.getWithDefault(part))
            |> List.distinct

    /// "lines>=4" を (名前, 比べ方, 値) に分ける。比べの記号が無ければ None。
    pub def splitCompare(text: String): Option[(String, Cmp, String)] =
        let ops = ("<=", Cmp.Le) :: (">=", Cmp.Ge) :: ("!=", Cmp.Differ) :: ("<", Cmp.Lt) :: (">", Cmp.Gt) :: ("=", Cmp.Same) :: Nil;
        let found = ops |> List.filterMap(entry -> {
            let (symbol, cmp) = entry;
            String.indexOfLeft({substr = symbol}, text) |> Option.map(i -> (i, symbol, cmp))
        });
        match found |> List.map(match (i, symbol, _) -> i * 10 - String.length(symbol)) |> List.minimum {
            case None => None
            case Some(best) => found |> List.find(match (i, symbol, _) -> i * 10 - String.length(symbol) == best)
                |> Option.map(match (i, symbol, cmp) -> (String.takeLeft(i, text), cmp, String.dropLeft(i + String.length(symbol), text)))
        }

    /// 式を書いた形に戻す（知らせ用）。
    pub def showExpr(expr: Expr): String = match expr {
        case Expr.Name(name)    => name
        case Expr.Not(inner)    => "!" + showExpr(inner)
        case Expr.Both(a, b)    => showExpr(a) + "&" + showExpr(b)
        case Expr.Compare(name, cmp, text) => name + cmpSymbol(cmp) + text
    }

    pub def cmpSymbol(cmp: Cmp): String = match cmp {
        case Cmp.Lt     => "<"
        case Cmp.Le     => "<="
        case Cmp.Same   => "="
        case Cmp.Ge     => ">="
        case Cmp.Gt     => ">"
        case Cmp.Differ => "!="
    }

    def showTarget(target: Target): String = match target {
        case Target.Role(name)  => "役 '${name}'"
        case Target.Keys(keys)  => "キー '${keys |> Set.toList |> List.map(k -> "${k}") |> String.intercalate(",")}'"
        case Target.Point(x, y) => "点 ${x},${y}"
    }
}
