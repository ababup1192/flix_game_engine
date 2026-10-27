// TestShader — 宣言シェーダー機構のデータ層テスト（GL 不要・headless で回る）。
// 3 本柱: (1) Spec 木の値を assert、(2) compile が吐く GLSL 文字列を決定論スナップショットで pin、
// (3) CPU 評価器 evalPixel/evalField の代表点を pin。絵でなく「宣言データとその変換」を釘打ちする。
//
// スナップショットの粒度（後で崩すとスナップ総入れ替えになるので前提として固定）:
//   - prelude（hash2/worley/fbm の固定テンプレ）は長さだけ pin し本文は Spec スナップから除外する
//     （prelude 改訂は 1 テストだけ動く）。
//   - Spec 本体は compileBody（prelude 抜きの main 式）を pin する。
//   - 個々のノードの GLSL 片も compileBody で個別に pin（1 ノード変更→その pin だけ動く）。

// ════════════════════════════════════════════════════════════════════
// (1) Spec 木の値を assert（組んだ木が期待通りか）
// ════════════════════════════════════════════════════════════════════

/// demoSurface は 2 色 Ramp を Uv U で補間する Fill。
@Test
def testDemoSpecShape(): Unit \ Assert =
    let spec = ShaderDoc.demoSurface();
    let axis = match spec#out {
        case ShaderDoc.Out.Fill(f) => match f#shade {
            case ShaderDoc.Shade.Ramp(r) => match r#field {
                case ShaderDoc.Field.Uv(u) => Some(u#axis)
                case _ => None
            }
            case _ => None
        }
    };
    Assert.assertEq(expected = (Some(ShaderDoc.Axis.U), 0.5), (axis, spec#cycleRate))

/// waterVeins は Worley F2mF1 を Warp+Scaled でくるみ Smoothstep で目地に絞る。
/// 木の芯（Smoothstep → Warp → Scaled → Worley(F2mF1)）を辿って型で確認する。
@Test
def testWaterVeinsSpecShape(): Unit \ Assert =
    let spec = ShaderDoc.waterVeins();
    let worleyOut = match spec#out {
        case ShaderDoc.Out.Fill(f) => match f#shade {
            case ShaderDoc.Shade.Ramp(r) => match r#field {
                case ShaderDoc.Field.Smoothstep(s) => match s#of {
                    case ShaderDoc.Field.Warp(wp) => match wp#of {
                        case ShaderDoc.Field.Scaled(sc) => match sc#of {
                            case ShaderDoc.Field.Worley(w) => Some(w#out)
                            case _ => None
                        }
                        case _ => None
                    }
                    case _ => None
                }
                case _ => None
            }
            case _ => None
        }
    };
    Assert.assertEq(expected = Some(ShaderDoc.WorleyOut.F2mF1), worleyOut)

// ════════════════════════════════════════════════════════════════════
// (2) GLSL 文字列スナップショット（決定論・codegen 変更を検出）
// ════════════════════════════════════════════════════════════════════

/// Spec 本体を組む小道具（prelude 抜きの main 式を作るためのラッパ）。
def bodyOfField(field: ShaderDoc.Field): String =
    ShaderGen.compileBody({ name = "t", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
                                   alpha = field }) })

/// prelude は長さだけ pin（本文は別扱い）。長さが変わったら prelude を触った合図。
@Test
def testPreludeLength(): Unit \ Assert =
    Assert.assertEq(expected = 4592, String.length(ShaderGen.preludeSource()))

/// prelude の中身も pin する。長さだけでは、断片を入れ替えても総文字数が同じなら緑のまま通り、
/// GLSL の宣言順が狂って面が代替の絵に落ちても誰も気づけない。
/// 組み立て方（+ の連鎖か 1 回組みか）を変えるときは、この値が動かないことが唯一の証拠になる。
@Test
def testPreludeContent(): Unit \ Assert =
    Assert.assertEq(expected = 914099489, Hash.hash(ShaderGen.preludeSource()))

/// demoSurface の main 式（prelude 抜き）。Ramp の三角波位相・Uv 展開まで含めて決定論で pin。
@Test
def testDemoBodySnapshot(): Unit \ Assert =
    let expected =
        "outColor = vec4(mix(vec3(0.15, 0.35, 0.55), " +
        "vec3(0.55, 0.85, 0.95), " +
        "clamp(abs(fract(((vUv).x) + 0.5 * uTime) * 2.0 - 1.0), 0.0, 1.0)), 1.0);";
    Assert.assertEq(expected = expected, ShaderGen.compileBody(ShaderDoc.demoSurface()))

/// Worley(F2mF1) ノード単体の GLSL 片（prelude の sg_worleyF1F2 を呼ぶ形）。
@Test
def testWorleyNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Worley({ scale = 6.0, seed = 42, out = ShaderDoc.WorleyOut.F2mF1 });
    let expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "(sg_worleyF1F2((vUv) * 6.0, 42.0).y - sg_worleyF1F2((vUv) * 6.0, 42.0).x));";
    Assert.assertEq(expected = expected, bodyOfField(field))

/// Fbm ノード単体の GLSL 片。
@Test
def testFbmNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Fbm({ octaves = 2, scale = 3.0, seed = 5 });
    Assert.assertEq(expected = "outColor = vec4(vec3(0.0, 0.0, 0.0), sg_fbm((vUv) * 3.0, 2, 5.0));",
                    bodyOfField(field))

/// Smoothstep ノード（inner を包んで 0..1 に絞る）。
@Test
def testSmoothstepNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Smoothstep({ lo = 0.0, hi = 0.06, of = ShaderDoc.Field.Const(0.03) });
    Assert.assertEq(expected = "outColor = vec4(vec3(0.0, 0.0, 0.0), smoothstep(0.0, 0.06, 0.03));",
                    bodyOfField(field))

/// Mix ノード（定数比 t で 2 場を混ぜる）。
@Test
def testMixNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Mix({ a = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }),
                                      b = ShaderDoc.Field.Const(1.0), t = 0.5 });
    Assert.assertEq(expected = "outColor = vec4(vec3(0.0, 0.0, 0.0), mix((vUv).x, 1.0, 0.5));",
                    bodyOfField(field))

/// Disk ノード（丸マスク・radius→radius+feather で soft fade）。
@Test
def testDiskNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.42, feather = 0.1 });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "(1.0 - smoothstep(0.42, 0.52, length((vUv) - vec2(0.5, 0.5)))));",
        bodyOfField(field))

// ════════════════════════════════════════════════════════════════════
// (3) CPU 評価器 evalPixel / evalField の代表点（数式の正気）
// ════════════════════════════════════════════════════════════════════

/// Uv U は u 座標をそのまま返す。
@Test
def testEvalUvU(): Unit \ Assert =
    Assert.assertEq(expected = 0.25,
        ShaderEval.evalField(ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }), { x = 0.25, y = 0.5 }, 0.0))

/// Smoothstep の中点（(lo+hi)/2 の入力）は 0.5。
@Test
def testEvalSmoothstepMidpoint(): Unit \ Assert =
    let field = ShaderDoc.Field.Smoothstep({ lo = 0.0, hi = 0.06, of = ShaderDoc.Field.Const(0.03) });
    Assert.assertEq(expected = 0.5, ShaderEval.evalField(field, { x = 0.0, y = 0.0 }, 0.0))

/// Mix(a=0.4, b=1.0, t=0.5) = 0.7。
@Test
def testEvalMix(): Unit \ Assert =
    let field = ShaderDoc.Field.Mix({ a = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }),
                                      b = ShaderDoc.Field.Const(1.0), t = 0.5 });
    Assert.assertEq(expected = 0.7, ShaderEval.evalField(field, { x = 0.4, y = 0.0 }, 0.0))

/// Scaled の scroll は時間で読む座標を動かす（t=0 で 0.2 が t=1 で 0.3 に流れる）。
/// = 「スクロールで模様が動く」ことの数式的な証拠。
@Test
def testEvalScaledScrollsWithTime(): Unit \ Assert =
    let field = ShaderDoc.Field.Scaled({ factor = 1.0, scroll = { x = 0.1, y = 0.0 },
                                         of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) });
    let at0 = ShaderEval.evalField(field, { x = 0.2, y = 0.0 }, 0.0);
    let at1 = ShaderEval.evalField(field, { x = 0.2, y = 0.0 }, 1.0);
    Assert.assertEq(expected = (0.2, true), (at0, at1 > at0))

