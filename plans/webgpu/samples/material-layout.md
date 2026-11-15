# 書き味の見本: 面と材質の draw ごとの値の並び（5.1・9.1 の表「面と材質の draw ごとの値の並びを誰が決めるか」）

- お題: 2D の面（`ShaderDoc.Spec`。Param を 2 つ・絵を 1 枚読む）と、3D の材質に Param を 1 つ足す。
- GL は今、値を uniform の名前で 1 つずつ渡す（`uTime`・`uAlpha`・`uRectPos`・`uParamN`・`uTexFlipN`・`uTexLevelsN`）。WebGPU は uniform buffer の 1 本に詰める。
- 決めた物: **候補 1（ShaderGen が struct を出し、並びの表も返す）**。欄は全部 f32 にして、並びの順 × 4 バイトがそのまま buffer の中の位置になるようにした。

## 比べの表

| 見る点 | 候補 1: ShaderGen が struct を出す | 候補 2: 前半が決めた並びにシェーダーを合わせる |
|---|---|---|
| 生成した WGSL | `sg.uParam1` と名前で読む。GLSL の uniform と同じ名前なので並べて読める | `sg.v[1].z` と番号で読む。何の値かは表を引かないと分からない |
| 並びの約束が書かれる所 | ShaderGen の 1 か所（struct の字と `slots` を同じ並びから作る） | 前半の並べる関数と ShaderGen の読む式の 2 か所が同じ表を引く |
| 材質に Param を足す時 | ShaderDoc の木に Param を書くだけ（struct と `slots` が増える）。前半は `slots` を順に詰める | 同じ（表が増える）。シェーダーの字は番号の読みが増える |
| 詰める側（backend）のコード | `slots` を前から読み、欄ごとの値を Float32 で詰める 1 つの関数 | 同じ |
| struct の形の数 | Spec ごとに違う（欄の数が違う）。pipeline は Spec ごとに作るので増えない | 欄の数だけ違う（配列の長さ） |
| WGSL の並びの決まり（16 バイトそろえ） | 欄を全部 f32 にすれば「4 バイトずつ前から」で済む。vec2 や vec3 を混ぜると穴が空く | vec4 の配列なので穴は無いが、4 つずつの番号の読みになる |

**決めた理由**: どちらも表は 1 つで、詰める側の手間は同じ。差は生成した WGSL が読めるかで、候補 1 は名前のまま読める。
欄を f32 だけにする決まりで、16 バイトそろえの穴の計算を詰める側に持ち込まない（f32 だけの struct の大きさは欄の数 n × 4 バイト。backend は buffer を roundUp(4n, 16) バイト以上で取る約束にする）。
場面で共通の値（光・影・霧・カメラ）は Spec に依らないので、手で書いた 1 つの struct にする（候補 2 の形。ShaderGen は知らない）。

## 候補 1: ShaderGen が struct を出す（入れた形）

```flix
// ShaderGen.Wgsl.compile(spec) の返す値（engine の pub）。functions = 入口（vs_main・fs_main）を除いた物。
pub type alias SurfaceWgsl = { module = String, functions = String, slots = List[UniformSlot],
                               texReads = List[(String, ShaderDoc.FilterMode)] }

// ShaderGen.Wgsl.UniformSlot
pub enum UniformSlot with Eq, ToString {
    case RectPosX
    case RectPosY
    case RectSizeX
    case RectSizeY
    case Time
    case Alpha
    case TexLevels(Int32)
    case Param(Int32)
}

// 生成した WGSL の頭（Param 2 つ・絵 1 枚の 2D の面）:
//   struct SgValues { uRectPosX: f32, uRectPosY: f32, uRectSizeX: f32, uRectSizeY: f32, uTime: f32, uAlpha: f32, uParam0: f32, uParam1: f32 };
//   @group(0) @binding(0) var<uniform> sg: SgValues;
//   @group(0) @binding(1) var uTex0: texture_2d<f32>;
//   @group(0) @binding(2) var uTex0Sampler: sampler;

// backend の詰める所（P6 の面の小分けで書く。下は形の見本）。
def packSlots(slots: List[ShaderGen.Wgsl.UniformSlot], draw: SurfaceDraw, buf: ByteBuffer): Unit \ IO =
    slots |> List.forEachWithIndex((i, slot) -> discard buf.putFloat(i * 4, valueOf(slot, draw)))
```

## 候補 2: 前半が決めた並びにシェーダーを合わせる

```flix
// 前半（backend に依らない所）が並びを決める。頭の vec4 2 つ = rect・(time, alpha, -, -)、続けて Param を 4 つずつ。
pub def surfaceIndexOf(slot: SurfaceSlot): Int32 = match slot {
    case SurfaceSlot.Time     => 4
    case SurfaceSlot.Alpha    => 5
    case SurfaceSlot.Param(k) => 8 + k
    ...
}

// ShaderGen は番号で読む式を出す: struct SgValues { v: array<vec4f, N> };
def slotRead(slot: SurfaceSlot): String =
    let k = surfaceIndexOf(slot);
    "sg.v[${k / 4}]." + (match k mod 4 { case 0 => "x" case 1 => "y" case 2 => "z" case _ => "w" })
// 生成した字: (sg.v[2].x * 0.5) + sg.v[1].x  — どれが Param でどれが time かは表を引いて読む
```
