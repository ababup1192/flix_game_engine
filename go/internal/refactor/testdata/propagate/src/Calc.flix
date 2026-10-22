mod Calc {
    use Kit.Res

    pub def leaf(w: Int32): Int32 = w + Kit.defaults()#scale

    pub def mid(w: Int32, k: Int32): Int32 = leaf(w) * k

    pub def top(res: Res, w: Int32): Int32 = mid(w, res#scale)
}
