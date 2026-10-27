// Stage — 舞台（背景・文章の出し方・環境音・粒の演出・揺れ）の状態と、シナリオのコマンドからの畳み方（純粋）。
// シナリオに書けるコマンド（Talk の語彙。check は名前だけを見るので、引数はここが読む）:
//
//   <<bg 写真 時間帯 秒>>   背景を「写真」（BackdropDoc の photos）に「時間帯」（grades）の色で替え、秒かけて重ねる。秒は省ける（1 秒）
//   <<nvl>> / <<adv>>       文章を画面いっぱいに積む / 下の窓に 1 行ずつ出す
//   <<clear>>               NVL の頁をめくる（ADV では何もしない）
//   <<ambience 名>>         鳴り続ける環境音を amb_<名> に替える（off で止める）
//   <<se 名>>               効果音 se_<名> を 1 回（音は World が出来事にして鳴らす）
//   <<fx 名>>               画面の粒の演出（fireflies / off）
//   <<shake>>               画面を短く揺らす
//
// 引数の読めないコマンドは Err で返し、World が 1 行知らせて舞台はそのまま続ける（シナリオの書き損じで止めない）。
// セーブから戻る時は YarnRunner.resume が通ったコマンドを全部返すので、同じ applyCue で畳んでから settle で
// 演出の途中を終わりの形にする（背景は重ね終わり・揺れは止まる）。
mod Stage {
    use fge::{Clock, Vec2, Yarn}

    /// 文章の出し方。Nvl = 画面いっぱいに積む（小説の頁）、Adv = 下の窓に 1 行ずつ。
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
    }

    /// 舞台。shot = 今の背景、under = 重ねている間だけ下に残す前の背景、fadeFrom / fadeSeconds = 重ね始めた時刻と長さ、
    /// mode = 文章の出し方、ambience = 鳴り続ける環境音の名前、particles = 粒の演出の名前、shakeFrom = 揺れ始めた時刻。
    pub type alias Stage = {
        shot = Option[Shot],
        under = Option[Shot],
        fadeFrom = Clock.Time[World.Story],
        fadeSeconds = Float64,
        mode = Mode,
        ambience = Option[String],
        particles = Option[String],
        shakeFrom = Option[Clock.Time[World.Story]]
    }

    /// 物語を始める前の舞台（背景なし・NVL・音なし）。
    pub def empty(): Stage =
        { shot = None, under = None, fadeFrom = Clock.never(), fadeSeconds = 0.0, mode = Mode.Nvl,
          ambience = None, particles = None, shakeFrom = None }

    /// Talk の語彙に載せるコマンドの名前（wait はエンジンが読むので入れない）。
    pub def commandNames(): List[String] =
        "bg" :: "nvl" :: "adv" :: "clear" :: "ambience" :: "se" :: "fx" :: "shake" :: Nil

    /// 粒の演出の名前（<<fx 名>> に書ける物）。
    pub def particleNames(): List[String] = "fireflies" :: Nil

    /// コマンドの意味を読む。写真・時間帯の名前は backdrops にあるかまで見る（無い名前で背景が消えないように）。
    pub def cueOf(backdrops: BackdropDoc.Doc, command: Yarn.Command): Result[String, Cue] =
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
                else Err("知らない粒の演出 '${name}'${at}")
            case ("shake", _)           => Ok(Cue.Shake)
            case (name, _)              => Err("<<${name}>> の引数が足りない${at}")
        }

    /// コマンド 1 つを舞台に畳む（now = 物語の時計の今）。Clear と Se は舞台を変えない（頁と音は World が持つ）。
    pub def applyCue(now: Clock.Time[World.Story], cue: Cue, stage: Stage): Stage = match cue {
        case Cue.Backdrop(shot, seconds) =>
            { shot = Some(shot), under = stage#shot, fadeFrom = now, fadeSeconds = seconds | stage }
        case Cue.ToMode(mode)       => { mode = mode | stage }
        case Cue.Ambience(name)     => { ambience = name | stage }
        case Cue.Particles(name)    => { particles = name | stage }
        case Cue.Shake              => { shakeFrom = Some(now) | stage }
        case Cue.Clear              => stage
        case Cue.Se(_)              => stage
    }

    /// 演出の途中を終わりの形にする（セーブから戻った時・描き出しで場面を作る時）。
    pub def settle(stage: Stage): Stage =
        { under = None, fadeFrom = Clock.never(), shakeFrom = None | stage }

    /// 背景の重ねの進み（0〜1。秒が 0 なら 1）。
    pub def fadeProgress(now: Clock.Time[World.Story], stage: Stage): Float64 =
        if (stage#fadeSeconds <= 0.0) 1.0
        else Float64.max(0.0, Float64.min(1.0, Clock.since(stage#fadeFrom, now) / stage#fadeSeconds))

    /// 揺れのずれ（px）。揺れの長さと幅は novel.kind.json。だんだん収まる。
    pub def shakeOffset(now: Clock.Time[World.Story], seconds: Float64, px: Float64, stage: Stage): (Float64, Float64) =
        match stage#shakeFrom {
            case None       => (0.0, 0.0)
            case Some(start) =>
                let t = Clock.since(start, now);
                if (t < 0.0 or t >= seconds or seconds <= 0.0) (0.0, 0.0)
                else {
                    let left = 1.0 - t / seconds;
                    (Vec2.sin(t * 71.0) * px * left, Vec2.cos(t * 53.0) * px * 0.5 * left)
                }
        }
}
