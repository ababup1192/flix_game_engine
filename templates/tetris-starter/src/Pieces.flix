// Pieces — ミノ（テトロミノ）の形と回転だけを受け持つ純粋な表。
// World を「規則（重力・接地・ライン消し）」に集中させるため、
// 「どの向きのときどの 4 マスか」という形の知識はここに切り出してある。
//
// 座標系: Cell = (col, row)。row 0 が最上段で、下に行くほど row が増える（画面と同じ向き）。
// 各ミノは「原点セル (0,0) を左上の基準にした 4 マスの相対座標」で表す。
// World はこれを piece の (col,row) だけ平行移動して盤の座標にする。
//
// 回転は SRS（公式の複雑な回転則）ではなく、素直な rot 0..3 の 4 状態テーブル。
// 原始的でよい — 「回してはめる」感触が出れば十分。壁際の救済は
// wallKickOffsets（簡易ウォールキック）を World.tryRotate が順に試す。
mod Pieces {

    /// ミノの 7 種。色（ThemeDoc.colorOf）も形（cellsOf）もこの種類から引く。
    pub enum Kind with Eq, ToString {
        case I
        case O
        case T
        case S
        case Z
        case J
        case L
    }

    /// 盤のマス。(col, row)。row 0 が最上段で、下に行くほど row が増える（画面と同じ向き）。
    pub type alias Cell = (Int32, Int32)

    // ── 形のテーブル（原点基準の相対 4 セル。rot 0..3） ──
    // 見た目のまま素直に並べる（初学者が形を目で追える）。
    // O は回しても同じなので全 rot 同一。I/S/Z も本来は 2 状態だが、
    // rot%4 で引ける表を素直に埋めておく（分岐を増やさない）。

    /// kind を rot（0..3）で回した 4 セルの相対座標。範囲外の rot は 4 で丸める。
    pub def cellsOf(kind: Kind, rot: Int32): List[Cell] =
        let r = Int32.modulo(Int32.modulo(rot, 4) + 4, 4);
        match kind {
            case Kind.I => iCells(r)
            case Kind.O => (1, 0) :: (2, 0) :: (1, 1) :: (2, 1) :: Nil   // 回っても同じ
            case Kind.T => tCells(r)
            case Kind.S => sCells(r)
            case Kind.Z => zCells(r)
            case Kind.J => jCells(r)
            case Kind.L => lCells(r)
        }

    // I（横一列・縦一列）。4×4 の升目の中で置くと回転の軸が素直に見える。
    def iCells(r: Int32): List[Cell] = match r {
        case 0 => (0, 1) :: (1, 1) :: (2, 1) :: (3, 1) :: Nil
        case 1 => (2, 0) :: (2, 1) :: (2, 2) :: (2, 3) :: Nil
        case 2 => (0, 2) :: (1, 2) :: (2, 2) :: (3, 2) :: Nil
        case _ => (1, 0) :: (1, 1) :: (1, 2) :: (1, 3) :: Nil
    }

    // T（凸）。出っぱりが上→右→下→左と回る。
    def tCells(r: Int32): List[Cell] = match r {
        case 0 => (1, 0) :: (0, 1) :: (1, 1) :: (2, 1) :: Nil
        case 1 => (1, 0) :: (1, 1) :: (2, 1) :: (1, 2) :: Nil
        case 2 => (0, 1) :: (1, 1) :: (2, 1) :: (1, 2) :: Nil
        case _ => (1, 0) :: (0, 1) :: (1, 1) :: (1, 2) :: Nil
    }

    // S（右上がりの階段）。
    def sCells(r: Int32): List[Cell] = match r {
        case 0 => (1, 0) :: (2, 0) :: (0, 1) :: (1, 1) :: Nil
        case 1 => (1, 0) :: (1, 1) :: (2, 1) :: (2, 2) :: Nil
        case 2 => (1, 1) :: (2, 1) :: (0, 2) :: (1, 2) :: Nil
        case _ => (0, 0) :: (0, 1) :: (1, 1) :: (1, 2) :: Nil
    }

    // Z（右下がりの階段）。
    def zCells(r: Int32): List[Cell] = match r {
        case 0 => (0, 0) :: (1, 0) :: (1, 1) :: (2, 1) :: Nil
        case 1 => (2, 0) :: (1, 1) :: (2, 1) :: (1, 2) :: Nil
        case 2 => (0, 1) :: (1, 1) :: (1, 2) :: (2, 2) :: Nil
        case _ => (1, 0) :: (0, 1) :: (1, 1) :: (0, 2) :: Nil
    }

    // J（左に足）。
    def jCells(r: Int32): List[Cell] = match r {
        case 0 => (0, 0) :: (0, 1) :: (1, 1) :: (2, 1) :: Nil
        case 1 => (1, 0) :: (2, 0) :: (1, 1) :: (1, 2) :: Nil
        case 2 => (0, 1) :: (1, 1) :: (2, 1) :: (2, 2) :: Nil
        case _ => (1, 0) :: (1, 1) :: (0, 2) :: (1, 2) :: Nil
    }

    // L（右に足）。
    def lCells(r: Int32): List[Cell] = match r {
        case 0 => (2, 0) :: (0, 1) :: (1, 1) :: (2, 1) :: Nil
        case 1 => (1, 0) :: (1, 1) :: (1, 2) :: (2, 2) :: Nil
        case 2 => (0, 1) :: (1, 1) :: (2, 1) :: (0, 2) :: Nil
        case _ => (0, 0) :: (1, 0) :: (1, 1) :: (1, 2) :: Nil
    }

    // ── 簡易ウォールキック ──
    // 回転後に盤外や他のブロックとぶつかったら、これらの平行移動を順に試して
    // 「最初に収まる」ずらしを採用する（World.tryRotate が使う）。
    // dx>0 は右、dy<0 は上に持ち上げる。全部だめなら回転しない。
    // 本格 SRS の緻密なオフセット表ではなく「壁際でも入る」を満たす最小限。

    /// 回転の救済候補（(dCol, dRow) の順に試す）。先頭 (0,0) は「ずらさず入るか」。
    pub def wallKickOffsets(): List[Cell] =
        (0, 0) :: (1, 0) :: (-1, 0) :: (2, 0) :: (-2, 0) :: (0, -1) :: Nil

    // ── 7 種すべて（7-bag と NEXT が舐める並び） ──

    /// テトリスの 7 種（bag のシャッフル元・色の割り当ての基準になる不変の並び）。
    pub def all(): List[Kind] =
        Kind.I :: Kind.O :: Kind.T :: Kind.S :: Kind.Z :: Kind.J :: Kind.L :: Nil
}
