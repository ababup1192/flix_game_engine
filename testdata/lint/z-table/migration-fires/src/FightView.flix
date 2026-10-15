mod FightView {
    def zWindow(): Int32 = SortingLayer.z(ZOrder.Layer.Scene, 20)
    def fightTree(items: List[Render.PlacedItem]): ZStack.Node[ZOrder.Layer] = ZStack.leafAbsolute(items)
}
