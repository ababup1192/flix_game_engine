# 書き味の見本: history と MSAA の resolve（表の 8 行目の 3 つ目の種類・R1b-3）

決める所は 3 つ。どれも 2 案を両方動かし、`bench/webgpu_v1` の 20 場面（足した history の 3 場面と MSAA の 4 場面を含む）を GL と比べた（この Mac・Dawn の Metal・2026-11-15）。
別案のコードは commit していない（差分は手元に置いて捨てた）。速さは人の方針（12.16）で測っていない。数えたのは 1 コマに積む pass の数と、行数（doc のコメントを含む）。

## 1. history の持ち方: 毎コマ写す（入れた形）／2 枚を入れ替える

| 見る点 | (a) 写す | (b) 入れ替える（ping-pong） |
|---|---|---|
| 動かした結果 | 20 場面とも GL と 0 px | 20 場面とも 0 px（入れ替えは LoadOp が Clear の時だけ。Keep の描き先は写す道のまま） |
| 道の数 | 1 本（LoadOp に関わらず写す） | 2 本（Keep は前のコマの絵から描き足すので写しが要る） |
| 名前 → 表の番号 | コマの間で変わらない | 毎コマ入れ替わる。標本つきの描き先（WebGPU の `msaaTargets`）を新しい番号へ付け替える行が要った。GL は `RenderTargetGl.Entry` が標本つきの FBO を持つので、Entry を割る作り替えが要る（GL は試していない・約 30 行【見積もり】） |
| 行数（足した分） | 前半 `historyFor` 13・GL `applyHistory` 12・WebGPU `applyHistory`・`copyInto`・`copyPipelineOf` 40 | (a) に足して前半 `swapHistory` 17・WebGPU 8 |
| 1 コマの pass | 読む描き先ごとに写す pass 1 本 | Clear の描き先は 0 本 |

```flix
// (a) 前半は「読むなら pass を開く前に写す」を答えるだけ（TargetTable.historyFor）。backend は答えをそのまま実行する。
let history = TargetTable.historyFor(allocator, textures, p#targets, design, spec, TargetTable.spritesReadHistory(spec#name, frame#sprites), true);
applyHistory(paint, slot#texture, row#format, history)   // CopyTo(n) = 写す・ClearTransparent(n) = 透明で塗る・NoHistory = 何もしない

// (b) Clear の描き先だけ表の番号を入れ替え、標本つきの描き先を付け替える（Keep は (a) のまま）。
let swap = reads and (match spec#clear { case RenderTarget.LoadOp.Keep => false; case _ => true });
let history = if (swap) {
    TargetTable.swapHistory(allocator, textures, p#targets, design, spec)
        |> Option.forEach(match (before, after) -> Map.get(before, Ref.get(p#msaaTargets)) |> Option.forEach(msaa ->
               Ref.put(Map.insert(after, msaa, Map.remove(before, Ref.get(p#msaaTargets))), p#msaaTargets)));
    PassHistory.NoHistory
} else TargetTable.historyFor(allocator, textures, p#targets, design, spec, reads, true);
```

**(a) に決めた。** 道が 1 本で、名前の表の番号がコマの間で動かない（標本つきの描き先や GL の Entry を付け替えない）。
(b) の得は Clear の描き先で写す pass が 1 本減る事で、描き先の画素の数ぶんの読み書き（Window の基準の HDR なら 1920 × 1080 × 8 バイト）。P10 の前の計測で写しが見えたら、(b) を Clear の描き先だけに足す。

## 2. MSAA の resolve の時: pass の終わりごと（入れた形）／endTarget で 1 回

| 見る点 | (a) pass ごと（`ColorAttachment#resolveTo`） | (b) endTarget で 1 回 |
|---|---|---|
| 動かした結果 | 0 px | 0 px |
| WebGPU | pass の `resolveTarget` に 1 標本の texture を付けるだけ（1 行） | endTarget で、標本つきの描き先を読み直して resolve するだけの空の pass を 1 本積む（13 行） |
| GL | blit を `endTarget` から `paintTarget` の pass の終わりへ移し、続けて描けるように標本つきの FBO を bind し直す | 前のまま |
| 1 コマの pass（標本つきの描き先 1 枚） | 1 本 | 2 本 |

```flix
// (a) 前半が pass の指定で決める（RenderList.targetPass が samples > 1 の時だけ resolveTo を入れる）。
if (Option.isEmpty(msaa)) () else discard desc.resolveTo(texture.defaultView());          // WebGPU の openPass
match (entry, RenderList.resolveTargetOf(pass)) { case (Some(e), Some(_)) => { RenderTargetGl.resolve(gl, e); RenderTargetGl.bind(gl, e) } case _ => () }  // GL

// (b) 閉じる時に空の pass で写す（WebGPU）。
let pass = encoderOf(paint).beginRenderPass(new RenderPassDesc("fge resolve").loadColor(msaa.defaultView()).resolveTo(slot#texture.defaultView()));
pass.end()
```

**(a) に決めた。** WebGPU で pass が 1 本で済む（タイルで描く GPU では、標本つきの描き先をもう 1 回メモリから読む分が無い）。
開いている描き先は読めない決まりなので、resolve を pass の終わりへ寄せても読む側から見える絵は同じ。1 回の begin〜end に renderCommands が 2 回来る描き方では resolve が 2 回になる（今のゲームには無い）。

## 3. WebGPU で history へ写す道具: 描いて写す（入れた形）／encoder の copyTextureToTexture

| 見る点 | (a) present と同じ WGSL の全面の三角形で描く | (b) `CommandEncoder.copyTextureToTexture` |
|---|---|---|
| 動かした結果 | 0 px | PC の Dawn で 0 px（ブラウザの実装は書いていない） |
| 変わる所 | render_gl の Flix だけ（形式ごとの pipeline 1 本・写すたびの bind group） | `render_gl/java` の `CommandEncoder` と Dawn の実装 24 行・ブラウザの `BrowserObjects`・描き先の texture に `COPY_DST`・GL の層の jar のハッシュ（`make gl-jar-pin` と Release の置き場） |
| Flix の行 | `copyInto` 13・`copyPipelineOf` 14 | `copyInto` 2 |

**(a) に決めた。** 絵は同じで、jar とブラウザの実装を動かさずに済む。staging（`copyBufferToTexture`）で jar を開ける時に、(b) へ替えて `copyPipelineOf` を消す。

## 4. GL と比べて分かった事（MSAA）

- GL の描き先は上下逆に格納されるので、標本の位置が中身に対して上下に返る。標準の 4 標本の並びは上下に返すと別の並びになり、**斜めの縁は GL と WebGPU で 1〜2 標本ずれる**
  （多角形の場面で 89 px・最大 ±51）。軸に沿った縁は、標本の x の組と y の組が上下に返しても同じなので一致する（MSAA の 4 場面は端数の位置の箱と四角形の多角形で 0 px）。
- 端数は画素の中心（0.5）と標本の位置（1/8 の奇数倍）を避ける。ちょうど乗ると、覆うかを決める規則が上下に返した描き先で逆の側を取る（標本 1 の場面でも最大 ±224 になった）。
- 標本 4 の場面と同じ物を標本 1 で描いた場面の絵が違う事を、GL と WebGPU の両方で見る（`[webgpu-v1] 標本 4 と 1 の差`。両方が MSAA を掛けずに同じ絵になる誤りを拾う）。
