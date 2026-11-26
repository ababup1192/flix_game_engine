# 物理（2D の剛体・決定性の決まり）

engine の剛体の物理は Flix で自前で書いた物で、物理の World は**不変の値**（`PhysicsWorld2d`）。ゲームの World の欄に 1 つ置き、
App が固定刻みで進める。体の id は ECS の `EntityId`。3D（`PhysicsWorld3d`）も同じ形と同じ道具（`Rot2`・`Quat`・`PortableMath`・`StateHash`）で作る予定。

## 決定性の決まり

約束するのは「**同じ入力を与えた物理の World は、JVM と wasm（ブラウザ）で同じビットになる・足す順によらない・巻き戻しても同じ**」まで。
ゲーム全体のテープを機種をまたいで流せるかは、入力の側（角度から向きを作る所など）にも同じ決まりを当てた時だけで、約束しない。

守り方は 3 つ:

1. **物理の中は足し引き掛け割りと平方根だけ**。向きは `Rot2`（cos・sin の組）のまま回し、角度は持たない。角度から作るのは
   `Rot2.fromDegrees`・`fromRadians`（`PortableMath.sin`・`cos` を通る）だけ。物理のファイルで `Num.sin` などを書くと
   lint-forbid の `physics-portable-math` が止める。
2. **回る順は `EntityId` の順**。体は id の順に並べて持ち、並べ替えは安定な物（`Sort.sortStableWith`）か `long` の並べ替えだけ。
3. **指紋はビットから**。`StateHash` が Float64 のビットを 64 bit の FNV-1a へ流す（数を字にしない）。

穴: `Rot2.fromCosSin(c, s)` は組をそのまま信じる口で、`Num.cos`・`Num.sin` で作った組を渡すと型は止めない
（lint の `rot2-from-num` が知らせるだけ）。

## 道具（engine/src/core）

| 名前 | 何か |
|---|---|
| `Rot2.identity`・`fromCosSin`・`fromDegrees`・`fromRadians`・`cos`・`sin`・`mul`・`inverse`・`rotate`・`nlerp`・`toRadians`・`toDegrees` | 2D の向き（Box2D 3 の `b2Rot`） |
| `PortableMath.sin`・`cos`・`atan2`・`sqrt`・`pi` | JVM と wasm で同じビットを返す数の道具 |
| `StateHash.start`・`mixFloat64`・`mixInt64`・`mixInt32`・`mixBool`・`toInt64` | 状態のビットの 64 bit の指紋 |

描くだけの計算（色・画面の揺れ・カメラ）は `Num` のままでよい。ずれても絵が数画素違うだけで、World は分かれない。

## 2D の剛体を使う（PhysicsWorld2d）

置き場は engine_world。体の id はゲームの `EntityId`。積む・転がす・押し合う剛体はこれを使う（今ある `Physics2D`・`CollisionShape2D` は、自分で動かす物の重なりと押し出しを聞く小さな道具で、積み重ねと眠りを持たない）。単位は m・秒・kg で、y は下が正（画面と同じ向き）。
描く時は 1 m あたりの画素（ゲームが決める）を掛ける。形は円・箱・凸多角形（8 頂点まで）。関節・CCD・凹んだ形は無い。

