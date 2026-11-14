// RenderShader — 描画に使うシェーダのソース・コンパイル・投影行列の設定をまとめる。
// スプライト用とタイルマップ用のシェーダ準備を一箇所に閉じるので、上位は組み上がったものを使うだけでよい。
// 利用例: 起動時にシェーダを用意する / 画面の解像度に合わせて座標変換を設定する。

mod RenderShader {
    import fge.gl.GlContext
    import fge.gl.GlConst

    // ========================================================================
    // Shader Sources
    // ========================================================================

    pub def tileVertexShaderSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec4 vertex;\n" +
        "layout (location = 1) in vec2 instPos;\n" +
        "layout (location = 2) in vec2 instUVO;\n" +
        "layout (location = 3) in vec2 instUVS;\n" +
        "layout (location = 4) in float instA;\n" +
        "layout (location = 5) in vec3 instTint;\n" +
        "out vec2 TexCoords;\n" +
        "out float FragAlpha;\n" +
        "out vec3 FragTint;\n" +
        "uniform mat4 projection;\n" +
        "uniform vec2 layerPos;\n" +
        "uniform float tileSize;\n" +
        "uniform vec2 tileScale;\n" +
        "void main() {\n" +
        "    vec2 screenPos = layerPos + (instPos + vertex.xy * tileSize) * tileScale;\n" +
        "    gl_Position = projection * vec4(screenPos, 0.0, 1.0);\n" +
        "    TexCoords = instUVO + vertex.zw * instUVS;\n" +
        "    FragAlpha = instA;\n" +
        "    FragTint = instTint;\n" +
        "}\n"

    pub def tileFragmentShaderSource(): String =
        "#version 330 core\n" +
        "in vec2 TexCoords;\n" +
        "in float FragAlpha;\n" +
        "in vec3 FragTint;\n" +
        "out vec4 color;\n" +
        "uniform sampler2D image;\n" +
        "uniform vec3 layerColor;\n" +
        "void main() {\n" +
        "    vec4 t = texture(image, TexCoords);\n" +
        "    color = vec4(layerColor * FragTint * t.rgb, t.a * FragAlpha);\n" +
        "    if (color.a < 0.01) discard;\n" +
        "}\n"

    /// instanced sprite 用の頂点シェーダ。1 体分の変換・UV・色・スタイル
    /// (角丸・枠・ハッチ・市松) をすべて instance 属性 (loc1-10) で受け取るので、
    /// uniform の設定なしに 1 回の draw call で何千体でも描ける。
    /// スタイルまで属性に載せるのは、単色矩形が常に style 付きで届く
    /// (RawDraw.box が solidStyle を持たせる) ため、style をバッチ分割条件に
    /// すると矩形が全部 1 枚ずつ描かれて一括化の意味が消えるから。
    /// mat2(inst1.xy, inst1.zw) + inst2 は回転×スケール＋平行移動（RenderFrame.writeInstAt が CPU で組む）。
    pub def spriteInstancedVertexShaderSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec4 vertex;\n" +
        "layout (location = 1) in vec4 inst1;\n" +   // ワールド変換 2x2: (c*sx, s*sx, -s*sy, c*sy)
        "layout (location = 2) in vec2 inst2;\n" +   // 平行移動 (tx, ty)
        "layout (location = 3) in vec4 inst3;\n" +   // uvOffset.xy + uvScale.zw
        "layout (location = 4) in vec4 inst4;\n" +   // color.rgb + alpha
        "layout (location = 5) in vec4 inst5;\n" +   // useTexture, sdfText, styleEnabled, hatchEnabled
        "layout (location = 6) in vec4 inst6;\n" +   // rectSize.xy, cornerRadius, borderWidth
        "layout (location = 7) in vec4 inst7;\n" +   // borderColor.rgb + borderAlpha
        "layout (location = 8) in vec4 inst8;\n" +   // hatchColor.rgb + hatchAlpha
        "layout (location = 9) in vec4 inst9;\n" +   // hatchWidth, hatchPeriod, hatchDir, checkerCell
        "layout (location = 10) in vec4 inst10;\n" + // checkerColor.rgb + checkerAlpha
        "out vec2 TexCoords;\n" +
        "out vec4 InstColor;\n" +
        "out vec4 InstFlags;\n" +
        "out vec4 InstRect;\n" +
        "out vec4 InstBorder;\n" +
        "out vec4 InstHatch;\n" +
        "out vec4 InstHatchDim;\n" +
        "out vec4 InstChecker;\n" +
        "uniform mat4 projection;\n" +
        "void main() {\n" +
        "    vec2 world = mat2(inst1.xy, inst1.zw) * vertex.xy + inst2;\n" +
        "    gl_Position = projection * vec4(world, 0.0, 1.0);\n" +
        "    TexCoords = vertex.zw * inst3.zw + inst3.xy;\n" +
        "    InstColor = inst4;\n" +
        "    InstFlags = inst5;\n" +
        "    InstRect = inst6;\n" +
        "    InstBorder = inst7;\n" +
        "    InstHatch = inst8;\n" +
        "    InstHatchDim = inst9;\n" +
        "    InstChecker = inst10;\n" +
        "}\n"

