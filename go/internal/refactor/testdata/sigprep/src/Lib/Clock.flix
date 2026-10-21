/// use で名前を引く mod（ゲームの fge::{Clock} の代わり）。
pub mod Lib.Clock {
    pub type alias Time = Int32

    pub def nowOf(w: Lib.World): Time = w#clock
}
