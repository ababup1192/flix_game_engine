# ゲームが頑張らなくても速くなるデータ構造と API

レビューは 1 回目 58 点、2 回目 76 点。下は 2 回目の指摘まで入れた形。

## ゴール

- ゲームは小さな純粋関数を渡すだけで、重いループはエンジンが持つ。
- conduit_hive が手で書いた `Separation` の格子・`FlowField`・`GpuWarmup` の回避策が、エンジンの口へ置き換わる。
- 重い形を書いたら、lint が正しい口へ案内する。

**やらないこと**: レコードの欄の読み取りの速さを変える（Flix の仕組み）。ECS の作り直し。ゲームの規則をエンジンへ持ち込むこと。

## 決まり

1. **重いループはエンジンの中に置く。** 内側でレコードの欄を読まない。配列を 1 回作って回す。
2. **1 つずつスパイクで測り、効いた物だけ入れる。** 手書きの版より 10% 以上遅い口は入れない。
3. **結果は基準の版とビット単位で同じ。** 決定性（trace・リプレイ）を壊さない。`Separation` の基準は、升ごとの小計をやめて 1 本の蓄積へ直した版にする（足す順で丸めが変わるため）。この直しで conduit_hive の押し合いの値はわずかに変わる。
4. **ブラウザでも動く。** スレッド無しでも同じ結果で動く。

## `plans/engine-horde-perf.md` との関係

| あちらの行 | この計画 | 人の確認 |
|---|---|---|
| Separation 昇格候補（`engine_world Separation`） | 格子だけを `SpatialGrid` として昇格。押し合いの規則はゲームに残す | 要らない（候補の範囲） |
| FlowField 昇格しない・`Steering.downhillOf` を足す | **覆す: `FlowField` を足す（人の決定 2026-11-05「決めるところは、おすすめで」）** | 済み |
| G → B → A（GL の層 → joint texture → インスタンス描き） | そのまま。ブラウザ 3D の段 1 が G を兼ねる | 要らない |
| D `Par`（A の後に cpu_plan と姿勢が work の 20% を超えた時だけ） | 条件ごとそのまま | 要らない |

## API（案）

### 1. `SpatialGrid`（近くの物を引く格子）

```flix
pub type alias SpatialGrid = ...  // 非 pub の enum。外から中を見られない

pub def build(minCellSize: Float64, xs: Vector[Float64], ys: Vector[Float64]): SpatialGrid
pub def buildBy(minCellSize: Float64, items: List[a], posOf: a -> (Float64, Float64)): SpatialGrid

// 本命: 番号と位置だけを渡す。内側でゲームのレコードを読まない
pub def foldNearIndex(grid: SpatialGrid, x: Float64, y: Float64, radius: Float64,
                      init: b, f: (b, Int32, Float64, Float64) -> b \ ef): b \ ef
```

**約束**
- `minCellSize` は下限。実際の一辺は `Separation.cellSizeOf` のように、個数と広さから広がる（はぐれた 1 体で升が膨らまない）。
- `foldNearIndex` は半径の中の物だけを通す。自分も番号で通すので、飛ばすのは `f` の側で決める。`radius` が一辺より大きければ、見る升を広げる。
- `xs` と `ys` の長さが違うのは呼ぶ側の誤りなので `bug!`。
- `buildBy` の番号は `items` の並びと同じ。段 0 で `build` より 16〜24% 速かったので入れる。
- 内側のループは升の順の写しを持たず、`order` 越しに `xs`・`ys` を読む（番号を複数回使う形。1 回だけ使う形だと Flix の最適化が `f` を畳み込めず遅くなる）。
- `doc` に「`f` はその場のラムダで渡す」と書く。畳み込まれないと別の `f` も通る時に最悪 2.55 倍遅い。生成物か時間の検査を段 1 で 1 本置くかを決める。
- 回す順は行が外側、升の中は入れた順。これを手書きの版と合わせる。
- 中は Vector（Flix の Vector の実体は JVM の配列で、`Array.toVector` は写し 1 回。1000 体で 1 コマ 40 KB 前後）。
- 毎コマ作る格子は World に置かない（開発時の履歴 1800 コマが抱える）。`doc` に書く。
- 2D と 3D で使うので引数名は `x, y`。3D は足元の平面の `(x, z)` を渡す。
- `Collision` の中身は替えない。結果の順番が変わり、手元に使っている所も見つからなかった。
- 押し合いの `radii`・`ids` はゲームが持つ。エンジンが持つのは格子だけ。

