# 書き味の見本: mask（stencil の比べる値を進める形・R1b-4）

mask つきスプライトは、mask の多角形を stencil に書いてから、その内側だけスプライトを描く（draw 2 回）。GL は前から mask ごとに stencil を clear して値 1 で書いていたが、
WebGPU は pass の途中で stencil だけを clear できない。そこで親 8 章のとおり、1 つの pass の中で mask ごとに比べる値（ref）を 1 ずつ進める（前の mask が書いた値はどれも今の値より小さいので、
0 に戻さなくても取り違えない）。値は 8 bit なので 255 の次は 1 に戻り、その前に stencil を 0 に戻す。

決める所は 2 つ。どちらも 2 案を両方動かし、`bench/webgpu_v1` の mask の 5 場面（`maskBasic`・`maskNested`・`maskPass`・`maskMsaa`・`maskOverflow`）を GL と比べた（この Mac・Dawn の Metal・2026-11-15）。
別案のコードは commit していない。速さは人の方針（12.16）で測っていない。

## 1. 比べる値を誰が進めるか: 前半（入れた形）／backend

| 見る点 | (a) 前半が行に書く | (b) backend がそれぞれ数える |
|---|---|---|
| 動かした結果 | 5 場面とも GL と 0 px | 5 場面とも 0 px（行の 11 番は「stencil を使うか」だけにし、GL は gs・WebGPU は geom に前の値を持った） |
| 決まりの置き場 | `RenderList.nextMaskRef` 1 か所。呼ぶのは前半の `pushMaskedItem` だけ | 同じ関数を GL と WebGPU の backend が別々に呼び、前の値を backend の状態に 1 つずつ持つ |
| GPU の無いテスト | 256 個積んだ行の 11 番を読むだけで、255 の次が 1 に戻るのを見られる（`TestMaskRows`） | backend ごとに偽の GL か Dawn を通さないと見られない |
| WebGPU が stencil つきの pass を開くか | 前半の状態（`usesStencil`）で決まる | 同じ物が要る（行を作る時に分かる事なので、どちらにしても前半が持つ） |
| GL の mask つきの面（GL を直に呼ぶ）の後 | 前半の状態を 0 にする（次の mask の前に stencil を 0 に戻させる） | GL の backend の状態を 0 にする |

```flix
// (a) 前半: mask 1 体を行にする時に値を進める（Frame.pushMaskedItem）。backend は行の 11 番をそのまま使う。
let ref = if (maskCount == 0) 0 else nextMaskRef(Array.get(maskRefSlot(), st));
appendMaskRow(list, instanceAt, maskFirst, maskCount, texId, blendCode(blend), clipFlag, x0, y0, x1, y1, ref)

// (b) backend: 行を流す時に数える（GL の drawMaskRow。WebGPU も geom の 27 番で同じ物）。
let ref = if (rowAt(rows, row, 11) == 0) 0 else { let r = RenderList.nextMaskRef(Array.get(20, gs)); Array.put(r, 20, gs); r };
```

**(a) に決めた。** 決まりが 1 か所で、GPU 無しのテストで固定できる（R1b-1 の寿命の表・R1b-3 の history と同じく「前半が決め、backend は答えを実行する」）。
形のレビュー（2D）の 3.1 の 9 は「比べる値を進めるのは backend の中」と書いていたが、動かした 2 案で絵は同じで、上の理由で前半へ寄せた。

## 2. 255 を超えた時に WebGPU で stencil を 0 に戻す形: pass の中で全面を描く（入れた形）／pass を閉じて開き直す

| 見る点 | (a) design の全面の 6 頂点を「stencil へ値 0 を書く pipeline」で描く | (b) pass を閉じ、色は前の中身のまま・stencil は clear で開き直す（親 8 章の案） |
|---|---|---|
| 動かした結果 | 5 場面とも 0 px | 5 場面とも 0 px |
| 足した物 | `WebGpuRows.resetStencil` 17 行・全面の 6 頂点の buffer（`createResetQuad` 15 行）・`setVertices` の 1 行。pipeline は mask を書く物と同じ | 行の列を値 1 の行で区切り、区切りごとに開き直す 22 行（試しの形）。ちゃんと入れるには、画面の pass を「前の中身のまま」で開く形（今の `PassSpec` の `Screen` は clear しか持たない）と、geom の控えを全部戻す関数が要る |
| 1 コマの pass | 増えない（draw が 1 本増える） | 255 個ごとに 1 本増える。標本つきの描き先は閉じるたびに resolve する |
| 1 枚の pass の中で | viewport・積んだ pipeline と buffer の控え・黒帯の箱はそのまま | 開き直すたびに viewport と控えを張り直す |

```flix
// (a) 値 1 の mask の前に、pass を開いた後で stencil へ書いていれば 0 に戻す（WebGpuRows.drawMaskRow）。
if (ref == 1 and Array.get(25, geom) == 1) resetStencil(pass, geom, setPipeline, setVertices, setValues) else ();
//   resetStencil: scissor を全面に・ref 0・mask を書く pipeline・全面の 6 頂点を draw

// (b) 値 1 の行（頭の 1 つを除く）で行の列を区切り、区切りごとに pass を開き直す。
let cuts = List.filter(r -> rowAt(rows, r, 0) == kindMask() and rowAt(rows, r, 11) == 1, List.range(0, n)) |> List.drop(1);
//   区切りごとに p.end() → cfg#openPass(色は Keep・stencil は clear) → setViewport → geom の控えを -1 へ → drawRowsFrom
```

**(a) に決めた。** pass が増えず、開き直す道（前の中身のままの画面の pass・控えの張り直し・区切りごとの resolve）を持たずに済む。
`maskOverflow`（同じ場所に 300 体・mask は升目の 1 つずつ）で、0 に戻す所を消すと 540 px・最大 ±129 違う（256 体目から 300 体目の色が 1〜45 体目の升にも出る）事を確かめた。
GL は値 1 の行の前で `glClear(STENCIL_BUFFER_BIT)` を呼ぶ（scissor を外してから）。

## 3. 比べていない物

- mask を書く draw で色を変えない形: blend を (0, 1) にした（色は前の値のまま）。色の書き込みの mask を 0 にする形は、`render_gl/java` の `RenderPipelineDesc` に口が無く、足すと GL の層の jar のハッシュとブラウザの実装が動くので試していない。
- 行の形: mask つき 1 体 = 1 行（mask の頂点の範囲と比べる値を同じ行に持つ）。「stencil に書く行」と「比べるスプライトの行」の 2 行に分ける形は試していない（面に mask を付ける時に、比べる値をスプライト以外の行にも持たせるかと一緒に決める）。
