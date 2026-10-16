// EngineInternal — エンジンの中だけで使う口。ゲームの View からは呼ばない。
// 使う場面: エンジンが木や UI を z の数へ戻すところ（SortingLayer.compose・App.composeScene の HUD・UiRender の層）。
// ゲームから呼ぶと bin/fge forbid（engine-internal）が止める。
// 使わない: ゲームの重なり順（積む順は ZStack.of、手前へは ZStack.topLayer、画面ごと動かすのは ZStack.mapItems）。
// WhyNot: Flix にはパッケージの中だけで見える仕組みが無い（pub でないモジュールは別のモジュールから呼べない）ので、
//   名前で「エンジンの中の物」と分かるようにしている。z を付け替えると、どの層に入るかが表から読めなくなる。
pub mod EngineInternal {

    use Render.Item

    /// 描画物の重なり順（zIndex）を f で写す（Clipped は中身の z）。
    pub def zMapped(f: Int32 -> Int32, item: Item): Item =
        match item {
            case Item.Sprite(s)  => Item.Sprite({ zIndex = f(s#zIndex) | s })
            case Item.Text(x)    => Item.Text({ zIndex = f(x#zIndex) | x })
            case Item.Box(b)     => Item.Box({ zIndex = f(b#zIndex) | b })
            case Item.Poly(p)    => Item.Poly({ zIndex = f(p#zIndex) | p })
            case Item.Shader(s)  => Item.Shader({ zIndex = f(s#zIndex) | s })
            case Item.Clipped(c) => Item.Clipped({ inner = zMapped(f, c#inner) | c })
        }
}
