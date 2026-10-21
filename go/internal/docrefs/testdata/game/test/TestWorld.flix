mod TestWorld {
    @Test
    def stepAddsTurn(): Bool = World.step(World.initial())#turn == 1
}