/// Ramp の位相は cycleRate*t で回る（demoSurface の色が時間で変わる）。
/// 同じ uv でも t=0 と t=1 で色が違う = パレット循環の証拠。
@Test
def testEvalRampCyclesWithTime(): Unit \ Assert =
    let spec = ShaderDoc.demoSurface();
    // t=0: 位相=triWave(0.25)=0.5 / t=0.5: 位相=triWave(0.25+0.5*0.5)=triWave(0.5)=0.0（別の色）。
    let c0 = ShaderEval.evalPixel(spec, { x = 0.25, y = 0.5 }, 0.0);
    let c1 = ShaderEval.evalPixel(spec, { x = 0.25, y = 0.5 }, 0.5);
    Assert.assertEq(expected = true, c0#r != c1#r)

/// Worley F2mF1 は非負（境界＝目地で大きく・セル内で小さい）。代表点で正の値。
@Test
def testEvalWorleyNonNegative(): Unit \ Assert =
    let field = ShaderDoc.Field.Worley({ scale = 6.0, seed = 42, out = ShaderDoc.WorleyOut.F2mF1 });
    let v = ShaderEval.evalField(field, { x = 0.5, y = 0.5 }, 0.0);
    Assert.assertEq(expected = true, v >= 0.0 and v < 2.0)

/// Angle: 中心の真右（角度 0）は 0.5 を返す（atan2(0, +)/2π + 0.5 = 0.5）。
@Test
def testEvalAngleRightIsHalf(): Unit \ Assert =
    let field = ShaderDoc.Field.Angle({ cx = 0.5, cy = 0.5 });
    Assert.assertEq(expected = 0.5, ShaderEval.evalField(field, { x = 1.0, y = 0.5 }, 0.0))

/// Rotate: turns=0・rate=0 は恒等（座標を回さない）→ Uv.U はそのまま。
@Test
def testEvalRotateIdentity(): Unit \ Assert =
    let field = ShaderDoc.Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.0, rate = 0.0,
                                         of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) });
    Assert.assertEq(expected = 0.3, ShaderEval.evalField(field, { x = 0.3, y = 0.5 }, 0.0))

/// Rotate: 半周回すと (0.7,0.5) は中心対称の (0.3,0.5) を読む → Uv.U ≈ 0.3。
@Test
def testEvalRotateHalfTurnMirrors(): Unit \ Assert =
    let field = ShaderDoc.Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.5, rate = 0.0,
                                         of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) });
    let v = ShaderEval.evalField(field, { x = 0.7, y = 0.5 }, 0.0);
    Assert.assertEq(expected = true, v > 0.29 and v < 0.31)

/// Cosine: b=0 なら cos 項が消えて col=a（a.r=0.5 → 画素 r=0.5）。
@Test
def testEvalCosineBaseColorIsA(): Unit \ Assert =
    let shade = ShaderDoc.Shade.Cosine({
        a = { r = 0.5, g = 0.2, b = 0.8 },
        b = { r = 0.0, g = 0.0, b = 0.0 },
        c = { r = 1.0, g = 1.0, b = 1.0 },
        d = { r = 0.0, g = 0.0, b = 0.0 },
        field = ShaderDoc.Field.Const(0.3) });
    let spec = { name = "t", cycleRate = 0.0, bindings = Nil,
                 out = ShaderDoc.Out.Fill({ shade = shade, alpha = ShaderDoc.Field.Const(1.0) }) };
    Assert.assertEq(expected = 0.5, ShaderEval.evalPixel(spec, { x = 0.0, y = 0.0 }, 0.0)#r)

/// waterVeins は Ramp 2 色の範囲内の色を返す（lo..hi の間・網目の濃淡）。
@Test
def testEvalWaterVeinsInRange(): Unit \ Assert =
    let c = ShaderEval.evalPixel(ShaderDoc.waterVeins(), { x = 0.3, y = 0.3 }, 0.0);
    // 端の色そのものになる点があり、色は Float32 に落として混ぜるので、両端に丸め 1 つぶんの余裕を持たせる。
    let eps = 0.000001;
    let inRange = c#r >= 0.35 - eps and c#r <= 0.80 + eps and c#g >= 0.55 - eps and c#g <= 0.95 + eps;
    Assert.assertEq(expected = true, inRange)

/// Disk: 中心=1・radius+feather の外=0・feather 中間=0.5。
@Test
def testEvalDisk(): Unit \ Assert =
    let d = ShaderDoc.Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.42, feather = 0.1 });
    let center = ShaderEval.evalField(d, { x = 0.5, y = 0.5 }, 0.0);            // dist 0 → 1
    let outside = ShaderEval.evalField(d, { x = 1.1, y = 0.5 }, 0.0);          // dist 0.6 > 0.52 → 0
    let mid = ShaderEval.evalField(d, { x = 0.97, y = 0.5 }, 0.0);            // dist 0.47 = radius+feather/2 → 0.5
    // mid は smoothstep 中点だが浮動小数で 0.5 の近傍。中心=1・外=0・中間≈0.5 を確かめる。
    Assert.assertEq(expected = (true, true, true),
        (center == 1.0, outside == 0.0, Float64.abs(mid - 0.5) < 0.0001))

// ════════════════════════════════════════════════════════════════════
// (4) JSON 往復（検証ループ②・toJson→parse で木が保たれる・fail-open）
// ════════════════════════════════════════════════════════════════════

/// parse(toJson(waterVeins())) の木が保たれる（Smoothstep→Warp→Scaled→Worley(F2mF1) を辿る）。
@Test
def testJsonRoundTripShape(): Unit \ Assert =
    let worleyOut = match ShaderJson.parse(ShaderJson.toJson(ShaderDoc.waterVeins())) {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#shade {
                case ShaderDoc.Shade.Ramp(r) => match r#field {
                    case ShaderDoc.Field.Smoothstep(s) => match s#of {
                        case ShaderDoc.Field.Warp(wp) => match wp#of {
                            case ShaderDoc.Field.Scaled(sc) => match sc#of {
                                case ShaderDoc.Field.Worley(w) => Some(w#out)
                                case _ => None
                            }
                            case _ => None
                        }
                        case _ => None
                    }
                    case _ => None
                }
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some(ShaderDoc.WorleyOut.F2mF1), worleyOut)

/// 往復後の代表値（cycleRate=0.25 / Scaled factor=5.0 / scroll.x=0.11）を釘打ち。
@Test
def testJsonRoundTripValues(): Unit \ Assert =
    let got = match ShaderJson.parse(ShaderJson.toJson(ShaderDoc.waterVeins())) {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#shade {
                case ShaderDoc.Shade.Ramp(r) => match r#field {
                    case ShaderDoc.Field.Smoothstep(s) => match s#of {
                        case ShaderDoc.Field.Warp(wp) => match wp#of {
                            case ShaderDoc.Field.Scaled(sc) => Some((spec#cycleRate, sc#factor, sc#scroll#x))
                            case _ => None
                        }
                        case _ => None
                    }
                    case _ => None
                }
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some((0.25, 5.0, 0.11)), got)

/// 往復後の Spec を compile すると元と同じ GLSL（JSON 経由でも既存スナップショットが不変な担保）。
@Test
def testJsonRoundTripGlslIdentical(): Unit \ Assert =
    let spec = ShaderDoc.waterVeins();
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(s2) => ShaderGen.compile(s2) == ShaderGen.compile(spec)
        case Err(_) => false
    };
    Assert.assertEq(expected = true, same)

/// fail-open: 未知 kind の壊れ json は Err で返る（load 側が getWithDefault でフォールバックする前提）。
@Test
def testJsonParseErrorOnUnknownKind(): Unit \ Assert =
    let r = match Util.Json.parse("{\"name\":\"x\",\"out\":{\"kind\":\"bogus\"}}") {
        case Ok(j)  => Result.isErr(ShaderJson.parse(j))
        case Err(_) => false
    };
    Assert.assertEq(expected = true, r)

/// fail-open: 色や必須キー欠落も Err（"of" 欠落の smoothstep）。
@Test
def testJsonParseErrorOnMissingKey(): Unit \ Assert =
    let broken = "{\"name\":\"x\",\"out\":{\"kind\":\"fill\"," +
                 "\"shade\":{\"kind\":\"solid\",\"color\":\"#112233\"}," +
                 "\"alpha\":{\"kind\":\"smoothstep\",\"lo\":0.0,\"hi\":1.0}}}";
    let r = match Util.Json.parse(broken) {
        case Ok(j)  => Result.isErr(ShaderJson.parse(j))
        case Err(_) => false
    };
    Assert.assertEq(expected = true, r)

/// 色は "#rrggbb" でも {r,g,b} でも読める（hex 経路の往復）。
@Test
def testJsonHexColor(): Unit \ Assert =
    let json = "{\"name\":\"c\",\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#ff8000\"}," +
               "\"alpha\":{\"kind\":\"const\",\"value\":1.0}}}";
    let got = match Util.Json.parse(json) {
        case Ok(j) => match ShaderJson.parse(j) {
            case Ok(spec) => match spec#out {
                case ShaderDoc.Out.Fill(f) => match f#shade {
                    case ShaderDoc.Shade.Solid(c) => Some((c#r, c#g, c#b))
                    case _ => None
                }
            }
            case Err(_) => None
        }
        case Err(_) => None
    };
    // #ff8000 → (1.0, 0.502..., 0.0)。中央値は 128/255 なので近い値で確かめる。
    let ok = match got {
        case Some((r, g, b)) => r == 1.0 and b == 0.0 and g > 0.49 and g < 0.51
        case None            => false
    };
    Assert.assertEq(expected = true, ok)

/// lavaVeins も JSON 往復で GLSL がバイト一致（Disk/Blend/Fbm/Warp 込みのフル語彙）。
@Test
def testLavaJsonRoundTripGlslIdentical(): Unit \ Assert =
    let spec = ShaderDoc.lavaVeins();
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(s2) => ShaderGen.compile(s2) == ShaderGen.compile(spec)
        case Err(_) => false
    };
    Assert.assertEq(expected = true, same)

// ════════════════════════════════════════════════════════════════════
// (5) 素の代数（Bin/Un/Pow/Time）— 走査線を math2/math1/time だけで組む
// ════════════════════════════════════════════════════════════════════

