// MultiMesh3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 同じ形を変換の並びで何体も置く物（閉じた型。Godot の MultiMesh・three.js の InstancedMesh・Unity の Graphics.RenderMeshInstanced に当たる）。
/// 場面の multiMeshes に載せると、GL と WebGPU の描き手は 1 体ずつの置いた物に開かずに並びを上げ、1 回の instanced draw で描く。
/// 群れ全体の境界で視錐台の外を間引く（1 体ずつは間引かない）。参照が同じ値を続けて渡すコマは、描き手が詰めた並びを持ち越す。
/// 向かない物（engine の docs/scene3d.md の「描く量」）: 1 体ずつ選ぶ・光らせる物・透けて重なる大きな板（不透明で描く）・骨で動く物（バインドポーズで描く）・
/// マップ全体に散らばった 1 つ（区画ごとに分ける）・動かない物（staticGroup）。
pub mod MultiMesh3d {

    /// 中身（描き手と engine_tools 専用。ゲームは build・withColors・withMaterial で作る）。
    /// mesh = 形・transforms = 1 体 12 個（行優先の 3×4 = 基底の行 3 つ、各行の 4 つ目が平行移動。Godot の MultiMesh の buffer と同じ並び）・
    /// colors = 1 体 3 個（sRGB の rgb。頂点の色に掛ける。None なら白）・material = 材質（半透明は withMaterial で落としてある）・
    /// blendRequested = withMaterial に半透明の材質を渡されたか（描き手が知らせる）・bounds = 群れ全体の world の境界（頂点の無い形と 0 体は None）。
    pub type alias MultiMeshFields = { mesh = Mesh3d.Mesh3d, transforms = Vector[Float64], colors = Option[Vector[Float64]],
                                       material = Option[Scene3d.Material3d], blendRequested = Bool, bounds = Option[Mesh3d.Bounds] }

    enum MultiMeshData { case MultiMeshData(MultiMeshFields) }

    pub type alias MultiMesh3d = MultiMeshData

    /// mesh を n 体、i 体目を worldOf(i) の行列で置く（行列の下の行は読まない）。群れ全体の境界もここで出す。
    pub def build(mesh: Mesh3d.Mesh3d, n: Int32, worldOf: Int32 -> Mat4.Mat4): MultiMesh3d =
        let count = Int32.max(0, n);
        let (transforms, bounds) = region rc {
            let a = Array.repeat(rc, count * 12, 0.0);
            putFrom(a, worldOf, 0, count);
            let acc = Array#{ Float64.maxValue(), Float64.maxValue(), Float64.maxValue(), Float64.minValue(), Float64.minValue(), Float64.minValue() } @ rc;
            (Array.toVector(a), boundsOf(mesh, a, acc, count))
        };
        MultiMeshData.MultiMeshData({ mesh = mesh, transforms = transforms, colors = None, material = None, blendRequested = false, bounds = bounds })

    def putFrom(a: Array[Float64, r], worldOf: Int32 -> Mat4.Mat4, i: Int32, n: Int32): Unit \ r =
        if (i >= n) () else { putOne(a, worldOf, i); putFrom(a, worldOf, i + 1, n) }

    // WhyNot: 末尾を呼び出しで終えない — 物の数だけ回る putFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def putOne(a: Array[Float64, r], worldOf: Int32 -> Mat4.Mat4, i: Int32): Unit \ r =
        let m = Mat4.asRows(worldOf(i));
        let o = i * 12;
        let put = (k: Int32) -> Array.put(Vector.get(k, m), o + k, a);
        put(0); put(1); put(2); put(3); put(4); put(5); put(6); put(7); put(8); put(9); put(10); put(11);
        ()

