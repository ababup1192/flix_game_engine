// Facing — 向き（地図の東西南北）。座標は地図の座標（x = 東・y = 北）。
mod Facing {
    /// 向き。
    pub enum Dir with Eq, ToString {
        case North
        case East
        case South
        case West
    }

    /// 向きの字（n・e・s・w）。知らない字は南（正面）。
    pub def ofLetter(letter: String): Dir = match letter {
        case "n" => Dir.North
        case "e" => Dir.East
        case "w" => Dir.West
        case _   => Dir.South
    }

    /// 向きの字（ofLetter の逆）。
    pub def letterOf(d: Dir): String = match d {
        case Dir.North => "n"
        case Dir.East  => "e"
        case Dir.South => "s"
        case Dir.West  => "w"
    }

    /// 向きの長さ 1 の (x, y)。
    pub def unitOf(d: Dir): (Float64, Float64) = match d {
        case Dir.North => (0.0, 1.0)
        case Dir.East  => (1.0, 0.0)
        case Dir.South => (0.0, -1.0)
        case Dir.West  => (-1.0, 0.0)
    }

    /// 動く向き (x, y) に近い 4 方向（横と縦の大きい方）。
    pub def nearestOf(v: (Float64, Float64)): Dir =
        let (x, y) = v;
        if (Float64.abs(x) > Float64.abs(y)) { if (x > 0.0) Dir.East else Dir.West }
        else if (y > 0.0) Dir.North else Dir.South
}
