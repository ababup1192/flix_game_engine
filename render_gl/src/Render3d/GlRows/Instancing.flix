// Render3d.GlRows.Instancing — GL の backend の、1 回の prepare の全部の batch の 1 体ごとの値（並びと番号の振り方は Render3d.InstanceValues）を 1 枚の RGBA32F のテクスチャへ上げる所。
// 頂点シェーダーは uInstanceBase + gl_InstanceID で引く（Render3dGlsl.instanceDeclarations）。テクスチャの回し方は Render3d.GlRows.DataTexture。約束は Render3d.flix の頭。
// WhyNot: GL で頂点の属性に置かない — GL 3.3 と WebGL2 に baseInstance が無く、batch にならない draw ごとに 8 本の属性を指し直すことになり、WebGL2 では submit が 3 倍を超える。
// WhyNot: pub を外さない — 呼び手の Render3d（と偽の GL を通るテスト）は GlRows の外で、pub でない孫の mod には届かない（親の Render3d が pub でないので、ゲームからは見えない）。
pub mod Render3d.GlRows.Instancing {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{MeshDraw, State, instanceTextureUnit, warnSceneOnce}
    use Render3d.Batch.{MeshBatch, SpanBatch}
    use Render3d.GlRows.DataTexture.{bufferFor, heightFor, rowLimit, takeTexture, textureWidth}
    use Render3d.InstanceValues.{countOf, mapBatches, numberSpan}
    use Render3dGlsl.{instancesPerRow, texelsPerInstance}
    use Render3d.ScenePlan.{ScenePlan}

    /// count 体を入れる行の数。
    pub def rowsFor(count: Int32): Int32 =
        (count + instancesPerRow() - 1) / instancesPerRow()

    /// 今の prepare の全部の batch に番号を振り、1 体ごとの値をテクスチャへ 1 回で上げて、振り終えた plans とテクスチャの番号を返す。描く物が無ければテクスチャを作らず None。
    /// テクスチャに入り切らない batch の物は描かない（1 回知らせる）。members = batch の描く物（Render3d.ScenePlan.Grouped#members）。
    pub def upload(gl: GlContext, state: State, gen: Int64, plans: List[ScenePlan[SpanBatch]], members: MutList[MeshDraw, Static]): (List[ScenePlan[MeshBatch]], Option[Int32]) \ IO =
        let total = List.sumWith(countOf, plans);
        if (total == 0) (plans |> List.map(mapBatches(_ -> b -> { head = b#head, count = 0, first = 0 })), None)
        else {
            let limit = rowLimit(gl, state#instances);
            let capacity = limit * instancesPerRow();
            if (total > capacity)
                warnSceneOnce(state, "@instance-rows", Log.fellBackLine("scene3d", "1 回の prepare の描く物", "入り切らない物を描かない", "${capacity} 体を超えた（${total} 体）"))
            else ();
            let kept = Int32.min(total, capacity);
            let rows = rowsFor(kept);
            let width = if (rows == 1) kept * texelsPerInstance() else textureWidth();
            let out = bufferFor(gl, state#instances, rows * textureWidth() * 4);
            discard out.clear();
            let scratch = Array.repeat(Static, texelsPerInstance() * 4, 0.0f32);
            let next = Array#{0} @ Static;
            let numbered = plans |> List.map(mapBatches(numberSpan(out, scratch, capacity, next, members)));
            discard out.position(0);
            discard out.limit(rows * width * 4);
            gl.activeTexture(GlConst.TEXTURE0 + instanceTextureUnit());
            let texture = takeTexture(gl, state#instances, gen, heightFor(limit, rows));
            gl.texSubImageRgba32f(0, 0, width, rows, out);
            gl.activeTexture(GlConst.TEXTURE0);
            (numbered, Some(texture#texId))
        }
}
