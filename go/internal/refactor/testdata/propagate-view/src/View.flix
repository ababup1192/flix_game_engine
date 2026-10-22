mod View {
    use Res.Res

    pub def leaf(w: Int32): Int32 = w * Res.defaults()#scale

    /// env#res は ViewEnv.Res（短い名前が同じ別の型）。葉の res には使えない。
    pub def endTree(env: ViewEnv.Env, w: Int32): Int32 = leaf(w) + env#n

    pub def mid(w: Int32): Int32 = endTree({ res = { atlas = 1 }, n = 2 }, w) + 1

    pub def mid2(w: Int32): Int32 = mid(w) * 2

    /// 別名（Model = Res）の引数は同じ型。
    pub def top(m: Res.Model, w: Int32): Int32 = mid2(w) + m#scale
}
