# 書き味の見本: draw ごとの値の置き場（R1b-2・多角形とタイルと static layer）

タイルの層（position・tileSize・tileScale・color の 8 個）と static layer の範囲（viewOffset・viewScale・halfDesign の 6 個）は、
スプライトと違って 1 体ごとの値でなく **draw ごとの値**を持つ。GL は uniform で差し、WebGPU は draw の間に uniform を書き替えられない（`writeBuffer` は submit の前にまとめて効く）。
決める所は 2 つ: (1) 前半が `RenderList` のどこに置くか（9.1 の表の「1 行の欄と高さ」の続き）・(2) WebGPU の backend がそれをどう shader へ渡すか。

- 比べた場面: `bench/webgpu_v1` の `polygons`・`polygonPass`・`tiles`・`staticLayer`（GL と Dawn の Metal を画面なしで比べる。2026-11-15・Apple M4 Pro）。
- 速さは比べない（人の方針・12.16）。1 コマのタイルの層と static の範囲は数個〜数十個で、1 体ごとに通る所（`emitSprite`）は触っていない。

## (1) 前半の置き場

| 見る点 | (1a) `values`（Float32 の配列・前半の持ち物）と行の欄 12 | (1b) 行は元の record の番号だけ持ち、record の列を横に置く |
|---|---|---|
| 前半 | 行を足す所で 6 / 8 個を詰める（`appendTileRow`・`appendStaticRow` 合わせて 34 行） | 行に番号を書くだけ（約 10 行）。record の列（`Array[Merged]`）を list に足す |
| GL の backend | `values` の位置を読んで `uniform2f` に渡す（`usePolyProgram`・`drawTileMapInstanced` の 10 行） | record の欄を読んで `uniform2f`（今と同じ。欄の引きは行ごと） |
| WebGPU の backend | `values` を 1 本の buffer へ `writeBuffer` 1 回 | record の欄を読んで float に詰め直す所が要る（約 20 行）。詰め方が GL と別の所に 2 本目としてできる |
| 多角形の view | 頭の 6 個をいつも「identity の view」にして、多角形と static が 1 本の式（shader 1 本・GL の関数 1 本）になる | identity の view の 6 個を backend ごとに持つ |
| P9（持ち越す list）・JS へ 1 回で渡す形（3.5） | 行と values はどちらも素の配列で、そのまま持ち越せる・渡せる | record の列が混ざり、どちらにも乗らない |

**(1a) に決めた。** 形のレビュー（2D）の 3.1 の 8（`values`）に沿う。行の欄は 10 → 12（10 = 頂点の buffer の番号・11 = values の先頭）。

```flix
// (1a) 前半: タイルの層 1 つを行と values にする（RenderList.appendTileRow）
let (values, at) = reserveValues(list, tileValueFloats());
Array.put(layer#posX, at + 0, values);   // … 8 個
putRow(rows, n, kindTile(), 0, count, texId, 0, 0, 0, 0, 0, 0, buffer, at)
// GL: 行の 11 番の位置から uniform を差す
gl.uniform2f(Array.get(locAt, locs), Array.get(at, values), Array.get(at + 1, values));
// WebGPU: values をコマに 1 回送り、行ごとに位置だけ替える
setValues(pass, valuesBase + 4 * rowAt(rows, row, 11))
```

```flix
// (1b) 見本（入れていない）: 行は record の番号だけ
Array.put(Array.length(sideItems), at + 11, rows);  sideItems = Merged.MTile(tm) :: …
// WebGPU: 行ごとに record をほどいて float に詰め直す（GL とは別の 2 本目）
match Vector.get(rowAt(rows, row, 11), sideItems) {
    case Merged.MTile(tm) => putFloats(staging, tm#position#x, tm#position#y, tm#tileSize, …)
    case Merged.MStatic(r) => putFloats(staging, r#viewOffset#x, …)
    case _ => ()
}
```

## (2) WebGPU で draw ごとの値を shader へ渡す形

