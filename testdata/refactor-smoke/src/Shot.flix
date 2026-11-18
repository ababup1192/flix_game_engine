// make refactor-smoke の場面: engine の新しい型（Camera3d の欄 lensShift・Scene3d.LightUnits）を使うゲームの小片。
mod Shot {
    use fge::{Camera3d, Scene3d, Vec2, Vec3}

    pub def shiftedCamera(): Camera3d.Camera3d =
        { lensShift = Vec2.v2(0.0, -0.5) | Camera3d.camera(Vec3.v3(0.0, 2.0, -6.0), 0.0, 0.3, 0.9) }

    pub def shiftY(): Float64 = shiftedCamera()#lensShift#y

    pub def lightUnits(): Scene3d.LightUnits = Scene3d.LightUnits.Physical
}

def main(): Unit \ IO = println("${Shot.shiftY()} ${Shot.lightUnits()}")
