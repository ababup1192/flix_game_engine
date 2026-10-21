/// remove-dead が転送するだけの包みを消す時、doc を転送先へ移すお手本。stand → standIn は転送先の doc が包みを指す・
/// plain → blank は転送先に doc が無い・keep → kept は転送先の doc が包みを指さない（人の書いた doc なので残す）。
mod Wrap {
    /// 立ち絵 1 体（表情の絵を 1 枚貼る）。
    pub def stand(w: Lib.World): Int32 = standIn(w#theme, Lib.Clock.nowOf(w))

    /// stand の、テーマだけで描く形。
    pub def standIn(theme: Int32, h: Int32): Int32 = theme + h

    /// 台本の番号に 1 を足す。
    pub def plain(w: Lib.World): Int32 = blank(w#script)

    pub def blank(n: Int32): Int32 = n + 1

    /// 包みの説明。
    pub def keep(w: Lib.World): Int32 = kept(w#clock)

    /// 時計の値に 2 を足す。
    pub def kept(n: Int32): Int32 = n + 2

    /// 立ち絵 1 体（時計を 0 で描く）。
    pub def standZero(w: Lib.World): Int32 = standIn(w#theme, 0)
}
