// Clock — 経過時間を貯めて「一定間隔で合図を出す」「残り時間を数える」を数値だけで扱う。
// タイマー用の仕組みを持ち出さなくても、貯めた秒数の足し引きだけで周期処理やカウントダウンが書ける。
// 利用例: 敵を一定間隔で湧かせる / アニメのコマを送る / 開始前の残り秒数を数える。
// 注意: 時間の管理だけで、何を動かすかには関与しない純粋な計算。
//
// ── 型で分けた時計（Clock[c] と Time[c]）──
// ゲームには進み方の違う時計が何本かある: 遊びの時計（ポーズで止まり、ヒットストップで遅くなる）・
// 実時間（ポーズの窓の点滅・雨のような背景）・曲の時計（拍に乗る演出）。どれも中身は秒の Float64 なので、
// 取り違えてもコンパイルは通り、「ポーズ中も粒が進む」「戻ると音が鳴り直す」が遊んで初めて見つかる。
// Clock[c] / Time[c] の c は時計の名前の型（ゲームが空の enum で作る。例: enum Play / enum Wall）。
// 違う時計の時刻を足す・比べる・同じ時刻表に渡すとコンパイルが止まる。
//
//   enum Play   enum Wall                         // 時計の名前（中身は要らない）
//   play: Clock.Clock[Play]  = Clock.start()
//   play = Clock.advance(runOf(w), frame#dt, w#play)   // 毎フレーム 1 回。止める理由はゲームの型
//   fx   = Lifetime.fireOn(w#play, 0.5)                // 遊びの時計で測る寿命
//   Timeline.soundsOnClock(w#play, at, tl)             // 前と今の時刻は時計が持つ（古い prev を渡せない）
//
// 時刻は時計からしか作れない（nowOf / after）。Fx.derive や Sway.wave のような周期の関数に渡すときだけ
// secondsOf で秒へ戻す（そこで時計の名前は消える）。
pub mod Clock {

    /// 反復タイマー: acc に dt を足し、interval に達したら（== も含む）1回 fire（rest に余りを残す）。
    /// 達しなければ fired=false、rest=acc+dt（貯め続ける）。
    /// 1 tick で最大1回（dt ≪ interval が前提。dt が interval を超えても 1 回だけ発火し
    /// 余りは rest に繰り越す＝脱落しない）。Timer(oneShot=false) 相当。
    pub def tick(acc: Float64, dt: Float64, interval: Float64): {fired = Bool, rest = Float64} =
        let t = acc + dt;
        if (t < interval) {fired = false, rest = t}
        else {fired = true, rest = t - interval}

    /// カウントダウン: 残り時間を dt 減らし、0 で下げ止める。Timer(oneShot=true) 相当。
    pub def countdown(remaining: Float64, dt: Float64): Float64 =
        Float64.max(0.0, remaining - dt)

    // ── 時刻 ──

    /// 時計 c で測った秒（外からは作れない。作るのは時計の nowOf / prevOf と after / never だけ）。
    enum Stamp[_: Type](Float64)

    /// 時計 c で測った時刻。
    pub type alias Time[c] = Stamp[c]

    instance Eq[Stamp[c]] {
        pub def eq(a: Stamp[c], b: Stamp[c]): Bool = secondsOf(a) == secondsOf(b)
    }

    instance Order[Stamp[c]] {
        pub def compare(a: Stamp[c], b: Stamp[c]): Comparison = secondsOf(a) <=> secondsOf(b)
    }

    instance ToString[Stamp[c]] {
        pub def toString(a: Stamp[c]): String = "${secondsOf(a)}s"
    }

    /// at から seconds 秒あとの時刻（負なら手前）。
    pub def after(seconds: Float64, at: Time[c]): Time[c] = Stamp.Stamp(secondsOf(at) + seconds)

    /// まだ起きていない出来事の時刻（どの今から見ても、演出が全部終わった過去）。
    pub def never(): Time[c] = Stamp.Stamp(-1.0e9)

    /// at から now までの秒（now が先なら負）。
    pub def since(at: Time[c], now: Time[c]): Float64 = secondsOf(now) - secondsOf(at)

