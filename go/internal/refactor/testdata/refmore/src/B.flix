mod B {
    use A.{keep, onlyUsed}

    pub def b(): Int32 = keep(2)

}
