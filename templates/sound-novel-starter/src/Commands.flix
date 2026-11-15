// Commands — シナリオの演出コマンド（<<名前 引数…>>）の表と、表を引いて舞台に当てる口（純粋）。
// 1 コマンド = 引数の表（YarnCommands.Spec）+ apply 1 つ。同じ表から、実行時の読み方と bin/fge yarn build の検査が読む
// assets/talk/vocab.json の commands（make talk-vocab）の両方が出る。ゲームが足すコマンドは GameCommands.all() に書く。
//
//   <<bg 写真 [grade=時間帯] [time=秒]>>      背景を「写真」（novel.backdrops.json の photos）に替え、秒かけて重ねる（既定 1 秒）。
//                                              grade（grades）を省くと今の背景の時間帯のまま
//   <<window nvl|bottom|clear|off>>           文章を画面いっぱいに積む / 下のウィンドウに 1 行ずつ出す / NVL の頁をめくる /
//                                              文字の枠と字を消す（次の台詞・選択肢か nvl・bottom で戻る）
//   <<audio ambience 音|off>>                 鳴り続ける環境音を替える・止める（音は project.json の sounds の名前）
//   <<audio se 音>>                           効果音を 1 回
//   <<fx fireflies|off>>                      画面のパーティクルの演出
//   <<shake>>                                 画面を短く揺らす（長さと幅は novel.kind.json）
//   <<show 名前 [表情] [at=位置] [time=秒]>>  立ち絵か小物（novel.cast.json の cast / props）を出す・表情や位置を替える。
//                                              省いた物は出ている形のまま（出ていなければ Doc の face・slot）。小物は同時に 1 つ
//   <<hide 名前|all [time=秒]>> / <<hide at=位置>>   その人・全部・その位置に出ている物を消す
//
// 書き方は YarnCommands（位置の引数は 2 つまで・ほかは key=value・"…" は空白を含む 1 つの値）。
// 表に無い名前と引数の誤りは Err を返し、World が 1 行言って舞台はそのまま続ける（シナリオの書き損じで止めない）。
// 引数はシナリオを読んだ時に 1 回だけ読んで表（ArgsTable。Res が持つ）に置き、毎回の実行では読み直さない。
// apply が後に残す物は全部 Stage に書く（セーブ・settle・素材待ちが Stage だけを見て済むように）。
mod Commands {
    use fge::{Clock, Yarn, YarnCommands}
    use fge::YarnCommands.{DocRef, Param}
    use fge::YarnCommands.Param.Or

    /// apply が読める物: now = 物語の時計の今、node = 読んでいるノード（無ければ ""）、res = Doc とシナリオ。
    pub type alias Ctx = { now = Clock.Time[Stage.Story], node = String, res = Res.Res }

    /// apply が舞台の外へ出す出来事（後に残る状態は書かない）。
    ///   ClearPage = NVL の頁をめくる / TurnPage = ADV の頁を送る / Sound(名前) = 効果音を 1 回（project.json の sounds）/
    ///   Event(名前) = その場の音や見た目の合図だけ（World.Event.Signal になる）。
    pub enum Out with Eq, ToString {
        case ClearPage
        case TurnPage
        case Sound(String)
        case Event(String)
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
        bg() :: window() :: audio() :: fx() :: shake() :: show() :: hide() :: Nil

    /// シナリオが使える全部（テンプレートの表とゲームの表）。
    def table(): List[Command[Stage.Stage]] = List.append(all(), GameCommands.all())

