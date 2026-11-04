// RenderShader — 描画に使うシェーダのソース・コンパイル・投影行列の設定をまとめる。
// スプライト用とタイルマップ用のシェーダ準備を一箇所に閉じるので、上位は組み上がったものを使うだけでよい。
// 利用例: 起動時にシェーダを用意する / 画面の解像度に合わせて座標変換を設定する。

mod RenderShader {
    import fge.gl.GlContext
    import fge.gl.GlContext
    import fge.gl.GlConst
    import fge.gl.GlContext

    // ========================================================================
    // Shader Sources
    // ========================================================================

    pub def vertexShaderSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec4 vertex;\n" +
        "out vec2 TexCoords;\n" +
        "uniform mat4 model;\n" +
        "uniform mat4 projection;\n" +
        "uniform vec2 uvOffset;\n" +
        "uniform vec2 uvScale;\n" +
        "void main() {\n" +
        "    TexCoords = vertex.zw * uvScale + uvOffset;\n" +
        "    gl_Position = projection * model * vec4(vertex.xy, 0.0, 1.0);\n" +
        "}\n"

    pub def fragmentShaderSource(): String =
        "#version 330 core\n" +
        "in vec2 TexCoords;\n" +
        "out vec4 color;\n" +
        "uniform sampler2D image;\n" +
        "uniform vec3 spriteColor;\n" +
        "uniform float spriteAlpha;\n" +
        "uniform bool useTexture;\n" +
        // SDF テキスト用。useTexture かつ sdfText のとき、テクスチャ .a を距離場として
        // smoothstep で輪郭を再構成する (任意サイズで縁がくっきり)。
        "uniform bool sdfText;\n" +
        // styled (角丸＋枠) 単色矩形用。styleEnabled=false なら従来の単色塗り。
        "uniform bool styleEnabled;\n" +
        "uniform vec2 rectSize;\n" +
        "uniform float cornerRadius;\n" +
        "uniform float borderWidth;\n" +
        "uniform vec3 borderColor;\n" +
        "uniform float borderAlpha;\n" +
        // 塗り領域に重ねる斜線ハッチ (CSS repeating-linear-gradient 相当)。hatchEnabled=false で従来の塗り。
        "uniform bool hatchEnabled;\n" +
        "uniform vec3 hatchColor;\n" +
        "uniform float hatchAlpha;\n" +
        "uniform float hatchWidth;\n" +
        "uniform float hatchPeriod;\n" +
        // 縞の向き。0 = 斜め 45° / 1 = 横縞 / 2 = 縦縞。
        "uniform int hatchDir;\n" +
        // 塗り領域に重ねる市松のタイル。checkerCell<=0 または checkerAlpha<=0 で無効。
        "uniform vec3 checkerColor;\n" +
        "uniform float checkerAlpha;\n" +
        "uniform float checkerCell;\n" +
        // Multiply ブレンド時に rgb へ alpha を掛けて出す（premultiply）。glBlendFunc の
        // 因子だけでは「alpha ぶんだけ乗算を弱める」式が作れないため、シェーダ側で仕込む。
        "uniform bool multiplyBlend;\n" +
        // 角丸矩形 SDF (RenderSdf.roundedBox と同式)。p=中心からのオフセット, hsz=半サイズ, r=角半径。
        "float roundedBox(vec2 p, vec2 hsz, float r) {\n" +
        "    vec2 q = abs(p) - hsz + r;\n" +
        "    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;\n" +
        "}\n" +
        "void main() {\n" +
        "    if (useTexture) {\n" +
        "        if (sdfText) {\n" +
        "            float d = texture(image, TexCoords).a;\n" +          // 距離場 (swizzle で R=alpha)
        "            float aa = fwidth(d);\n" +                            // 画面 px 基準の AA 幅
        "            float a = smoothstep(0.5 - aa, 0.5 + aa, d);\n" +
        "            if (a < 0.004) discard;\n" +
        "            color = vec4(spriteColor, spriteAlpha * a);\n" +
        "        } else {\n" +
        // Rgba16Float の Pass の α は Add で 1 を超えて溜まるので、読む所で 0..1 に切る（8bit の絵では α は 1 以下で変わらない）。
        // WhyNot: glBlendFuncSeparate で α の溜まり方を変えない — 8bit の ClearTransparent の Pass の α が変わり、それを貼った絵が変わる。
        "            vec4 t = texture(image, TexCoords);\n" +
        "            t.a = clamp(t.a, 0.0, 1.0);\n" +
        "            color = vec4(spriteColor, spriteAlpha) * t;\n" +
        "        }\n" +
        "    } else if (styleEnabled) {\n" +
        "        vec2 hsz = rectSize * 0.5;\n" +
        "        vec2 p = TexCoords * rectSize - hsz;\n" +
        // 角半径は矩形の最小半辺にクランプ（巨大値を入れても形が破綻しないように）
        "        float cr = clamp(cornerRadius, 0.0, min(hsz.x, hsz.y));\n" +
        "        float dOuter = roundedBox(p, hsz, cr);\n" +
        // AA 幅は画面 px 基準 (fwidth)。カメラ zoom で rectSize が小さくなっても角丸が潰れない
        // （固定 1px AA だと縮小時に AA の幅が矩形全体を覆い、角丸が消えて四角に見える）。
        "        float aaO = max(fwidth(dOuter), 0.0001);\n" +
        "        float outerCov = 1.0 - smoothstep(0.0, aaO, dOuter);\n" +   // 矩形内=1 / 外=0
        "        float ri = max(cr - borderWidth, 0.0);\n" +
        "        vec2 hi = max(hsz - vec2(borderWidth), vec2(0.0));\n" +
        "        float dInner = roundedBox(p, hi, ri);\n" +
        "        float aaI = max(fwidth(dInner), 0.0001);\n" +
        "        float fillCov = 1.0 - smoothstep(0.0, aaI, dInner);\n" +    // 塗り領域=1 / 枠+外=0
        // 塗りベース。hatchEnabled なら斜線を塗りの上に over 合成してから枠と混ぜる。
        "        vec3 fillRgb = spriteColor;\n" +
        "        float fillA = spriteAlpha;\n" +
        "        if (hatchEnabled) {\n" +
        // hatchDir で縞の向きを切替 (0: x-y で 45° / 1: y で横縞 / 2: x で縦縞)。
        "            float hv = (hatchDir == 1) ? p.y : ((hatchDir == 2) ? p.x : (p.x - p.y));\n" +
        "            float m = mod(hv, hatchPeriod);\n" +                    // 縞の位相
        // 軸に沿った縞 (dir 1/2) はピクセル整列なので AA を掛けずくっきり出す (走査線用)。45° だけ AA。
        "            float haa = (hatchDir == 0) ? max(fwidth(hv), 0.0001) : 0.0001;\n" +
        "            float sOn = smoothstep(0.0, haa, m) - smoothstep(hatchWidth, hatchWidth + haa, m);\n" +
        "            float sa = hatchAlpha * clamp(sOn, 0.0, 1.0);\n" +
        "            float outA = sa + fillA * (1.0 - sa);\n" +
        "            fillRgb = (outA > 0.0001) ? (hatchColor * sa + fillRgb * fillA * (1.0 - sa)) / outA : fillRgb;\n" +
        "            fillA = outA;\n" +
        "        }\n" +
        // 市松タイル。on のセルだけ checkerColor を over 合成 (縞 → 市松 → 枠の順)。
        "        if (checkerCell > 0.0 && checkerAlpha > 0.0) {\n" +
        "            bool on = mod(floor(p.x / checkerCell) + floor(p.y / checkerCell), 2.0) < 0.5;\n" +
        "            float ca = on ? checkerAlpha : 0.0;\n" +
        "            float outA = ca + fillA * (1.0 - ca);\n" +
        "            fillRgb = (outA > 0.0001) ? (checkerColor * ca + fillRgb * fillA * (1.0 - ca)) / outA : fillRgb;\n" +
        "            fillA = outA;\n" +
        "        }\n" +
        "        vec3 rgb = mix(borderColor, fillRgb, fillCov);\n" +
        "        float a = mix(borderAlpha, fillA, fillCov) * outerCov;\n" +
        "        if (a < 0.004) discard;\n" +
        "        color = vec4(rgb, a);\n" +
        "    } else {\n" +
        "        color = vec4(spriteColor, spriteAlpha);\n" +
        "    }\n" +
        // Multiply の合成は dst×(1−a×(1−src))。GL 側 (GL_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA) と
        // 合わせるにはここで rgb×a（premultiply）が要る — 因子を変えるだけだと a=0 でオーバーレイが
        // 消えるどころか明るくなる。
        "    if (multiplyBlend) { color.rgb *= color.a; }\n" +
        "}\n"

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
    /// mat2(inst1.xy, inst1.zw) + inst2 は drawSprite の model 行列
    /// （回転×スケール＋平行移動）と同じ変換。
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

