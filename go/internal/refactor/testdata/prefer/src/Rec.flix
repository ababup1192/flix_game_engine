mod Rec {
    use View.{Env, World}

    pub type alias Panel = { open = Bool, size = Int32 }

    pub def closed(w: World): Panel = { open = false, size = w#speed }

    pub def wide(w: World): Panel = {
        open = true,
        // the size of the panel
        size = w#speed
    }

    pub def framed(w: World): Panel =
        let env = View.bareOf(w);
        { open = true, size = env#scale }

    pub def given(env: Env, w: World): Panel = { open = true, size = w#speed + env#scale }
}
