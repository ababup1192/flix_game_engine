mod Shots {
    pub def top(w: World.World): Int32 = Tutorial.penOf(w) + w#step

    pub def view(res: Res.Res, w: World.World): Int32 = top(w) + res#theme

    pub def shownAge(w: World.World, extra: Int32): Int32 = Tutorial.penSeconds(w) + extra

    pub def ages(res: Res.Res, w: World.World): Int32 = shownAge(w, res#theme)

    pub def local(res: Res.Res, w: World.World): Int32 = Tutorial.localRes(w) + res#theme

    pub def both(res: Res.Res, w: World.World): Int32 = Tutorial.penOnly(res, w) + w#step
}
