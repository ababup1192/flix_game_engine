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

    /// 1 スプライトを描画する。
    /// rotation は center 周りのラジアン回転。useTex = false で純色矩形。
    /// uniforms は起動時に 1 回だけ引いた location 一式（RenderShader.spriteUniformsOf）。
    pub def drawSprite(gl: GlContext, shader: Int32, vao: Int32, uniforms: RenderShader.SpriteUniforms,
                        params: RenderType.DrawSpriteParams): Unit \ IO =
        // 1 レコードからローカルへ束ね直す（以降の描画ロジックは従来どおり）。
        let texture = params#texture;
        let pos     = params#position;
        let size    = params#scale;
        let color   = params#color;
        let alpha   = params#alpha;
        let uvOff   = params#uvOffset;
        let uvSc    = params#uvScale;
        let rot     = params#rotation;
        let useTex  = params#useTexture;
        let style   = params#style;
        let sdf     = params#sdf;
        let f32 = RenderUtil.f32;
        let cosF = RenderUtil.cosF;
        let sinF = RenderUtil.sinF;
        gl.useProgram(shader);
        let c = cosF(rot);
        let s = sinF(rot);
        let sx = size#x;
        let sy = size#y;
        let tx = pos#x + sx / 2.0 - c * sx / 2.0 + s * sy / 2.0;
        let ty = pos#y + sy / 2.0 - s * sx / 2.0 - c * sy / 2.0;
        let model = Array#{
            f32(c * sx), f32(s * sx), 0.0f32, 0.0f32,
            f32(-1.0 * s * sy), f32(c * sy), 0.0f32, 0.0f32,
            0.0f32, 0.0f32, 1.0f32, 0.0f32,
            f32(tx), f32(ty), 0.0f32, 1.0f32
        } @ Static;
        gl.uniformMatrix4fv(uniforms#model, false, model);
        gl.uniform3f(uniforms#spriteColor, f32(color#r), f32(color#g), f32(color#b));
        gl.uniform1f(uniforms#spriteAlpha, f32(alpha));
        gl.uniform2f(uniforms#uvOffset, f32(uvOff#x), f32(uvOff#y));
        gl.uniform2f(uniforms#uvScale, f32(uvSc#x), f32(uvSc#y));
        gl.uniform1i(uniforms#useTexture, if (useTex) 1 else 0);
        // SDF テキスト uniform。テキスト以外は 0 にして GL state 持ち越しを防ぐ。
        gl.uniform1i(uniforms#sdfText, if (sdf) 1 else 0);
        // drawPolygon と同じシェーダを共有するため、premultiply スイッチも明示 0 にして持ち越しを防ぐ。
        gl.uniform1i(uniforms#multiplyBlend, 0);
        // 角丸＋枠スタイル uniform。Some のとき styleEnabled=1（単色矩形のみシェーダ側で適用）。
        match style {
            case Some(st) =>
                let DrawCmd.BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                                              sr, sg, sb, sa, sw, sp, sd,
                                              kr, kg, kb, ka, kc) = st;
                gl.uniform1i(uniforms#styleEnabled, 1);
                gl.uniform2f(uniforms#rectSize, f32(size#x), f32(size#y));
                gl.uniform1f(uniforms#cornerRadius, f32(rad));
                gl.uniform1f(uniforms#borderWidth, f32(bw));
                gl.uniform3f(uniforms#borderColor, f32(br), f32(bg), f32(bb));
                gl.uniform1f(uniforms#borderAlpha, f32(ba));
                // 斜線ハッチ uniform。幅・濃さ・周期がすべて正のときのみ有効化(SoftRaster と同じ判定)。
                let hatchOn = sw > 0.0 and sa > 0.0 and sp > 0.0;
                gl.uniform1i(uniforms#hatchEnabled, if (hatchOn) 1 else 0);
                gl.uniform3f(uniforms#hatchColor, f32(sr), f32(sg), f32(sb));
                gl.uniform1f(uniforms#hatchAlpha, f32(sa));
                gl.uniform1f(uniforms#hatchWidth, f32(sw));
                gl.uniform1f(uniforms#hatchPeriod, f32(sp));
                gl.uniform1i(uniforms#hatchDir, sd);
                // 市松 uniform。有効判定 (cell>0 かつ alpha>0) はシェーダ側で行う。
                gl.uniform3f(uniforms#checkerColor, f32(kr), f32(kg), f32(kb));
                gl.uniform1f(uniforms#checkerAlpha, f32(ka));
                gl.uniform1f(uniforms#checkerCell, f32(kc))
            case None =>
                gl.uniform1i(uniforms#styleEnabled, 0);
                gl.uniform1i(uniforms#hatchEnabled, 0);
                gl.uniform1f(uniforms#checkerCell, 0.0f32)
        };
        if (useTex) {
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindTexture(GlConst.TEXTURE_2D, texture)
        } else ();
        gl.bindVertexArray(vao);
        gl.drawArrays(GlConst.TRIANGLES, 0, 6);
        gl.bindVertexArray(0)

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
                let flat = Triangulate.triangles(pc#vertices)
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
                Triangulate.triangles(pc#vertices) |> List.foldLeft((i, tri) -> {
                    let (v0, v1, v2) = tri;
                    writeXY(data, i,     v0, r, g, b, alpha);
                    writeXY(data, i + 1, v1, r, g, b, alpha);
                    writeXY(data, i + 2, v2, r, g, b, alpha);
                    i + 3
                }, firstVert) - firstVert
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

    /// 溜めた頂点 [0, vertexCount) を 1 回の draw call で塗る（入れ物から直に流す）。
    /// 流し終えたら書ける範囲を元に戻す — 上限を切ったままだと次の書き込みが弾かれる。
    pub def drawPolygonBatchBuf(gl: GlContext, shader: Int32, vao: Int32, vbo: Int32,
                                 uniforms: RenderShader.PolyBatchUniforms, blend: DrawCmd.BlendMode,
                                 data: FloatBuffer, vertexCount: Int32): Unit \ IO =
        if (vertexCount < 3) () else {
            gl.useProgram(shader);
            applyBlend(gl, blend);
            gl.uniform1i(uniforms#multiplyBlend, multiplyFlag(blend));
            gl.uniform2f(uniforms#viewOffset, 0.0f32, 0.0f32);
            gl.uniform2f(uniforms#viewScale, 1.0f32, 1.0f32);
            gl.uniform2f(uniforms#halfDesign, 0.0f32, 0.0f32);
            gl.bindVertexArray(vao);
            gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
            discard data.position(0);
            discard data.limit(vertexCount * 6);
            gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.DYNAMIC_DRAW);
            discard data.clear();
            gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
            gl.drawArrays(GlConst.TRIANGLES, 0, vertexCount);
            gl.bindVertexArray(0)
        }

    /// 三角形化済みの多角形頂点をまとめて 1 回の draw call で塗る。
    /// data は 1 頂点 6 floats（位置 2 + 色 4）を列順に並べたもの（RenderFrame が組む）。
    /// blend は run 内で均一（RenderFrame が blend / 切り抜き clip 矩形の変化で run を切る）。
    /// glBufferData で丸ごと差し替える（orphaning。drawSpriteInstanced と同方式）。
    pub def drawPolygonBatch(gl: GlContext, shader: Int32, vao: Int32, vbo: Int32,
                              uniforms: RenderShader.PolyBatchUniforms, blend: DrawCmd.BlendMode,
                              data: Array[Float32, Static], vertexCount: Int32): Unit \ IO =
        if (vertexCount < 3) () else {
            gl.useProgram(shader);
            applyBlend(gl, blend);
            gl.uniform1i(uniforms#multiplyBlend, multiplyFlag(blend));
            // 動的多角形は既に centerOn 済みのスクリーン座標で来るので camera uniform は恒等。
            // 静的レンジ描画が設定した値が持ち越されないよう毎 draw call で明示リセットする
            // （sprite の multiplyBlend が毎回 0 明示されるのと同じ作法）。
            gl.uniform2f(uniforms#viewOffset, 0.0f32, 0.0f32);
            gl.uniform2f(uniforms#viewScale, 1.0f32, 1.0f32);
            gl.uniform2f(uniforms#halfDesign, 0.0f32, 0.0f32);
            gl.bindVertexArray(vao);
            gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
            gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.DYNAMIC_DRAW);
            gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
            gl.drawArrays(GlConst.TRIANGLES, 0, vertexCount);
            gl.bindVertexArray(0)
        }

    // ========================================================================
    // Static Polygon Retained Rendering — 三角形化済み頂点を 1 度だけ GPU に載せ使い回す
    // ========================================================================

    /// 三角形化済みの静的多角形頂点を永続 VBO へアップロードする（キー変化時に 1 度だけ）。
    /// vertex layout は drawPolygonBatch と同じ 6 floats（位置 2 + 色 4 / 24 bytes）。
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
    /// camera（viewOffset/viewScale/halfDesign）を uniform で当てる。blend / scissor は
    /// 呼び側（RenderFrame）が設定済み。
    pub def drawStaticRange(gl: GlContext, shader: Int32, vao: Int32,
                             uniforms: RenderShader.PolyBatchUniforms, blend: DrawCmd.BlendMode,
                             viewOffset: Vec2.Vec2, viewScale: Vec2.Vec2, halfDesign: Vec2.Vec2,
                             first: Int32, count: Int32): Unit \ IO =
        if (count < 3) () else {
            let f32 = RenderUtil.f32;
            gl.useProgram(shader);
            applyBlend(gl, blend);
            gl.uniform1i(uniforms#multiplyBlend, multiplyFlag(blend));
            gl.uniform2f(uniforms#viewOffset, f32(viewOffset#x), f32(viewOffset#y));
            gl.uniform2f(uniforms#viewScale, f32(viewScale#x), f32(viewScale#y));
            gl.uniform2f(uniforms#halfDesign, f32(halfDesign#x), f32(halfDesign#y));
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

    /// タイルインスタンスデータ用の VBO を新規に作り、中身をアップロードする。
    /// 各インスタンスは 10 floats:
    /// instPos(2) + instUVO(2) + instUVS(2) + instA(1) + instTint(3) = 40 bytes
    pub def buildTileInstanceVBO(gl: GlContext, instances: List[RenderType.TileInstance]): Int32 \ IO =
        let vbo = gl.createBuffer();
        uploadTileInstances(gl, vbo, instances);
        vbo

    /// 既存のインスタンス VBO へ中身を入れ直す（glBufferData の作り直し —
    /// 古い領域はドライバが回収する）。作り直しの多いタイル層が VBO を積み増さないための関数。
    pub def uploadTileInstances(gl: GlContext, vbo: Int32, instances: List[RenderType.TileInstance]): Unit \ IO =
        let f32 = RenderUtil.f32;
        let count = List.length(instances);
        let data = Array.empty(Static, count * 10);
        discard List.foldLeft((i, inst) -> {
            let base = i * 10;
            let px = inst#px;
            Array.put(f32(px#x),       base + 0, data);
            Array.put(f32(px#y),       base + 1, data);
            let uvOff = inst#uvOff;
            Array.put(f32(uvOff#x),    base + 2, data);
            Array.put(f32(uvOff#y),    base + 3, data);
            let uvSc = inst#uvSc;
            Array.put(f32(uvSc#x),     base + 4, data);
            Array.put(f32(uvSc#y),     base + 5, data);
            Array.put(f32(inst#alpha), base + 6, data);
            let tint = inst#tint;
            Array.put(f32(tint#r),     base + 7, data);
            Array.put(f32(tint#g),     base + 8, data);
            Array.put(f32(tint#b),     base + 9, data);
            i + 1
        }, 0, instances);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.STATIC_DRAW);
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
    /// uniforms は起動時に 1 回だけ引いた location 一式（RenderShader.tileUniformsOf）。
    pub def drawTileMapInstanced(gl: GlContext, tileShader: Int32, texId: Int32, tileVao: Int32,
                                  uniforms: RenderShader.TileUniforms,
                                  layerPos: Vec2.Vec2, tileSize: Float64,
                                  tileScale: Vec2.Vec2,
                                  color: Color, tileCount: Int32): Unit \ IO =
        let f32 = RenderUtil.f32;
        gl.useProgram(tileShader);
        gl.uniform2f(uniforms#layerPos, f32(layerPos#x), f32(layerPos#y));
        gl.uniform1f(uniforms#tileSize, f32(tileSize));
        gl.uniform2f(uniforms#tileScale, f32(tileScale#x), f32(tileScale#y));
        gl.uniform3f(uniforms#layerColor, f32(color#r), f32(color#g), f32(color#b));
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

    /// 宣言シェーダー面 1 枚を描く。共有 quad VAO（loc0 = x,y,u,v）を使い、
    /// rect（スクリーン px）と time を uniform で差して 1 draw call で塗る。
    /// projection は起動時に setProjectionMatrix 済みの前提（program ごとに1回）。
    /// texBinds が非空なら各 unit へテクスチャ + sampler を bind し、描画後は使った全 unit
    ///（unit 0 含む）の sampler を解除して unit 0 へ戻す — unit 0 は sprite / tile / static /
    /// font が glActiveTexture を触らず共用するため、残すとフォント作り直しやアトラス
    /// 差し替えが別 unit へ上がる事故になる。
    pub def drawShaderSurface(gl: GlContext, program: Int32, vao: Int32, uniforms: SurfaceUniforms,
                              texBinds: List[SurfaceTexBind],
                              rect: Rect2.Rect2, time: Float64, alpha: Float64, blend: DrawCmd.BlendMode): Unit \ IO =
        let f32 = RenderUtil.f32;
        gl.useProgram(program);
        applyBlend(gl, blend);
        gl.uniform2f(uniforms#rectPos, f32(rect#position#x), f32(rect#position#y));
        gl.uniform2f(uniforms#rectSize, f32(rect#size#x), f32(rect#size#y));
        gl.uniform1f(uniforms#time, f32(time));
        // 毎回差す。program は面どうしで共有され、差さないと前の面の濃さ（初めは 0.0 = 透明）が残る。
        gl.uniform1f(uniforms#alpha, f32(alpha));
        List.forEach(tb -> {
            gl.activeTexture(GlConst.TEXTURE0 + tb#texUnit);
            gl.bindTexture(GlConst.TEXTURE_2D, tb#texId);
            gl.bindSampler(tb#texUnit, tb#sampler);
            gl.uniform1f(tb#flipLoc, f32(tb#flip))
        }, texBinds);
        gl.bindVertexArray(vao);
        gl.drawArrays(GlConst.TRIANGLES, 0, 6);
        gl.bindVertexArray(0);
        if (List.isEmpty(texBinds)) ()
        else {
            List.forEach(tb -> gl.bindSampler(tb#texUnit, 0), texBinds);
            gl.activeTexture(GlConst.TEXTURE0)
        }

    /// マスク多角形（スクリーン px）を三角形化し、drawPolygonBatch が食う頂点配列
    /// （頂点ごとに x,y,r,g,b,a の 6 float・色はステンシルにしか使わないので白）へ。
    /// 戻り値 = (頂点配列, 頂点数)。
    def buildMaskData(maskPolys: List[List[Vec2.Vec2]]): (Array[Float32, Static], Int32) \ IO =
        let f32 = RenderUtil.f32;
        let flat = maskPolys |> List.flatMap(poly ->
            Triangulate.triangles(poly) |> List.flatMap(tri -> {
                let (a, b, c) = tri; a :: b :: c :: Nil }));
        let n = List.length(flat);
        let data = Array.empty(Static, n * 6);
        discard List.foldLeft((i, v) -> {
            let base = i * 6;
            Array.put(f32(v#x), base + 0, data);
            Array.put(f32(v#y), base + 1, data);
            Array.put(1.0f32, base + 2, data);
            Array.put(1.0f32, base + 3, data);
            Array.put(1.0f32, base + 4, data);
            Array.put(1.0f32, base + 5, data);
            i + 1
        }, 0, flat);
        (data, n)

    /// 宣言シェーダー面を maskPolys（スクリーン px の多角形）の内側だけに抜いて描く。
    /// mask を GL のステンシルに焼き（色は書かない・内側を 1 に）、EQUAL テスト付きで矩形を塗る。
    /// これで丸い池形など任意の形に水面を切り抜ける（矩形の隅がはみ出さない）。
    /// mask が退化（頂点 3 未満）なら素直に矩形そのまま描く。
    pub def drawShaderSurfaceMasked(gl: GlContext, program: Int32, vao: Int32, uniforms: SurfaceUniforms,
                                    texBinds: List[SurfaceTexBind],
                                    rect: Rect2.Rect2, time: Float64, alpha: Float64, blend: DrawCmd.BlendMode,
                                    polyShader: Int32, polyVao: Int32, polyVbo: Int32,
                                    polyUniforms: RenderShader.PolyBatchUniforms,
                                    maskPolys: List[List[Vec2.Vec2]]): Unit \ IO =
        let (maskData, maskCount) = buildMaskData(maskPolys);
        if (maskCount < 3)
            drawShaderSurface(gl, program, vao, uniforms, texBinds,
                              rect, time, alpha, blend)
        else {
            // 1) mask を stencil に描き込む（色は書かず内側を 1 に）。この面ぶんだけ使うので毎回 clear。
            gl.enable(GlConst.STENCIL_TEST);
            gl.stencilMask(255i32);
            gl.clearStencil(0);
            gl.clear(GlConst.STENCIL_BUFFER_BIT);
            gl.stencilFunc(GlConst.ALWAYS, 1i32, 255i32);
            gl.stencilOp(GlConst.KEEP, GlConst.KEEP, GlConst.REPLACE);
            gl.colorMask(false, false, false, false);
            drawPolygonBatch(gl, polyShader, polyVao, polyVbo, polyUniforms,
                             DrawCmd.BlendMode.Normal, maskData, maskCount);
            gl.colorMask(true, true, true, true);
            // 2) stencil==1 の画素だけシェーダー矩形を塗る（stencil は書かない）。
            gl.stencilFunc(GlConst.EQUAL, 1i32, 255i32);
            gl.stencilOp(GlConst.KEEP, GlConst.KEEP, GlConst.KEEP);
            gl.stencilMask(0i32);
            drawShaderSurface(gl, program, vao, uniforms, texBinds,
                              rect, time, alpha, blend);
            // 3) 後始末（次の描画にステンシル状態を持ち越さない）。
            gl.stencilMask(255i32);
            gl.disable(GlConst.STENCIL_TEST)
        }

    // ========================================================================
    // Sprite Instanced Rendering — 連続する同テクスチャのスプライトを 1 draw call で
    // ========================================================================

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

    /// 同じテクスチャのスプライト count 体を 1 回の instanced draw で描画する。
    /// data は 1 体 38 floats を列順に並べた instance データ（RenderFrame が組む）。
    /// 毎フレーム glBufferData で丸ごと差し替える（orphaning。drawPolygon と同方式）。
    /// texId = 0 は単色矩形の run で、シェーダはテクスチャを読まないので bind しない。
    /// blend は run 内で均一（RenderFrame が blend 変化で run を切る）。multiplyBlendLoc は
    /// instanced シェーダの premultiply スイッチの location（起動時に 1 回引いたもの）。
    pub def drawSpriteInstanced(gl: GlContext, shader: Int32, vao: Int32, instanceVbo: Int32, texId: Int32,
                                 multiplyBlendLoc: Int32, blend: DrawCmd.BlendMode,
                                 data: Array[Float32, Static], count: Int32): Unit \ IO =
        gl.useProgram(shader);
        applyBlend(gl, blend);
        gl.uniform1i(multiplyBlendLoc, multiplyFlag(blend));
        if (texId != 0) {
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindTexture(GlConst.TEXTURE_2D, texId)
        } else ();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, instanceVbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.DYNAMIC_DRAW);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.drawArraysInstanced(GlConst.TRIANGLES, 0, 6, count);
        gl.bindVertexArray(0)

    /// 溜めた instance [0, count) を 1 回の instanced draw で描く（入れ物から直に流す）。
    /// 流し終えたら書ける範囲を元に戻す — 上限を切ったままだと次の書き込みが弾かれる。
    pub def drawSpriteInstancedBuf(gl: GlContext, shader: Int32, vao: Int32, instanceVbo: Int32, texId: Int32,
                                    multiplyBlendLoc: Int32, blend: DrawCmd.BlendMode,
                                    data: FloatBuffer, count: Int32): Unit \ IO =
        gl.useProgram(shader);
        applyBlend(gl, blend);
        gl.uniform1i(multiplyBlendLoc, multiplyFlag(blend));
        if (texId != 0) {
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindTexture(GlConst.TEXTURE_2D, texId)
        } else ();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, instanceVbo);
        discard data.position(0);
        discard data.limit(count * 38);
        gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.DYNAMIC_DRAW);
        discard data.clear();
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.drawArraysInstanced(GlConst.TRIANGLES, 0, 6, count);
        gl.bindVertexArray(0)

    /// スプライト 1 体を maskPolys（スクリーン px の多角形）の内側だけに抜いて描く。
    /// 手順は drawShaderSurfaceMasked と同じステンシル流用: mask を描き込む（色は書かない）→
    /// EQUAL テスト付きで instance 1 体だけ描く → 後始末。instData には slot 0 に
    /// 1 体ぶんが書き込み済みの前提（RenderFrame が writeInstAt で書く）。
    /// mask が退化（頂点 3 未満）ならステンシルを触らずそのまま 1 体描く。
    pub def drawSpriteMasked(gl: GlContext, shader: Int32, vao: Int32, instanceVbo: Int32, texId: Int32,
                             multiplyBlendLoc: Int32, blend: DrawCmd.BlendMode,
                             instData: FloatBuffer,
                             polyShader: Int32, polyVao: Int32, polyVbo: Int32,
                             polyUniforms: RenderShader.PolyBatchUniforms,
                             maskPolys: List[List[Vec2.Vec2]]): Unit \ IO =
        let (maskData, maskCount) = buildMaskData(maskPolys);
        if (maskCount < 3)
            drawSpriteInstancedBuf(gl, shader, vao, instanceVbo, texId, multiplyBlendLoc, blend,
                                   instData, 1)
        else {
            // 1) mask を stencil に描き込む（色は書かず内側を 1 に）。この 1 体ぶんだけ使うので毎回 clear。
            gl.enable(GlConst.STENCIL_TEST);
            gl.stencilMask(255i32);
            gl.clearStencil(0);
            gl.clear(GlConst.STENCIL_BUFFER_BIT);
            gl.stencilFunc(GlConst.ALWAYS, 1i32, 255i32);
            gl.stencilOp(GlConst.KEEP, GlConst.KEEP, GlConst.REPLACE);
            gl.colorMask(false, false, false, false);
            drawPolygonBatch(gl, polyShader, polyVao, polyVbo, polyUniforms,
                             DrawCmd.BlendMode.Normal, maskData, maskCount);
            gl.colorMask(true, true, true, true);
            // 2) stencil==1 の画素だけスプライトを描く（stencil は書かない）。
            gl.stencilFunc(GlConst.EQUAL, 1i32, 255i32);
            gl.stencilOp(GlConst.KEEP, GlConst.KEEP, GlConst.KEEP);
            gl.stencilMask(0i32);
            drawSpriteInstancedBuf(gl, shader, vao, instanceVbo, texId, multiplyBlendLoc, blend,
                                   instData, 1);
            // 3) 後始末（次の描画にステンシル状態を持ち越さない）。
            gl.stencilMask(255i32);
            gl.disable(GlConst.STENCIL_TEST)
        }

}
