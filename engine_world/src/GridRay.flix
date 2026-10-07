// GridRay — マス目の世界で「start から goal までの間に壁が挟まるか」（視線の遮蔽）。
// 壁の向こうの松明を消す・敵から主人公が見えるか、のような見通し判定に使う。
// solid の判定は関数で注入する（WallFaces と同じ並び — MapDoc の形を知らない）。
//
// 中身は Amanatides–Woo 型のグリッド横断（DDA）。セル中心が整数・境界が ±0.5 の
// 座標系で、線分が通過するマスを漏れなく順にたどる（標本を打つ行進ではないので、
// 角を薄くかすめるマスも拾い損ねない）。start と goal のマス自身も対象 —
// goal が壁面ぎりぎり（壁掛けの松明など）のときは ignore 述語でそのマスを除く。
// 線分が角をちょうど通る縮退では x 側へ先に進むと決めてある（呼ぶたび同じ結果）。
pub mod GridRay {

    /// 軸 1 本ぶんの横断の設定と進み具合。step = マス番号の増分（-1 / 0 / +1）、
    /// tDelta = 境界を 1 枚越えるのに要する t（線分全体を 0..1 とした割合）、
    /// tMax = 次の境界に届く t。
    type alias Axis = { step = Int32, tDelta = Float64, tMax = Float64 }

    /// 実質無限大の t。動かない軸の tMax に入れて「その軸の境界には永遠に届かない」
    /// を比較だけで表す（分母 0 の除算を避ける）。
    def farAway(): Float64 = Float64.maxValue()

    /// 1 軸ぶんの横断設定を作る。s = 始点（マス境界が整数に来るよう +0.5 ずらした座標）、
    /// d = その軸の移動量（goal - start）。
    def axisSetup(s: Float64, d: Float64): Axis =
        let cellEdge = Int32.toFloat64(Num.floorInt(s));
        if (d > 0.0)
            { step = 1, tDelta = 1.0 / d, tMax = (cellEdge + 1.0 - s) / d }
        else if (d < 0.0)
            { step = -1, tDelta = 1.0 / (-d), tMax = (s - cellEdge) / (-d) }
        else
            { step = 0, tDelta = farAway(), tMax = farAway() }

    /// hit なマスに出会うまで境界を 1 枚ずつ越える。tMax が小さい軸が先、
    /// 同時（角をちょうど通る）なら x 側 — どちらでも幾何としては正しいので、
    /// 決定性のために片方に固定してある。fuel は浮動小数の誤差で goal のマスに
    /// 届かない事故への保険（マス数ぶんしか歩かない）。
    def walk(hit: Grid.Cell -> Bool, goalCell: Grid.Cell, fuel: Int32,
             ax: Axis, ay: Axis, cell: Grid.Cell): Bool =
        if (hit(cell)) true
        else if ((cell#x == goalCell#x and cell#y == goalCell#y) or fuel <= 0) false
        else if (ax#tMax <= ay#tMax)
            walk(hit, goalCell, fuel - 1, { tMax = ax#tMax + ax#tDelta | ax }, ay,
                 { x = cell#x + ax#step, y = cell#y })
        else
            walk(hit, goalCell, fuel - 1, ax, { tMax = ay#tMax + ay#tDelta | ay },
                 { x = cell#x, y = cell#y + ay#step })

    /// start → goal の間に solid なマスが挟まるか。両端のマス自身も数えるので、
    /// goal が壁マスに掛かる物（松明など）のときは ignore 述語でそのマスを除く
    /// （無視が要らなければ `_ -> false`）。
    /// 点がどのマスに属するかは Grid.cellAtCentered の契約 — 境界 ±0.5 ちょうどの点は
    /// + 側のマスに属する。fuel（歩数の保険）が尽きたときは「見える」側（false）にする
    /// fail-open — 誤差の事故で急に視界が塞がるより、見え過ぎる方を選ぶ。
    pub def blocked(solidAt: Grid.Cell -> Bool, ignore: Grid.Cell -> Bool,
                    start: Vec2.Vec2, goal: Vec2.Vec2): Bool =
        let startCell = Grid.cellAtCentered(start);
        let goalCell = Grid.cellAtCentered(goal);
        let d = Vec2.sub(goal, start);
        walk(c -> solidAt(c) and not ignore(c), goalCell,
             Int32.abs(goalCell#x - startCell#x) + Int32.abs(goalCell#y - startCell#y),
             axisSetup(start#x + 0.5, d#x), axisSetup(start#y + 0.5, d#y), startCell)
}
