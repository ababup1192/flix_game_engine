// RenderSprite — スプライト1枚やタイルマップ1面を、実際に画面へ描く低レベルの描画関数。
// GL の頂点バッファ準備や描画命令をこの一箇所に閉じるので、上位はこれを呼ぶだけで絵を出せる。
// 利用例: キャラや弾の画像を描く / 敷き詰めた地形タイルをまとめて描く。

mod RenderSprite {
    import fge.gl.GlContext
    import fge.gl.GlConst
    import java.nio.FloatBuffer

    /// 共有 quad の VAO/VBO を生成する。
    /// vertex layout: (x, y, u, v) の 4 floats。
    /// 戻り値: (vao, vbo)
    pub def initSpriteRenderer(gl: GlContext): (Int32, Int32) \ IO =
        let vao = gl.createVertexArray();
        let vbo = gl.createBuffer();
        let vertices = Array#{
            0.0f32, 1.0f32, 0.0f32, 1.0f32,
            1.0f32, 0.0f32, 1.0f32, 0.0f32,
            0.0f32, 0.0f32, 0.0f32, 0.0f32,
            0.0f32, 1.0f32, 0.0f32, 1.0f32,
            1.0f32, 1.0f32, 1.0f32, 1.0f32,
            1.0f32, 0.0f32, 1.0f32, 0.0f32
        } @ Static;
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, vertices, GlConst.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 4, GlConst.FLOAT, false, 16, 0);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        (vao, vbo)

    /// blend に応じて GL のブレンド因子を切り替える。呼んだ後の描画から効く。
    /// Multiply は因子だけでは alpha 付きの正しい式にならないため、シェーダ側の
    /// premultiply（multiplyBlend uniform）とペアで dst×(1−a×(1−src)) を作る。
    pub def applyBlend(gl: GlContext, blend: DrawCmd.BlendMode): Unit \ IO =
        match blend {
            case DrawCmd.BlendMode.Normal   =>
                gl.blendFunc(GlConst.SRC_ALPHA, GlConst.ONE_MINUS_SRC_ALPHA)
            case DrawCmd.BlendMode.Add      =>
                gl.blendFunc(GlConst.SRC_ALPHA, GlConst.ONE)
            case DrawCmd.BlendMode.Multiply =>
                gl.blendFunc(GlConst.DST_COLOR, GlConst.ONE_MINUS_SRC_ALPHA)
        }

    /// multiplyBlend uniform に渡す値（Multiply のときだけ premultiply を有効化）。
    pub def multiplyFlag(blend: DrawCmd.BlendMode): Int32 =
        if (blend == DrawCmd.BlendMode.Multiply) 1 else 0

    // ========================================================================
    // Polygon Batch Rendering — 同じ blend / 切り抜き clip 矩形の多角形を 1 draw call で
    // ========================================================================

    /// 多角形バッチ用の VAO と動的 VBO を生成する（起動時に 1 回）。
    /// vertex layout: 位置(x, y) + 色(r, g, b, a) の 6 floats / 24 bytes。
    ///   loc 0: 位置 (vec2)
    ///   loc 1: 色 (vec4)。drawPolygon の単色 uniform を頂点色に置き換えたもの。
    /// 戻り値: (vao, vbo)
    pub def initPolygonBatchRenderer(gl: GlContext): (Int32, Int32) \ IO =
        let vao = gl.createVertexArray();
        let vbo = gl.createBuffer();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, GlConst.FLOAT, false, 24, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 4, GlConst.FLOAT, false, 24, 8);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        (vao, vbo)

    /// 多角形 1 個を 6 floats/頂点 (x, y, r, g, b, a) の配列列（逆順）に展開する。
    /// 動的バッチ（RenderFrame）と静的焼き（RenderStatic）が同じ展開を見るための共通口。
    /// grad = None は従来どおり耳切り＋単色 — 単色の絵を 1 バイトも変えないため経路を分けたまま、
    /// grad = Some だけ DrawCmd.gradTriangles（凸の扇割り）＋頂点色で展開する。
    /// 戻り値 = (頂点数, 逆順の配列列)。呼び側が末尾から詰め戻すと入力順に戻る。
    pub def polyVertsRev(pc: DrawCmd.PolygonRenderCmd): (Int32, List[Array[Float32, Static]]) \ IO =
        let f32 = RenderUtil.f32;
        match pc#grad {
            case None =>
                let color = pc#color;
                let alpha = f32(pc#alpha);
                let flat = DrawCmd.polygonTriangles(pc)
                    |> List.flatMap(tri -> { let (a, b, c) = tri; a :: b :: c :: Nil });
                let n = List.length(flat);
                let vertsRev = List.foldLeft((rest, v) ->
                    (Array#{ f32(v#x), f32(v#y), f32(color#r), f32(color#g), f32(color#b), alpha } @ Static) :: rest,
                    Nil, flat);
                (n, vertsRev)
            case Some(_) =>
                let flat = DrawCmd.gradTriangles(pc)
                    |> List.flatMap(tri -> { let (a, b, c) = tri; a :: b :: c :: Nil });
                let n = List.length(flat);
                let vertsRev = List.foldLeft((rest, v) ->
                    (Array#{ f32(v#pos#x), f32(v#pos#y), f32(v#color#r), f32(v#color#g), f32(v#color#b), f32(v#alpha) } @ Static) :: rest,
                    Nil, flat);
                (n, vertsRev)
        }

    /// 多角形 1 個を三角形化し、頂点 6 floats (x, y, r, g, b, a) を入れ物の
    /// firstVert 番目の頂点から順に直に書く。書いた頂点数を返す。
    /// 頂点ごとに小さな配列を作って後で写し直さないのは、1 画面ぶんで
    /// 万を数える作り直しになり、それだけでフレーム時間に乗るため。
    pub def writePolyVerts(data: FloatBuffer, firstVert: Int32,
                            pc: DrawCmd.PolygonRenderCmd): Int32 \ IO =
        match pc#grad {
            case None =>
                let color = pc#color;
                let r = RenderUtil.f32(color#r);
                let g = RenderUtil.f32(color#g);
                let b = RenderUtil.f32(color#b);
                let alpha = RenderUtil.f32(pc#alpha);
                let vs = pc#triangles |> Option.map(_ -> List.toVector(pc#vertices)) |> Option.getWithDefault(Vector#{});
                match pc#triangles {
                    // 割り方を覚えた形は、番号で頂点を引いて直に書く（三角形の組の列を毎フレーム作らない）。
                    case Some(order) if Triangulate.fitsIndices(order, Vector.length(vs)) =>
                        Vector.forEachWithIndex((k, at) -> writeXY(data, firstVert + k, Vector.get(at, vs), r, g, b, alpha), order);
                        Vector.length(order)
                    case _ =>
                        DrawCmd.polygonTriangles(pc) |> List.foldLeft((i, tri) -> {
                            let (v0, v1, v2) = tri;
                            writeXY(data, i,     v0, r, g, b, alpha);
                            writeXY(data, i + 1, v1, r, g, b, alpha);
                            writeXY(data, i + 2, v2, r, g, b, alpha);
                            i + 3
                        }, firstVert) - firstVert
                }
            case Some(_) =>
                DrawCmd.gradTriangles(pc) |> List.foldLeft((i, tri) -> {
                    let (v0, v1, v2) = tri;
                    writeTinted(data, i,     v0);
                    writeTinted(data, i + 1, v1);
                    writeTinted(data, i + 2, v2);
                    i + 3
                }, firstVert) - firstVert
        }

    def writeXY(data: FloatBuffer, vert: Int32, v: Vec2.Vec2,
                r: Float32, g: Float32, b: Float32, alpha: Float32): Unit \ IO =
        let base = vert * 6;
        discard data.put(base + 0, RenderUtil.f32(v#x));
        discard data.put(base + 1, RenderUtil.f32(v#y));
        discard data.put(base + 2, r);
        discard data.put(base + 3, g);
        discard data.put(base + 4, b);
        discard data.put(base + 5, alpha)

    def writeTinted(data: FloatBuffer, vert: Int32, v: DrawCmd.GradVertex): Unit \ IO =
        let color = v#color;
        writeXY(data, vert, v#pos, RenderUtil.f32(color#r), RenderUtil.f32(color#g),
                RenderUtil.f32(color#b), RenderUtil.f32(v#alpha))

    /// 溜めた頂点 [first, first + count) を 1 回の draw call で塗る（入れ物から直に流す）。
    /// locs の [locAt, locAt + 4) = 多角形のシェーダーの uniform location（multiplyBlend・viewOffset・viewScale・halfDesign の順）・
    /// values の [at, at + 6) = view（RenderList の values の並び）。
    /// 流し終えたら書ける範囲を元に戻す — 上限を切ったままだと次の書き込みが弾かれる。
    pub def drawPolygonRange(gl: GlContext, shader: Int32, vao: Int32, vbo: Int32, locs: Array[Int32, Static], locAt: Int32,
                             blend: DrawCmd.BlendMode, values: Array[Float32, Static], at: Int32,
                             data: FloatBuffer, first: Int32, count: Int32): Unit \ IO =
        if (count < 3) () else {
            usePolyProgram(gl, shader, locs, locAt, blend, values, at);
            gl.bindVertexArray(vao);
            gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
            discard data.limit((first + count) * 6);
            discard data.position(first * 6);
            gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.DYNAMIC_DRAW);
            discard data.clear();
            gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
            gl.drawArrays(GlConst.TRIANGLES, 0, count);
            gl.bindVertexArray(0)
        }

    /// 多角形のシェーダーを使い、blend と view の uniform を差す（locs と values は drawPolygonRange と同じ）。
    def usePolyProgram(gl: GlContext, shader: Int32, locs: Array[Int32, Static], locAt: Int32, blend: DrawCmd.BlendMode,
                       values: Array[Float32, Static], at: Int32): Unit \ IO =
        gl.useProgram(shader);
        applyBlend(gl, blend);
        gl.uniform1i(Array.get(locAt, locs), multiplyFlag(blend));
        gl.uniform2f(Array.get(locAt + 1, locs), Array.get(at, values), Array.get(at + 1, values));
        gl.uniform2f(Array.get(locAt + 2, locs), Array.get(at + 2, values), Array.get(at + 3, values));
        gl.uniform2f(Array.get(locAt + 3, locs), Array.get(at + 4, values), Array.get(at + 5, values))

    // ========================================================================
    // Static Polygon Retained Rendering — 三角形化済み頂点を 1 度だけ GPU に載せ使い回す
    // ========================================================================

    /// 三角形化済みの静的多角形頂点を永続 VBO へアップロードする（キー変化時に 1 度だけ）。
    /// vertex layout は drawPolygonRange と同じ 6 floats（位置 2 + 色 4 / 24 bytes）。
    /// GL_STATIC_DRAW で載せ、毎フレームは範囲だけ流して drawStaticRange で描く。
    /// 戻り値: (vao, vbo)。free 時に両方 delete する。
    pub def buildStaticPolyVBO(gl: GlContext, data: Array[Float32, Static], _vertexCount: Int32): (Int32, Int32) \ IO =
        let vao = gl.createVertexArray();
        let vbo = gl.createBuffer();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, GlConst.FLOAT, false, 24, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 4, GlConst.FLOAT, false, 24, 8);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        (vao, vbo)

    /// 永続 VBO の [first, first+count) の頂点範囲を 1 回の draw call で塗る（アップロードなし）。
    /// camera（viewOffset/viewScale/halfDesign）と blend を uniform と因子で当てる（scissor は呼び側の GlRows.drawRow が張る）。
    /// locs と values は drawPolygonRange と同じ。
    pub def drawStaticRange(gl: GlContext, shader: Int32, vao: Int32, locs: Array[Int32, Static], locAt: Int32, blend: DrawCmd.BlendMode,
                            values: Array[Float32, Static], at: Int32, first: Int32, count: Int32): Unit \ IO =
        if (count < 3) () else {
            usePolyProgram(gl, shader, locs, locAt, blend, values, at);
            gl.bindVertexArray(vao);
            gl.drawArrays(GlConst.TRIANGLES, first, count);
            gl.bindVertexArray(0)
        }

    /// 永続 VBO と VAO を解放する（キー変化でキャッシュを作り直す前に古い方を捨てる）。
    pub def freeStaticPolyVBO(gl: GlContext, vao: Int32, vbo: Int32): Unit \ IO =
        gl.deleteBuffer(vbo);
        gl.deleteVertexArray(vao)

    // ========================================================================
    // Tile Map Instanced Rendering
    // ========================================================================

    /// タイルの instance の VBO を新規に作り、floats（TileTable.instanceFloats の並び・1 枚 10 個 = 40 bytes）を上げる。
    pub def buildTileInstanceVBO(gl: GlContext, floats: Array[Float32, Static]): Int32 \ IO =
        let vbo = gl.createBuffer();
        uploadTileInstances(gl, vbo, floats);
        vbo

    /// 既存のインスタンス VBO へ中身を入れ直す（glBufferData の作り直し —
    /// 古い領域はドライバが回収する）。作り直しの多いタイル層が VBO を積み増さないための関数。
    pub def uploadTileInstances(gl: GlContext, vbo: Int32, floats: Array[Float32, Static]): Unit \ IO =
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, floats, GlConst.STATIC_DRAW);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0)

    /// TileLayer 専用 VAO を構築する。
    /// loc 0: 共有 quad VBO (vertex.xy = 局所座標, vertex.zw = UV)
    /// loc 1-4: per-instance VBO (divisor=1)
    pub def buildTileMapVAO(gl: GlContext, quadVBO: Int32, instanceVBO: Int32): Int32 \ IO =
        let vao = gl.createVertexArray();
        gl.bindVertexArray(vao);
        // 共有 quad VBO (loc 0)
        gl.bindBuffer(GlConst.ARRAY_BUFFER, quadVBO);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 4, GlConst.FLOAT, false, 16, 0);
        // インスタンス VBO (loc 1-4, divisor=1)
        gl.bindBuffer(GlConst.ARRAY_BUFFER, instanceVBO);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, GlConst.FLOAT, false, 40, 0);
        gl.vertexAttribDivisor(1, 1);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 2, GlConst.FLOAT, false, 40, 8);
        gl.vertexAttribDivisor(2, 1);
        gl.enableVertexAttribArray(3);
        gl.vertexAttribPointer(3, 2, GlConst.FLOAT, false, 40, 16);
        gl.vertexAttribDivisor(3, 1);
        gl.enableVertexAttribArray(4);
        gl.vertexAttribPointer(4, 1, GlConst.FLOAT, false, 40, 24);
        gl.vertexAttribDivisor(4, 1);
        gl.enableVertexAttribArray(5);
        gl.vertexAttribPointer(5, 3, GlConst.FLOAT, false, 40, 28);
        gl.vertexAttribDivisor(5, 1);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        vao

    /// 1 draw call で TileLayer のすべてのタイルを描画する。
    /// locs の [locAt, locAt + 4) = tile シェーダーの uniform location（layerPos・tileSize・tileScale・layerColor の順・起動時に 1 回だけ引いた物）・
    /// values の [at, at + 8) = 層の値（RenderList の values のタイルの並び）。
    pub def drawTileMapInstanced(gl: GlContext, tileShader: Int32, texId: Int32, tileVao: Int32, locs: Array[Int32, Static], locAt: Int32,
                                 values: Array[Float32, Static], at: Int32, tileCount: Int32): Unit \ IO =
        gl.useProgram(tileShader);
        gl.uniform2f(Array.get(locAt, locs), Array.get(at, values), Array.get(at + 1, values));
        gl.uniform1f(Array.get(locAt + 1, locs), Array.get(at + 2, values));
        gl.uniform2f(Array.get(locAt + 2, locs), Array.get(at + 3, values), Array.get(at + 4, values));
        gl.uniform3f(Array.get(locAt + 3, locs), Array.get(at + 5, values), Array.get(at + 6, values), Array.get(at + 7, values));
        gl.activeTexture(GlConst.TEXTURE0);
        gl.bindTexture(GlConst.TEXTURE_2D, texId);
        gl.bindVertexArray(tileVao);
        gl.drawArraysInstanced(GlConst.TRIANGLES, 0, 6, tileCount);
        gl.bindVertexArray(0)

    // ========================================================================
    // 宣言シェーダー面（Platform.Draw2d.drawSurface）— 面 quad 1 枚を宣言シェーダーで塗る
    // ========================================================================

    /// tex 場（Field.Tex）専用の sampler object を 1 個作る（起動時に 1 回）。
    /// NEAREST + CLAMP_TO_EDGE を unit へ強制する — 通常テクスチャは REPEAT で上がっているため、
    /// Shift で端を越えた標本が反対側へ回り込むと CPU（端に張り付き）と絵が割れる。
    /// テクスチャ本体のパラメータは触らない（sprite 経路の見え方を変えない）。
    /// linear = true で GL_LINEAR（ShaderDoc の sampler 節の Linear）。端の張り付きは同じ。
    pub def createSurfaceSampler(gl: GlContext, linear: Bool): Int32 \ IO =
        let sampler = gl.createSampler();
        let filter = if (linear) GlConst.LINEAR else GlConst.NEAREST;
        gl.samplerParameteri(sampler, GlConst.TEXTURE_MIN_FILTER, filter);
        gl.samplerParameteri(sampler, GlConst.TEXTURE_MAG_FILTER, filter);
        gl.samplerParameteri(sampler, GlConst.TEXTURE_WRAP_S, GlConst.CLAMP_TO_EDGE);
        gl.samplerParameteri(sampler, GlConst.TEXTURE_WRAP_T, GlConst.CLAMP_TO_EDGE);
        sampler

    /// tex 場の bind 指示 1 本。Int32 が 3 つ並ぶので位置タプルだと取り違えても型では
    /// 捕まらない — 名前渡しのレコードにして混線を型より手前で防ぐ。
    pub type alias SurfaceTexBind =
        { texUnit = Int32, texId = Int32, flipLoc = Int32, flip = Float64, sampler = Int32 }

    /// 宣言シェーダー面の uniform の location（無い uniform は -1。glUniform は -1 を無視する）。
    pub type alias SurfaceUniforms = { rectPos = Int32, rectSize = Int32, time = Int32, alpha = Int32 }

    /// 宣言シェーダー面 1 枚を描く。共有 quad VAO（loc0 = x,y,u,v）を使い、values の [at, at + 6)（RenderList の面の値の並び:
    /// rect の位置 2・大きさ 2（スクリーン px）・time・alpha）を uniform で差して 1 draw call で塗る。
    /// projection は起動時に setProjectionMatrix 済みの前提（program ごとに1回）。
    /// texBinds が非空なら各 unit へテクスチャ + sampler を bind し、描画後は使った全 unit
    ///（unit 0 含む）の sampler を解除して unit 0 へ戻す — unit 0 は sprite / tile / static /
    /// font が glActiveTexture を触らず共用するため、残すとフォント作り直しやアトラス
    /// 差し替えが別 unit へ上がる事故になる。
    pub def drawShaderSurface(gl: GlContext, program: Int32, vao: Int32, uniforms: SurfaceUniforms,
                              texBinds: List[SurfaceTexBind], values: Array[Float32, Static], at: Int32, blend: DrawCmd.BlendMode): Unit \ IO =
        gl.useProgram(program);
        applyBlend(gl, blend);
        gl.uniform2f(uniforms#rectPos, Array.get(at, values), Array.get(at + 1, values));
        gl.uniform2f(uniforms#rectSize, Array.get(at + 2, values), Array.get(at + 3, values));
        gl.uniform1f(uniforms#time, Array.get(at + 4, values));
        // 毎回差す。program は面どうしで共有され、差さないと前の面の濃さ（初めは 0.0 = 透明）が残る。
        gl.uniform1f(uniforms#alpha, Array.get(at + 5, values));
        List.forEach(tb -> {
            gl.activeTexture(GlConst.TEXTURE0 + tb#texUnit);
            gl.bindTexture(GlConst.TEXTURE_2D, tb#texId);
            gl.bindSampler(tb#texUnit, tb#sampler);
            gl.uniform1f(tb#flipLoc, RenderUtil.f32(tb#flip))
        }, texBinds);
        gl.bindVertexArray(vao);
        gl.drawArrays(GlConst.TRIANGLES, 0, 6);
        gl.bindVertexArray(0);
        if (List.isEmpty(texBinds)) ()
        else {
            List.forEach(tb -> gl.bindSampler(tb#texUnit, 0), texBinds);
            gl.activeTexture(GlConst.TEXTURE0)
        }

    // ========================================================================
    // Sprite Instanced Rendering — 連続する同テクスチャのスプライトを 1 draw call で
    // ========================================================================

    /// instanced sprite の 1 体ぶんの float の数（下の VAO の stride 152 bytes = 38 floats）。
    def instanceFloats(): Int32 = 38

    /// instanced sprite 用の VAO と instance VBO を構築する（起動時に 1 回）。
    /// loc 0: 共有 quad VBO (vertex.xy = 局所座標, vertex.zw = UV)
    /// loc 1-10: per-instance VBO (divisor=1)。1 instance = 38 floats / 152 bytes:
    ///   loc1 vec4 = ワールド変換 2x2 / loc2 vec2 = 平行移動 /
    ///   loc3 vec4 = uvOffset+uvScale / loc4 vec4 = color+alpha /
    ///   loc5 vec4 = フラグ (useTexture, sdf, styleEnabled, hatchEnabled) /
    ///   loc6 vec4 = rectSize+cornerRadius+borderWidth / loc7 vec4 = 枠色+枠alpha /
    ///   loc8 vec4 = ハッチ色+alpha / loc9 vec4 = ハッチ幅+周期+向き+市松セル /
    ///   loc10 vec4 = 市松色+alpha
    /// 戻り値: (vao, instanceVbo)
    pub def initSpriteInstancedRenderer(gl: GlContext, quadVBO: Int32): (Int32, Int32) \ IO =
        let vao = gl.createVertexArray();
        let instanceVbo = gl.createBuffer();
        gl.bindVertexArray(vao);
        // 共有 quad VBO (loc 0)
        gl.bindBuffer(GlConst.ARRAY_BUFFER, quadVBO);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 4, GlConst.FLOAT, false, 16, 0);
        // インスタンス VBO (loc 1-10, divisor=1, stride 152 bytes)
        gl.bindBuffer(GlConst.ARRAY_BUFFER, instanceVbo);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 4, GlConst.FLOAT, false, 152, 0);
        gl.vertexAttribDivisor(1, 1);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 2, GlConst.FLOAT, false, 152, 16);
        gl.vertexAttribDivisor(2, 1);
        gl.enableVertexAttribArray(3);
        gl.vertexAttribPointer(3, 4, GlConst.FLOAT, false, 152, 24);
        gl.vertexAttribDivisor(3, 1);
        gl.enableVertexAttribArray(4);
        gl.vertexAttribPointer(4, 4, GlConst.FLOAT, false, 152, 40);
        gl.vertexAttribDivisor(4, 1);
        gl.enableVertexAttribArray(5);
        gl.vertexAttribPointer(5, 4, GlConst.FLOAT, false, 152, 56);
        gl.vertexAttribDivisor(5, 1);
        gl.enableVertexAttribArray(6);
        gl.vertexAttribPointer(6, 4, GlConst.FLOAT, false, 152, 72);
        gl.vertexAttribDivisor(6, 1);
        gl.enableVertexAttribArray(7);
        gl.vertexAttribPointer(7, 4, GlConst.FLOAT, false, 152, 88);
        gl.vertexAttribDivisor(7, 1);
        gl.enableVertexAttribArray(8);
        gl.vertexAttribPointer(8, 4, GlConst.FLOAT, false, 152, 104);
        gl.vertexAttribDivisor(8, 1);
        gl.enableVertexAttribArray(9);
        gl.vertexAttribPointer(9, 4, GlConst.FLOAT, false, 152, 120);
        gl.vertexAttribDivisor(9, 1);
        gl.enableVertexAttribArray(10);
        gl.vertexAttribPointer(10, 4, GlConst.FLOAT, false, 152, 136);
        gl.vertexAttribDivisor(10, 1);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        (vao, instanceVbo)

    /// 同じテクスチャのスプライト count 体を 1 回の instanced draw で描く。data は 1 体 instanceFloats() 個
    /// （RenderFrame が組む）で、first 体目から count 体を流す（入れ物から直に流す）。
    /// texId = 0 は単色矩形の run で、シェーダはテクスチャを読まないので bind しない。
    /// blend は run 内で均一（RenderFrame が blend 変化で run を切る）。multiplyBlendLoc は
    /// instanced シェーダの premultiply スイッチの location（起動時に 1 回引いたもの）。
    /// 流し終えたら書ける範囲を元に戻す — 上限を切ったままだと次の書き込みが弾かれる。
    pub def drawSpriteInstancedBuf(gl: GlContext, shader: Int32, vao: Int32, instanceVbo: Int32, texId: Int32,
                                    multiplyBlendLoc: Int32, blend: DrawCmd.BlendMode,
                                    data: FloatBuffer, first: Int32, count: Int32): Unit \ IO =
        gl.useProgram(shader);
        applyBlend(gl, blend);
        gl.uniform1i(multiplyBlendLoc, multiplyFlag(blend));
        if (texId != 0) {
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindTexture(GlConst.TEXTURE_2D, texId)
        } else ();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, instanceVbo);
        discard data.limit((first + count) * instanceFloats());
        discard data.position(first * instanceFloats());
        gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.DYNAMIC_DRAW);
        discard data.clear();
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.drawArraysInstanced(GlConst.TRIANGLES, 0, 6, count);
        gl.bindVertexArray(0)

    /// mask の多角形の列（画面の座標）を三角形にほどき、頂点 6 floats（位置と白）を入れ物の firstVert 番目から書く。書いた頂点数を返す。
    pub def writeMaskVerts(data: FloatBuffer, firstVert: Int32, maskPolys: List[List[Vec2.Vec2]]): Int32 \ IO =
        maskPolys |> List.foldLeft((i, poly) -> Triangulate.triangles(poly) |> List.foldLeft((j, tri) -> {
            let (v0, v1, v2) = tri;
            writeXY(data, j,     v0, 1.0f32, 1.0f32, 1.0f32, 1.0f32);
            writeXY(data, j + 1, v1, 1.0f32, 1.0f32, 1.0f32, 1.0f32);
            writeXY(data, j + 2, v2, 1.0f32, 1.0f32, 1.0f32, 1.0f32);
            j + 3
        }, i), firstVert) - firstVert

    /// stencil を全部 0 にする（scissor を外してから。張り直すのは呼ぶ側）。
    pub def clearStencil(gl: GlContext): Unit \ IO =
        gl.disable(GlConst.SCISSOR_TEST);
        gl.stencilMask(255i32);
        gl.clearStencil(0);
        gl.clear(GlConst.STENCIL_BUFFER_BIT)

    /// vertices の [maskFirst, maskFirst + maskCount) の三角形を stencil へ値 ref で書き（色は書かない・view は values の at からの 6 個）、
    /// この後の draw を stencil が ref の画素だけにする（mask つきスプライトと mask つきの面の 1 本目。2 本目を描いたら endStencilMask）。
    /// locs の [locAt, locAt + 4) = 多角形のシェーダーの uniform location（drawPolygonRange と同じ）。
    pub def writeStencilMask(gl: GlContext, polyShader: Int32, polyVao: Int32, polyVbo: Int32, locs: Array[Int32, Static], locAt: Int32,
                             values: Array[Float32, Static], at: Int32, vertices: FloatBuffer, maskFirst: Int32, maskCount: Int32,
                             ref: Int32): Unit \ IO =
        gl.enable(GlConst.STENCIL_TEST);
        gl.stencilMask(255i32);
        gl.stencilFunc(GlConst.ALWAYS, ref, 255i32);
        gl.stencilOp(GlConst.KEEP, GlConst.KEEP, GlConst.REPLACE);
        gl.colorMask(false, false, false, false);
        drawPolygonRange(gl, polyShader, polyVao, polyVbo, locs, locAt, DrawCmd.BlendMode.Normal, values, at, vertices, maskFirst, maskCount);
        gl.colorMask(true, true, true, true);
        gl.stencilFunc(GlConst.EQUAL, ref, 255i32);
        gl.stencilOp(GlConst.KEEP, GlConst.KEEP, GlConst.KEEP);
        gl.stencilMask(0i32)

    /// writeStencilMask の後始末（stencil の検査を外し、書き込みの mask を戻す）。
    pub def endStencilMask(gl: GlContext): Unit \ IO =
        gl.stencilMask(255i32);
        gl.disable(GlConst.STENCIL_TEST)

}
