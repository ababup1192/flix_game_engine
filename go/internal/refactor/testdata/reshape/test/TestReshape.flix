mod TestReshape {
    use Mode.Scene

    pub def drawsOnce(): Bool =
        let w = { speed = 1, clock = 3 };
        Sig.draw({ scale = 2 }, w) == 7

    pub def startsInFight(): Bool = Mode.isFight(Scene.Fight)
}