| 見る点 | (2a) stride 0 の instance の頂点の buffer（入れた形） | (2b) uniform の buffer を 256 バイトの枠に割り、枠ごとの bind group を作り置く | (2c) dynamic offset の uniform |
|---|---|---|---|
| 行ごとに積む物 | `setVertexBuffer(1, values, 位置)`（4 バイト刻み） | `setBindGroup(2, 枠 i の group)` | `setBindGroup(2, group, [offset])` |
| 前に作る物 | 無し（values の buffer 1 本） | 枠の数だけ bind group（コマの draw の数で増える・作り直しは buffer を伸ばした時） | 無し |
| 詰め方 | values をそのまま（6 / 8 個を詰めたまま） | 1 draw 256 バイト（`minUniformBufferOffsetAlignment`）。タイル 8 個 = 32 バイトに 224 バイトの穴 | 同じ 256 バイト刻み |
| 道具の口（`render_gl/java` の `WebGpu`） | 今の口で足りる（`vertexBuffer(0, true)` を足すだけ） | 今の口で足りる | `setBindGroup` に offset の列を足す。GL の層の jar のハッシュが動き、ブラウザの JSO の実装（engine_web）にも足す |
| 試した | **Dawn の Metal で 5 場面とも GL と 0 px・WebGPU の誤り 0**（`bench/webgpu_v1`）。形だけの門 `stride0-instance-attribute`（`bench/webgpu_check`・offset を替えた 2 draw・firstInstance 3 でも同じ要素）は PC の Dawn と headless の Chrome で通った。前に作る物 0・行ごとに積むのは `setVertexBuffer` 1 回 | 形だけの門 `uniform-slot-bind-groups`（`bench/webgpu_check`・8 draw）を PC の Dawn と headless の Chrome で通した（色は期待と ±1 の内・誤り 0）。**bind group 8 個（draw の数と同じ）・uniform は 1 draw 256 バイト**（中身は 20 バイト）。行ごとに積むのは `setBindGroup` 1 回 | 試していない（道具の口が変わるので捨てた） |
| 危ない所 | stride 0 は WebGPU の仕様で許された形（同じ要素を全部の instance が読む）。**通したのは Dawn の Metal と headless の Chrome（Metal）だけ**で、Safari と Firefox（wgpu の Metal での stride 0）は【未確認】。ブラウザで多角形とタイルの絵を GL と比べる門はまだ無い | bind group の数が 1 コマの draw の数を追い、buffer を伸ばすたびに全部作り直す。256 バイトの枠に穴が空く | 道具の口の変更 |

**(2a) に決めた。** 両方とも動いたうえで、(2a) は道具の口を変えず、作り置きの物も無く、詰め方も前半の並びのまま（(2b) は 1 コマの draw の数だけ bind group を持ち、値の 12 倍の bytes を送る）。shader の側は `@location(2..)` の属性で受けるだけ。

```wgsl
// (2a) 多角形: view を stride 0 の instance の buffer（頂点の buffer の 1 番）の属性で受ける
@vertex fn vs_main(@location(0) vertex: vec2f, @location(1) vColor: vec4f,
                   @location(2) viewOffset: vec2f, @location(3) viewScale: vec2f, @location(4) halfDesign: vec2f) -> VsOut
```
```flix
// pipeline: 頂点（24 バイト）と view（stride 0・instance）の 2 本
discard desc.vertexBuffer(24, false).attribute(VertexFormat.FLOAT32X2, 0, 0).attribute(VertexFormat.FLOAT32X4, 8, 1);
discard desc.vertexBuffer(0, true).attribute(VertexFormat.FLOAT32X2, 0, 2).attribute(VertexFormat.FLOAT32X2, 8, 3).attribute(VertexFormat.FLOAT32X2, 16, 4);
```
```flix
// (2b) 見本（backend には入れていない。形だけは bench/webgpu_check の checkUniformSlots で動かした）: 枠 i ごとの bind group を作り置き、行ごとに選ぶ
def slotGroup(paint: Paint, i: Int32): BindGroup \ IO = match Map.get(i, Ref.get(p#slotGroups)) {
    case Some(g) => g
    case None    =>
        let g = p#gpu.createBindGroup(new BindGroupDesc("fge draw values", p#valuesLayout).buffer(0, uniforms, Int32.toInt64(256 * i), 32i64));
        Ref.put(Map.insert(i, g, Ref.get(p#slotGroups)), p#slotGroups);
        g
}
// values を 1 draw 256 バイトに広げて送り直し、行ごとに setBindGroup(2, slotGroup(paint, 行の枠))
```

## 頂点の buffer の寿命（比べていない・R1b-1 の決まりに載せた）

タイルの層の instance の buffer と static layer の頂点の buffer は、R1b-1 で決めた「表は前半・作る消すだけ backend」に載せた（`samples/gpu-lifetime.md`）。
入れ直すか作るか（`TileTable.update`）・鍵が替わったら古い方を捨てて作り直す（`RenderStatic.resolve`）は前半の 1 か所で、backend は `TileAllocator{create, write, destroy}`・`StaticAllocator{create, destroy}` を渡す。
GPU を呼ばない allocator のテスト 10 本（`TestShapeBuffers`）で両方の backend の振る舞いを固定する。
