# Flix 0.78 データ構造・書き方の実行時コスト（調査と小計測）
日付 2026-11-14 / 機械: 12 コア Mac（別ベンチが並走・load 5〜7）/ JDK 21 Zulu / Flix 0.78（engine の bin/flix.jar）。
印: 【確】=実装(jar のソース・javap したバイトコード)を読んだか測った / 【推】=推測 / 【不明】=分からない。
計測の生出力: scratchpad `flix-ds/raw-*.txt`、コード: `flix-ds/bench/src/*.flix`、javap の元: `flix-ds/jclasses/`（`bench.jar` を展開）、`flix-ds/jp.sh`。
**数字は 1 区間 20,000 個・温めた後の中央値。JIT の当たり外れで 10 倍ぶれる所がある（後述の「注意」）。比の大小だけを信じる。**

## 0. 最大の発見: 0.78 の呼び出しの形（javap で確認）【確】
- 全ての Flix 関数は `Result$`（`dev.flix.runtime`）を返す。呼ぶ側は `while (r instanceof Thunk$) r = r.invoke()` + `Suspension$` の検査を毎回出す。
  プリミティブの戻り値は `Value$`（欄 b,c,i8,i16,i32,i64,f32,f64,o を全部持つ大きな物）に包んで `new` する（例: `Int32/Def$toFloat64.staticApply` は `new Value$` して `f64` に入れる）。
  C2 が inline できれば逃げ解析で消えるが、inline できない呼び（大きい関数・megamorphic な閉包）では 1 呼びごとに割り当てが出る。
- 関数の値は `Fn1$Int32$Obj` `Fn2$Obj$Obj$Float64` のように引数・戻りの型ごとの abstract class（`arg0..` 欄 + `invoke()`）。Float32/Float64/Int32/Int64 などの引数はプリミティブのまま持つ（`Fn1$Float32$Obj`）。
- 標準の `List.map` `foldLeft` `forEach` と `Vector.map` などはこのビルドで**呼び側へ inline されて消えていた**（`List/Def$foldLeft` のクラスが無い）。`def` の再帰 `@Tailrec` は loop になる【確・クラスに List 版が無い／計測 h2≈h3】。
- 出どころ: `bin/flix.jar` の `dev/flix/runtime/{Value$,Result$,Thunk$,Suspension$}.class`、`ca/uwaterloo/flix/language/phase/jvm/classes/Gen*.class`（GenRecordExtend, GenStruct, GenTuple, GenTagged）、ビルドした `bench.jar` の `Bm1/Def$mk32.class`。コンパイラのソースは jar に無い（クラスのみ）ので GitHub の flix/flix は読んでいない【不明: 単相化・Eraser のソース】。

