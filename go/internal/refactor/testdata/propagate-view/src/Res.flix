mod Res {
    pub type alias Res = { scale = Int32 }

    pub type alias Model = Res

    pub def defaults(): Res = { scale = 2 }
}
