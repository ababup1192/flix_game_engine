# 書き味の見本: WGSL の出し方（7 章・9.1 の表「WGSL の出し方」）

- お題: `ShaderDoc.Field` の 3 つの節（`Angle`・`TexSize`・`Tex`）と、binding の宣言の 1 文を GLSL と WGSL の両方で出す。
- 数字は 2026-11-15 のこの worktree の `engine/src/shader/ShaderGen.flix`（1,299 行）で数えた物。
- 決めた物: **(a) 小さな書き手を挟む**。理由は表の下。

## 比べの表

| 見る点 | (a) 書き手を挟む | (b) WGSL 用に 2 本目を書く | (c) GLSL を naga / Tint で WGSL に訳す |
|---|---|---|---|
| ShaderGen の増え方 | 式の組み立て（`fieldExpr` ほか 257 行）は 1 本のまま。言葉で違う所（`atan`・`textureSize`・`texture`・`textureLod`・宣言の頭・端が定数の `smoothstep`）を小さな関数へ寄せる。前置き（ノイズの関数 130 行）は WGSL で 1 本書き足す | `fieldExpr`・`shadeExpr`・`gradientExpr`・`hashCoord`・`negPowExpr`・`powProduct`・`outStmt`・`bindingStatements` の写し（約 320 行）+ 前置き 130 行 | ShaderGen は変わらない。訳す道具を PC とブラウザの両方に持つ |
| 式の行（ExprRows）の通り方 | 式の字は GLSL と同じ所から出るので、GLSL で通った突き合わせがそのまま WGSL の式の正しさの裏付けになる。WGSL で別に確かめるのは前置きと、言葉で違う小さな関数だけ | 節ごとに 2 本の式が別れて育つ。節を足すたびに GLSL・WGSL・CPU の 3 つを突き合わせる | 訳した字は人が読まない。誤りの行が元の GLSL のどこか分かりにくい |
| 節を 1 つ足す時 | 1 か所に書く（今と同じ） | 2 か所に書く。片方を忘れても型検査では止まらない | 1 か所 |
| ブラウザ | 同じ Flix のコードが TeaVM で動く | 同じ | ゲームの `ShaderDoc` は走りながら変わる（Studio の保存即反映）ので、訳す道具を wasm で運ぶ事になる（naga の wasm で数 MB【推】） |
| 試した事 | `allKinds`（Field の全部の種類）と 5 種類の Shade を (a) で出し、PC の Dawn で組んだ（テスト `TestWgslDawn`） | `Angle`・`TexSize`・`Tex` の 3 節を下のとおり書いた。3 節で 27 行。全部で約 320 行の見込み | jWebGPU（webgpu.h）の `createShaderModule` が受けるのは WGSL と SPIR-V だけで、GLSL を渡す口が無い。Tint が GLSL を読めるかは【未確認】（読めても webgpu.h の外）。この Mac に naga・glslang は無い |

**決めた理由**: (b) は式の木の 257 行を写すことになり、節を足すたびに 2 か所を直す。(c) はブラウザに訳す道具を運ぶ。(a) は言葉で違う所だけを関数に寄せれば済み、
GLSL の字は 1 文字も変わらない（スナップショットのテストがそのまま門になる）。前置き（ノイズの関数）と手書きの式は文の形（`var`・`for`・型の付け方）が違うので、
書き手を文の高さまで広げず、WGSL で書き足す（7 章の「手書きの式は WGSL で書き直す」のとおり）。

## (a) 書き手を挟む（入れた形）

```flix
// 式の組み立ては 1 本（ShaderGen.fieldExpr）。言葉で違う所だけを、表の鍵 @mode:wgsl を見る小さな関数に寄せる。
case ShaderDoc.Field.Angle(an) =>
    "(" + atan2Name(tex) + "((" + uv + ").y - " + f(an#cy) + ", (" + uv + ").x - " + f(an#cx) + ") * 0.15915494 + 0.5)"
case ShaderDoc.Field.TexSize(ts) => ... case Some(i) => texSizeCall(i, tex) + axis + ")"
case ShaderDoc.Field.Tex(tx)     => markRead(texReadCall(i, uv, tex)) + chan

def atan2Name(tex: Map[String, Int32]): String = if (isWgsl(tex)) "atan2" else "atan"

/// 寸法を float で読む式の頭（閉じ括弧は呼ぶ側）。
def texSizeCall(i: Int32, tex: Map[String, Int32]): String =
    if (isWgsl(tex)) "f32(textureDimensions(uTex${i}, 0)" else "float(textureSize(uTex${i}, 0)"

// binding の宣言: GLSL は "float sg_b_x = …;"・WGSL は "let sg_b_x = …;"
let line = floatBindingHead(tex) + "sg_b_" + name + " = " + fieldExpr(field, uv, env, tex) + ";";

// 出口: ShaderGen.Wgsl.compile(spec)#module（2D の面）・ShaderGen.Wgsl.compile3d(spec, emission, metallicRoughness, group)（3D の材質の部品）
```

## (b) WGSL 用に 2 本目を書く（試した 3 節）

```flix
def fieldWgsl(field: ShaderDoc.Field, uv: String, env: Map[String, String], tex: Map[String, Int32]): String =
    match field {
        case ShaderDoc.Field.Angle(an) =>
            "(atan2((" + uv + ").y - " + f(an#cy) + ", (" + uv + ").x - " + f(an#cx) + ") * 0.15915494 + 0.5)"
        case ShaderDoc.Field.TexSize(ts) =>
            let axis = match ts#axis {
                case ShaderDoc.Axis.U => ".x"
                case ShaderDoc.Axis.V => ".y"
            };
            match Map.get(sizeKey(ts#name), tex) {
                case Some(i) => "f32(textureDimensions(uTex${i}, 0)" + axis + ")"
                case None    => "0.0"
            }
        case ShaderDoc.Field.Tex(tx) =>
            let i = Map.get(tx#name, tex) |> Option.getWithDefault(0);
            let chan = match tx#chan {
                case ShaderDoc.TexChan.R => ".r"
                case ShaderDoc.TexChan.G => ".g"
                case ShaderDoc.TexChan.B => ".b"
                case ShaderDoc.TexChan.A => ".a"
            };
            markRead("textureSampleLevel(uTex${i}, uTex${i}Sampler, (" + uv + "), 0.0)") + chan
        // …ほかの 37 節は GLSL の節と同じ字（Smoothstep・Mix・Bin・Pow …）を写す
    }
```
