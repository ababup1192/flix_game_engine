mod ZOrder {
    pub enum Layer { case Scene case Talk }
    instance SortingLayer[Layer] {
        pub def zRange(layer: Layer): (Int32, Int32) = (0, 99)
    }
}
