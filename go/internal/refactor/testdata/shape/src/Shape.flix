/// remove-field・fix-construction のお手本: World の欄 old は読み書きが 0 で、組み立て（initial・別名 Model を通した fresh・
/// テストの作り手）にだけ出てくる。Panel の case Open の record の欄 top も同じ。
/// Pair は World と欄の組が違う別の record（当てない）。文字列の中の `{ … }` も当てない。
mod Shape {
    pub type alias World = {
        speed = Int32,
        // 使われない欄
        old = Bool,
        clock = Float64,
        pointer = { x = Float64, y = Float64 }
    }

    /// World の別名（組み立ては欄の組で当てるので、別名を通しても拾う）。
    pub type alias Model = World

    pub type alias Pair = { speed = Int32, clock = Float64 }

    pub enum Panel {
        case Closed
        case Open({ at = Int32, cursor = Int32, top = Int32 })
    }

    pub def initial(): World =
        { speed = 1,
          old = false,
          clock = 0.0,
          pointer = { x = -1.0, y = -1.0 } }

    pub def fresh(): Model = { speed = 2, old = true, clock = 1.0, pointer = { x = 0.0, y = 0.0 } }

    pub def pair(): Pair = { speed = 3, clock = 2.0 }

    pub def speedOf(w: World): Int32 = w#speed

    pub def tick(w: World): World = { clock = w#clock + 1.0 | w }

    pub def open(at: Int32): Panel = Panel.Open({ at = at, cursor = 0, top = 0 })

    pub def cursorOf(p: Panel): Int32 = match p {
        case Panel.Open(r) => r#cursor
        case Panel.Closed => 0
    }

    pub def note(): String = "{ speed = 1, old = false, clock = 0.0, pointer = 0 }"

    /// World と欄の組が違う record の old（受け手は owner=other。World の old には数えない）。
    pub def flagOf(r: { old = Bool, id = Int32 }): Bool = r#old

    /// 開いた row の speed（受け手は owner=maybe。World かもしれないので数える。違うと決めたら --skip で外す）。
    pub def speedOfAny(r: { speed = Int32 | rest }): Int32 = r#speed
}