    // 群れ全体の境界 = 各体の (形の境界の真ん中を写した点) ± (形の境界の対角の半分 × 3×3 の Frobenius の長さ) の最小と最大。
    // WhyNot: 各体の 8 つの角を写さない — 体ごとに 8 回の写しになり、作る代金が詰める代金を超える。球で囲めば外れる側（大きめ）に倒れるだけで、絵は変わらない。
    def boundsOf(mesh: Mesh3d.Mesh3d, a: Array[Float64, r], acc: Array[Float64, r], n: Int32): Option[Mesh3d.Bounds] \ r =
        if (n == 0 or Mesh3d.vertexCount(mesh) == 0) None
        else {
            let b = Mesh3d.bounds(mesh);
            let c = Vec3.mul(Vec3.add(b#min, b#max), 0.5);
            let h = Vec3.mul(Vec3.sub(b#max, b#min), 0.5);
            let radius = Num.sqrt(h#x * h#x + h#y * h#y + h#z * h#z);
            growFrom(acc, a, c, radius, 0, n);
            let at = (k: Int32) -> Array.get(k, acc);
            Some({ min = Vec3.v3(at(0), at(1), at(2)), max = Vec3.v3(at(3), at(4), at(5)) })
        }

    def growFrom(acc: Array[Float64, r], a: Array[Float64, r], c: Vec3.Vec3, radius: Float64, i: Int32, n: Int32): Unit \ r =
        if (i >= n) () else { growOne(acc, a, c, radius, i); growFrom(acc, a, c, radius, i + 1, n) }

    // WhyNot: 末尾を呼び出しで終えない — growFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def growOne(acc: Array[Float64, r], a: Array[Float64, r], c: Vec3.Vec3, radius: Float64, i: Int32): Unit \ r =
        let o = i * 12;
        let m = (k: Int32) -> Array.get(o + k, a);
        let sq = (k: Int32) -> m(k) * m(k);
        let reach = radius * Num.sqrt(sq(0) + sq(1) + sq(2) + sq(4) + sq(5) + sq(6) + sq(8) + sq(9) + sq(10));
        let x = m(0) * c#x + m(1) * c#y + m(2) * c#z + m(3);
        let y = m(4) * c#x + m(5) * c#y + m(6) * c#z + m(7);
        let z = m(8) * c#x + m(9) * c#y + m(10) * c#z + m(11);
        let low = (k: Int32, v: Float64) -> Array.put(Float64.min(Array.get(k, acc), v - reach), k, acc);
        let high = (k: Int32, v: Float64) -> Array.put(Float64.max(Array.get(k, acc), v + reach), k, acc);
        low(0, x); low(1, y); low(2, z); high(3, x); high(4, y); high(5, z);
        ()

    /// i 体目の色を colorOf(i) にする（sRGB。頂点の色に掛ける。instances の withTint と同じ意味）。
    pub def withColors(colorOf: Int32 -> Color, mm: MultiMesh3d): MultiMesh3d =
        let MultiMeshData.MultiMeshData(r) = mm;
        let n = Vector.length(r#transforms) / 12;
        let colors = Vector.range(0, n * 3) |> Vector.map(k -> {
            let c = colorOf(k / 3);
            match Int32.modulo(k, 3) {
                case 0 => c#r
                case 1 => c#g
                case _ => c#b
            }
        });
        MultiMeshData.MultiMeshData({ colors = Some(colors) | r })

    /// 材質を付ける。半透明の材質は不透明として描く（中の 1 体ずつを奥から手前に並べられないため）。描き手は初めて描くコマに 1 回知らせる。
    // WhyNot: 半透明を描き手の側で落とさない — 計画と CPU の描き手（toInstances）の 2 か所で落とすことになり、片方の直し忘れで絵が食い違う。
    pub def withMaterial(m: Scene3d.Material3d, mm: MultiMesh3d): MultiMesh3d =
        let MultiMeshData.MultiMeshData(r) = mm;
        let blend = Scene3d.materialFieldsOf(m)#blend;
        MultiMeshData.MultiMeshData({ material = Some(if (blend) Scene3d.withAlphaBlend(false, m) else m), blendRequested = blend | r })

    /// 中身を読む（描き手と engine_tools 専用）。
    pub def fieldsOf(mm: MultiMesh3d): MultiMeshFields =
        let MultiMeshData.MultiMeshData(r) = mm;
        r

    /// 置く体の数。
    pub def countOf(mm: MultiMesh3d): Int32 = Vector.length(fieldsOf(mm)#transforms) / 12

    /// i 体目の色（colors が無いか足りなければ白・描き手と engine_tools 専用）。
    pub def colorAt(colors: Option[Vector[Float64]], i: Int32): Color = match colors {
        case Some(c) if Vector.length(c) >= i * 3 + 3 => Color.rgb(Vector.get(i * 3, c), Vector.get(i * 3 + 1, c), Vector.get(i * 3 + 2, c))
        case _                                         => Color.rgb(1.0, 1.0, 1.0)
    }

    /// 体を原点に置いた 1 体（描き手と engine_tools 専用。材質のプログラム・絵の名前・先に用意する物を 1 体で決める時に使う）。
    pub def headOf(mm: MultiMesh3d): Scene3d.Instance3d =
        let r = fieldsOf(mm);
        let placed = Scene3d.meshInstance(r#mesh, Mat4.identity());
        match r#material {
            case Some(m) => Scene3d.withMaterial(m, placed)
            case None    => placed
        }

    /// 材質が読む絵の名前（体は同じ材質なので headOf の 1 体で数える・描き手と engine_tools 専用）。
    // WhyNot: toInstances で開いて数えない — 毎コマ数える道（ブラウザの使った絵の記録・撮りの鍵）で全部の体を作ることになる。
    pub def textureNamesOf(mm: MultiMesh3d): List[String] = Scene3d.textureNamesOf(headOf(mm))

    /// 1 体ずつの置いた物に作り直した並び（CPU の描き手と描き出しの鍵が使う。来た順）。全部の体を作るので、毎コマ呼ぶ道（GL・WebGPU の描き手）では使わない。
    pub def toInstances(mm: MultiMesh3d): List[Scene3d.Instance3d] =
        let r = fieldsOf(mm);
        let t = (k: Int32) -> Vector.get(k, r#transforms);
        List.range(0, countOf(mm)) |> List.map(i -> {
            let o = i * 12;
            let world = Mat4.mul(Mat4.translate(Vec3.v3(t(o + 3), t(o + 7), t(o + 11))),
                                 Mat4.ofLinearRows(Vec3.v3(t(o), t(o + 1), t(o + 2)), Vec3.v3(t(o + 4), t(o + 5), t(o + 6)), Vec3.v3(t(o + 8), t(o + 9), t(o + 10))));
            let placed = Scene3d.withTint(colorAt(r#colors, i), Scene3d.meshInstance(r#mesh, world));
            match r#material {
                case Some(m) => Scene3d.withMaterial(m, placed)
                case None    => placed
            }
        })
}
