// Commands — シナリオの演出コマンド（<<名前 引数…>>）の表と、表を引いて舞台に当てる口（純粋）。
// 1 コマンド = 引数の表（YarnCommands.Spec）+ apply 1 つ。同じ表から、実行時の読み方と bin/fge yarn build の検査が読む
// assets/talk/vocab.json の commands（make talk-vocab）の両方が出る。ゲームが足すコマンドは GameCommands.all() に書く。
//
//   <<bg 写真 [grade=時間帯] [time=秒] [transition=fade|black|wipe|slide|pan|cut] [pace=walk|run] [ease=]>>
//                                              背景を「写真」（novel.backdrops.json の photos）に替え、秒かけて切り替える（既定 1 秒）。
//                                              grade（grades）を省くと今の背景の時間帯のまま・transition を省くと Doc の defaultTransition
//   <<window nvl|bottom|clear|off>>           文章を画面いっぱいに積む / 下のウィンドウに 1 行ずつ出す / NVL の頁をめくる /
//                                              文字の枠と字を消す（次の台詞・選択肢か nvl・bottom で戻る）
//   <<audio ambience|bgm 音[,音]|off [volume=] [fade=]>>   鳴り続ける環境音（, で重ねる）・音楽を替える・止める（音は project.json の sounds の名前。
//                                              volume は数か novel.mixer.json の volumes の名前）
//   <<audio se 音 [wait=true]>>               効果音を 1 回（wait は音の長さだけ続きを待つ。novel.mixer.json の lockSeconds の間は押しても送らない）
//   <<audio all off [fade=]>>                 環境音と音楽を全部止める
//   <<fx 名前|off [once=true]>>               画面の粒の演出（novel.effects.json の particles）
//   <<shake [強さ] [on=screen|window|名前] [time=秒]>>   揺らす（強さは novel.kind.json の shakes の名前か px・省くと shakeSeconds / shakePx）
//   <<overlay 濃さ [color=black|white|#rrggbb] [from=] [layer=stage|screen] [time=0] [ease=]>>   画面に色を被せる（同じ濃さへは何もしない）
//   <<camera [zoom=] [x=] [y=] [time=0.5] [ease=]>>   world の層を寄せる・ずらす（文字の枠と HUD には掛けない）
//   <<show 名前 [表情] [at=位置] [from=left|right|top|bottom] [x=] [y=] [scale=] [alpha=] [time=秒] [ease=]>>
//                                              立ち絵か小物（novel.cast.json の cast / props）を出す・表情や位置を替える。何人・何個でも出せ、
//                                              exclusive の位置にだけは 1 つ（後から出した物が前の物を消す）。省いた物は出ている形のまま
//                                              （出ていなければ Doc の face・slot）。from は端から slideDistance だけ滑って出る。x〜alpha は actor.<名>.*
//   <<hide 名前|all [to=left|right|top|bottom] [time=秒] [ease=]>> / <<hide at=位置>>   その人・全部・その位置に出ている物を消す（to は端へ滑って消える）
//   <<move 名前 [x=|dx=] [y=|dy=] [scale=] [alpha=] [rotate=] [from=] [to=] [time=0.5] [ease=smoothstep]>>
//                                              出ている絵の位置・大きさ・濃さ・傾きを時間で動かす（dx・dy は今の終わりの値に足す）。
//                                              from は出ていない絵を端の外から出し、to は端の外まで動かしてから消す
//
// 書き方は YarnCommands（位置の引数は 2 つまで・ほかは key=value・"…" は空白を含む 1 つの値）。
// 表に無い名前と引数の誤りは Err を返し、World が 1 行言って舞台はそのまま続ける（シナリオの書き損じで止めない）。
// 引数はシナリオを読んだ時に 1 回だけ読んで表（ArgsTable。Res が持つ）に置き、毎回の実行では読み直さない。
// apply が後に残す物は全部 Stage に書く（セーブ・settle・素材待ちが Stage だけを見て済むように）。
mod Commands {
    use fge::{Clock, Color, Curve, Log, Yarn, YarnCommands}
    use fge::YarnCommands.{DocRef, Param}
    use fge::YarnCommands.Param.Or

    /// apply が読める物: now = 物語の時計の今、node = 読んでいるノード（無ければ ""）、res = Doc とシナリオ。
    pub type alias Ctx = { now = Clock.Time[Stage.Story], node = String, res = Res.Res }

