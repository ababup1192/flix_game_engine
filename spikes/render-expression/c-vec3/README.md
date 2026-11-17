# スパイク (c): `ShaderDoc.Field` に vec3 を足すと木はどれだけ減るか

`plans/webgpu/analysis-render-structure.md` の「決める前に小さく試す事 3」。engine は書き換えていない。
今の Spec を JSON（`ShaderJson.toJson`）に出し、`vec3count.py` の決まりで vec3 の木に括った時の節の数を数えた。

## 入力

- lamplighter の後がけ 4 本（スパイク (a) の写しに `PostStack.dumpSpecs` を足して出した。`inputs.txt` の SPEC 行）
- テンプレの材質 3 本（tidepool-starter の rock・water・caustics）・ws の材質 2 本（pbr_room・plateau_city）
- スパイク (b) の SSAO の 2 本（暗さ・最後の面）

## 結果（`python3 vec3count.py inputs.txt`）

| Spec | 今の節 | vec3 で括った節 | 減り |
|---|---|---|---|
| 後がけの本編（DoF・ブルーム・ビネット・ACES・彩度） | 246 | 78 | 68% |
| 明るい所の抜き出し | 30 | 12 | 60% |
| ぼかし | 12 | 6 | 50% |
| FXAA（engine の `PostProcess.fxaaSpec`） | 408 | 190 | 53% |
| 材質 5 本（rock・water・caustics・pbr_room・plateau_city） | 77 | 77 | 0% |
| SSAO の暗さ | 3,153 | 3,151（機械の決まりでは括れない） | 0%（手の見積もりは下） |
| SSAO の最後の面 | 15 | 9 | 40% |

- 後がけは 696 → 286（59% 減）。束ね（shared）は本編で 12 → 6。
- 材質は 0%: どれもスカラーの場を `Ramp`・`Gradient` で色にしていて、色を 3 回書いていない。
- SSAO の暗さが減らないのは、3,000 節の大半が「読む点 12 個 × 同じ式 約 250 節」の写しだから。
  vec3 で内積を 1 節にすると 1 点の式が約 250 → 約 200 節（約 2 割）【推】。
  **効くのは vec3 ではなく、読む点の中の局所の束ね（let）か、決まった回数の輪（taps）のノード**で、
  あれば 1 点の式を 1 回だけ持てて 3,153 → 約 400 節（約 87% 減）【推】。

## 手で書く量

ws の 16 本の src に `chan ->` が 77 か所・`Shade.Rgb(` が 97 か所・`luma709` が 16 か所（字の数え）。
vec3 の `Tex`（rgb を一度に読む）・vec3 の算術・`dot`（luma は `dot(c, 定数)`）があれば、
`chan ->` の 3 回当ては全部消える（色の式を 1 本で書ける）。

## engine の中の手本

`LightModel3d.Vec3Expr` は既に vec3（`Make`・`Add`・`Scale`・`Mix`）・`Let`・決まった回数の輪（`SumPoints`・`SumSpots`）を持つ。
`ShaderDoc` に vec3 と let と taps を足す時は、この形と生成器に寄せられる（式の木を 1 本へ寄せる一歩）。

## 確かめていない所

- `eqSpec` の時間と生成した GLSL・WGSL の行の前後（vec3 を実装していないので測れない）【未確認】。
- 括り方は機械の決まり（字の上で同じ形）。r・g・b で定数が違う式（色ずらし）は括れず、ここでは今のまま数えた。