| 名前 | 何か |
|---|---|
| `PhysicsWorld2d.empty(settings, stepSeconds)`・`settings()` | 空の World（刻みは `App.withFixedStep` と同じ値） |
| `PhysicsWorld2d.insert(id, body, w)`・`remove(id, w)` | 体を足す・消す（同じ id の insert は置き換え。出来事は出さない） |
| `RigidBody2d.dynamic`・`kinematic`・`fixed`・`withRotation(Rot2)`・`withLinearVelocity`・`withAngularVelocity` | 体の作り |
| `Collider2d.circle`・`box`・`convex(頂点)`・`withMaterial(名前)`・`withSensor`・`withCollisionLayers(layer, mask)`・`withMass` | 体の中の形 |
| `PhysicsWorld2d.applyImpulse`・`applyImpulses`・`setLinearVelocity`・`setAngularVelocity`・`setKinematicTarget`・`setPosition`・`wakeUp` | 外から動かす（World を最後に） |
| `PhysicsWorld2d.positionOf`・`rotationOf`・`linearVelocityOf`・`bodies`・`isSleeping`・`colliderOf`・`interpolatedPoseOf(id, alpha, w)` | 読む（render-from-World） |
| `PhysicsWorld2d.events(w)`・`CollisionEvent2d`・`SensorEvent2d` | 直前の 1 刻みの出来事 |
| `PhysicsWorld2d.castRay`・`queryPoint` | 光線・点の当たり（当たり層の mask で絞る） |
| `PhysicsWorld2d.stateHash` | 状態のビットの指紋（体・触れている組・warm start の控え） |
| `PhysicsMaterial`・`PhysicsWorld2d.withMaterials`・`withSettings`・`PhysicsDoc2d.load`・`loadOr`・`applyTo` | 材質と `physics2d.kind.json` |
| `App.addPhysics2d({ physicsOf, withPhysics, clockOf, onEvents })`・`ViewCtx#physicsAlpha`・`fixedAlpha` | App が固定刻みで回す・補間の割合（物理の体・系で動かす主役とカメラ） |

### 手本: 同じ大きさの石が触れたら 1 つ上の石に合わせる

```flix
// World の欄: physics = PhysicsWorld2d.PhysicsWorld2d・play = Clock.Clock[Play]・paused = Bool
//             stones = Map[EntityId, Int32]（大きさの段）・nextId = EntityId
//             hits = Emit.Events[CollisionEvent2d.CollisionEvent2d]（onEvents が積む）・seen = 同じ型（系が前に読んだ所）
def stoneBody(at: Vec2.Vec2, rank: Int32): RigidBody2d.RigidBody2d =
    RigidBody2d.dynamic(at, Collider2d.circle(0.15 + 0.05 * Int32.toFloat64(rank)) |> Collider2d.withMaterial("stone"))

/// 系: 前に読んだ所から後に積まれた Started だけを読み、同じ段の組を 1 つ上の石へ合わせる。
def mergeTouches(_f: App.Frame, w: World): World =
    let fresh = Emit.since(w#seen, w#hits) |> List.filterMap(CollisionEvent2d.startedPair);
    fresh |> List.foldLeft((acc, pair) -> mergeIfSameRank(pair, acc), { seen = w#hits | w })

def mergeIfSameRank(pair: (EntityId, EntityId), w: World): World =
    let (a, b) = pair;
    match (Map.get(a, w#stones), Map.get(b, w#stones), PhysicsWorld2d.positionOf(a, w#physics), PhysicsWorld2d.positionOf(b, w#physics)) {
        case (Some(ra), Some(rb), Some(pa), Some(pb)) if ra == rb =>
            let mid = { x = (pa#x + pb#x) / 2.0, y = (pa#y + pb#y) / 2.0 };
            let physics = w#physics |> PhysicsWorld2d.remove(a) |> PhysicsWorld2d.remove(b) |> PhysicsWorld2d.insert(w#nextId, stoneBody(mid, ra + 1));
            { physics = physics, stones = w#stones |> Map.remove(a) |> Map.remove(b) |> Map.insert(w#nextId, ra + 1), nextId = w#nextId + 1 | w }
        case _ => w
    }

// 材質 "stone" は Doc から入れる: PhysicsWorld2d.empty(..) |> PhysicsDoc2d.applyTo(PhysicsDoc2d.loadOr("assets/data/physics2d.kind.json"))
app |> App.withFixedStep(1.0 / 60.0)
    |> App.addSystem(mergeTouches)
    |> App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w },
                      paceOf = w -> Clock.paceOf(if (w#paused) Clock.Run.Paused(Pause.Menu) else Clock.Run.Running) })
    |> App.addPhysics2d({ physicsOf = w -> w#physics, withPhysics = (p, w) -> { physics = p | w }, clockOf = w -> w#play,
                          onEvents = (evs, w) -> { hits = snd(Emit.collectInto(() -> List.forEach(Emit.emit, evs#collisions), w#hits)) | w } })
```