/// 走査線の木を作る。scan = 0.5 + 0.5*sin(v*40 - uTime*3)。hash も floor も踏まない連続 sin。
def scanlineField(): ShaderDoc.Field =
    ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add,
        a = ShaderDoc.Field.Const(0.5),
        b = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul,
            a = ShaderDoc.Field.Const(0.5),
            b = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sin,
                of = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Sub,
                    a = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul,
                        a = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V }),
                        b = ShaderDoc.Field.Const(40.0) }),
                    b = ShaderDoc.Field.Time({ scale = 3.0,
                        offset = ShaderDoc.Field.Const(0.0) }) }) }) }) })

/// 走査線が Bin/Un/Time だけで書けて compileBody を pin（実装が最初に吐いた文字列を固定）。
@Test
def testScanlineBodySnapshot(): Unit \ Assert =
    let expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "(0.5 + (0.5 * sin((((vUv).y * 40.0) - (uTime * 3.0 + (0.0)))))));";
    Assert.assertEq(expected = expected, bodyOfField(scanlineField()))

/// 整数指数の Pow は pow() でなく反復積の入れ子になる。指数 4 で括弧が 3 段。
/// 入れ子の段数と括弧の位置を pin する — 組み立て方を変えたとき、段が 1 つ増減しても
/// GLSL としては通ってしまい、絵だけが変わるため。
@Test
def testPowProductSnapshot(): Unit \ Assert =
    let expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "(((max(0.0, (vUv).x) * max(0.0, (vUv).x)) * max(0.0, (vUv).x)) * max(0.0, (vUv).x)));";
    let field = ShaderDoc.Field.Pow({ of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }), p = 4.0 });
    Assert.assertEq(expected = expected, bodyOfField(field))

/// 指数 1 は底そのもの・指数 0 は 1.0（境目で括弧が湧かない）。
@Test
def testPowProductEdges(): Unit \ Assert =
    let at = p -> bodyOfField(ShaderDoc.Field.Pow({ of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }), p = p }));
    Assert.assertEq(
        expected = ("outColor = vec4(vec3(0.0, 0.0, 0.0), max(0.0, (vUv).x));",
                    "outColor = vec4(vec3(0.0, 0.0, 0.0), 1.0);"),
        (at(1.0), at(0.0)))

/// 同じ木の CPU 代表点 pin。v=0.3, t=0.1 → 位相 = 40*0.3 - 3*0.1 = 11.7（連続 sin ＝ 安全）。
@Test
def testScanlineEval(): Unit \ Assert =
    let got = ShaderEval.evalField(scanlineField(), { x = 0.0, y = 0.3 }, 0.1);
    Assert.assertEq(expected = 0.5 + 0.5 * Vec2.sin(11.7), got)

// ════════════════════════════════════════════════════════════════════
// (6) Wave 2a: bindings（shared/use）＋ Tiling — 共有機構と座標のマス目化
// ════════════════════════════════════════════════════════════════════

// ripples プリミティブと同じ式を素の atom + bindings(wob) で書き下す（§3 の反射うねり線）。
//   freq=9, amp=0.24, speed=0.09, seed=7。厳密一致のため掛け算の順序と 2π 定数(6.2831853)を
//   プリミティブ（sg_ripples の CPU 版）とそっくり同じ順で計算する（浮動小数は結合則が成り立たないので）。
//   wob = sin(uv.x*6.2831853*9*0.5 + 7)*0.24 + sin(uv.x*6.2831853*9*1.3 + 18.9)*0.096
//   結果 = 0.5 + 0.5*sin((uv.y*9 + wob + t*0.09) * 6.2831853)。
def ripplesAtomField(): (List[(String, ShaderDoc.Field)], ShaderDoc.Field) =
    let tau = 6.2831853;
    let mul = (a, b) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = a, b = b });
    let add = (a, b) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add, a = a, b = b });
    let c = v -> ShaderDoc.Field.Const(v);
    let uvU = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U });
    // sin(((uv.x * tau) * freq) * fracK + phase)。掛け順は sg_ripples に一致。
    let sinOf = (fracK, phase) ->
        ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sin,
            of = add(mul(mul(mul(uvU, c(tau)), c(9.0)), c(fracK)), c(phase)) });
    // 第 1 項 = sin(...)*amp、第 2 項 = (sin(...)*amp)*0.4（プリミティブの掛け順そのまま）。
    let wob = add(mul(sinOf(0.5, 7.0), c(0.24)),
                  mul(mul(sinOf(1.3, 18.900000000000002), c(0.24)), c(0.4)));
    // band = uv.y*9 + wob + t*0.09。alpha = 0.5 + 0.5*sin(band * tau)。
    let band = add(add(mul(ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V }), c(9.0)),
                       ShaderDoc.Field.Ref("wob")),
                   ShaderDoc.Field.Time({ scale = 0.09, offset = c(0.0) }));
    let alpha = add(c(0.5), mul(c(0.5), ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sin,
        of = mul(band, c(tau)) })));
    (("wob", wob) :: Nil, alpha)

/// ② 素 atom + bindings(wob) で組んだ ripples が、プリミティブ Ripples と代表点で厳密一致する。
///   連続 sin なので hash/floor を踏まず assertEq で完全一致するはず（ズレたら式の写し間違い）。
@Test
def testRipplesAtomsMatchPrimitive(): Unit \ Assert =
    let uv = { x = 0.3, y = 0.4 };
    let t = 0.2;
    let (bindings, alpha) = ripplesAtomField();
    let spec = { name = "r", cycleRate = 0.0, bindings = bindings,
                 out = ShaderDoc.Out.Fill({
                     shade = ShaderDoc.Shade.Solid({ r = 1.0, g = 1.0, b = 1.0 }),
                     alpha = alpha }) };
    let atomVal = ShaderEval.evalAlpha(spec, uv, t);
    let prim = ShaderDoc.Field.Ripples({ freq = 9.0, amp = 0.24, speed = 0.09, seed = 7 });
    let primVal = ShaderEval.evalField(prim, uv, t);
    Assert.assertEq(expected = primVal, atomVal)

/// ③ Tiling ノードは inner uv を fract((vUv) * vec2(..,..)) に差し替える（初回出力を固定）。
@Test
def testTilingNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Tiling({ tiles = { x = 8.0, y = 8.0 },
                                         of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), (fract((vUv) * vec2(8.0, 8.0))).x);",
        bodyOfField(field))

/// ④a 前方参照: 後の binding が前の binding を Ref して正しく評価される。
///   base=0.5 を wob=base+0.25 が参照 → alpha=use(wob)=0.75。
@Test
def testBindingForwardRef(): Unit \ Assert =
    let bindings =
        ("base", ShaderDoc.Field.Const(0.5)) ::
        ("wob", ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add,
            a = ShaderDoc.Field.Ref("base"), b = ShaderDoc.Field.Const(0.25) })) :: Nil;
    let spec = { name = "f", cycleRate = 0.0, bindings = bindings,
                 out = ShaderDoc.Out.Fill({
                     shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
                     alpha = ShaderDoc.Field.Ref("wob") }) };
    Assert.assertEq(expected = 0.75, ShaderEval.evalAlpha(spec, { x = 0.0, y = 0.0 }, 0.0))

/// ④a-gl GLSL 経路: bindings は main 先頭に sg_b_<name> を宣言し、Ref は生の名前でなく
///   sg_b_<name> を参照する（bindings/Ref を実際にコンパイルして「未宣言 wob」事故を釘打ち）。
@Test
def testBindingCompilesToBindingVar(): Unit \ Assert =
    let bindings =
        ("base", ShaderDoc.Field.Const(0.5)) ::
        ("wob", ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add,
            a = ShaderDoc.Field.Ref("base"), b = ShaderDoc.Field.Const(0.25) })) :: Nil;
    let spec = { name = "f", cycleRate = 0.0, bindings = bindings,
                 out = ShaderDoc.Out.Fill({
                     shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
                     alpha = ShaderDoc.Field.Ref("wob") }) };
    let expected =
        "    float sg_b_base = 0.5;\n" +
        "    float sg_b_wob = (sg_b_base + 0.25);\n" +
        "outColor = vec4(vec3(0.0, 0.0, 0.0), sg_b_wob);";
    Assert.assertEq(expected = expected, ShaderGen.compileBody(spec))

/// ④b 循環（自己参照 or 後方参照）の JSON は parse で Err（fail-open で呼び側がフォールバック）。
@Test
def testBindingCircularIsErr(): Unit \ Assert =
    // "a" が自分自身を Ref（自己参照＝定義前の名前）→ Err。
    let json = "{\"name\":\"x\"," +
               "\"shared\":[[\"a\",{\"kind\":\"use\",\"name\":\"a\"}]]," +
               "\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#000000\"}," +
               "\"alpha\":{\"kind\":\"const\",\"value\":1.0}}}";
    let r = match Util.Json.parse(json) {
        case Ok(j)  => Result.isErr(ShaderJson.parse(j))
        case Err(_) => false
    };
    Assert.assertEq(expected = true, r)

