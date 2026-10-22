/// The fixture of `--spans` (test/run.sh compares the index with test/expected-spans-<stage>.txt).
mod Shapes {
    use Shapes.area

    pub enum Shape {
        case Circle(Int32),
        case Square(Int32),
        case Dot
    }

    pub type alias World = { shape = Shape, count = Int32 }

    pub type alias Pair = { left = Int32, right = Int32 }

    pub def area(s: Shape): Int32 = match s {
        case Shape.Circle(r) => 3 * r * r
        case Shape.Square(a) => a * a
        case _ => 0
    }

    pub def isRound(s: Shape): Bool = match s {
        case Shape.Circle(_) => true
        case other if area(other) > 10 => false
        case other => area(other) == 0
    }

    def make(): World = { shape = Shape.Dot, count = 0 }

    pub def fromParam(w: World): Int32 = w#count + area(w#shape)

    pub def fromLet(): Int32 =
        let w: World = make();
        w#count

    pub def fromCall(): Shape = make()#shape

    pub def fromRow(): Int32 = List.sum(List.map(p -> p#left + p#right, ({ left = 1, right = 2 } :: Nil)))

    pub def open(r: { count = Int32 | a }): Int32 = r#count

    pub def bump(w: World): World = { count = w#count + 1 | w }

    pub def piped(xs: List[Shape]): Int32 = xs |> List.map(Shapes.area) |> List.sum

    pub def wide(): String = "円の面積" + ToString.toString(area(Shape.Circle(2)))

    pub type alias Point = { x = Int32, y = Int32 }

    pub type alias Size = { x = Int32, y = Int32 }

    pub def spread(): Int32 = List.sum(List.map(p -> p#x, ({ x = 1, y = 2 } :: Nil)))
}