**段 0 の結果（2026-11-05）**: 入れてよい。8 形すべて基準の版とビット単位で同じ（211 例・ゲーム本体の指紋も同じ）。n=1000 の 1 回の押し合いは、手書き 806 µs に対し `foldNearIndex` 192 µs（散らした場面）。蓄積の組の代金はラムダが畳み込まれればほぼ無い。ゲーム本体で `cpu_step` が 25〜30% 減り、1 コマの時間は動かない（重ねた描く側の陰に隠れる）。入れる理由は手書きの格子を消すことと、規則の余裕。

### 2. `FlowField`（共有する距離の地図）

```flix
pub def build(width: Int32, height: Int32, isOpen: (Int32, Int32) -> Bool,
              goals: List[(Int32, Int32)], opts: { neighbors = FlowField.Neighbors, maxSteps = Int32 }): FlowField
pub def empty(): FlowField
pub def stepsAt(f: FlowField, cell: (Int32, Int32)): Option[Int32]
pub def downhill(f: FlowField, cell: (Int32, Int32)): Option[(Int32, Int32)]
```

- 歩数はいつも 4 方向で塗る。`Neighbors` は下るマスの選び方だけを決める（4 方向か 8 方向。斜めは両脇が床の時だけ）。
- 下るマスを見る順は上 → 右 → 下 → 左 → 斜め。同じ歩数の時の選び方に効くので約束にする。
- `isEmpty` も足す（`Horde.flix:348` の「まだ塗っていない」の判定）。
- 塗る所を配列の幅優先にする（距離は順番によらず同じ）。
- `Steering` は替えない（使う所が 0 件で、歩き方も違う）。
- エンジンの名前は `fge::FlowField`。置き換えの後、ゲームの同名の mod は消す。

### 3. 間引きの口は足さない

`App.addSystemEvery` も、その代わりに考えた `Clock.isDue` も足さない。どちらも使う側が無い。
- conduit_hive の間引きは系の単位でなく「前に塗ってからの秒」で、既存の `Clock.tick` の形で足りている。
- `addSystemEvery` は、App が遊びのコマを知らず、飛ばしたコマの `justPressed` が消える。
- `isDue` は `withFixedStep` の刻みが 0 回のコマで境目を取りこぼし、置き換えると塗るコマも変わる。

2 本目のゲームが同じ形を書いた時に考え直す。`docs/performance.md` の「重くなったらこれ」に `Clock.tick` の使い方を 1 行書く。

### 4. 3D の先上げ

**4a: 材質のプログラムの上限を直す（ブラウザ 3D を待たない）**
- `Render3d/Material.flix:509` の `max(16, 今使っている数 × 2)` を `max(64, 今使っている数 × 2)` へ。プログラムは小さいので下限を上げるだけで足りる。
- `GpuWarmup` の `keep`（毎コマ置き続ける分）が消える見込み。起動直後の `all` は 4b まで残る。

**4b: `App.withPreload3d`（ブラウザ 3D の段 1 の後）**

```flix
pub def withPreload3d(plan: { key = w -> GameEngine.StaticKey, instances = w -> List[Scene3d.Instance3d] }, app: App[w, ef]): App[w, ef]
```

- `staticLayer` と同じ形。毎コマ読むのは `key` だけで、変わった時に `instances` を組み直す（Doc の読み直しで中身が変わるため）。
- プログラムの版は置いた物から導く（`vertexKindOf`）。描かない道なので、骨つきの物は姿勢を付けたまま渡せば組める。
- 置いた物から導けない `coverage` は両方の版を組む。
- 形と絵の印は絶対でなく優先度。予算を超えたら印の無い物から捨て、足りなければ印のある物も捨てて 1 回警告する。
- CPU の描き手と窓の無い描き手では何もしない。