/// ④c 未定義 Ref（out が定義されていない名前を使う）の JSON は parse で Err。
@Test
def testUndefinedRefIsErr(): Unit \ Assert =
    let json = "{\"name\":\"x\"," +
               "\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#000000\"}," +
               "\"alpha\":{\"kind\":\"use\",\"name\":\"ghost\"}}}";
    let r = match Util.Json.parse(json) {
        case Ok(j)  => Result.isErr(ShaderJson.parse(j))
        case Err(_) => false
    };
    Assert.assertEq(expected = true, r)

// ════════════════════════════════════════════════════════════════════
// (7) Wave 2b: Hash1/Hash2（bucket）— セル乱数
//   パリティの線引き（設計 §5）を厳守する:
//     floor/hash を踏む値を「GPU が出すはずの値」として assertEq しない。
//     許すのは「範囲が正気」「floor が段階を刻んで値が変わる」「亜種が JSON で組める」だけ。
//   （GPU は f32/floor で境界の位置が CPU と別なので、CPU の hash/cyc 値が GPU と一致する
//     保証はない。ここでは GPU 一致を一切主張しない。）
// ════════════════════════════════════════════════════════════════════

/// 時間で乱数を選び直すための「バケツ」場: cyc = floor(uTime*0.5)。
/// （bucket にこれを入れると一定時間ごとに別の乱数へ切り替わる。）
def cycField(): ShaderDoc.Field =
    ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Floor,
        of = ShaderDoc.Field.Time({ scale = 0.5, offset = ShaderDoc.Field.Const(0.0) }) })

/// ⑤ Hash1 の GLSL 片（bucket 無し/有り）。既存 sg_hash1 を呼ぶだけ（prelude は増えない）。
@Test
def testHash1NodeSnapshot(): Unit \ Assert =
    let none = ShaderDoc.Field.Hash1({ scale = 8.0, seed = 5, bucket = None });
    let buck = ShaderDoc.Field.Hash1({ scale = 8.0, seed = 5, bucket = Some(cycField()) });
    let expNone = "outColor = vec4(vec3(0.0, 0.0, 0.0), sg_hash1(floor((vUv) * 8.0), 5.0));";
    let expBuck = "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "sg_hash1((floor((vUv) * 8.0) + (floor((uTime * 0.5 + (0.0))))), 5.0));";
    Assert.assertEq(expected = (expNone, expBuck), (bodyOfField(none), bodyOfField(buck)))

/// ⑤ Hash2 の GLSL 片（bucket 無し=comp u / bucket 有り=comp v）。
@Test
def testHash2NodeSnapshot(): Unit \ Assert =
    let none = ShaderDoc.Field.Hash2({ scale = 8.0, seed = 22, comp = ShaderDoc.Axis.U, bucket = None });
    let buck = ShaderDoc.Field.Hash2({ scale = 8.0, seed = 22, comp = ShaderDoc.Axis.V,
                                       bucket = Some(cycField()) });
    let expNone = "outColor = vec4(vec3(0.0, 0.0, 0.0), (sg_hash2(floor((vUv) * 8.0), 22.0)).x);";
    let expBuck = "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "(sg_hash2((floor((vUv) * 8.0) + (floor((uTime * 0.5 + (0.0))))), 22.0)).y);";
    Assert.assertEq(expected = (expNone, expBuck), (bodyOfField(none), bodyOfField(buck)))

/// ⑥ hash1 の eval は代表点で 0..1 の範囲に収まる（範囲の正気のみ・GPU 一致は非主張）。
@Test
def testHash1Range(): Unit \ Assert =
    let field = ShaderDoc.Field.Hash1({ scale = 8.0, seed = 5, bucket = None });
    let v = ShaderEval.evalField(field, { x = 0.37, y = 0.62 }, 0.0);
    Assert.assertEq(expected = true, 0.0 <= v and v < 1.0)

/// ⑥ bucket=cyc（floor(uTime*k)）の Hash1 を、別々の時間バケツに落ちる 2 時刻で eval し、
///   「floor が段階を刻んで値が変わる」ことだけ確かめる（値そのものは pin しない）。
///   t=0.0 → cyc=floor(0)=0、t=3.0 → cyc=floor(1.5)=1 で別セルの乱数になる。
///   GPU は f32/floor で境界が別位置なので、この CPU 値が GPU と一致するとは主張しない。
@Test
def testHashBucketSteps(): Unit \ Assert =
    let field = ShaderDoc.Field.Hash1({ scale = 8.0, seed = 5, bucket = Some(cycField()) });
    let uv = { x = 0.37, y = 0.62 };
    let vLow  = ShaderEval.evalField(field, uv, 0.0);   // cyc=0
    let vHigh = ShaderEval.evalField(field, uv, 3.0);   // cyc=1（段階が 1 つ上がる）
    // 段階が変われば hash の入力座標が変わるので値も変わる。範囲も両方 0..1 に収まる。
    let sane = 0.0 <= vLow and vLow < 1.0 and 0.0 <= vHigh and vHigh < 1.0;
    Assert.assertEq(expected = (true, true), (vLow != vHigh, sane))

/// ⑥ Hash1(bucket=cyc) を on、菱形（Pow）/丸（Un）で組んだ Sparkle 亜種を eval して
///   0.0 <= v の範囲に収まることだけ確かめる（＝亜種が JSON 語彙で組めることの実証）。
///   この亜種は bucket に floor(cyc) を通すので CPU パリティ（GPU との値一致）は適用外。
@Test
def testSparkleVariantEvalSane(): Unit \ Assert =
    // on = Hash1(bucket=cyc)、tw = pow(sat(sin(uTime)), 12)、point = 1 - sat(|uv.x-0.5|)。
    let on = ShaderDoc.Field.Hash1({ scale = 8.0, seed = 5, bucket = Some(cycField()) });
    let tw = ShaderDoc.Field.Pow({ p = 12.0,
        of = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sat,
            of = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sin,
                of = ShaderDoc.Field.Time({ scale = 1.0, offset = ShaderDoc.Field.Const(0.0) }) }) }) });
    let point = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.OneMinus,
        of = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sat,
            of = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Abs,
                of = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Sub,
                    a = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }),
                    b = ShaderDoc.Field.Const(0.5) }) }) }) });
    let variant = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul,
        a = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = on, b = tw }), b = point });
    let v = ShaderEval.evalField(variant, { x = 0.4, y = 0.6 }, 0.3);
    Assert.assertEq(expected = true, 0.0 <= v)

/// ⑦ hash 呼び出し回数 lint。生成 GLSL 中の sg_hash 出現数の上限を機械ガードする。
///   compileBody（prelude 抜き）で数える理由: prelude には sg_hash1/sg_hash2 の定義と内部呼びが
///   多数あり、そこを含めると Spec 側の展開数が測れない（prelude の定数に埋もれる）。
///   方式(b): 同じ hash 場を「binding で 1 回だけ計算して 2 か所で use する版」と
///   「2 か所に直書きする版」で作り、共有版の sg_hash 数 < 直書き版 を assert する。
///   閾値マジックナンバーを使わず、共有し忘れると sg_hash がテキスト増殖する footgun を直接示す。
@Test
def testHashCallCountBounded(): Unit \ Assert =
    let h = ShaderDoc.Field.Hash1({ scale = 8.0, seed = 5, bucket = Some(cycField()) });
    let mul = (a, b) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = a, b = b });
    // 直書き版: alpha = h * h（h を 2 か所に展開）→ sg_hash がテキストで 2 回出る。
    let inlinedSpec = { name = "inl", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
            alpha = mul(h, h) }) };
    // 共有版: binding "h" に 1 回だけ計算し、alpha = use(h) * use(h)。sg_hash はテキストで 1 回。
    let sharedSpec = { name = "shr", cycleRate = 0.0, bindings = ("h", h) :: Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
            alpha = mul(ShaderDoc.Field.Ref("h"), ShaderDoc.Field.Ref("h")) }) };
    let nInlined = countOccurrences("sg_hash", ShaderGen.compileBody(inlinedSpec));
    let nShared  = countOccurrences("sg_hash", ShaderGen.compileBody(sharedSpec));
    Assert.assertEq(expected = (true, true), (nShared < nInlined, nShared >= 1))

/// 部分文字列の非重複な出現回数を数える薄いヘルパ（見つけたら needle の長さだけ削って進む）。
def countOccurrences(needle: String, haystack: String): Int32 =
    def loop(rest, acc) =
        match String.indexOf({ substr = needle }, rest) {
            case Some(i) => loop(String.drop(i + String.length(needle), rest), acc + 1)
            case None    => acc
        };
    loop(haystack, 0)

// ════════════════════════════════════════════════════════════════════
// (8) Wave 3: Shade.Gradient（3 色以上のグラデ）
//   prelude を増やさず素の mix/smoothstep の入れ子で色を作る。連続なので hash/floor を
//   踏まず、代表色（field=0.5 補間）も evalPixel の脈動も厳密に pin できる。
// ════════════════════════════════════════════════════════════════════

/// Gradient の shade を包んで compileBody を作る小道具（alpha=1 固定）。
def bodyOfGradient(stops: List[(Float64, Color)], field: ShaderDoc.Field): String =
    ShaderGen.compileBody({ name = "g", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Gradient({ stops = stops, field = field }),
                                   alpha = ShaderDoc.Field.Const(1.0) }) })

