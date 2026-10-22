mod World {
    pub type alias DeckUi = { cursor = Int32 }

    pub enum Scene {
        case Deck(DeckUi),
        case Board({ turn = Int32 }),
        case Title
    }

    pub enum Mode {
        case Off,
        case On
    }

    pub type alias World = { scene = Scene, deckScroll = Int32, deckOpen = Bool, hp = Int32, mode = Mode }

    pub def initial(): World = { scene = Scene.Title, deckScroll = 0, deckOpen = false, hp = 10, mode = Mode.Off }

    pub def openDeck(w: World): World = { scene = Scene.Deck({ cursor = 0 }) | w }

    pub def scrollOf(w: World): Int32 = w#deckScroll

    pub def toBoard(w: World): World = { scene = Scene.Board({ turn = 1 }) | w }

    pub def cursorOf(w: World): Int32 = match w#scene {
        case Scene.Deck(ui) => ui#cursor
        case _              => 0
    }
}