実装（2026-11-06・未コミット）: `Platform.Draw3d.preload3d` を足し、受けたその場で `Render3d.Preload` が上げる。上げた物は `budgetEvictions`（形もこれへ移した）の捨てる順を後ろへ回す。材質のプログラムは数の上限しかないので必ず守る。`key` が 300 コマの内に 30 回変わると 1 回知らせる。

上の形から 1 つ変えた: `Instance3d` は `tex3d:` の絵の名前しか持たないので、plan に `textures = w -> List[Texture3d.Texture3d]` を足した（`withPreload3d(plan: { key, instances, textures }, app)`）。場面の `textures` から引く形だと、場面が来るまで上げられず、見つからない絵を待つ仕組みが要るため。

未測定の懸念: 全部を 1 コマで上げるので、ブラウザではそのコマの長さが問題になりうる（上げる量が多いゲームで、タブが止まって見える時間を測っていない）。1 コマに上げる量を分ける作りは入れていない。測ってから決める。

**0.88.0 の移行メモ（下書き。リリースの時に `docs/migrations/0.88.0.md` へ写す）**

- 足した口: `App.withPreload3d({ key, instances, textures }, app)`。初めて出る物を視錐台の外へ毎コマ置いていたゲームは、その物を `instances` へ、読む `tex3d:` の絵を `textures` へ移して消せる。骨つきの物は姿勢を外さず渡すと、骨つきの版も組める。描く時は今まで通り場面の `textures` にも載せる。
- 壊れる所: `Platform.Draw3d` に `preload3d` を足した。`handler Platform.Draw3d` を手で書いているテストは `def preload3d(_cmd, k) = k(())` を足す。`Platform.runNoopDraw3d` を使う所は直さなくてよい。
- `Scene3dRenderer.Renderer` に `preload` の欄を足した。手で組む描き手は `Scene3dRenderer.none()` を土台にするか、`preload = (_, _, _) -> checked_ecast(())` を足す。
- 絵: 3D の同じ平面に重ねた物の勝ち方が変わる場合がある（同じ形と材質の物をまとめて描くので描く順が変わる）。重ねるなら少しずらす。

### 5. 自動インスタンス描き（ゲームの変更なし）

- `plans/engine-horde-perf.md` の G → B → A をそのまま進める。
- G はブラウザ 3D の段 1 が兼ねる。B（joint texture）は 5〜6.5 日、A は 8〜10 日。骨つきの物の答えは B。
- 上限の見込みは submit −2.6 ms。PC とブラウザに 1 回で効く。

### 6. `Par`（条件つき）

- `plans/engine-horde-perf.md` の D のまま。A の後に `cpu_plan` と姿勢が work の 20% を超えた時だけ入れる。
- 型は `Vector`。`Par.map` は 16,384 個未満なら 1 本で回るので、群れには `mapChunked` を使う。
- 控えた patch の頭は 0.81.0。`engine-core-polish.md:145-157` の直しを当てる。
- `spawn` を使う点は、`Platform.Tasks` が handler に閉じた考えと向きが逆になる。入れる時に理由を書く。

### 7. lint

| 規則 | 見つける形 | 案内先 | 置き場 |
|---|---|---|---|
| `perf-near-scan` | `List.map` などの中の `List.filter` / `exists` / `find` | `SpatialGrid` | `lint-quadratic` を広げる（Go の道具と JSON。配れる） |
| `perf-list-index` | ループの中の `List.nth` / `List.memberOf` | Vector / Set | `docs/performance.md` 7 節の残り約 16 件と重ねて扱う |

- `lint/rules.flix` はゲームの側のファイルなので、エンジンが配れる `bin/lint-rules/` に置く。
- 最初は知らせるだけ。害を測れた形だけ止める規則へ上げる。
- conduit_hive の直す前のコミットに当てて、本当に重かった所を拾えるかを確かめる。
- 「引数に関係ない計算」と「内側の欄の読み取り」の 2 本は外す。データの流れの事実が足りず、誤検知が多い見込み。