    /// instanced sprite 用のフラグメントシェーダ。1 体ぶんの値は instance 由来の varying で受ける。
    /// 角丸・枠・ハッチ・市松の式は CPU の描き手（SoftRaster）と同じ式にそろえてあり、
    /// 突き合わせは gl-parity が画素で見る。
    pub def spriteInstancedFragmentShaderSource(): String =
        "#version 330 core\n" +
        "in vec2 TexCoords;\n" +
        "in vec4 InstColor;\n" +
        "in vec4 InstFlags;\n" +
        "in vec4 InstRect;\n" +
        "in vec4 InstBorder;\n" +
        "in vec4 InstHatch;\n" +
        "in vec4 InstHatchDim;\n" +
        "in vec4 InstChecker;\n" +
        "out vec4 color;\n" +
        "uniform sampler2D image;\n" +
        // Multiply 用 premultiply スイッチ。run 内は blend が均一
        // （RenderFrame が blend 変化で run を切る）ため per-instance 属性ではなく uniform で足りる。
        "uniform bool multiplyBlend;\n" +
        "float roundedBox(vec2 p, vec2 hsz, float r) {\n" +
        "    vec2 q = abs(p) - hsz + r;\n" +
        "    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;\n" +
        "}\n" +
        "void main() {\n" +
        "    if (InstFlags.x > 0.5) {\n" +
        "        if (InstFlags.y > 0.5) {\n" +
        "            float d = texture(image, TexCoords).a;\n" +          // 距離場 (swizzle で R=alpha)
        "            float aa = fwidth(d);\n" +                            // 画面 px 基準の AA 幅
        "            float a = smoothstep(0.5 - aa, 0.5 + aa, d);\n" +
        "            if (a < 0.004) discard;\n" +
        "            color = vec4(InstColor.rgb, InstColor.a * a);\n" +
        "        } else {\n" +
        // α を読む所で切る理由は fragmentShaderSource と同じ。
        "            vec4 t = texture(image, TexCoords);\n" +
        "            t.a = clamp(t.a, 0.0, 1.0);\n" +
        "            color = InstColor * t;\n" +
        "        }\n" +
        "    } else if (InstFlags.z > 0.5) {\n" +
        "        vec2 hsz = InstRect.xy * 0.5;\n" +
        "        vec2 p = TexCoords * InstRect.xy - hsz;\n" +
        "        float cr = clamp(InstRect.z, 0.0, min(hsz.x, hsz.y));\n" +
        "        float dOuter = roundedBox(p, hsz, cr);\n" +
        "        float aaO = max(fwidth(dOuter), 0.0001);\n" +
        "        float outerCov = 1.0 - smoothstep(0.0, aaO, dOuter);\n" +
        "        float ri = max(cr - InstRect.w, 0.0);\n" +
        "        vec2 hi = max(hsz - vec2(InstRect.w), vec2(0.0));\n" +
        "        float dInner = roundedBox(p, hi, ri);\n" +
        "        float aaI = max(fwidth(dInner), 0.0001);\n" +
        "        float fillCov = 1.0 - smoothstep(0.0, aaI, dInner);\n" +
        "        vec3 fillRgb = InstColor.rgb;\n" +
        "        float fillA = InstColor.a;\n" +
        "        if (InstFlags.w > 0.5) {\n" +
        "            float hv = (InstHatchDim.z > 1.5) ? p.x : ((InstHatchDim.z > 0.5) ? p.y : (p.x - p.y));\n" +
        "            float m = mod(hv, InstHatchDim.y);\n" +
        // 軸に沿った縞 (dir 1/2) はピクセル整列なので AA を掛けずくっきり出す。
        "            float haa = (InstHatchDim.z > 0.5) ? 0.0001 : max(fwidth(hv), 0.0001);\n" +
        "            float sOn = smoothstep(0.0, haa, m) - smoothstep(InstHatchDim.x, InstHatchDim.x + haa, m);\n" +
        "            float sa = InstHatch.a * clamp(sOn, 0.0, 1.0);\n" +
        "            float outA = sa + fillA * (1.0 - sa);\n" +
        "            fillRgb = (outA > 0.0001) ? (InstHatch.rgb * sa + fillRgb * fillA * (1.0 - sa)) / outA : fillRgb;\n" +
        "            fillA = outA;\n" +
        "        }\n" +
        "        if (InstHatchDim.w > 0.0 && InstChecker.a > 0.0) {\n" +
        "            bool on = mod(floor(p.x / InstHatchDim.w) + floor(p.y / InstHatchDim.w), 2.0) < 0.5;\n" +
        "            float ca = on ? InstChecker.a : 0.0;\n" +
        "            float outA = ca + fillA * (1.0 - ca);\n" +
        "            fillRgb = (outA > 0.0001) ? (InstChecker.rgb * ca + fillRgb * fillA * (1.0 - ca)) / outA : fillRgb;\n" +
        "            fillA = outA;\n" +
        "        }\n" +
        "        vec3 rgb = mix(InstBorder.rgb, fillRgb, fillCov);\n" +
        "        float a = mix(InstBorder.a, fillA, fillCov) * outerCov;\n" +
        "        if (a < 0.004) discard;\n" +
        "        color = vec4(rgb, a);\n" +
        "    } else {\n" +
        "        color = InstColor;\n" +
        "    }\n" +
        // Multiply の合成は dst×(1−a×(1−src))。GL の因子 (GL_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA) と合わせるには rgb×a（premultiply）が要る。
        "    if (multiplyBlend) { color.rgb *= color.a; }\n" +
        "}\n"