/// 3 stops の Gradient の GLSL 片（入れ子 mix + smoothstep・cycleRate=0 の clamp 係数）。
@Test
def testGradientNodeSnapshot(): Unit \ Assert =
    let stops =
        (0.0, { r = 0.0, g = 0.0, b = 0.0 }) ::
        (0.5, { r = 1.0, g = 0.0, b = 0.0 }) ::
        (1.0, { r = 1.0, g = 1.0, b = 0.0 }) :: Nil;
    let field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U });
    let expected =
        "outColor = vec4(mix(mix(vec3(0.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), " +
        "smoothstep(0.0, 0.5, clamp((vUv).x, 0.0, 1.0))), vec3(1.0, 1.0, 0.0), " +
        "smoothstep(0.5, 1.0, clamp((vUv).x, 0.0, 1.0))), 1.0);";
    Assert.assertEq(expected = expected, bodyOfGradient(stops, field))

/// 区切り 5 個の Gradient。3 個では入れ子が 2 段しかなく、段の作り方を変えたとき
/// 1 段ずれても偶然合ってしまう余地がある。4 段まで伸ばして、
/// 各段が「1 つ前の式全体 + 次の色 + 次の smoothstep」で閉じることを pin する。
@Test
def testGradientFiveStopsSnapshot(): Unit \ Assert =
    let stops =
        (0.0,  { r = 0.0, g = 0.0, b = 0.0 }) ::
        (0.25, { r = 1.0, g = 0.0, b = 0.0 }) ::
        (0.5,  { r = 0.0, g = 1.0, b = 0.0 }) ::
        (0.75, { r = 0.0, g = 0.0, b = 1.0 }) ::
        (1.0,  { r = 1.0, g = 1.0, b = 1.0 }) :: Nil;
    let field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U });
    let expected =
        "outColor = vec4(mix(mix(mix(mix(vec3(0.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), " +
        "smoothstep(0.0, 0.25, clamp((vUv).x, 0.0, 1.0))), vec3(0.0, 1.0, 0.0), " +
        "smoothstep(0.25, 0.5, clamp((vUv).x, 0.0, 1.0))), vec3(0.0, 0.0, 1.0), " +
        "smoothstep(0.5, 0.75, clamp((vUv).x, 0.0, 1.0))), vec3(1.0, 1.0, 1.0), " +
        "smoothstep(0.75, 1.0, clamp((vUv).x, 0.0, 1.0))), 1.0);";
    Assert.assertEq(expected = expected, bodyOfGradient(stops, field))

/// representativeColor は field を評価せず f=0.5 の補間色を返す（GL なし経路のベタ塗り）。
///   stops = [(0, #000000), (0.5, #ff6000 相当), (1, #ffe0a0 相当)] の f=0.5 → 2 つ目の色ちょうど。
///   f=0.5 では 1 つ目→2 つ目の smoothstep(0,0.5,0.5)=1（2 つ目にぴったり）、
///   2 つ目→3 つ目の smoothstep(0.5,1,0.5)=0（動かない）ので結果は 2 つ目の色そのもの。
@Test
def testGradientRepresentativeColor(): Unit \ Assert =
    let stops =
        (0.0, { r = 0.1, g = 0.02, b = 0.01 }) ::
        (0.5, { r = 0.8, g = 0.3, b = 0.05 }) ::
        (1.0, { r = 1.0, g = 0.9, b = 0.6 }) :: Nil;
    let spec = { name = "g", cycleRate = 0.0, bindings = Nil,
                 out = ShaderDoc.Out.Fill({
                     shade = ShaderDoc.Shade.Gradient({ stops = stops,
                         field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) }),
                     alpha = ShaderDoc.Field.Const(1.0) }) };
    let got = ShaderDoc.representativeColor(spec);
    // f=0.5 の補間は 2 つ目の色そのもの（1つ目→2つ目 smoothstep=1・2つ目→3つ目 smoothstep=0）。
    let ok = Float64.abs(got#r - 0.8) < 0.001 and
             Float64.abs(got#g - 0.3) < 0.001 and
             Float64.abs(got#b - 0.05) < 0.001;
    Assert.assertEq(expected = true, ok)

/// ヒーロー: magma_geothermal（地熱の脈動する溶岩流）。§3 の hero JSON を parse し、
///   ① hex stops + comment キーが通って parse 成功する（hash 不使用の連続 spec）、
///   ② 同じ uv で 2 時刻の evalPixel が違う色になる（脈動する）ことと値が正気（0..1）なことを確かめる。
@Test
def testMagmaGeothermalPulses(): Unit \ Assert =
    // hex stops（#rrggbb）と各ノードの comment キー（parser は無視する）が通る証拠も兼ねる。
    let json =
        "{\"name\":\"magma_geothermal\",\"cycleRate\":0.0,\"out\":{\"kind\":\"fill\"," +
        "\"shade\":{\"kind\":\"gradient\",\"stops\":[[0.0,\"#1a0602\"],[0.45,\"#e0500a\"]," +
        "[1.0,\"#ffe6a0\"]],\"field\":{\"kind\":\"math2\",\"op\":\"add\"," +
        "\"a\":{\"comment\":\"cleft x pulse\",\"kind\":\"math2\",\"op\":\"mul\"," +
        "\"a\":{\"kind\":\"pow\",\"p\":2.5,\"of\":{\"kind\":\"smoothstep\",\"lo\":0.55,\"hi\":0.72," +
        "\"of\":{\"kind\":\"warp\",\"amount\":0.12,\"scale\":2.5,\"seed\":5," +
        "\"of\":{\"kind\":\"scaled\",\"factor\":3.5,\"scroll\":{\"x\":0.05,\"y\":0.04}," +
        "\"of\":{\"kind\":\"fbm\",\"octaves\":3,\"scale\":1.0,\"seed\":11}}}}}," +
        "\"b\":{\"comment\":\"pulse\",\"kind\":\"math2\",\"op\":\"add\"," +
        "\"a\":{\"kind\":\"const\",\"value\":0.55},\"b\":{\"kind\":\"math2\",\"op\":\"mul\"," +
        "\"a\":{\"kind\":\"const\",\"value\":0.45},\"b\":{\"kind\":\"math1\",\"op\":\"sin\"," +
        "\"of\":{\"kind\":\"time\",\"scale\":1.6,\"offset\":{\"kind\":\"const\",\"value\":0.0}}}}}}," +
        "\"b\":{\"comment\":\"heat\",\"kind\":\"math2\",\"op\":\"mul\"," +
        "\"a\":{\"kind\":\"const\",\"value\":0.12},\"b\":{\"kind\":\"math2\",\"op\":\"add\"," +
        "\"a\":{\"kind\":\"const\",\"value\":0.5},\"b\":{\"kind\":\"math2\",\"op\":\"mul\"," +
        "\"a\":{\"kind\":\"const\",\"value\":0.5},\"b\":{\"kind\":\"math1\",\"op\":\"sin\"," +
        "\"of\":{\"kind\":\"math2\",\"op\":\"sub\",\"a\":{\"kind\":\"math2\",\"op\":\"mul\"," +
        "\"a\":{\"kind\":\"uv\",\"axis\":\"v\"},\"b\":{\"kind\":\"const\",\"value\":14.0}}," +
        "\"b\":{\"kind\":\"time\",\"scale\":2.0,\"offset\":{\"kind\":\"const\",\"value\":0.0}}}}}}}}}," +
        "\"alpha\":{\"kind\":\"const\",\"value\":1.0}}}";
    let result = match Util.Json.parse(json) {
        case Ok(j) => match ShaderJson.parse(j) {
            case Ok(spec) =>
                let uv = { x = 0.4, y = 0.6 };
                let c0 = ShaderEval.evalPixel(spec, uv, 0.0);
                let c1 = ShaderEval.evalPixel(spec, uv, 1.0);
                // 脈動: 2 時刻で色が違う。正気: 各成分が 0..1 に収まる。
                let differ = c0#r != c1#r or c0#g != c1#g or c0#b != c1#b;
                let sane = c0#r >= 0.0 and c0#r <= 1.0 and c1#g >= 0.0 and c1#g <= 1.0;
                Some((differ, sane))
            case Err(_) => None
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some((true, true)), result)

/// lava の alpha は Disk（丸い溶岩溜まり）を Warp でくるんだ木（往復後も辿れる）。
@Test
def testLavaAlphaIsWarpDisk(): Unit \ Assert =
    let radius = match ShaderJson.parse(ShaderJson.toJson(ShaderDoc.lavaVeins())) {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.Warp(wp) => match wp#of {
                    case ShaderDoc.Field.Disk(d) => Some(d#radius)
                    case _ => None
                }
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some(0.42), radius)

// ════════════════════════════════════════════════════════════════════
// (R3) Radial — 中心距離場（ビネットの素材）。3面（Gen/Eval/Json）を同時に pin する。
// ════════════════════════════════════════════════════════════════════

/// Radial ノード単体の GLSL 片（length((uv) - vec2(cx, cy)) をそのまま吐く）。
@Test
def testRadialNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Radial({ cx = 0.5, cy = 0.5 });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), length((vUv) - vec2(0.5, 0.5)));",
        bodyOfField(field))

/// Radial の CPU 評価: 中心 0・横 0.5・四隅 √0.5（GLSL の length と同じ式）。
@Test
def testEvalRadial(): Unit \ Assert =
    let rd = ShaderDoc.Field.Radial({ cx = 0.5, cy = 0.5 });
    let center = ShaderEval.evalField(rd, { x = 0.5, y = 0.5 }, 0.0);
    let edge = ShaderEval.evalField(rd, { x = 1.0, y = 0.5 }, 0.0);
    let corner = ShaderEval.evalField(rd, { x = 1.0, y = 1.0 }, 0.0);
    Assert.assertEq(expected = (true, true, true),
        (center == 0.0, edge == 0.5, Float64.abs(corner - Vec2.sqrt(0.5)) < 0.0000001))

/// CPU/GPU 一致: Radial+Smoothstep のビネット式で、CPU 評価（ShaderEval）と
/// GLSL 側（ShaderGen）が同じ smoothstep(lo, hi, length(...)) の構造を持つことを釘打ちする。
/// 代表点の値は CPU で（GLSL は文字列 pin — GL の無いテスト環境での「一致」の作法は Disk と同じ）。
@Test
def testRadialVignetteCpuGpuParity(): Unit \ Assert =
    let vig = ShaderDoc.Field.Smoothstep({ lo = 0.3, hi = 0.7,
        of = ShaderDoc.Field.Radial({ cx = 0.5, cy = 0.5 }) });
    // GLSL: smoothstep が Radial の length を包む（CPU と同じ入れ子構造）。
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "smoothstep(0.3, 0.7, length((vUv) - vec2(0.5, 0.5))));",
        bodyOfField(vig));
    // CPU: 中心 0（暗がり無し）・距離 0.5（= (lo+hi)/2）で 0.5・四隅 ≈ 1 近く。
    let center = ShaderEval.evalField(vig, { x = 0.5, y = 0.5 }, 0.0);
    let mid = ShaderEval.evalField(vig, { x = 1.0, y = 0.5 }, 0.0);
    Assert.assertEq(expected = (true, true),
        (center == 0.0, Float64.abs(mid - 0.5) < 0.0000001))

