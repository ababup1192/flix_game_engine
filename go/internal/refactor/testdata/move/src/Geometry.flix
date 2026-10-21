/// 移し先（もうある mod）。移す def を修飾名で呼ぶ所もある。
mod Geometry {
    pub def origin(): Int32 = 0

    pub def unitArea(): Int32 = Shapes.area({ w = 1, h = 1 })
}