    /// 多角形バッチ用の頂点シェーダ。1 頂点 = 位置(vec2) + 色(vec4)。
    /// 同じ blend / 切り抜き clip 矩形の多角形を三角形化して 1 本の頂点バッファに連結し、
    /// 1 回の draw call でまとめて塗る。色を uniform でなく頂点属性で持たせるのは、
    /// 多角形ごとに色が違っても run をまたいで 1 バッファに詰められるようにするため
    /// （洞窟の壁数千枚が 1 枚ずつ描かれる詰まりを解く）。
    pub def polyBatchVertexShaderSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 vertex;\n" +
        "layout (location = 1) in vec4 vColor;\n" +   // color.rgb + alpha（アルファは頂点色へ掛け合わせ済み）
        "out vec4 FragColor;\n" +
        "uniform mat4 projection;\n" +
        // カメラの平行移動 / ズームを頂点シェーダで当てる（タイルの layerPos/tileScale と同型）。
        // 動的多角形は既に centerOn 済みのスクリーン座標で来るので、毎 draw call で
        // viewOffset=(0,0) viewScale=(1,1) halfDesign=(0,0) を渡して恒等にする（絵は不変）。
        // 静的多角形はワールド座標で焼き、viewOffset=camera center・viewScale=zoom・
        // halfDesign=design/2 を渡して screenPos に写す。
        "uniform vec2 viewOffset;\n" +
        "uniform vec2 viewScale;\n" +
        "uniform vec2 halfDesign;\n" +
        "void main() {\n" +
        "    vec2 screenPos = (vertex - viewOffset) * viewScale + halfDesign;\n" +
        "    gl_Position = projection * vec4(screenPos, 0.0, 1.0);\n" +
        "    FragColor = vColor;\n" +
        "}\n"