    /// instanced sprite 用のフラグメントシェーダ。
    /// 分岐・数式は uniform 版 (fragmentShaderSource) の逐語移植で、
    /// uniform を instance 由来の varying に置き換えただけ。式を同一に
    /// 保つことで per-draw 経路と 1 ピクセルも違わないことを保証する。
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
        // uniform 版と同じ Multiply 用 premultiply スイッチ。run 内は blend が均一
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
        // 軸に沿った縞 (dir 1/2) はピクセル整列なので AA を掛けずくっきり出す (uniform 版と同じ規約)。
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
        // uniform 版 main 末尾と同じ premultiply（式を同一に保ち経路間で絵を割らない）。
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
    /// 頂点色をそのまま出すだけ。末尾の premultiply は uniform 版 drawPolygon と同式で、
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

    /// sprite シェーダの uniform location 一式。
    /// location はリンク後に不変。毎フレーム文字列で問い合わせると描画数×十数回の
    /// JNI 呼び出しになるため、起動時に 1 回だけ引いてレコードに詰めて持ち回る。
    pub type alias SpriteUniforms = {
        model = Int32,
        spriteColor = Int32,
        spriteAlpha = Int32,
        uvOffset = Int32,
        uvScale = Int32,
        useTexture = Int32,
        sdfText = Int32,
        styleEnabled = Int32,
        rectSize = Int32,
        cornerRadius = Int32,
        borderWidth = Int32,
        borderColor = Int32,
        borderAlpha = Int32,
        hatchEnabled = Int32,
        hatchColor = Int32,
        hatchAlpha = Int32,
        hatchWidth = Int32,
        hatchPeriod = Int32,
        hatchDir = Int32,
        checkerColor = Int32,
        checkerAlpha = Int32,
        checkerCell = Int32,
        multiplyBlend = Int32
    }

