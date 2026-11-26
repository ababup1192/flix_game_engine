# 性能の決まり — 何を性能の問題と呼び、何を直さないか

「遅いところを速くする」では判断できない。速い / 遅いは相対で、比べる相手が要る。
自動で止まるのは**絵の値段（1 フレームに組む描き物の数）だけ**で（§9）、
時間・割り当て・二乗は今も人が基準に照らして決める。その基準をここに置く。

経緯と調査の記録は `plans/performance.md`。**決まりの本文はこちら。**

ここで言う性能は**走らせたときの速さ**。`flix check` の速さ（型検査が record の展開で
伸びる罠と、World が持つ大きな record を enum で包む決まり）は
`docs/flix-conventions.md`「型の設計」。フェーズ別の秒数は `bin/check-phases <dir>`
（`--Xbenchmark-phases` はコンパイラ自身のテスト用で、プロジェクトには使えない）。

---

## 1. 直す前に通す 3 つの門

### pub 不変の門 — 外から呼ばれている形を変えない

engine / engine_world の `pub` は、このリポジトリの外にある独立したゲーム 11 本が呼ぶ。
性能の直しでも、外から見える形は変えない。

- **戻り値の順序も「振る舞い」に含める。** `GridSearch.flix:15` のように doc が
  「返る順は幅優先の訪問順」と約束している関数は、順序を変えたら pub の変更として扱う
- **pub を「足す」のも同じ扱い。** 型に索引のフィールドを 1 つ足すのも変更。
  索引が要るなら private の再帰へ引数で通す
  （`UiHierarchy.buildChildIndex` がこの形。`UiLayout.LayoutInput` は
  `docs/api-digest.md` に公開されているので触らない）

### 予算の門 — その経路は誰がいつ払うか

同じ 1 ミリ秒でも、払う相手が違えば価値が違う。**2 軸**で見る。

| | 毎フレーム | 1 回だけ |
|---|---|---|
| **遊ぶ人が払う** | 最優先。予算は R3（動的 PlacedItem < 2000 個/フレーム・avg < 8ms / p99 < 12ms） | 場面の切り替わり・セーブ / 読み込み・`Audio.reloadAudio`。1 フレームぶんを丸ごと使ってよいが、超えるならフレームを分けて分割する |
| **作る人が払う** | 該当なし | headless の描き出し（ルートの `make render-all` = 全テンプレ）・Studio のプレビュー・CI・コミット前の lint。合否線は**実時間の背中合わせで 1 割** |

右上のマスで、遊んでいる最中に起きる物（ブラウザで後から届く glb の束を解く）は、フレームを分けるより**メインのスレッドの外へ出す**方が効く。
後回しの glb は頁が Web Worker で解き、メインは組むだけにしてある（[web-export.md](web-export.md) の「後回しの glb を Web Worker で解く」・`?fge=noworker` で前の道と比べる）。

右下のマスは、速くするより**払う回数を減らす**方が効く。全テンプレの描き出しは実時間 150 秒だが、
触ったテンプレ 1 本なら 20〜40 秒で、`make render-changed` がその 1 本だけを選ぶ。

**遊ぶ人 × 毎フレームを最優先する。** 描き出しが速くなるのは価値があるが、
遊ぶ人の手触りには 1 ミリ秒も反映されない。順番を間違えない。

この表は**性能のために足す仕組み自身にも当たる**（右下のマス）。
コミットのたびに数十秒かかる検査は置かない。

> **R3 予算の限界。** これは `docs/pxsprite-timeline-promotion.md:117` が
> **1 本のゲーム向けにその回で決めた数字**で、エンジン全体の予算としては昇格していない。
> 測定条件も `bench/*/RESULTS.md` の「design 320×240 / vsync off / この Mac」に固定されている。
> **引いてよいが、絶対視しない。**

### 生死の門 — その経路は生きているか

**pub API か JSON の許可リストから到達できる経路は、実行の記録が無くても生きているとみなす。**
どちらからも到達できないなら、直す前に「消すか」を先に問う。

判定は観測できる事実だけで書く（「自分たちが足したから」は理由にしない）。
外部のゲーム 11 本はこのリポジトリから観測できないので、pub かどうかで代替する。

---

## 2. 判定 3 — 読みやすさの代金で分ける

計算量か係数かで分けない。**その直しが読みやすさをいくら払うか**で分ける。

**3-a: 代金を払わない直し** — `List.reverse` 蓄積、値を 1 回だけ計算して持ち回る。
書き換えた後の方が読みやすいか、同じ。→ **無条件でやる。N の実測も測定も要らない。**

理由は 2 つ。**N を決めるのはゲームで、エンジンは N を知らない**（今のテンプレが 9 要素だから
軽い、はエンジンの性質ではない）。そして**代金がゼロなら、効果がゼロでも損をしない**。

> 「代金を払わない」は主観なので、自分で 3-a を名乗れば測定が免除される抜け道になる。
> **レビューで否認されたら 3-b へ落ちて測る。**

**3-b: 代金を払う直し** — 1 つの走査に複数の仕事を同乗させる、専用のキャッシュを足す、
データの持ち方を根本から変える。→ **測ってから決める。**

**3-c: 性能に関係なく、決まった壊れ方は例外を残さず直す。**
`App.Internal.Output.sustainOps` のように N が数本で実害が無くても直す。例外を 1 つ残すと、
次の人が「前例がある」と言える。

---

## 3. 足切り — どれだけ速くなれば代金を払う価値があるか

新しい数字を作らず、このリポジトリが過去に採った / 採らなかった実績から引く。

| 過去の改修 | 差 | 結論 |
|---|---|---|
| uniform location のキャッシュ | −2%（誤差の範囲） | **棄却** |
| style を instance 属性へ | −16〜−34% | 採用 |
| zIndex ソートの置き換え | 6〜37 倍 | 採用 |
| PxSprite 1 クアッド | 5.5〜8.8 倍 | 採用 |
| 画素を int[] のまま一括で GPU へ写す | frame_p50 −1.0ms(12%) / frame_avg −0.63〜−0.86ms(8〜11%) | 採用（下の注） |
| 辺長が同じときの `glTexSubImage2D` | 差なし（0.68ms 対 0.68ms） | **棄却** |

> **一括で写す方の判断（2026-08-18）。** avg では 8〜11% と線をまたぐが、median では 12% で
> 超える（avg だけがぶれるのは外れフレームが平均を押すため）。採ったのは 2 つの理由で、
> ① 読みやすさの代金がほぼ無い（1 要素ずつ回す `Vector.forEach` が 1 行の一括写しになる。
> 払ったのは `Vector` と `Array` が同じ JVM 配列だという前提だけで、そこは
> `render_gl/test/TestTextureUpload.flix` が固定している）、② **効きの大きさを決めるのは
> テクスチャの面積 = ゲームで、エンジンは N を知らない**（320x240 で 0.65ms なら
> 1024x1024 では 9ms 前後になる）。数字は `bench/texture_upload/RESULTS.md`。

**採らなかった最大が −2%、採った最小が −16%。** 足切りをその間に置く。

> **3-b の足切り: 同条件の背中合わせ A/B で、avg か p99 のどちらかが 1 割以上縮むこと。**
>
> **分母は R3 の条件下でのフレーム時間**（avg 8ms / p99 12ms）であって、**関数自身の時間ではない**。
> 関数単体で 1 割速いのは簡単に満たせて、フレームには 0.01ms も出ない。avg なら **0.8ms** が線になる。
> **作る人のマス（描き出し）だけは分母が違い、ルートの `make render-all`（全テンプレ）の実時間に対する 1 割。**
>
> ただしこの分母は**今のところ使い物にならない**。ルートの `make render-all` の実時間はテンプレの
> コンパイル時間が支配していて（実時間 150 秒に対し CPU 時間 653 秒 = 406%）、
> 実行のたびのばらつき ±9% が合否線の 1 割と同じ大きさになる。
> **描き出しの中身を測るなら、実時間ではなくその経路単体の数字を取る。**

届かなかったら**やらない**。届かなかった数字と日付を `docs/backlog.md` へ残す
（同じ調査を次の人がやり直さないため）。

例が 4 つしかないのは弱い。9% と 11% の間に本質的な差があるわけではない。

---

## 4. 打ち切り 4 — 絵と音の一致を証明できない直しはしない

性能の直しは**出力を 1 ビットも変えない**のが原則。変わったらそれは性能の直しではなく
仕様変更で、別の話になる。

