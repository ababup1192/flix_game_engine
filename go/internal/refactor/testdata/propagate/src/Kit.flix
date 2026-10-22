mod Kit {
    pub type alias Res = { scale = Int32 }

    pub type alias Env = { res = Res, n = Int32 }

    pub def defaults(): Res = { scale = 2 }
}