- 系は物理の step を呼ばない（lint-forbid の `physics-step-direct`）。App が系の後に、`clockOf` の遊びの時計で貯めた固定刻みで 0〜5 回 step し、
  刻みごとに `onEvents` を呼ぶ。1 フレームに 2 刻み回っても出来事を落とさない。系は `Emit.since(前に読んだ所, w#hits)` で読み、
  読んだ所を World に持つ（`Emit.Events` は collectInto 64 回分を残す。毎フレーム読む系なら読み落とさない）。
  系は物理より先に回るので、系が読むのは前のフレームの刻みの出来事（1 フレーム遅れる）。この手本は `TestAppPhysics2d` の `testMergeExample` で動かしている。
- `App.addPhysics2d` は `App.withFixedStep` の後に呼ぶ（先に呼ぶと組み立てで止まる）。`PhysicsWorld2d.empty` の刻みが
  `withFixedStep` と違っても止まる。時計は `App.addClock` で進めている物を渡す（進めていない時計では物理が動かない）。
- 遊びの時計が止まっている間（ポーズ）は物理の貯めが貯まらず、系は回り続ける。`Scaled(k)` は物理だけが k 倍で進む。
- 貯めは遊びの時計のナノ秒の整数で数え、5 刻みを超えた分は捨てる。F8 の巻き戻し（記録に `rewind` の行が残る跳び）では 0 に戻し、flow の再生の `rewind` も同じく 0 に戻す。

### 描く（補間）

固定刻みと画面のフレームはずれる（120 Hz の画面・揺れる間隔）。物理の体は
`PhysicsWorld2d.interpolatedPoseOf(id, ctx#physicsAlpha, w#physics)` が前の刻みと今の刻みの間をなめらかにつないだ姿勢を返す
（描くだけに使う・決定性は要らない）。向きを描く口が角度を受けるなら `Rot2.toRadians`。
`ViewCtx#physicsAlpha` は物理の貯め（遊びの時計）の端数、`ViewCtx#fixedAlpha` は系の貯め（実時間）の端数。主役やカメラも系の固定刻みで動かすなら、
前の刻みの位置をゲームの World に持ち、`fixedAlpha` でつなぐ（ポーズやヒットストップで遊びの時計だけが止まると、2 つの端数はずれたままになるので混ぜない）。
`setPosition`（瞬間移動）は補間の前の姿勢もそろえる。

### 出来事の決め方

- `CollisionEvent2d.Started(a, b)`: 離れが 1 cm（食い込みを許す幅の 2 倍）以下になった刻み。`Stopped(a, b, removed)`: 2 cm を超えた刻み。
  組は小さい id が先で、出来事は組の鍵の順。判定は刻みの頭（解く前）の離れで見るので、見た目で触れた次の刻みに出ることがある。
- 眠った島の組は触れたままと見て `Stopped` を出さない。体を消すと、その体の組に `removed = true` の `Stopped`（次の刻みの出来事）。
- sensor の形（`Collider2d.withSensor(true)`）は押し返さず、`SensorEvent2d.Started(sensor, 体)`・`Stopped` だけを出す。
  Fixed の体と sensor どうしは出さない。眠った体は中に居るままと見る。
- 押し合う組み合わせ: Dynamic と Dynamic・Kinematic・Fixed。Kinematic どうし・Kinematic と Fixed・Fixed どうしは押し合わない。
  当たり層は「a の layer が b の mask に入り、かつ b の layer が a の mask に入る」時だけ当たる（既定は layer 1・mask 全部）。

### 誤った使い方と止め方