証拠は 3 種類あり、**対象ごとに何が守れるかが違う**。直す前にこの表を自分で埋める。

| 証拠 | 守れる物 | 守れない物 |
|---|---|---|
| ユニットテスト | 純粋な導出の値・順序 | atlas やフォントが要る描画（`RichText.place` は `engine_world/test/TestRichText.flix:2` が明示的に除外していた） |
| スナップショットの SHA | 画面に出る絵 | 音・テンプレに用例が無い部品・呼び出し元がテストだけの関数 |
| `make gl-parity` | GL と headless の食い違い | 上と同じ |

**空欄がそのまま危険な場所の一覧になる。** 空欄のまま直さない。
先に証拠を 1 本足すか（2026-08-13 の回は `RichText.place` の等価を pin するテストを足した）、
足せないなら直す対象から外す。

---

## 5. 二乗であることをどう示すか

### 割り当てバイトで測る

`List.foldLeft` の中の `List.append(acc, ...)` が O(N²) になる理由は**割り当てそのもの**。
時間でなく**割り当てたバイト数**を測れば、熱・JIT・GC・マシンのどれにも動かされない
決定的な数字になる。`ManagementFactory.getThreadMXBean()` を
`com.sun.management.ThreadMXBean` へ落として `getThreadAllocatedBytes` を読む
（前例は `GifEncoder.flix:63` / `SoftRaster.flix:12` / `RenderUtil.flix:15`）。
普通の Flix テストとして書けるので、パッケージも Makefile のターゲットも増えない。

**絶対バイト数を `assertEq` で pin しない。** JDK のバージョンや計測区間に混ざる
他の割り当てで動く。書くのは**比**（N を 8 倍にしたとき、O(N) なら 8 倍前後・O(N²) なら 64 倍前後）。

2026-08-13 の回の実測（N を 8 倍にしたときの割り当ての伸び・直す前 → 直した後）:

| 関数 | 前 | 後 |
|---|---|---|
| `Text.toDrawables` | 33.3 | 7.68 |
| `RichText.place` | 19.2 | 8.26 |
| `App.Internal.Output.sustainOps` | 54.6 | 9.96 |
| `UiLayout.computeLayout`（`UiHierarchy` 側の二乗） | 63.3 | 11.5 |
| `GridSearch.reachable` | 43.7 | 10.8 |

### 割り当てで見えない二乗がある

**走査型の二乗はこの方式では原理的に見えない。** `List.exists` / `List.memberOf` /
`List.range` の中の `List.nth` は、何も割り当てずに N 回舐める。

| 二乗の正体 | 割り当てで見えるか |
|---|---|
| `List.foldLeft` の中で `List.append(acc, …)` を呼ぶ | ○ |
| ループの中の `List.exists` / `List.memberOf` | ✕ |
| `List.range` の中の `List.nth` | ✕（割り当ては O(N) のまま） |

見えない側は**測らない**と決め切る。守るのはユニットテストだけになる。

### lint で拾えない隠れた二乗の形（呼んだ関数の中にある）

`lint-quadratic` はループの中に書いた字を見るので、呼んだ関数の中の二乗とコピーは拾えない。glb の読み込み（`Gltf`）で 1 束 78 ms を食っていた 2 つ:

- **番号で引く関数が、呼ぶたびに配列を作り直す**: `objectAt(kind, i, json)` が `objectsOf(kind, json)` で accessor 1,915 個の Vector をそのたびに作っていた。配列は読んだ時に 1 回だけ取り出して型に持たせる（`Gltf.Internal.Parse.Glb` の `accessors` など）
- **標準の `Vector.slice`・`take`・`drop`・`splitAt` は Vector 全体を配列へコピーしてから切る**（flix.jar の `Vector.flix`）。大きな Vector から何度も切ると、切る回数 × 全体の長さだけ写す（1.5 MB の束から絵 46 枚で 70 MB）。切る分だけ写す関数（`Gltf.Internal.copyRange`）を使う。短い Vector の `take` は害が無いので止めない

### 時間で測るとき

熱スロットリングで 4 割方遅く出るので、倍率の閾値は成立しない。**N を 100 / 200 / 400 / 800 と
振って log-log の傾きを取り、`p > 1.5` を注意の線とする**（O(N)=1.00 / O(N log N)=1.08 /
O(N²)=2.00）。1 計測の内側で固定回数だけ呼んで合計を測る（小さい N が時計の分解能に沈むと、
分母だけ底上げされて二乗を見逃す）。5 回回して min を採り、測る順は交互・背中合わせ。
戻り値は必ず消費する（JIT が計算ごと消す）。

CPU の描く時間（SoftRaster・SoftRaster3d）は `CpuTiming.measure({ warmup, runs }, 仕事)` で温めてから何回か測り、中央値で比べる（最後の回の値を返すので、使って捨てない）
（3D の部屋は `make bench B=scene3d-cpu`・gl-parity の場面ごとは `make bench B=gl-parity-cpu`。描き出しの `renderPng*` はキャッシュが写すだけの回があるので、
時間を測るのは同じ塗りの `HeadlessRender.renderImageFull` / `renderImageSoft`）。同じ機械でも負荷で 5〜10% ほど揺れる（`bench/baseline/0.76.0/scene3d.txt`）。

**時間で測る物はゲートに乗せない。** `make release` は並列のテスト（`test-release`）の直後で熱と CPU の
取り合いのピークなので、偽陽性を出しうる検査をリリースの経路へ置かない。

---

## 6. 手本と壊れ方 — 同じファイルの中で流儀が割れていた

`engine/src/render2d/Text.flix` には、同じ形の `List.foldLeft` が 2 つある。
**片方は正しく、もう片方は 2026-08-13 まで二乗だった。**

**手本**（`groupRows:144`）— 新しい要素を `::` で先頭へ積み、最後に `List.reverse` で並べ直す:

```flix
let folded = List.foldLeft((acc, entry) -> {
    ...
    { rows = List.reverse(acc#current) :: acc#rows, current = charAdv :: Nil, rowY = y }
}, { rows = Nil, current = Nil, rowY = 0.0 }, entries);
List.reverse(List.reverse(folded#current) :: folded#rows)
```

**壊れ方**（`toDrawables:179`。直す前の形）— 1 行ごとに `acc` の末尾へ `append` する:

```flix
// これは書かない: 行数の二乗で割り当てる
{drawables = List.append(acc#drawables, lineDrawables), lineIdx = lineIdx + 1}
```

`List.append` は第 1 引数を丸ごと作り直す。`List.foldLeft` の中で `acc` を第 1 引数に置くと、
1 回目に 1 個・2 回目に 2 個…と積み上がって、合計 N²/2 個の cons を割り当てる。
**手本は同じファイルの 144 行目にある。** 読んだ人がどちらを真似るかは運になっていた。

直した形は `::` で積んで `List.flatten(List.reverse(...))`。**行数の二乗が消え、
`TestText.flix:137` もスナップショットもそのまま緑**（出力は 1 ビットも変わらない）。

覚えることは 1 つ。**`List.foldLeft` の中で `acc` を `List.append` の第 1 引数に置かない。**
`::` で積んで最後に `List.reverse` する。名前が `acc` でなくても
（`done`・`acc#drawables`・タプルを分解した別名でも）同じ。

同じ話がもう 2 つある。

- **`List.exists` / `List.memberOf` をループの中で呼ばない。** 会員判定は `Set` / `Map` で見る。
  順序も要るなら「順序つきの蓄積 + 判定用の `Set`」の二本立てにする
  （`GridSearch.floodList` がこの形。`floodField` は最初から `Map` で見ていた）
- **`List.range` を回して `List.nth` で引かない。** 1 巡で済ませる。
  ただし `List.zip` は短い方で打ち切るので、余った側の後始末が要るなら
  先に `List[Option[_]]` へ伸ばしてから 1 巡する（`UiSlots.fill`）

### ループの外に置いた式がループへ戻る（Flix 0.78・2026-10-19）

**純粋な `let x = 式` がラムダの中で 1 回だけ使われると、0.78 の最適化は式をラムダの中へ書き写す**
（`@DontInline` でも止まらない）。画素やコマごとに呼ばれるラムダなら、1 回のはずの組み立てが毎回走る。
値は変わらないので、テストも絵の比べも気づかない。0.50 の描き出しはこれで、シェーダー面が Spec を
画素ごとに組み直し（今の `ShaderEval.compile`）、頂点色の多角形が三角形の record を画素ごとに引いていた。
直してから internet_dungeon の reference-check は 243 秒 → 69 秒。

