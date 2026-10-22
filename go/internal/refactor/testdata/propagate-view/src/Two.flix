/// 1 つのファイルに 2 つの mod。TwoA の use ViewEnv.Res は TwoB の中では効かない（TwoB の Res は TwoB.Res）。
mod TwoA {
    use ViewEnv.Res

    pub def atlasOf(r: Res): Int32 = r#atlas
}

mod TwoB {
    pub type alias Res = { scale = Int32 }

    pub def defaults(): Res = { scale = 3 }

    pub def leaf(w: Int32): Int32 = w * TwoB.defaults()#scale

    /// r は TwoB.Res（葉に足す res と同じ型）。広げずに r を書く。
    pub def top(r: Res, w: Int32): Int32 = leaf(w) + r#scale
}
