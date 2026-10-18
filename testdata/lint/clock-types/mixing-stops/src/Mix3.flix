// 合図からの秒を、別の時計（物語）の今で測る。
mod Mix3 {
    pub def sinceHit(w: Shapes.World): Float64 = Clock.since(w#hitAt, Clock.nowOf(w#story))
}