/// Radial の JSON 往復: radial {cx, cy} → Field.Radial → toJson → parse で保たれ、
/// 往復後の GLSL がバイト一致する（Gen/Json の 2 面がズレない）。cx/cy 省略時は中心 (0.5, 0.5)。
@Test
def testRadialJsonRoundTrip(): Unit \ Assert =
    let spec: ShaderDoc.Spec = { name = "vignette", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.1, g = 0.1, b = 0.2 }),
            alpha = ShaderDoc.Field.Smoothstep({ lo = 0.3, hi = 0.7,
                of = ShaderDoc.Field.Radial({ cx = 0.4, cy = 0.6 }) }) }) };
    let roundTrip = ShaderJson.parse(ShaderJson.toJson(spec));
    let glslSame = match roundTrip {
        case Ok(spec2) => ShaderGen.compile(spec2) == ShaderGen.compile(spec)
        case Err(_)    => false
    };
    let cxcy = match roundTrip {
        case Ok(spec2) => match spec2#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.Smoothstep(s) => match s#of {
                    case ShaderDoc.Field.Radial(rd) => Some((rd#cx, rd#cy))
                    case _ => None
                }
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = (true, Some((0.4, 0.6))), (glslSame, cxcy))

/// radial の cx/cy は省略可（既定 0.5, 0.5 = 中心）。
@Test
def testRadialJsonDefaults(): Unit \ Assert =
    let json = "{ \"name\": \"v\", \"out\": { \"kind\": \"fill\"," +
        " \"shade\": { \"kind\": \"solid\", \"color\": \"#101020\" }," +
        " \"alpha\": { \"kind\": \"radial\" } } }";
    let got = Util.Json.parse(json) |> Result.flatMap(ShaderJson.parse);
    let cxcy = match got {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.Radial(rd) => Some((rd#cx, rd#cy))
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some((0.5, 0.5)), cxcy)

// ════════════════════════════════════════════════════════════════════
// (9) 周期 Fbm（FbmTile）・量子化（Quantize）・アスペクト補正距離（RadialAspect）
//   3 面（Gen/Eval/Json）を Radial の前例と同じ粒度で pin する。
// ════════════════════════════════════════════════════════════════════

/// FbmTile ノード単体の GLSL 片（prelude の sg_fbmTile を呼ぶ形）。
@Test
def testFbmTileNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.FbmTile({ octaves = 2, scale = 4.0,
                                          period = { x = 4.0, y = 4.0 }, seed = 7 });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), sg_fbmTile((vUv) * 4.0, vec2(4.0, 4.0), 2, 7.0));",
        bodyOfField(field))

/// FbmTile は period ちょうどでラップして値が一致する（= スクロールでループが閉じる証拠）。
///   scale=4・period=(4,4) なので uv が 1.0 進むと格子は 4 マス = ちょうど 1 周期進む。
///   uv は 2 進小数で正確な値（21/64, 37/64）を選び、全オクターブで浮動小数の丸めが出ないようにする。
@Test
def testFbmTileWrapsAtPeriod(): Unit \ Assert =
    let field = ShaderDoc.Field.FbmTile({ octaves = 3, scale = 4.0,
                                          period = { x = 4.0, y = 4.0 }, seed = 7 });
    let v0 = ShaderEval.evalField(field, { x = 0.328125, y = 0.578125 }, 0.0);
    let vx = ShaderEval.evalField(field, { x = 1.328125, y = 0.578125 }, 0.0);
    let vy = ShaderEval.evalField(field, { x = 0.328125, y = 1.578125 }, 0.0);
    Assert.assertEq(expected = (v0, v0), (vx, vy))

/// Quantize ノード単体の GLSL 片（floor(x*n)/n・steps は 1 で下切り）。
@Test
def testQuantizeNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Quantize({ of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }),
                                           steps = 4 });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), (floor(((vUv).x) * 4.0) / 4.0));",
        bodyOfField(field))

/// Quantize の CPU 評価: 4 段階で 0.3→0.25・0.9→0.75・1.0→1.0（GLSL と同じ floor(x*n)/n）。
@Test
def testEvalQuantizeSteps(): Unit \ Assert =
    let q = of -> ShaderDoc.Field.Quantize({ of = of, steps = 4 });
    let at = x -> ShaderEval.evalField(q(ShaderDoc.Field.Const(x)), { x = 0.0, y = 0.0 }, 0.0);
    Assert.assertEq(expected = (0.25, 0.75, 1.0), (at(0.3), at(0.9), at(1.0)))

/// RadialAspect ノード単体の GLSL 片（u 方向だけ aspect 倍して距離を測る）。
@Test
def testRadialAspectNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 2.0 });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), length(vec2(((vUv).x - 0.5) * 2.0, (vUv).y - 0.5)));",
        bodyOfField(field))

/// RadialAspect の CPU 評価: 幅 2:1 の rect（aspect=2）では u の 0.25 と v の 0.5 が同じ距離
/// （= px で見て真円になる補正）。中心は 0。
@Test
def testEvalRadialAspectCircle(): Unit \ Assert =
    let ra = ShaderDoc.Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 2.0 });
    let center = ShaderEval.evalField(ra, { x = 0.5, y = 0.5 }, 0.0);
    let right = ShaderEval.evalField(ra, { x = 0.75, y = 0.5 }, 0.0);
    let down = ShaderEval.evalField(ra, { x = 0.5, y = 1.0 }, 0.0);
    Assert.assertEq(expected = (0.0, 0.5, 0.5), (center, right, down))

/// 新 3 ノードを組んだ Spec の JSON 往復で GLSL がバイト一致（Gen/Json の 2 面がズレない）。
@Test
def testNewNodesJsonRoundTripGlslIdentical(): Unit \ Assert =
    let spec: ShaderDoc.Spec = { name = "tile", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.2, g = 0.4, b = 0.6 }),
            alpha = ShaderDoc.Field.Quantize({ steps = 5,
                of = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul,
                    a = ShaderDoc.Field.FbmTile({ octaves = 2, scale = 4.0,
                        period = { x = 4.0, y = 4.0 }, seed = 7 }),
                    b = ShaderDoc.Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 2.0 }) }) }) }) };
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(s2) => ShaderGen.compile(s2) == ShaderGen.compile(spec)
        case Err(_) => false
    };
    Assert.assertEq(expected = true, same)