| 誤り | 止め方 |
|---|---|
| 可変の dt で物理を進める | 型: `step` が dt を受けない。`withFixedStep` の無い `addPhysics2d` は組み立てで `bug!` |
| ゲームが `PhysicsWorld2d.step` を直に呼ぶ | lint-forbid の `physics-step-direct` |
| 物理のファイルで三角関数 | lint-forbid の `physics-portable-math` |
| `Rot2.fromCosSin(Num.cos(..), ..)` | lint-forbid の `rot2-from-num`（知らせるだけ） |
| 位置をゲームの store に写して 2 か所に持つ | docs（位置の持ち主は物理の World だけ。読むのは `positionOf`・`bodies`） |
| NaN・無限大の速さ・衝撃・位置 | 捨てて最初の 1 回だけ言う。中で NaN になった体は消し、`removed` の `Stopped` と 1 行 |
| 材質の値が負・0・NaN | `PhysicsDoc2d.load` が `Err`・`loadOr` は既定で続けて 1 行。`withMaterials` に渡した使えない材質は既定の材質で 1 行 |

### 代金

- `insert`・`remove`・`set*`・`applyImpulse` は 1 回で体の数ぶんの写しがかかる（不変の Vector）。多くの体へ毎フレーム衝撃を掛けるなら
  `applyImpulses` で 1 回にまとめる。数百個を足すのは起動・面の切り替え・合わさった時に。
- 眠りのしきいの既定は 0.01 m/s・0.02 rad/s（積んだ山は数十秒で眠る。山の端で転がる円が止まるまでかかる）。
  早く眠らせたいゲームは `withSettings` でしきいを上げる（転がる石が早く止まり、隣まで届かないことが起きる）。
- 材質と設定は Doc（`physics2d.kind.json`）に出す。読み直すと、もう居る体の摩擦と跳ね返りにも次の刻みから効く。
  重さは体を作った時に出すので、密度の読み直しは新しく作る体からだけ効く。

### 重さの予算

`make physics2d-same CPU=4` が bench/physics2d の 4 場面を PC とブラウザ（ヘッドレスの Chrome・CPU 4 倍に絞る）で流し、指紋を比べて 1 刻みの平均を出す。
予算と、2026-11-26 に Apple M4 Pro で測った値（機械の負荷 8〜15 の中・`make physics2d-same CPU=4` を 3 回流し、PC はそれぞれの 2〜3 回目・ブラウザはそれぞれの 2 回目）:

| 場面 | PC（JVM）の予算 | 測った値 | ブラウザ CPU 4 倍の予算 | 測った値 |
|---|---|---|---|---|
| 物 100 個が落ちて積もる 600 刻み（`fall100`） | 0.3 ms | 0.11 ms | 0.8 ms | 0.68〜0.70 ms |
| 物 500 個の起きた山（`awake500`・眠り無し） | — | 0.69〜0.70 ms | — | 3.9〜4.1 ms |
| 物 1,000 個の起きた山（`awake1000`・眠り無し） | 4 ms | 1.55〜1.56 ms | 20 ms | 8.8〜9.1 ms |
| 眠った物 1,000 個（`asleep1000`） | 0.2 ms | 0.02 ms | 1 ms | 0.40〜0.41 ms |

ブラウザ版（wasm-GC）には JIT もエスケープ解析も無いので、1 刻みの中で組・点・頂点ごとに作る入れ物がそのまま時間に出る。
内側の輪に置かない形は docs/performance.md の「それ以外（JIT されていても 1 個ごとに払う物）」の表
（fall100 の 1 刻み 1.14 ms のうち、細かい当たり 354 µs・解き手 313 µs・world の頂点 158 µs・warm の控え 129 µs がこれだった。直して 0.68 ms）。
fall100 の残りは細かい当たりと掃く所（約 210 µs）・解き手（約 190 µs）・warm の控えを作る所（約 80 µs）。
眠った体だけの刻みは当たりも解き手も回さない（全部が眠っている時だけ。1 つでも起きていれば全部を詰めて掃く）。