    /// 多角形バッチ用のフラグメントシェーダ。
    /// 頂点色をそのまま出すだけ。末尾の premultiply は instanced スプライトのシェーダーと同式で、
    /// Multiply ブレンド時に絵が割れないよう合わせてある（run 内は blend 均一なので uniform）。
    pub def polyBatchFragmentShaderSource(): String =
        "#version 330 core\n" +
        "in vec4 FragColor;\n" +
        "out vec4 color;\n" +
        "uniform bool multiplyBlend;\n" +
        "void main() {\n" +
        "    color = FragColor;\n" +
        "    if (multiplyBlend) { color.rgb *= color.a; }\n" +
        "}\n"

    // ========================================================================
    // Shader Compilation
    // ========================================================================

    pub def compileShader(gl: GlContext, source: String, shaderType: Int32): Int32 \ IO =
        let shader = gl.createShader(shaderType);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        let success = gl.getShaderi(shader, GlConst.COMPILE_STATUS);
        if (success == GlConst.FALSE) {
            let log = gl.getShaderInfoLog(shader);
            println("Shader compilation error: ${log}");
            bug!("Shader failed")
        } else ();
        shader

    pub def createShaderProgram(gl: GlContext, vertexSrc: String, fragmentSrc: String): Int32 \ IO =
        let vs = compileShader(gl, vertexSrc, GlConst.VERTEX_SHADER);
        let fs = compileShader(gl, fragmentSrc, GlConst.FRAGMENT_SHADER);
        let program = gl.createProgram();
        gl.attachShader(program, vs);
        gl.attachShader(program, fs);
        gl.linkProgram(program);
        let success = gl.getProgrami(program, GlConst.LINK_STATUS);
        if (success == GlConst.FALSE) {
            let log = gl.getProgramInfoLog(program);
            println("Shader linking error: ${log}");
            bug!("Linking failed")
        } else ();
        gl.deleteShader(vs);
        gl.deleteShader(fs);
        program

    // ========================================================================
    // 宣言シェーダー面（Platform.GpuResources.buildProgram）用: fail-open コンパイル
    // ========================================================================

    /// GLSL をコンパイルする（fail-open 版）。失敗時は bug! で落とさず、log をパス付きで
    /// println して None を返す（呼び側が単色フォールバックへ切り替える）。
    /// theme 由来の codegen ミスで全体クラッシュを避けるための「落ちない版」。
    pub def tryCompileShader(gl: GlContext, source: String, shaderType: Int32, label: String): Option[Int32] \ IO =
        let shader = gl.createShader(shaderType);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        let success = gl.getShaderi(shader, GlConst.COMPILE_STATUS);
        if (success == GlConst.FALSE) {
            let log = gl.getShaderInfoLog(shader);
            println("[shader ${label}] compile failed (単色フォールバックへ): ${log}");
            gl.deleteShader(shader);
            None
        } else Some(shader)

    /// vertex/fragment ソースからプログラムを作る（fail-open 版）。コンパイル/リンク
    /// いずれかが失敗したら None を返す（呼び側が単色フォールバックへ切り替える）。
    pub def tryCreateProgram(gl: GlContext, vertexSrc: String, fragmentSrc: String, label: String): Option[Int32] \ IO =
        match tryCompileShader(gl, vertexSrc, GlConst.VERTEX_SHADER, "${label}.vs") {
            case None     => None
            case Some(vs) => match tryCompileShader(gl, fragmentSrc, GlConst.FRAGMENT_SHADER, "${label}.fs") {
                case None     => gl.deleteShader(vs); None
                case Some(fs) =>
                    let program = gl.createProgram();
                    gl.attachShader(program, vs);
                    gl.attachShader(program, fs);
                    gl.linkProgram(program);
                    let ok = gl.getProgrami(program, GlConst.LINK_STATUS);
                    gl.deleteShader(vs);
                    gl.deleteShader(fs);
                    if (ok == GlConst.FALSE) {
                        let log = gl.getProgramInfoLog(program);
                        println("[shader ${label}] link failed (単色フォールバックへ): ${log}");
                        gl.deleteProgram(program);
                        None
                    } else Some(program)
            }
        }

