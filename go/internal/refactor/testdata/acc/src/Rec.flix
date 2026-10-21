/// field-to-accessor のお手本: World の欄 clock の直の読み書きを、口（clockOf・mapClock・withClock）へ替える。
/// Other にも同じ名前の欄 clock があり、こちらは替えない。
mod Rec {
    pub type alias World = {
        speed = Int32,
        // 時計（秒）
        clock = Float64
    }

    pub type alias Other = { clock = Float64, name = String }

    pub def clockOf(w: World): Float64 = w#clock

    pub def mapClock(f: Float64 -> Float64, w: World): World = { clock = f(w#clock) | w }

    pub def withClock(c: Float64, w: World): World = { clock = c | w }

    pub def make(): World = { clock = 0.0, speed = 1 }

    def other(): Other = { clock = 9.0, name = "o" }

    def half(x: Float64): Float64 = x / 2.0

    pub def tick(dt: Float64, w: World): World = { clock = w#clock + dt | w }

    pub def reset(w: World): World = { clock = 0.0 | w }

    pub def both(w: World): World = { clock = 1.0, speed = 2 | w }

    pub def late(w: World): World = { speed = 3, clock = 2.0 | w }

    pub def sum(a: World, b: World): Float64 = a#clock + b#clock

    pub def otherClock(): Float64 = other()#clock

    pub def made(): Float64 = make()#clock

    pub def piped(w: World): World = { clock = w#clock |> half | w }

    pub def total(w: World, ws: List[World]): World =
        { clock = List.foldLeft((acc, v) -> acc + v#clock, 0.0, ws) + w#clock | w }

    pub def spread(): Float64 = List.foldLeft((acc, p) -> acc + p#clock, 0.0, { clock = 1.0, speed = 0 } :: Nil)

    pub def open(r: { clock = Float64 | a }): Float64 = r#clock

    pub def note(w: World): String = "clock: ${w#clock}"
}
