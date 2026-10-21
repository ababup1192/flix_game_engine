mod Tile {
    use Shapes.area

    pub def tile(r: Shapes.Rect): Int32 = area(r) * 2
}