```flix
// これは書かない: eval の組み立てが画素ごとに走る
let eval = ShaderEval.compileSpec(s#spec);
shadeAll(n, i -> eval(uvOf(i), time))

// 手本（SoftRaster.Internal.Surface.drawSurface）: 組み立てはデータで返し、Ref を通してループの外に留める
let compiled = onceOutsideLoop(rc, ShaderEval.compile(s#spec, texEnv));
shadeAll(n, i -> ShaderEval.evalCompiled(compiled, u, v, time))
```

- 組み立てを **関数で返さない**（`def f(spec): (A) -> B`）。データ（enum の木など）で返す
- ループの外の値は `onceOutsideLoop(rc, 式)`（`Ref.get(Ref.fresh(rc, 式))`）で受ける。Ref は純粋でないので動かされない
- record の欄（`p#blend`）も同じ。名前つき引数の関数（`Float64.clampToFloat32(min = .., max = .., x)`）は
  呼ぶたびに record を作るので、画素ごとの所では書き下す（`SoftRaster.f32`）

`bin/fge hoist`（precommit）が 2 つの形を止める: エンジンの塗りの道で戻り値が関数の型の def と、
`shadeAll` / `Array.forEachWithIndex` のラムダが、呼び出しの結果や record の欄の let を `onceOutsideLoop` なしで
使う所（目安。軽い呼び出しは `bin/lint-rules/hoist.json` の notMoved、残すと決めた所は exempt）。

---

## 7. 残っている二乗の一覧

**最終確認日: 2026-08-17**

`bin/fge quadratic`（2026-10-15）が機械で見るのは、fold の中で蓄積を `List.append` の
第 1 引数に置く形と、文字列の蓄積に 1 回ごとに足す形だけ（コミット時は足した行だけ）。
**ループの中の `memberOf` / `nth` と `sortBy` のキーは見ないので、その宿題の置き場はここしか無い**。触るときに見る。

2026-10-15 に `bin/fge quadratic --all` が見つけた、この一覧から漏れていた 3 件
（どれも 8/13〜8/17 の洗い直しより前に入っていた）: `UiTypewriter.visibleText`
（`foldLeft(String.concat, "")`。N は見えている文字数で、ゲームが決める）と `templates/tetris-starter`（2026-10-28 に引退）の
`shuffle`（ゲームが写す元）は 3-a として直した。`FontCache.fontHash` は N が 8 で決まっているので
`bin/lint-rules/quadratic.json` の除外に理由ごと載せた。

### この一覧が緑のテストに騙されていた（2026-08-17）

`TestAllocGrowth` が緑でも、**二乗が無い証拠にはならない**。閾値の置き方に窓がある。

前の回は `RichText.placeLine` の `List.append` を直したが、**同じファイルの `wrapLinesBy` /
`take` / `plainText` には文字列連結の二乗が残っていた**。それでも
`testPlaceAllocatesLinearlyInLineLength` は緑のまま通っていた（実ログ `PASS 389.0ms`）。

理由は混合の比率。N=100 → 800 で二乗の項だけなら 42.7 倍だが、線形の項が太いので
全体の比は 15.3 倍に薄まり、閾値 16.0 を下回る。**1 文字あたりの線形の割り当てが
約 600 バイトを超えると、二乗はこの検査の下に隠れる。**

**閾値は「比例なら 8 倍」に近づける。** 実測の最大 × 1.4 程度が線で、16 は緩すぎた
（`place` は 16.0 → 11.5 に締めた。実測 8.0 前後）。ただし 10 を切ると偽陽性を出す
（線形の床が消えないため）。**2 点しか測らないので混合を分離できない**のも同じ理由で、
このテストの限界として残る。

### `UiHierarchy.childrenOf` — 1 つの親が子を 100 個以上持つ UI で今も二乗（要相談）

`engine_world/src/UiHierarchy.flix:10`。原因は `List.sortBy`。

- Flix の `List.sortBy` は**安定ではなく、pivot に最後の要素を採るクイックソート**
  （stdlib の `Array.flix:1498` `quicksortPartition`）。
  **すでに整列した並びを渡すと最悪の O(N²)** になる
- しかも比較のたびにキー関数（`Map.get(id, order)`）を呼ぶので、**割り当ても二乗**になる

`resolveInherited` / `UiLayout` の経路は `buildChildIndex` で「親 → 子の一覧」を 1 回だけ
作る形に直したので、**ツリー全体を舐める二乗は 2026-08-13 に消えた**。残っているのは
**1 つの親の子の数**に対する二乗で、今のテンプレでは 9 要素なので実害は出ていない。

**直すと並び順が変わりうる**（安定ソートへ替えると、order が同値の兄弟の順が変わる）。
`childrenOf` は pub なので pub 不変の門に当たる。**着手前に相談する。**

### 毎フレームの `sortBy` — キーは比較のたびに 2 回組まれる

**Flix の `List.sortBy(f, l)` は `sortWith(Order.compare `on` f)`** なので、
**1 回の比較でキー関数を 2 回呼ぶ**（メモ化しない）。キーが重い関数を呼ぶ形は、
それだけで `2·N·log N` 回の呼び出しになる。

直し方は decorate-sort-undecorate（`(キー, 要素)` を 1 回だけ作り `sortBy(fst)` で並べて戻す）。
**キー列が同一なら出力の順列はビット同一**になる（`quicksortPartition` の swap は
比較の結果だけで決まり、要素の同一性は制御フローに入らない）。並びは変わらない。

2026-08-17 にこの形で直したのは `UiExtract` の 3 本（`extract` / `extractPolys` /
`extractShapes`）と `Painter.zOrdered`。**残りの `sortBy` を触るときは、キーが何を
呼んでいるかを先に見る。**

### 走査 5 本の同乗（適用 E）— 測って打ち切り済み

`docs/backlog.md` の「性能（2026-08-13 の回で測って打ち切った物）」に、数字と
トリガーごと残してある。二乗ではなく係数の話。

### ループの中の `List.memberOf` / `List.nth` — 残り 16 件前後

`plans/performance.md:412` の実測（この回に数えた値）:

| 形 | 件数 |
|---|---|
| `List.foldLeft` の中で蓄積へ `List.append` | 9 |
| `List.range` / `forEach` の中の `List.nth` / `List.length` | 1 |
| ループの中の `List.memberOf` | 約 12 |

合計 約 22 件。**このうち 6 件をこの回で直した**（`Text.toDrawables` /
`RichText.placeLine` / `UiSlots.fill` / `App.Internal.Output.sustainOps` / `UiHierarchy` の呼び出し側 /
`GridSearch.floodList`）ので、**残りは 16 件前後**。

内訳は数え直していない（数え直す代金が高く、機械で数える物も無いため）。
`List.memberOf` の約 12 件は**大半が 3〜10 要素の許可リストに対する会員判定**で、
N が定数なので実害は無いと判断している。**N を決めるのがゲームになる場所
（Doc から来る一覧・entity の一覧）だけは、見つけたら 3-a として直す。**

2026-08-17 に engine / engine_world / render_gl / engine_tools を洗い直し、
**`List.foldLeft` の中で蓄積へ `List.append` する形は engine / engine_world から消えた**
（残っていた `ReferenceSite.scenariosOf` / `tagsOf` の 2 件もこの回で直した）。
文字列版（`String.concat` / 補間で 1 文字ずつ足す）は見落としていた形で、
`RichText` の 3 件と `PxShade.shade` がこれに当たり、直した。

同じ日の追加調査で **`ShaderGen` の 3 件が漏れていた**ことが分かり、直した
（`bindingPrelude` / `gradientExpr` / `powProduct`。N はそれぞれ Doc の binding 本数・
グラデーションの区切り数・Doc に書かれた指数で、**どれもゲームが決める**）。
`AllocMeter` で要素数を 8 倍にしたときの割り当ての増え方を測ると **61 / 61 / 26 倍**
（比例なら 8 倍）で、二乗であることが数字で出た。`preludeSource` の 119 個の `+` 連鎖も
同じ回で 1 回組みに替えている（項数は固定なので二乗ではないが、`compile` の割り当ての
7 割を占めていた）。`compile` 1 回の割り当ては 314,848 → **121,608 バイト（−61%）**。
検査は `engine_world/test/TestShaderGrowth.flix` に常設した。

