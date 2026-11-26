// SphericalHarmonics — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 周りの景色から求めた拡散の光（2 次までの実数の球面調和 9 個 × rgb・線形の量。閉じた型）。Scene3d.withSkyContribution の元。
/// 基底（engine の座標のまま・Y = 上）: Y0 = 0.282095・Y1..3 = 0.488603 × (y, z, x)・Y4 = 1.092548 xy・Y5 = 1.092548 yz・
/// Y6 = 0.315392 (3z² − 1)・Y7 = 1.092548 xz・Y8 = 0.546274 (x² − y²)。
/// 係数 c_i = 放射輝度の射影 × 畳み込みの係数（l = 0: π・1: 2π/3・2: π/4）÷ π。読む式 irradianceAt(n) = max(0, Σ c_i Y_i(n))。
/// 明るさ 1 の一様な景色で irradianceAt = 1（Environment3d の ambient 1.0 と同じ明るさ）。
pub mod SphericalHarmonics {

    /// 係数 27 個（c0 の r, g, b・c1 の r, g, b … の順）。
    enum SphericalHarmonicsData { case SphericalHarmonicsData(Vector[Float64]) }

    pub type alias SphericalHarmonics = SphericalHarmonicsData

    /// 正距円筒の景色の絵 t から求める（絵ごとに 1 回だけ求め、2 回目からは控えを返す）。機種の側の絵（PlatformImage）は画素が無いので None。
    /// 大きな絵は初めて呼んだ時に 50〜150 ms 止まるので、読み込みの時に 1 回呼んでおく。左右の向きは環境マップと同じ（Blender のパノラマは左右を反転してから渡す）。
    pub def fromEquirectangular(t: Texture3d.Texture3d): Option[SphericalHarmonics] = force Texture3d.Internal.irradianceOf(t)

    /// 係数 9 個（線形の rgb を x・y・z に入れた物。並びは型の doc の基底の順）から作る。9 個でない・NaN か無限がある、は Err。
    // WhyNot: 係数を Color で受けない — 係数は負にもなる線形の値で、Color の 0..1 の約束に合わない。
    pub def fromCoefficients(cs: List[Vec3.Vec3]): Result[String, SphericalHarmonics] =
        if (List.length(cs) != 9) Err("SphericalHarmonics.fromCoefficients: 係数は 9 個（${List.length(cs)} 個ある）")
        else {
            let flat = cs |> List.flatMap(c -> c#x :: c#y :: c#z :: Nil);
            if (List.forAll(Float64.isFinite, flat)) Ok(SphericalHarmonicsData.SphericalHarmonicsData(List.toVector(flat)))
            else Err("SphericalHarmonics.fromCoefficients: NaN か無限の係数がある")
        }

    /// 係数 9 個（fromCoefficients と同じ並び）。
    pub def coefficientsOf(sh: SphericalHarmonics): List[Vec3.Vec3] =
        let SphericalHarmonicsData.SphericalHarmonicsData(v) = sh;
        List.range(0, 9) |> List.map(i -> Vec3.v3(Vector.get(3 * i, v), Vector.get(3 * i + 1, v), Vector.get(3 * i + 2, v)))

    /// 向き n（長さ 1）の面が受ける拡散の光（線形の rgb・負は 0）。3 つの描き手の光の式（LightModel3d の木）と同じ式。
    pub def irradianceAt(sh: SphericalHarmonics, n: Vec3.Vec3): (Float64, Float64, Float64) =
        let SphericalHarmonicsData.SphericalHarmonicsData(v) = sh;
        let basis = basisAt(n#x, n#y, n#z);
        let channel = (k: Int32) -> Float64.max(0.0, List.range(0, 9) |> List.foldLeft((acc, i) -> acc + Vector.get(3 * i + k, v) * Vector.get(i, basis), 0.0));
        (channel(0), channel(1), channel(2))

    /// 向き (x, y, z) の基底 9 個（型の doc の順）。
    def basisAt(x: Float64, y: Float64, z: Float64): Vector[Float64] =
        Vector#{ 0.282095, 0.488603 * y, 0.488603 * z, 0.488603 * x, 1.092548 * x * y, 1.092548 * y * z,
                 0.315392 * (3.0 * z * z - 1.0), 1.092548 * x * z, 0.546274 * (x * x - y * y) }
}
