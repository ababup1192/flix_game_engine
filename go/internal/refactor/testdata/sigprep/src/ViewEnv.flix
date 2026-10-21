/// 描く元。of・resOf の本体は record の式なので、道具は欄の式（ctx・resOf(w)・w#theme…）を env#欄 へ読み替えられる。
mod ViewEnv {
    pub type alias Res = { theme = Int32, script = Int32 }
    pub type alias Env = { ctx = Lib.Ctx, res = Res, now = Lib.Clock.Time }

    pub def of(ctx: Lib.Ctx, w: Lib.World): Env =
        { ctx = ctx, res = resOf(w), now = Lib.Clock.nowOf(w) }

    pub def resOf(w: Lib.World): Res = { theme = w#theme, script = w#script }
}
