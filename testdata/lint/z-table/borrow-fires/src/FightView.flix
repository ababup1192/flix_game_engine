mod FightView {
    use CardsView.{zPickCard}
    def zCard(): Int32 = CardsView.zPickCard() + 1
    def zFoe(): Int32 = ZOrder.zBoard() + Render.zOf(2)
}
