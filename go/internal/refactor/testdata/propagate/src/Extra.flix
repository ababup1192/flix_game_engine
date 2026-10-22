mod Extra {
    use Kit.Res

    pub type alias Blank = Unit

    pub def blankOf(_w: Int32): Blank = ()

    pub def screen(w: Int32): (Int32, Unit) = if (w > 0) (w, blankOf(w)) else (0, ())

    pub def quiet(_r: Res, w: Int32): Int32 = Rule.score(w)

    pub def scores(res: Res, ws: List[Int32]): List[Int32] = List.map(Rule.score, ws) |> List.map(x -> x + res#scale)

    pub def piped(res: Res, w: Int32): Int32 = (w |> Rule.score) + res#scale

    pub def bonusOf(res: Res, w: Int32): Int32 = (1 |> Rule.total(w)) + res#scale

    pub def tip(w: Int32): Int32 = w + Kit.defaults()#scale

    pub def wrap(f: (Res, Int32) -> Int32, w: Int32): Int32 = f(Kit.defaults(), w)

    pub def viaLambda(w: Int32): Int32 = wrap((res, x) -> res#scale + tip(x), w) + wrap((_, x) -> tip(x), w)
}