## 順番

| 段 | 中身 | 先に要る物 | 大きさ |
|---|---|---|---|
| 0 | conduit_hive の `Separation` を 1 本の蓄積へ直す・測る土台・`SpatialGrid` のスパイク（蓄積の組・`List` → 配列・基準との比べ） | なし | 1〜1.5 日 |
| 1 | `SpatialGrid`・conduit_hive の置き換え・`perf-near-scan` | 0 | 2〜3 日 |
| 2 | `FlowField` と conduit_hive の置き換え | なし | 0.5〜1.5 日 |
| 3 | 4a の上限の直し | なし | 0.5 日 |
| 4 | G（ブラウザ 3D の段 1 と同じ）→ 4b | ブラウザ 3D の段 1 | 2〜3 日 |
| 5 | B → A | 4 | 13〜17 日 |
| 6 | 測ってから `Par` | 5 と 20% の条件 | 5〜7 日 |

段 0〜3 はブラウザ 3D と並行できる。ただしエンジンの同じファイルを 2 人で触らない。

**段 1・2 の結果（2026-11-05・未コミット）**: `SpatialGrid` と `FlowField` を engine_world に足し、conduit_hive を置き換えた（手書きの `src/FlowField.flix` は消した）。`perf-near-scan` と `perf-list-index` も入れた。

| 測った物 | 前 | 後 |
|---|---|---|
| 手書きと API の比べ・n=1000・散らばり | 806 µs | 192 µs |
| 同・固まり | 976 µs | 287 µs |
| 同・積み重なり | 4984 µs | 3179 µs |
| conduit_hive の `cpu_step`・horde1000 | 2.669 ms | 1.779 ms（−33%） |
| conduit_hive の `cpu_step`・waves | 2.86 ms | 2.169 ms（−24%） |

手書きとの比べの結果はビット単位で同じ。1 コマの時間は約 12 ms で変わらない（`withPipelinedRendering` が規則の時間を描く時間の裏へ隠すため）。conduit_hive は手で直した fpkg で動かしていて、エンジンの次のリリースまで push できない。

G はブラウザ 3D の段 1 で済んだ。段 3（4a）も済んだ（効果は未測定）。次は 4b。

## 門（どの段も）

- 測り方: `FLIX_GE_NO_VSYNC=1` で `bench-horde` の `horde1000` と `horde-waves1000`。基準の値（段 0）: horde1000 は 1 コマ 12.0〜12.4 ms・`cpu_step` 2.66〜2.87 ms。horde-waves1000 は 1 コマ 11.81 ms・`cpu_step` 3.18 ms。
- 規則の段（1〜2）は `cpu_step` の中央値の悪化が 5% まで。重ねた後は規則の遅れが 1 コマの時間に出ないため。`cpu_column` の指紋で同じ列かを見る。湧く組は `BENCH_MICRO_WARM=1800` を付ける。`FLIX_GE_FIXED_DT` は 1 コマの時間を壊すので付けない。
- 描く側の段（3〜5）は /perf の同じ列で比べ、悪化は 5% まで（/perf は描く側しか測らない）。
- 基準の版と同じ結果になるテスト（小さな例と乱数の例）。
- App を触る段の前に、`engine-horde-perf.md` の「まだ無いテスト」（重ねる道の固定）を足す。
- 層のテストは `.layers` で流す。ブラウザの書き出しで ERROR 0 件。
- conduit_hive へは手元の fpkg でつなぐ（未リリースの口のため）。
- 2D は `SpatialGrid` を `bench/` の 2D の群れで測る（新しく作る）。
- `agents-pack/AGENTS.core.md` の早見表に 1 行、`agents-pack/agent-eval/engine.json` にお題を 1 本、`docs/performance.md` に「重くなったらこれ」の表、`docs/api-digest.md` の更新と移行メモ。
