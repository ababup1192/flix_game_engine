/// `use` and the types it names (the `use`, `type-use` and `alias-decl` rows of the resolved stage).
/// `isRound` is brought in and never called; `World` is brought in, but the code writes `Shapes.World` in full.
mod Uses {
    use Shapes.Shape
    use Shapes.isRound
    use Shapes.World

    pub def dot(): Shape = Shape.Dot

    pub def same(w: Shapes.World): Shapes.World = w
}
