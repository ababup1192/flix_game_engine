mod Screen {
    use View.{Env, World}

    pub def withLet(ctx: Int32, w: World): Int32 =
        let env = View.bareOf(w);
        Hand.hand(ctx, w) + env#scale

    pub def entry(ctx: Int32, env: Env, w: World): Int32 =
        Hand.hand(ctx, w) + env#scale

    pub def other(ctx: Int32, env: Env, w: World): Int32 =
        Hand.hand(ctx, w) + env#scale

    pub def arms(ctx: Int32, w: World, b: Bool): Int32 = match b {
        case true => let env = View.bareOf(w); env#scale
        case false => Hand.hand(ctx, w)
    }

    pub def main(w: World): Int32 =
        entry(1, View.bareOf(w), w) + other(2, { scale = 3 }, w)
}
