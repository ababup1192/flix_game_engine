// Dir4 — 画面上の上下左右の4方向を、1つの値としてまとめて表す。
// 生の座標差や真偽値の寄せ集めにせず enum にすることで、向きの比較・反転・回転を
// そのつど計算し直さずに扱える。
// 利用例: 4方向入力 / タイルを1マスずつ動かす移動 / スプライトがどちらを向くか。
// 注意: 斜めも「なし」も無い（必要なら Option[Dir4]）。画面座標ゆえ y は下向きで、Up は上へ -1。

pub mod Dir4 {

    /// 四方位のいずれか。斜めも「なし」も無い: 「方向があるかもしれない」を扱う呼び側は
    /// Option[Dir4] を使う。
    pub enum Dir4 with Eq, ToString {
        case Up
        case Down
        case Left
        case Right
    }

    /// この方向がグリッド上で進む単位ステップ、(列, 行) として。y は下向きゆえ Up は
    /// (0, -1)、Down は (0, 1) — 画面ピクセルや大半のタイルマップと同じ規約。
    pub def delta(d: Dir4): (Int32, Int32) = match d {
        case Dir4.Up    => (0, -1)
        case Dir4.Down  => (0, 1)
        case Dir4.Left  => (-1, 0)
        case Dir4.Right => (1, 0)
    }

    /// 逆を向いた方向（Up <-> Down、Left <-> Right）。
    pub def opposite(d: Dir4): Dir4 = match d {
        case Dir4.Up    => Dir4.Down
        case Dir4.Down  => Dir4.Up
        case Dir4.Left  => Dir4.Right
        case Dir4.Right => Dir4.Left
    }

    /// 左右を反転した方向（Left <-> Right）。Up と Down は変わらない。水平反転の鏡像が
    /// 片方の向きの絵をその逆向きに使い回すときに有用。
    pub def mirrorX(d: Dir4): Dir4 = match d {
        case Dir4.Left  => Dir4.Right
        case Dir4.Right => Dir4.Left
        case Dir4.Up    => Dir4.Up
        case Dir4.Down  => Dir4.Down
    }

    /// 画面上で時計回りに 90 度: Up -> Right -> Down -> Left -> Up。
    /// （y が下向きのとき、プレイヤーから見て時計回り。）
    pub def rotateCw(d: Dir4): Dir4 = match d {
        case Dir4.Up    => Dir4.Right
        case Dir4.Right => Dir4.Down
        case Dir4.Down  => Dir4.Left
        case Dir4.Left  => Dir4.Up
    }

    /// ステップベクトルから方向を復元する（ちょうど四つの単位ステップのいずれかのとき）。
    /// それ以外のベクトル（ゼロ・斜め・1 セルより長い）は単一の方向を持たず None を返す
    /// — `delta` の逆。
    pub def fromDelta(dx: Int32, dy: Int32): Option[Dir4] = match (dx, dy) {
        case (0, -1) => Some(Dir4.Up)
        case (0, 1)  => Some(Dir4.Down)
        case (-1, 0) => Some(Dir4.Left)
        case (1, 0)  => Some(Dir4.Right)
        case _       => None
    }

    /// 四方向すべてを固定順 Up, Down, Left, Right で。テストや隣接セルの走査に便利。
    pub def all(): List[Dir4] =
        Dir4.Up :: Dir4.Down :: Dir4.Left :: Dir4.Right :: Nil
}
