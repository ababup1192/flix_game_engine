/// The fixture of `bin/fge refactor expand-wildcard` and `remove-dead` (go/internal/refactor の e2e と単体テスト).
mod Zoo {
    pub enum Animal {
        case Cat,
        case Dog(Int32),
        case Bird(Int32, Bool),
        case Fish
    }

    /// What it says.
    pub def sound(a: Animal): String = match a {
        case Animal.Cat => "meow"
        case _          => "..."
    }

    pub def legs(a: Animal): Int32 = match a {
        case Animal.Dog(_) => 4
        case other         => describe(other)
    }

    def describe(a: Animal): Int32 = match a {
        case Animal.Bird(n, _) if n > 1 => n
        case _ if true => 1
        case _ => 0
    }

    pub def pair(a: Animal, b: Animal): String = match a {
        case Animal.Cat => "cat"
        case _ => match b {
            case Animal.Dog(_) => "x-dog"
            case _ => "x-other"
        }
    }

    /// Only the tests call this.
    @Deprecated
    pub def onlyTested(x: Int32): Int32 = helper(x) + 1

    def helper(x: Int32): Int32 = x * 2

    pub def onlyTestedToo(x: Int32): Int32 = x + 2

    pub def unused(): Int32 = 7

    pub def used(): Int32 = 1
}
