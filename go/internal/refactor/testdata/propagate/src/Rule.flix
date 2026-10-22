mod Rule {
    use Kit.Res

    pub def score(w: Int32): Int32 = w * Kit.defaults()#scale

    pub def total(w: Int32, bonus: Int32): Int32 = score(w) + bonus

    pub def twice(w: Int32): Int32 = total(w, 1) + total(w, 2)

    pub def withRes(r: Res, w: Int32): Int32 = score(w) + r#scale

    pub def entry(): Int32 = twice(3)

    pub def stopped(w: Int32): Int32 = score(w)

    pub def shown(env: Kit.Env, w: Int32): Int32 = score(w) + env#n
}