## A. データ構造ごとの表（JVM 表現・代金・ボックス化・向き不向き）
| 型 | JVM 上の形【確】 | 読む | 作る / 足す | プリミティブ | 向き・避け方 |
|---|---|---|---|---|---|
| record `{x=..}` | `RecordExtend$Float32/Float64/Int32/Obj`（label:String・value・rest の**連結リスト**）。`Record$` interface | `lookupField` が `label.equals(name)` を再帰（interface 呼び）。**先頭の欄は 2 ns、後ろは欄 1 つ進むごとに約 1.5 ns 増え、11 欄の最後で約 16 ns**（測定 c3〜c7）。並びは**リテラルに書いた順**（`{z=..,x=..}` と書くと z が先頭）。型 alias にしても同じ（型は消える） | 11 欄で 33 ns（tuple 11 ns・struct 6〜9 ns）。`{x=3 \| r}` は restrictField が手前の節を全部作り直す（バイトコード）= 位置に比例 | Float32/Float64/Int32 は節ごとに専用クラスでボックス化なし。Int64・Bool・Char などは【推】Obj か専用（今回 Int32/Float32/Float64/Obj の 4 種だけ生成を確認） | 欄は 3 つ以下か、熱い欄を**リテラルの先頭**に。内側の輪では `let` に 1 回だけ受ける。大量の物の運搬には使わない |
| struct（0.78 にある） | `Struct$Float64$…` 1 つのクラス、欄 field0.. が**プリミティブのまま**（`Struct$Int32$Float32$…`） | 定数（欄の読み）。**不変の欄の読みは純粋**、`mut` の欄だけ region の effect（公式文書）。11 欄を 11 回読んで 0.8 ns/個（JIT で畳まれる）| `new S @ rc {..}` で 6〜9 ns | 無し（unboxed） | 欄は**同名の mod の中だけ**で読める（`mod S32 { pub struct S32[r] {..} }` とファイル名 `S32.flix`・`pub mod` と struct の pub を合わせる）。外へは getter / 書き出し関数を pub。region が型に付く（`Array[S32[rc], rc]`）。**record の代わりに「描く物 1 個」を運ぶなら最有力** |
| tuple | `Tuple$Float32$…`（`field0..` プリミティブのまま） | 定数 | 11 欄で 11 ns | 無し | 名前が無いので 4 つ以内。パターン `let (a,b,..) = t` で 1 回で出す（ラムダの引数位置にタプルパターンは書けない=コンパイルエラー確認） |
| enum | `Tag$Obj` `Tag$Int32$Obj` `Tag$Obj$Obj`…（`v0,v1` 欄）。case 無し側は `Case$…$Nil` の 1 個 | match は ordinal 分岐【推】 | 1 case の enum は**消えない**（余分に 1 つ割り当て: Boxed(record) の create 41 ns 対 33 ns）| payload の Int32 は Tag$Int32$Obj で unboxed | newtype 目的の包みは作る代金が +25%・読みは +数 ns。導出 `Eq/Order/ToString` の代金は【不明】（今回測らず）。record を payload に持つと `Eq` が使えない（engine の既知） |
| List | cons（Nil は共有） | `get(i)`・`length` は O(n) | `map` は逆順に積んで `reverse`（**中間リスト 2 つ**）。`append` は第 1 引数を作り直す。融合は**無い**（map×3 で 12.2 ns/個、foldLeft 1 回で 1.2 ns/個＝10 倍）| 要素は Obj（Float32 は Float 箱）| 小さい・順に舐める・先頭へ積む用。`++`/`append` を fold の中に置かない |
| Vector | **Flix の配列と同じ JVM 配列**（engine docs の記述＋`Vector.get` は `%%VECTOR_GET%%` 命令、`toArray` コピー）。`Vector[Float32]` は【推】`float[]`（`Array[Float32]` が `float[]` なのは engine の `FloatBuffer.put(scratch)` で確認）| `get` は O(1) 命令 | `Vector.map` は `init`→配列に書いて Vector 化。3 回つなぐと 1.9 ns/個（List の 1/6）| 配列側が primitive | 読み取り専用で添字が要る所の標準 |
| Array | region つき。`Array.get/put` は `%%ARRAY_LOAD/STORE%%` 命令 | O(1) | `Array.repeat/empty` | Float32/Int32 は `float[]`/`int[]`【確: Array.flix の命令名＋engine の Java 渡し】 | 内側の輪の書き先。Java の `float[]` と同じ物 |
| MutList | **struct** `MutList[a,r]{ r, mut values: Array, mut length }`（stdlib の MutList.flix） | `get` は `nth`→Option→match | `push` は容量倍増 | Obj 配列 | 要素数が先に分からない時の溜め先 |
| Chain / Nel / DelayList | Chain=`Empty/One/Chain(l,r)` の木（append が O(1)）、Nel=head+List、DelayList=遅延 | — | 今回測らず【不明】 | — | Chain は「後ろへ足し続けて最後に 1 回 toList」用【推】 |
| Map / Set | `Map` は enum `Map(RedBlackTree)`＝赤黒木（stdlib の Map.flix / RedBlackTree.flix）。**MutMap は struct で中身は `mut inner: Map`＝同じ木**（ハッシュではない）。`MutHashMap`/`MutHashSet` が 0.78 に別にある | `get` O(log n)＋`Order[k]` の辞書呼び: 100 キーで **28〜137 ns（JIT 次第・下記注意）**。`MutHashMap[String]` 3.9 ns、Java `HashMap` 2.4 ns、Vector の添字 3.4 ns | `Map.insert` 280 ns/個、`MutHashMap.put` 304 ns/個（1000 個の新規 insert）| キーの Int32 は Obj 箱 | 毎コマ `Map[String,_]` を引く所は、**起動時に Int の添字へ**して `Vector.get`、または `MutHashMap` に。record は `Order` を持てないのでキーにできない（tuple は可: 20 ns） |
| String | `java.lang.String` | `==` 1.5 ns（同内容・別物 22 字）/ `Hash.hash` 0.8 ns | `"x${i}"` 補間 19 ns・`String.concat` 9 ns・StringBuilder(3 append) 16 ns | — | 毎コマ作らない。鍵にするなら Int に |
| クロージャ | `Fn/Clo` クラス（上記）。**inline できる場所では消える**。配列に入れた閉包を別々に呼ぶ（4 種）と 6.0 ns/呼び（Float32→Float32 も 6.4 ns）、`@DontInline` の def 呼びは 0.3〜0.7 ns（C2 が inline）| — | — | 引数・戻りは primitive 専用クラスで箱なし（Fn1$Float32$Obj など）| ラムダを**変数に入れて持ち回る**と inline されず 6 ns/呼び（engine の docs/performance.md §12 の `foldNearIndex` の注意と一致）。def は 0.78 ではカリー化されない【推: 部分適用は閉包を作る】。`x \|> f \|> g` は `g(f(x))` と同じ（測定 c7≈c8）|
| effect | `Eff$X` クラス＋`Suspension$`（継続 `Resumption$`/`Frames$` を作って handler へ）。`run … with handler` は GenHandler | — | **1 回の操作 ≈ 50 ns**（素の Ref 操作 1.3 ns。handler がすぐ `resume`）。操作が 100 個に 1 回の疎な形では 1 回あたり約 240 ns になった（JIT 次第）。`run{…} with handler` を要素ごとに入れ直すと 131 ns/回 | 引数・戻りは `ResumptionWrapper$Float32/Int32…` で primitive 専用 | **内側の輪（1 万〜2 万回）の中で effect を呼ばない**。effect は「1 コマに数回」まで。純粋・IO だけの関数は継続を作らない |
| region | `Region$`（GenRegion） | — | 作る代金は【不明】（今回測らず。`region rc` は 1 コマに 1 回でよい）| — | 内側の輪の外に 1 つ |
| 数の型 | Float32/Float64/Int32 は関数の引数・戻り・record/tuple/struct の欄でプリミティブ。**関数の戻りだけは `Value$` に包む**（0 章）| `Float64.truncateToFloat32` `Int32.toFloat64` は stdlib の def（Java の `Integer.valueOf(..).doubleValue()` を呼び結果を `Value$` に入れる）= **inline されなければ呼び 1 回ごとに割り当て** | — | 型クラス辞書（`Order[k]`）は【推】単相化で消えるが、Map の木の中の比べは辞書の呼びが残って見える（Map.get の遅さ）| 総称関数（`Add[a]` 等）を通した時の箱化は【不明】（測らず）。engine の `RenderUtil.f32` は `Float64.truncateToFloat32` の薄い包みで、熱い輪では変換回数を減らす |
| Java 直使い | `java.nio.FloatBuffer`・`HashMap` は `import` して呼べる（mod の中に import）。`Array[Float32,r]` は `float[]` なので `fb.put(scratch)` に渡せる【確: engine の packDraw・今回 h2】| `FloatBuffer.put(int, float)` の絶対 put は 3.5 ns/物（16 float 書き）| — | primitive のまま | キャスト・`checked_cast`・null の扱いは今回 HashMap の戻り値を `.hashCode()` するだけ試し、**checked_cast は測っていない**【不明】 |
| その他 | 末尾呼び出し: 自己再帰は loop（`@Tailrec`）、相互再帰は thunk に戻す【推: Thunk$ の仕組みから】。`lazy`・例外・`MethodTooLarge`: 測らず【不明】（engine の既知: full build の MethodTooLarge は肥大テスト。`flix check` で足りる）。**sort は標準の `sortBy`/`sortWith`/`Array.sortWithin` が全部 Lomuto クイックソート・基準は範囲の最後・安定でない**（stdlib の Array.flix `sortWithin`/`quicksortPartition`）| | | | 0.78 のリリースノートの速さの話: 読めていない【不明】（URL を引いていない）|

