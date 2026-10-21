mod View {
    pub type alias World = { scale = Int32, speed = Int32 }

    pub type alias Env = { scale = Int32 }

    pub def bareOf(w: World): Env = { scale = w#scale }
}
