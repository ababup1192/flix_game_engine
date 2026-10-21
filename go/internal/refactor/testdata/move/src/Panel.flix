mod Panel {
    use Shapes.{area, perimeter}

    pub def panel(r: Shapes.Rect): Int32 = area(r) + perimeter(r)
}