    /// tile シェーダの uniform location 一式。理由は `SpriteUniforms` と同じ。
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

    pub def spriteUniformsOf(gl: GlContext, shader: Int32): SpriteUniforms \ IO =
        {
            model = gl.getUniformLocation(shader, "model"),
            spriteColor = gl.getUniformLocation(shader, "spriteColor"),
            spriteAlpha = gl.getUniformLocation(shader, "spriteAlpha"),
            uvOffset = gl.getUniformLocation(shader, "uvOffset"),
            uvScale = gl.getUniformLocation(shader, "uvScale"),
            useTexture = gl.getUniformLocation(shader, "useTexture"),
            sdfText = gl.getUniformLocation(shader, "sdfText"),
            styleEnabled = gl.getUniformLocation(shader, "styleEnabled"),
            rectSize = gl.getUniformLocation(shader, "rectSize"),
            cornerRadius = gl.getUniformLocation(shader, "cornerRadius"),
            borderWidth = gl.getUniformLocation(shader, "borderWidth"),
            borderColor = gl.getUniformLocation(shader, "borderColor"),
            borderAlpha = gl.getUniformLocation(shader, "borderAlpha"),
            hatchEnabled = gl.getUniformLocation(shader, "hatchEnabled"),
            hatchColor = gl.getUniformLocation(shader, "hatchColor"),
            hatchAlpha = gl.getUniformLocation(shader, "hatchAlpha"),
            hatchWidth = gl.getUniformLocation(shader, "hatchWidth"),
            hatchPeriod = gl.getUniformLocation(shader, "hatchPeriod"),
            hatchDir = gl.getUniformLocation(shader, "hatchDir"),
            checkerColor = gl.getUniformLocation(shader, "checkerColor"),
            checkerAlpha = gl.getUniformLocation(shader, "checkerAlpha"),
            checkerCell = gl.getUniformLocation(shader, "checkerCell"),
            multiplyBlend = gl.getUniformLocation(shader, "multiplyBlend")
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
