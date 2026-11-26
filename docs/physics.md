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