### 要相談として残した物（2026-08-17 に調べて、手を付けなかった）

| 場所 | 事実 | 止めた理由 |
|---|---|---|
| `RenderPaint.buildProgram` | 面の Spec を **name で引き、中身（`eqSpec`）が違えば GLSL を組んでコンパイル・リンクし直す**。当たれば GLSL は組まない | 毎コマ中身が変わる Spec（濃さを `Const` で書き込む等）は毎コマ作り直しになる。濃さは `Render.fade`（uniform `uAlpha`）で渡す。作り直した古い program は引退させ、使われなくなってから消す。見つけ方は §11 |
| `Sprite.buildMaskData:470` | mask 付き描画ごとに毎フレーム再三角形化（凹なら二乗） | mask はカメラ変換後の座標で毎フレーム値が変わる。**鍵にできる不変量が無い** |
| `Shadow.rimBlocked:109` | 前面辺 × 全影四角形の O(E²) | 本物の二乗だが `Light.items` の呼び出し元がテストのみ。直しは空間分割 = 3-b |
| `UiExtract.measureTexts:10` | 毎フレーム全テキストを再計測（可視でなくても・変わっていなくても） | 二乗ではなく係数。§10 の「まだ 1 度も採っていない手」に当たる |
| `SoftRaster` の資産の読み直し | GIF は **コマ数 ×(1+pass 枚数)** だけ全 PNG と TTF を読み直す | 予算の門の右下。置き場は `RenderConfig` ではなく既存の `extraImages` / `extraFonts` 経路へ private で通す形（pub を増やさない）。**寿命は 1 回の描き出しの中に閉じる** |
| `Material.grain` の静的化 | エンジン側に「この fx は静的か」の口が無い | pub 追加 + エンジン拡張。相談の前に**既存の `prebuilt` へ寄せられるか**を調べること |

### 調べて「穴ではない」と分かった物（同じ調査をやり直さないため）

- `ViewProjection.coveringCells:276` — **入力は整列済みではない**（生成は行優先、キーは `x+y` で鋸歯）。
  末尾ピボットの最悪 O(N²) には当たらない
- `Hit.firstHit` / `hits` / `anyHit` — **1 対 N の O(N)** であって二乗ではない。
  `Collision` の一様格子は全ペア用で、API の形が違うので比較にならない
- `UiFocus.hitTestUi:32` — 毎フレームではない。しかも `measures` が空 vs 実測で
  **計算そのものが違う**ので、`UiRender` と共有すると絵が変わる
- `Terrain.surfaceItems:75` — 二乗ではなく線形。カリングは呼び側の仕事
- `ShaderEval.neighborCells:368` — `envOf` と同じ経路・同じ性質・同じ分母で、そちらは打ち切り済み
- `SoftRaster.Internal.Text.drawGlyph` の `deriveFont` — JDK が font strike をキャッシュしている
- `RenderLint.pairsOf:193` — 全ペアが仕様で、出力自体が N²/2 要素ある
- `TileLayer.sourceIdAt:117` — 形は正しいが**呼び出し元がゼロ**（`isWall` / `isFloor` にも無い）。
  生死の門により、直す前に「消すか」を問う対象

---

## 8. 触らないと決めてある物

- `render_gl/src/Frame.flix` の `mergedByZ` — 既にカウンティングソートで O(N)。
  `sortBy` の頃から 6〜37 倍の改善が入っている
- `polyVertCap` / `List.length(sprites)` — GL のバッファを確保する前の見積もりで、
  描画の実行より前に確定させる必要がある
- `emitMerged` — 描画の実行そのもの。順序に依存する
- `App.Internal.Paint.resolvedCamera` の `safeZoom` — 1 フレームに 1 回しか走らない。N に依存しない
- ~~`ShaderEval.envOf`~~ の画素ごとの `Map` — 測って打ち切り済み（`docs/backlog.md`）
- `render_gl/src/Render3dGlsl/MeshVertex.flix`・`Render3dWgsl/MeshVertex.flix`（置いた物の頂点シェーダー）— ShaderAst の木へ移さず手書きの字のまま。
  ブラウザ版の wasm の brotli の大きさ（retro3d-horror-starter の書き出しで測る）の上限は 1,432.8 KB から +6% の 1,518.8 KB と決めてあり、
  今 1,513.1 KB（+5.6%）で、木の組み立てを足すと届く。frag の varying の表とのずれは `TestShaderDump` が字で照らす

---

## 9. 絵の値段の検査（唯一の自動検出器）

**捕まえる事故**: 盤・群れ・タイルを毎フレーム N 個の `PlacedItem` に組む形。
型検査もテストもリファレンス画像も止められない（box 列と 1 コマ 1 クアッドは**画素が同一**
なので SHA が 1 ビットも動かない）。見ていたのは人の目の fps だけだった、その穴を埋める。

**どこで数えるか**: `engine_tools/src/HeadlessRender.flix` の PNG 系 5 変種が、描き出すたびに
PNG の隣へ `gallery/<場面>.items.tsv`（`total` / `passes` / `surfaces`）を常時書く。
env でも引数でも切れない — 消せる検査は消えるので。

**判定** `$(ENGINE)/bin/fge check-render-budget`（`make reference-check` と `make status` が呼ぶ）:

| | 内容 |
|---|---|
| ① 硬い上限 | 動的 ≥ 2000 個（R3 の借り物。基準が無い初日から効く） |
| ② ドリフト | 基準から max(×1.5, +200) を超えて増えた |
| ③ sanity | 静的層の申告が総数を超える・items.tsv 無しの static.tsv |

**動的 = total(+passes) − static**。タイル層・静的層は headless では CPU 投影されて
items に混ざるので、**正しく静的化したゲームほど総数が膨らむ**。その分は
`HeadlessRender.noteStaticItems(cfg, name, items)` で申告して引く（**render を呼んだ後に**
呼ぶ。逆順だと申告が消えるが、消えた側は動的が過大 = 保守側に倒れる）。

**基準の置き場**: `reference/ITEMS.tsv`（`make reference-update` の生成物・git 追跡）と
`reference/ITEMS.caps.tsv`（手書きの場面別上限・`note` 必須・再生成しない）。
PNG は git 外・一覧は git 内、という既存の非対称と同型なので、clone 直後でも判定できる。

**増やしたいとき**: 上限超えは `reference-update` の門が拒否する（初回実装が遅くても
基準にする所で止まる）。意図した増加は `make reference-update BUDGET=accept`、
場面ごとに上限そのものを上げるなら caps.tsv に `cap` と `note`。どちらも git 差分に残る。

**実行時の網**: `App.Internal.Paint.renderFrame` が本編 + pass の items を数え、2000 を超えたら
標準エラーへ**初回 1 回だけ**知らせる（`App.Internal.Paint.warnOverBudget`）。headless の代表フレームに
無い瞬間（Fx の最悪化・場面の切り替わり・GIF でしか描き出さない場面）の最後の受け皿。

**捕まえられない物**: 個数が増えない「毎フレーム組み直し」（541 個を組み直しても 541 個）・
2000 未満の緩やかな悪化・caps.tsv の濫用・シェーダー面の画素コスト・1 item の重さ。

---

## 10. この決まりが正直に言えないこと

- **機械が止めるのは 2 つの形だけ（ループの中の List 探しは知らせるだけ・§12）。** `bin/fge quadratic` は fold の中の `List.append` と文字列の形を見るが、
  ループの中の `memberOf` / `nth`・`sortBy` の重いキー・fold でない二乗（子の一覧を毎回探し直す形）は見ない。
  そちらは今もこの文章と `.claude/rules/flix.md` の 1 節だけで、**文章だけでは同じ壊れ方がまた入る**
- **割り当てバイトも傾きも、定数倍の退行を捕まえられない。** 1 個あたりのコストが 2 倍でも、
  階段が変わらなければ緑のまま通る。そこは `bench/sprite_stress` と人の目に残る
- **「毎フレーム走らせない（結果を持ち回す）」という 3 番目の手は、まだ 1 度も採っていない。**
  代金が最も高い（キャッシュを足すと「いつ古くなるか」という新しい正しさの問題が生まれ、
  絵の SHA では捕まらない「1 フレーム古い絵」を作りうる）。`docs/backlog.md` に起票してある

---

## 11. 遊んでいる時のヒッチを追う（hitch.md と POST /perf）