    /// vocab.json の commands に書く表。
    pub def specs(): List[YarnCommands.Spec] = table() |> List.map(c -> c#spec)

    def lookup(name: String): Option[Command[Stage.Stage]] = table() |> List.find(c -> YarnCommands.nameOf(c#spec) == name)

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
        forM (c <- lookup(command#name); args <- argsOf(res#commandArgs, c, command) |> Result.toOption) yield (c, args)

    // ── 表を引く ──

    /// command を表で読んで st に当てる。Silent の時は Sound と Event を落とす。
    pub def execute(replay: Replay, ctx: Ctx, command: Yarn.Command, st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        let at = " (${Yarn.sourceText(command#source)})";
        forM (
            c <- lookup(command#name) |> Option.toOk("知らないコマンド <<${command#name}>>${at}");
            args <- argsOf(ctx#res#commandArgs, c, command);
            done <- c#apply(ctx, args, st) |> Result.mapErr(why -> "<<${command#name}>> ${why}${at}")
        ) yield {
            let (next, outs) = done;
            (next, outs |> List.filter(out -> replay == Replay.Live or isPageOut(out)))
        }

    def isPageOut(out: Out): Bool = match out {
        case Out.ClearPage => true
        case Out.TurnPage  => true
        case Out.Sound(_)  => false
        case Out.Event(_)  => false
    }

    /// command が時間を取る演出か（読めないコマンドは Instant）。
    pub def timingOf(res: Res.Res, command: Yarn.Command): Timing =
        parsed(res, command) |> Option.map(match (c, _) -> c#timing) |> Option.getWithDefault(Timing.Instant)

    /// command を st に当てる前に届いていてほしい絵と音の名前（読めないコマンドは空）。
    pub def needsOf(res: Res.Res, command: Yarn.Command, st: Stage.Stage): List[String] =
        parsed(res, command) |> Option.map(match (c, args) -> c#needs(res, args, st)) |> Option.getWithDefault(Nil)

    // ── Doc の名前の場所（vocab.json のフォルダ assets/talk から数える） ──

    def backdrops(path: String): DocRef = DocRef.Keys("../novel.backdrops.json", path)

    def castNames(): List[DocRef] = DocRef.Keys("../novel.cast.json", "cast") :: DocRef.Keys("../novel.cast.json", "props") :: Nil

    def slots(): List[DocRef] = DocRef.Keys("../novel.cast.json", "slots") :: Nil

    def sounds(): List[DocRef] = DocRef.Path("../../project.json", "sounds[].name") :: Nil

    // ── コマンド ──

    def bg(): Command[Stage.Stage] =
        let photo = Param.name("photo", backdrops("photos") :: Nil) |> Param.at(1) |> Param.required;
        let grade = Param.name("grade", backdrops("grades") :: Nil);
        let time = Param.time(1.0);
        let gradeOf = (a, st: Stage.Stage) -> Param.getOpt(grade, a) |> Option.withDefault(default = st#shot |> Option.map(s -> s#grade));
        { spec = YarnCommands.spec("bg", "背景の写真を時間帯の色で替え、秒かけて重ねる",
                                   Param.erase(photo) :: Param.erase(grade) :: Param.erase(time) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let doc = ctx#res#backdrops;
              let name = Param.get(photo, a);
              match gradeOf(a, st) {
                  case None => Err("grade= が要る（前の背景が無い）")
                  case Some(g) =>
                      if (Option.isEmpty(BackdropDoc.photoOf(name, doc))) Err("知らない写真 '${name}'")
                      else if (Option.isEmpty(BackdropDoc.gradeOf(g, doc))) Err("知らない時間帯 '${g}'")
                      else {
                          let next = Stage.withBackdrop(ctx#now, { photo = name, grade = g }, Param.get(time, a), st);
                          // WhyNot: NVL の頁を背景の切り替えでめくらない — NVL の頁の切れ目は <<window clear>> と行の数が決める。
                          Ok((next, if (st#mode == Stage.Mode.Adv) Out.TurnPage :: Nil else Nil))
                      }
              }
          },
          needs = (res, a, _) -> BackdropDoc.textureOf(Param.get(photo, a), res#backdrops) |> Option.toList }

    def window(): Command[Stage.Stage] =
        let mode = Param.choice("mode", "nvl" :: "bottom" :: "clear" :: "off" :: Nil) |> Param.at(1) |> Param.required;
        let toMode = (now, m, st: Stage.Stage) -> (Stage.withWindowShown(now, { mode = m | st }), if (m == st#mode) Nil else Out.ClearPage :: Nil);
        { spec = YarnCommands.spec("window", "文字の出し方を替える（nvl = 画面いっぱい・bottom = 下のウィンドウ）・NVL の頁をめくる（clear）・文字の枠と字を消す（off。次の台詞で戻る）",
                                   Param.erase(mode) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> match Param.get(mode, a) {
              case "nvl"    => Ok(toMode(ctx#now, Stage.Mode.Nvl, st))
              case "bottom" => Ok(toMode(ctx#now, Stage.Mode.Adv, st))
              case "off"    => Ok((Stage.withWindowHidden(ctx#now, true, st), Nil))
              case _        => Ok((st, Out.ClearPage :: Nil))
          },
          needs = noAssets }

    /// audio のチャンネル: 鳴り続ける環境音。
    def ambience(): String = "ambience"

    /// audio のチャンネル: 一発の効果音。
    def se(): String = "se"

    def audio(): Command[Stage.Stage] =
        let channel = Param.choice("channel", ambience() :: se() :: Nil) |> Param.at(1) |> Param.required;
        let sound = Param.name("sound", sounds()) |> Param.orWords("off" :: Nil) |> Param.at(2) |> Param.required;
        { spec = YarnCommands.spec("audio", "環境音を替える・止める（ambience）・効果音を 1 回鳴らす（se）",
                                   Param.erase(channel) :: Param.erase(sound) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> match (Param.get(channel, a), Param.get(sound, a)) {
              case (c, Or.Value(name)) if c == ambience() => Ok((Stage.withAmbience(ctx#now, Some(name), st), Nil))
              case (c, Or.Word(_)) if c == ambience()     => Ok((Stage.withAmbience(ctx#now, None, st), Nil))
              case (_, Or.Value(name))                    => Ok((st, Out.Sound(name) :: Nil))
              case (_, Or.Word(_))                        => Err("効果音は止められない（off は ambience だけ）")
          },
          needs = (_, a, _) -> match (Param.get(channel, a), Param.get(sound, a)) {
              case (c, Or.Value(name)) if c == ambience() => name :: Nil
              case _                                      => Nil
          } }

    def fx(): Command[Stage.Stage] =
        let name = Param.choice("name", Stage.particleNames()) |> Param.orWords("off" :: Nil) |> Param.at(1) |> Param.required;
        { spec = YarnCommands.spec("fx", "画面のパーティクルの演出を出す・止める", Param.erase(name) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> match Param.get(name, a) {
              case Or.Value(n) => Ok((Stage.withParticles(ctx#now, Some(n), st), Nil))
              case Or.Word(_)  => Ok((Stage.withParticles(ctx#now, None, st), Nil))
          },
          needs = noAssets }

    def shake(): Command[Stage.Stage] =
        { spec = YarnCommands.spec("shake", "画面を短く揺らす（長さと幅は novel.kind.json）", Nil),
          timing = Timing.Timed,
          apply = (ctx, _, st) -> {
              let seconds = KindDoc.rec(ctx#res#kind)#shakeSeconds;
              Ok(({ props = PropertyTween.trigger(Stage.shakeKey(), ctx#now, 0.0, seconds, st#props) | st }, Nil))
          },
          needs = noAssets }

    def show(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.at(1) |> Param.required;
        let face = Param.name("face", Nil) |> Param.at(2);
        let slot = Param.name("at", slots());
        let time = Param.num("time", 0.0, 10.0);
        let cueOf = (res: Res.Res, a) -> Cast.showCue(res#cast, Param.get(who, a), Param.getOpt(face, a), Param.getOpt(slot, a), Param.getOpt(time, a));
        { spec = YarnCommands.spec("show", "立ち絵か小物を出す・表情や位置を替える（time を省くと novel.cast.json の fadeSeconds）",
                                   Param.erase(who) :: Param.erase(face) :: Param.erase(slot) :: Param.erase(time) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> cueOf(ctx#res, a) |> Result.map(cue -> (withCast(ctx#now, cue :: Nil, st), Nil)),
          needs = (res, a, st) -> cueOf(res, a) |> Result.toOption |> Option.flatMap(cue -> Cast.targetOf(cue, st#cast))
              |> Option.map(match (_, figure) -> Cast.textureOf(figure)) |> Option.toList }

    def hide(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.orWords("all" :: Nil) |> Param.at(1) |> Param.oneOf("target");
        let slot = Param.name("at", slots()) |> Param.oneOf("target");
        let time = Param.num("time", 0.0, 10.0);
        { spec = YarnCommands.spec("hide", "立ち絵か小物を消す（all = 全部・at= = その位置に出ている物）",
                                   Param.erase(who) :: Param.erase(slot) :: Param.erase(time) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let doc = ctx#res#cast;
              let seconds = Param.getOpt(time, a);
              let named = match Param.getOpt(who, a) {
                  case Some(Or.Value(name)) => Cast.hideCue(doc, name, seconds) |> Result.map(cue -> cue :: Nil)
                  case Some(Or.Word(_))     => Ok(Cast.hideAllCues(doc, seconds))
                  case None                 => Ok(Nil)
              };
              let atSlot = Param.getOpt(slot, a) |> Option.map(s -> Cast.hideAtCues(doc, s, seconds, st#cast)) |> Option.getWithDefault(Nil);
              named |> Result.map(cues -> (withCast(ctx#now, List.append(cues, atSlot), st), Nil))
          },
          needs = noAssets }

    def withCast(now: Clock.Time[Stage.Story], cues: List[Cast.Cue], st: Stage.Stage): Stage.Stage =
        { cast = cues |> List.foldLeft((layer, cue) -> Cast.apply(now, cue, layer), st#cast) | st }
}
