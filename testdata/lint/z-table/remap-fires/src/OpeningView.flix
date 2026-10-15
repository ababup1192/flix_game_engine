mod OpeningView {
    def squeezed(items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        items |> List.map(p -> { item = Render.zMapped(z -> z / 4, p#item) | p })
}