**捕まえる物**: 遊んでいる最中の、手の後や場面の切り替わりで起きる数コマの重さ（ヒッチ）。
§9 は描き出しの代表コマの「描き物の数」しか見ないので、シェーダーの作り直し・初めて出る字・
テクスチャの上げ直し・GC・swap の待ちのような、**実機の GL を通る時だけ起きる重さ**はここで拾う。

**書き出す物**: `make debug`（DEBUG の起動）で遊ぶと、`App.HitchDetector` が毎コマを見張り、
重いコマの並びだけを `debug/perf/hitches/<起動時刻>/f<コマ>/hitch.md` に書く（`make status` に件数が出る）。
中身は上から「一番重いコマ（更新 / 送る / swap）→ 直前の手と状態 → 推定原因 → 作ったシェーダーと理由
（同じ名前で中身が違えば、違う所の抜き書き）→ 重いコマの表 → 再現」。1 件は数十行で、毎コマの全部は書かない。
音を消すなら `FLIX_GE_MUTE=1`。

- 重いコマ = swap を除いた仕事が予算（60fps）を超えた・swap まで含めて予算の 2 倍を超えた・シェーダーを作った。
  vsync で待つ分は数えない
- 数は描く側（render_gl）が `Platform.Diagnostics.setDiagnosticsEnabled` の間だけ集め、App が毎コマ
  `consumeDiagnostics` で引き取る（`FrameDiagnostics`）。切っている本番では数えない
- 起動直後の 120 コマはヒッチに数えず、その間の重いコマは「起動の区間」として `<置き場>/startup/hitch.md` に 1 回だけ別に出す（初めて見える集まりの組み立て・最初の材質の組みはここに出る）。1 実行 10 件まで（単発は数えない）。実行の置き場は新しい 5 つだけ残す

**直したか確かめる**: 同じ置き場の `record.flow`（ヒッチの最初のコマの手前までの手）を、DEBUG で起動した
ゲームへ `curl -X POST "http://127.0.0.1:<port>/perf?path=<置き場>/record.flow"` で流す。flow を決まった刻みで
流した World の列を本物の GL で 1 コマずつ塗り、同じ判定で `hitch.md` を書いて、その場所と数を返す。
隠しウィンドウ（`FLIX_GE_HIDDEN=1`）なら vsync を待たない。`make flow` は GL を通らないので、塗る側の重さは再現しない。
記録が長ければ `last=<コマ数>`（hitch.md の再現の行に入っている）で最後のコマだけを塗る。初めての型（初めて作るシェーダー・
初めて出る字）は同じプロセスで一度描いた物を作り直さないので、ゲームを起動し直してから流す。
GC か swap が半分以上を占める 1 コマだけの重さ（単発）は 1 件にせず、実行の置き場の `summary.md` に数だけ書く。

**比べるのは数**: ms は機械と、ドライバのシェーダーのキャッシュ（同じ GLSL なら 2 回目から速い）で変わる。
直す前と後は「作ったシェーダーの数」「GPU にあるシェーダーの数」で比べる。

**捕まえられない物**: 系ごとの更新の時間（更新は合計だけ）・
1 コマあたりの割り当てバイト・スパイクにならない、ゆっくりした悪化。GPU の塗りの時間は hitch.md には出ない（swap の待ちに混ざる）ので、下の画面の表示で見る。

### ゲームの画面に出す（App.withDiagnostics）

遊びながら 1 コマの重さを見たい時は、`App.withDiagnostics()` を足して `frame#diagnostics`（前のコマの `FrameDiagnostics`）を
World に写し、`FrameDiagnostics.summaryLines(d)` をゲームの字の部品で debug の表示として描く（F3 で出すなど。出す所はゲームが決める）。
出るのは CPU（GL へ送る・swap）・**GPU**（`gpuNs` = 描き先ごとの `GL_TIME_ELAPSED` の query の合計（描き先の間の GPU の空きは入らない）と描き先ごとの `gpuPasses`。
結果が出た query だけを GPU を待たずに読む。query を作れない GL・ブラウザ・CPU の描き出しでは None）・3D の数（`scene3dCounts` の置いた物・描いた物・draw call）・
2D の draw call の数と切れた理由（`draw2dCounts`。下の節）。
`FLIX_GE_FRAME_STATS=1` の println は 600 コマごとの平均と、その行を出したコマの 2D の draw call の数と切れた理由を標準出力へ書く（GPU を含まない。
`App.withDiagnostics` を足していないゲームでも出る）。こちらはゲームの画面に出せて、GPU を含む。
自前で `System.nanoTime` を測って出さない（GPU の仕事は CPU の時計では swap の待ちに混ざって見えない）。

**GPU の時間は 16 コマに 1 回だけ測る。** 間のコマの `gpuNs`・`gpuPasses` には最後に読めた値がそのまま入る（60 fps で 1 秒に 4 回ほど替わる）。
毎コマ測ると `glEndQuery` がドライバに溜めた命令を流させ、GPU の仕事が軽い場面で 1 コマが倍になった（診断を付けた時だけ遅いゲームになる）。
毎コマの値が要る時（GPU のスパイクを 1 コマずつ追う時）は `FLIX_GE_GPU_TIMER_EVERY=1` で起動する（数は何コマに 1 回か）。
測るコマは他のコマより長いので、`frame_p99` のような端の値には測るコマが混ざる。CPU の ms を比べる時は診断を付けない回（ベンチの `DIAG=0`）を基準にする。

**3D の中の pass ごとの GPU の時間**: `gpuPasses` には描き先（Pass の名前・`screen`）に加え、3D の描き手の中の区間が入る:
`shadow:sun`・`shadow:spot`・`shadow:point`（影の地図。点光源の atlas は面ごとの pass を足した値）・`shadow:cache`（動かない物だけの控えを描き直した分・WebGPU だけ）・
`scene3d`・`scene3d:depth`（場面の色の pass・奥行きの書き出し）。GL では描き先の query をそこで閉じて区間を測り、描き先の名前で開き直すので、描き先の時間は中の区間を引いた残り。
- **WebGPU（PC のウィンドウの既定）は `FLIX_GE_GPU_TIMER=1` を置いた時だけ測る**（timestamp-query の `timestampWrites`）。読み戻し（Dawn の mapAsync を待つ形）はそれまでの仕事を GPU が終えるまで返らず、
  測るコマが長くなる。1 コマの時間を比べる回はこれを置かずに流し、pass ごとの内訳を見る回だけ置く。ブラウザでは測らない（`gpuNs` は None）。
- タイル型の GPU（M 系・Mali）は次の pass を前の pass の終わりを待たずに始めるので、WebGPU の pass の時間は「前の pass の終わりから自分の終わりまで」で数える（重なった分は先の pass に入る・`GpuTimer.exclusiveTimes`）。
  Chrome の timestamp は 100 µs に丸められる。
- `FLIX_GE_FRAME_STATS=1` の行の末尾に、その行の間に読めた GPU の時間の中央値（全体と区間ごと）が出る（例 `GPU 26.0ms（shadow:point 12.1, scene3d 12.3, …・38 回）`）。
- 送る時間と塗る時間を分ける試しの旗: `FLIX_GE_SKIP_3D_DRAWS=shadow|color|all`（その pass を開いて閉じるだけにして draw を積まない・絵は欠ける）と
  `FLIX_GE_WINDOW_SIZE=<幅>x<高さ>`（ウィンドウの大きさを替えて描き先の画素の数を変える・design は替えない）。draw を飛ばして 1 コマが縮めば命令を積む分、
  画素を 1/4 にして縮めば GPU の塗りの分。
- 影の地図の控え（staticGroup の物だけを描いた深度を控え、毎コマ写して動く物だけを上に描く）の効き目は `scene3dCounts` の `shadowMapsReused`・`shadowMapsRedrawn` と、
  `FLIX_GE_SHADOW_CACHE=off`（控えずに毎コマ描く）との比べで見る。

### draw call がまとまらない時の読み方（draw2dCounts・scene3dCounts#batchBreaks）

描き手は、続けて来た同じ状態の物を 1 つの draw call にまとめる。まとまらなかった所は、理由ごとに数えて診断に出る
（`FrameDiagnostics.summaryLines` の「2D draw calls 96 / top break blend 72」の行・ヒッチの報告の「一番重いコマの draw call」・ベンチの JSON の `draw2d_breaks`・`draw3d_breaks`）。
draw call の数が多くて重い時は、**一番多い理由から**ゲームの側を直す。数え方の決まりは `FrameDiagnostics.Draw2dBatchBreaks`・`Scene3dBatchBreaks` の doc。