出どころ URL・jar の道:
- struct: https://doc.flix.dev/structs.html（unboxed・不変欄は純粋・companion mod の中だけ欄が見える）、record: https://doc.flix.dev/records.html（性能の記述は無い）
- stdlib（jar の `src/library/*.flix`）: List.flix `map`（`loop`+`reverse`）/`foldLeft`(@Tailrec)/`sortBy`(`toArray`→`Array.sortBy`→`toList`)、Vector.flix `map`=`init`・`get`=`%%VECTOR_GET%%`、Array.flix `sortWith`/`sortWithin`/`quicksortPartition`・`%%ARRAY_NEW/LOAD/STORE%%`、MutList.flix の `pub struct MutList`、MutMap.flix の `pub struct MutMap{ rc, mut inner: Map }`、Map.flix の `enum Map(RedBlackTree)`。API 一覧: https://api.flix.dev/
- jar のクラス（`bin/flix.jar`）: `dev/flix/runtime/*`、`ca/uwaterloo/flix/language/phase/jvm/classes/Gen{RecordExtend,Struct,Tuple,Tagged,Handler,Suspension,Region}*.class`

## B. このリポジトリが既に知っている事と A の突き合わせ
| 既知（出どころ） | A・C との関係 |
|---|---|
| record の欄は読むたびに名前で探す・熱い所は `let` に 1 回（performance.md §12・plans/engine-scene3d-cpu.md 4）| 合う。**さらに「欄の位置で値段が違う（先頭 2 ns・11 番目 16 ns）」「並びはリテラルの順」は A で初めて分かった**。`Mat4`（record）を `Mat4.apply` で何度も引く所は、熱い欄をリテラルの先頭にする手がある（型は変えない）|
| RESULTS.md: record をやめて Float32 配列・比べる並べ替えをやめて 37 倍 | 合う。C: record の List の 11 欄書き出し 121 ns/個 対 列の `Array[Float32]` 3.1 ns・struct の Array 4.6 ns・tuple 4.4 ns（**25〜40 倍**）。作るのは record 33 → struct 6〜9 → 列 2.9 ns |
| `List.sortBy` は安定でない・キー関数が比較ごとに 2 回（performance.md §7・flix-docs）| 合う。**さらに C: 同じ入力でも `sortBy(fst)` は `sortWith(cmp)` の 1.7〜5.7 倍遅い**（重複の多いキーで 873 対 153 ns/個）。並んだ入力・同じキーは**二乗**（n=5k/10k/20k で sortWith 20/72/337 ms、sortBy 143/484/1538 ms）|
| plans/engine-sort-quadratic.md の「Lomuto・基準が最後」 | 合う（stdlib のソースで確認）。バケツ分配 27 ns/個（キー 100 種）、**カウンティングソート 1.7 ns/個**（Int32 配列だけ）。キーが広い（1e6 種）時のバケツ配列は 213 ns/個で負け（配列が大きすぎ。`mergedByZ` の `seatLimit` と同じ理由）|
| `onceOutsideLoop`・「純粋な let が 1 回使いならラムダへ書き写される」（performance.md §6）| **C でも再現した**: 純粋な `let v = f(i)` を計測の外で使うと f の仕事が時計の外へ動き、`0.0 µs` になった。`Ref.put(f(i), cell)` で時計の内側に固定した（Harness.flix）|
| effect の handler はスレッドをまたがない・並列は純粋だけ（engine-core-polish）| A で初めて: effect 1 操作 ≈ 50 ns なので、内側の輪に置かない |
| `Map.map` は純粋なら並列（engine-core-polish 3.）| 今回は測らず |
| `Array[Float32]` を `FloatBuffer.put` に渡す（Instancing.packDraw）| 合う（h2: scratch[16]→`put(float[])` 5.9 ns/個、絶対 put 3.5 ns/個、配列直 3.1 ns/個）|

