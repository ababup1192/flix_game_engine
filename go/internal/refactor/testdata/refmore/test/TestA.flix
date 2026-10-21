mod TestA {

    @Test
    def testKeep(): Unit \ Assert = Assert.assertEq(expected = 3, A.keep(2))

}
