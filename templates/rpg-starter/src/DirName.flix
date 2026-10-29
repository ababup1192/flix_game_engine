// DirName — Doc と始まりの引数に書く向きの名前（up / down / left / right）と Dir4 の行き来。
mod DirName {
    use fge::{Dir4}

    /// 向きの名前 → 向き（知らない名前は None。読む側が既定へ落として言う）。
    pub def dirOf(name: String): Option[Dir4.Dir4] = match name {
        case "up"    => Some(Dir4.Dir4.Up)
        case "down"  => Some(Dir4.Dir4.Down)
        case "left"  => Some(Dir4.Dir4.Left)
        case "right" => Some(Dir4.Dir4.Right)
        case _       => None
    }

    /// 書ける名前（知らせる文に並べる）。
    pub def names(): String = "up / down / left / right"
}
