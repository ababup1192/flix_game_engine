// Render3d.GlRows.JointTexture — GL の backend の、1 回の prepare の姿勢（行の割り当てと詰め方は Render3d.PoseRows）を 1 枚の RGBA32F のテクスチャへ上げる所。
// 1 行 = 1 姿勢・1 ジョイント = 横に 4 texel（mat4 の列の順）。頂点シェーダーは texelFetch 4 本で mat4 に組む（Render3dGlsl.skinDeclarations）。テクスチャの回し方は Render3d.GlRows.DataTexture。約束は Render3d.flix の頭。
// WhyNot: UBO に置かない — 最低保証の 16 KB に重複の無い姿勢が入り切らず、1 体ごとに書き直すことになる。SSBO は GL 3.3 と WebGL2 に無い。
// WhyNot: pub を外さない — 呼び手の Render3d（と偽の GL を通るテスト）は GlRows の外で、pub でない孫の mod には届かない（親の Render3d が pub でないので、ゲームからは見えない）。
pub mod Render3d.GlRows.JointTexture {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{State, jointTextureUnit, warnSceneOnce}
    use Render3d.GlRows.DataTexture.{bufferFor, heightFor, takeTexture}
    use Render3d.Counts.{Counter, count}
    use Render3d.PoseRows.{PoseRows, floatCountOf, packRows, posesInRowOrder}

    /// 1 つの joint 行列の幅（texel）。
    def texelsPerJoint(): Int32 = 4

    // ── 上げる ──

    /// 今の prepare の姿勢をテクスチャへ 1 回で上げて joint の unit に貼り、テクスチャの番号を返す。姿勢が無ければテクスチャを作らず None。
    pub def upload(gl: GlContext, state: State, gen: Int64, rows: PoseRows): Option[Int32] \ IO =
        if (rows#dropped > 0)
            warnSceneOnce(state, "@joint-rows", Log.fellBackLine("scene3d", "1 回の prepare の違う姿勢", "最後の行の姿勢", "${rows#limit} 行を超えた（${rows#dropped} 個）"))
        else ();
        if (rows#used == 0) None
        else {
            let buffer = bufferFor(gl, state#joints, floatCountOf(rows));
            packRows(rows#joints, posesInRowOrder(rows), buffer);
            gl.activeTexture(GlConst.TEXTURE0 + jointTextureUnit());
            let texture = takeTexture(gl, state#joints, gen, heightFor(rows#limit, rows#used));
            gl.texSubImageRgba32f(0, 0, rows#joints * texelsPerJoint(), rows#used, buffer);
            gl.activeTexture(GlConst.TEXTURE0);
            count(state, Counter.JointUploads, 1);
            Some(texture#texId)
        }
}
