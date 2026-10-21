/// change-signature のお手本: draw(ctx, w) と drawBoth(ctx, w) を (env, speed) へ。本体は envOf(ctx, w) と speedOf(w) を
/// let で先に書き、残りはその名前だけを使う。tick は人へ回す所のお手本（関数として渡す・2 回使う引数に式・本体が w を使う）。
mod Sig {
    pub type alias Ctx = { scale = Int32 }
    pub type alias World = { speed = Int32, clock = Int32 }
    pub type alias Env = { scale = Int32, clock = Int32 }

    pub def envOf(ctx: Ctx, w: World): Env = { scale = ctx#scale, clock = w#clock }

    pub def speedOf(w: World): Int32 = w#speed

    pub def draw(ctx: Ctx, w: World): Int32 =
        let env = envOf(ctx, w);
        let speed = speedOf(w);
        env#scale * env#clock + speed

    pub def drawBoth(ctx: Ctx, w: World): Int32 =
        let env = envOf(ctx, w);
        let speed = speedOf(w);
        draw(ctx, w) + env#scale + speed

    pub def label(ctx: Ctx, w: World, name: String): String =
        "${name}: ${draw(ctx, w)}"

    pub def twice(ctx: Ctx, w: World): Int32 =
        draw(ctx, w) + draw({ scale = 2 },
                            w)

    pub def asValue(ctx: Ctx, ws: List[World]): List[Int32] = List.map(x -> draw(ctx, x), ws)

    pub def tick(ctx: Ctx, w: World): Int32 = ctx#scale + w#speed

    pub def ticks(ctx: Ctx, w: World, ws: List[World]): List[Int32] =
        tick(ctx, { speed = 1 | w }) :: List.map(tick(ctx), ws)
}
