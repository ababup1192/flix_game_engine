/// 下ごしらえ無しの本体: 引数にする式を let に置かず、ViewEnv.of の欄と同じ式（ctx・w#theme・Clock.nowOf(w)）と
/// 新しい引数の式（w#dialog）が本体のあちこちに出る。引数の並びは決まった桁で折ってある。
mod Talk {
    use Lib.Clock

    pub def box(ctx: Lib.Ctx, w: Lib.World,
                lines: Int32): Int32 =
        ctx#atlas + w#theme * lines + Clock.nowOf(w) + w#dialog

    pub def boxes(ctx: Lib.Ctx, w: Lib.World): Int32 = box(ctx, w, 1) + box(ctx, w, 2)

    /// 1 つずつ改行した並び。
    pub def tag(ctx: Lib.Ctx,
                w: Lib.World,
                n: Int32): Int32 =
        let e = ViewEnv.of(ctx, w);
        e#res#script + n + Lib.Clock.nowOf(w)

    pub def tags(ctx: Lib.Ctx, w: Lib.World): Int32 = tag(ctx, w, 3)

    /// 欄の一部だけが同じ（{ theme = 1 | w } は w でない）・副作用のある式は人へ回す。
    pub def odd(ctx: Lib.Ctx, w: Lib.World): Int32 \ IO =
        ctx#atlas + ViewEnv.resOf({ theme = 1 | w })#theme + Lib.tick(w)

    pub def odds(ctx: Lib.Ctx, w: Lib.World): Int32 \ IO = odd(ctx, w)
}
