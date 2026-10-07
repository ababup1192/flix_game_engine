// Calendar — ゲームの中の「時計と暦」。実時間の秒を、分・時・日・季節・年へ換算する。
// 世界が始まってからの通算の分を 1 つ持つだけなので、セーブも巻き戻しも数ひとつで済む。
// 利用例: 朝 6 時に起きて夜 2 時に倒れる / 日が変わったら畑を一斉に更新する /
//   季節で採れる物を変える / 曜日で店が閉まる。
// 注意: 時の流れを数えるだけで、日が変わったとき何をするかには関与しない（呼び側の規則）。
pub mod Calendar {

    /// 暦の決まり。1 日の長さ・1 時間の長さ・1 分に掛ける実時間・1 季節の日数・季節の名前。
    /// 現実の 24 時間制なら minutesPerDay = 1440・minutesPerHour = 60。
    /// secondsPerMinute を小さくするほど時が速く流れる。
    pub type alias Spec = {
        minutesPerDay    = Int32,
        minutesPerHour   = Int32,
        secondsPerMinute = Float64,
        daysPerSeason    = Int32,
        seasons          = List[String]
    }

    /// いまが世界の何分目か。carry は「次の 1 分までに貯まった実時間の端数」。
    pub type alias Stamp = { minute = Int32, carry = Float64 }

    /// よくある形（24 時間 = 1440 分・1 分 ≒ 0.7 秒 = 1 日約 17 分・1 季節 28 日・四季）。
    pub def defaults(): Spec =
        { minutesPerDay = 1440, minutesPerHour = 60, secondsPerMinute = 0.7,
          daysPerSeason = 28, seasons = "春" :: "夏" :: "秋" :: "冬" :: Nil }

    /// day 日目（0 始まり）の minuteOfDay 分に時計を合わせる。起床・寝直しに使う。
    pub def at(spec: Spec, day: Int32, minuteOfDay: Int32): Stamp =
        { minute = day * dayLength(spec) + minuteOfDay, carry = 0.0 }

    /// 実時間 dt 秒ぶん時を進める。1 フレームで何分進んでも取りこぼさない。
    pub def advance(spec: Spec, dt: Float64, s: Stamp): Stamp =
        // 数でない dt（初回フレームや落ちたフレーム、Doc の壊れた速度）は見送る —
        // 一度でも持ち越しに混ざると、以後どれだけ呼んでも時計が二度と進まなくなる。
        if (not Float64.isFinite(dt)) s
        else {
        let per = Float64.max(0.000001, spec#secondsPerMinute);
        let pool = s#carry + Float64.max(0.0, dt);
        let whole = Float64.floor(pool / per);
        let steps = Num.floorInt(whole);
        { minute = s#minute + steps, carry = pool - whole * per }
        }

    /// 次の日の minuteOfDay 分へ飛ばす（寝る）。すでにその時刻を過ぎていても必ず翌日になる。
    pub def sleepTo(spec: Spec, minuteOfDay: Int32, s: Stamp): Stamp =
        at(spec, dayOf(spec, s) + 1, minuteOfDay)

    // ── 読み出し ──

    /// 通算の日（0 始まり）。
    /// 負の分（「今より 30 分前」）でも 1 日前として数える — 切り捨て除算だと
    /// 「0 日目の 23:30」という、日と時刻が食い違う読みになる。
    pub def dayOf(spec: Spec, s: Stamp): Int32 =
        (s#minute - minuteOfDay(spec, s)) / dayLength(spec)

    /// その日の何分目か（0 〜 minutesPerDay-1）。
    pub def minuteOfDay(spec: Spec, s: Stamp): Int32 =
        Int32.modulo(s#minute, dayLength(spec))

    /// 何時か（0 始まり）。
    pub def hourOf(spec: Spec, s: Stamp): Int32 =
        minuteOfDay(spec, s) / hourLength(spec)

    /// その時の何分目か。
    pub def minuteOfHour(spec: Spec, s: Stamp): Int32 =
        Int32.modulo(minuteOfDay(spec, s), hourLength(spec))

    /// 1 日の進み具合（0.0 = 日付が変わった瞬間、1.0 手前 = その日の終わり）。
    /// 空の色や店の開き閉じを時刻から導くときの入口。
    pub def dayFraction(spec: Spec, s: Stamp): Float64 =
        Int32.toFloat64(minuteOfDay(spec, s)) / Int32.toFloat64(dayLength(spec))

    /// いまが何季節目か（0 始まり・seasons の添字）。
    pub def seasonIndexOf(spec: Spec, s: Stamp): Int32 =
        let count = Int32.max(1, List.length(spec#seasons));
        Int32.modulo(dayOf(spec, s) / seasonLength(spec), count)

    /// いまの季節の名前。名前が 1 つも無ければ空文字（fail-open）。
    pub def seasonOf(spec: Spec, s: Stamp): String =
        List.nth(seasonIndexOf(spec, s), spec#seasons) |> Option.getWithDefault("")

    /// その季節の何日目か（1 始まり — 画面に出す数）。
    pub def dayOfSeason(spec: Spec, s: Stamp): Int32 =
        Int32.modulo(dayOf(spec, s), seasonLength(spec)) + 1

    /// 何年目か（1 始まり — 画面に出す数）。
    pub def yearOf(spec: Spec, s: Stamp): Int32 =
        let yearLength = seasonLength(spec) * Int32.max(1, List.length(spec#seasons));
        dayOf(spec, s) / yearLength + 1

    /// 週の何日目か（0 始まり）。週の長さは呼び側が決める（7 日なら 7 を渡す）。
    pub def dayOfWeek(spec: Spec, weekLength: Int32, s: Stamp): Int32 =
        Int32.modulo(dayOf(spec, s), Int32.max(1, weekLength))

    /// 日付が変わったか（before から after の間に日をまたいだか）。
    /// 畑を一斉に更新する・眠気を出すといった「1 日 1 回」の合図に使う。
    pub def dayRolled(spec: Spec, before: Stamp, after: Stamp): Bool =
        dayOf(spec, before) != dayOf(spec, after)

    // ── 表示用 ──

    /// "6:30" の形。分は 2 桁に揃える。
    pub def hhmm(spec: Spec, s: Stamp): String =
        let m = minuteOfHour(spec, s);
        let pad = if (m < 10) "0" else "";
        "${hourOf(spec, s)}:${pad}${m}"

    /// "春 12日目" の形。
    pub def dateLabel(spec: Spec, s: Stamp): String =
        "${seasonOf(spec, s)} ${dayOfSeason(spec, s)}日目"

    // ── 内部（0 で割らないための下限） ──

    def dayLength(spec: Spec): Int32 = Int32.max(1, spec#minutesPerDay)

    def hourLength(spec: Spec): Int32 = Int32.max(1, spec#minutesPerHour)

    def seasonLength(spec: Spec): Int32 = Int32.max(1, spec#daysPerSeason)
}
