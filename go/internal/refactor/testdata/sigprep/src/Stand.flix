/// 新しい引数の型（Clock.Time）の名前がこのファイルでは引けない形。Stand は同じ親（Lib.）の use の並びがある・
/// Plain（src/Plain.flix）は use が 1 つも無い。
mod Stand {
    use Lib.{Ctx}

    pub def atlasOf(c: Ctx): Int32 = c#atlas

    pub def stand(w: Lib.World, h: Int32): Int32 = Lib.Clock.nowOf(w) + h
}
