// TimeScale — ヒットストップ・スローモーション（ゲームの時計の進み方を一時的に遅くする）。
// 合図の瞬間からの**実時間**で「止める → 遅く流す → 等速へ戻す」を決め、それを
// ゲームの時計の進み（毎フレームの dt）へ直す。ゲームの時計ごと遅くするので、粒・揺れ・拍の進みが
// 全部いっしょに止まり、いっしょに遅くなる（Unity の Time.timeScale を区間で決める形）。
// 合図からの実時間はゲームの時計の進みから逆に引ける（realAt）—— 別の時計を持たなくてよい。
//
// 使い方: 合図の時刻 at（ゲームの時計）を覚えておき、毎フレーム gameDt(plan, w#t - at, dt) を
// World の dt の代わりに使う。画面の光や揺れは realAt(plan, w#t - at) の実秒で動かす
// （ゲームの時計が止まっていても揺れて光る）。
// 利用例: トドメの一撃で一瞬止めてからスローで流す / 被弾の瞬間のヒットストップ。

pub mod TimeScale {

    /// 区間 1 つ: dur 実秒のあいだ、時間を scale 倍（0 = 止める、1 = 等速）で流す。
    pub type alias Step = { dur = Float64, scale = Float64 }

    /// 区間の列（頭から順）と、最後の区間の速さから等速へなめらかに戻す実秒 ramp。
    pub type alias Plan = { steps = List[Step], ramp = Float64 }

    pub def step(dur: Float64, scale: Float64): Step = { dur = Float64.max(0.0, dur), scale = scale }

    /// 「止める → 遅く流す → 戻す」のよくある形。長さ 0 の区間は無い物として扱う。
    pub def freezeThenSlow(freeze: Float64, freezeScale: Float64, slow: Float64, slowScale: Float64,
                           ramp: Float64): Plan =
        { steps = step(freeze, freezeScale) :: step(slow, slowScale) :: Nil, ramp = Float64.max(0.0, ramp) }

    /// 区間の合計（実秒。この後に ramp が続く）。
    def heldOf(p: Plan): Float64 = p#steps |> List.foldLeft((acc, s) -> acc + s#dur, 0.0)

    /// 等速へ戻り始める直前の速さ（長さのある最後の区間の速さ。区間が無ければ 1）。
    def rampFrom(p: Plan): Float64 =
        p#steps |> List.filter(s -> s#dur > 0.0) |> List.last |> Option.map(s -> s#scale)
                |> Option.getWithDefault(1.0)

    /// 合図から実秒 r の時点の時間の速さ（0〜1）。戻りは出だしと終わりがゆっくりの曲線でつなぐ。
    pub def scaleAt(p: Plan, r: Float64): Float64 =
        if (r < 0.0) 1.0
        else {
            def walk(steps, start) = match steps {
                case s :: rest => if (r < start + s#dur) Some(s#scale) else walk(rest, start + s#dur)
                case Nil       => None
            };
            match walk(p#steps, 0.0) {
                case Some(scale) => scale
                case None        =>
                    let held = heldOf(p);
                    if (p#ramp > 0.0 and r < held + p#ramp) {
                        let u = (r - held) / p#ramp;
                        let s0 = rampFrom(p);
                        s0 + (1.0 - s0) * (u * u * (3.0 - 2.0 * u))
                    }
                    else 1.0
            }
        }

    /// 合図から実秒 r までにゲームの時計が進む秒（scaleAt を 0 から r まで足し上げた物。
    /// 戻りの曲線 3u² − 2u³ の足し上げは式で解ける: u³ − u⁴/2）。
    pub def gameAt(p: Plan, r: Float64): Float64 =
        let part = (start, len) -> Num.clamp(0.0, len, r - start);
        let (held, stepped) = p#steps |> List.foldLeft((acc, s) -> {
            let (start, sum) = acc;
            (start + s#dur, sum + part(start, s#dur) * s#scale)
        }, (0.0, 0.0));
        let ramped = if (p#ramp <= 0.0) 0.0 else {
            let x = part(held, p#ramp);
            let u = x / p#ramp;
            let s0 = rampFrom(p);
            s0 * x + (1.0 - s0) * p#ramp * (u * u * u - u * u * u * u / 2.0)
        };
        let after = Float64.max(0.0, r - held - p#ramp);
        stepped + ramped + after

    /// ゲームの時計が合図から g 秒進んだのは、実時間で何秒後か（gameAt の逆。
    /// gameAt は増える一方なので、半分ずつ狭めて探す）。g <= 0 は合図の前なので等速のまま。
    pub def realAt(p: Plan, g: Float64): Float64 =
        if (g <= 0.0) g
        else {
            let hi0 = heldOf(p) + p#ramp + g + 1.0;
            def search(lo, hi, n) =
                if (n <= 0) (lo + hi) / 2.0
                else {
                    let mid = (lo + hi) / 2.0;
                    if (gameAt(p, mid) < g) search(mid, hi, n - 1) else search(lo, mid, n - 1)
                };
            search(0.0, hi0, 40)
        }

    /// 実時間 dt に対して、ゲームの時計を進める秒。age = いまのゲームの時計 − 合図の時刻。
    /// 合図の前は dt のまま、合図をまたぐフレームは「合図までは等速・そこから先は区間の速さ」で割る。
    pub def gameDt(p: Plan, age: Float64, dt: Float64): Float64 =
        if (age + dt <= 0.0) dt
        else if (age < 0.0) (0.0 - age) + gameAt(p, dt + age)
        else gameAt(p, realAt(p, age) + dt) - age

    /// 全部の秒を k 倍する（「はやさ」の設定）。速さ（scale）は変えない。
    pub def scaled(k: Float64, p: Plan): Plan =
        { steps = List.map(s -> { dur = s#dur * k | s }, p#steps), ramp = p#ramp * k }
}