    /// 秒へ戻す。周期の関数（Fx.derive・Sway.wave・Anim.frameAt）に渡すときだけ使う —— 時計の名前は消える。
    pub def secondsOf(at: Time[c]): Float64 = match at {
        case Stamp.Stamp(s) => s
    }

    // ── 時計 ──

    /// 時計 c。now = 今の時刻、prev = 前のフレームの時刻（音を鳴らす区間 (prev, now] の頭）。
    /// slow = 掛かっているヒットストップ・スロー（TimeScale の Plan と、掛けた時刻）。
    enum Ticker[_: Type]({ now = Float64, prev = Float64, slow = Option[{ at = Float64, plan = TimeScale.Plan }] })

    /// 時計 c。
    pub type alias Clock[c] = Ticker[c]

    /// このフレームの時計の進み方。r は止める理由（ゲームの型）。
    /// Running = そのまま・Scaled(k) = k 倍（説明を読む間ゆっくり 等）・Paused(r) = 止める。
    pub enum Run[r] {
        case Running
        case Scaled(Float64)
        case Paused(r)
    }

    /// 0 秒から始まる時計。
    pub def start(): Clock[c] = Ticker.Ticker({ now = 0.0, prev = 0.0, slow = None })

    /// seconds 秒から始まる時計（描き出し・テストで決まった瞬間を撮るとき。遊びの中では start を使う）。
    pub def startAt(seconds: Float64): Clock[c] = Ticker.Ticker({ now = seconds, prev = seconds, slow = None })

    /// 今の時刻。
    pub def nowOf(clock: Clock[c]): Time[c] = match clock {
        case Ticker.Ticker(r) => Stamp.Stamp(r#now)
    }

    /// 前のフレームの時刻（止まっていたフレームは今と同じ）。
    pub def prevOf(clock: Clock[c]): Time[c] = match clock {
        case Ticker.Ticker(r) => Stamp.Stamp(r#prev)
    }

    /// このフレームに進んだ秒（止まっていれば 0・スロー中は縮む）。遊びの更新はこの秒で進める。
    pub def dtOf(clock: Clock[c]): Float64 = since(prevOf(clock), nowOf(clock))

    /// 1 フレーム進める（毎フレーム 1 回だけ呼ぶ —— 2 回呼ぶと prev が上書きされ、1 回目の区間の音が消える）。
    /// dt は実時間。Paused なら進まない（prev = now になるので、戻ったときに止める前の区間の音を鳴らし直さない）。
    /// スローが掛かっていれば TimeScale.gameDt で縮める。終わったスローは外す。
    pub def advance(rate: Run[r], dt: Float64, clock: Clock[c]): Clock[c] = match clock {
        case Ticker.Ticker(r) =>
            let realDt = match rate {
                case Run.Running   => dt
                case Run.Scaled(k) => dt * Float64.max(0.0, k)
                case Run.Paused(_) => 0.0
            };
            let gameDt = match r#slow {
                case None    => realDt
                case Some(s) => TimeScale.gameDt(s#plan, r#now - s#at, realDt)
            };
            let now = r#now + gameDt;
            let slow = match r#slow {
                case Some(s) if TimeScale.realAt(s#plan, now - s#at) < TimeScale.heldOf(s#plan) + s#plan#ramp => Some(s)
                case _ => None
            };
            Ticker.Ticker({ now = now, prev = r#now, slow = slow })
    }

    /// 今からスロー（ヒットストップ）を掛ける。掛かっている物は置き換える。
    pub def withSlow(plan: TimeScale.Plan, clock: Clock[c]): Clock[c] = match clock {
        case Ticker.Ticker(r) => Ticker.Ticker({ slow = Some({ at = r#now, plan = plan }) | r })
    }

    /// スローを掛けてからの実秒（掛かっていなければ None）。止めている間も光る・揺れる演出が読む。
    pub def slowRealAgeOf(clock: Clock[c]): Option[Float64] = match clock {
        case Ticker.Ticker(r) => r#slow |> Option.map(s -> TimeScale.realAt(s#plan, r#now - s#at))
    }

    /// スローが掛かっているか。
    pub def isSlowed(clock: Clock[c]): Bool = Option.nonEmpty(slowRealAgeOf(clock))
}
