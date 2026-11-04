// SoftRaster3d — 3D の場面（Scene3d.RenderCmd）1 つを CPU で画素に塗り、SoftRaster の下地へ重ねる。
// GL を使わない描き出し（スナップショット・テスト）で、Render3d（GL）と同じ場面を同じ光の式で描く。
// GL と画素は一致させない（Shader 面と同じ扱い）。比べは CPU の絵どうしで行う。
//
// 光・かすみ・空の式は LightModel3d の木（光の量 light・fog・空の色）。CPU はその木から生成した SoftRaster3dLight を画素ごとに呼ぶ。
// ここに書くのは木の外（入力の作り方と、光を色に掛ける所）:
//
//   色     = 頂点の色 × tint × light
//   材質のある置いた物: 色 = albedo × tint × light（頂点の色は掛けない。材質の Spec が VertexColor で読む）・fog の後に emission を足す
//            albedo・α・emission = ShaderEval.evalMaterial3(world の点・法線・uv・頂点の色, 時刻)。cutout なら α < materialCutoff() の画素を捨てる（深度も書かない）
//            材質の Tex の名前は "tex3d:" なら場面の textures、ほかは全体の登録から引いた絵（drawScene の textures）。
//            段つきの絵は lod を求めて段を読む（ShaderEval.evalMaterial3Mip。右隣と下隣の画素の入力は、三角形の重みを外へ延ばして求める）。
//            cutout の α は段 0 で読む。
//            1 つの材質が読む絵の組は Scene3d.maxMaterialTextures() まで（後ろの組は 0。GL と同じ）。
//            法線マップ（uv つきの形だけ・材質の wrap・Linear）: T = normalize(T − N (N·T))・B = cross(N, T) × w・c = 絵の rgb・
//            m = ((c.x·2 − 1)·s, (c.y·2 − 1)·s, c.z·2 − 1)・n' = normalize(T m.x + B m.y + N m.z)。光の計算は n'、Spec の Normal は当てる前の N。
//            lightmap（Scene3d.lightmapOf が Some の物だけ）: light = LightModel3d.lightmapLightingModel
//              s = lightmap の絵を 2 本目の uv で段つきの Linear・Clamp で読んだ rgb（段は min(段の数, その lightmap の maxLevels)。
//              lod は 2 本目の uv の右隣と下隣との差から Mip.lodOf）。名前が場面の textures に無い絵は 0 で読む。
//              法線マップの n' は点光源とスポットにだけ効く。
//   fog    = LightModel3d.fogModel（fog が None なら掛けない）
//   3D の色（Scene3d の頭の「3D の色」）: 光の color・ambient・かすみ・空の 3 色・tint は場面ごと・物ごとに 1 回、
//            材質の無い物の頂点の色は頂点ごとに、材質の albedo.rgb・emission とビルボードの絵の rgb は画素ごとに線形の量へ戻し、
//            emission には戻した後に emissionIntensity を掛ける。色を作った直後（shadePixel の色の枝・blendRow で重ねる前・skyFill）に
//            1 回だけ画面の値へ戻す。background・Output.Depth の灰色・法線マップは変換しない。
//   Output.Depth の灰色 = clamp((|点 − 目| − near) / max(range, 1e-6), 0, 1)（目からの直線の距離。view の z ではない）
//
// 半透明（材質の blend）: 不透明の物とビルボードで画素ごとの勝者と深度を決めて色を塗った後（1 段目）、2 段目で半透明の物を
//   Scene3d.blendOrderOf の順（遠い物から・同じ距離なら並びの前）に、1 つの物の中は三角形の並びのまま、不透明の深度より手前の画素だけに重ねる
//   （深度は書かない。半透明どうしは並びの順で重なる）。色 = src × α + dst × (1 − α)・α = α + dst の α × (1 − α)（src も dst も画面の値）
//   （dst の α が 1 なら GL の glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA) と同じ値。dst が透明でも
//   下地へ Normal で重ねた時に GL の画面への直の重ねと同じ色になるよう、色は α で割り戻して持つ）。α は材質の α（段つきで読んだ値）。
//   cutout も真なら α < materialCutoff() の画素は捨てる。半透明の三角形の縁の画素は、2 枚が分け合う縁を片方だけが持つ（左と上の縁）。
//   半透明の物は影を落とさず、Output.Depth には描かない。
// 両面（材質の doubleSided）: その物の裏の三角形も捨てない。裏の三角形（画面で反時計回り）は光の計算の法線（法線マップの前の n）を裏返す。
// 空（Scene3d.Scene3dCmd の sky が Some）: 何も描かれない画素を、画素の真ん中の NDC の向き（Scene3d.skyDirectionOf）の LightModel3d.skyModel の色（α 1）で塗る（background は使わない）。
//   Output.Depth では白（一番奥）。かすみは掛けない。
// ビルボード: 絵の α が billboardCutoff() 未満の画素は捨てる（深度も書かない）。lit が真なら法線をカメラへ向けて同じ光と fog を当てる。
// 光は Scene3d.pickLights（目に近い順に点光源 8・スポット 2）で選んだ物だけを使う。
// 間引き（GL の Render3d と同じ判定）: Scene3d.isOutsideFrustum が真の置いた物（場面のカメラの視錐台の外）と、
//   isBillboardOutsideFrustum が真のビルボードは三角形を作らない。影の地図は Scene3d.shadowFrustumOf の視錐台で同じく間引く。
//   外れる側に倒した判定（画素を 1 つも出さない物だけを間引く）なので、絵は間引かない時と同じ。
// ジョイント: Scene3d.skinningOf が Some の置いた物は、頂点を GL の Render3d と同じ式で曲げてから写す（式は placedOf の doc。影の地図も同じ形）。
//
// 影（GL の Render3d と同じ約束。本文は Scene3d.shadowMatrix の doc）:
//   影を落とすのは、pickLights の後の並びで shadow が Some の最初のスポット 1 本だけ（2 本目以降の shadow は無視）。
//   地図 = mapSize × mapSize。置いた物の三角形を表も裏も shadowMatrix で写して near で切り、画素ごとに一番近い z × 0.5 + 0.5。
//          何も無い画素は 1。ビルボードは影を落とさない。
//   地図の画素 = ((x × 0.5 + 0.5) × mapSize, (y × 0.5 + 0.5) × mapSize) の切り捨て（NDC の x・y）。行 0 が NDC の y = −1 側（GL のテクスチャと同じ向き）。
//   pcf の周りの画素が地図の外に出たら端の画素を読む（GL の CLAMP_TO_EDGE）。
//   光の w が 0 以下（光の後ろ）の点は、NDC の外と同じく影にしない。
//   影はスポットの光の量（att × facing × cone）に掛け、環境光・半球・点光源には掛けない。Output.Depth では地図を作らない。
// WhyNot: 半透明の混ぜを線形の量どうしで行わない — GL は描き先の画面の値の上でハードウェアで混ぜ、MSAA の平均も画面の値どうし。
//   線形で混ぜるには 3D を別の float の描き先へ描いて貼り直す形が要り、背景の無い場面の縁は 2D の上で結局画面の値で混ざる。
pub mod SoftRaster3d {
    import java.awt.image.BufferedImage
    import java.lang.System
    import java.util.function.IntConsumer
    import java.util.stream.IntStream

    /// ビルボードの絵の α がこれ未満の画素は捨てる。
    pub def billboardCutoff(): Float64 = 0.5

    /// cutout の材質で、α がこれ未満の画素は捨てる。
    pub def materialCutoff(): Float64 = 0.5

    // ════════════════════════════════════════════════════════
    // 光の式（pub の口は GL の担当と値を突き合わせるため）
    // ════════════════════════════════════════════════════════

