// SceneSeq — カットの列を上から順に演じる逐次シーケンサの骨格。イベントシーンのように
// 「世界を見て尺が決まる」再生を受け持つ（Timeline は尺が既知の時刻サンプル、Replay は
// 入力固定の再生 — 分業は docs/module-index.md の進行 4 抽象を参照）。
// 何がカットで（c）、演じるとは何で（perform）、待ち時間の進捗は何か（p）は、
// ぜんぶゲーム側が注入する — だからどのゲームでも同じ書き味になる。
//
// 使い方（ゲーム側が書くのは 2 つだけ）:
//   1. perform: (cut, いままでの進捗, dt, world) -> (Status, world)
//      カット 1 つを 1 コマぶん演じる。続けるなら Running(進捗)、
//      終わったら Done、演じられないなら Skip(理由) を返す。
//   2. idle: (dt, world) -> world
//      カットが尽きたあとも世界の時間だけを流す（炎の揺らぎなどを止めない）。
//
// fail-open だが無音ではない: Skip の理由と打ち切りは notes に残り、
// 描き出し側が最後にまとめて報せる — 脚本の誤りはログで見つかる。
pub mod SceneSeq {

    /// perform が返す、カット 1 つの行方。
    pub enum Status[p] {
        /// まだ途中。進捗 p を持ち回り、次のコマも同じカットを演じる。
        case Running(p)
        /// このカットは演じ終えた。次のカットへ。
        case Done
        /// このカットは演じられない（目的地に着けない等）。理由を報せて次へ。
        case Skip(String)
    }

    /// シーンの進行状態。cuts = 残りのカット（先頭が演じている最中の 1 つ）、
    /// progress = いまのカットの進捗（None = まだ手を付けていない）、
    /// at = いま何番目のカットか（1 始まり。脚本の JSON と同じ数え方）、
    /// notes = 演じながら残した報せ（飛ばしたカットとその理由）。
    pub type alias State[c, p] = {
        cuts = List[c],
        progress = Option[p],
        at = Int32,
        notes = List[String]
    }

    /// カット→コマの対応表の 1 行。cut = 1 始まりの通し番号、
    /// frame = そのカットが始まる瞬間のコマ番号（frames の添字。frame 0 = w0）。
    pub type alias Mark = { cut = Int32, frame = Int32 }

    /// 演じ切った結果。frames = コマの列（先頭 = 始まりの姿）、
    /// marks = カットごとの始まりのコマ番号（コマ送りで「カット N へ跳ぶ」に使う）、
    /// notes = 報せ（飛ばしたカット・打ち切り。無ければ空）。
    pub type alias Played[w] = { frames = List[w], marks = List[Mark], notes = List[String] }

    /// カットの列から進行状態を作る（1 番から演じ始める）。
    pub def start(cuts: List[c]): State[c, p] =
        { cuts = cuts, progress = None, at = 1, notes = Nil }

    /// シーンがもう終わっているか。
    pub def done(s: State[c, p]): Bool =
        List.isEmpty(s#cuts)

    /// シーンを 1 コマ演じる。カットが尽きていれば idle で時間だけを流す。
    pub def tick(perform: (c, Option[p], Float64, w) -> (Status[p], w),
                 idle: (Float64, w) -> w,
                 dt: Float64, s: State[c, p], w: w): (State[c, p], w) =
        match s#cuts {
            case Nil => (s, idle(dt, w))
            case cut :: rest =>
                let (status, acted) = perform(cut, s#progress, dt, w);
                match status {
                    case Status.Running(p) => ({ progress = Some(p) | s }, acted)
                    case Status.Done       => (next(rest, s), acted)
                    case Status.Skip(why)  =>
                        ({ notes = "カット${s#at} を飛ばした: ${why}" :: s#notes
                           | next(rest, s) }, acted)
                }
        }

    /// 次のカットへ（進捗を捨て、通し番号を進める）。
    def next(rest: List[c], s: State[c, p]): State[c, p] =
        { cuts = rest, progress = None, at = s#at + 1 | s }

    /// シーンを最初から最後まで演じ、コマの列と報せを返す。
    /// maxFrames は暴走の安全弁 — 終われないカットが居ても必ず戻ってくる。
    /// 上限で切れたのか演じ切ったのかは画から区別できないので、言葉で notes に残す。
    pub def play(perform: (c, Option[p], Float64, w) -> (Status[p], w),
                 idle: (Float64, w) -> w,
                 maxFrames: Int32, dt: Float64,
                 cuts: List[c], w0: w): Played[w] =
        let (ended, frames, marks) = act(perform, idle, maxFrames, dt, start(cuts), w0, w0 :: Nil, 0, Nil);
        let notes = if (done(ended)) ended#notes
                    else "カット${ended#at} の途中、${maxFrames} コマで打ち切った"
                         + "(脚本が長すぎるか、終われないカットがある)" :: ended#notes;
        { frames = frames |> List.reverse, marks = marks |> List.reverse,
          notes = notes |> List.reverse }

    def act(perform: (c, Option[p], Float64, w) -> (Status[p], w),
            idle: (Float64, w) -> w,
            remaining: Int32, dt: Float64, s: State[c, p], w: w,
            acc: List[w], framesDone: Int32, marks: List[Mark]): (State[c, p], List[w], List[Mark]) =
        if (remaining <= 0 or done(s)) (s, acc, marks)
        else {
            // 演じているカットの番号が（Done/Skip で）進んだ瞬間だけ、対応表に 1 行足す。
            let marked = match marks {
                case head :: _ if head#cut == s#at => marks
                case _                             => { cut = s#at, frame = framesDone } :: marks
            };
            let (s2, w2) = tick(perform, idle, dt, s, w);
            act(perform, idle, remaining - 1, dt, s2, w2, w2 :: acc, framesDone + 1, marked)
        }

    /// 演じ切った終わりの姿だけ（テストの検査用）。
    pub def finalWorld(perform: (c, Option[p], Float64, w) -> (Status[p], w),
                       idle: (Float64, w) -> w,
                       maxFrames: Int32, dt: Float64, cuts: List[c], w0: w): w =
        settle(perform, idle, maxFrames, dt, start(cuts), w0)

    def settle(perform: (c, Option[p], Float64, w) -> (Status[p], w),
               idle: (Float64, w) -> w,
               remaining: Int32, dt: Float64, s: State[c, p], w: w): w =
        if (remaining <= 0 or done(s)) w
        else {
            let (s2, w2) = tick(perform, idle, dt, s, w);
            settle(perform, idle, remaining - 1, dt, s2, w2)
        }
}