**2D**（`draw2dCounts#batchBreaks`）: 描き物は z の順に 1 列に並び、前の draw call に続けられなかった所で 1 つ数える。1 つの切れ目に理由は 1 つだけ
（`target` → `kind` → `texture` → `blend` → `clip` → `mask` の順で先に当てはまった物）。コマの最初の draw call は数えないので、合計は `drawCalls − 1`。

| 理由 | 起きている事 | ゲームの側で直す所 |
|---|---|---|
| `texture` | スプライトの絵（テクスチャ）が前と違う。箱（絵なし）と字（フォントのアトラス）と絵が z の順で交互に来ても切れる | 一緒に出る絵を 1 枚のアトラスにまとめて uv で切り出す。同じ絵の物を同じ z にして続けて並べる（窓の箱を全部描いてから字を全部描く、など） |
| `kind` | 種類（スプライト・多角形・タイル層・static の範囲・Shader の面・3D の場面）が前と違う。タイル層・static の範囲・Shader の面は 1 つで 1 draw call | 同じ種類を続けて並べる（多角形の飾りを 1 つの z にまとめる）。細かい多角形の絵はスプライト 1 枚の絵にして描く。Shader の面は枚数を減らす |
| `blend` | blend（Normal・Add・Multiply）が前と違う | Multiply や Add の物を 1 つの層（同じ z）にまとめ、Normal の物と交互に重ねない。影や水の濃淡を 1 枚の絵にまとめる |
| `clip` | 切り抜きの矩形（scissor）が前と違う | 同じ矩形で切り抜く物を続けて並べる。切り抜きの要らない物に矩形を付けない |
| `mask` | mask つき（stencil へ描く分・mask つきの本体・その次の draw call）。mask つき 1 個で draw call が 2〜3 増える | mask を付ける物を減らす。形が決まっているなら、抜いた後の絵を先に作っておく |
| `target` | 描き先（Pass か画面）が変わった最初の draw call | Pass の数を減らす（使っていない Pass を宣言しない） |

**3D**（`scene3dCounts#batchBreaks`）: 3D は同じ形・同じ材質の物を鍵でまとめてから描くので、draw call 1 つを 1 つの理由に数える（合計は `drawCalls`）。
優先の順は `shadowPass` → `billboard` → `sky` → `transparent` → `lightmap` → `skinned` → `material` → `mesh`。

| 理由 | 起きている事 | ゲームの側で直す所 |
|---|---|---|
| `mesh` | 材質は同じ（か無い）で、形が違う | 同じ形（`Mesh3d` の同じ値）を使い回して world と tint だけ変える。細かい形は 1 つの形につないでおく |
| `material` | 材質（プログラム・材質の木・params・絵の組）が前の batch と違う | 色の違いは `tint` で付ける（tint は 1 体ごとの値で batch を分けない）。絵は 1 枚のアトラスにまとめる |
| `skinned` | 骨つきの物の batch（骨の無い物とはプログラムが別） | 同じ形・同じ材質の骨つきの物はまとまる。形と材質の種類を減らす |
| `lightmap` | lightmap つきの物（物ごとに絵が違うので 1 体ずつ） | 動かない部屋は 1 つの形につないで lightmap を 1 枚にする |
| `transparent` | 半透明の物（遠い順に 1 体ずつ） | 半透明にする物を減らす。抜くだけなら cutout（`withCutout`）にする |
| `billboard` | ビルボード（来た順で続く同じ絵の板の並びで 1 回の instanced draw。並びの数と絵の種類の数は `billboardRuns`・`billboardImages`） | 同じ絵の板を続けて `billboards` に並べる（runs が images に近づく・[scene3d.md](scene3d.md) の「ビルボードの draw の数」）。視錐台の外は描かれない |
| `shadowPass` | 影の地図へ描いた分（影を落とす光ごとに、形の batch の数だけ） | 影を落とす光を減らす（スポットの `shadow`・太陽の影）。形の種類を減らす |
| `sky` | 空（場面 1 つで 1 draw call） | 直す所は無い |

draw call を減らして効くのは、数が数百を超える場面（細かい多角形と Multiply を交互に重ねる画・絵が 1 個ごとに替わる群れ・形が物ごとに違う 3D）。
1 コマに 10 前後の画面は、1 つにまとめても 0.1 ms も変わらない（§3 の足切り）。

### 描き手を直す前後で比べるベンチ（bench/）

描き手・描く物の列の作り方を直す時は、直す前と後で同じベンチを背中合わせに回して比べる。3 つとも区間ごとに 1 行の JSON（`[bench] result {…}`）を出す
（1 コマの avg / p50 / p95 / p99・GL へ送る時間・GPU・3D は draw call と `cpuPhases`・2D の draw call の数 `draw2d_calls` と
まとまらなかった理由ごとの数 `draw2d_breaks`・`draw3d_breaks`。形は `bench/common/BenchRun.flix`）。

| 口 | 測る物 | つまみ |
|---|---|---|
| `make bench B=sprite-stress-bench` | 2D のスプライトの数・絵の種類・blend の混在 | `COUNTS=1000,5000,20000 TEX=1/16/256 BLEND=alt` |
| `make bench B=crowd2d-bench` | 2D の群れ（規則 + 描く） | `COUNTS=6000,10000,20000 SEARCH=grid` |
| `make bench B=scene3d-bench` | 3D の部屋。`SCENE=field` で物を並べた場面 | `COUNT=12000 SHAPES=16 MATS=16 MOVING=10 ALPHA=10 SHADOW=1` |
| `make bench-web BENCH=<名前> ARGS='n=20000&tex=16'` | 同じ 3 つのブラウザ版（ヘッドレスの Chrome・WebGL2） | URL の query（鍵は小文字。`n`・`tex`・`blend`・`search`・`scene`・`shapes`・`mats`・`moving`・`alpha`・`shadow`） |

- 共通のつまみ: `FRAMES`（1 区間で測るコマ数）・`DIAG=0`（診断を付けない。GPU の時間の query の重さを見る時）。ブラウザは `frames`・`diag`。
- PC の窓の 3 つは既定の WebGPU で描く（WebGPU では GPU の時間 `gpuNs` が出ない）。`RESULTS.md` の GL の数字と比べる時は `FLIX_GE_BACKEND=gl make bench B=…` で GL を測る。
- ブラウザ版は `make sync-engine-full-web` の後。頁は結果を上に字で出し、`window.__bench` に JSON で置く。スマホでは `build/bench-web/<名前>` を
  静的なサーバーで配って `index.html?<つまみ>` を開く。ブラウザは rAF に合わせて待つので、比べるのは `cpu_p50`（wasm が 1 コマに使った時間）。
- 決まった組を通しで回すのは `bench/baseline.sh <出力> [pc|web|all]`（同じ組を 2 回。1 本ごとにプロセスを分けて間を空ける）。
  基準の生の数字は `bench/baseline/<版>/pc.jsonl`・`web.jsonl`、表は `bench/<名前>/RESULTS.md`。
- 熱で 4 割遅く出ることがある。重い区間の直後に軽い区間を測らない・同じ条件の 2 回の差を揺れとして読む（`bench/sprite_stress/RESULTS.md`）。

### 規則と描くのを重ねる（App.withPipelinedRendering）

規則（系）の 1 コマと描く 1 コマが直列だと、群れの多い場面で 60 fps を割る。効果の無い App（`App[w, {}]`）は
`app |> App.withPipelinedRendering` で、次のコマの World を別のスレッドで進めながら 1 つ前の World を描ける（Bevy の pipelined rendering）。
進める時間が描く時間と GPU を待つ時間の陰に隠れる（conduit_hive の 1000 体で 1 コマ 17 ms → 12 ms）。代わりに入力が画面に出るまでが 1 コマ遅れ、
音は絵より 1 コマ早い。重ねるのは機種の `Platform.Tasks` の handler で、デスクトップは別のスレッド 1 本・ブラウザ版はその場で順に進める。
60 fps より上を測る時は `FLIX_GE_NO_VSYNC=1`（見える窓のまま垂直同期を待たない。隠し窓の `FLIX_GE_HIDDEN` は描き先が design に縮む）。

### 3D の場面の描く量（視錐台の外を間引く）

