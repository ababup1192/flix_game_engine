mod Tutorial {
    use World.World
    use Res.Res

    /// 葉: w を tutorialDoc にだけ使う（全部を res へ読み替えると w が空く）。
    pub def penOf(w: World): Int32 = w#tutorialDoc#pen

    /// 葉: 呼び手 shownAge は w を渡すだけ（葉から w を外すと shownAge の w が空く）。
    pub def penSeconds(w: World): Int32 = w#tutorialDoc#pen * 60

    /// 葉: 本体に局所の res がある（足す res は使われず、読み替えた res#… は局所を読む）。
    pub def localRes(w: World): Int32 =
        let res = 3;
        w#tutorialDoc#pen + res

    /// res を持つ def: 別の World（prev）と式（nextOf(w)）の読みは替えない。w は nextOf に残る。
    pub def changed(res: Res, w: World, prev: World): Bool =
        w#tutorialDoc#pen != prev#tutorialDoc#pen and nextOf(w)#tutorialDoc#pen > res#theme

    def nextOf(w: World): World = { step = w#step + 1 | w }

    /// 書き込み（{ tutorialDoc = … | w }）は人へ。読みは替える。
    pub def withPen(res: Res, w: World): World = { tutorialDoc = w#tutorialDoc | w } |> (x -> { step = res#theme | x })

    /// 読み替えると w を読む所が 0 になる。
    pub def penOnly(res: Res, w: World): Int32 = w#tutorialDoc#pen + res#theme
}
