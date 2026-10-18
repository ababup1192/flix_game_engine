// Clock — 時間を数える道具。2 つの層がある。
//
// ── 秒を貯める（tick / countdown）──
// タイマー用の仕組みを持ち出さなくても、貯めた秒数の足し引きだけで周期処理やカウントダウンが書ける。
// 利用例: 敵を一定間隔で湧かせる / アニメのコマを送る / 開始前の残り秒数を数える。
//
// ── 型で分けた時計（Clock[c] と Time[c]）──
// ゲームには進み方の違う時計が何本かある: 遊びの時計（ポーズで止まり、ヒットストップで遅くなる）・
// 実時間（ポーズメニューの点滅・雨のような背景）。どれも中身は秒の Float64 なので、取り違えてもコンパイルは
// 通り、「ポーズ中もパーティクルが進む」「戻ると音が鳴り直す」が遊んで初めて見つかる。
// Clock[c] / Time[c] の c は時計の名前の型。違う時計の時刻を引く・比べる・同じ寿命や時刻表に渡すと
// コンパイルが止まる（E7491）。Bevy の Time<Real> / Time<Virtual> と同じ分け方。
//
//   実時間  Time[Clock.Real]  App が毎フレーム frame#realNow で配る。ゲームは時計を持たず、止められない
//   遊び    Clock[Play]       名前はゲームが pub の空の enum で作る（enum Play）。World の欄に置き、
//                             App.addClock で宣言すると App が毎フレーム 1 回だけ進める
//
//   pub enum Play                                          // 時計の名前（中身は要らない。pub でないと E8176 の使っていない enum）
//   play = Clock.start()                                   // World の欄 Clock.Clock[Play]
//   app |> App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w },
//                         paceOf = World.paceOf })         // 止める理由と遅くする Plan は World から宣言
//   Clock.dtOf(w#play)                                     // 遊びの更新はこの秒で進める（frame#dt ではない）
//   Lifetime.fireOn(Clock.nowOf(w#play), 0.5)              // 遊びの時計で測る寿命
//   Timeline.soundsOnClock(ws#after#play, at, tl)          // 鳴らす区間 (prev, now] は時計が持つ
//
// 時計を進めるのは App だけ（advance をゲームから呼ぶと lint-forbid の clock-advance が止める —— 同じ
// フレームに 2 回進めると、1 回目の区間の音が消える）。時刻は時計から読む（nowOf）か、
// 決まった時刻から作る（zero / never / after）。
// secondsOf で秒へ戻すのは、周期の関数（Anim.frameAt・Sway.wave・Fx.derive の点滅・揺れ・流れ）に
// 渡す所だけ。そこで時計の名前は消えるので、差は since・前後は Time のまま比べる
// （秒へ戻して引く・比べる・after で包み直すと lint-forbid の clock-seconds-leak が止める）。
// 考え方・ジャンルごとの使い方・止まる誤りと止まらない誤りは docs/clock.md。
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

    /// 実時間の時計の名前。App だけが進め、frame#realNow で配る。
    pub enum Real

    /// 時計 c で測った秒。型引数は中身に出てこないので名前を `_` にして種を書く（名前を付けると E8518 の使っていない型引数）。
    enum Stamp[_: Type](Float64)

    /// 時計 c で測った時刻。中身は外から作れない（nowOf / prevOf と zero / never / after だけが作る）。
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

    /// 時計の頭の時刻（start した時計の nowOf と同じ）。World の初期値や、テストで組む Frame の realNow に。
    pub def zero(): Time[c] = Stamp.Stamp(0.0)

    /// まだ起きていない出来事の時刻（どの今から見ても、演出が全部終わった過去）。
    pub def never(): Time[c] = Stamp.Stamp(-1.0e9)

    /// at から seconds 秒あとの時刻（負なら手前）。
    pub def after(seconds: Float64, at: Time[c]): Time[c] = Stamp.Stamp(secondsOf(at) + seconds)

    /// at から now までの秒（now が先なら負）。
    pub def since(at: Time[c], now: Time[c]): Float64 = secondsOf(now) - secondsOf(at)

    /// 秒へ戻す。周期の関数（Anim.frameAt・Sway.wave・Fx.derive）に渡す所だけで使う —— 時計の名前は消える。
    pub def secondsOf(at: Time[c]): Float64 = match at {
        case Stamp.Stamp(s) => s
    }

    // ── 時計 ──

    /// 時計 c。now = 今の時刻、prev = 前のフレームの時刻（音を鳴らす区間 (prev, now] の頭）。
    enum Ticker[_: Type]({ now = Float64, prev = Float64 })

    /// 時計 c。
    pub type alias Clock[c] = Ticker[c]

    /// このフレームの時計の進み方。r は止める理由（ゲームの型）。
    /// Running = 実時間どおり・Scaled(k) = k 倍（説明を読む間ゆっくり 等）・Paused(r) = 止める。
    pub enum Run[r] {
        case Running
        case Scaled(Float64)
        case Paused(r)
    }

    /// 時刻 at から掛かるスロー・ヒットストップ（TimeScale の Plan）。
    pub type alias Slow[c] = { at = Time[c], plan = TimeScale.Plan }

    /// World から導く「このフレームの時計の進み方」の宣言。mode が止める・倍速を、slow がヒットストップを決める（run は Flix の予約語）。
    /// 止めている間はスローも止まり、戻ると続きから流れる（スローの進みは時計 c で測るため）。
    pub type alias Pace[c, r] = { mode = Run[r], slow = Option[Slow[c]] }

    /// スローの掛かっていない進み方。
    pub def paceOf(mode: Run[r]): Pace[c, r] = { mode = mode, slow = None }

    /// 時刻 at から plan のスローを掛ける（掛かっている物は置き換える）。
    /// at はスローの合図の時刻（踏んだ瞬間の nowOf）。never() ならもう終わったスロー。
    pub def withSlow(at: Time[c], plan: TimeScale.Plan, pace: Pace[c, r]): Pace[c, r] =
        { slow = Some({ at = at, plan = plan }) | pace }

    /// 0 秒から始まる時計。
    pub def start(): Clock[c] = Ticker.Ticker({ now = 0.0, prev = 0.0 })

    /// seconds 秒から始まる時計（描き出し・テストで決まった瞬間を撮るとき。遊びの中では start を使う）。
    pub def startAt(seconds: Float64): Clock[c] = Ticker.Ticker({ now = seconds, prev = seconds })

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

    /// 1 フレーム進める。App が毎フレーム 1 回だけ呼ぶ（ゲームからは App.addClock で宣言する）。
    /// dt は実時間。Paused なら進まない —— prev = now になるので、戻ったときに止める前の区間の音を
    /// 鳴らし直さない。スローは合図からの時計 c の秒で TimeScale.gameDt を引く。
    pub def advance(pace: Pace[c, r], dt: Float64, clock: Clock[c]): Clock[c] = match clock {
        case Ticker.Ticker(r) =>
            let realDt = match pace#mode {
                case Run.Running   => dt
                case Run.Scaled(k) => dt * Float64.max(0.0, k)
                case Run.Paused(_) => 0.0
            };
            let gameDt = match pace#slow {
                case None    => realDt
                case Some(s) => slowedDt(s, r#now, realDt)
            };
            Ticker.Ticker({ now = r#now + gameDt, prev = r#now })
    }

    /// スローの中の進み。終わったスロー（never を含む）は TimeScale を通さない ——
    /// 合図から遠いと realAt の二分探索の幅が広がり、秒の誤差が毎フレーム乗るため。
    def slowedDt(s: Slow[c], now: Float64, realDt: Float64): Float64 =
        let age = now - secondsOf(s#at);
        let length = TimeScale.gameAt(s#plan, TimeScale.heldOf(s#plan) + s#plan#ramp);
        if (age >= length) realDt
        else TimeScale.gameDt(s#plan, age, realDt)

    /// pace のスローがこの時計の今まだ掛かっているか（ヒットストップの光・揺れの出し入れに）。
    pub def isSlowed(pace: Pace[c, r], clock: Clock[c]): Bool = match pace#slow {
        case None    => false
        case Some(s) =>
            let age = since(s#at, nowOf(clock));
            age >= 0.0 and age < TimeScale.gameAt(s#plan, TimeScale.heldOf(s#plan) + s#plan#ramp)
    }
}
