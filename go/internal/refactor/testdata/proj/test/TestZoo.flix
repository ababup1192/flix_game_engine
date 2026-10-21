mod TestZoo {
    @Test
    def onlyTestedAddsOne(): Unit \ Assert = Assert.assertEq(expected = 3, Zoo.onlyTested(1))

    @Test
    def onlyTestedTooWithUsed(): Unit \ Assert = Assert.assertEq(expected = Zoo.used() + 2, Zoo.onlyTestedToo(1))
}
