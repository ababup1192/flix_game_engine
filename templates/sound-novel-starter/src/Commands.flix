// Commands — シナリオの演出コマンド（<<名前 引数…>>）の表と、表を引いて舞台に当てる口（純粋）。
// 1 コマンド = 引数の表（YarnCommands.Spec）+ apply 1 つ。同じ表から、実行時の読み方と bin/fge yarn build の検査が読む
// 語彙（make talk-vocab。テンプレートの表 all() は assets/talk/vocab.std.json、ゲームの表 GameCommands.all() は assets/talk/vocab.json の commands）の両方が出る。
//
//   <<bg 写真 [grade=時間帯] [time=秒] [transition=fade|black|wipe|slide|pan|cut] [pace=walk|run] [ease=]>>
//                                              背景を「写真」（novel.backdrops.json の photos）に替え、秒かけて切り替える。
//                                              grade（grades）を省くと今の背景の時間帯のまま・transition / time / ease を省くと Doc の defaultTransition / defaultSeconds / defaultEase
//   <<window 型|clear|off|on [time=]>>        メッセージ枠の型（novel.theme.json の windows。作例は nvl = 画面いっぱい・bottom = 下の枠）に替える /
//                                              NVL の頁をめくる / 文字の枠と字を消す・出す（off は次の台詞・選択肢か型の指定でも戻る。time は off・on の薄くなる秒・
//                                              省くと novel.kind.json の windowFadeSeconds）。型を替えると、その型に align があれば字の揃えを型の既定へ戻す
//   <<text [at=top|center|bottom] [size=名前] [align=left|center] [speed=倍率] [lock=秒]>>
//                                              字の置き場（NVL の頁の中）・大きさ（novel.kind.json の textSizes）・揃え・文字送りの速さの倍率・押しても送らない秒
//   <<speak 名前>>                            字を出さずに話す（話し手を明るくし、novel.cast.json の speakFx を markers の mouth から一度出す）
//   <<audio ambience|bgm 音[,音]|off [volume=] [fade=]>>   鳴り続ける環境音（, で重ねる）・音楽を替える・止める（音は project.json の sounds の名前。
//                                              volume は数か novel.mixer.json の volumes の名前）
//   <<audio se 音 [wait=true]>>               効果音を 1 回（wait は音の長さだけ続きを待つ。novel.mixer.json の lockSeconds の間は押しても送らない）
//   <<audio all off [fade=]>>                 環境音と音楽を全部止める
//   <<fx 名前|off [once=true] [on=絵.点]>>    画面の粒の演出（novel.effects.json の particles。on は novel.cast.json の markers の点から出す・点から出せる粒だけ）
//   <<shake [強さ] [on=screen|window|名前] [time=秒]>>   揺らす（強さは novel.kind.json の shakes の名前か px・省くと shakeSeconds / shakePx）
//   <<overlay 濃さ [color=black|white|#rrggbb] [from=] [layer=stage|screen] [time=0] [ease=]>>   画面に色を被せる（同じ濃さへは何もしない）
//   <<camera [zoom=] [x=] [y=] [time=0.5] [ease=]>>   world の層を寄せる・ずらす（文字の枠と HUD には掛けない）
//   <<tween 鍵 値 [from=] [time=0.5] [ease=smoothstep]>>   ゲームの数の値（鍵 lair.arrive は game.lair.arrive）を秒かけて動かす（3D のカメラの道筋の進みなど）
//   <<show 名前 [表情] [at=位置] [from=left|right|top|bottom] [x=] [y=] [scale=] [alpha=] [time=秒] [ease=]>>
//                                              立ち絵か小物（novel.cast.json の cast / props）を出す・表情や位置を替える。何人・何個でも出せ、
//                                              exclusive の位置にだけは 1 つ（後から出した物が前の物を消す）。省いた物は出ている形のまま
//                                              （出ていなければ Doc の face・slot）。from は端から slideDistance だけ滑って出る。x〜alpha は actor.<名>.*。
//                                              ease は出入りの濃さと動きの曲線（省くと濃さは novel.cast.json の fadeEase・動きは smoothstep）
//   <<hide 名前|all [to=left|right|top|bottom] [time=秒] [ease=]>> / <<hide at=位置>>   その人・全部・その位置に出ている物を消す（to は端へ滑って消える）
//   <<move 名前 [x=|dx=] [y=|dy=] [scale=] [alpha=] [rotate=] [from=] [to=] [time=0.5] [ease=smoothstep]>>
//                                              出ている絵の位置・大きさ・濃さ・傾きを時間で動かす（dx・dy は今の終わりの値に足す）。
//                                              from は出ていない絵を端の外から出し、to は端の外まで動かしてから消す
//
// 書き方は YarnCommands（位置の引数は 2 つまで・ほかは key=value・"…" は空白を含む 1 つの値）。
// 表に無い名前と引数の誤りは Err を返し、World が 1 行言って舞台はそのまま続ける（シナリオの書き損じで止めない）。
// 引数はシナリオを読んだ時に 1 回だけ読んで表（ArgsTable。Res が持つ）に置き、毎回の実行では読み直さない。
// apply が後に残す物は全部 Stage に書く（セーブ・settle・素材待ちが Stage だけを見て済むように）。
// WhyNot: <<audio se 音 wait=true>> の待ちを後ろの <<wait 秒>> に足さない — 実行器はコマンドを返した時にはもう後ろの <<wait>> まで流していて、
//   その時刻から数える。足すには実行器（engine_world の YarnRunner）に待ちを差し込む口が要るので、2 つは重なり、長い方だけ待つ。
mod Commands {
    use fge::{Clock, Curve, Yarn, YarnCommands}
    use fge::YarnCommands.{DocRef, Param}
    use fge::YarnCommands.Param.Or

    /// apply が読める物: now = 物語の時計の今、node = 読んでいるノード（無ければ ""）、res = Doc とシナリオ、
    /// instant = 演出を待たずに済ませる時（Silent の当て直しかスキップ中。ゲームが持つ背景の切り替えを聞かない）。
    pub type alias Ctx = { now = Clock.Time[Stage.Story], node = String, res = Res.Res, instant = Bool }

    /// apply が舞台の外へ出す出来事（後に残る状態は書かない）。
    ///   ClearPage = NVL の頁をめくる / TurnPage = ADV の頁を送る / Sound(名前) = 効果音を 1 回（project.json の sounds）/
    ///   Event(名前) = その場の音や見た目の合図だけ（World.Event.Signal になる）/
    ///   Wait(秒) = 物語の時計で秒だけ、続きの台詞・選択肢・コマンドを出さずに待つ（<<wait 秒>> と同じ待ち。Silent では落とす）/
    ///   WaitOrTap(秒) = Wait と同じ待ちで、人が押すと（送りの操作）秒を待たずに明ける。押して明けた時は、ゲームが持つ背景の切り替えも
    ///   終わりの形にする（Stage.withGameSwitchFinished）。オートでは明けない。Silent では落とし、スキップ中は Wait と同じくすぐ明ける /
    ///   LineWait(秒) = 次の台詞を待たせる待ち。WaitOrTap と同じく押すと明け、待ちの間も後ろの時間を取らない命令
    ///   （<<audio>>・<<jump>> の先の命令など。<<set>> は実行器が先に済ませるので出来事にならない）は先に流し、
    ///   台詞・選択肢・<<wait>>・時間を取る命令で止まる。bg がゲームの切り替えで出す待ちと、後ろを止めずに次の台詞だけを待たせたい
    ///   ゲームのコマンド（コメントを 1 件流して間を置く等）が使う。
    // WhyNot: WaitOrTap に時間を取らない命令を流させない — 待ちが明けてから後ろの効果音を鳴らしたいゲームのコマンドもあり、どちらも選べるよう 2 つ持つ。
    pub enum Out with Eq, ToString {
        case ClearPage
        case TurnPage
        case Sound(String)
        case Event(String)
        case Wait(Float64)
        case WaitOrTap(Float64)
        case LineWait(Float64)
    }