GL・WebGPU・CPU の描き手は、カメラの視錐台の外の置いた物とビルボードを描かない（`Scene3d.isOutsideFrustum`・1 物あたり角 8 つ × 面 6 つの判定）。
外の物では、1 物あたりの uniform と draw call の仕事を払わなくなる。`scene3dCounts#drawn` が減るのを F3 の表示で見る。
間引くのは視錐台の外だけで、壁の向こうは間引かない（部屋ごとに描くかはゲームが決める）。
間引いた物も材質のプログラムを組み、形と絵を今のコマで使った物として GPU に残すので、振り向いた最初のコマで組み直し・上げ直しは起きない。
口と決まりは [scene3d.md](scene3d.md) の「描く量」。
3D の材質は読み込みで 1 回作って持つ（毎コマ `Scene3d.material` を呼ぶと、描き手のまとめ描きの分け方の控え（材質の値の参照が鍵）に当たらず、物ごとに材質の中身を比べ直す）。
形も同じ値を使い回す。計画は、姿勢と lightmap の無い物の (材質の値, 形の値) の組が前の物と参照で同じ時、分け方を 1 体目から使い回す（1 万個の箱で計画が 6 ms → 3 ms 前後）。

---

## 12. 重くなったらこれ

ゲームは小さな純粋関数を渡すだけで、重いループはエンジンが持つ。手で格子や探索を書く前にここを引く。

| 重い形 | 使う口 | 決まり |
|---|---|---|
| 全員どうしを比べている（押し合い・近くの敵を数える・範囲の当たり） | `SpatialGrid.buildBy` + `foldNearIndex` | `f` はその場のラムダで渡す（変数に入れて持ち回ると畳み込まれず、最悪 2.5 倍遅い）。毎コマ作る格子は World に置かない。半径と番号はゲームが `Vector` で持つ |
| 1 体ずつ経路を探している（同じ相手を群れが追う） | `FlowField.build` + `downhill` / `stepsAt` | 歩数は 4 方向で塗る。下るマスを読むのは 1 回の配列読みで、地図を置くのは World でよい |
| 毎コマ回さなくてよい仕事を毎コマ回している（地図の塗り直し・遠い物の見直し） | `Clock.tick(acc, dt, interval)` の `fired` の時だけ回す（前に回した時刻を持つ形でも同じ） | 間引きの口は足していない。使う側が 1 本で、系の単位で飛ばすと飛ばしたコマの `justPressed` が消える |
| 内側のループで List を引く・レコードの欄を読む | ループの前に `Vector` へ 1 回写す | レコードの欄は読むたびに名前で探す |
| 規則と描くのが直列で 60 fps を割る | `App.withPipelinedRendering` | §11 の「規則と描くのを重ねる」 |
| 3D で動かない物（建物・木・家具）が数千〜1 万個あって毎コマ重い | 読み込みで 1 回 `Scene3d.staticGroup` を作って Resources に持ち、毎コマ `groups` に載せる | 毎コマ `staticGroup` を呼ばない。動かす物・色を変える物は `withoutItems` で外して `instances` へ。スマホのブラウザで 12,000 個が 1.6 fps → 60 fps（[scene3d.md](scene3d.md) の「動かない物をまとめる」） |
| 3D で同じ形の動く物（群れ・弾・草）が 2,000 体以上あって毎コマ重い | `MultiMesh3d.build(形, n, i -> 行列)` で 1 つにして場面の `multiMeshes` に載せる | 1 体ずつ選ぶ・光らせる物は instances のまま。散らばる物は区画ごとに分ける。ブラウザで 1 万個が 1 コマ 20 ms → 5 ms（[scene3d.md](scene3d.md) の「物の置き方を選ぶ」） |
| 2D の動かない絵（影・壁・地形の多角形）の一部だけが変わるたびにコマが止まる（置き物を壊す・掘る） | `App.withStaticLayers(w -> 区画ごとの { id, key, items = () -> .. })` | 下の「静的層を区画に分ける」。地図全体を 1 つの `withStaticLayer` に入れて key を変えると、多角形を全部 GPU へ上げ直す（約 8,000 個で 1 コマ 43 ms） |
| 3D のビルボード（木・人・草）が多くて draw call が数百 | 同じ絵の板を続けて `billboards` に並べる（描き手が 1 回の instanced draw にまとめる） | 来た順は描き手が崩さない（重なりの前後が来た順で決まるため）。効き目は `drawCalls` の `billboard`（[scene3d.md](scene3d.md) の「ビルボードの draw の数」） |
| 3D で初めて出る物のコマだけ跳ねる（mipmap 作り・材質のプログラムの組み立て） | `App.withPreload3d({ textures = .., variants = .. \| App.preload3d(key, instances) })` | 視錐台の外へ置いて毎コマ描かせない。点光源の影と Physical の場面は `variants` に `Scene3d.preloadVariantOf(場面)`（変種のプログラムも先に組む）。骨つきの物は姿勢を付けたまま渡す。`tex3d:` の絵は `textures` に渡す。上げるのは起動と読み直しのコマで、そのコマは長くなる。`key` に時刻を混ぜると毎コマ組み直す（300 コマの内に 30 回変わると知らせる） |

ブラウザ（PC の Chrome・スマホ）で測る時の旗と比べ方は [web-export.md](web-export.md) の「ブラウザで重さを測る」。

### 静的層を区画に分ける

`App.withStaticLayers` の層は id ごとに GPU バッファを 1 本持ち、key が前のコマと違う層だけを作り直す。前のコマにあって今のコマに無い id のバッファは捨てる。

- **区画の大きさ**: 16〜32 マス角を目安にする。小さすぎると層の数だけ毎コマ宣言と key の比較が増え、draw call も層ごとに切れる。大きすぎると 1 つ壊した時の上げ直しが大きい。1 区画の多角形が数百個に収まる大きさにする。
- **key**: World に区画ごとの世代番号（`Map[(Int32, Int32), Int32]` など）を持ち、その区画を変えた系で 1 つ上げる。key は `"${世代}"` 程度にして、宣言のたびに区画の中身から作らない（毎コマ呼ばれる）。
- **items**: サンク（`() -> ..`）。作り直す時だけ呼ばれる。区画をまたぐ影・壁は、その物の足元のマスの区画に入れる（両方に入れると二重に描く）。
- **重なり順**: 並びの順が同じ z の中の前後になる（前の層が奥）。区画どうしで同じ z の多角形が重ならないなら、並びの順は絵に効かない。
- **headless**: 描き出しはゲームが静的な items を自分で描く。区画に分けたら `List.flatMap(s -> (s#items)(), specs)` を描いて `HeadlessRender.noteStaticItems` に渡す。

`bin/fge quadratic` は perf-near-scan として、回すラムダの本体とそこから呼ぶ同じファイルの def の中の `List.filter` / `exists` / `find` を知らせる（止めない。回す物の大きさは字から分からない）。
小さいと決まった列は `quadratic.local.json` の `exempt` へ理由つきで載せると黙る。

2D の群れで `SpatialGrid` と `FlowField` の得を確かめるのは `make bench B=crowd2d-cpu`（窓なし）と `make bench B=crowd2d-bench`（窓あり・`bench/crowd2d`）。

`SpatialGrid` の回す順は行が外側、升の中は入れた順で、同じ入力なら毎回同じ。足す順で丸めが変わるので、手書きの升ごとの小計から置き換えると値がわずかに変わる（1 本の蓄積へ直した版とはビット単位で同じ）。

`foldNearIndex` の `f` が畳み込まれているかは `TestSpatialGrid.testInlineLambdaFoldsIntoTheLoop` が割り当てバイトの比で見る。止めるのは畳み込みが丸ごと無くなる退行で、2 割ほどの最適化の差は見えない。

---

## 13. 物が多い時の .flix の書き方（ループを JIT に乗せる）

1 コマに 1 万個を超える物を回すループは、**JVM が JIT したかどうか**で 1 個あたりの時間が 5〜10 倍変わる。
Flix 0.78 の出すバイトコードには JIT から外れる形が 2 つあり、値も絵も変わらないのでテストも絵の比べも気づかない。
2026-11-14 に `bench/sprite_stress`（同じ絵のスプライト 20,000 個）で 1 コマ 30 ms → 8 ms になった直しは、どれも下の形だった
（数字は `bench/sprite_stress/RESULTS.md` の「描く物の列を作る所の直し」）。エンジンの .flix にもゲームの .flix にも当てはまる。

### JIT から外れる形