/// fail-open の既定: radialAspect の aspect 省略 = 1.0（Radial と同じ円）・
/// quantize の steps 省略 = 4。
@Test
def testNewNodesJsonDefaults(): Unit \ Assert =
    let json = "{\"name\":\"q\",\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#000000\"}," +
               "\"alpha\":{\"kind\":\"quantize\",\"of\":{\"kind\":\"radialAspect\"}}}}";
    let got = Util.Json.parse(json) |> Result.flatMap(ShaderJson.parse);
    let vals = match got {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.Quantize(q) => match q#of {
                    case ShaderDoc.Field.RadialAspect(ra) => Some((q#steps, ra#aspect))
                    case _ => None
                }
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some((4, 1.0)), vals)

// ════════════════════════════════════════════════════════════════════
// (10) 座標スナップ（Snap）— uv をマス目に丸めて絵をドット絵の粒に落とす
//   GLSL と CPU のパリティは「片方に (floor(uv*cells)+0.5)/cells の文字列を pin し、
//   もう片方に同じ数式で出る数値を pin する」の 2 本立てで見る（Radial/Quantize と同じ流儀）。
// ════════════════════════════════════════════════════════════════════

/// Snap ノード単体の GLSL 片。inner の uv が (floor(uv*cells)+0.5)/cells に差し替わり、
/// cells は軸ごと（4 分割 × 2 分割）に効く。
@Test
def testSnapNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Snap({ cells = { x = 4.0, y = 2.0 },
                                       of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), " +
        "(((floor((vUv) * vec2(4.0, 2.0)) + 0.5) / vec2(4.0, 2.0))).x);",
        bodyOfField(field))

/// Snap の CPU 評価はマスの中心を読む（GLSL 片と同じ数式の数値側）。
///   cells=(4,2)・uv=(0.3, 0.3) → u は (floor(1.2)+0.5)/4 = 0.375、v は (floor(0.6)+0.5)/2 = 0.25。
///   u と v で答えが違う = 軸ごとの分割数が効いている証拠。
@Test
def testEvalSnapReadsCellCenter(): Unit \ Assert =
    let snapOf = axis -> ShaderDoc.Field.Snap({ cells = { x = 4.0, y = 2.0 },
                                                of = ShaderDoc.Field.Uv({ axis = axis }) });
    let at = axis -> ShaderEval.evalField(snapOf(axis), { x = 0.3, y = 0.3 }, 0.0);
    Assert.assertEq(expected = (0.375, 0.25),
        (at(ShaderDoc.Axis.U), at(ShaderDoc.Axis.V)))

/// 同じマスの中はどこを読んでも同じ値・マスの境をまたぐと値が変わる（＝塊が出ている）。
///   cells=(4,4) なので u の境は 0.25/0.5/0.75。
///       0.26  0.49 |  0.51
///        └ 同じマス ┘  └ 隣のマス
///   なめらかな Fbm を包んでも階段が立つことを確かめる。
@Test
def testEvalSnapHoldsValueInsideCell(): Unit \ Assert =
    let field = ShaderDoc.Field.Snap({ cells = { x = 4.0, y = 4.0 },
        of = ShaderDoc.Field.Fbm({ octaves = 3, scale = 6.0, seed = 5 }) });
    let at = u -> ShaderEval.evalField(field, { x = u, y = 0.1 }, 0.0);
    Assert.assertEq(expected = (true, true),
        (at(0.26) == at(0.49), at(0.49) != at(0.51)))

/// Snap を含む Spec の JSON 往復で GLSL がバイト一致する（Gen/Json の 2 面がズレない）。
@Test
def testSnapJsonRoundTripGlslIdentical(): Unit \ Assert =
    let spec: ShaderDoc.Spec = { name = "nebula", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.3, g = 0.5, b = 0.9 }),
            alpha = ShaderDoc.Field.Snap({ cells = { x = 120.0, y = 68.0 },
                of = ShaderDoc.Field.Fbm({ octaves = 3, scale = 4.0, seed = 11 }) }) }) };
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(spec2) => ShaderGen.compile(spec2) == ShaderGen.compile(spec)
        case Err(_)    => false
    };
    Assert.assertEq(expected = true, same)

/// fail-open の既定: snap の cells 省略 = 8×8（of は必須）。
@Test
def testSnapJsonDefaultCells(): Unit \ Assert =
    let json = "{\"name\":\"s\",\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#000000\"}," +
               "\"alpha\":{\"kind\":\"snap\",\"of\":{\"kind\":\"uv\",\"axis\":\"u\"}}}}";
    let cells = match Util.Json.parse(json) |> Result.flatMap(ShaderJson.parse) {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.Snap(sn) => Some((sn#cells#x, sn#cells#y))
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some((8.0, 8.0)), cells)

// ════════════════════════════════════════════════════════════════════
// (9) Wave D: tex 場（Tex / Shift / Shade.Rgb）— テクスチャを場として読む
//   パリティの線引き: 標本の量子化（floor + clamp + 8bit/255）は両経路同式なので assertEq で
//   釘打ちする。テクスチャ以降の float 合成は従来どおり近似（GPU 一致を主張しない）。
// ════════════════════════════════════════════════════════════════════

/// tex 場を使う代表 Spec（pin 用）: shade は pass "glow" の Rgb 素通し、alpha は "mask" の R。
def texSpecOf(): ShaderDoc.Spec =
    { name = "texdemo", cycleRate = 0.0, bindings = Nil,
      out = ShaderDoc.Out.Fill({
          shade = ShaderDoc.Shade.Rgb({
              r = ShaderDoc.Field.Tex({ name = "glow", chan = ShaderDoc.TexChan.R }),
              g = ShaderDoc.Field.Tex({ name = "glow", chan = ShaderDoc.TexChan.G }),
              b = ShaderDoc.Field.Tex({ name = "glow", chan = ShaderDoc.TexChan.B }) }),
          alpha = ShaderDoc.Field.Tex({ name = "mask", chan = ShaderDoc.TexChan.R }) }) }

/// compile() の共通ヘッダ（uniform 宣言の直前まで）。
def glslHeader(): String =
    "#version 330 core\nin vec2 vUv;\nout vec4 outColor;\nuniform float uTime;\nuniform float uAlpha;\n"

/// compile() の main の終わり（面全体の濃さ uAlpha を掛けて閉じる）。
def glslMainEnd(): String = "\n    outColor.a *= uAlpha;\n}\n"

/// (a) 新語彙を使わない既存代表 Spec の compile() 全文は「ヘッダ + prelude + main」のままで、
///   uTex uniform が 1 文字も足されない（使わない Spec の GLSL を変えないことを全文で釘打ち）。
@Test
def testNoTexUniformForExistingSpecs(): Unit \ Assert =
    let fullOf = (spec: ShaderDoc.Spec) ->
        glslHeader() + ShaderGen.preludeSource() +
        "void main() {\n    " + ShaderGen.compileBody(spec) + glslMainEnd();
    let specs = ShaderDoc.demoSurface() :: ShaderDoc.waterVeins() :: ShaderDoc.lavaVeins() :: Nil;
    Assert.assertEq(expected = List.map(fullOf, specs), List.map(ShaderGen.compile, specs))

/// (b) tex 場つき Spec の compile() 全文: uniform 行が texNames の正典順（glow=0, mask=1）で
///   uTime の直後に並び、main は texture() 標本 + flip の mix を含む（番号割当を全文で固定）。
@Test
def testTexSpecCompileSnapshot(): Unit \ Assert =
    let expectedBody =
        "outColor = vec4(vec3(" +
        "texture(uTex0, vec2((vUv).x, mix((vUv).y, 1.0 - (vUv).y, uTexFlip0))).r, " +
        "texture(uTex0, vec2((vUv).x, mix((vUv).y, 1.0 - (vUv).y, uTexFlip0))).g, " +
        "texture(uTex0, vec2((vUv).x, mix((vUv).y, 1.0 - (vUv).y, uTexFlip0))).b), " +
        "texture(uTex1, vec2((vUv).x, mix((vUv).y, 1.0 - (vUv).y, uTexFlip1))).r);";
    let expected =
        glslHeader() +
        "uniform sampler2D uTex0;\nuniform float uTexFlip0;\n" +
        "uniform sampler2D uTex1;\nuniform float uTexFlip1;\n" +
        ShaderGen.preludeSource() +
        "void main() {\n    " + expectedBody + glslMainEnd();
    Assert.assertEq(expected = expected, ShaderGen.compile(texSpecOf()))

/// (c) texNames の順序決定性: bindings（前から）→ 色 → alpha の初出順・重複除去。
///   bindings の "b" が先頭・shade の "a" が次・alpha の "b" は 2 度目なので出ない。
@Test
def testTexNamesCanonicalOrder(): Unit \ Assert =
    let texOf = name -> ShaderDoc.Field.Tex({ name = name, chan = ShaderDoc.TexChan.R });
    let spec: ShaderDoc.Spec =
        { name = "o", cycleRate = 0.0,
          bindings = ("s", texOf("b")) :: Nil,
          out = ShaderDoc.Out.Fill({
              shade = ShaderDoc.Shade.Ramp({ lo = { r = 0.0, g = 0.0, b = 0.0 },
                                             hi = { r = 1.0, g = 1.0, b = 1.0 },
                                             field = texOf("a") }),
              alpha = texOf("b") }) };
    Assert.assertEq(expected = "b" :: "a" :: Nil, ShaderDoc.texNames(spec))

/// Shift ノードの GLSL 片: dx/dy は外側 uv の式で組み、of は uv+vec2(dx,dy) で読む。
@Test
def testShiftNodeSnapshot(): Unit \ Assert =
    let field = ShaderDoc.Field.Shift({
        dx = ShaderDoc.Field.Const(0.1), dy = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V }),
        of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) });
    Assert.assertEq(expected =
        "outColor = vec4(vec3(0.0, 0.0, 0.0), (((vUv) + vec2(0.1, (vUv).y))).x);",
        bodyOfField(field))

