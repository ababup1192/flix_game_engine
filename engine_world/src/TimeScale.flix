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

    /// 区間 1 つ: dur 実秒のあいだ、時間を scale 倍（0 に近いほど止まる、1 = 等速）で流す。
    pub type alias Segment = { dur = Float64, scale = Float64 }

    /// 速さの下限。ちょうど 0 にしないのは、止めている間ゲームの時計が進まないと、
    /// 合図からの実秒をゲームの時計から逆に引けず（realAt）、時計が止まったまま動き出せなくなるため。
    def minScale(): Float64 = 0.001

    /// 区間の列（頭から順）と、最後の区間の速さから等速へなめらかに戻す実秒 ramp。
    pub type alias Plan = { segments = List[Segment], ramp = Float64 }

    pub def segment(dur: Float64, scale: Float64): Segment =
        { dur = Float64.max(0.0, dur), scale = Float64.max(minScale(), scale) }

    /// 「止める → 遅く流す → 戻す」のよくある形の秒と速さ（freeze 秒を freezeScale 倍、
    /// slow 秒を slowScale 倍、ramp 秒で等速へ戻す）。
    pub type alias FreezeThenSlow = { freeze = Float64, freezeScale = Float64, slow = Float64,
                                      slowScale = Float64, ramp = Float64 }

    /// FreezeThenSlow から区間の列を作る。長さ 0 の区間は無い物として扱う。
    pub def freezeThenSlow(f: FreezeThenSlow): Plan =
        { segments = segment(f#freeze, f#freezeScale) :: segment(f#slow, f#slowScale) :: Nil,
          ramp = Float64.max(0.0, f#ramp) }

    /// 区間の合計（実秒）。この後に ramp 秒かけて等速へ戻る（寄りを引く・光を消す拍を合わせるときに読む）。
    pub def heldOf(p: Plan): Float64 = p#segments |> List.foldLeft((acc, s) -> acc + s#dur, 0.0)

    /// 等速へ戻り始める直前の速さ（長さのある最後の区間の速さ。区間が無ければ 1）。
    def rampFrom(p: Plan): Float64 =
        p#segments |> List.filter(s -> s#dur > 0.0) |> List.last |> Option.map(s -> s#scale)
                |> Option.getWithDefault(1.0)

    /// 合図から実秒 r までにゲームの時計が進む秒（時間の速さを 0 から r まで足し上げた物。
    /// 戻りの曲線 3u² − 2u³ の足し上げは式で解ける: u³ − u⁴/2）。
    pub def gameAt(p: Plan, r: Float64): Float64 =
        let part = (start, len) -> Num.clamp(0.0, len, r - start);
        let (held, stepped) = p#segments |> List.foldLeft((acc, s) -> {
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
    /// 区間ごとに式で解かないのは、戻りの区間が 4 次式で、解の公式を書くより探す方が読めるため
    /// （40 回で秒の誤差は 1e-12 より小さい）。
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
        { segments = List.map(s -> { dur = s#dur * k | s }, p#segments), ramp = p#ramp * k }
}
