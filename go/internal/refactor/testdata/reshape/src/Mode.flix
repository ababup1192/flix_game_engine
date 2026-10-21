/// change-case-shape のお手本: 中身の無い case（Title・Fight）・欄 1 つ（Deck）・欄 2 つ（Cards）・record 1 つ（Menu）。
/// 作る所・当てる所・関数として渡す所（decks）・使う変数の欄（nameOf の Deck の n）がある。
mod Mode {
    pub enum Scene {
        case Title
        case Fight
        case Deck(Int32)
        case Cards(Int32, Bool)
        case Menu({ at = Int32, cursor = Int32 })
    }

    pub def start(): Scene = Scene.Fight

    pub def deck(n: Int32): Scene = Scene.Deck(n + 1)

    pub def cards(): Scene = Scene.Cards(1,
                                         true)

    pub def menu(): Scene = Scene.Menu({ at = 0, cursor = 1 })

    pub def decks(xs: List[Int32]): List[Scene] = List.map(Scene.Deck, xs)

    pub def nameOf(s: Scene): String = match s {
        case Scene.Title       => "title"
        case Scene.Fight       => "fight"
        case Scene.Deck(n)     => "deck ${n}"
        case Scene.Cards(_, p) => if (p) "cards" else "cards?"
        case Scene.Menu(m)     => "menu ${m#cursor}"
    }

    pub def isFight(s: Scene): Bool = match s {
        case Scene.Fight => true
        case _           => false
    }

    pub def deckSize(s: Scene): Int32 = match s {
        case Scene.Deck(_) => 1
        case _             => 0
    }
}