    /// apply が舞台の外へ出す出来事（後に残る状態は書かない）。
    ///   ClearPage = NVL の頁をめくる / TurnPage = ADV の頁を送る / Sound(名前) = 効果音を 1 回（project.json の sounds）/
    ///   Event(名前) = その場の音や見た目の合図だけ（World.Event.Signal になる）/
    ///   Wait(秒) = 物語の時計で秒だけ、続きの台詞・選択肢・コマンドを出さずに待つ（<<wait 秒>> と同じ待ち。Silent では落とす）。
    pub enum Out with Eq, ToString {
        case ClearPage
        case TurnPage
        case Sound(String)
        case Event(String)
        case Wait(Float64)
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
        bg() :: window() :: audio() :: fx() :: shake() :: overlay() :: camera() :: show() :: hide() :: move() :: Nil

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
        case Out.Wait(_)   => false
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
        let transition = Param.choice("transition", BackdropDoc.transitionNames());
        let pace = Param.choice("pace", "walk" :: "run" :: Nil);
        let ease = Param.ease(Curve.Ease.Linear);
        let gradeOf = (a, st: Stage.Stage) -> Param.getOpt(grade, a) |> Option.withDefault(default = st#shot |> Option.map(s -> s#grade));
        { spec = YarnCommands.spec("bg", "背景の写真を時間帯の色で替え、秒かけて切り替える（transition = fade・black・wipe・slide・pan・cut。省くと novel.backdrops.json の defaultTransition・pace = 3D の道筋の歩き方）",
                                   Param.erase(photo) :: Param.erase(grade) :: Param.erase(time) :: Param.erase(transition) :: Param.erase(pace) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> {
              let doc = ctx#res#backdrops;
              let name = Param.get(photo, a);
              let switch = { transition = Param.getOpt(transition, a) |> Option.flatMap(BackdropDoc.transitionOf) |> Option.getWithDefault(BackdropDoc.rec(doc)#defaultTransition),
                             ease = Param.get(ease, a),
                             pace = if (Param.getOpt(pace, a) == Some("run")) Stage.Pace.Run else Stage.Pace.Walk };
              match gradeOf(a, st) {
                  case None => Err("grade= が要る（前の背景が無い）")
                  case Some(g) =>
                      if (Option.isEmpty(BackdropDoc.photoOf(name, doc))) Err("知らない写真 '${name}'")
                      else if (Option.isEmpty(BackdropDoc.gradeOf(g, doc))) Err("知らない時間帯 '${g}'")
                      else {
                          let next = Stage.withBackdropBy(ctx#now, { photo = name, grade = g }, Param.get(time, a), switch, st);
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
    def withSustained(now: Clock.Time[Stage.Story], keys: (PropertyTween.NameKey, PropertyTween.NumKey), sound: Option[String], volume: Float64, fade: Float64,
                      st: Stage.Stage): Stage.Stage =
        let (nameKey, volumeKey) = keys;
        let props = match sound {
            case Some(_) =>
                let named = PropertyTween.setName(nameKey, sound, now, 0.0, st#props);
                if (fade > 0.0) PropertyTween.tween(volumeKey, Some(0.0), volume, now, 0.0, fade, Curve.Ease.Linear, named)
                else PropertyTween.setNum(volumeKey, volume, now, 0.0, named)
            case None =>
                if (fade > 0.0) PropertyTween.tween(volumeKey, None, 0.0, now, 0.0, fade, Curve.Ease.Linear, st#props) |> PropertyTween.setName(nameKey, None, now, fade)
                else PropertyTween.setName(nameKey, None, now, 0.0, st#props)
        };
        { props = props | st }

    /// 効果音 name を鳴らす: 音を 1 回、Doc の lockSeconds の間は押しても送らない、wait なら音の長さだけ続きを待つ。
    def playSe(ctx: Ctx, name: String, wait: Bool, st: Stage.Stage): (Stage.Stage, List[Out]) =
        let locked = MixerDoc.lockOf(name, ctx#res#sounds)
            |> Option.map(secs -> { props = PropertyTween.trigger(Stage.textLockKey(), ctx#now, 0.0, secs, st#props) | st }) |> Option.getWithDefault(st);
        let waits = match (wait, Map.get(name, ctx#res#soundSeconds)) {
            case (false, _)        => Nil
            case (true, Some(secs)) => Out.Wait(secs) :: Nil
            case (true, None)      => Log.warnThen("[stage] <<audio se ${name} wait=true>> の長さが読めないので待たない", Nil)
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
                  case Some(Or.Word(name)) => MixerDoc.volumeOf(name, ctx#res#sounds) |> Option.toOk("知らない音量 '${name}'")
              };
              match (ch, Param.get(sound, a), level) {
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
        { spec = YarnCommands.spec("fx", "画面の粒の演出（novel.effects.json の particles）を出す・止める（once = Doc の onceSeconds だけ一度出す）",
                                   Param.erase(name) :: Param.erase(once) :: Nil),
          timing = Timing.Instant,
          apply = (ctx, a, st) -> match Param.get(name, a) {
              case Or.Value(n) => withEffect(ctx, n, Param.getOpt(once, a) == Some(true), st)
              case Or.Word(_)  => Ok((Stage.withParticles(ctx#now, None, st), Nil))
          },
          needs = noAssets }

    /// 粒の演出 n を出す（once なら Doc の onceSeconds だけ一度・そうでなければ止めるまで）。
    def withEffect(ctx: Ctx, n: String, once: Bool, st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        match EffectsDoc.particleOf(n, ctx#res#effects) {
            case None    => Err("知らない粒の演出 '${n}'")
            case Some(p) =>
                if (once) Ok(({ props = PropertyTween.trigger(Stage.fxOnceKey(n), ctx#now, 0.0, p#onceSeconds, st#props) | st }, Nil))
                else Ok((Stage.withParticles(ctx#now, Some(n), st), Nil))
        }

    def shake(): Command[Stage.Stage] =
        let strength = Param.num("strength", 0.0, 200.0) |> Param.orNames(DocRef.Keys("../novel.kind.json", "shakes") :: Nil) |> Param.at(1);
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
              if (colorName |> Option.exists(c -> Option.isEmpty(colorOfName(c)))) Err("知らない色 '${Option.getWithDefault("", colorName)}'（black・white・#rrggbb）")
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

    /// overlay の色の名前（black・white・#rrggbb）の色。
    pub def colorOfName(name: String): Option[Color] = match name {
        case "black" => Some({ r = 0.0, g = 0.0, b = 0.0 })
        case "white" => Some({ r = 1.0, g = 1.0, b = 1.0 })
        case _       => Color.hex(name)
    }

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
        let face = Param.name("face", Nil) |> Param.at(2);
        let slot = Param.name("at", slots());
        let fromArg = Param.choice("from", edgeNames());
        let x = Param.num("x", -3.0, 3.0);
        let y = Param.num("y", -3.0, 3.0);
        let scale = Param.num("scale", 0.0, 10.0);
        let alpha = Param.num("alpha", 0.0, 1.0);
        let time = Param.num("time", 0.0, 10.0);
        let ease = Param.ease(Curve.Ease.SmoothStep);
        let cueOf = (res: Res.Res, a) -> Cast.showCue(res#cast, Param.get(who, a), Param.getOpt(face, a), Param.getOpt(slot, a), Param.getOpt(time, a));
        let targetsOf = a -> ((Stage.ActorField.X, x) :: (Stage.ActorField.Y, y) :: (Stage.ActorField.Scale, scale) :: (Stage.ActorField.Alpha, alpha) :: Nil)
            |> List.filterMap(match (f, h) -> Param.getOpt(h, a) |> Option.map(v -> (f, v))) |> List.toMap;
        { spec = YarnCommands.spec("show", "立ち絵か小物を出す・表情や位置を替える（time を省くと novel.cast.json の fadeSeconds。from = 端から滑って出る・x〜alpha = 置き場所からのずれと倍率）",
                                   Param.erase(who) :: Param.erase(face) :: Param.erase(slot) :: Param.erase(fromArg) :: Param.erase(x) :: Param.erase(y) ::
                                   Param.erase(scale) :: Param.erase(alpha) :: Param.erase(time) :: Param.erase(ease) :: Nil),
          timing = Timing.Timed,
          apply = (ctx, a, st) -> cueOf(ctx#res, a) |> Result.map(cue -> {
              let d = CastDoc.rec(ctx#res#cast);
              let motion = { targets = targetsOf(a), fromEdge = Param.getOpt(fromArg, a) |> Option.flatMap(edgeOf), toEdge = None,
                             seconds = Param.getOpt(time, a) |> Option.getWithDefault(d#fadeSeconds), ease = Param.get(ease, a) };
              (withMotion(ctx#now, d#slideDistance, Param.get(who, a), motion, withCast(ctx#now, cue :: Nil, st)), Nil)
          }),
          needs = (res, a, st) -> cueOf(res, a) |> Result.toOption |> Option.flatMap(cue -> Cast.targetOf(cue, st#cast))
              |> Option.map(match (_, figure) -> Cast.textureOf(figure)) |> Option.toList }

    def hide(): Command[Stage.Stage] =
        let who = Param.name("name", castNames()) |> Param.orWords("all" :: Nil) |> Param.at(1) |> Param.oneOf("target");
        let slot = Param.name("at", slots()) |> Param.oneOf("target");
        let toArg = Param.choice("to", edgeNames());
        let time = Param.num("time", 0.0, 10.0);
        let ease = Param.ease(Curve.Ease.SmoothStep);
        { spec = YarnCommands.spec("hide", "立ち絵か小物を消す（all = 全部・at= = その位置に出ている物・to = 端へ滑って消える）",
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
                             seconds = Option.getWithDefault(d#fadeSeconds, seconds), ease = Param.get(ease, a) };
              named |> Result.map(cues -> {
                  let all = List.append(cues, atSlot);
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
        // 出ていない絵を from= で出す時の意味（秒 0 で、Doc の face・slot に出す）。
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