    /// 時間を取る演出か。Timed なら、後の <<wait>> の間テープの位置がこの行を指す（World.talkCursorOf）。
    pub enum Timing with Eq, ToString {
        case Timed
        case Instant
    }

    /// 出来事を外へ出すか。Live = 人が読み進めている時、Silent = ロード・戻る・プレビューの当て直し（音と合図を落とす。頁は作り直すので通す）。
    pub enum Replay with Eq {
        case Live
        case Silent
    }

    /// コマンド 1 つ。apply は純粋で、Doc に無い名前は Err。needs = 当てる前に届いていてほしい絵と音の名前（project.json の textures / sounds）。
    pub type alias Command[st] = {
        spec = YarnCommands.Spec,
        timing = Timing,
        apply = (Ctx, YarnCommands.Args, st) -> Result[String, (st, List[Out])],
        needs = (Res.Res, YarnCommands.Args, st) -> List[String]
    }

    /// 待つ素材の無いコマンドの needs。
    pub def noAssets(_res: Res.Res, _args: YarnCommands.Args, _st: st): List[String] = Nil

    /// テンプレートのコマンドの表。
    pub def all(): List[Command[Stage.Stage]] =
        bg() :: window() :: text() :: speak() :: audio() :: fx() :: shake() :: overlay() :: camera() :: tween() :: show() :: hide() :: move() :: Nil

    /// シナリオが使える全部（テンプレートの表とゲームの表）。
    pub def table(): List[Command[Stage.Stage]] = List.append(all(), GameCommands.all())

    /// 読み進める時に当てる命令の表（Res#commands）。
    // WhyNot: Res に命令の列をそのまま持たせない — Command の Ctx が Res を持つので、型の別名どうしが互いを指して組めない。
    enum CommandTable(List[Command[Stage.Stage]])

    pub type alias Table = CommandTable

    pub def tableOf(commands: List[Command[Stage.Stage]]): Table = CommandTable.CommandTable(commands)

    pub def commandsIn(t: Table): List[Command[Stage.Stage]] = let CommandTable.CommandTable(commands) = t; commands

    /// 台詞を 1 行積むたびに舞台を動かす口（GameCommands.onLine）。Res が持ち、テストが差す。
    // WhyNot: Res に関数をそのまま持たせない — Ctx が Res を持つので、型の別名どうしが互いを指して組めない。
    enum LineHookOf((Ctx, Stage.Stage) -> Stage.Stage)

    pub type alias LineHook = LineHookOf

    pub def lineHookOf(f: (Ctx, Stage.Stage) -> Stage.Stage): LineHook = LineHookOf.LineHookOf(f)

    pub def applyLineHook(hook: LineHook, ctx: Ctx, st: Stage.Stage): Stage.Stage = let LineHookOf.LineHookOf(f) = hook; f(ctx, st)

