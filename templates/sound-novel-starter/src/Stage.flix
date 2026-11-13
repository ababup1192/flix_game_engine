// Stage — 舞台（背景・文章の出し方・環境音・パーティクルの演出・揺れ）の状態と、シナリオのコマンドからの反映のし方（純粋）。
// シナリオに書けるコマンド（Talk の語彙。check は名前だけを見るので、引数はここが読む）:
//
//   <<bg 写真 時間帯 秒>>   背景を「写真」（BackdropDoc の photos）に「時間帯」（grades）の色で替え、秒かけて重ねる。秒は省ける（1 秒）
//   <<nvl>> / <<adv>>       文章を画面いっぱいに積む / 下のウィンドウに 1 行ずつ出す
//   <<clear>>               NVL の頁をめくる（ADV では何もしない）
//   <<ambience 名>>         鳴り続ける環境音を amb_<名> に替える（off で止める）
//   <<se 名>>               効果音 se_<名> を 1 回（音は World が出来事にして鳴らす）
//   <<fx 名>>               画面のパーティクルの演出（fireflies / off）
//   <<shake>>               画面を短く揺らす
//   <<char 名前 [表情] [位置] [秒]>>  立ち絵を出す・表情や位置を替える（語の順は問わない。省いた語は出ている形のまま・出ていなければ CastDoc の既定）
//   <<char 名前 off [秒]>> / <<char off [秒]>>   その人を消す / 全員消す
//   <<item 名前 [位置] [秒]>> / <<item off [秒]>>  小物を出す（前の小物と入れ替わる）/ 消す（読み方と重ね方は Cast）
//
// 引数の読めないコマンドは Err で返し、World が 1 行知らせて舞台はそのまま続ける（シナリオの書き損じで止めない）。
// セーブから戻る時は YarnRunner.resume が通ったコマンドを全部返すので、同じ applyCue で反映してから settle で
// 演出の途中を終わりの形にする（背景は重ね終わり・揺れは止まる）。
mod Stage {
    use fge::{Clock, Num, Vec2, Yarn}

    /// 物語の時計の名前（中身は要らない）。文字送り・<<wait>>・背景の重ね・揺れが使い、画面や確認のウィンドウを開くと止まる。
    pub enum Story

    /// 文章の出し方。Nvl = 画面いっぱいに積む（小説の頁）、Adv = 下のウィンドウに 1 行ずつ。
    pub enum Mode with Eq, ToString {
        case Nvl
        case Adv
    }

    /// 背景 1 枚（写真と時間帯の名前）。
    pub type alias Shot = { photo = String, grade = String }

    /// コマンド 1 つの意味。
    pub enum Cue {
        case Backdrop(Shot, Float64)
        case ToMode(Mode)
        case Clear
        case Ambience(Option[String])
        case Se(String)
        case Particles(Option[String])
        case Shake
        case Cast(Cast.Cue)
    }

    /// 舞台。shot = 今の背景、under = 重ねている間だけ下に残す前の背景、fadeFrom / fadeSeconds = 重ね始めた時刻と長さ、
    /// mode = 文章の出し方、ambience = 鳴り続ける環境音の名前、particles = パーティクルの演出の名前、shakeFrom = 揺れ始めた時刻、
    /// cast = 立ち絵と小物の層。
    pub type alias Stage = {
        shot = Option[Shot],
        under = Option[Shot],
        fadeFrom = Clock.Time[Story],
        fadeSeconds = Float64,
        mode = Mode,
        ambience = Option[String],
        particles = Option[String],
        shakeFrom = Option[Clock.Time[Story]],
        cast = Cast.Layer
    }

    /// 物語を始める前の舞台（背景なし・NVL・音なし）。
    pub def empty(): Stage =
        { shot = None, under = None, fadeFrom = Clock.never(), fadeSeconds = 0.0, mode = Mode.Nvl,
          ambience = None, particles = None, shakeFrom = None, cast = Cast.empty() }

    /// Talk の語彙に載せるコマンドの名前（wait はエンジンが読むので入れない）。
    pub def commandNames(): List[String] =
        "bg" :: "nvl" :: "adv" :: "clear" :: "ambience" :: "se" :: "fx" :: "shake" :: "char" :: "item" :: Nil

    /// 環境音の名前（<<ambience 名>> の名）→ project.json の sounds の名前。
    pub def ambienceSound(name: String): String = "amb_${name}"

    /// パーティクルの演出の名前（<<fx 名>> に書ける物）。
    pub def particleNames(): List[String] = "fireflies" :: Nil