/// 2×2 のテスト画素（ARGB）。
///   ┌───────────────┬───────────────┐
///   │ (0,0) 赤 255  │ (1,0) 緑 128  │
///   ├───────────────┼───────────────┤
///   │ (0,1) 青 64   │ (1,1) α 255 白│
///   └───────────────┴───────────────┘
def tex2x2(): ShaderEval.TexData =
    // ARGB を 10 進で書く（0xffff0000 などは Int32 の正リテラル範囲を超える）:
    //   -65536 = 0xffff0000（不透明・R=255）、-16744448 = 0xff008000（G=128）、
    //   -16777152 = 0xff000040（B=64）、-1 = 0xffffffff（不透明の白）。
    { width = 2, height = 2,
      pixels = Vector#{ -65536, -16744448, -16777152, -1 } }

/// Tex の CPU 標本（NEAREST の釘打ち）: 四隅の画素中心でチャンネル値が 8bit/255 で出る。
@Test
def testEvalTexSamplesCorners(): Unit \ Assert =
    let env = Map#{ "t" => tex2x2() };
    let at = (u, v, chan) -> {
        let spec: ShaderDoc.Spec = { name = "t", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({
                shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
                alpha = ShaderDoc.Field.Tex({ name = "t", chan = chan }) }) };
        ShaderEval.evalAlphaTex(spec, { x = u, y = v }, 0.0, env)
    };
    Assert.assertEq(
        expected = (255.0 / 255.0, 128.0 / 255.0, 64.0 / 255.0, 255.0 / 255.0),
        (at(0.25, 0.25, ShaderDoc.TexChan.R), at(0.75, 0.25, ShaderDoc.TexChan.G),
         at(0.25, 0.75, ShaderDoc.TexChan.B), at(0.75, 0.75, ShaderDoc.TexChan.A)))

/// Tex の端は張り付き（CLAMP）: u<0 と u>1 は端の texel と同じ値になる（回り込まない）。
@Test
def testEvalTexClampsAtEdges(): Unit \ Assert =
    let env = Map#{ "t" => tex2x2() };
    let spec: ShaderDoc.Spec = { name = "t", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
            alpha = ShaderDoc.Field.Tex({ name = "t", chan = ShaderDoc.TexChan.R }) }) };
    let at = u -> ShaderEval.evalAlphaTex(spec, { x = u, y = 0.25 }, 0.0, env);
    Assert.assertEq(expected = (at(0.25), at(0.75)), (at(-0.5), at(1.5)))

/// Shift の dx/dy は「外側の uv」で評価する: dy = uv.y なので、読み先は (u, y+y) になる。
///   uv=(0.25, 0.25) → 読み先 v = 0.5 → 下段（青 64）を拾う（内側 uv で再評価すると値が変わる）。
@Test
def testEvalShiftUsesOuterUv(): Unit \ Assert =
    let env = Map#{ "t" => tex2x2() };
    let spec: ShaderDoc.Spec = { name = "t", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
            alpha = ShaderDoc.Field.Shift({
                dx = ShaderDoc.Field.Const(0.0),
                dy = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V }),
                of = ShaderDoc.Field.Tex({ name = "t", chan = ShaderDoc.TexChan.B }) }) }) };
    Assert.assertEq(expected = 64.0 / 255.0,
        ShaderEval.evalAlphaTex(spec, { x = 0.25, y = 0.25 }, 0.0, env))

/// shared の先行評価: 座標変換（Shift）の内側で use しても「基準 uv で 1 回評価した値」が返る。
///   binding u0 = uv.x。alpha = Shift(dx=0.5){ use(u0) } — 内側で読み直すなら 0.75 になるはずだが、
///   基準 uv の 0.25 が返る（GL が main 先頭で 1 回計算する挙動が正）。
@Test
def testEvalSharedFrozenAtBaseUv(): Unit \ Assert =
    let spec: ShaderDoc.Spec = { name = "t", cycleRate = 0.0,
        bindings = ("u0", ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U })) :: Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
            alpha = ShaderDoc.Field.Shift({
                dx = ShaderDoc.Field.Const(0.5), dy = ShaderDoc.Field.Const(0.0),
                of = ShaderDoc.Field.Ref("u0") }) }) };
    Assert.assertEq(expected = 0.25, ShaderEval.evalAlpha(spec, { x = 0.25, y = 0.5 }, 0.0))

/// evalPixelAlphaTex は evalPixelTex / evalAlphaTex と同じ (色, α) を返す（委譲がズレない）。
@Test
def testEvalPixelAlphaTexAgrees(): Unit \ Assert =
    let env = Map#{ "glow" => tex2x2(), "mask" => tex2x2() };
    let spec = texSpecOf();
    let uv = { x = 0.75, y = 0.25 };
    let (c, a) = ShaderEval.evalPixelAlphaTex(spec, uv, 0.0, env);
    let c2 = ShaderEval.evalPixelTex(spec, uv, 0.0, env);
    let a2 = ShaderEval.evalAlphaTex(spec, uv, 0.0, env);
    Assert.assertEq(
        expected = (c2#r, c2#g, c2#b, a2),
        (c#r, c#g, c#b, a))

/// tex/shift/rgb の JSON 往復で GLSL がバイト一致する（Gen/Json の 2 面がズレない）。
@Test
def testTexJsonRoundTripGlslIdentical(): Unit \ Assert =
    let spec: ShaderDoc.Spec = { name = "wave_d", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Rgb({
                r = ShaderDoc.Field.Tex({ name = "scene", chan = ShaderDoc.TexChan.R }),
                g = ShaderDoc.Field.Tex({ name = "scene", chan = ShaderDoc.TexChan.G }),
                b = ShaderDoc.Field.Tex({ name = "scene", chan = ShaderDoc.TexChan.B }) }),
            alpha = ShaderDoc.Field.Shift({
                dx = ShaderDoc.Field.Const(0.01), dy = ShaderDoc.Field.Const(0.02),
                of = ShaderDoc.Field.Tex({ name = "mask", chan = ShaderDoc.TexChan.A }) }) }) };
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(spec2) => ShaderGen.compile(spec2) == ShaderGen.compile(spec)
        case Err(_)    => false
    };
    Assert.assertEq(expected = true, same)

/// tex の chan 省略は R になる（fail-open の既定）。
@Test
def testTexJsonDefaultChan(): Unit \ Assert =
    let json = "{\"name\":\"s\",\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#000000\"}," +
               "\"alpha\":{\"kind\":\"tex\",\"name\":\"scene\"}}}";
    let chan = match Util.Json.parse(json) |> Result.flatMap(ShaderJson.parse) {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.Tex(tx) => Some((tx#name, tx#chan))
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some(("scene", ShaderDoc.TexChan.R)), chan)

// ── blur（TexBlur）──

def blurSpec(radius: Float64, amount: ShaderDoc.Field): ShaderDoc.Spec =
    { name = "b", cycleRate = 0.0, bindings = Nil,
      out = ShaderDoc.Out.Fill({
          shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 0.0 }),
          alpha = ShaderDoc.Field.TexBlur({ name = "t", chan = ShaderDoc.TexChan.R,
                                            radius = { x = radius, y = radius }, taps = 16, amount = amount }) }) }

/// 左半分が黒・右半分が白の 2×1 の絵。
def halves(): ShaderEval.TexData = { width = 2, height = 1, pixels = Vector#{ -16777216, -1 } }

/// amount が 0 ならぼかさない（Tex と同じ画素）。境目の上では白黒の間の値になり、境目から半径より遠ければ元の値。
@Test
def testEvalBlurMixesOnlyNearTheEdge(): Unit \ Assert =
    let env = Map#{ "t" => halves() };
    let at = (spec, u) -> ShaderEval.evalAlphaTex(spec, { x = u, y = 0.5 }, 0.0, env);
    let blurred = blurSpec(0.2, ShaderDoc.Field.Const(1.0));
    let still = blurSpec(0.2, ShaderDoc.Field.Const(0.0));
    let mid = at(blurred, 0.5);
    Assert.assertEq(expected = (0.0, 1.0, true, 0.0, 1.0),
                    (at(still, 0.49), at(still, 0.51), mid > 0.25 and mid < 0.75, at(blurred, 0.1), at(blurred, 0.9)))

/// blur の JSON 往復で GLSL がバイト一致し、ぼかしを使う Spec にだけ sg_blur が入る。
@Test
def testBlurJsonRoundTripAndPreludeOnlyWhenUsed(): Unit \ Assert =
    let spec = blurSpec(0.02, ShaderDoc.Field.Time({ scale = 0.5, offset = ShaderDoc.Field.Const(0.0) }));
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(spec2) => ShaderGen.compile(spec2) == ShaderGen.compile(spec)
        case Err(_)    => false
    };
    let has = s -> String.contains({ substr = "sg_blur(" }, ShaderGen.compile(s));
    Assert.assertEq(expected = (true, true, false), (same, has(spec), has(ShaderDoc.demoSurface())))

/// blur の taps と radius と amount を省いた JSON は、24 回・半径 0.01・amount 1 で読む。
@Test
def testBlurJsonDefaults(): Unit \ Assert =
    let json = "{\"name\":\"s\",\"out\":{\"kind\":\"fill\"," +
               "\"shade\":{\"kind\":\"solid\",\"color\":\"#000000\"}," +
               "\"alpha\":{\"kind\":\"blur\",\"name\":\"photo\"}}}";
    let got = match Util.Json.parse(json) |> Result.flatMap(ShaderJson.parse) {
        case Ok(spec) => match spec#out {
            case ShaderDoc.Out.Fill(f) => match f#alpha {
                case ShaderDoc.Field.TexBlur(bl) => Some((bl#name, bl#taps, bl#radius#x, ShaderDoc.texNames(spec)))
                case _ => None
            }
        }
        case Err(_) => None
    };
    Assert.assertEq(expected = Some(("photo", 24, 0.01, List#{"photo"})), got)
