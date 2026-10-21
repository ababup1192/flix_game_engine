mod A {

    /// 外から呼ばれる口。
    pub def keep(x: Int32): Int32 = helper(x, 1)

    /// 同じ mod の中からだけ呼ばれる（make-private で pub を外せる）。2 つ目の引数は本体が使わない（remove-param で消す）。
    pub def helper(x: Int32, unused: Int32): Int32 = x + 1

    /// 呼ぶ所が Option を開いた後の値 v を持つ（change-signature の @v）。
    pub def caller(o: Option[Int32]): Int32 = match o {
        case Some(v) => wrap(1)
        case None    => wrap(0)
    }

    /// let で束ねた値 n を持つ呼ぶ所。
    pub def letCaller(): Int32 =
        let n = 3;
        wrap(n)

    pub def wrap(a: Int32): Int32 = a + 0

    /// 外の mod が use だけする（呼ばない）。
    pub def onlyUsed(): Int32 = 7

    pub def selfUse(): Int32 = onlyUsed()

    /// どこからも呼ばれない。
    pub def lonely(): Int32 = 9

}