    /// テンプレートとゲームを合わせた全部の命令の表（名前の重なりを見るテスト）。
    pub def specs(): List[YarnCommands.Spec] = table() |> List.map(c -> c#spec)

    def lookup(name: String): Option[Command[Stage.Stage]] = lookupIn(table(), name)

    /// ease=曲線の名前（Curve.easeTable）。書かなければ None（既定は呼ぶ側が Doc から引く）。
    // WhyNot: Param.ease を使わない — 既定を表に持つので書いたかが分からず、Doc の既定（defaultEase・fadeEase）へ落とせない。
    def easeParam(): Param.Opt[String] = Param.choice("ease", Curve.easeTable() |> List.map(fst))

    /// 書いた ease= の曲線（書いていなければ None）。
    def easeArg(h: Param.Opt[String], a: YarnCommands.Args): Option[Curve.Ease] =
        Param.getOpt(h, a) |> Option.flatMap(name -> Curve.easeTable() |> List.find(e -> fst(e) == name) |> Option.map(snd))

    /// ease= を書いた時だけ、出し入れの濃さの曲線をその曲線にした意味。
    def withEaseOf(ease: Option[Curve.Ease], cue: Cast.Cue): Cast.Cue =
        ease |> Option.map(e -> Cast.withCueEase(e, cue)) |> Option.getWithDefault(cue)

    def lookupIn(commands: List[Command[Stage.Stage]], name: String): Option[Command[Stage.Stage]] =
        commands |> List.find(c -> YarnCommands.nameOf(c#spec) == name)

    /// シナリオの <<audio se 音 wait=true>> の音の名前（長さが要る音）。
    pub def waitSoundsOf(program: Yarn.Program): List[String] =
        Talk.commandsOf(program) |> List.filterMap(c -> match c#args {
            case "se" :: sound :: rest if c#name == "audio" and List.memberOf("wait=true", rest) => Some(sound)
            case _                                                                          => None
        }) |> List.distinct

    // ── 読んだ引数の表 ──

    /// シナリオの全部のコマンドを読んだ結果（鍵は .yarn の「ファイル:行」。表に無い名前のコマンドは入れない）。
    enum ArgsTableOf(Map[String, (Yarn.Command, Result[String, YarnCommands.Args])])

    /// シナリオを読んだ時に 1 回だけ作る引数の表（Res.withDialogue が作り直す）。
    pub type alias ArgsTable = ArgsTableOf

    /// program の全部のコマンドを表で読む。
    pub def argsTableOf(program: Yarn.Program): ArgsTable =
        let entryOf = (command: Yarn.Command) -> lookup(command#name)
            |> Option.map(c -> (Yarn.sourceText(command#source), (command, YarnCommands.parse(c#spec, command))));
        ArgsTableOf.ArgsTableOf(Talk.commandsOf(program) |> List.filterMap(entryOf) |> List.toMap)

    /// command の引数（表に同じ行の同じコマンドがあればそれを使い、無ければここで読む）。
    // WhyNot: 行の鍵だけで引かない — 台本の差し替えの前に作った表やテストが組んだコマンドは、同じ行に別のコマンドがありうる。
    def argsOf(table: ArgsTable, c: Command[Stage.Stage], command: Yarn.Command): Result[String, YarnCommands.Args] =
        let ArgsTableOf.ArgsTableOf(m) = table;
        match Map.get(Yarn.sourceText(command#source), m) {
            case Some((seen, args)) if seen#name == command#name and seen#args == command#args => args
            case _ => YarnCommands.parse(c#spec, command)
        }

    def parsed(res: Res.Res, command: Yarn.Command): Option[(Command[Stage.Stage], YarnCommands.Args)] =
        forM (c <- lookupIn(commandsIn(res#commands), command#name); args <- argsOf(res#commandArgs, c, command) |> Result.toOption) yield (c, args)

    // ── 表を引く ──

    /// command を表で読んで st に当てる。Silent の時は Sound と Event を落とし、apply には instant を立てて渡す。
    pub def execute(replay: Replay, ctx: Ctx, command: Yarn.Command, st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        executeUsing(commandsIn(ctx#res#commands), replay, ctx, command, st)

    /// execute の、引く表を commands から取る形（テストが命令を差す）。
    pub def executeUsing(commands: List[Command[Stage.Stage]], replay: Replay, ctx: Ctx, command: Yarn.Command, st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        let at = " (${Yarn.sourceText(command#source)})";
        forM (
            c <- lookupIn(commands, command#name) |> Option.toOk("知らないコマンド <<${command#name}>>${at}");
            args <- argsOf(ctx#res#commandArgs, c, command);
            done <- c#apply({ instant = ctx#instant or replay == Replay.Silent | ctx }, args, st) |> Result.mapErr(why -> "<<${command#name}>> ${why}${at}")
        ) yield {
            let (next, outs) = done;
            (next, outs |> List.filter(out -> replay == Replay.Live or isPageOut(out)))
        }

    def isPageOut(out: Out): Bool = match out {
        case Out.ClearPage => true
        case Out.TurnPage  => true
        case Out.Sound(_)  => false
        case Out.Event(_)  => false
        case Out.Wait(_)   => false
        case Out.WaitOrTap(_) => false
        case Out.LineWait(_) => false
    }

    /// command が時間を取る演出か（読めないコマンドは Instant）。
    pub def timingOf(res: Res.Res, command: Yarn.Command): Timing =
        parsed(res, command) |> Option.map(match (c, _) -> c#timing) |> Option.getWithDefault(Timing.Instant)

    /// command を st に当てる前に届いていてほしい絵と音の名前（読めないコマンドは空）。
    pub def needsOf(res: Res.Res, command: Yarn.Command, st: Stage.Stage): List[String] =
        parsed(res, command) |> Option.map(match (c, args) -> c#needs(res, args, st)) |> Option.getWithDefault(Nil)

    // ── 台本と同じ書き方の 1 行を当てる（GameCommands が標準の舞台を替える口） ──

    /// "<<show whale corpse time=0>>" を表で読んで st に当てる。GameCommands が人物・背景・覆いを替える時はこれを通す（Cast や背景の形に直に触らない）。
    /// 出来事は落とさない（GameCommands の apply を呼んだ execute が replay で振り分ける）。
    pub def applyText(ctx: Ctx, text: String, st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        forM (
            command <- commandOfText(text);
            c <- lookup(command#name) |> Option.toOk("知らないコマンド ${text}");
            args <- YarnCommands.parse(c#spec, command);
            done <- c#apply(ctx, args, st) |> Result.mapErr(why -> "${text} ${why}")
        ) yield done

    /// applyText で当てる 1 行が、当てる前に届いていてほしい絵と音の名前（読めない行は空。GameCommands の needs に使う）。
    pub def needsOfText(res: Res.Res, text: String, st: Stage.Stage): List[String] =
        let found = forM (command <- commandOfText(text) |> Result.toOption; c <- lookup(command#name); args <- YarnCommands.parse(c#spec, command) |> Result.toOption)
            yield c#needs(res, args, st);
        Option.getWithDefault(Nil, found)

    /// "<<名前 引数…>>" をコマンド 1 つに。台本と同じく空白で割り、"…" は空白を含んでも 1 つ（" ごと残す。外すのは Param）。
    pub def commandOfText(text: String): Result[String, Yarn.Command] =
        let inner = String.stripPrefix(substr = "<<", String.trim(text)) |> Option.flatMap(String.stripSuffix(substr = ">>")) |> Option.map(String.trim);
        match inner |> Option.map(wordsOf) {
            case Some(name :: args) => Ok({ name = name, args = args, tags = Nil, source = { file = "applyText", line = 0 } })
            case _                  => Err("<<名前 引数…>> の形でない '${text}'")
        }

    /// コマンドの中を空白で割る（"…" の中の空白では割らず、中の \ は次の 1 字をそのまま入れる）。
    def wordsOf(inner: String): List[String] =
        let flush = (out, cur) -> if (List.isEmpty(cur)) out else (List.reverse(cur) |> List.map(Char.toString) |> String.flatten) :: out;
        let step = (acc: (List[String], List[Char], Bool, Bool), c: Char) -> {
            let (out, cur, quoted, escaped) = acc;
            if (escaped) (out, c :: cur, quoted, false)
            else if (quoted and c == '\\') (out, c :: cur, quoted, true)
            else if (c == '"') (out, c :: cur, not quoted, false)
            else if (not quoted and Char.isWhitespace(c)) (flush(out, cur), Nil, false, false)
            else (out, c :: cur, quoted, false)
        };
        let (out, cur, _, _) = String.toList(inner) |> List.foldLeft(step, (Nil, Nil, false, false));
        List.reverse(flush(out, cur))

    // ── Doc の名前の場所（vocab.json のフォルダ assets/talk から数える） ──

    def backdrops(path: String): DocRef = DocRef.Keys("../novel.backdrops.json", path)

    def castNames(): List[DocRef] = DocRef.Keys("../novel.cast.json", "cast") :: DocRef.Keys("../novel.cast.json", "props") :: Nil

    def faces(): List[DocRef] = DocRef.Path("../novel.cast.json", "cast.*.faces[]") :: DocRef.Path("../novel.cast.json", "props.*.faces[]") :: Nil

    def markers(): List[DocRef] = DocRef.Keys("../novel.cast.json", "cast.*.markers") :: DocRef.Keys("../novel.cast.json", "props.*.markers") :: Nil

    def slots(): List[DocRef] = DocRef.Keys("../novel.cast.json", "slots") :: Nil

    def sounds(): List[DocRef] = DocRef.Path("../../project.json", "sounds[].name") :: Nil

    // ── コマンド ──

    def bg(): Command[Stage.Stage] = bgUsing(GameCommands.backdropSwitch)

    /// <<bg>> の表。switchOf = ゲームが持つ背景の切り替え（Ctx・前の背景・替える先・台本の替え方 → 秒と音。None なら台本の transition と time=）。
    /// ゲームが持つ切り替えは、その秒だけ続きを待たせる（Out.Wait）。instant の時は聞かない。
    // WhyNot: ゲームが持つ切り替えに台本の transition を残さない — slide・pan のずれと black の暗転が歩く絵に掛かり、cut は秒を 0 に潰す。
    pub def bgUsing(switchOf: (Ctx, Option[Stage.Shot], Stage.Shot, Stage.Switch) -> Option[Stage.GameSwitch]): Command[Stage.Stage] =
        let photo = Param.name("photo", backdrops("photos") :: Nil) |> Param.at(1) |> Param.required;
        let grade = Param.name("grade", backdrops("grades") :: Nil);
        let time = Param.num("time", 0.0, 60.0);
        let transition = Param.choice("transition", BackdropDoc.transitionNames());
        let pace = Param.choice("pace", "walk" :: "run" :: Nil);
        let ease = easeParam();
        let gradeOf = (a, prev: Option[Stage.Shot]) -> Param.getOpt(grade, a) |> Option.withDefault(default = prev |> Option.map(s -> s#grade));
        { spec = YarnCommands.spec("bg", "背景の写真を時間帯の色で替え、秒かけて切り替える（transition = fade・black・wipe・slide・pan・cut。transition・time・ease を省くと novel.backdrops.json の defaultTransition・defaultSeconds・defaultEase・pace = 3D の道筋の歩き方）",
                                   Param.erase(photo) :: Param.erase(grade) :: Param.erase(time) :: Param.erase(transition) :: Param.erase(pace) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let doc = ctx#res#backdrops;
              let name = Param.get(photo, a);
              let switch = { transition = Param.getOpt(transition, a) |> Option.flatMap(BackdropDoc.transitionOf) |> Option.getWithDefault(BackdropDoc.rec(doc)#defaultTransition),
                             ease = easeArg(ease, a) |> Option.getWithDefault(BackdropDoc.rec(doc)#defaultEase),
                             pace = if (Param.getOpt(pace, a) == Some("run")) Stage.Pace.Run else Stage.Pace.Walk,
                             game = None };
              let prev = Stage.shownShot(doc, st);
              match gradeOf(a, prev) {
                  case None => Err("grade= が要る（前の背景が無い）")
                  case Some(g) =>
                      if (Option.isEmpty(BackdropDoc.photoOf(name, doc))) Err("知らない写真 '${name}'")
                      else if (Option.isEmpty(BackdropDoc.gradeOf(g, doc))) Err("知らない時間帯 '${g}'")
                      else {
                          let shot = { photo = name, grade = g };
                          let owned = if (ctx#instant) None else switchOf(ctx, prev, shot, switch);
                          let seconds = owned |> Option.map(o -> o#seconds) |> Option.getWithDefault(Param.getOpt(time, a) |> Option.getWithDefault(BackdropDoc.rec(doc)#defaultSeconds));
                          let byGame = if (Option.nonEmpty(owned)) { transition = BackdropDoc.Transition.Fade, game = owned | switch } else switch;
                          let next = Stage.withBackdropBy(ctx#now, shot, seconds, byGame, { shot = prev | st });
                          let waits = if (Option.nonEmpty(owned) and next#fadeSeconds > 0.0) Out.LineWait(next#fadeSeconds) :: Nil else Nil;
                          // WhyNot: NVL の頁を背景の切り替えでめくらない — NVL の頁の切れ目は <<window clear>> と行の数が決める。
                          Ok((next, List.append(if (Stage.kindOf(ctx#res#theme, st) == ThemeDoc.WindowKind.Adv) Out.TurnPage :: Nil else Nil, waits)))
                      }
              }
          },
          needs = (res, a, _) -> BackdropDoc.textureOf(Param.get(photo, a), res#backdrops) |> Option.toList }

    def window(): Command[Stage.Stage] =
        let mode = Param.name("mode", DocRef.Keys("../novel.theme.json", "windows") :: Nil) |> Param.orWords("clear" :: "off" :: "on" :: Nil)
            |> Param.at(1) |> Param.required;
        let time = Param.num("time", 0.0, 10.0);
        let toMode = (ctx: Ctx, name, st: Stage.Stage) -> {
            let changed = fst(Stage.windowOf(ctx#res#theme, st)) != name;
            let typed = Option.nonEmpty(snd(ThemeDoc.windowOf(name, ctx#res#theme))#align);
            // WhyNot: align の無い型へ替えた時は <<text align=>> の揃えを消さない — 消すと、今の台本の <<text align=center>> の後の <<window 型>> で見た目が変わる。
            let props = if (changed and typed) PropertyTween.setName(Stage.textAlignKey(), None, ctx#now, 0.0, st#props) else st#props;
            (Stage.withWindowShown(ctx#now, { mode = name, props = props | st }), if (changed) Out.ClearPage :: Nil else Nil)
        };
        { spec = YarnCommands.spec("window", "メッセージ枠の型（novel.theme.json の windows）に替える・NVL の頁をめくる（clear）・文字の枠と字を消す（off。次の台詞で戻る）・出す（on。time = off・on の薄くなる秒・省くと novel.kind.json の windowFadeSeconds）",
                                   Param.erase(mode) :: Param.erase(time) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> {
              let secs = Param.getOpt(time, a);
              let fade = Option.getWithDefault(KindDoc.rec(ctx#res#kind)#windowFadeSeconds, secs);
              match Param.get(mode, a) {
                  case Or.Word("off") => Ok((Stage.withWindowFade(ctx#now, true, fade, st), Nil))
                  case Or.Word("on")  => Ok((Stage.withWindowFade(ctx#now, false, fade, st), Nil))
                  case _ if Option.nonEmpty(secs) => Err("time= は off・on だけ")
                  case Or.Word(_)     => Ok((st, Out.ClearPage :: Nil))
                  case Or.Value(name) =>
                      if (ThemeDoc.hasWindow(name, ctx#res#theme)) Ok(toMode(ctx, name, st))
                      else Err("知らないメッセージ枠の型 '${name}'（novel.theme.json の windows）")
              }
          },
          needs = noAssets }

    def text(): Command[Stage.Stage] =
        let place = Param.choice("at", "top" :: "center" :: "bottom" :: Nil) |> Param.oneOf("what");
        let size = Param.name("size", DocRef.Keys("../novel.kind.json", "textSizes") :: Nil) |> Param.oneOf("what");
        let align = Param.choice("align", "left" :: "center" :: Nil) |> Param.oneOf("what");
        let speed = Param.num("speed", 0.05, 10.0) |> Param.oneOf("what");
        let lock = Param.num("lock", 0.0, 30.0) |> Param.oneOf("what");
        { spec = YarnCommands.spec("text", "字の置き場（at = NVL の頁の中の top・center・bottom）・大きさ（size = novel.kind.json の textSizes）・揃え（align）・文字送りの速さの倍率（speed）・押しても送らない秒（lock）",
                                   Param.erase(place) :: Param.erase(size) :: Param.erase(align) :: Param.erase(speed) :: Param.erase(lock) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> {
              let named = (key, value: Option[String], t) -> value |> Option.map(v -> PropertyTween.setName(key, Some(v), ctx#now, 0.0, t)) |> Option.getWithDefault(t);
              let sizeName = Param.getOpt(size, a);
              let inAdv = Stage.kindOf(ctx#res#theme, st) == ThemeDoc.WindowKind.Adv;
              if (Option.nonEmpty(Param.getOpt(place, a)) and inAdv)
                  Err("at= は NVL の頁の中の置き場（今の型は ADV。ADV の枠の置き場は novel.theme.json の windows の place）")
              else if (sizeName |> Option.exists(n -> not Map.memberOf(n, KindDoc.rec(ctx#res#kind)#textSizes)))
                  Err("知らない字の大きさ '${Option.getWithDefault("", sizeName)}'（novel.kind.json の textSizes）")
              else {
                  let props = st#props |> named(Stage.textAtKey(), Param.getOpt(place, a)) |> named(Stage.textSizeKey(), sizeName)
                      |> named(Stage.textAlignKey(), Param.getOpt(align, a));
                  let sped = Param.getOpt(speed, a) |> Option.map(v -> PropertyTween.setNum(Stage.textSpeedKey(), v, ctx#now, 0.0, props)) |> Option.getWithDefault(props);
                  let locked = Param.getOpt(lock, a) |> Option.map(secs -> PropertyTween.trigger(Stage.textLockKey(), ctx#now, 0.0, secs, sped)) |> Option.getWithDefault(sped);
                  Ok(({ props = locked | st }, Nil))
              }
          },
          needs = noAssets }

    def speak(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.at(1) |> Param.required;
        { spec = YarnCommands.spec("speak", "字を出さずに話す（話し手を明るくし、novel.cast.json の speakFx を markers の mouth から一度出す）",
                                   Param.erase(who) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> {
              let name = Param.get(who, a);
              let spoken = { props = PropertyTween.setName(Stage.speakerKey(), Some(name), ctx#now, 0.0, st#props) | st };
              match Cast.entryOf(ctx#res#cast, name) |> Option.map(e -> e#speakFx) {
                  case None             => Err("知らない人物か小物 '${name}'")
                  case Some(None)       => Ok((spoken, Nil))
                  case Some(Some(fx))   =>
                      if (Option.isEmpty(CastDoc.markerOf(name, "mouth", ctx#res#cast))) Err("'${name}' に speakFx があるのに markers に mouth が無い（novel.cast.json）")
                      else applyEffect(ctx, fx, true, Some("${name}.mouth"), spoken)
              }
          },
          needs = noAssets }

    /// <<audio>> のチャンネル。Ambience = 鳴り続ける環境音（, で重ねる）・Bgm = 音楽・Se = 一発の効果音・All = 環境音と音楽の全部（off だけ）。
    enum Channel with Eq {
        case Ambience
        case Bgm
        case Se
        case All
    }

    def channelOf(name: String): Channel = match name {
        case "ambience" => Channel.Ambience
        case "bgm"      => Channel.Bgm
        case "se"       => Channel.Se
        case _          => Channel.All
    }

    /// 鳴り続ける音の名前と音量の鍵の組（環境音か音楽）。
    def sustainedKeys(channel: Channel): Option[(PropertyTween.NameKey, PropertyTween.NumKey)] = match channel {
        case Channel.Ambience => Some((Stage.ambienceKey(), Stage.ambienceVolumeKey()))
        case Channel.Bgm      => Some((Stage.bgmKey(), Stage.bgmVolumeKey()))
        case _                => None
    }

    /// 鳴り続ける音を now から替える。sound = None で止める。fade > 0 なら、鳴らす時は音量 0 から、止める時は音量 0 まで fade 秒で動かす。
    /// 鳴っている音と同じ音なら、鳴らし直さずに今の音量から volume へ動かす。
    def withSustained(now: Clock.Time[Stage.Story], keys: (PropertyTween.NameKey, PropertyTween.NumKey), sound: Option[String], volume: Float64, fade: Float64,
                      st: Stage.Stage): Stage.Stage =
        let (nameKey, volumeKey) = keys;
        let same = Option.nonEmpty(sound) and PropertyTween.nameEnd(nameKey, st#props) == sound;
        let props = match sound {
            case Some(_) if same =>
                PropertyTween.tween(volumeKey, Some(PropertyTween.numAt(now, volumeKey, 1.0, st#props)), volume, now, 0.0, fade, Curve.Ease.Linear, st#props)
            case Some(_) =>
                let named = PropertyTween.setName(nameKey, sound, now, 0.0, st#props);
                if (fade > 0.0) PropertyTween.tween(volumeKey, Some(0.0), volume, now, 0.0, fade, Curve.Ease.Linear, named)
                else PropertyTween.setNum(volumeKey, volume, now, 0.0, named)
            case None =>
                if (fade > 0.0) PropertyTween.tween(volumeKey, None, 0.0, now, 0.0, fade, Curve.Ease.Linear, st#props) |> PropertyTween.setName(nameKey, None, now, fade)
                else PropertyTween.setName(nameKey, None, now, 0.0, st#props)
        };
        { props = props | st }

    /// チャンネルに書けない引数を書いた時の理由（無ければ None）。
    // WhyNot: 効果音の volume= と fade= を受けて捨てない — 一発の音（Out.Sound）は名前しか運べず、音量はバスが決める。黙って捨てると書いた人が効いたと思う。
    def misuseOf(ch: Channel, hasVolume: Bool, hasFade: Bool, hasWait: Bool): Option[String] = match ch {
        case Channel.Se  => if (hasVolume or hasFade) Some("効果音に volume= と fade= は書けない（音量は novel.mixer.json のバスが決める）") else None
        case Channel.All => if (hasVolume or hasWait) Some("all off に書けるのは fade= だけ") else None
        case _           => if (hasWait) Some("wait=true は効果音（se）だけ") else None
    }

    /// 効果音 name を鳴らす: 音を 1 回、Doc の lockSeconds の間は押しても送らない、wait なら音の長さだけ続きを待つ。
    /// 長さが読めない音は待たない（読めないことは読み込みの時に Controls.loadSoundSeconds が 1 回知らせる）。
    // WhyNot: ここで知らせない — apply はロード・戻る・ノードの頭の舞台づくりでも何度も当て直すので、同じ 1 行が流れ続ける。
    def playSe(ctx: Ctx, name: String, wait: Bool, st: Stage.Stage): (Stage.Stage, List[Out]) =
        let locked = MixerDoc.lockOf(name, ctx#res#mixerExtras)
            |> Option.map(secs -> { props = PropertyTween.trigger(Stage.textLockKey(), ctx#now, 0.0, secs, st#props) | st }) |> Option.getWithDefault(st);
        let waits = match (wait, Map.get(name, ctx#res#soundSeconds)) {
            case (false, _)        => Nil
            case (true, Some(secs)) => Out.Wait(secs) :: Nil
            case (true, None)      => Nil
        };
        (locked, Out.Sound(name) :: waits)

    def audio(): Command[Stage.Stage] =
        let channel = Param.choice("channel", "ambience" :: "bgm" :: "se" :: "all" :: Nil) |> Param.at(1) |> Param.required;
        let sound = Param.name("sound", sounds()) |> Param.list |> Param.orWords("off" :: Nil) |> Param.at(2) |> Param.required;
        let volume = Param.num("volume", 0.0, 1.0) |> Param.orNames(DocRef.Keys("../novel.mixer.json", "volumes") :: Nil);
        let fade = Param.num("fade", 0.0, 30.0);
        let wait = Param.flag("wait");
        { spec = YarnCommands.spec("audio", "環境音（ambience。, で重ねる）・音楽（bgm）を替える・止める、効果音を 1 回鳴らす（se。wait = 音の長さだけ待つ）、all off で環境音と音楽を止める（volume = 数か novel.mixer.json の volumes の名前・fade = 秒）",
                                   Param.erase(channel) :: Param.erase(sound) :: Param.erase(volume) :: Param.erase(fade) :: Param.erase(wait) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> {
              let ch = channelOf(Param.get(channel, a));
              let secs = Param.getOpt(fade, a) |> Option.getWithDefault(0.0);
              let level = match Param.getOpt(volume, a) {
                  case None                => Ok(1.0)
                  case Some(Or.Value(v))   => Ok(v)
                  case Some(Or.Word(name)) => MixerDoc.volumeOf(name, ctx#res#mixerExtras) |> Option.toOk("知らない音量 '${name}'")
              };
              let misuse = misuseOf(ch, Option.nonEmpty(Param.getOpt(volume, a)), Option.nonEmpty(Param.getOpt(fade, a)), Option.nonEmpty(Param.getOpt(wait, a)));
              match (ch, Param.get(sound, a), level) {
                  case _ if Option.nonEmpty(misuse)        => Err(Option.getWithDefault("", misuse))
                  case (_, _, Err(why))                    => Err(why)
                  case (Channel.Se, Or.Value(name :: Nil), _) => Ok(playSe(ctx, name, Param.getOpt(wait, a) == Some(true), st))
                  case (Channel.Se, Or.Value(_), _)        => Err("効果音は 1 つずつ鳴らす")
                  case (Channel.Se, Or.Word(_), _)         => Err("効果音は止められない（off は ambience・bgm・all）")
                  case (Channel.All, Or.Word(_), _)        =>
                      let off = (cur, c) -> sustainedKeys(c) |> Option.map(k -> withSustained(ctx#now, k, None, 0.0, secs, cur)) |> Option.getWithDefault(cur);
                      Ok((off(off(st, Channel.Ambience), Channel.Bgm), Nil))
                  case (Channel.All, Or.Value(_), _)       => Err("all に書けるのは off だけ")
                  case (c, Or.Value(names), Ok(v))         =>
                      let joined = String.intercalate(",", names);
                      Ok((sustainedKeys(c) |> Option.map(k -> withSustained(ctx#now, k, Some(joined), v, secs, st)) |> Option.getWithDefault(st), Nil))
                  case (c, Or.Word(_), _)                  =>
                      Ok((sustainedKeys(c) |> Option.map(k -> withSustained(ctx#now, k, None, 0.0, secs, st)) |> Option.getWithDefault(st), Nil))
              }
          },
          needs = (_, a, _) -> match (channelOf(Param.get(channel, a)), Param.get(sound, a)) {
              case (Channel.Ambience, Or.Value(names)) => names
              case (Channel.Bgm, Or.Value(names))      => names
              case _                                   => Nil
          } }

    def fx(): Command[Stage.Stage] =
        let name = Param.name("name", DocRef.Keys("../novel.effects.json", "particles") :: Nil) |> Param.orWords("off" :: Nil) |> Param.at(1) |> Param.required;
        let once = Param.flag("once");
        let on = Param.marker("on", markers());
        { spec = YarnCommands.spec("fx", "画面の粒の演出（novel.effects.json の particles）を出す・止める（once = Doc の onceSeconds だけ一度出す・on = novel.cast.json の markers の点から出す）",
                                   Param.erase(name) :: Param.erase(once) :: Param.erase(on) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> {
              let point = Param.getOpt(on, a);
              let missing = point |> Option.filter(match (n, p) -> Option.isEmpty(CastDoc.markerOf(n, p, ctx#res#cast)));
              match (Param.get(name, a), missing) {
                  case (_, Some((n, p)))   => Err("'${n}' に点 '${p}' が無い（novel.cast.json の markers）")
                  case (Or.Value(n), None) => applyEffect(ctx, n, Param.getOpt(once, a) == Some(true), point |> Option.map(match (x, p) -> "${x}.${p}"), st)
                  case (Or.Word(_), None)  =>
                      if (Option.nonEmpty(point) or Option.nonEmpty(Param.getOpt(once, a))) Err("off に once= と on= は書けない")
                      else Ok((Stage.withParticles(ctx#now, None, None, st), Nil))
              }
          },
          needs = noAssets }

    /// 粒の演出 n を出す（once なら Doc の onceSeconds だけ一度・そうでなければ止めるまで。at = 出す点「絵.点」・None は画面に広げる）。
    def applyEffect(ctx: Ctx, n: String, once: Bool, at: Option[String], st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        match EffectsDoc.particleOf(n, ctx#res#effects) {
            case None => Err("知らない粒の演出 '${n}'")
            case Some(p) if Option.nonEmpty(at) and not EffectsDoc.isPointed(p#look) =>
                Err("'${n}' は画面に広げる粒なので点から出せない（点から出せるのは look が puff の粒）")
            case Some(p) =>
                if (once) {
                    let props = PropertyTween.setName(Stage.fxOnceAtKey(n), at, ctx#now, 0.0, st#props);
                    Ok(({ props = PropertyTween.trigger(Stage.fxOnceKey(n), ctx#now, 0.0, p#onceSeconds, props) | st }, Nil))
                }
                else Ok((Stage.withParticles(ctx#now, Some(n), at, st), Nil))
        }

    def shake(): Command[Stage.Stage] =
        let strength = Param.num("strength", 0.0, 80.0) |> Param.orNames(DocRef.Keys("../novel.kind.json", "shakes") :: Nil) |> Param.at(1);
        let on = Param.name("on", castNames()) |> Param.orWords("screen" :: "window" :: Nil);
        let time = Param.num("time", 0.0, 10.0);
        { spec = YarnCommands.spec("shake", "揺らす（強さ = novel.kind.json の shakes の名前か px・省くと shakeSeconds / shakePx。on = screen（既定）・window・絵の名前）",
                                   Param.erase(strength) :: Param.erase(on) :: Param.erase(time) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let kind = ctx#res#kind;
              let named = (name: String) -> Map.get(name, KindDoc.rec(kind)#shakes) |> Option.toOk("知らない揺れの強さ '${name}'");
              let base = match Param.getOpt(strength, a) {
                  case None                  => Ok(KindDoc.defaultShake(kind))
                  case Some(Or.Value(px))    => Ok({ px = px | KindDoc.defaultShake(kind) })
                  case Some(Or.Word(name))   => named(name)
              };
              let target = match Param.getOpt(on, a) {
                  case Some(Or.Value(name))  => Stage.ShakeTarget.Actor(name)
                  case Some(Or.Word("window")) => Stage.ShakeTarget.Window
                  case _                     => Stage.ShakeTarget.Screen
              };
              base |> Result.map(shake -> {
                  let seconds = Param.getOpt(time, a) |> Option.getWithDefault(shake#seconds);
                  (Stage.withShake(ctx#now, target, { seconds = seconds | shake }, st), Nil)
              })
          },
          needs = noAssets }

    // ── 画面の覆いとカメラ: overlay・camera ──

    def overlay(): Command[Stage.Stage] =
        let alpha = Param.num("alpha", 0.0, 1.0) |> Param.at(1) |> Param.required;
        let color = Param.name("color", Nil);
        let fromArg = Param.num("from", 0.0, 1.0);
        let place = Param.choice("layer", "stage" :: "screen" :: Nil);
        let time = Param.time(0.0);
        let ease = Param.ease(Curve.Ease.SmoothStep);
        { spec = YarnCommands.spec("overlay", "画面に色を被せる濃さを秒かけて替える（color = black・white・#rrggbb・from = 始まりの濃さ・layer = stage（world の中）か screen（文字の枠より手前））",
                                   Param.erase(alpha) :: Param.erase(color) :: Param.erase(fromArg) :: Param.erase(place) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let colorName = Param.getOpt(color, a);
              let target = Param.get(alpha, a);
              let start = KindDoc.rec(ctx#res#kind)#overlayStart;
              let now = PropertyTween.numAt(ctx#now, Stage.overlayAlphaKey(), start, st#props);
              let unchanged = Option.isEmpty(Param.getOpt(fromArg, a)) and PropertyTween.numEnd(Stage.overlayAlphaKey(), start, st#props) == target;
              if (colorName |> Option.exists(c -> Option.isEmpty(Stage.overlayColorOf(c)))) Err("知らない色 '${Option.getWithDefault("", colorName)}'（black・white・#rrggbb）")
              else {
                  let named = (key, value: Option[String], t) -> value |> Option.map(v -> PropertyTween.setName(key, Some(v), ctx#now, 0.0, t)) |> Option.getWithDefault(t);
                  let props = st#props |> named(Stage.overlayColorKey(), colorName) |> named(Stage.overlayLayerKey(), Param.getOpt(place, a));
                  let moved = if (unchanged) props
                              else PropertyTween.tween(Stage.overlayAlphaKey(), Some(Param.getOpt(fromArg, a) |> Option.getWithDefault(now)), target,
                                                       ctx#now, 0.0, Param.get(time, a), Param.get(ease, a), props);
                  Ok(({ props = moved | st }, Nil))
              }
          },
          needs = noAssets }

    def camera(): Command[Stage.Stage] =
        let zoom = Param.num("zoom", 0.1, 10.0);
        let x = Param.num("x", -3.0, 3.0);
        let y = Param.num("y", -3.0, 3.0);
        let time = Param.time(0.5);
        let ease = Param.ease(Curve.Ease.SmoothStep);
        { spec = YarnCommands.spec("camera", "world の層（背景・絵・粒）を寄せる・ずらす（zoom = 倍率・x・y = 見る所のずれ。文字の枠には掛けない）",
                                   Param.erase(zoom) :: Param.erase(x) :: Param.erase(y) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let fields = (Stage.CameraField.Zoom, zoom) :: (Stage.CameraField.X, x) :: (Stage.CameraField.Y, y) :: Nil;
              let step = (props, pair) -> {
                  let (field, h) = pair;
                  Param.getOpt(h, a) |> Option.map(v -> PropertyTween.tween(Stage.cameraKey(field), Some(Stage.cameraAt(ctx#now, field, st)), v,
                                                                           ctx#now, 0.0, Param.get(time, a), Param.get(ease, a), props))
                      |> Option.getWithDefault(props)
              };
              Ok(({ props = List.foldLeft(step, st#props, fields) | st }, Nil))
          },
          needs = noAssets }


    def tween(): Command[Stage.Stage] =
        let key = Param.name("key", Nil) |> Param.at(1) |> Param.required;
        let value = Param.num("value", -100000.0, 100000.0) |> Param.at(2) |> Param.required;
        let fromArg = Param.num("from", -100000.0, 100000.0);
        let time = Param.time(0.5);
        let ease = Param.ease(Curve.Ease.SmoothStep);
        { spec = YarnCommands.spec("tween", "ゲームの数の値を秒かけて動かす（鍵 lair.arrive は game.lair.arrive。game. は書かない。from = 始まりの値・省くと今の値から。書いたことの無い鍵は 0 から）",
                                   Param.erase(key) :: Param.erase(value) :: Param.erase(fromArg) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let name = Param.get(key, a);
              if (String.startsWith(prefix = "game.", name)) Err("鍵に game. は書かない '${name}'（lair.arrive と書くと game.lair.arrive を動かす）")
              else {
                  let k = PropertyTween.numKey("game.${name}");
                  let origin = Param.getOpt(fromArg, a) |> Option.getWithDefault(PropertyTween.numAt(ctx#now, k, 0.0, st#props));
                  Ok(({ props = PropertyTween.tween(k, Some(origin), Param.get(value, a), ctx#now, 0.0, Param.get(time, a), Param.get(ease, a), st#props) | st }, Nil))
              }
          },
          needs = noAssets }

    // ── 名前付きの絵（立ち絵と小物）: show・hide・move ──

    /// from= / to= の端。
    enum Edge with Eq {
        case Left
        case Right
        case Top
        case Bottom
    }

    def edgeNames(): List[String] = "left" :: "right" :: "top" :: "bottom" :: Nil

    def edgeOf(name: String): Option[Edge] = match name {
        case "left"   => Some(Edge.Left)
        case "right"  => Some(Edge.Right)
        case "top"    => Some(Edge.Top)
        case "bottom" => Some(Edge.Bottom)
        case _        => None
    }

    /// 端へ滑る値と向き（左と上が負）。
    def edgeAxisOf(edge: Edge): (Stage.ActorField, Float64) = match edge {
        case Edge.Left   => (Stage.ActorField.X, -1.0)
        case Edge.Right  => (Stage.ActorField.X, 1.0)
        case Edge.Top    => (Stage.ActorField.Y, -1.0)
        case Edge.Bottom => (Stage.ActorField.Y, 1.0)
    }

    /// 名前付きの絵 1 つの動き: targets = 着く値（書いた値だけ）、from / to = 端から出る・端へ出る、seconds / ease = 動く秒と曲線。
    type alias Motion = { targets = Map[Stage.ActorField, Float64], fromEdge = Option[Edge], toEdge = Option[Edge], seconds = Float64, ease = Curve.Ease }

    /// name の actor.<名>.* を motion のとおりに now から動かす。着く値は書いた値か今の終わりの値で、to の向きの値はそこから slideDistance だけ先、
    /// from の向きの値はそこから slideDistance だけ手前（端の側）から、ほかの値は now の値から動き出す。どれも替わらない値は書かない。
    // WhyNot: 動き出す値を PropertyTween に任せない（origin = None）— 出し直しで既定へ戻した値は now に始まる予定なので、同じ now の tween が捨てて前の値から動く。
    def withMotion(now: Clock.Time[Stage.Story], distance: Float64, name: String, motion: Motion, st: Stage.Stage): Stage.Stage =
        let offsetOn = (edge: Option[Edge], field) -> edge |> Option.map(edgeAxisOf) |> Option.filter(match (f, _) -> f == field)
            |> Option.map(match (_, sign) -> sign * distance);
        let step = (cur: Stage.Stage, field) -> {
            let base = Map.get(field, motion#targets) |> Option.getWithDefault(Stage.actorEnd(name, field, cur));
            let toward = offsetOn(motion#toEdge, field);
            let away = offsetOn(motion#fromEdge, field);
            if (Option.isEmpty(toward) and Option.isEmpty(away) and not Map.memberOf(field, motion#targets)) cur
            else {
                let dest = base + Option.getWithDefault(0.0, toward);
                let key = Stage.actorKey(name, field);
                let origin = away |> Option.map(o -> base + o) |> Option.getWithDefault(PropertyTween.numAt(now, key, Stage.actorDefaultOf(field), cur#props));
                { props = PropertyTween.tween(key, Some(origin), dest, now, 0.0, motion#seconds, motion#ease, cur#props) | cur }
            }
        };
        Stage.actorFields() |> List.foldLeft(step, st)

    /// cues を層に当てる。出ていなかった絵を出す時は、その絵の actor.<名>.* を先に既定へ戻す。
    def withCast(now: Clock.Time[Stage.Story], cues: List[Cast.Cue], st: Stage.Stage): Stage.Stage =
        let one = (cur: Stage.Stage, cue) -> {
            let fresh = Cast.targetOf(cue, cur#cast) |> Option.exists(match (_, figure) -> not Cast.isShown(figure#name, cur#cast));
            let reset = Cast.targetOf(cue, cur#cast) |> Option.filter(_ -> fresh)
                |> Option.map(match (_, figure) -> Stage.withActorReset(now, figure#name, cur)) |> Option.getWithDefault(cur);
            { cast = Cast.apply(now, cue, reset#cast) | reset }
        };
        List.foldLeft(one, st, cues)

    def show(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.at(1) |> Param.required;
        let face = Param.name("face", faces()) |> Param.scopedBy("name") |> Param.at(2);
        let slot = Param.name("at", slots());
        let fromArg = Param.choice("from", edgeNames());
        let x = Param.num("x", -3.0, 3.0);
        let y = Param.num("y", -3.0, 3.0);
        let scale = Param.num("scale", 0.0, 10.0);
        let alpha = Param.num("alpha", 0.0, 1.0);
        let time = Param.num("time", 0.0, 10.0);
        let ease = easeParam();
        let cueOf = (res: Res.Res, a) -> Cast.showCue(res#cast, Param.get(who, a), Param.getOpt(face, a), Param.getOpt(slot, a), Param.getOpt(time, a))
            |> Result.map(withEaseOf(easeArg(ease, a)));
        let targetsOf = a -> ((Stage.ActorField.X, x) :: (Stage.ActorField.Y, y) :: (Stage.ActorField.Scale, scale) :: (Stage.ActorField.Alpha, alpha) :: Nil)
            |> List.filterMap(match (f, h) -> Param.getOpt(h, a) |> Option.map(v -> (f, v))) |> List.toMap;
        { spec = YarnCommands.spec("show", "立ち絵か小物を出す・表情や位置を替える（time を省くと novel.cast.json の fadeSeconds。from = 端から滑って出る・x〜alpha = 置き場所からのずれと倍率・ease = 濃さと動きの曲線。省くと濃さは fadeEase）",
                                   Param.erase(who) :: Param.erase(face) :: Param.erase(slot) :: Param.erase(fromArg) :: Param.erase(x) :: Param.erase(y) ::
                                   Param.erase(scale) :: Param.erase(alpha) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> cueOf(ctx#res, a) |> Result.map(cue -> {
              let d = CastDoc.rec(ctx#res#cast);
              let motion = { targets = targetsOf(a), fromEdge = Param.getOpt(fromArg, a) |> Option.flatMap(edgeOf), toEdge = None,
                             seconds = Param.getOpt(time, a) |> Option.getWithDefault(d#fadeSeconds), ease = easeArg(ease, a) |> Option.getWithDefault(Curve.Ease.SmoothStep) };
              (withMotion(ctx#now, d#slideDistance, Param.get(who, a), motion, withCast(ctx#now, cue :: Nil, st)), Nil)
          }),
          needs = (res, a, st) -> cueOf(res, a) |> Result.toOption |> Option.flatMap(cue -> Cast.targetOf(cue, st#cast))
              |> Option.map(match (_, figure) -> Cast.textureOf(figure)) |> Option.toList }

    def hide(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.orWords("all" :: Nil) |> Param.at(1) |> Param.oneOf("target");
        let slot = Param.name("at", slots()) |> Param.oneOf("target");
        let toArg = Param.choice("to", edgeNames());
        let time = Param.num("time", 0.0, 10.0);
        let ease = easeParam();
        { spec = YarnCommands.spec("hide", "立ち絵か小物を消す（all = 全部・at= = その位置に出ている物・to = 端へ滑って消える・ease = 濃さと動きの曲線。省くと濃さは novel.cast.json の fadeEase）",
                                   Param.erase(who) :: Param.erase(slot) :: Param.erase(toArg) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let doc = ctx#res#cast;
              let d = CastDoc.rec(doc);
              let seconds = Param.getOpt(time, a);
              let named = match Param.getOpt(who, a) {
                  case Some(Or.Value(name)) => Cast.hideCue(doc, name, seconds, 0.0) |> Result.map(cue -> cue :: Nil)
                  case Some(Or.Word(_))     => Ok(Cast.hideAllCues(doc, seconds))
                  case None                 => Ok(Nil)
              };
              let atSlot = Param.getOpt(slot, a) |> Option.map(s -> Cast.hideAtCues(doc, s, seconds, st#cast)) |> Option.getWithDefault(Nil);
              let motion = { targets = Map.empty(), fromEdge = None, toEdge = Param.getOpt(toArg, a) |> Option.flatMap(edgeOf),
                             seconds = Option.getWithDefault(d#fadeSeconds, seconds), ease = easeArg(ease, a) |> Option.getWithDefault(Curve.Ease.SmoothStep) };
              named |> Result.map(cues -> {
                  let all = List.append(cues, atSlot) |> List.map(withEaseOf(easeArg(ease, a)));
                  let slid = if (Option.isEmpty(motion#toEdge)) st
                             else Cast.hiddenNamesOf(all, st#cast) |> List.foldLeft((cur, name) -> withMotion(ctx#now, d#slideDistance, name, motion, cur), st);
                  (withCast(ctx#now, all, slid), Nil)
              })
          },
          needs = noAssets }

    def move(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.at(1) |> Param.required;
        let x = Param.num("x", -3.0, 3.0);
        let y = Param.num("y", -3.0, 3.0);
        let dx = Param.num("dx", -3.0, 3.0);
        let dy = Param.num("dy", -3.0, 3.0);
        let scale = Param.num("scale", 0.0, 10.0);
        let alpha = Param.num("alpha", 0.0, 1.0);
        let rotate = Param.num("rotate", -720.0, 720.0);
        let fromArg = Param.choice("from", edgeNames());
        let toArg = Param.choice("to", edgeNames());
        let time = Param.time(0.5);
        let ease = Param.ease(Curve.Ease.SmoothStep);
        let entryCue = (res: Res.Res, a, st: Stage.Stage) ->
            if (Cast.isShown(Param.get(who, a), st#cast) or Option.isEmpty(Param.getOpt(fromArg, a))) Ok(None)
            else Cast.showCue(res#cast, Param.get(who, a), None, None, Some(0.0)) |> Result.map(Some);
        let targetsOf = (a, st: Stage.Stage) -> {
            let name = Param.get(who, a);
            let relative = (field, h) -> Param.getOpt(h, a) |> Option.map(v -> Stage.actorEnd(name, field, st) + v);
            let absolute = (field: Stage.ActorField, h) -> Param.getOpt(h, a) |> Option.map(v -> (field, v));
            let moved = (field, abs, rel) -> absolute(field, abs) |> Option.withDefault(default = relative(field, rel) |> Option.map(v -> (field, v)));
            List.filterMap(o -> o, moved(Stage.ActorField.X, x, dx) :: moved(Stage.ActorField.Y, y, dy) ::
                                   absolute(Stage.ActorField.Scale, scale) :: absolute(Stage.ActorField.Alpha, alpha) :: absolute(Stage.ActorField.Rotate, rotate) :: Nil)
                |> List.toMap
        };
        let conflict = a -> if (Option.nonEmpty(Param.getOpt(x, a)) and Option.nonEmpty(Param.getOpt(dx, a))) Some("x= と dx= は一緒に書けない")
                            else if (Option.nonEmpty(Param.getOpt(y, a)) and Option.nonEmpty(Param.getOpt(dy, a))) Some("y= と dy= は一緒に書けない")
                            else None;
        { spec = YarnCommands.spec("move", "出ている絵の位置・大きさ・濃さ・傾きを秒かけて動かす（x・y = 置き場所からのずれ・dx・dy = 今の値に足す・from = 出ていない絵を端の外から出す・to = 端の外まで動かして消す）",
                                   Param.erase(who) :: Param.erase(x) :: Param.erase(y) :: Param.erase(dx) :: Param.erase(dy) :: Param.erase(scale) ::
                                   Param.erase(alpha) :: Param.erase(rotate) :: Param.erase(fromArg) :: Param.erase(toArg) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let name = Param.get(who, a);
              let doc = ctx#res#cast;
              let seconds = Param.get(time, a);
              let toEdge = Param.getOpt(toArg, a) |> Option.flatMap(edgeOf);
              match (conflict(a), entryCue(ctx#res, a, st)) {
                  case (Some(why), _) => Err(why)
                  case (None, Ok(None)) if Cast.isShown(name, st#cast) and Option.nonEmpty(Param.getOpt(fromArg, a)) =>
                      Err("'${name}' はもう出ている（from= は出ていない絵を端の外から出す時だけ）")
                  case (None, Err(why)) => Err(why)
                  case (None, Ok(None)) if not Cast.isShown(name, st#cast) => Err("'${name}' は出ていない（出すなら <<show>> か from=）")
                  case (None, Ok(entering)) =>
                      let shown = entering |> Option.map(cue -> withCast(ctx#now, cue :: Nil, st)) |> Option.getWithDefault(st);
                      let motion = { targets = targetsOf(a, shown), fromEdge = Param.getOpt(fromArg, a) |> Option.flatMap(edgeOf), toEdge = toEdge,
                                     seconds = seconds, ease = Param.get(ease, a) };
                      let moved = withMotion(ctx#now, CastDoc.rec(doc)#slideDistance, name, motion, shown);
                      let gone = toEdge |> Option.map(_ -> Cast.hideCue(doc, name, Some(0.0), seconds) |> Result.map(cue -> withCast(ctx#now, cue :: Nil, moved)))
                          |> Option.getWithDefault(Ok(moved));
                      gone |> Result.map(next -> (next, Nil))
              }
          },
          needs = (res, a, st) -> entryCue(res, a, st) |> Result.toOption |> Option.flatMap(o -> o) |> Option.flatMap(cue -> Cast.targetOf(cue, st#cast))
              |> Option.map(match (_, figure) -> Cast.textureOf(figure)) |> Option.toList }
}