    /// プログラムを GPU から捨てる。キャッシュから追い出したら必ずこれで捨てる —
    /// 捨て忘れると、シェーダーの数値を触って作り直すたびに GPU のメモリが増え続ける。
    pub def deleteProgram(gl: GlContext, program: Int32): Unit \ IO =
        gl.deleteProgram(program)

    /// 宣言シェーダー面の代表色ベタ塗りフォールバック用フラグメントシェーダー。
    /// codegen が壊れた GLSL を吐いた面をこれで塗る（黒画面でなく色は出る）。
    pub def fallbackFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 outColor;\n" +
        "uniform float uTime;\n" +
        "void main() {\n" +
        "    outColor = vec4(0.5, 0.2, 0.2, 1.0);\n" +
        "}\n"

    // ========================================================================
    // Uniform Locations
    // ========================================================================

    /// tile シェーダの uniform location 一式。
    /// location はリンク後に不変。毎フレーム文字列で問い合わせると描画数×十数回の
    /// JNI 呼び出しになるため、起動時に 1 回だけ引いてレコードに詰めて持ち回る。
    pub type alias TileUniforms = {
        layerPos = Int32,
        tileSize = Int32,
        tileScale = Int32,
        layerColor = Int32
    }

    /// 多角形バッチシェーダの uniform location 一式。動的多角形と静的レンジで同じ
    /// シェーダを共有し、camera（viewOffset/viewScale/halfDesign）を毎 draw call で明示設定する。
    pub type alias PolyBatchUniforms = {
        multiplyBlend = Int32,
        viewOffset = Int32,
        viewScale = Int32,
        halfDesign = Int32
    }

    pub def tileUniformsOf(gl: GlContext, shader: Int32): TileUniforms \ IO =
        {
            layerPos = gl.getUniformLocation(shader, "layerPos"),
            tileSize = gl.getUniformLocation(shader, "tileSize"),
            tileScale = gl.getUniformLocation(shader, "tileScale"),
            layerColor = gl.getUniformLocation(shader, "layerColor")
        }

    pub def polyBatchUniformsOf(gl: GlContext, shader: Int32): PolyBatchUniforms \ IO =
        {
            multiplyBlend = gl.getUniformLocation(shader, "multiplyBlend"),
            viewOffset = gl.getUniformLocation(shader, "viewOffset"),
            viewScale = gl.getUniformLocation(shader, "viewScale"),
            halfDesign = gl.getUniformLocation(shader, "halfDesign")
        }

    // ========================================================================
    // Projection Matrix
    // ========================================================================

    pub def setProjectionMatrix(gl: GlContext, shader: Int32, width: Float64, height: Float64): Unit \ IO =
        gl.useProgram(shader);
        let left = 0.0;
        let right = width;
        let bottom = height;
        let top = 0.0;
        let proj = Array#{
            RenderUtil.f32(2.0 / (right - left)), 0.0f32, 0.0f32, 0.0f32,
            0.0f32, RenderUtil.f32(2.0 / (top - bottom)), 0.0f32, 0.0f32,
            0.0f32, 0.0f32, -1.0f32, 0.0f32,
            RenderUtil.f32(-1.0 * (right + left) / (right - left)),
            RenderUtil.f32(-1.0 * (top + bottom) / (top - bottom)),
            0.0f32, 1.0f32
        } @ Static;
        let loc = gl.getUniformLocation(shader, "projection");
        gl.uniformMatrix4fv(loc, false, proj)

}