| 形 | 何が起きるか | 直し方 | 直した所と前後 |
|---|---|---|---|
| ループの 1 個ぶんが大きい（ラムダを渡した def の中で、さらに大きな関数を呼ぶ） | Flix はラムダを渡した def を呼ぶ所へインライン展開する。1 個ぶんのメソッドが **8,000 バイト**を超えると JVM は JIT しない（インタプリタのまま） | 1 個ぶんを別の def に出して `@DontInline` を付ける。ループのラムダはその def を呼ぶだけにする | `Render.Internal.Extract.drawInto` → `pushPlaced`。Item → Drawable が 1 個 約 1,040 ns → 約 190 ns |
| ループの中から呼ぶ関数が、別の関数の呼び出しで終わる（末尾呼び出し） | 末尾呼び出しは続き（Thunk）を返し、呼んだ側がその場の while で回す。JVM はその while の位置からループを JIT（OSR）しようとして「stack not empty」で諦める。1 コマに 1 回しか呼ばれないループは、何百コマもインタプリタのまま回る | ループから直に呼ぶ関数の末尾を、呼び出しでない式にする（Unit なら `;` の後に `()`・値なら `if` の枝を値にするか、Option に包んで `match` で開く）。`let` に受けて返すだけの形は Flix がたたんで末尾呼び出しに戻す事がある【未確認】自分自身への末尾再帰はそのままでよい | `RenderFrame.emitMerged` → `emitOne`（1 個 177 ns → 92 ns）。`SpatialGrid.cellIndexOf`（crowd2d 10,000 体の規則 9.06 / 8.88 → 7.67 / 7.63 ms） |
| 1 コマに 1 回しか呼ばれない関数の中の長いループ（ラムダの末尾が呼び出しでなくても起きた） | JVM が同じ「stack not empty」で OSR を諦める。末尾呼び出しが無いのに起きた理由は【不明】 | ループのラムダの中身を `@DontInline` の def に出し、ラムダはその def を呼ぶだけにする。`-XX:+PrintCompilation` で `COMPILE SKIPPED` の行が消えた事を確かめる | `Render3d.Material.splitByMaterial` → `placedDrawOf`（3D の field 12,000 個で frame p50 22.7〜24.0 → 18.5〜18.9 ms・`bench/scene3d/RESULTS.md`） |

### それ以外（JIT されていても 1 個ごとに払う物）

| 形 | 何が起きるか | 直し方 | 直した所と前後 |
|---|---|---|---|
| 逆順に `::` で積んで、最後に `List.reverse` | 積んだ cons がほかの値の間に散らばり、戻す 1 巡が 1 個ごとにキャッシュを外す | 個数が多い所は `region` の中の `MutList` へ `push` して `MutList.toList`。小さな列は今までどおり `::` と `List.reverse` でよい | `drawInto`（20,000 個で `List.reverse` の 約 1.6 ms が消えた。代わりに List にする所の時間は出していない） |
| ループの 1 個ぶんが、effect を持つ def を呼ぶ（`\ ef` の関数を受けて回す形） | effect を持つ def は、呼ぶたびに続きを運ぶ入れ物を割り当てる。PC は JIT が消すことがあるが、ブラウザ版（wasm）はそのまま時間に出る | 数の多い種類だけ、effect の無い def で先に済ませる。残りを effect のある def へ回す | `drawInto` → `pushPlain`（Sprite と Box）。ブラウザ版の cpu p50 34.3 → 29.9 ms（main は 31.3〜31.5）。PC は静かな状態の 4 回で frame p50 7.9〜8.6 ms が 3 回・11.8 ms が 1 回（main は 31.0〜32.1） |

| （ブラウザ版だけ）Flix の関数を呼ぶたびに、返った値へ `instanceof Thunk$` がかかる | `Thunk$` は Flix の関数の類（1 万を超える）がみな実装する interface。TeaVM の wasm-gc は interface の instanceof を、実装する類の番号と順に比べて答える。fps3d の部屋では、1 コマの CPU の 4 割がこの検査だった | ゲームの .flix では直さない。`bin/fge export-web` の付け替え（`fge.teavmfix.Rewrite`）で `FlixThunks.isThunk`（null でも final の `Value$`・`Suspension$` でもない）へ替える。書き出しの終わりに `rewrite instanceof-Thunk <数>` が出る | fps3d-room-bench（PC の headless Chrome・WebGPU）の cpu 中央 11.6〜13.3 → 7.1〜7.4 ms・split 4.3 → 1.9 ms・submit 8.4 → 3.8 ms。部屋の絵は WebGL2・WebGPU とも前後で 0 px の差 |

**PC だけで測らない。** 「JIT から外れる形」の 1 つ目の直しは PC で 3 倍速く、ブラウザ版では 9% 遅くなった（「それ以外」の 2 つ目で戻した）。
描く道を直したら `make bench-web` でも前後を 1 組測る。

- **ゲームの側でも同じ。** `bench/crowd2d` の 1 体ごとのループ（`Crowd.moveByGrid`）は、中から呼ぶ engine の `SpatialGrid.cellIndexOf` が
  末尾呼び出しで終わっていたせいでインタプリタのまま回っていた（engine の側を直して規則が 16% 速くなった。ベンチの .flix は直していない）。
  `bench/sprite_stress` の `List.range(0, n) |> List.map(i -> placedOf(i, t))` も、直した後の標本でインタプリタの frame に残っている
  （`placedOf` の片方の枝が `RawDraw.boxAt(…)` の呼び出しで終わる。直して確かめてはいない）。
  `bench/scene3d/src/Field.flix` の `instancesAt`（`List.map` のラムダが片方の枝で呼び出しで終わる）は、1 個ぶんを `@DontInline` の def に出して直した
  （PrintCompilation の「stack not empty at OSR entry point」の行が出なくなった）。
- **record の欄は今も 1 個ずつ名前で探す。** `Render.Item.Sprite` の 12 欄を全部読むのに 1 個 約 150 ns かかり、直した後の 20,000 個では 1 コマの 35% を占める。
  内側のループだけの値は enum に平らに並べる（`DrawCmd.Drawable`）か配列で運ぶ。
- 標準の並べ替えを毎コマの道に置かない（`Sort.sortStable*` か、鍵が小さな整数なら数えて振り分ける。§7）。

### JIT から外れたループの見つけ方

時間や割り当てでは見分けにくい。**どのメソッドがインタプリタで回っているか**を直に見る。ゲームのフォルダで:

```sh
# 1. JIT が途中から切り替えるのを諦めたまま（OSR）のループを出す。Flix の関数の名前に直し、後から通った物は外す
JAVA_TOOL_OPTIONS="-XX:+PrintCompilation" make run | bin/fge osr-skipped -

# 2. 走っている間の標本を取り、インタプリタで回っているメソッドを数える（type が Interpreted の frame）
JAVA_TOOL_OPTIONS="-XX:StartFlightRecording=filename=/tmp/rec.jfr,settings=profile" make run
jfr print --json --events jdk.ExecutionSample /tmp/rec.jfr \
  | jq -r '.recording.events[].values | select(.sampledThread.javaName=="main") | .stackTrace.frames[0]
           | select(.type=="Interpreted") | .method.type.name + "." + .method.name' \
  | sort | uniq -c | sort -rn | head
```

8,000 バイトを超えたメソッドは、ゲームでは `make lint-huge-methods`（遊ぶ時と同じ jar を作って数える）、engine では `make lint ONLY=huge-methods`（ベンチの jar を見るので、ベンチを流した後に打つ）で数える。
超えていて良い物（1 コマに 1 回・毎コマ通らない）は `bin/lint-rules/huge-methods.json`（ゲームは `huge-methods.local.json`）の exempt に理由 1 行で載せる。
大きさが 8,000 バイト未満でも、1 コマに 1 回しか呼ばれない関数の中のループは OSR を諦める事がある。こちらは class の大きさでは分からないので、上の 1 の `bin/fge osr-skipped` で見る（1 コマに 1 回だけ回る外側のループは、同じ exempt に `"モジュール.関数::osr-skipped"` で載せる）。

- スレッドダンプ（jstack）でも当たりは付くが、インタプリタのメソッドに偏って止まる。割合は JFR の標本で読む。
- `-XX:-DontCompileHugeMethods` を付けて速くなるなら 1 つ目の形。**旗で直さない**（ブラウザ版には効かない）。確かめにだけ使う。
- メソッドの名前の `$数字` は、インライン展開でできたラムダ。行の番号（`List.flix:798` は `foldLeft`）と、呼んでいる def の名前で元の場所を探す。
