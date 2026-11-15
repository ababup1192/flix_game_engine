# 書き味の見本: 面（ShaderDoc の面を行にする・R1b-6）

面は `ShaderDoc` から作る 2D の矩形 1 枚で、Spec ごとに別のシェーダー（GL は GLSL・WebGPU は `ShaderGen.Wgsl` の WGSL）を使う。
draw ごとの値（rect・time・alpha・params）の並びは Spec ごとに長さが違い、WGSL では `ShaderGen.Wgsl` が `var<uniform> sg: SgValues` として出す（12.17）。
R1b-6 で面を `RenderList` の行（`kindSurface`）にし、GL と WebGPU の backend が同じ行を流すようにした。決める所は 3 つ。
どれも別案を動かして `bench/webgpu_v1` で比べた（この Mac・Apple M4 Pro・Dawn の Metal・2026-11-15）。別案のコードは commit していない。

## 1. 面の値をどこに置き、WebGPU でどう読むか

行の 11 番が values（前半の Float32 の配列）の先頭を指し、そこから rect 4・time・alpha・params の順に書く（`SgValues` の欄と同じ順）。
WebGPU は values の buffer を頂点の buffer（タイルと static の値）としてだけでなく uniform としても bind し、面ごとにその位置から読む。

| 見る点 | (a) values に置き、面ごとに 256 バイトの倍数の位置で uniform として読む（入れた形） | (b) 面だけの uniform の buffer（4 本目の Stream） | (c) storage にして instance の番号で引く |
|---|---|---|---|
| bind の位置 | 前半が面の値を 64 個（256 バイト）の倍数へそろえ、backend は送る位置を 256 バイトにそろえる | 同じく 256 バイトの倍数（static offset の uniform はどれも同じ決まり） | 4 バイト刻みでよい |
| 余る bytes | 面 1 枚 256 バイト（中身は 24 + 4 × params） | (a) と同じ | 無し |
| 送る回数 | values と 1 回 | 4 本目の分が 1 回増える（`planUpload` の本も 4 本に） | — |
| 変える所 | render_gl の中だけ | render_gl の中だけ | `ShaderGen.Wgsl` の `var<uniform>` を `var<storage>` に（engine の変更） |

**(a) に決めた。** (b) は bytes が同じで本が 1 本増えるだけ、(c) は engine の変更（相談事）。面 200 枚の場面で余る bytes は 1 コマ 約 45 KB。

```flix
// 前半（RenderList.appendSurfaceRow）: 値を 64 個の倍数の位置へ書き、行の 11 番にその位置。
let (values, at) = reserveAlignedValues(list, 6 + List.length(params), surfaceValueAlign());
// WebGPU（WebGpuSurfaces.draw）: values の buffer の (送った位置 + 4 × at) から、SgValues の大きさ（16 の倍数）を group 0 の 0 番に。
let desc = new BindGroupDesc("fge surface", layoutOf(surfaces, program#reads)).buffer(0, values, Int32.toInt64(bytes), Int32.toInt64(size));
```

## 2. bind group を draw ごとに作るか、控えて使い回すか

面の group 0 は値の位置と読む絵の組で決まる。(a) draw ごとに作って submit の後に手放す（入れた形）・(b) (位置・buffer・絵の番号) を鍵に控えて使い回す。

| 見る点 | (a) draw ごとに作る | (b) 控えて使い回す |
|---|---|---|
| 面 200 枚（絵 1 枚を読む・同じ Spec）の 1 コマ（300 コマの平均） | 645〜846 µs | 535〜744 µs |
| 絵や buffer を捨てる・作り直す時 | 何もしない（draw の物は submit の後に手放す） | 控えを外す決まりが要る。外さずに動かすと `surfaceMask` が 592 px 違った（作り直した buffer の古い group を読んだ） |
| 位置が動く時 | 何もしない | 前の行の values の数で位置が動くたびに控えが増える（古い物を捨てる決まりが要る） |

**(a) に決めた。** 差は 1 面あたり 0.5 µs ほどで、測る回ごとの揺れ（同じ形で 645 と 846）より小さい。控える形の正しさの決まりの方が重い。
ブラウザで JS の物を作る代金は測っていない（P10 の前の計測で、面の多い画面が重ければ (b) を足す）。

## 3. pipeline を draw ごとに作るか、鍵で控えるか

| 見る点 | (a) program × blend × 形式 × 標本 × stencil の鍵で控える（入れた形） | (b) draw ごとに作る |
|---|---|---|
| 面 200 枚の 1 コマ | 645〜846 µs | 1,065〜1,294 µs（Dawn は同じ形の pipeline を中で使い回すので、ここでは差が小さい） |
| ブラウザ | 同じ | 1 本 65〜93 ms（4.3 の試作）なので使えない |
| 違う Spec 200 個を初めて描くコマ | 38.8 ms（WGSL の組み立てと shader module と pipeline を 200 回） | 同じ |

**(a) に決めた。** 初めて描くコマが詰まる事（8 章の「コマの途中で同期では作らない」）は持ち越し（P10）。

## 4. mask つきの面の stencil の比べる値

| 見る点 | (a) mask つきスプライトと同じく前半が進めて行の 10 番に書く（入れた形） | (b) 面は毎回 stencil を 0 に戻して 1 を書く（R1b-5 までの GL の形） |
|---|---|---|
| 動かした結果 | 面の 6 場面とも GL と 0 px | 6 場面とも 0 px（前半は面で値 1・前の値を 0 に戻す） |
| WebGPU の draw | 戻すのは pass の頭か 255 を使い切った後だけ | 面ごとに 1 本（design の全面の draw）と、面の後の最初の mask つきスプライトの前に 1 本。`surfaceMask` で 3 本増える |
| 前半の決まり | `nextMaskRef` 1 本（スプライトと面で同じ） | 面の後で前の値を 0 にする枝が残る |

**(a) に決めた。** 12.20 の持ち越し「面に mask を付ける時、比べる値を面の行にも持たせるか」の答え。
