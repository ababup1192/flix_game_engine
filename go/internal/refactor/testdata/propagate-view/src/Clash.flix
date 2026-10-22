mod Clash {
    use Res.Res

    pub def leaf(w: Int32): Int32 = w * Res.defaults()#scale

    /// res は ViewEnv.Res（葉に足す res と同じ名前・別の型）。res を書くと型が合わず、res を足すと名前が重なる。
    pub def other(res: ViewEnv.Res, w: Int32): Int32 = leaf(w) + res#atlas
}
