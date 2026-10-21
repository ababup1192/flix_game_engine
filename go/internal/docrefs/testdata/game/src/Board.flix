mod Board {
    pub enum Cell with Eq {
        case Piece(Int32), case Hole
    }
    pub def swapCells(b: List[Cell]): List[Cell] = b
}

mod Board.Gen {
    pub def fill(n: Int32): List[Board.Cell] = List.repeat(n, Board.Cell.Hole)
}

pub mod PreRoll {
    pub type alias Clock = { age = Float64 }
}
