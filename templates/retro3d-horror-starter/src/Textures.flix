// Textures — 仮の建物と非常口のプレートに貼る絵を、コードで作る（純粋）。校舎の glb が届けば建物の絵は glb の物を使い、
// ここの絵は非常口のプレートだけが使う。どれも 1 枚 64×64（プレートは 16×8）で、Nearest で読む前提の粗い画素。
// 色は画面の値（sRGB）。木目は板ごとに色を振り、板の継ぎ目を暗く、木目の筋を波で引く。
mod Textures {
    use fge::{Hash01, Num, Texture3d}

    /// 仮の建物の材質の種類。
    pub enum Surface with Eq, Order, ToString {
        case FloorWood   // 床の板
        case Plaster     // 壁の上の漆喰
        case Wainscot    // 壁の下 1 m の腰板
        case Ceiling     // 天井の板
        case Furniture   // 机・棚・下駄箱
        case Stairs      // 階段の坂と踊り場
        case ExitSign    // 非常口のプレート
    }

    pub def surfaces(): List[Surface] =
        Surface.FloorWood :: Surface.Plaster :: Surface.Wainscot :: Surface.Ceiling :: Surface.Furniture :: Surface.Stairs :: Surface.ExitSign :: Nil

    type alias Rgb = (Float64, Float64, Float64)

    /// 材質の絵（作れなければ None。大きさは決め打ちなので失敗しない）。
    pub def build(s: Surface): Option[Texture3d.Texture3d] = match s {
        case Surface.ExitSign => image(16, 8, exitSign)
        case _                => image(64, 64, pixelOf(s))
    }

    def pixelOf(s: Surface): (Int32, Int32) -> Rgb = match s {
        case Surface.FloorWood => planks((0.40, 0.27, 0.16), 16, false, 11)
        case Surface.Plaster   => plaster
        case Surface.Wainscot  => planks((0.31, 0.20, 0.12), 8, true, 23)
        case Surface.Ceiling   => planks((0.44, 0.38, 0.29), 12, false, 37)
        case Surface.Furniture => planks((0.46, 0.32, 0.19), 32, false, 41)
        case Surface.Stairs    => planks((0.35, 0.23, 0.14), 16, false, 53)
        case Surface.ExitSign  => exitSign
    }

    def image(w: Int32, h: Int32, f: (Int32, Int32) -> Rgb): Option[Texture3d.Texture3d] =
        let argb = Vector.range(0, w * h) |> Vector.map(i -> argbOf(f(Int32.modulo(i, w), i / w)));
        Texture3d.fromArgb(w, h, argb) |> Result.toOption

    def argbOf(c: Rgb): Int32 =
        let (r, g, b) = c;
        let byte = (v: Float64) -> Num.clampInt(0, 255, Float64.round(Num.clamp01(v) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0));
        Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(byte(r), 16), Int32.bitwiseOr(Int32.leftShift(byte(g), 8), byte(b))))

    def scale(k: Float64, c: Rgb): Rgb = let (r, g, b) = c; (r * k, g * k, b * k)

    /// 板張り。plankPx = 板の幅（画素）・vertical = 板が縦に並ぶ（腰板）。板ごとに明るさを振り、継ぎ目の 1 画素を暗くし、
    /// 板の向きに流れる木目の筋を足す。板の端（継ぎ目の横の切れ目）は板ごとにずらす。
    def planks(base: Rgb, plankPx: Int32, vertical: Bool, seed: Int32): (Int32, Int32) -> Rgb = (x, y) -> {
        let (along, across) = if (vertical) (y, x) else (x, y);
        let plank = across / plankPx;
        let inPlank = Int32.modulo(across, plankPx);
        let tone = 0.82 + 0.3 * Hash01.at(plank, seed);
        let offset = Num.floorInt(Hash01.at(plank, seed + 1) * 64.0);
        let endJoint = Int32.modulo(along + offset, 64) == 0;
        let phase = Hash01.at(plank, seed + 2) * 6.28;
        let ring = Num.sin(Int32.toFloat64(inPlank) * 0.9 + Num.sin(Int32.toFloat64(along) * 0.11 + phase) * 2.2 + phase);
        let grain = if (ring > 0.82) 0.78 else if (ring < -0.9) 1.08 else 1.0;
        let speck = 0.94 + 0.12 * Hash01.at(along * 131 + across, seed + 3);
        let seam = inPlank == 0 or endJoint;
        scale(if (seam) 0.45 else tone * grain * speck, base)
    }

    /// 漆喰。薄い灰色に細かいむらと、下の方ほど濃い汚れ。
    def plaster(x: Int32, y: Int32): Rgb =
        let speck = 0.9 + 0.14 * Hash01.at(y * 64 + x, 71);
        let blotch = 0.94 + 0.08 * Num.sin(Int32.toFloat64(x) * 0.21 + Num.sin(Int32.toFloat64(y) * 0.17) * 1.6);
        let grime = 1.0 - 0.12 * Int32.toFloat64(y) / 64.0;
        scale(speck * blotch * grime, (0.62, 0.60, 0.55))

    /// 非常口のプレート: 緑の地に白い人の形（逃げる向きの矢印の代わりの 1 本の帯）。
    def exitSign(x: Int32, y: Int32): Rgb =
        let figure = (x >= 3 and x <= 5 and y >= 2 and y <= 6) or (y == 4 and x >= 7 and x <= 13);
        if (figure) (0.92, 0.98, 0.92) else (0.05, 0.62, 0.30)
}