engine の「速い形」の手本（`bin/fge refactor` で確認した名前）:
1. `RenderFrame.mergedByZ`（src/render_gl/Frame.flix:70）— 比較なしの安定スロット分配。`region`+`Array[List[Merged]]`、幅は Int64 で見る、広い時は範囲番号→範囲内スロット。
2. `Render3d.Instancing.packDraw`（src/render_gl/Render3d/Instancing.flix:81）— 1 体ぶんを `Array[Float32,Static]` の scratch に組み、`FloatBuffer.put(scratch)` で 1 回で詰める。
3. `SoftRaster.onceOutsideLoop`（src/engine_tools/SoftRaster.flix:483）— ループの外の式を `Ref` で動かされない形に。
4. `SpatialGrid.buildBy` + `foldNearIndex`（docs/performance.md §12）— ラムダはその場で渡して inline させる（C: 変数に入れて持ち回ると 6 ns/呼び）。
5. （計画）`Par.mapChunked` — `spawn`+`Channel`（plans/engine-core-polish.md）。

## C. 計測（N=20,000・中央値・ns/個。生出力は raw-*.txt）
実行コマンド（毎回 1 本・各 5〜30 秒）: `cd /Users/abab/Desktop/flix_game_engine && devbox run -- bash -c 'cd <scratchpad>/flix-ds/bench && bin/flix run --entrypoint Bm1.main'`（`bench/run.sh <Mod.entry>`）。ブートは約 3 秒、12 コアの別ベンチと並走（load 5〜7）。
### C1 描く物 1 個（11 数）の形ごと（作る / 16 Float32 を配列へ書く）
| 形 | 作って列にする | 列をなめて 16 float を書く |
|---|---|---|
| (a) record(Float64) の List | 33.3 | 121.3 |
| (a') record(Float32) の List | 42.0 | 123.9 |
| (b) record の Vector | 53.5 | 130.4 |
| (c) 欄の順を逆にした record の List | 31.1 | 184.1（熱い欄 x,y,w,h を後ろに置いた）|
| (d) struct の Array（Float32 / Float64 の作り） | 9.3 / 6.0 | 4.6 |
| (e) tuple(11) の List | 10.7 | 4.4 |
| (f) 1 case の enum(record) の List | 41.0 | 137.9 |
| (g) 欄ごとの `Array[Float32]`（列） | 2.9（11 本） | 3.1 |
| (h) `FloatBuffer`（direct）へ絶対 put / scratch[16]→`put(float[])` | — | 3.5 / 5.9 |
欄の引き当て（同じ欄を 11 回読む 1 個あたり）: record 先頭 23 ns・中ほど 96 ns・最後（Int32）175 ns / 逆順 record は先頭 9 ns・最後 183 ns / struct 0.8 ns。
### C2 並べ替え（20,000 個。タプル (key, id)）
| | キー 100 種(重複多) | キー 1e6 種 |
|---|---|---|
| `List.sortBy(fst)` | 873 | 264 |
| `List.sortWith(cmp)` | 153 | 88 |
| `Vector.sortBy` | 848 | 247 |
| `Array.sortBy`（コピー込み）| 847 | 242 |
| バケツ（`Array[List]`+flatten）| 27 | 213（配列 100 万は不向き）|
| カウンティング（Int32 配列）| 1.7 | 28.8 |
| 参考: `List.map` のコピーだけ | 8.5 | 8.7 |
並んだ入力 / 同じキー（二乗）: sortWith n=5k/10k/20k = 20 / 72 / 337 ms、sortBy = 143 / 484 / 1538 ms。同じキー n=20k: sortWith 378 ms・sortBy 1123 ms。
### C3 高階関数（同じ計算 `((x*3+1)*2)-5` の和）
List.map×3+foldLeft 12.2 / foldLeft 1 回 1.24 / 手書き末尾再帰 1.23 / `List.forEach` 1.24 / `foreach (x <- xs)` 1.32 / Vector.map×3+foldLeft 1.9 / Vector.foldLeft 0.32 / 添字ループ 0.35。呼び: 配列に入れた未知のラムダ 6.0（Float32→Float32 6.4）/ `@DontInline` def 0.28（Float32 0.66・Float64 0.69）/ パイプ 0.275 ≒ 入れ子 0.29 / IO の def 0.29。
注意: 0.3 ns/個は JIT がループを畳んだ値（演算だけの `c3` が 1.9 と逆転している）。**絶対値でなく「中間リスト 10 倍」「未知の閉包 +6 ns」の比だけ使う。**
### C4 effect
素の Ref ループ 1.3 / 輪の中で effect 操作 1 回 50.8（Unit 引数 51.1）/ 100 個に 1 回の操作は平均 3.7（1 操作あたり約 240）/ 要素ごとに `run…with handler` に入って 1 操作 131。
### C5 Map など（100 キー）
`Map[String]`.get 27.7（同じプロセスで最初）/ 136.5（そのキーだけで別プロセス）/ `Map[Int32]` 118.8 → 別プロセス 107.5 / `Map[(Int32,Int32)]` 20.2 / `MutMap[String]` 32.2 / `MutHashMap[String]` 3.9 / Java `HashMap.get` 2.4 / `Vector.get` 3.4。insert 1000 個: Map 280・MutHashMap 304。文字列: 補間 19.3・`String.concat` 9.3・StringBuilder 15.9・`==` 1.5・`Hash.hash` 0.8。
**注意: Map の get は 28〜137 ns と 5 倍ぶれた**（JIT が `Order` 辞書呼びを inline できるかで変わる）。木の get は「数十〜百 ns」と読む。

## まとめ — 描く物の列・3D の計画を書き直す時の指針
1. **「1 個ぶんの運び荷」は struct か Float32 の列/配列にする**（record をやめる）。record の 11 欄書き出しは 121 ns/個、struct 4.6・tuple 4.4・列 3.1。出どころ: A の javap（RecordExtend 連結リスト）＋C1。内側の輪（`packDraw` 型）だけ閉じ込める。外（`Instance3d` の pub の型）は今の record のまま。**折り合い**: struct は欄が `mod S` の中でしか読めないので、「欄を読む関数ごと同じ mod に置き、外へは `writeTo(out, off, s)` だけ pub」にする。AGENTS.md の「読みやすさ」には、mod を 1 つ足す代金で釣り合う（`record-wrap` の流儀に近い）。
2. **record を残す所は、熱い欄をリテラルの先頭に書く**・輪の前に `let` で 1 回受ける。欄の位置で 2 ns〜16 ns（C1）。型 alias の順は無関係、**作る側のリテラルの順**。pub の型は変えずに済む。
3. **中間リストを作る map の連鎖をやめる**: List.map×3 は 12 ns/個、1 回の foldLeft は 1.2（10 倍・融合なし）。計画では `Vector.map`（1.9）か 1 本の `foldLeft` で書く。純粋な関数を好む流儀と両立（どちらも純粋）。
4. **並べ替えは `List.sortBy` を使わず、(a) 鍵が小さな整数ならバケツ/カウンティング（27 / 1.7 ns/個）、(b) 汎用なら `sortWith` に直接比較を渡す**。`sortBy` は `sortWith` の 1.7〜5.7 倍遅い上、並んだ入力・同じ鍵で二乗（20,000 個で sortBy 1.5 秒）。出どころ: stdlib Array.flix（Lomuto・末尾基準）＋C2。plans/engine-sort-quadratic.md の「共通の安定マージソート」はこの表の「sortWith の 1/3〜1/6 を保てる」ことを門にする。
5. **内側の輪で effect を呼ばない**（1 回 50〜240 ns、`run…with` を毎回入れると 131 ns）。AGENTS.md の「`run … with` は 1 関数に 1 つ」とは同じ向き。輪の外で値を引き出して純粋な関数へ渡す（Bevy の render-from-World と同じ）。
6. **ラムダを変数に入れて内側の輪へ持ち回らない**（未知の閉包 6 ns/呼び対 inline 0.3）。リテラルのラムダのまま `foldLeft` などに渡す。engine の `foldNearIndex` の注意と一致。
7. **毎コマ `Map[String,_]` を引かない**。起動時に Int の添字へ引き直し `Vector.get`（3.4 ns）か `MutHashMap`（3.9）。`Map` は 28〜137 ns でぶれる。record はキーにできない（tuple 20 ns は可）。
8. **Float32 への変換は輪の外か 1 回**。`Float64.truncateToFloat32` と `Int32.toFloat64` は関数呼び＋`Value$` の割り当てで、inline されないと高い【推・javap の形】。Float32 を列で持てば変換は作る時の 1 回で済む。engine の「pub に Float32 を出さない」とは、Float32 を**内側の輪の中だけ**（struct/配列の内部）に閉じ込めれば衝突しない。
9. **書き込み先は `Array[Float32, rc]`（= `float[]`）か direct `FloatBuffer`**。配列直 3.1、FloatBuffer の絶対 put 3.5、scratch→`put(float[])` 5.9 ns/個。`packDraw` の形で十分速いので、まず形を直してから Java に降りる。`match` を入れ子にしない流儀は、`let (a,b,..) = t` で 1 回に出す形で守れる。
10. **計測の作法**: 純粋な `let v = f(..)` は時計の外へ動く（再現した）。`Ref.put(f(i), cell)` で固定する。JIT のぶれ（Map 5 倍・0.3 ns の畳まれ方）があるので、**案を入れる前後は engine の `bench/sprite_stress`・`bench/scene3d` の背中合わせで見る**。ここでの数字は設計の順位づけ用。

## 測れなかった・不明
region 作成の代金／導出した Eq・Order・ToString の代金／`Chain`・`Nel`・`DelayList`／総称関数（型クラス）経由の箱化／`checked_cast`・null／`lazy`・例外／`MethodTooLarge` の閾値／0.78 リリースノートの速さの記述／コンパイラ本体（単相化・Eraser）のソース（jar はクラスのみで GitHub を読んでいない）／相互再帰の末尾呼び出し。