    /// コマンドの意味を読む。写真・時間帯の名前は backdrops に、人物・小物・表情・位置の名前は cast にあるかまで見る（無い名前で舞台が消えないように）。
    pub def cueOf(res: Res.Res, command: Yarn.Command): Result[String, Cue] =
        let backdrops = res#backdrops;
        let at = " (${Yarn.sourceText(command#source)})";
        match (command#name, command#args) {
            case ("bg", photo :: grade :: rest) =>
                let seconds = match rest {
                    case text :: _ => Float64.fromString(text)
                    case Nil       => Some(1.0)
                };
                if (Option.isEmpty(BackdropDoc.photoOf(photo, backdrops))) Err("知らない写真 '${photo}'${at}")
                else if (Option.isEmpty(BackdropDoc.gradeOf(grade, backdrops))) Err("知らない時間帯 '${grade}'${at}")
                else match seconds {
                    case Some(s) => Ok(Cue.Backdrop({ photo = photo, grade = grade }, Float64.max(0.0, s)))
                    case None    => Err("<<bg>> の秒が数でない${at}")
                }
            case ("bg", _)              => Err("<<bg 写真 時間帯 秒>> の写真と時間帯が無い${at}")
            case ("nvl", _)             => Ok(Cue.ToMode(Mode.Nvl))
            case ("adv", _)             => Ok(Cue.ToMode(Mode.Adv))
            case ("clear", _)           => Ok(Cue.Clear)
            case ("ambience", "off" :: _) => Ok(Cue.Ambience(None))
            case ("ambience", name :: _) => Ok(Cue.Ambience(Some(name)))
            case ("se", name :: _)      => Ok(Cue.Se(name))
            case ("fx", "off" :: _)     => Ok(Cue.Particles(None))
            case ("fx", name :: _)      =>
                if (List.memberOf(name, particleNames())) Ok(Cue.Particles(Some(name)))
                else Err("知らないパーティクルの演出 '${name}'${at}")
            case ("shake", _)           => Ok(Cue.Shake)
            case ("char", _)            => Cast.cueOf(res#cast, command) |> Result.map(Cue.Cast)
            case ("item", _)            => Cast.cueOf(res#cast, command) |> Result.map(Cue.Cast)
            case (name, _)              => Err("<<${name}>> の引数が足りない${at}")
        }

    /// コマンド 1 つを舞台に反映する（now = 物語の時計の今）。Clear と Se は舞台を変えない（頁と音は World が持つ）。
    pub def applyCue(now: Clock.Time[Story], cue: Cue, stage: Stage): Stage = match cue {
        case Cue.Backdrop(shot, seconds) =>
            { shot = Some(shot), under = stage#shot, fadeFrom = now, fadeSeconds = seconds | stage }
        case Cue.ToMode(mode)       => { mode = mode | stage }
        case Cue.Ambience(name)     => { ambience = name | stage }
        case Cue.Particles(name)    => { particles = name | stage }
        case Cue.Shake              => { shakeFrom = Some(now) | stage }
        case Cue.Cast(c)            => { cast = Cast.apply(now, c, stage#cast) | stage }
        case Cue.Clear              => stage
        case Cue.Se(_)              => stage
    }

    /// 画面の上で時間をかけて変わる演出か（背景の重ね・揺れ・立ち絵と小物の出入り）。音・文章の出し方・頁・パーティクルは同じフレームで終わる。
    /// 付箋の台本の位置（World.talkCursorOf）は、時間を取る演出の後の <<wait>> の間だけその演出の行を指す。
    pub def hasDuration(cue: Cue): Bool = match cue {
        case Cue.Backdrop(_, _) => true
        case Cue.Shake          => true
        case Cue.Cast(_)        => true
        case Cue.ToMode(_)      => false
        case Cue.Clear          => false
        case Cue.Ambience(_)    => false
        case Cue.Se(_)          => false
        case Cue.Particles(_)   => false
    }

    /// 演出の途中を終わりの形にする（セーブから戻った時・描き出しで場面を作る時）。
    pub def settle(stage: Stage): Stage =
        { under = None, fadeFrom = Clock.never(), shakeFrom = None, cast = Cast.settle(stage#cast) | stage }

    /// 背景の重ねの進み（0〜1。秒が 0 なら 1）。
    pub def fadeProgress(now: Clock.Time[Story], stage: Stage): Float64 =
        if (stage#fadeSeconds <= 0.0) 1.0
        else Float64.max(0.0, Float64.min(1.0, Clock.since(stage#fadeFrom, now) / stage#fadeSeconds))

    /// 揺れのずれ（px）。揺れの長さと幅は novel.kind.json。だんだん収まる。
    pub def shakeOffset(now: Clock.Time[Story], seconds: Float64, px: Float64, stage: Stage): (Float64, Float64) =
        match stage#shakeFrom {
            case None       => (0.0, 0.0)
            case Some(start) =>
                let t = Clock.since(start, now);
                if (t < 0.0 or t >= seconds or seconds <= 0.0) (0.0, 0.0)
                else {
                    let left = 1.0 - t / seconds;
                    (Num.sin(t * 71.0) * px * left, Num.cos(t * 53.0) * px * 0.5 * left)
                }
        }
}
