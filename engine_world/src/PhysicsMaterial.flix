// PhysicsMaterial — 剛体の材質（摩擦・跳ね返り・密度）。Collider2d は材質を名前で指し、PhysicsWorld2d.withMaterials の表で引く。
// 名前で引くので、Doc を読み直すと、もう居る体の摩擦と跳ね返りにも次の刻みから効く（重さは体を作った時に出すので、新しく作る体からだけ）。
pub mod PhysicsMaterial {

    /// friction = 摩擦の係数（2 つの形は掛けた物の平方根）・restitution = 跳ね返り（0 = 跳ねない・2 つの形は大きい方）・
    /// density = 面積あたりの重さ（kg/m²。重さ = 密度 × 形の面積）。
    pub type alias PhysicsMaterial = { friction = Float64, restitution = Float64, density = Float64 }

    /// 名前を引けない時と、表を渡していない時の材質（摩擦 0.5・跳ね返り 0・密度 1）。
    pub def default(): PhysicsMaterial = { friction = 0.5, restitution = 0.0, density = 1.0 }

    /// 値が使える形か（摩擦と跳ね返りは 0 以上・密度は 0 より大きい・どれも有限）。
    pub def isValid(m: PhysicsMaterial): Bool =
        isFinite(m#friction) and isFinite(m#restitution) and isFinite(m#density)
            and m#friction >= 0.0 and m#restitution >= 0.0 and m#density > 0.0

    def isFinite(x: Float64): Bool = not Float64.isNan(x) and not Float64.isInfinite(x)
}
