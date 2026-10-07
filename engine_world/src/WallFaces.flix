// WallFaces — マス目の迷路から「カメラに見える壁の境界面」だけを集める純幾何。
// 壁マスと空きマスの境界の縦のストリップを、足元の 2D 線分（a→b）+ 外向き法線として返す。
// 壁どうしの内部面は出さず、カメラに背を向けた面（裏面）も落とす。
//
// solid の判定は関数で注入する（MapDoc の形を知らない — Terrain と同じ並び）。
// 投影・近クリップは Persp、描画順は Painter の仕事で、ここは世界空間まで。
pub mod WallFaces {

    /// 面の足元の 2D 線分（a→b）と、外向き法線・属する壁マス。
    /// セル中心が整数の座標系（1 マス = 1.0）で、面はその境界 x±0.5 / y±0.5 にある。
    pub type alias Face = { a = Vec2.Vec2, b = Vec2.Vec2, normal = Vec2.Vec2, cell = Grid.Cell }

    /// eye の周囲 radius マスを走査し、壁と空きの境界のうち eye に見える面だけを集める。
    /// 走査順（x → y → Dir4.all()）は安定 — 同距離の面の並びが呼ぶたびに変わらない。
    pub def visibleFaces(solidAt: Grid.Cell -> Bool, radius: Int32, eye: Vec2.Vec2): List[Face] =
        let center = Grid.cellAtCentered(eye);
        List.range(center#x - radius, center#x + radius + 1) |> List.flatMap(x ->
            List.range(center#y - radius, center#y + radius + 1) |> List.flatMap(y -> {
                let cell = { x = x, y = y };
                if (not solidAt(cell)) Nil
                else Dir4.all() |> List.filterMap(dir ->
                    faceIfVisible(solidAt, eye, cell, dir))
            }))

    /// 壁マス cell の dir 側の面。隣が空きで、eye へ向いていれば残す。
    def faceIfVisible(solidAt: Grid.Cell -> Bool, eye: Vec2.Vec2,
                    cell: Grid.Cell, dir: Dir4.Dir4): Option[Face] =
        if (solidAt(Grid.neighborOf(cell, dir))) None
        else {
            let face = faceOf(cell, dir);
            // 裏面カリング: 面の開いた側（法線の向く側）に目が無ければ見えない。
            if (Vec2.dot(face#normal, Vec2.sub(eye, centerOf(face))) <= 0.0) None
            else Some(face)
        }

    /// 壁マスの dir 側の面（visibleFaces を通さず 1 枚だけ欲しいとき — 壁掛けの
    /// 松明・扉・看板の位置決めに使う）。
    pub def faceOf(cell: Grid.Cell, dir: Dir4.Dir4): Face =
        let x = Int32.toFloat64(cell#x);
        let y = Int32.toFloat64(cell#y);
        let (dx, dy) = Dir4.delta(dir);
        let normal = { x = Int32.toFloat64(dx), y = Int32.toFloat64(dy) };
        match dir {
            case Dir4.Dir4.Up    => { a = { x = x - 0.5, y = y - 0.5 },
                                      b = { x = x + 0.5, y = y - 0.5 }, normal = normal, cell = cell }
            case Dir4.Dir4.Down  => { a = { x = x - 0.5, y = y + 0.5 },
                                      b = { x = x + 0.5, y = y + 0.5 }, normal = normal, cell = cell }
            case Dir4.Dir4.Left  => { a = { x = x - 0.5, y = y - 0.5 },
                                      b = { x = x - 0.5, y = y + 0.5 }, normal = normal, cell = cell }
            case Dir4.Dir4.Right => { a = { x = x + 0.5, y = y - 0.5 },
                                      b = { x = x + 0.5, y = y + 0.5 }, normal = normal, cell = cell }
        }

    /// 面に沿った t（0..1。a が 0・b が 1）の世界座標。目地や飾りを
    /// 世界に固定する（歩いても滑らない）ための足がかり。
    pub def pointAt(face: Face, t: Float64): Vec2.Vec2 =
        Vec2.lerp(face#a, face#b, t)

    /// 面の足元の中点（裏面カリングと「面のわずかに手前」の基準点）。
    pub def centerOf(face: Face): Vec2.Vec2 =
        Vec2.mul(Vec2.add(face#a, face#b), 0.5)
}