    /// world の点 position・法線 normal（長さ 1）に当たる光の量（色ごと。toonSteps の丸めまで済ませた値）。
    // WhyNot: ここで影を見ない — 影の地図は場面の置いた物から作るので、光の並びだけでは作れない。影は drawScene の道でだけ付く。
    pub def lightAt(env: Scene3d.Environment3d, pointLights: List[Scene3d.PointLight], spotLights: List[Scene3d.SpotLight],
                    position: Vec3.Vec3, normal: Vec3.Vec3): Color =
        let (r, g, b) = evalLight(compileLights(env, pointLights, spotLights, None),
                                  position#x, position#y, position#z, normal#x, normal#y, normal#z);
        { r = r, g = g, b = b }

    /// 目 eye から見た world の点 position の色 c に、距離のかすみを掛けた色（fog が None なら c のまま）。
    pub def fogAt(env: Scene3d.Environment3d, eye: Vec3.Vec3, position: Vec3.Vec3, c: Color): Color =
        let (r, g, b) = applyFog(compileFog(env#fog), eye#x, eye#y, eye#z, position#x, position#y, position#z, c#r, c#g, c#b);
        { r = r, g = g, b = b }

    /// 3D の色を作る最後の組み立て（GL の r3d_surfaceOut と同じ式。gl-parity の式の行が値をそろえて確かめる）:
    /// 色 = albedoLinear × tint × light（fogOn なら env#fog のかすみ。かすみの色は線形の量へ戻す）+ 線形へ戻した emission × intensity を、
    /// 画面の値へ戻した色。tint と light は呼ぶ側が線形の量にして渡す（GL の uniform と同じ）。
    // WhyNot: 画素ごとの塗り（materialColor・shadePixel）からこの関数を呼ばない — 画素ごとの変換は表（Texture3d.colorLut）で行い、
    //   場面ごとの値は外で 1 回だけ組む。式の並びは同じで、TestSoftRaster3dLinear が材質の画素をこの関数の値と突き合わせる。
    pub def surfaceOutAt(env: Scene3d.Environment3d, eye: Vec3.Vec3, position: Vec3.Vec3,
                         albedoLinear: Color, tint: Color, light: Color, emission: Color, intensity: Float64, fogOn: Bool): Color =
        let (r, g, b) = (albedoLinear#r * tint#r * light#r, albedoLinear#g * tint#g * light#g, albedoLinear#b * tint#b * light#b);
        let (fr, fg, fb) = if (fogOn) applyFog(compileLinearFog(env#fog), eye#x, eye#y, eye#z, position#x, position#y, position#z, r, g, b) else (r, g, b);
        let toL = Texture3d.srgbToLinear;
        let toS = Texture3d.linearToSrgb;
        Color.rgb(toS(fr + toL(emission#r) * intensity), toS(fg + toL(emission#g) * intensity), toS(fb + toL(emission#b) * intensity))

    // WhyNot: 光をレコードの列のまま画素ごとに読まない — レコードの欄は名前で引くので、画素 × 光の数だけ重くなる。
    //   並べ方は LightModel3d.packPointLights・packSpotLights（生成した SoftRaster3dLight の輪が番号で読む）。
    enum Lights {
        // ambient r, g, b・hemisphere・toonSteps・点光源の並び・スポットの並び・影
        case Lights(Float64, Float64, Float64, Float64, Int32, Vector[Float64], Vector[Float64], SpotShadow)
    }

    /// 影を落とすスポット 1 本の地図と判定に要る値。スポットの並びの中の位置（spots の Vector の先頭からの欄の数）・
    /// shadowMatrix の 16 個（行優先）・mapSize・bias・pcfRadius・strength・地図（行 0 が NDC の y = −1 側）。
    enum Shadow { case Shadow(Int32, Vector[Float64], Int32, Float64, Int32, Float64, Vector[Float64]) }

    /// 場面の影（影を落とすスポットが無ければ None）。生成した SoftRaster3dLight がスポットごとに shadowFactorAt へ渡す。
    pub type alias SpotShadow = Option[Shadow]

    /// ambient と光の color を書いた値のまま並べる（pub の光の式の口のため）。
    def compileLights(env: Scene3d.Environment3d, pointLights: List[Scene3d.PointLight],
                      spotLights: List[Scene3d.SpotLight], shadow: SpotShadow): Lights =
        Lights.Lights(env#ambient#r, env#ambient#g, env#ambient#b, env#hemisphere, env#toonSteps,
                      LightModel3d.packPointLights(pointLights), LightModel3d.packSpotLights(spotLights), shadow)

    /// ambient と光の color を線形の量へ戻してから並べる（hemisphere・intensity・range は線形の量のまま）。
    def compileLinearLights(env: Scene3d.Environment3d, pointLights: List[Scene3d.PointLight],
                            spotLights: List[Scene3d.SpotLight], shadow: SpotShadow): Lights =
        compileLights({ ambient = Texture3d.srgbToLinearColor(env#ambient) | env },
                      pointLights |> List.map(l -> { color = Texture3d.srgbToLinearColor(l#color) | l }),
                      spotLights |> List.map(l -> { color = Texture3d.srgbToLinearColor(l#color) | l }), shadow)

    /// 不透明の画素の色 (r, g, b, 1)（3 成分を画面の値へ。toSrgbColor と同じ変換で、組を作り直さない）。
    def toSrgbOpaque(lut: Texture3d.ColorLut, r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64, Float64) =
        (Texture3d.linearToSrgbLut(lut, r), Texture3d.linearToSrgbLut(lut, g), Texture3d.linearToSrgbLut(lut, b), 1.0)

    /// 3D の色を作った直後の 1 回の変換（3 成分を画面の値へ）。
    def toSrgbColor(lut: Texture3d.ColorLut, c: (Float64, Float64, Float64)): (Float64, Float64, Float64) =
        let (r, g, b) = c;
        (Texture3d.linearToSrgbLut(lut, r), Texture3d.linearToSrgbLut(lut, g), Texture3d.linearToSrgbLut(lut, b))

    def evalLight(lights: Lights, px: Float64, py: Float64, pz: Float64,
                  nx: Float64, ny: Float64, nz: Float64): (Float64, Float64, Float64) =
        let Lights.Lights(ar, ag, ab, hemi, steps, points, spots, shadow) = lights;
        SoftRaster3dLight.lightAt(steps, points, spots, shadow, px, py, pz, nx, ny, nz, ar, ag, ab, hemi)

    /// lightmap つきの物に当たる光。sample = lightmap の絵から段つきで読んだ rgb。
    def evalLightBaked(lights: Lights, bake: Baked, sample: (Float64, Float64, Float64), px: Float64, py: Float64, pz: Float64,
                       nx: Float64, ny: Float64, nz: Float64): (Float64, Float64, Float64) =
        let Lights.Lights(_, _, _, _, steps, points, spots, shadow) = lights;
        let (sr, sg, sb) = sample;
        SoftRaster3dLight.lightmapLightAt(steps, points, spots, shadow, px, py, pz, nx, ny, nz, sr, sg, sb,
                                    if (bake#srgb) 1.0 else 0.0, bake#intensity)

    /// スポットの並びの位置 offset のスポットが、world の点 (px, py, pz) へ届ける光に掛ける割合（影を落とさないスポットは 1）。
    pub def shadowFactorAt(shadow: SpotShadow, offset: Int32, px: Float64, py: Float64, pz: Float64): Float64 = match shadow {
        case Some(Shadow.Shadow(at, m, n, bias, radius, strength, map)) if at == offset =>
            1.0 - strength * (1.0 - shadowLitFractionAt(m, n, bias, radius, map, px, py, pz))
        case _ => 1.0
    }

    /// world の点 (px, py, pz) が影の地図で照らされている割合（pcf の (2r+1)² 画素のうち照らされている数の割合。地図の外と光の後ろは 1）。
    /// m = shadowMatrix の 16 個（行優先・rowMajorOf）・地図 map は n × n（行 0 が NDC の y = −1 側）・r = pcfRadius。
    /// GL の shadowLitFraction（Render3dGlsl）と同じ数え方で、gl-parity の式の行が値をそろえて確かめる。
    // WhyNot: 地図と値をレコードにまとめて渡さない — 画素 × スポットの数だけレコードを作ることになる。
    pub def shadowLitFractionAt(m: Vector[Float64], n: Int32, bias: Float64, pcfRadius: Int32, map: Vector[Float64],
                                px: Float64, py: Float64, pz: Float64): Float64 =
        let row = k -> Vector.get(k * 4, m) * px + Vector.get(k * 4 + 1, m) * py + Vector.get(k * 4 + 2, m) * pz + Vector.get(k * 4 + 3, m);
        let w = row(3);
        let (sx, sy, sz) = if (w <= 0.0) (2.0, 2.0, 0.0) else (row(0) / w, row(1) / w, row(2) / w);
        if (sx < -1.0 or sx > 1.0 or sy < -1.0 or sy > 1.0) 1.0
        else {
            let r = Int32.max(0, pcfRadius);
            let side = 2 * r + 1;
            let lit = countLit(map, n, mapTexel(n, sx) - r, mapTexel(n, sy) - r, side, sz * 0.5 + 0.5 - bias, 0, 0);
            Int32.toFloat64(lit) / Int32.toFloat64(side * side)
        }

    /// スポットの並びの位置 offset のスポットが落とす影（引数は shadowLitFractionAt と同じ・strength = 影の濃さ）。
    pub def spotShadowOf(offset: Int32, m: Vector[Float64], n: Int32, bias: Float64, pcfRadius: Int32, strength: Float64,
                         map: Vector[Float64]): SpotShadow =
        Some(Shadow.Shadow(offset, m, n, bias, pcfRadius, strength, map))

    /// 行列 m の 16 個（行優先）。shadowLitFractionAt の rows の形。
    pub def rowMajorOf(m: Mat4.Mat4): Vector[Float64] =
        let c = Mat4.toColumns(m);
        Vector.range(0, 16) |> Vector.map(k -> { let row = k / 4; Vector.get((k - row * 4) * 4 + row, c) })

    /// NDC の x か y（−1..1）が落ちる地図の画素（0..n−1）。
    def mapTexel(n: Int32, ndc: Float64): Int32 =
        Int32.max(0, Int32.min(n - 1, floorInt((ndc * 0.5 + 0.5) * Int32.toFloat64(n))))

    /// 左下 (x0, y0) から side × side の地図の画素のうち、depth が地図の値以下の画素の数（地図の外は端の画素を読む）。
    def countLit(map: Vector[Float64], n: Int32, x0: Int32, y0: Int32, side: Int32, depth: Float64, k: Int32, acc: Int32): Int32 =
        if (k >= side * side) acc
        else {
            let x = Int32.max(0, Int32.min(n - 1, x0 + (k - (k / side) * side)));
            let y = Int32.max(0, Int32.min(n - 1, y0 + k / side));
            countLit(map, n, x0, y0, side, depth, k + 1, if (depth <= Vector.get(y * n + x, map)) acc + 1 else acc)
        }

    // fog があるか・色 r, g, b・near・far。
    enum Fog { case Fog(Bool, Float64, Float64, Float64, Float64, Float64) }

    /// かすみの色を書いた値のまま（pub の光の式の口のため）。
    def compileFog(fog: Option[Scene3d.DistanceFog]): Fog = match fog {
        case None    => Fog.Fog(false, 0.0, 0.0, 0.0, 0.0, 0.0)
        case Some(f) => Fog.Fog(true, f#color#r, f#color#g, f#color#b, f#near, f#far)
    }

    /// かすみの色を線形の量へ戻した Fog。
    def compileLinearFog(fog: Option[Scene3d.DistanceFog]): Fog =
        compileFog(fog |> Option.map(f -> { color = Texture3d.srgbToLinearColor(f#color) | f }))

    def applyFog(fog: Fog, ex: Float64, ey: Float64, ez: Float64, px: Float64, py: Float64, pz: Float64,
                 r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) =
        let Fog.Fog(on, fr, fg, fb, near, far) = fog;
        if (not on) (r, g, b)
        else SoftRaster3dLight.fogAt(px, py, pz, ex, ey, ez, r, g, b, fr, fg, fb, near, far)

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))

    // ════════════════════════════════════════════════════════
    // 場面 1 つを下地へ
    // ════════════════════════════════════════════════════════

    /// 場面 cmd を image へ重ねる。sf = design px → 出力の画素の倍率。textures = ビルボードと材質が引く絵（(名前, 段の平均の色空間) → 段の列。
    /// 段 0 が元の絵。鍵の色空間は Texture3d.mipSpaceOf）。
    /// time = 材質の Spec に渡す秒（Shader 面の time と同じ物）。
    /// Native は出力の画素で塗り、Design は design の画素で塗ってから最も近い画素で広げる。
    /// 何も描かれない画素は background が Some ならその色、None なら透明（下地が見える）。重ね方は Shader 面と同じ blendPixel。
    pub def drawScene(image: BufferedImage, sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
                      time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO = region rc {
        let scene = cmd#scene;
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, { position = cmd#at, size = scene#size });
        let dw = rx1 - rx0;
        let dh = ry1 - ry0;
        let (cx0, cy0, cx1, cy1) = match cmd#clip {
            case None    => (rx0, ry0, rx1, ry1)
            case Some(r) => DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, r)
        };
        let x0 = Int32.max(0, Int32.max(rx0, cx0));
        let y0 = Int32.max(0, Int32.max(ry0, cy0));
        let x1 = Int32.min(image.getWidth(), Int32.min(rx1, cx1));
        let y1 = Int32.min(image.getHeight(), Int32.min(ry1, cy1));
        let w = x1 - x0;
        let h = y1 - y0;
        if (dw <= 0 or dh <= 0 or w <= 0 or h <= 0 or scene#size#x <= 0.0 or scene#size#y <= 0.0) ()
        else {
            let (lw, lh) = match scene#resolution {
                case Scene3d.Resolution.Native => (dw, dh)
                case Scene3d.Resolution.Design =>
                    (Int32.max(1, roundInt(scene#size#x)), Int32.max(1, roundInt(scene#size#y)))
            };
            let layer: Array[Int32, Static] = Array.repeat(Static, lw * lh, 0);
            renderLayer(scene, lw, lh, textures, time, LayerOut.Argb(layer));
            let buf: Array[Int32, rc] = Array.empty(rc, w * h);
            discard image.getRGB(x0, y0, w, h, buf, 0, w);
            List.range(0, h) |> List.forEach(j -> {
                let ly = nearestIndex(y0 + j - ry0, dh, lh);
                List.range(0, w) |> List.forEach(i -> {
                    let lx = nearestIndex(x0 + i - rx0, dw, lw);
                    let k = j * w + i;
                    Array.put(SoftRaster.blendPixel(DrawCmd.BlendMode.Normal, Array.get(ly * lw + lx, layer), Array.get(k, buf)), k, buf)
                })
            });
            image.setRGB(x0, y0, w, h, buf, 0, w)
        }
    }

    /// drawScene の Rgba16Float の描き先版。rgba = 描き先（1 画素に r, g, b, α の 4 つ）・size = その幅と高さ。
    /// 層は色を切らずに塗り（emission が 1 を超えて残る）、SoftRaster.blendPixelF の Normal で重ねる。
    pub def drawSceneHdr(rgba: Array[Float64, Static], size: (Int32, Int32), sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
                         time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO =
        let (width, height) = size;
        let scene = cmd#scene;
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, { position = cmd#at, size = scene#size });
        let dw = rx1 - rx0;
        let dh = ry1 - ry0;
        let (cx0, cy0, cx1, cy1) = match cmd#clip {
            case None    => (rx0, ry0, rx1, ry1)
            case Some(r) => DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, r)
        };
        let x0 = Int32.max(0, Int32.max(rx0, cx0));
        let y0 = Int32.max(0, Int32.max(ry0, cy0));
        let x1 = Int32.min(width, Int32.min(rx1, cx1));
        let y1 = Int32.min(height, Int32.min(ry1, cy1));
        let w = x1 - x0;
        let h = y1 - y0;
        if (dw <= 0 or dh <= 0 or w <= 0 or h <= 0 or scene#size#x <= 0.0 or scene#size#y <= 0.0) ()
        else {
            let (lw, lh) = match scene#resolution {
                case Scene3d.Resolution.Native => (dw, dh)
                case Scene3d.Resolution.Design =>
                    (Int32.max(1, roundInt(scene#size#x)), Int32.max(1, roundInt(scene#size#y)))
            };
            let layer: Array[Float64, Static] = Array.repeat(Static, lw * lh * 4, 0.0);
            renderLayer(scene, lw, lh, textures, time, LayerOut.Rgba(layer));
            List.range(0, h) |> List.forEach(j -> {
                let ly = nearestIndex(y0 + j - ry0, dh, lh);
                List.range(0, w) |> List.forEach(i -> {
                    let k = (ly * lw + nearestIndex(x0 + i - rx0, dw, lw)) * 4;
                    SoftRaster.blendPixelF(DrawCmd.BlendMode.Normal, Array.get(k, layer), Array.get(k + 1, layer), Array.get(k + 2, layer),
                                           Array.get(k + 3, layer), rgba, (y0 + j) * width + x0 + i)
                })
            })
        }

    /// 層の画素の置き場。Argb = 8bit（argbOfRgba で 0..1 に切る）・Rgba = 1 画素に r, g, b, α の 4 つ（切らない）。
    enum LayerOut {
        case Argb(Array[Int32, Static])
        case Rgba(Array[Float64, Static])
    }

    /// 層の画素 i に (r, g, b, a) を書く。
    def putLayer(out: LayerOut, i: Int32, r: Float64, g: Float64, b: Float64, a: Float64): Unit \ IO =
        match out {
            case LayerOut.Argb(argb) => Array.put(SoftRaster.argbOfRgba(r, g, b, a), i, argb)
            case LayerOut.Rgba(rgba) =>
                Array.put(r, i * 4, rgba);
                Array.put(g, i * 4 + 1, rgba);
                Array.put(b, i * 4 + 2, rgba);
                Array.put(a, i * 4 + 3, rgba)
        }

    /// 出力の画素 o（0..outN−1）が拾う層の画素（0..srcN−1）。同じ数なら o のまま。
    def nearestIndex(o: Int32, outN: Int32, srcN: Int32): Int32 =
        if (outN == srcN) o
        else Int32.max(0, Int32.min(srcN - 1, floorInt((Int32.toFloat64(o) + 0.5) * Int32.toFloat64(srcN) / Int32.toFloat64(outN))))

    // ════════════════════════════════════════════════════════
    // 場面 1 つを lw × lh の ARGB へ
    // ════════════════════════════════════════════════════════

    // 1 頂点の欄の数。clip の段では (clip x, y, z, w, world x, y, z, 法線 x, y, z, 色 r, g, b, uv u, v, タンジェント x, y, z, w, 2 本目の uv u, v)、
    // 画面へ写した後は先頭 4 つが (画面 x, y, NDC の z, 1 / w) に替わる。
    // 材質の無い物の色の欄は 頂点の色 × tint（両方を線形の量へ戻してから）・材質のある物は頂点の色だけ（tint は Mat）・ビルボードは白で、uv の欄に絵の px。
    // 2 本目の uv の無い形とビルボードは 2 本目の uv が (0, 0)。
    def stride(): Int32 = 21

    def colorSlot(): Int32 = 10

    def uvSlot(): Int32 = 13

    def tangentSlot(): Int32 = 15

    def uv2Slot(): Int32 = 19

    /// 画面へ写した三角形 1 枚。頂点 3 つ（stride() 個ずつ）・符号つきの面積（画面の px²）・
    /// ビルボードの番号（メッシュは −1）・材質の番号（材質の無い物とビルボードは −1）。
    enum Tri { case Tri(Vector[Float64], Float64, Int32, Int32) }

    /// 置いた物 1 つの材質。組み直した Spec（Param は値に置き換え済み）・cutout・置いた物の tint r, g, b（線形の量）・法線マップ・emissionIntensity。
    enum Mat { case Mat(ShaderEval.CompiledSpec, Bool, Float64, Float64, Float64, Option[NormalMapping], Float64) }

    /// 当てる法線マップ。絵の段の列・strength・0..1 の外の uv を繰り返すか。
    type alias NormalMapping = { texture = Vector[ShaderEval.TexData], strength = Float64, repeat = Bool }

    /// 置いた物 1 つに貼る lightmap。絵の段の列・Srgb で読むか・intensity・読む段の数の上限。
    type alias Baked = { texture = Vector[ShaderEval.TexData], srgb = Bool, intensity = Float64, maxLevels = Int32 }

    /// 置いた物 f の lightmap（Scene3d.lightmapOfFields が Some の時だけ）。絵が無ければ透明な黒で読む（GL の代わりの絵と同じ）。
    def bakedOf(textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], f: Scene3d.InstanceFields): Option[Baked] =
        Scene3d.lightmapOfFields(f) |> Option.map(lm ->
            { texture = Map.getWithDefault((lm#texture, Texture3d.mipSpaceOf(Texture3d.TextureUse.Lightmap(lm#colorSpace))), blackTexture(), textures),
              srgb = lm#colorSpace == Texture3d.ColorSpace.Srgb, intensity = lm#intensity, maxLevels = lm#maxLevels })

    /// hasUv = 形が uv を持つか（uv の無い形には法線マップを当てない。GL と同じ）。法線マップの絵が無ければ透明な黒で読む（GL の代わりの絵と同じ）。
    /// materialTextures = 材質の Tex が名前で引く絵（textures の材質の絵の鍵の物）・textures = 法線マップを引く全部の絵。
    def matOf(textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], materialTextures: Map[String, Vector[ShaderEval.TexData]],
              tint: Color, hasUv: Bool, m: Scene3d.Material3d): Mat =
        let f = Scene3d.materialFieldsOf(m);
        let (spec, emission) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), f#spec, f#emission);
        let repeat = f#wrap == Scene3d.Wrap.Repeat;
        let compiled = ShaderEval.compileMaterial({ spec = spec, emission = emission, params = f#params, textures = materialTextures,
                                                    repeat = repeat });
        let normal = if (not hasUv) None else f#normalMap |> Option.map(n ->
            { texture = Map.getWithDefault((n#texture, Texture3d.mipSpaceOf(Texture3d.TextureUse.NormalMap)), blackTexture(), textures),
              strength = n#strength, repeat = repeat });
        let t = Texture3d.srgbToLinearColor(tint);
        Mat.Mat(compiled, f#cutout, t#r, t#g, t#b, normal, f#emissionIntensity)

    /// 無い絵の代わり（透明な黒 1 × 1。GL の代わりの絵と同じ）。
    def blackTexture(): Vector[ShaderEval.TexData] = Vector#{ { width = 1, height = 1, pixels = Vector#{0} } }

    /// textures のうち材質の絵の鍵（Texture3d.mipSpaceOf(MaterialTexture)）の物を、名前 → 段の列にした物（ShaderEval が名前で引く）。
    def materialTexturesOf(textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]]): Map[String, Vector[ShaderEval.TexData]] =
        let space = Texture3d.mipSpaceOf(Texture3d.TextureUse.MaterialTexture);
        textures |> Map.foldLeftWithKey((acc, key, levels) -> if (snd(key) == space) Map.insert(fst(key), levels, acc) else acc, Map.empty())

    /// 置いた物ごとの材質の番号（材質の無い物は −1）。番号は材質のある物だけを前から数える。
    def numberMaterials(placed: List[Placed]): List[(Placed, Int32)] =
        let (_, numbered) = placed |> List.foldLeft((acc, p) -> {
            let (next, out) = acc;
            if (Option.isEmpty(p#fields#material)) (next, (p, -1) :: out) else (next + 1, (p, next) :: out)
        }, (0, Nil));
        List.reverse(numbered)

    /// 置いた物 1 つの中身と、ジョイントで曲げた後の頂点の位置と法線（形の座標・頂点ごとに 3 つ。曲げない物は形のまま）と
    /// タンジェント（頂点ごとに 4 つ・w はそのまま。uv の無い形は None）。
    type alias Placed = { fields = Scene3d.InstanceFields, positions = Vector[Float64], normals = Vector[Float64],
                          tangents = Option[Vector[Float64]] }

    /// 置いた物 i を、Scene3d.skinningOf が Some なら曲げて Placed にする（GL の Render3d の頂点シェーダーと同じ式）:
    ///   位置 = Σ w_k × (jointMatrices[j_k] × p)・法線とタンジェントの xyz = Σ w_k × (jointMatrices[j_k] の左上 3×3 × n)
    /// world と normalMatrix(world) は instanceTris が後から掛ける。
    // WhyNot: instanceTris の中で曲げない — 影の地図と画面の 2 回通るので、置いた物ごとに 1 回で済むようここで曲げる。
    // WhyNot: 法線に skin の逆行列の転置を使わない — ジョイントの倍率が軸ごとに違うと少しずれるが、GL も左上 3×3 のままで、両方の絵がそろう方を取る。
    def placedOf(i: Scene3d.Instance3d): Placed =
        let f = Scene3d.instanceFieldsOf(i);
        let bent = forM (
            pose <- Scene3d.skinningOf(i);
            joints <- Mesh3d.skinJoints(f#mesh);
            weights <- Mesh3d.skinWeights(f#mesh)
        ) yield bendVertices(Pose3d.jointMatrices(pose), joints, weights, f#mesh);
        let (positions, normals, tangents) = Option.getWithDefault((Mesh3d.positions(f#mesh), Mesh3d.normals(f#mesh), Mesh3d.tangents(f#mesh)), bent);
        { fields = f, positions = positions, normals = normals, tangents = tangents }

    /// 形 mesh の頂点を、頂点ごとの 4 つのジョイント（joints の番号・weights の重み。頂点 k は [4k, 4k + 4)）で曲げた位置と法線とタンジェント。
    // WhyNot: 重み 0 の欄を飛ばす — 足しても値が変わらず、多くの頂点は 1〜2 本しか使わない。
    def bendVertices(matrices: Vector[Mat4.Mat4], joints: Vector[Int32], weights: Vector[Float64],
                     mesh: Mesh3d.Mesh3d): (Vector[Float64], Vector[Float64], Option[Vector[Float64]]) =
        let blendAt = (move: (Mat4.Mat4, Vec3.Vec3) -> Vec3.Vec3, v: Vec3.Vec3, k: Int32) ->
            List.range(k * 4, k * 4 + 4) |> List.foldLeft((acc, s) -> {
                let w = Vector.get(s, weights);
                if (w == 0.0) acc else Vec3.add(acc, Vec3.mul(move(Vector.get(Vector.get(s, joints), matrices), v), w))
            }, Vec3.zero());
        let ps = Mesh3d.positions(mesh);
        let ns = Mesh3d.normals(mesh);
        let bent = Vector.range(0, Mesh3d.vertexCount(mesh)) |> Vector.map(k ->
            (blendAt(Mat4.apply, vec3At(ps, k), k), blendAt(Mat4.applyDir, vec3At(ns, k), k)));
        let tangents = Mesh3d.tangents(mesh) |> Option.map(ts -> Vector.range(0, Mesh3d.vertexCount(mesh)) |> Vector.flatMap(k -> {
            let (xyz, w) = vec4At(ts, k);
            let moved = blendAt(Mat4.applyDir, xyz, k);
            Vector#{ moved#x, moved#y, moved#z, w }
        }));
        (Vector.flatMap(pair -> xyzOf(fst(pair)), bent), Vector.flatMap(pair -> xyzOf(snd(pair)), bent), tangents)

    /// 頂点ごとに 3 つ並んだ v の k 番目の頂点。
    def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 =
        Vec3.v3(Vector.get(k * 3, v), Vector.get(k * 3 + 1, v), Vector.get(k * 3 + 2, v))

    def xyzOf(v: Vec3.Vec3): Vector[Float64] = Vector#{ v#x, v#y, v#z }

    /// 頂点ごとに 4 つ並んだ v の k 番目の頂点（xyz と w）。
    def vec4At(v: Vector[Float64], k: Int32): (Vec3.Vec3, Float64) =
        (Vec3.v3(Vector.get(k * 4, v), Vector.get(k * 4 + 1, v), Vector.get(k * 4 + 2, v)), Vector.get(k * 4 + 3, v))

    /// ビルボード 1 枚の絵。画素・region の px 矩形（x0, y0, x1, y1。x1・y1 は含まない）・tint r, g, b・光を当てるか。
    enum Ink { case Ink(ShaderEval.TexData, Int32, Int32, Int32, Int32, Float64, Float64, Float64, Bool) }

    /// 場面を lw × lh（行優先）の out に塗る。
    def renderLayer(scene: Scene3d.Scene3dCmd, lw: Int32, lh: Int32,
                    textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], time: Float64, out: LayerOut): Unit \ IO = region rc {
        let cam = scene#camera;
        let picked = Scene3d.pickLights(cam#eye, scene);
        let view = Camera3d.viewMatrix(cam);
        let proj = Camera3d.projectionMatrix(cam, Scene3d.aspectOf(scene));
        let screen = { w = Int32.toFloat64(lw), h = Int32.toFloat64(lh), near = cam#near };
        let frustum = Scene3d.frustumOf(scene);
        let materialTextures = materialTexturesOf(textures);
        // WhyNot: 表を場面ごとに作り直すのを JVM で 1 つに控えない — Flix に top-level の値が無く、作るのは 8194 回の pow（場面 1 つに 1 回）で済む。
        let lut = hoist(rc, Texture3d.colorLut());
        let placed = scene#billboards |> List.filter(b -> not Scene3d.isBillboardOutsideFrustum(frustum, b)) |> List.filterMap(b -> {
            let f = Scene3d.billboardFieldsOf(b);
            Map.get(f#texture, materialTextures) |> Option.flatMap(Vector.head) |> Option.map(tex -> (f, tex))
        });
        let inks = placed |> List.map(pair -> inkOf(snd(pair), fst(pair))) |> List.toVector;
        let numbered = numberMaterials(scene#instances |> List.map(placedOf));
        let isDepth = match scene#output {
            case Scene3d.Output.Color    => false
            case Scene3d.Output.Depth(_) => true
        };
        // WhyNot: 半透明の物を 1 段目の勝者の選びに入れない — 勝者は画素に 1 つで、奥の物の色が残らない。
        let (blendedNumbered, solidNumbered) = List.partition(pair -> Scene3d.isBlendedFields(fst(pair)#fields), numbered);
        // WhyNot: 同じ Spec の材質を 1 つに束ねない — Spec に Eq が無く、束ねる鍵（JSON の字）を作る手間が組み直しと同じくらいかかる。
        let mats = hoist(rc, numbered |> List.filterMap(pair -> {
            let fields = fst(pair)#fields;
            fields#material |> Option.map(matOf(textures, materialTextures, fields#tint, Option.nonEmpty(Mesh3d.uvs(fields#mesh))))
        }) |> List.toVector);
        // WhyNot: lightmap を Mat に入れない — Mat は材質の中身で、lightmap は置いた物ごと（同じ材質を別の光の場所に置く）。
        let bakes = hoist(rc, numbered |> List.filterMap(pair -> {
            let fields = fst(pair)#fields;
            fields#material |> Option.map(_ -> bakedOf(textures, fields))
        }) |> List.toVector);
        // WhyNot: 間引いた物を numberMaterials の前に除かない — 材質の番号（mats の並び）を置いた物の並びのまま保つ。
        let meshTris = solidNumbered |> List.flatMap(pair ->
            if (Scene3d.isOutsideFrustumFields(frustum, fst(pair)#fields)) Nil
            else instanceTris(view, proj, screen, Some(lut), not isDoubleSided(fst(pair)), fst(pair), snd(pair)));
        let blendedTris = hoist(rc, if (isDepth) Vector.empty()
            else Scene3d.blendOrderOf(cam#eye, pair -> fst(pair)#fields, blendedNumbered)
                |> List.filter(pair -> not Scene3d.isOutsideFrustumFields(frustum, fst(pair)#fields))
                |> List.flatMap(pair -> instanceTris(view, proj, screen, Some(lut), not isDoubleSided(fst(pair)), fst(pair), snd(pair)))
                |> List.toVector);
        let blendedBins = hoist(rc, binRows(rc, lh, blendedTris));
        let billboardTris = List.zipWithIndex(placed) |> List.flatMap(entry -> {
            let (index, (f, _)) = entry;
            billboardTris(view, proj, screen, cam, index, f)
        });
        let tris = hoist(rc, List.append(meshTris, billboardTris) |> List.toVector);
        let bins = hoist(rc, binRows(rc, lh, tris));
        let shadow = match scene#output {
            case Scene3d.Output.Color    => shadowOf(solidNumbered |> List.map(fst), picked#spotLights)
            case Scene3d.Output.Depth(_) => None
        };
        let lights = hoist(rc, compileLinearLights(picked#environment, picked#pointLights, picked#spotLights, shadow));
        let fog = hoist(rc, compileLinearFog(scene#environment#fog));
        let inkTable = hoist(rc, inks);
        let eye = hoist(rc, (cam#eye#x, cam#eye#y, cam#eye#z));
        let background = hoist(rc, match scene#environment#background {
            case Some(c) => (c#r, c#g, c#b, 1.0)
            case None    => (0.0, 0.0, 0.0, 0.0)
        });
        let sky = hoist(rc, scene#sky |> Option.map(sk -> (linearSkyColorsOf(sk), Scene3d.skyBasisOf(scene))));
        let shadeEnv = hoist(rc, { time = time, lights = lights, fog = fog, eye = eye, lut = lut });
        let fillAt = (x: Int32, y: Int32) -> skyFill(sky, lut, isDepth, (lw, lh), (x, y)) |> Option.getWithDefault(background);
        let depthBand = hoist(rc, match scene#output {
            case Scene3d.Output.Color    => None
            case Scene3d.Output.Depth(d) => Some((d#near, d#range))
        });
        forEachRow(lh, y -> region rr {
            let depth: Array[Float64, rr] = Array.repeat(rr, lw, 2.0);
            let winner: Array[Int32, rr] = Array.repeat(rr, lw, -1);
            let w0: Array[Float64, rr] = Array.repeat(rr, lw, 0.0);
            let w1: Array[Float64, rr] = Array.repeat(rr, lw, 0.0);
            let py = Int32.toFloat64(y) + 0.5;
            Vector.get(y, bins) |> List.forEach(ti -> coverRow(lw, py, tris, inkTable, mats, time, ti, depth, winner, w0, w1));
            let blendedRow = Vector.get(y, blendedBins);
            let shadeAt = (x: Int32) -> {
                let ti = Array.get(x, winner);
                if (ti < 0) fillAt(x, y)
                else shadePixel(Vector.get(ti, tris), inkTable, mats, bakes, shadeEnv, lights, fog, eye, lut, depthBand, (x, y),
                                Array.get(x, w0), Array.get(x, w1))
            };
            if (List.isEmpty(blendedRow))
                List.range(0, lw) |> List.forEach(x -> {
                    let (r, g, b, a) = shadeAt(x);
                    putLayer(out, y * lw + x, r, g, b, a)
                })
            else {
                let rgba: Array[Float64, rr] = Array.repeat(rr, lw * 4, 0.0);
                List.range(0, lw) |> List.forEach(x -> {
                    let (r, g, b, a) = shadeAt(x);
                    Array.put(r, x * 4, rgba);
                    Array.put(g, x * 4 + 1, rgba);
                    Array.put(b, x * 4 + 2, rgba);
                    Array.put(a, x * 4 + 3, rgba)
                });
                let blended = { tris = blendedTris, mats = mats, bakes = bakes, env = shadeEnv };
                blendedRow |> List.forEach(ti -> blendRow(lw, y, blended, ti, depth, rgba));
                List.range(0, lw) |> List.forEach(x ->
                    putLayer(out, y * lw + x, Array.get(x * 4, rgba), Array.get(x * 4 + 1, rgba), Array.get(x * 4 + 2, rgba), Array.get(x * 4 + 3, rgba)))
            }
        })
    }

    /// 置いた物の材質が両面（doubleSided）か。
    def isDoubleSided(p: Placed): Bool =
        p#fields#material |> Option.exists(m -> Scene3d.materialFieldsOf(m)#doubleSided)

    /// 層の画素 (x, y) の空の色（sky が None なら None・Output.Depth なら白）。向きは画素の真ん中の NDC を通る向き（Scene3d.skyDirectionOf）。
    def skyFill(sky: Option[(SkyColors, Scene3d.SkyBasis)], lut: Texture3d.ColorLut, isDepth: Bool, layer: (Int32, Int32), pixel: (Int32, Int32)): Option[(Float64, Float64, Float64, Float64)] =
        let (lw, lh) = layer;
        let (x, y) = pixel;
        sky |> Option.map(sb -> {
            let (colors, basis) = sb;
            if (isDepth) (1.0, 1.0, 1.0, 1.0)
            else {
                let ndc = { x = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(lw) * 2.0 - 1.0,
                            y = 1.0 - (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(lh) * 2.0 };
                let (r, g, b) = toSrgbColor(lut, skyColorWith(colors, Scene3d.skyDirectionOf(basis, ndc)));
                (r, g, b, 1.0)
            }
        })

    /// 空の色の材料（zenith・horizon・ground の r, g, b・曲がり）。
    // WhyNot: 画素ごとに Sky3d のレコードから読まない — レコードの欄は名前で引くので、空の画素の数だけ重くなる。
    enum SkyColors { case SkyColors(Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64) }

    /// 3 色を線形の量へ戻して並べる（空は線形の量の中で混ぜる）。
    def linearSkyColorsOf(s: Scene3d.Sky3d): SkyColors = skyColorsWith(Texture3d.srgbToLinearColor, s)

    /// 3 色を convert に通して並べる。
    def skyColorsWith(convert: Color -> Color, s: Scene3d.Sky3d): SkyColors =
        let f = Scene3d.skyFieldsOf(s);
        let (zenith, horizon, ground) = (convert(f#zenith), convert(f#horizon), convert(f#ground));
        SkyColors.SkyColors(zenith#r, zenith#g, zenith#b, horizon#r, horizon#g, horizon#b,
                            ground#r, ground#g, ground#b, Scene3d.skyCurveOf(s))

    /// 目から見た向き dir（長さ 1）の空の色（LightModel3d.skyModel）。
    def skyColorWith(colors: SkyColors, dir: Vec3.Vec3): (Float64, Float64, Float64) =
        let SkyColors.SkyColors(zr, zg, zb, hr, hg, hb, gr, gg, gb, curve) = colors;
        SoftRaster3dLight.skyAt(dir#x, dir#y, dir#z, zr, zg, zb, hr, hg, hb, gr, gg, gb, curve)

    /// 半透明の物を塗る時に要る、場面ごとに 1 回だけ組んだ物（半透明の三角形・材質・lightmap・塗りの材料）。
    type alias BlendedShading = { tris = Vector[Tri], mats = Vector[Mat], bakes = Vector[Option[Baked]], env = ShadeEnv }

    /// 半透明の三角形 ti が行 y で覆い、1 段目の深度 depth より手前の画素に、その色を重ねる（rgba = その行の r, g, b, α。深度は書かない）。
    /// 2 枚の三角形が分け合う縁の上の画素は、左か上の縁を持つ方だけが塗る（同じ物の 2 枚で 2 回重ねない。GL のラスタライズの決まりと同じ考え）。
    def blendRow(lw: Int32, y: Int32, blended: BlendedShading, ti: Int32, depth: Array[Float64, r], rgba: Array[Float64, r]): Unit \ r =
        let tri = Vector.get(ti, blended#tris);
        let Tri.Tri(v, area, _, mat) = tri;
        let s = stride();
        let (x0, y0, z0, q0) = (Vector.get(0, v), Vector.get(1, v), Vector.get(2, v), Vector.get(3, v));
        let (x1, y1, z1, q1) = (Vector.get(s, v), Vector.get(s + 1, v), Vector.get(s + 2, v), Vector.get(s + 3, v));
        let (x2, y2, z2, q2) = (Vector.get(s * 2, v), Vector.get(s * 2 + 1, v), Vector.get(s * 2 + 2, v), Vector.get(s * 2 + 3, v));
        let clockwise = area > 0.0;
        let own0 = ownsEdge(clockwise, x1, y1, x2, y2);
        let own1 = ownsEdge(clockwise, x2, y2, x0, y0);
        let own2 = ownsEdge(clockwise, x0, y0, x1, y1);
        let inside = (l: Float64, owns: Bool) -> l > 0.0 or (l == 0.0 and owns);
        let py = Int32.toFloat64(y) + 0.5;
        let lo = Int32.max(0, ceilInt(Float64.min(x0, Float64.min(x1, x2)) - 0.5));
        let hi = Int32.min(lw - 1, floorInt(Float64.max(x0, Float64.max(x1, x2)) - 0.5));
        let material = Vector.get(mat, blended#mats);
        def loop(x: Int32): Unit \ r =
            if (x > hi) ()
            else {
                let px = Int32.toFloat64(x) + 0.5;
                let l0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) / area;
                let l1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) / area;
                let l2 = 1.0 - l0 - l1;
                let z = l0 * z0 + l1 * z1 + l2 * z2;
                let covered = inside(l0, own0) and inside(l1, own1) and inside(l2, own2) and z >= -1.0 and z <= 1.0 and z < Array.get(x, depth);
                if (covered and not isCutAway(material, blended#env#time, v, perspectiveWeights(l0, l1, l2, q0, q1, q2))) {
                    let (lr, lg, lb, sa) = materialPixel(tri, material, Vector.get(mat, blended#bakes), blended#env, (x, y), l0, l1);
                    let (sr, sg, sb) = toSrgbColor(blended#env#lut, (lr, lg, lb));
                    let a = clamp01(sa);
                    let k = x * 4;
                    let (dr, dg, db, da) = (Array.get(k, rgba), Array.get(k + 1, rgba), Array.get(k + 2, rgba), Array.get(k + 3, rgba));
                    let outA = a + da * (1.0 - a);
                    let back = da * (1.0 - a);
                    let mixed = (src: Float64, dst: Float64) -> if (outA <= 0.0) 0.0 else (src * a + dst * back) / outA;
                    Array.put(mixed(sr, dr), k, rgba);
                    Array.put(mixed(sg, dg), k + 1, rgba);
                    Array.put(mixed(sb, db), k + 2, rgba);
                    Array.put(outA, k + 3, rgba)
                } else ();
                loop(x + 1)
            };
        loop(lo)

    /// 三角形の縁 a → b の上にちょうど乗った画素の真ん中を、この三角形が持つか（左の縁と上の縁を持つ）。
    /// clockwise = 三角形が画面（y は下へ）で時計回りか。反時計回りの三角形は縁の向きを逆にして同じ決まりで見る。
    def ownsEdge(clockwise: Bool, ax: Float64, ay: Float64, bx: Float64, by: Float64): Bool =
        let (dx, dy) = if (clockwise) (bx - ax, by - ay) else (ax - bx, ay - by);
        dy < 0.0 or (dy == 0.0 and dx > 0.0)

    /// 画素ループの外で 1 回だけ計算した値を、そのまま返す。
    // WhyNot: `let x = 式` で直に置かない — Flix 0.78 の最適化は、純粋な let の値がラムダの中で 1 回だけ使われると
    // 式をラムダの中へ書き写すので、三角形の組み立てが行ごとに走る（SoftRaster.onceOutsideLoop と同じ罠）。
    def hoist(rc: Region[r], x: a): a \ r = Ref.get(Ref.fresh(rc, x))

    /// 行 0..n−1 を rowFn で塗る。行どうしは互いの画素を読まないので、Java の並列ストリームでコアの数だけ並べる
    /// （SoftRaster.shadeAll と同じく FGE_SOFT_SERIAL=1 なら 1 本で回す）。
    def forEachRow(n: Int32, rowFn: Int32 -> Unit \ IO): Unit \ IO =
        let serial = System.getenv("FGE_SOFT_SERIAL");
        let range = IntStream.range(0, n);
        let stream = if (not Object.isNull(serial) and serial == "1") range else range.parallel();
        stream.forEach(new IntConsumer {
            def accept(_this: IntConsumer, i: Int32): Unit \ IO = rowFn(i)
        })

    // ── 影の地図 ─────────────────────────────────────────

    /// spots（pickLights の後の並び）のうち shadow が Some の最初の 1 本の地図。mapSize が 0 以下なら影を落とさない。
    def shadowOf(instances: List[Placed], spots: List[Scene3d.SpotLight]): SpotShadow \ IO =
        let caster = List.zipWithIndex(spots) |> List.findMap(entry -> {
            let (index, spot) = entry;
            spot#shadow |> Option.filter(sm -> sm#mapSize > 0) |> Option.map(sm -> (index, spot, sm))
        });
        match caster {
            case None => None
            case Some((index, spot, sm)) =>
                let rows = rowMajorOf(Scene3d.shadowMatrix(spot));
                let size = Int32.min(sm#mapSize, Scene3d.maxShadowMapSize());
                let pcf = Int32.min(sm#pcfRadius, Scene3d.maxShadowPcfRadius());
                spotShadowOf(index * LightModel3d.spotStride(), rows, size, sm#bias, pcf, sm#strength, buildShadowMap(instances, spot, size))
        }

    /// 光から見た n × n の地図（一番近い面の NDC の z × 0.5 + 0.5。何も無い画素は 1。行 0 が NDC の y = −1 側）。
    // WhyNot: 裏の面を捨てない — 薄い板や片面だけの物は、光へ裏を向けていても影を落としてほしい。
    // WhyNot: cutout の材質の α を見ない — 材質を画素ごとに評価すると地図が場面の塗りと同じくらい重くなる。抜いた穴の影は今は埋まる。
    def buildShadowMap(instances: List[Placed], spot: Scene3d.SpotLight, n: Int32): Vector[Float64] \ IO = region rc {
        let cam = Scene3d.shadowCamera(spot);
        let view = Camera3d.viewMatrix(cam);
        let proj = Camera3d.projectionMatrix(cam, 1.0);
        let screen = { w = Int32.toFloat64(n), h = Int32.toFloat64(n), near = cam#near };
        let frustum = Scene3d.shadowFrustumOf(spot);
        let tris = hoist(rc, instances |> List.filter(f -> not Scene3d.isOutsideFrustumFields(frustum, f#fields))
            |> List.flatMap(f -> instanceTris(view, proj, screen, None, false, f, -1)) |> List.toVector);
        let bins = hoist(rc, binRows(rc, n, tris));
        let noInks: Vector[Ink] = Vector.empty();
        let noMats: Vector[Mat] = Vector.empty();
        let out: Array[Float64, Static] = Array.repeat(Static, n * n, 1.0);
        forEachRow(n, y -> region rr {
            let depth: Array[Float64, rr] = Array.repeat(rr, n, 2.0);
            let winner: Array[Int32, rr] = Array.repeat(rr, n, -1);
            let w0: Array[Float64, rr] = Array.repeat(rr, n, 0.0);
            let w1: Array[Float64, rr] = Array.repeat(rr, n, 0.0);
            let py = Int32.toFloat64(y) + 0.5;
            Vector.get(y, bins) |> List.forEach(ti -> coverRow(n, py, tris, noInks, noMats, 0.0, ti, depth, winner, w0, w1));
            // WhyNot: 画面の行の順（上が行 0）のまま置かない — GL の深度テクスチャは行 0 が NDC の y = −1 側で、向きをそろえる。
            List.range(0, n) |> List.forEach(x -> {
                let z = Array.get(x, depth);
                if (z <= 1.0) Array.put(z * 0.5 + 0.5, (n - 1 - y) * n + x, out) else ()
            })
        });
        Array.toVector(out)
    }

    def inkOf(tex: ShaderEval.TexData, f: Scene3d.BillboardFields): Ink =
        let r = f#regionRect;
        let x0 = Int32.max(0, Int32.min(tex#width - 1, floorInt(r#position#x)));
        let y0 = Int32.max(0, Int32.min(tex#height - 1, floorInt(r#position#y)));
        let x1 = Int32.max(x0 + 1, Int32.min(tex#width, floorInt(r#position#x + r#size#x)));
        let y1 = Int32.max(y0 + 1, Int32.min(tex#height, floorInt(r#position#y + r#size#y)));
        let tint = Texture3d.srgbToLinearColor(f#tint);
        Ink.Ink(tex, x0, y0, x1, y1, tint#r, tint#g, tint#b, f#lit)

    // ── 三角形を組む ─────────────────────────────────────

    type alias Screen = { w = Float64, h = Float64, near = Float64 }

    /// clip の段の頂点（stride() 個）。w は目の座標の −z（Mat4.perspective の 4 行目が (0, 0, −1, 0)）。
    /// rest = 色 3・uv 2・タンジェント 4・2 本目の uv 2 の欄。
    // WhyNot: proj × view の 1 本の行列で w を出さない — Mat4 は閉じた型で 4 行目を読めず、apply は w を返さない。
    def clipVertex(view: Mat4.Mat4, proj: Mat4.Mat4, p: Vec3.Vec3, n: Vec3.Vec3, rest: Vector[Float64]): Vector[Float64] =
        let e = Mat4.apply(view, p);
        let c = Mat4.apply(proj, e);
        Vector.append(Vector#{ c#x, c#y, c#z, 0.0 - e#z, p#x, p#y, p#z, n#x, n#y, n#z }, rest)

    /// 置いた物 placed の三角形（頂点は placedOf で曲げた後の物）。mat = 材質の番号（−1 なら頂点の色 × tint を色の欄に、それ以外は頂点の色だけを入れる）。
    /// lut が Some なら、材質の無い物の頂点の色と tint を線形の量へ戻してから掛ける（材質のある物の頂点の色は戻さない — Spec の出口で戻す）。
    /// None は色を読まない影の地図の道。
    /// タンジェントの xyz は world の左上 3×3 で写し（法線の normalMatrix ではない）、world が裏返す行列なら w の符号も裏返す。
    /// cull が真なら裏の三角形を捨てる。
    def instanceTris(view: Mat4.Mat4, proj: Mat4.Mat4, screen: Screen, lut: Option[Texture3d.ColorLut], cull: Bool, placed: Placed, mat: Int32): List[Tri] =
        let f = placed#fields;
        let world = f#world;
        let nm = Mat4.normalMatrix(world);
        let flip = if (linearDeterminant(world) < 0.0) -1.0 else 1.0;
        let cs = match (mat < 0, lut) {
            case (true, Some(table)) => Mesh3d.colors(f#mesh) |> Vector.map(c -> Texture3d.srgbToLinearLut(table, c))
            case _                   => Mesh3d.colors(f#mesh)
        };
        let uvs = Mesh3d.uvs(f#mesh);
        let uvs2 = Mesh3d.uvs2(f#mesh);
        let tint = if (mat < 0 and Option.nonEmpty(lut)) Texture3d.srgbToLinearColor(f#tint)
                   else if (mat < 0) f#tint
                   else { r = 1.0, g = 1.0, b = 1.0 };
        let surfaceAt = (k: Int32) -> {
            let (u, v) = match uvs {
                case Some(uv) => (Vector.get(k * 2, uv), Vector.get(k * 2 + 1, uv))
                case None     => (0.0, 0.0)
            };
            let (t, w) = match placed#tangents {
                case Some(ts) => let (xyz, tw) = vec4At(ts, k); (Vec3.normalized(Mat4.applyDir(world, xyz)), tw * flip)
                case None     => (Vec3.zero(), 0.0)
            };
            let (u2, v2) = match uvs2 {
                case Some(uv) => (Vector.get(k * 2, uv), Vector.get(k * 2 + 1, uv))
                case None     => (0.0, 0.0)
            };
            Vector#{ Vector.get(k * 3, cs) * tint#r, Vector.get(k * 3 + 1, cs) * tint#g, Vector.get(k * 3 + 2, cs) * tint#b,
                     u, v, t#x, t#y, t#z, w, u2, v2 }
        };
        let vertices = List.range(0, Mesh3d.vertexCount(f#mesh)) |> List.map(k ->
            clipVertex(view, proj, Mat4.apply(world, vec3At(placed#positions, k)), Vec3.normalized(Mat4.applyDir(nm, vec3At(placed#normals, k))),
                       surfaceAt(k)))
            |> List.toVector;
        let idx = Mesh3d.indices(f#mesh);
        List.range(0, Vector.length(idx) / 3) |> List.flatMap(t ->
            screenTris(screen, cull, -1, mat,
                       Vector.get(Vector.get(t * 3, idx), vertices) ::
                       Vector.get(Vector.get(t * 3 + 1, idx), vertices) ::
                       Vector.get(Vector.get(t * 3 + 2, idx), vertices) :: Nil))

    /// m の左上 3×3 の行列式（負なら鏡写しにする行列）。
    def linearDeterminant(m: Mat4.Mat4): Float64 =
        let c = Mat4.toColumns(m);
        let col = (j: Int32) -> Vec3.v3(Vector.get(j * 4, c), Vector.get(j * 4 + 1, c), Vector.get(j * 4 + 2, c));
        Vec3.dot(col(0), Vec3.cross(col(1), col(2)))

    /// ビルボード 1 枚の三角形 2 枚。四角はカメラの right / up に沿って立て、anchor の点を position に合わせる。
    /// uv の欄には絵の px（region の中）を入れる。
    // WhyNot: 裏を捨てない — 四角はいつもカメラへ向くので、裏になるのは size が負の時だけで、それは左右・上下の反転として描く。
    def billboardTris(view: Mat4.Mat4, proj: Mat4.Mat4, screen: Screen, cam: Camera3d.Camera3d,
                      index: Int32, f: Scene3d.BillboardFields): List[Tri] =
        let right = Camera3d.right(cam);
        let up = Camera3d.up(cam);
        let facing = Vec3.mul(Camera3d.forward(cam), -1.0);
        let r = f#regionRect;
        let corner = (u: Float64, v: Float64) -> {
            let p = Vec3.add(f#position, Vec3.add(Vec3.mul(right, (u - f#anchor#x) * f#size#x),
                                                  Vec3.mul(up, (f#anchor#y - v) * f#size#y)));
            clipVertex(view, proj, p, facing, Vector#{ 1.0, 1.0, 1.0, r#position#x + u * r#size#x, r#position#y + v * r#size#y, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 })
        };
        let tl = corner(0.0, 0.0);
        let tr = corner(1.0, 0.0);
        let br = corner(1.0, 1.0);
        let bl = corner(0.0, 1.0);
        List.append(screenTris(screen, false, index, -1, tl :: tr :: br :: Nil),
                    screenTris(screen, false, index, -1, tl :: br :: bl :: Nil))

    /// clip の段の三角形を near で切り、扇に割って画面へ写す。cull が真なら画面で反時計回り（裏）の物を捨てる。
    def screenTris(screen: Screen, cull: Bool, ink: Int32, mat: Int32, tri: List[Vector[Float64]]): List[Tri] =
        match List.map(projectVertex(screen), clipNear(screen#near, tri)) {
            case v0 :: rest =>
                List.zip(rest, List.drop(1, rest)) |> List.filterMap(pair -> {
                    let (v1, v2) = pair;
                    let area = signedArea(v0, v1, v2);
                    if (Float64.abs(area) < 1.0e-12 or (cull and area < 0.0)) None
                    else Some(Tri.Tri(Vector.append(v0, Vector.append(v1, v2)), area, ink, mat))
                })
            case Nil => Nil
        }

    /// 画面（y は下へ）で頂点が時計回りなら正。
    def signedArea(a: Vector[Float64], b: Vector[Float64], c: Vector[Float64]): Float64 =
        let ax = Vector.get(0, a);
        let ay = Vector.get(1, a);
        (Vector.get(0, b) - ax) * (Vector.get(1, c) - ay) - (Vector.get(0, c) - ax) * (Vector.get(1, b) - ay)

    /// 多角形を w ≥ near の側だけ残して切る（Sutherland–Hodgman。欄は全部 clip 空間でまっすぐつなぐ）。
    def clipNear(near: Float64, poly: List[Vector[Float64]]): List[Vector[Float64]] =
        let inside = (v: Vector[Float64]) -> Vector.get(3, v) >= near;
        let next = List.append(List.drop(1, poly), List.take(1, poly));
        List.zip(poly, next) |> List.flatMap(edge -> {
            let (a, b) = edge;
            let cut = _ -> {
                let wa = Vector.get(3, a);
                let wb = Vector.get(3, b);
                let t = (near - wa) / (wb - wa);
                Vector.zipWith((x, y) -> x + (y - x) * t, a, b)
            };
            match (inside(a), inside(b)) {
                case (true, true)   => b :: Nil
                case (true, false)  => cut(()) :: Nil
                case (false, true)  => cut(()) :: b :: Nil
                case (false, false) => Nil
            }
        })

    /// clip の段の頂点を画面の段へ（先頭 4 つを 画面 x, y・NDC の z・1 / w に替える）。
    def projectVertex(screen: Screen, v: Vector[Float64]): Vector[Float64] =
        let invW = 1.0 / Vector.get(3, v);
        let sx = (Vector.get(0, v) * invW + 1.0) / 2.0 * screen#w;
        let sy = (1.0 - Vector.get(1, v) * invW) / 2.0 * screen#h;
        let sz = Vector.get(2, v) * invW;
        Vector.mapWithIndex((i, x) -> if (i == 0) sx else if (i == 1) sy else if (i == 2) sz else if (i == 3) invW else x, v)

    /// 行ごとに、その行の画素の中心を通る三角形の番号（番号の小さい順）。
    def binRows(rc: Region[r], lh: Int32, tris: Vector[Tri]): Vector[List[Int32]] \ r =
        let bins: Array[List[Int32], r] = Array.repeat(rc, lh, Nil);
        // 後ろの三角形から先頭へ積むので、各行の並びは番号の小さい順になる（同じ深さなら先に渡した物が勝つ）。
        List.range(0, Vector.length(tris)) |> List.reverse |> List.forEach(ti -> {
            let Tri.Tri(v, _, _, _) = Vector.get(ti, tris);
            let s = stride();
            let ys = Vector.get(1, v) :: Vector.get(1 + s, v) :: Vector.get(1 + s * 2, v) :: Nil;
            let lo = Int32.max(0, ceilInt(List.foldLeft(Float64.min, 1.0e18, ys) - 0.5));
            let hi = Int32.min(lh - 1, floorInt(List.foldLeft(Float64.max, -1.0e18, ys) - 0.5));
            List.range(lo, hi + 1) |> List.forEach(y -> Array.put(ti :: Array.get(y, bins), y, bins))
        });
        Array.toVector(bins)

    // ── 塗る ─────────────────────────────────────────────

    /// 三角形 ti が行 py（画素の中心の y）で覆う画素の奥行きを比べ、手前なら番号と重み（画面の段の λ0・λ1）を残す。
    /// ビルボードの α の抜きと cutout の材質の α の抜きは、深度を書く前に行う（抜いた画素の奥の物が見える）。
    def coverRow(lw: Int32, py: Float64, tris: Vector[Tri], inks: Vector[Ink], mats: Vector[Mat], time: Float64, ti: Int32,
                 depth: Array[Float64, r], winner: Array[Int32, r],
                 w0: Array[Float64, r], w1: Array[Float64, r]): Unit \ r =
        let Tri.Tri(v, area, ink, mat) = Vector.get(ti, tris);
        let s = stride();
        let (x0, y0, z0, q0) = (Vector.get(0, v), Vector.get(1, v), Vector.get(2, v), Vector.get(3, v));
        let (x1, y1, z1, q1) = (Vector.get(s, v), Vector.get(s + 1, v), Vector.get(s + 2, v), Vector.get(s + 3, v));
        let (x2, y2, z2, q2) = (Vector.get(s * 2, v), Vector.get(s * 2 + 1, v), Vector.get(s * 2 + 2, v), Vector.get(s * 2 + 3, v));
        let lo = Int32.max(0, ceilInt(Float64.min(x0, Float64.min(x1, x2)) - 0.5));
        let hi = Int32.min(lw - 1, floorInt(Float64.max(x0, Float64.max(x1, x2)) - 0.5));
        def loop(x: Int32): Unit \ r =
            if (x > hi) ()
            else {
                let px = Int32.toFloat64(x) + 0.5;
                let l0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) / area;
                let l1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) / area;
                let l2 = 1.0 - l0 - l1;
                let z = l0 * z0 + l1 * z1 + l2 * z2;
                let covered = l0 >= 0.0 and l1 >= 0.0 and l2 >= 0.0 and z >= -1.0 and z <= 1.0 and z < Array.get(x, depth);
                let keep = covered and (ink < 0 or {
                    let (u, uv) = perspectiveUv(v, l0, l1, l2, q0, q1, q2);
                    alphaOf(sampleInk(Vector.get(ink, inks), u, uv)) >= billboardCutoff()
                }) and (mat < 0 or not isCutAway(Vector.get(mat, mats), time, v, perspectiveWeights(l0, l1, l2, q0, q1, q2)));
                if (keep) {
                    Array.put(z, x, depth);
                    Array.put(ti, x, winner);
                    Array.put(l0, x, w0);
                    Array.put(l1, x, w1)
                } else ();
                loop(x + 1)
            };
        loop(lo)

    /// 画面の段の重み λ を、奥行きで補正した重み b へ（b_i = λ_i / w_i ÷ Σ λ_j / w_j）。和の逆数（目からの奥行き）も返す。
    def perspectiveWeights(l0: Float64, l1: Float64, l2: Float64, q0: Float64, q1: Float64, q2: Float64): (Float64, Float64, Float64, Float64) =
        let a = l0 * q0;
        let b = l1 * q1;
        let c = l2 * q2;
        let sum = a + b + c;
        if (sum <= 0.0) (l0, l1, l2, 0.0) else (a / sum, b / sum, c / sum, 1.0 / sum)

    /// 頂点の欄 k を奥行きで補正して補間する。
    def attr(v: Vector[Float64], k: Int32, b0: Float64, b1: Float64, b2: Float64): Float64 =
        let s = stride();
        b0 * Vector.get(k, v) + b1 * Vector.get(s + k, v) + b2 * Vector.get(s * 2 + k, v)

    /// 奥行きで補正した重み（perspectiveWeights の値）での world の点。
    def worldAt(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): Vec3.Vec3 =
        let (b0, b1, b2, _) = weights;
        Vec3.v3(attr(v, 4, b0, b1, b2), attr(v, 5, b0, b1, b2), attr(v, 6, b0, b1, b2))

    /// 奥行きで補正した重みでの法線（長さ 1 にそろえる）。
    def normalAt(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): Vec3.Vec3 =
        let (b0, b1, b2, _) = weights;
        Vec3.normalized(Vec3.v3(attr(v, 7, b0, b1, b2), attr(v, 8, b0, b1, b2), attr(v, 9, b0, b1, b2)))

    /// 奥行きで補正した重みでの、材質が読む画素の入力（world の点・法線・uv・頂点の色）。
    def surfaceAt(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): ShaderEval.SurfacePoint =
        let (b0, b1, b2, _) = weights;
        let (c, uv) = (colorSlot(), uvSlot());
        { world = worldAt(v, weights), normal = normalAt(v, weights),
          uv = { x = attr(v, uv, b0, b1, b2), y = attr(v, uv + 1, b0, b1, b2) },
          color = { r = attr(v, c, b0, b1, b2), g = attr(v, c + 1, b0, b1, b2), b = attr(v, c + 2, b0, b1, b2) } }

    /// 奥行きで補正した重みでのタンジェント（xyz は長さをそろえない・w は ±1 の補間）。
    def tangentAt(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): (Vec3.Vec3, Float64) =
        let (b0, b1, b2, _) = weights;
        let t = tangentSlot();
        (Vec3.v3(attr(v, t, b0, b1, b2), attr(v, t + 1, b0, b1, b2), attr(v, t + 2, b0, b1, b2)), attr(v, t + 3, b0, b1, b2))

    def normalMappingOf(m: Mat): Option[NormalMapping] =
        let Mat.Mat(_, _, _, _, _, normal, _) = m;
        normal

    /// 奥行きで補正した重み（perspectiveWeights の値）の、横隣と縦隣の画素の組。
    type alias NeighborWeights = ((Float64, Float64, Float64, Float64), (Float64, Float64, Float64, Float64))

    /// 三角形 tri の、画面の重み (l0, l1) の画素 pixel と 2 × 2 の区画を組む横隣と縦隣の画素の、奥行きで補正した重み
    /// （偶数の列・行は右・下、奇数は左・上）。重みは画面の上で線形なので、隣が三角形の外でも同じ式を外へ延ばす（GL の区画の helper の画素と同じ）。
    // WhyNot: いつも右隣と下隣を取らない — GL の dFdx / dFdy は 2 × 2 の区画の中の差なので、奇数の列では左隣との差になる。
    //   右隣で取ると奇数の列の lod が半画素ずれ、段の境目の画素が GL とそろわない（区画は層の左上を原点に取る）。
    // WhyNot: 段つきの絵を読む材質かを見てから隣を求める形にしない — 法線マップも隣の uv を読むので分岐が 2 つに割れる。ここは重みの
    //   足し算で済み、重い評価（隣の bindings からの評価）は ShaderEval.evalMaterial3Mip が段つきの材質だけで行う。
    def neighborWeights(tri: Tri, pixel: (Int32, Int32), l0: Float64, l1: Float64): NeighborWeights =
        let Tri.Tri(v, area, _, _) = tri;
        let (px, py) = pixel;
        let stepOf = (k: Int32) -> if (Int32.remainder(k, 2) == 0) 1.0 else -1.0;
        let (sx, sy) = (stepOf(px), stepOf(py));
        let s = stride();
        let (x0, y0, q0) = (Vector.get(0, v), Vector.get(1, v), Vector.get(3, v));
        let (x1, y1, q1) = (Vector.get(s, v), Vector.get(s + 1, v), Vector.get(s + 3, v));
        let (x2, y2, q2) = (Vector.get(s * 2, v), Vector.get(s * 2 + 1, v), Vector.get(s * 2 + 3, v));
        let at = (a: Float64, b: Float64) -> perspectiveWeights(a, b, 1.0 - a - b, q0, q1, q2);
        (at(l0 - sx * (y2 - y1) / area, l1 - sx * (y0 - y2) / area), at(l0 + sy * (x2 - x1) / area, l1 + sy * (x0 - x2) / area))

    /// 頂点の欄 v の、横隣と縦隣の画素（neighborWeights の重み）の材質が読む入力。
    def neighborPoints(v: Vector[Float64], neighbors: NeighborWeights): (ShaderEval.SurfacePoint, ShaderEval.SurfacePoint) =
        let (nextX, nextY) = neighbors;
        (surfaceAt(v, nextX), surfaceAt(v, nextY))

    /// 奥行きで補正した重みでの 2 本目の uv。
    def uv2At(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): (Float64, Float64) =
        let (b0, b1, b2, _) = weights;
        (attr(v, uv2Slot(), b0, b1, b2), attr(v, uv2Slot() + 1, b0, b1, b2))

    /// lightmap bake の、頂点の欄 v の画素（奥行きで補正した重み weights・横隣と縦隣の重み neighbors）で段つきで読んだ rgb。
    def lightmapSampleAt(bake: Baked, v: Vector[Float64], weights: (Float64, Float64, Float64, Float64), neighbors: NeighborWeights): (Float64, Float64, Float64) =
        let (u, uvV) = uv2At(v, weights);
        let (nextX, nextY) = neighbors;
        let (xu, xv) = uv2At(v, nextX);
        let (yu, yv) = uv2At(v, nextY);
        let levels = Int32.min(Vector.length(bake#texture), bake#maxLevels);
        let lod = match Vector.head(bake#texture) {
            case Some(base) => Mip.lodOf({ dudx = xu - u, dvdx = xv - uvV, dudy = yu - u, dvdy = yv - uvV }, base#width, base#height, levels)
            case None       => 0.0
        };
        ShaderEval.sampleMipRgb(bake#texture, { linear = true, repeat = false }, lod, u, uvV)

    /// 材質のある物の画素の光（lightmap が無ければ evalLight・あれば evalLightBaked）。n = 光の計算に使う法線。
    def materialLight(bake: Option[Baked], lights: Lights, v: Vector[Float64], weights: (Float64, Float64, Float64, Float64),
                      neighbors: NeighborWeights, p: (Float64, Float64, Float64), n: Vec3.Vec3): (Float64, Float64, Float64) =
        let (px, py, pz) = p;
        match bake {
            case None    => evalLight(lights, px, py, pz, n#x, n#y, n#z)
            case Some(b) => evalLightBaked(lights, b, lightmapSampleAt(b, v, weights, neighbors), px, py, pz, n#x, n#y, n#z)
        }

    /// 光の計算に使う法線（法線マップが無ければ point の法線のまま。式はファイルの頭）。法線マップは段つきの Linear で読む
    /// （lod は uv の右隣と下隣との差から Mip.lodOf）。
    def mappedNormal(normal: Option[NormalMapping], point: ShaderEval.SurfacePoint, neighbors: (ShaderEval.SurfacePoint, ShaderEval.SurfacePoint),
                     tangent: (Vec3.Vec3, Float64)): Vec3.Vec3 =
        let n = point#normal;
        match normal {
            case None => n
            case Some(nm) =>
                let (raw, w) = tangent;
                let (nextX, nextY) = neighbors;
                let (u, uvV) = (point#uv#x, point#uv#y);
                let lod = match Vector.head(nm#texture) {
                    case Some(base) =>
                        Mip.lodOf({ dudx = nextX#uv#x - u, dvdx = nextX#uv#y - uvV, dudy = nextY#uv#x - u, dvdy = nextY#uv#y - uvV },
                                  base#width, base#height, Vector.length(nm#texture))
                    case None => 0.0
                };
                applyNormalMap(n, raw, w, nm#strength, ShaderEval.sampleMipRgb(nm#texture, { linear = true, repeat = nm#repeat }, lod, u, uvV))
        }

    /// 外向きの法線 n（長さ 1）を、タンジェント raw（長さはそろえない）・w（±1）と法線マップの rgb c で傾けた法線（式はファイルの頭）。
    /// GL の applyNormalMap（Render3dGlsl）と同じ式で、gl-parity の式の行が値をそろえて確かめる。
    // WhyNot: 長さ 0 のタンジェントで傾けない — 長さ 1 にそろえられず、画素の法線が 0 になる。GL も同じ画素は n のまま。
    pub def applyNormalMap(n: Vec3.Vec3, raw: Vec3.Vec3, w: Float64, strength: Float64, c: (Float64, Float64, Float64)): Vec3.Vec3 =
        let ortho = Vec3.sub(raw, Vec3.mul(n, Vec3.dot(n, raw)));
        if (Vec3.dot(ortho, ortho) < 1.0e-12) n
        else {
            let t = Vec3.normalized(ortho);
            let b = Vec3.mul(Vec3.cross(n, t), w);
            let (cr, cg, cb) = c;
            let (mx, my, mz) = ((cr * 2.0 - 1.0) * strength, (cg * 2.0 - 1.0) * strength, cb * 2.0 - 1.0);
            let p = Vec3.add(Vec3.add(Vec3.mul(t, mx), Vec3.mul(b, my)), Vec3.mul(n, mz));
            if (Vec3.dot(p, p) < 1.0e-12) n else Vec3.normalized(p)
        }

    /// cutout の材質 m で、この画素の α が materialCutoff() 未満か（cutout でない材質は捨てない）。
    def isCutAway(m: Mat, time: Float64, v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): Bool =
        let Mat.Mat(compiled, cutout, _, _, _, _, _) = m;
        cutout and ShaderEval.evalMaterial3(compiled, surfaceAt(v, weights), time)#alpha < materialCutoff()

    def perspectiveUv(v: Vector[Float64], l0: Float64, l1: Float64, l2: Float64,
                      q0: Float64, q1: Float64, q2: Float64): (Float64, Float64) =
        let (b0, b1, b2, _) = perspectiveWeights(l0, l1, l2, q0, q1, q2);
        (attr(v, uvSlot(), b0, b1, b2), attr(v, uvSlot() + 1, b0, b1, b2))

    def sampleInk(ink: Ink, u: Float64, v: Float64): Int32 =
        let Ink.Ink(tex, x0, y0, x1, y1, _, _, _, _) = ink;
        let ix = Int32.max(x0, Int32.min(x1 - 1, floorInt(u)));
        let iy = Int32.max(y0, Int32.min(y1 - 1, floorInt(v)));
        Vector.get(iy * tex#width + ix, tex#pixels)

    def alphaOf(argb: Int32): Float64 = Int32.toFloat64(SoftRaster.channelOf(24, argb)) / 255.0

    def channel01(shift: Int32, argb: Int32): Float64 = Int32.toFloat64(SoftRaster.channelOf(shift, argb)) / 255.0

    /// 勝った三角形の画素の色（r, g, b, α = 1。画面の値・0..1 に切らない — 切るのは書く所）。
    /// env = 材質の画素が読む場面の値（lights・fog・eye・lut はその中身と同じ物）。
    // WhyNot: lights・fog・eye・lut を env から読まない — レコードの欄は名前で引くので、画素ごとに 4 回引くと CPU の 3D が 1 割遅くなる。
    def shadePixel(tri: Tri, inks: Vector[Ink], mats: Vector[Mat], bakes: Vector[Option[Baked]], env: ShadeEnv,
                   lights: Lights, fog: Fog, eye: (Float64, Float64, Float64), lut: Texture3d.ColorLut,
                   depthBand: Option[(Float64, Float64)], pixel: (Int32, Int32),
                   l0: Float64, l1: Float64): (Float64, Float64, Float64, Float64) =
        let Tri.Tri(v, _, ink, mat) = tri;
        let s = stride();
        let weights = perspectiveWeights(l0, l1, 1.0 - l0 - l1, Vector.get(3, v), Vector.get(s + 3, v), Vector.get(s * 2 + 3, v));
        let (b0, b1, b2, _) = weights;
        let (px, py, pz) = (attr(v, 4, b0, b1, b2), attr(v, 5, b0, b1, b2), attr(v, 6, b0, b1, b2));
        let (ex, ey, ez) = eye;
        match depthBand {
            case Some((near, range)) =>
                let (dx, dy, dz) = (px - ex, py - ey, pz - ez);
                let gray = clamp01((Num.sqrt(dx * dx + dy * dy + dz * dz) - near) / Float64.max(range, 1.0e-6));
                (gray, gray, gray, 1.0)
            case None =>
                let point = surfaceAt(v, weights);
                let litWith = (n: Vec3.Vec3, base: (Float64, Float64, Float64)) -> {
                    let (br, bg, bb) = base;
                    let (lr, lg, lb) = evalLight(lights, px, py, pz, n#x, n#y, n#z);
                    applyFog(fog, ex, ey, ez, px, py, pz, br * lr, bg * lg, bb * lb)
                };
                let litFogged = (base: (Float64, Float64, Float64)) -> litWith(point#normal, base);
                if (ink >= 0) { let (r, g, b) = inkColor(lut, Vector.get(ink, inks), point#uv#x, point#uv#y, litFogged); toSrgbOpaque(lut, r, g, b) }
                else if (mat < 0) { let (r, g, b) = litFogged((point#color#r, point#color#g, point#color#b)); toSrgbOpaque(lut, r, g, b) }
                else { let (r, g, b, _) = materialPixel(tri, Vector.get(mat, mats), Vector.get(mat, bakes), env, pixel, l0, l1); toSrgbOpaque(lut, r, g, b) }
        }

    /// 画素の色を塗る時に場面ごとに決まっている物。lut = 頂点ごと・画素ごとの色の変換の表。
    type alias ShadeEnv = { time = Float64, lights = Lights, fog = Fog, eye = (Float64, Float64, Float64), lut = Texture3d.ColorLut }

    /// 材質 material の三角形 tri の画面の重み (l0, l1) の画素の色（線形の量のまま — 呼び手が画面の値へ戻す）と α（α は材質の α。不透明の物を塗る呼び手は捨てる）。
    /// 裏の三角形（画面で反時計回り。両面の材質の物だけが残る）は、光の計算の法線を裏返す（spec の Normal は裏返さない）。
    def materialPixel(tri: Tri, material: Mat, bake: Option[Baked], env: ShadeEnv, pixel: (Int32, Int32),
                      l0: Float64, l1: Float64): (Float64, Float64, Float64, Float64) =
        let Tri.Tri(v, area, _, _) = tri;
        let s = stride();
        let weights = perspectiveWeights(l0, l1, 1.0 - l0 - l1, Vector.get(3, v), Vector.get(s + 3, v), Vector.get(s * 2 + 3, v));
        let point = surfaceAt(v, weights);
        let (px, py, pz) = (point#world#x, point#world#y, point#world#z);
        let (ex, ey, ez) = env#eye;
        let nextWeights = neighborWeights(tri, pixel, l0, l1);
        let neighbors = neighborPoints(v, nextWeights);
        let facingPoint = if (area < 0.0) { normal = Vec3.mul(point#normal, -1.0) | point } else point;
        let lightNormal = mappedNormal(normalMappingOf(material), facingPoint, neighbors, tangentAt(v, weights));
        let (lr, lg, lb) = materialLight(bake, env#lights, v, weights, nextWeights, (px, py, pz), lightNormal);
        materialColor(material, env#lut, env#time, point, neighbors, base -> {
            let (br, bg, bb) = base;
            applyFog(env#fog, ex, ey, ez, px, py, pz, br * lr, bg * lg, bb * lb)
        })

    /// ビルボードの絵の (u, v) の色（線形の量へ戻す）に tint を掛け、lit なら光とかすみを当てる。
    def inkColor(lut: Texture3d.ColorLut, ink: Ink, u: Float64, v: Float64,
                 litFogged: ((Float64, Float64, Float64)) -> (Float64, Float64, Float64)): (Float64, Float64, Float64) =
        let Ink.Ink(_, _, _, _, _, tr, tg, tb, isLit) = ink;
        let texel = sampleInk(ink, u, v);
        let toLinear = Texture3d.srgbToLinearLut(lut);
        let base = (toLinear(channel01(16, texel)) * tr, toLinear(channel01(8, texel)) * tg, toLinear(channel01(0, texel)) * tb);
        if (isLit) litFogged(base) else base

    /// 材質の色と α: albedo × tint に光とかすみを当ててから emission × emissionIntensity を足す（GL の Render3d と同じ順）。α は材質の α のまま。
    /// Spec の出口の albedo.rgb と emission を線形の量へ戻してから計算する（色は線形の量のまま返す）。
    // WhyNot: emission にかすみを掛けない — 自分で光る物（溶岩・目）は遠くでもかすみに沈まずに見えてほしい。
    def materialColor(m: Mat, lut: Texture3d.ColorLut, time: Float64, point: ShaderEval.SurfacePoint, neighbors: (ShaderEval.SurfacePoint, ShaderEval.SurfacePoint),
                      litFogged: ((Float64, Float64, Float64)) -> (Float64, Float64, Float64)): (Float64, Float64, Float64, Float64) =
        let Mat.Mat(compiled, _, tr, tg, tb, _, intensity) = m;
        let (nextX, nextY) = neighbors;
        let sample = ShaderEval.evalMaterial3Mip(compiled, point, nextX, nextY, time);
        let a = sample#albedo;
        let e = sample#emission;
        // WhyNot: emission の無い材質（0 の色）を変換に通さない — 0 は変換しても 0 で、材質の画素ごとに 3 回の表引きが無駄になる。
        let glows = not (e#r == 0.0 and e#g == 0.0 and e#b == 0.0);
        let (r, g, b) = litFogged((Texture3d.srgbToLinearLut(lut, a#r) * tr, Texture3d.srgbToLinearLut(lut, a#g) * tg, Texture3d.srgbToLinearLut(lut, a#b) * tb));
        if (glows) (r + Texture3d.srgbToLinearLut(lut, e#r) * intensity, g + Texture3d.srgbToLinearLut(lut, e#g) * intensity,
                    b + Texture3d.srgbToLinearLut(lut, e#b) * intensity, sample#alpha)
        else (r, g, b, sample#alpha)

    // ── 数の小物 ─────────────────────────────────────────

    def clampForInt(x: Float64): Float64 = Float64.max(-1.0e9, Float64.min(1.0e9, x))

    def floorInt(x: Float64): Int32 = Float64.tryToInt32(Float64.floor(clampForInt(x))) |> Option.getWithDefault(0)

    def ceilInt(x: Float64): Int32 = Float64.tryToInt32(Float64.ceil(clampForInt(x))) |> Option.getWithDefault(0)

    def roundInt(x: Float64): Int32 = floorInt(x + 0.5)
}
