// make refactor-smoke の場面: engine の新しい型（Camera3d の欄 lensShift・Scene3d.LightUnits）を使うゲームの小片。
mod Shot {
    use fge::{Camera3d, Scene3d, Vec2, Vec3}

    pub def shiftedCamera(): Camera3d.Camera3d =
        { lensShift = Vec2.v2(0.0, -0.5) | Camera3d.camera(Vec3.v3(0.0, 2.0, -6.0), 0.0, 0.3, 0.9) }

    /// WhyNot: 欄を全部字で書く（Camera3d.camera の doc は勧めない形）。refactor usages がパッケージの record の組み立てを数えるかを見るため。
    pub def literalCamera(): Camera3d.Camera3d =
        { eye = Vec3.v3(0.0, 1.0, 0.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    pub def shiftY(): Float64 = shiftedCamera()#lensShift#y

    pub def lightUnits(): Scene3d.LightUnits = Scene3d.LightUnits.Physical
}

/// companion mod を持つ enum（case の名前は Mood.Mood）。
enum Mood {
    case Mood(Int32)
}

mod Mood {
    pub def level(m: Mood): Int32 = match m {
        case Mood.Mood(n) => n
    }
}

def main(): Unit \ IO = println("${Shot.shiftY()} ${Shot.lightUnits()} ${Shot.literalCamera()#fovY} ${Mood.level(Mood.Mood(1))}")
