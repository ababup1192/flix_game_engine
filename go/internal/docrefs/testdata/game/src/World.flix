/// 小さなゲームの World（doc-refs のテスト用）。
mod World {
    use Board.Cell

    pub enum Phase with Eq {
        case Title, case Home
        case Fight(Int32)
    }

    pub type alias Rec = { phase = Phase, turn = Int32, clock = Float64 }

    pub def initial(): Rec = { phase = Phase.Title, turn = 0, clock = 0.0 }

    // def removedOnce(): Int32 = 1   コメントの中の宣言は数えない
    pub def step(w: Rec): Rec = {
        def local(x: Int32): Int32 = x + 1;
        let s = "def notADecl() mod Nope {";
        { turn = local(w#turn) | w }
    }

    eff Ask {
        def ask(): Int32
    }

    instance ToString[Rec] {
        pub def toString(_r: Rec): String = "rec"
    }
}
