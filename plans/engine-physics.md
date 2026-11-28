# 物理の差を詰める計画（3D の剛体・2D の扱い・決定性）

書いた日: 2026-11-26。状態: 計画だけ（実装は TPS デモを写す時）。engine の拡張なので、段 0 に入る前に人と相談する。

## 0. 一言で

- **3D は Flix で自前で書く（案 B）**。TPS デモで要るのは「敵の部品 3 つが箱と球の形で崩れ落ちる・弾・扉の領域・光線」だけなので、球・箱・カプセル・重力・積み重ね・摩擦・跳ね返り・眠り・sensor・光線と形の cast に絞る。関節・凸包・三角形の mesh の当たり・CCD は入れない。
- **物理の World は 1 つの不変の値**（`PhysicsWorld3d`）で、ゲームの World の欄に置く。体の id は ECS の `EntityId`（engine_world にあるので、物理も engine_world に置く）。1 歩は固定の刻みで、`step` は dt を受け取らない。刻みの持ち主は `App.withFixedStep` の 1 か所、進める時計はゲームの遊びの時計（ポーズで止まる）。
- **決定性は「同じ入力を与えた物理の World は JVM と wasm で同じ」まで約束する**。足し引き掛け割りと平方根は IEEE で両方同じなので、物理の中で `java.lang.Math` の三角関数（`Num.sin` など）を使わない・Float の字を指紋に入れない・回る順を id の順に固定する、の 3 つで守る。ゲーム全体のテープを機種をまたいで流せるかは、入力の側（カメラの yaw・`CharacterBody3d` の床の角度など）にも同じ決まりを当てた時だけで、今は約束しない（4.3）。
- **2D は自前（Flix）で 3D より先に入れる**（[engine-physics2d.md](engine-physics2d.md)・11-26 の人の決め）。JBox2D・dyn4j・自前を同じ場面でスパイクし、JVM と wasm の指紋を仕組みで守れて不変の World に入るのは自前だけだった。共通の道具（`Rot2`・`PortableMath`・`StateHash`・lint）と `App.addPhysicsXd` の固定刻みと補間は 2D で先に作り、3D が使う。
- 差し替え口（`PhysicsBackend`）は置かない。

## 1. 今あるもの（11-26 に refactor と api-digest で確認）

| 物 | 置き場 | 中身 | 物理として足りない所 |
|---|---|---|---|
| `CollisionShape3d`（`BoxShape3d`・`SphereShape3d`・`CapsuleShape3d`） | engine/src/scene3d | OBB の箱（`center`・`ax/ay/az`・`half`）・球・縦のカプセル（`feet`・`radius`・`height`） | 形はある。重さ・速さ・材質が無い |
| `CollisionWorld3d` | engine/src/scene3d | 動かない箱を xz の格子（既定 2 m）で引く。`boxesNear` は build の並びの順・重複なし | 動かない箱だけ。体どうしの当たりは無い |
| `Ray3d` | engine/src/scene3d | 箱・球・カプセル・三角形・mesh・`pickNearest` | 光線だけ。形を滑らせる cast は無い |
| `CharacterBody3d` | engine_world | カプセルの `moveAndSlide`（区切って押し出す・段差・床への吸い付き）。`moving` に動く箱を渡せる（扉の板） | 剛体を押さない。剛体に押されるのは「動く箱」として渡した時だけ |
| `SpatialGrid` | engine_world | 点の xy の格子（`region` の中で配列を使い、外へは不変の値） | 点だけ。広がりのある物の組を出す口ではない |
| `Physics2D` + `CollisionShape2D` | engine_world / engine/src/physics2d | 2D の形の重なり・押し出し・跳ね返し | 回転・積み重ね・眠りが無い。ゲームからは呼ばれていない |
| `App.withFixedStep` + `App.Internal.Frame.fixedSteps` | engine_world | 固定刻みの貯金（1 フレーム 0〜5 回・超えたら切り捨て） | 使っているゲームは 0 本。描く時に「刻みの間の何割か」（補間の割合）を渡す口が無い |
| `App.withFingerprint`・flow の記録 | engine_world | 60 フレームごとの指紋・dt はナノ秒で全部残る | 物理の状態を指紋に入れる口が無い |
| `Num.sin/cos/atan2/asin/log` | engine/src/core | `java.lang.Math` を包む | JVM と wasm で最下位ビットがずれる（plans/browser-spike.md の 4・TeaVM の `StrictMath` も JS の `Math` へ渡すだけ: plans/engine-browser-spikes.md） |

LÖVE との採点で 2 点（LÖVE 8 点）だったのは、上の表のとおり「当たるだけで転がらない」から。

## 2. TPS デモで物理が要る所（README と GitHub の中身を読んだ）

godotengine/tps-demo の master の .gd と .tscn を読んだ結果（11-26）。

| 物 | Godot での作り | 物理として要る物 | この計画での手当て |
|---|---|---|---|
| 主役 | `CharacterBody3D`・`CapsuleShape3D` + `SeparationRayShape3D`・`move_and_slide`・`get_gravity()` | 今の `CharacterBody3d` で足りる | そのまま。剛体を押す口だけ足す（段 3・4） |
| 敵（red_robot） | `CharacterBody3D`・重力で落ちて `move_and_slide`・レーザーは `intersect_ray`・見つける範囲は `Area3D`（球 r=20 m） | 光線・sensor | 光線は今の `Ray3d`。範囲は sensor（段 3）か距離の比べ（ゲーム側） |
| 敵が壊れた時の部品 | `RigidBody3D` ×3（盾 2 枚 = 薄い箱 2 つずつ・頭 = 球と箱）・`mass` 2000〜6600・最初は `freeze`、壊れた時に上へ 3 m/s・回転 ±10 rad/s・3〜6 秒で消える | **剛体の本体**: 箱と球の合わせた形・重力・床と壁の箱への当たり・摩擦・回転 | 段 1〜3 |
| 弾 | `CharacterBody3D` を 20 m/s で `move_and_collide`（5 秒で消える） | 形を滑らせる cast（または光線） | 段 3 の `castSphere`（小さな球）。今の `Ray3d` で代えてもよい |
| 扉 | `Area3D` の `body_entered` で開くアニメを流す（扉の板は物理で動かさない） | sensor の入った・出た | 段 3 |
| 床と壁 | `StaticBody3D` に `BoxShape3D` 約 66 個・`CylinderShape3D` 5 個・`CollisionPolygon3D` 1 個・`CollisionShape3D` 約 530 個（形の使い回し） | 動かない箱がほとんど | 今の `CollisionWorld3d` の箱。円柱は箱で近づける（形を足すのは後） |
| project.godot | `3d/physics_engine="Bullet"`（Godot 4 には無いので既定の Godot Physics で動く【推】）・`common/physics_interpolation=true` | **刻みの間の補間** | 段 4（App から補間の割合を渡す。engine_world の拡張なので相談） |

**TPS の範囲の結論**: 同時に動く剛体は 1 体の敵につき 3 つ・敵は数体なので 30 個まで見れば足りる。関節・凸包・mesh の当たり・CCD（速い物のすり抜け止め）は要らない（部品は 3 m/s 程度・60 Hz で 1 歩 5 cm。弾は cast で扱う）。

## 3. 候補の比べ

### 3.1 3D

**dyn4j と Box2D（JBox2D・Box2D 3 系）は 2D だけ**で、TPS の 3D には効かない。3D の候補は次の 4 つ。

| 観点 | B: Flix で自前（推す） | ode4j（ODE の Java 移植） | JBullet（Bullet 2.72 の Java 移植） | Jolt / Bullet 3 を FFM で呼ぶ |
|---|---|---|---|---|
| 手入れ | 自分で持つ | 続いている（0.5.4・2025-05） | 止まっている（元は 2008 年・Maven の最後は 2013 年。stephengold の fork がある） | 本体は活発 |
| license | — | LGPL-2.1 か BSD-3 を選べる | zlib（fork による） | MIT / zlib |
| ブラウザ（TeaVM の wasm） | そのまま入る（engine と同じ Flix） | 試していない。スレッドを使う解き手がある（切れば使わない）【推】 | 速くするために JStackAlloc のバイトコードの書き換えを前提にしている。TeaVM の前にもう 1 段の書き換えが要る | **FFM はブラウザに無い**。別に wasm へ組んで JS で橋渡しする（下の 3.3 と同じ手間） |
| 決定性（JVM と wasm） | 自分で決まりを守れる（4 節） | ODE の既定の回し方は四元数を足して長さ 1 に戻す形で、三角関数は finite rotation を選んだ時だけ。ただし接触や関節の中の `Math.*` と、スレッドの解き手の順は未確認。TeaVM では `StrictMath` も JS の `Math` に化ける | Float32・三角関数は `Math` | Jolt は `JPH_CROSS_PLATFORM_DETERMINISTIC` で組めば機種をまたいで同じと言っている。ただし JVM 側（native）とブラウザ側（別の wasm）は別の組み立て物 |
| World の形 | 不変の値。巻き戻し（`Worldline`）と指紋がそのまま効く（セーブはしない。5.1） | 中で書き換える物（`DWorld`・`DBody`・`dSpaceCollide` の呼び返し）。巻き戻すには全部の状態を写し出して戻す口を自分で書く。接触の控え（warm start）は写せず、戻した後の転がりが元と分かれる | 同じく書き換える物 | 同じく |
| 量の目安 | 2,500〜3,500 行【推】 | jar 1 つ | jar 1 つ | native 3 機種 + wasm 1 つ |
| TPS に足りるか | 足りる（2 節の範囲に絞る） | 足りる（多すぎる） | 足りる | 足りる（多すぎる） |

ode4j と JBullet を採らない理由: どちらも「中で書き換わる Java の物」を不変の World に抱えることになり、このエンジンの強み（テープの再生・巻き戻し・指紋・render-from-World）と噛み合わない。ブラウザでの決定性も三角関数で崩れる見込みで、直すには付け替えの道具（`engine_web/teavm/java/fge/teavmfix/Rewrite.java`）で中の `Math.sin` を置き換える手間が要る。TPS に要る範囲は狭いので、自前の代金の方が読める。

### 3.2 2D（決まった: 自前を先に入れる）

| 観点 | A1: JBox2D | A2: dyn4j | A3: B の 2D 版（自前） | Box2D 3 系を FFM で |
|---|---|---|---|---|
| 手入れ | 止まっている（2.2.1.1・2014 年。Box2D 2.2 の写し） | 続いている（README の Maven の例は 6.0.0。GitHub の release は 3.4.0 で作るのをやめたと書いてある。版と日付はスパイクの時に Maven Central で確かめる） | 自分で持つ | 本体は活発（v3.1 で機種をまたいだ決定性） |
| license | BSD-2 系【推】 | BSD-3 | — | MIT |
| TeaVM に入る見込み | 高い【推】: `MathUtils` にリフレクションは無く、`StrictMath` を使う。libGDX の GWT 版が Box2D の Java 移植を JS に訳して動かしていた前例 | 見込みはある【推】: `Transform` にスレッドとリフレクションは無い。全体は未確認（スパイクで見る） | 入る | **入らない**（FFM はブラウザに無い） |
| 決定性 | Float32（WASM GC の Float32 は JVM と一致した: plans/browser-spike.md）。回転の角を毎歩 `sin/cos` で回す（Box2D 2.2 の `Rot.set`）。`SINCOS_LUT_ENABLED` の表も `Math.sin` で作る。TeaVM では `StrictMath` が JS の `Math` に化けるので、`Rewrite` で純粋な Java の sin/cos へ付け替えれば揃う見込み | Float64。`Transform.rotate` が毎回 `Math.cos/Math.sin`（ソースで確認）。同じく付け替えが要る | 自分で守れる | Box2D 3 の中は揃う。ただし JVM（native）とブラウザ（別の wasm）が別の組み立て物 |
| API の形 | `World.step(dt, velIter, posIter)`・`Body`・`Fixture`。Box2D 3 の呼び名（`b2World`・`b2Body`・`b2Shape`）に近い | `World<Body>`・`Body.addFixture(Geometry.createCircle(..))`・`MassType.NORMAL/INFINITE`・`world.step` | B と同じ形 | Box2D 3 そのもの |
| World の形 | 書き換える物（巻き戻しは写し出しの口を書いても接触の控えが戻らない） | 同じ | 不変の値 | 同じく書き換える物 |

ChatGPT の提案は「Java だけで完結・保守を抑えるなら dyn4j、ブラウザ重視なら JBox2D」。この計画の見立て:

- 手入れでは dyn4j が上。ただし JBox2D は「止まった」のでなく「Box2D 2.2 で完成して動かない」物で、TeaVM の前例があるのは JBox2D の方。どちらも回転の三角関数の付け替えが要るので、決定性の手間は同じ。
- どちらも書き換える Java の物なので、巻き戻し・指紋・セーブの代金はどちらを選んでも同じだけかかる。
- **決まった段取り（11-26）**: 3.4 の手順で JBox2D・dyn4j・自前を同じ場面でスパイクした（[engine-physics2d.md](engine-physics2d.md)）。dyn4j は JVM と wasm の指紋が 3 場面とも分かれ、JBox2D は揃ったが揃う理由が無く、どちらも書き換える Java の物で不変の World に入らない。そこで **A3（自前）を B より先に入れる**。名前は `PhysicsWorld2d`・`RigidBody2d`・`Collider2d` で、今の `Physics2D`・`CollisionShape2D` は改名せずに並ぶ。解き手は soft step（substep 4 回・解く順の入れ替えつき）で、B と同じ形。共通の道具（`Rot2`・`PortableMath`・`StateHash`・lint の `physics-portable-math`・`physics-step-direct`）と `App.addPhysics2d` の固定刻み・物理のアキュムレータ・`ViewCtx#fixedAlpha` は 2D で先に作り、B は `App.addPhysics3d` で同じ物を使う。下の表と 3.4 は比べた時の記録として残す。

### 3.3 Box2D 3 系を Java FFM で呼ぶ案（判定: 採らない）

- PC（JVM）: FFM は JDK 22 から正式（engine は JDK 25 なので使える）。native の .dylib・.dll・.so を機種ごとに配る。GraalVM native image でも FFM の下準備（呼ぶ先の登録）が要る。
- **ブラウザ（TeaVM の wasm）では FFM が無い**。Box2D 3 を emscripten などで別の wasm に組み、頁の JS で TeaVM の wasm と橋渡しする道しかない。その手間: (1) 2 つ目の wasm の組み立てを make と export-web に足す（emsdk を入れる・配る物が増える）、(2) 毎コマ全部の体の位置と回転を JS 越しに写す（TeaVM の JSO を通る。glb の Worker と同じく、写しの代金が乗る）、(3) 素材を後から取る道（`web.deferred`）と同じく、読み込みの順と失敗の扱いを機種の handler に足す。
- 決定性: Box2D 3 は x64・ARM・3 つのコンパイラで同じと言っている（FMA を切る・自前の sin/cos/atan2）。それでも JVM の側は native の組み立て物、ブラウザの側は別の wasm の組み立て物になり、「同じソースだから同じ」は組み立て方（`-ffp-contract=off`・fast-math を切る）を両方で守った時だけ。テープを JVM で録ってブラウザで流す時、ずれの原因を Flix の外まで追うことになる。
- 判定: **採らない**。2D だけで TPS に効かず、機種の handler を 2 つとも広げる代金が、2D の物理を使うゲームが 0 本の今は見合わない。2D で数千個の体を動かすゲームが来て、A3 の速さで足りないと測れた時にだけ見直す。

### 3.4 2D のスパイクの手順（要る時に。JBox2D と dyn4j を同じ手順で）

1. 一時的なベンチのパッケージ（`build/spike-physics2d/`。git の外）に flix.toml の `mvn-dependencies` で jar を 1 つ足す。取り物は `make mvn-cache-share` の共有の置き場を通す（`bin/flix` か make から流す。`java -jar bin/flix.jar` を直に叩かない）。
2. 場面: 床 1 枚・箱 30 個を 3 列に積む・球 10 個を上から落とす。60 Hz で 600 歩。
3. JVM で 600 歩の後の全部の体の位置と角の **ビット**（`Double.doubleToLongBits`）を SHA-256 にする。2 回流して同じか。
4. `bin/fge export-web` で同じ場面を wasm に組む。TeaVM が止まったら、足りない類を記録する（リフレクション・スレッド・`java.util.concurrent`）。
5. ブラウザで同じ SHA を出す。ずれたら、`teavmfix/Rewrite.java` で `StrictMath.sin/cos/atan2`（と `Math.*`）を純粋な Java の実装へ付け替えて、もう一度比べる。
6. 測る: JVM と wasm の 1 歩の ms（`make bench-web ... CPU=4` で絞った値も）。
7. 結果を plans/engine-physics.md の 3.2 に 1 段落で書く。かける時間は 1 本 2 時間まで。超えたらその候補は落とす。

### 3.5 差し替え口（`PhysicsBackend`）を置く案（判定: 今は置かない）

提案は「Native Flix・dyn4j・Box2D 3 から選べる形」。評価:

- **層を置く物差し**（docs/flix-conventions.md）: 抽象の境目は同じ API に実装が 2 つ以上ある時だけ。3D の実装は B の 1 つ、2D は 0 本。しかも dyn4j と Box2D は 2D、B は 3D で、同じ API の 2 つの実装にすらならない。
- **決定性**: 差し替えると転がり方が変わる。テープ（flow の記録）は「同じ入力で同じ World」を前提にしているので、録った時と流す時で backend が違えば最初の指紋で食い違う。backend を替えられること自体が、テープとテープとデッキ（前の版の jar で再生）を壊す口になる。
- **API の形**: 不変の値の World（B）と書き換える Java の物（dyn4j・JBox2D）を 1 つの口で包むと、巻き戻し・セーブ・指紋の約束をどちらかに合わせて弱めることになる（「巻き戻しは backend によっては効かない」）。
- 判定: **置かない**。見直すのは、同じ次元（3D なら 3D）で 2 つ目の実装が要る事が 1 行で書けた時（例: PC だけで数千個を動かす場面のために Jolt を FFM で呼ぶ）。その時も、選ぶのは**ゲームの起動の時に 1 回**だけにし、flow の記録の頭に backend の名前と版を書いて、違えば再生を始めずに止める。

## 4. 決定性の決まり

### 4.1 比べた先

| エンジン | 何を約束しているか | どう守っているか |
|---|---|---|
| Box2D 3 系 | x64・ARM・MSVC・GCC・Clang で同じ（既定で）。巻き戻しは約束しない | 自前の sin/cos/atan2・FMA を切る・fast-math を使わない・スレッドの結果を bit の配列で集めて順を固定・CI で「Falling Hinges」の最後の位置の hash と眠った歩数を比べる |
| Rapier（Bevy の bevy_rapier も同じ） | `enhanced-determinism` を入れると機種と OS をまたいで同じ（wasm も） | IEEE 754-2008 に従う機種だけ・最初の値を三角関数で作るなら nalgebra の関数を使う・体を足す順と消す順を同じにする・並列の解き手も順に解いた物と同じ結果 |
| Godot（Godot Physics・Jolt） | 約束しない。Godot Jolt の README は「決定的に見えても頼るな」 | — （Jolt 本体は `JPH_CROSS_PLATFORM_DETERMINISTIC` で組めば機種をまたいで同じ） |
| このエンジン（B） | 同じ入力を与えた物理の World について **JVM と wasm で同じ**・**足す順によらない**・**巻き戻しても同じ**（Box2D 3 より 1 つ多い） | 下の 4.2 |

### 4.2 守る決まり（B の中で）

1. **固定の刻み**: `PhysicsWorld3d.step(w)` は dt を受け取らない。刻みの持ち主は `App.withFixedStep(秒)` の 1 か所で、`App.addPhysics3d` が組み立ての時にその値を物理の World へ書き込む（`PhysicsWorld3d.Settings` に刻みの欄を置かない。テストで直に作る時は `PhysicsWorld3d.empty(settings, stepSeconds, staticWorld)` で渡す）。解き手の中で刻みを割る回数は `Settings#solverSubsteps`（Box2D の `subStepCount`。App の「固定刻みの 1 回」とは呼び分ける）。App の貯金（`fixedSteps`）は flow がナノ秒で残した dt から決まるので、再生で同じ回数だけ回る。
   - **巻き戻しと貯金の端数**: 端数（carry）は App が World の外に持つ。F8 からの再開・`/start`・`onJump` で World を跳ばした拍は carry を 0 に戻す決まりにする（段 4。跳ばした後の step の回数を通しの再生とそろえる）。
2. **三角関数を使わない**: 物理の中の回転は四元数（`Quat`）で持ち、角速度での回し方は「`q + 0.5·dt·(ω·q)` を足して平方根で長さ 1 に戻す」形にする（三角関数が要らない）。平方根は JVM・wasm とも IEEE で正しく丸めるので使ってよい。`Num.sin/cos/atan2/asin/log`・`Float64.pow/exp` を物理のファイルで使うと lint が止める（6.3）。
3. **最初の値**: ゲームが Doc の角度（度）から向きを作る所は、`PortableMath.sin/cos`（多項式で書いた sin/cos。新しい pub）を通す。`Num.sin` で作った向きを渡すと、JVM と wasm で最初の 1 ビットから分かれうる（Rapier が書いている落とし穴と同じ）。`Num.sin` 自体は替えない（替えると CPU の絵の SHA が全部変わる。plans/engine-core-polish.md の 4）。
4. **回る順**: 体は `Map[EntityId, …]`（Flix の Map は木なので key の順に回る）で持ち、解き手は「id の小さい組から」の順に解く。broadphase の並べ替えは (min の座標, id) で比べ、等しい物が無いようにする。`java.util.HashMap`・`MutMap` 以外の Java の集まり・`Par` は物理で使わない。だから**体を足した順は結果に効かない**（Rapier より強い。テストで確かめる）。
5. **足し算の順**: 力と衝撃の足し込みは id の順の 1 本の流れで行う。途中で組を Set に入れ直して順を変えない。
6. **NaN と無限大**: 入ってきた速さ・衝撃に NaN・無限大があれば捨て、最初の 1 回だけ 1 行言う（`CharacterBody3d.moveAndSlide` と同じ扱い + `warnOnce`）。中の計算で NaN が出た体は、いつも消して `removed` の印つきの出来事と 1 行の warn を出す（入力が正しくても数が暴れることはあるので遊びを落とさない。テストはその出来事が無いことを見る。道は 1 本）。
7. **指紋は字でなくビットで**: `Float64.toString` は JVM と TeaVM で字の出し方が違いうるので使わない。`PhysicsWorld3d.stateHash` は各体の位置・向き・速さ・眠りを `Float64` のビット（NaN を 1 つの形にそろえる方）にして、Flix で書いた 64 bit の hash（FNV-1a）へ id の順に流す。純粋な Flix なので JVM と wasm で同じ関数が動き、unsafe IO も要らない。`WorldHash.sha256Of` はリフレクションを使うので wasm の比べには使わない。
8. **FMA**: Java は 17 から浮動小数がいつも strict で、`Math.fma` を呼ばない限り掛けて足すを 1 つに縮めない。TeaVM の wasm も縮めない。なので気にするのは「`Math.fma` を書かない」だけ。
9. **GraalVM native**: native image でも `Math.sin` の中身が JVM と違いうる【推】。2 と 3 を守れば効かない。

### 4.3 一番の危険とその手当て

**一番の危険: 物理の外から三角関数の結果が入ってくること**。物理の中を決まりどおり書いても、入口で 1 ビットずれれば積み重ねの崩れ方まで変わる。しかも入口はもう三角関数を通っている:
- `CharacterBody3d` は床の角度の判定に `Num.cos` を使う（主役の足の位置が `setKinematicTarget` で物理へ入る）。
- `Mat4` の回す関数・`Transform3d`（オイラー角）は `Num.sin/cos` を使う。
- 主役の移動の向きは、カメラの yaw から `Num.sin/cos` で作る。

だから約束は「**同じ入力を与えた物理の World** は JVM と wasm で同じ」に絞る。ゲーム全体のテープを機種をまたいで流すことは約束しない（今の flow の再生 `E2e.play` も JVM でしか動かない）。

手当て:
- 物理の入口の pub（`RigidBody3d.withRotation`・`withAngularVelocity` など）は `Quat`・`Vec3` を受け、角度は受けない。角度から作る口は `PortableMath` を通る物だけを置く（`RigidBody3d.withYawDeg(度)` の形で物理の側に持つ）。
- JVM と wasm の比べ（6.2 の e）は、入力を物理の口だけにした場面（`bench/physics3d`）で見る。これで物理の中の決まりの破れだけを確かに拾える。
- 機種をまたぐ約束の使い手: 今はブラウザで遊んだ不具合の記録を PC で再生したい時（まだ道が無い）。その道を作る時に、入力の側（カメラ・`CharacterBody3d`・`Mat4`）を `PortableMath` へ寄せる計画を別に立てる（CPU の絵の SHA が変わる代金があるので、plans/engine-core-polish.md の 4 の決めを見直す話になる）。
- 決まりを docs/physics.md の頭に置き、早見表に 1 行。

## 5. 形（ゲームの書き方）

### 5.1 物理の World と ECS

- ゲームの World の欄に `physics: PhysicsWorld3d` を 1 つ置く。中身（体・接触の控え・眠り・前の歩の位置）は外から見えない（非 pub の enum + `pub type alias`。AGENTS.md の「取り違えは型で止める」）。
- 体の id はゲームの `EntityId`。Avian（Bevy の物理）が Entity を体の名前に使うのと同じ。別の handle を作らないので、ゲームの `Map[EntityId, Robot]` と物理の体がそのまま結べる。
- **位置の持ち主は物理の World だけ**。ゲームの store に位置を写して持たない（2 か所に持つと、どちらが正かで食い違う）。View は `PhysicsWorld3d.bodies(w)`（id の順）か、`positionOf`・`rotationOf`（`Quat`。Godot の `position`・`quaternion`、Rapier の `translation()`・`rotation()`）・描く用の `matrixOf`（`Mat4`。`Scene3d.meshInstance(mesh, Mat4)` に渡す）を読んで描く（render-from-World）。今の `Transform3d` はオイラー角なので返さない（四元数から戻すと `atan2` が要り、決定性の決まりにも触れる）。
- 変える時は値を返す関数: `insert(id, body, w)`・`remove(id, w)`・`applyImpulse(id, v, w)`・`setLinearVelocity(id, v, w)`・`setKinematicTarget(id, position, rotation, w)`・`setPosition(id, position, rotation, w)`（瞬間移動。Rapier の `set_position`（位置と向きの組）と同じ。`Transform3d` は受けないので名前に Transform を入れず、`Pose3d`（アニメの姿勢）とも取り違えない。補間の前の姿勢も同じ所へそろえる。Godot の `reset_physics_interpolation` に当たる）。どれも新しい `PhysicsWorld3d` を返す。引数の順は今の `CollisionWorld3d.boxesNear(w, …)` と違い **World を最後**に置く（`|>` で繋ぐため。engine_world の `Query`・`Map` の流儀と同じ）。
- 中の解き手は `region` の中で配列を使って速くし、外へは不変の値を返す（`SpatialGrid` と同じ形）。眠った体は書き直さず、起きている体だけ `Map.insert` し直す（眠った体 1,000 個の予算を守るため）。
- 出来事（当たり始め・離れた・sensor に入った・出た）は `PhysicsWorld3d.events(w)` で読む。中身は**直前の 1 刻みの分だけ**で、step のたびに入れ替える（どの出来事も 1 回だけ読める。積むと 1 刻み目の出来事を後の系がもう一度読み、ダメージが 2 回入る）。系は step の前に回るので、系が読むのは 1 刻み前の出来事（1 刻み遅れる）と doc に書く。step が系の間に 2 回回るフレームの出来事を取りこぼさないよう、App は step のたびに `events` をゲームの `Emit.Events` へ渡す口（`addPhysics3d` の `onEvents`）を持つ。View と音はそこから `Emit.since` で読む。テストに「1 フレームに 2 刻み回っても出来事を 1 回ずつ読む」を 1 本足す。体を `remove` した時は、その体が関わっていた接触と sensor の `Stopped` を `removed = true` の印つきで出す（Rapier と同じ）。音を鳴らすなら `Emit.Events` に積んで `Emit.since` で読む（`withFixedStep` の doc にある「刻みが 0 回のフレームで同じ音がもう一度鳴る」を避ける）。
- **物理の World はセーブしない**。このエンジンのセーブは JSON の codec（`EcsCodec`・docs/save-compat.md）で書き、転がる部品は数秒で消える一時的な物なので、読み込んだらゲームの状態から組み直す。保存が要るゲームが出たら、その時に codec と版の計画を足す。

```flix
// World の欄: physics = PhysicsWorld3d.PhysicsWorld3d・robots = Map[EntityId, Robot]
def explode(id: EntityId, r: Robot, w: World): World =
    let parts = Robot.partsOf(r);   // List[(EntityId, RigidBody3d.RigidBody3d)]
    let physics = List.foldLeft((acc, p) -> PhysicsWorld3d.insert(fst(p), snd(p), acc), w#physics, parts);
    { physics = physics, robots = Map.remove(id, w#robots) | w }

app |> App.withFixedStep(1.0 / 60.0)
    |> App.addPhysics3d({ physicsOf = w -> w#physics, withPhysics = (p, w) -> { physics = p | w },
                          clockOf = w -> w#play })
```

### 5.2 App との繋ぎ（engine_world の拡張・相談）

- `App.addPhysics3d({ physicsOf, withPhysics, clockOf })`: `addClock` と同じ「World から取り出して App が進める」形。App は固定刻みの 1 回ごとに、系（addSystem）の後に `step` を 1 回呼ぶ。ゲームは step を自分で呼ばない（呼ぶ回数を間違える口を無くす）。
- **どの時計で進めるか**: 今の `withFixedStep` の貯金には実時間の dt が入るので、そのままではポーズメニューを開いても部品が転がり続け、`Scaled(k)` やヒットストップ（`withSlow`）でも遅くならない（docs/clock.md の決まりと合わない）。そこで**貯金を 2 つに分ける**: 系（addSystem）は今のまま実時間の貯金で回し、物理の step だけを `clockOf` の時計の dt で貯めた別の貯金で回す（Bevy の `Time<Fixed>` が `Time<Virtual>` から貯めるのと同じ）。`Paused` の間は物理の貯金が貯まらず step しないが、系は回り続けるのでポーズメニューの入力を読んで閉じられる。`Scaled(k)` は物理だけが k 倍で貯まり、入力は遅れない。step の回数は系の回数と同じとは限らない（系の 1 回の中で 0〜5 回）。物理の貯金も App が World の外に持つので、跳ばした拍で 0 に戻す決まり（4.2 の 1）はこちらにも当てる。Bevy の `Update` と `FixedUpdate` のように系の列を 2 本にする道もあるが、engine_world の変更が大きいので採らない（10 節の 3）。
- **貯金はナノ秒の整数で数える**: flow は dt をナノ秒で残しているので、物理の貯金は Int64 のナノ秒で数え、刻みもナノ秒に直す。Float64 で `total / fixedDt` を出すと 0.9999… になり、0 回のフレームの後に 2 回のフレームが来て刻みが偏りうる。段 4 のテストで「1/60 秒のフレームを 600 回 → ちょうど 600 刻み」と「`Paused` の間もポーズを解く系が回る」を確かめる。
- 刻みの値: `withFixedStep` を呼ばずに `addPhysics3d` を呼んだら、App の組み立ての時に止める（`bug!`。可変 dt の物理を作らない）。刻みは `withFixedStep` の値を物理の World へ書き込む（4.2 の 1）。
- **補間の割合**: View の型は `(ViewCtx, w) -> …` で `Frame` を受け取らないので、`ViewCtx#fixedAlpha`（貯金の端数 ÷ 刻み。0〜1。Gaffer の記事の "alpha"・Bevy の `overstep_fraction` と同じ物）に置く。画面なしの描き出しと `FLIX_GE_FIXED_DT` の時は、刻みと 1 フレームの秒が同じならナノ秒の整数で数えた端数が毎回 0 になるので gallery の SHA は揺れない（段 4 で `make render-all` の SHA が変わらないことを確かめる）。
- **補間は物理の外の決まり**: 固定刻みにすると主役・カメラ・敵の系も全部固定刻みで動く。剛体だけをなめらかにすると、120 Hz の画面やフレームの間隔が揺れた時に主役とカメラだけがカクつく（TPS の `physics_interpolation=true` は全部のノードに効く）。そこで: (1) 物理の体は `PhysicsWorld3d.interpolatedMatrixOf(id, alpha, w)` が前の刻みと今の刻みの間をなめらかにつなぐ（向きは長さを 1 に戻した四元数の足し合わせ。描くだけなので決定性は要らない）。(2) 主役とカメラは「前の刻みの姿勢」をゲームの World の欄に持ち、`ViewCtx#fixedAlpha` で同じようにつなぐ手本を docs/physics.md と TPS のゲームに書く。段 4 で TPS の主役とカメラで確かめる（60 Hz の画面でも `FLIX_GE_FIXED_DT` を 1/120・1/144 にして起動すれば、刻みとフレームがずれた時の見え方を確かめられる）。

### 5.3 CharacterBody3d との合流

- 主役のカプセルは今の `moveAndSlide` のまま（Godot の `CharacterBody3D` と同じく、剛体の力では動かない kinematic の体）。
- 主役 → 剛体: 物理の World に主役を kinematic のカプセルとして入れ、毎刻み `setKinematicTarget(id, 足の位置 + 半分の高さ, Quat.identity(), w)` で動かす。剛体は主役を重さ無限の物として受けて押し退けられる。
- 剛体 → 主役: 今の `moveAndSlide(world, moving, …)` の `moving` に、`PhysicsWorld3d.boxesNear(point, reach, w)`（眠っているか遅い箱の体だけ）を渡す。球の体は今の口では渡せないので、段 4 で `moving` を `List[CollisionShape3d]` に広げるかを決める（TPS の部品の球は 1 つだけなので、箱で近づけるのも手）。
- 順: 主役の moveAndSlide → 物理の step（App の固定刻みの 1 回の中で同じ順）。

### 5.4 Doc に出す値

- `physics.kind.json`（ゲームが持つ）: `materials`（名前 → `friction`・`restitution`・`density`）と `world`（`gravity`・`solverSubsteps`・眠りのしきい）。重さは既定で density × 形の体積から出す（Rapier・Box2D と同じ。重さを直に書くと形を変えた時に食い違う）。TPS の部品のように重さを直に決めたい時は `Collider3d.withMass`（Rapier の `ColliderBuilder::mass`）で上書きする。刻みは Doc に出さない（`withFixedStep` の 1 か所）。
- 体の形と置き場は、ゲームの Doc（敵の部品の表など）がその材質の名前を指す。
- **読み直した時**: 材質と world の値は、もう居る体にも次の刻みから効かせる（`PhysicsWorld3d.withMaterials(table, w)`・`withSettings(s, w)`。材質は名前で引くので体に写して持たない。引けない名前は既定の材質で続けて最初の 1 回だけ言う）。重さは体を作った時に出すので、読み直しは新しく作る体からだけ効く（もう居る体の重さを途中で替えると転がりが跳ぶ）。これを docs/physics.md に書く。
- 出さない物: 解き手の中身（反復の回数の既定・接触の余白）・形の当たりの式。

### 5.5 誤った使い方を止める（型 → lint → docs）

| 誤り | 止め方 |
|---|---|
| 可変の dt で物理を進める | 型: `step` が dt を受け取らない。App: `addPhysics3d` は `withFixedStep` が無ければ止める |
| 位置をゲームの store に写して 2 か所に持つ | docs（早見表の 1 行と docs/physics.md）。lint にできるかは段 4 で試す（`positionOf`・`matrixOf` の結果を `Map.insert` している形） |
| ゲームが `PhysicsWorld3d.step` を直に呼ぶ | lint-forbid の `physics-step-direct`（test と engine を除く） |
| 物理のファイルで `Num.sin` などを使う | lint-forbid の `physics-portable-math`（engine の物理のファイルだけ） |
| 角度から向きを作って渡す | 型: 入口は `Quat` を受ける。角度は `withYawDeg` などの物理の側の口だけ |
| 動かない体を毎フレーム足し直す | docs + 測る（足し直すと眠りが解けて重い） |
| 重さ・密度・摩擦が 0 以下・NaN | Doc を読む `PhysicsDoc.load` の側で `Err`（`JsonError`）にし、`loadOr` で既定値で続けて 1 行言う。作る口（`RigidBody3d.dynamic`・`Collider3d.withMass` など）は値をそのまま返し、不正な値は既定値に直して最初の 1 回だけ言う（docs/error-handling.md の「ゲームが呼ぶ口に Result を出さない」） |

## 6. 中身（B）

### 6.1 段の中で作る物

- **体**: `Dynamic`・`Kinematic`・`Fixed`（Rapier の `RigidBodyType` の 3 つ。`Static` と言わないのは、作る口 `RigidBody3d.fixed` と語をそろえるため）。形は体の中に 1〜4 個まで（合わせた形。TPS の盾は箱 2 つ）。重さの中心と慣性は形から出す。
- **`Collider3d` と今の `CollisionShape3d` の関係**: `Collider3d` は「体の座標の形 + `offset`（体の中の位置と向き）+ 材質の名前 + `sensor` の印 + 当たり層」（Rapier の Collider と Shape の分け方）。形は体の座標で持つ: 球（半径）・箱（半分の長さ。向きは offset）・カプセル（体の座標の y 軸に沿った線分 + 半径。回る体に付けても向きを持つ）。当たりを見る時に、その刻みの体の姿勢で world の `CollisionShape3d.Box3d`（OBB）・`Sphere3d` へ写し、今の `Ray3d` と当たりの関数を使い回す。今の縦だけの `Capsule3d`（`feet`・`height`）は kinematic の主役の写しにだけ使い、向きのあるカプセルは物理の中の型（`PhysicsWorld3d.Internal`）で持つ。
- **動かない箱**: 今の `CollisionWorld3d` を `PhysicsWorld3d.empty(settings, stepSeconds, staticWorld)` で受け取る。動かない箱は体として足さず、id は `CollisionWorld3d.build` の並びの番号を使う（warm start の key の片側）。`Fixed` の体は、動かない箱で表せない物（合わせた形・球）だけに使う。
- **組み合わせの表**（Rapier の `ActiveCollisionTypes` の既定と同じ考え）:

  | | Dynamic | Kinematic | Fixed / 動かない箱 | sensor の形 |
  |---|---|---|---|---|
  | Dynamic | 接触を作る | 接触を作る（kinematic は重さ無限） | 接触を作る | 出来事を出す |
  | Kinematic | ← | 作らない | 作らない | **出来事を出す**（扉と主役） |
  | Fixed / 動かない箱 | ← | ← | 作らない | 出さない |
  | sensor の形 | ← | ← | ← | 出さない |

- **broadphase**: 動かない箱は今の `CollisionWorld3d`（xz の格子）をそのまま使う。動く体どうしは x 軸での並べ替え（sort and sweep。(minX, id) で比べる）。前の歩の並びから始めるので、ほとんど並んだ物の並べ替えで安い。二乗を書かない（`bin/lint-rules/quadratic.json`）。体が 30 個なら全部の組を見ても良いが、ベンチの 500 個で効く形にする。
- **当たりの組**（TPS で要る順）: 箱-箱・球-箱・球-球（段 1）、カプセル-箱・カプセル-球（kinematic の主役が部品を押す。段 3）。カプセル-カプセルと動くカプセルの体は TPS の後。箱-箱は（分離軸で一番浅い向きを見つけ、面を切り取って最大 4 点の接触を作る。Box2D の `b2ClipPolygons` と同じ考えの 3D 版）。
- **内側の輪で record・`Map` を引かない**: 接触の点も体の欄も stride の配列にする（2D のスパイクで、record の欄を名前で探す代金が 3〜5 倍の重さになった。engine-physics2d.md の 6.4）。並べ替えは `Sort.sortStableWith` か挿し込み（`Array.sortWith` は並んだ入力で二乗）。
- **解き手**: Box2D 3 系の「soft step」（刻みを `solverSubsteps`（既定 4）に割り、ばねで柔らかくした接触の拘束を 1 回ずつ解き、最後に食い込みを直さない「relax」の回をする）。接触の控え（前の歩の衝撃）を (体 a, 体 b, 特徴の番号) で持って最初に掛ける（warm start）。摩擦は接触の点ごとに 2 本の向き。跳ね返りは最後に 1 回（近づく速さが 1 m/s 以上の時だけ）。
- **余白の接触（speculative contact）**: 少し離れた所から接触を作り、1 歩でのすり抜けを減らす（Box2D 3 と同じ）。CCD は作らない。
- **眠り**: 接触でつながった島ごとに、全部の体が 0.5 秒続けて遅ければ眠らせる。島を作るのは union-find（id の順）。眠った島は解き手に入れない。力・衝撃・触れた kinematic の体で起きる。
- **sensor**: 形に `sensor` の印。当たりの組は作るが解き手に入れず、入った・出たの出来事だけ出す（Rapier・Box2D・Avian の `Sensor`、Godot の `Area3D`）。
- **cast**: `castRay`（体の形も的にする。`Ray3d` の関数を使い回す）・`castSphere`（球を動かして最初の当たり。弾。球 対 OBB は「半径だけ膨らませた箱への光線」で解けるので GJK が要らない）。カプセルを滑らせる cast は TPS の後。当たり層（`collisionLayer`・`collisionMask`。Godot と同じ 32 bit）で絞る。
- **入れない物**: 関節（TPS に無い。扉はアニメ）・凸包と三角形の mesh の当たり（TPS の当たりは箱と円柱。円柱は箱で近づける）・CCD・布・車・水。森か次の場面で要ったら、その時の計画で。

### 6.2 テスト

決定性のテストは engine_world の flix test（画面なし・純粋）。**1 本 0.3 秒前後**を上限に、場面（箱 20 個・300 刻み）をそこへ合わせる。最初の 1 本は JIT が温まる前なので、その分を除いて測る。

| | 見る物 | 大きさ |
|---|---|---|
| a | 同じ場面を 2 回 300 歩流して `stateHash` が同じ | 箱 20 個 |
| b | 体を足す順を逆にしても `stateHash` が同じ | 同じ |
| c | 150 歩の World を取っておき、そこから流し直した 300 歩目が、通しで流した 300 歩目と同じ（巻き戻し） | 同じ |
| c2 | App を通した形: `withFixedStep` + `addPhysics3d` のゲームを flow で流し、途中で World を跳ばして（`onJump`）続けた最後の指紋が、跳ばした所から通しで流した物と同じ（貯金の端数を 0 に戻す決まりの確かめ） | 箱 5 個・120 フレーム |
| d | 基準の SHA（テストに書いた字）と同じ。意図して変えた時だけ書き換える（Box2D の CI と同じ） | 同じ |
| e | JVM と wasm で d が同じ | `bench/physics3d` を export-web して headless の Chrome で SHA を出す。画面を開く門なので `gui: true`・release の前に手元で（gates.json の `pre-release`） |

性質のテスト（期待値は Doc か式から出す・1 テスト 1 アサート。`/quality-assurance`）:
- 箱 5 段の積み重ねが 5 秒後に 1 cm 以上ずれない・2 秒以内に眠る。
- 摩擦: 20° の坂（向きのある動かない箱）で μ = 0.5 の箱は 1 秒後の速さが 1 cm/s 未満（tan 20° ≒ 0.36）・μ = 0.2 は 1 秒で 0.5 m 以上滑る。
- 跳ね返り 0.5 の球を 1 m から落とすと 1 回目の高さが 0.25 m ±2 cm。
- 跳ね返り 0 の球が落ちきった後（2 秒後）の、位置と動きのエネルギーの合計が、最初の位置のエネルギーを 1% を超えて上回らない（毎刻みでなく区間の終わりで見る。食い込みを戻す動きで 1 刻みごとには少し増えうる）。
- sensor に入った・出たがちょうど 1 回ずつ出る。kinematic のカプセルでも出る。
- 体を消すと `removed` の印つきの `Stopped` が出る。
- NaN の衝撃を捨てる。

**gl-parity との関係**: 物理は描く物でないので gl-parity に場面を足さない。物理の形を線で描くデバッグの重ね（任意・段 5）を足すなら gl-parity に 1 場面だけ。**新しい場面 1 つが 2 秒を超えるか、gl-parity 全体（今 18 秒）が 1 割（1.8 秒）を超えて増えるなら、場面を小さくする**（体の数か歩の数を減らす）。物理のテストの合計も engine_world の flix test（今 48 秒）の 1 割（4.8 秒）を超えたら同じく小さくする（1 本 0.3 秒 × 15 本前後で収まる見込み）。

テープ: `App.withFingerprint` の字に `PhysicsWorld3d.stateHash` を入れる形を手本に書く（60 フレームごとなので重さは問題にならない）。物理を直した版でテープの再生が食い違うのは意図した差として承認する（テープとデッキの決まりどおり）。

### 6.3 lint と docs と早見表

- `bin/lint-rules/forbid.json` に `physics-step-direct`・`physics-portable-math` の 2 行。
- docs/physics.md（決まり・形・手本）。docs/module-index.md に 1 行。
- `agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本（「敵が壊れたら部品を 3 つ転がす」）。
- JVM と wasm の比べの門は engine のリポでだけ打てる口なので、AGENTS.md の検証の節に 1 行と `testdata/agent-eval/engine-repo.json` にお題 1 本。

## 7. 重さの予算とベンチ

| 場面 | PC（JVM・温まった後） | スマホ相当（ブラウザ・`CPU=4`） |
|---|---|---|
| TPS の部品（動く体 30・動かない箱 600） | 1 歩 0.5 ms 以下 | 1 歩 2 ms 以下 |
| 積み上げ（動く体 200・接触 800 程度） | 1 歩 2 ms 以下 | 対象外（測るだけ） |
| 眠った体 1,000 | 1 歩 0.1 ms 以下 | 0.5 ms 以下 |

- 1 フレームに 2 歩回ると倍。スマホの 3D の基準（fps3d-room の cpu 20.7 ms）に 2 ms を足しても 30 fps の線（33 ms）の中。
- ベンチ: `bench/physics3d`（画面なし）。上の 3 場面を流し、1 歩の ms の p50・p95 と `stateHash` を JSON で出す。ブラウザは `make bench-web BENCH=physics3d CPU=4`。gates.json の packages に足す（check-pkgs の 6 秒前後）。
- JIT の罠（project_webgpu_migration の記録）: 8,000 バイトを超えるメソッドは JIT されず、末尾呼び出しの輪では OSR が諦める。解き手の内側の輪は小さい関数に割る（`bin/lint-rules/huge-methods.json` が見る）。ベンチは温めの 300 歩を捨ててから測る。

## 8. 段の分け方と実時間

見積もりは推測の時間。直近の engine の段は見積もりの半分〜3 分の 1 で済んでいるので、右の列に実績の割合を当てた目安を書く。ただし**段 2（積み重ねの安定）は調整に時間がかかる種類の仕事**なので、割り引かずに推測どおりの時間を置く。

| 段 | 中身 | 届く物 | 推測 | 目安 |
|---|---|---|---|---|
| 0 | 決まりと道具: `PortableMath`・`stateHash`（FNV-1a）・決定性のテストの台（a〜d の枠）・`bench/physics3d` の枠・docs/physics.md の頭・lint 2 行 | 決まりがテストと lint で守られる | 4 h | 1.5〜2 h |
| 1 | 体の芯: `RigidBody3d`・`Collider3d`・重力・四元数の積み上げ・**箱-箱の分離軸と面の切り取りと特徴の番号**・球-箱・球-球・動かない箱（`CollisionWorld3d`）との当たり・soft step・摩擦・跳ね返り | 球と箱が床（向きのある箱）に落ちて転がり止まる | 10 h | 4〜5 h |
| 2 | 体どうし: sort and sweep・warm start（接触の控え）・合わせた形・積み重ねの安定 | 箱 5 段が崩れない・TPS の部品どうしが重なる | 10 h | 10 h（割り引かない） |
| 3 | 眠り・島・sensor の出来事・組み合わせの表・`castRay`・`castSphere`・当たり層・kinematic の体とカプセル-箱/球 | 弾・扉・主役が部品を押す・眠り | 6 h | 2〜3 h |
| 4 | 繋ぎ: `App.addPhysics3d`（時計で貯める固定刻み・刻みの 1 か所化・跳ばした拍の carry）・`ViewCtx#fixedAlpha` と補間の手本（主役とカメラも）・主役との合流・`physics.kind.json` の手本と読み直し・早見表とお題 | ゲームから 10 行で使える・ポーズで止まる・120 Hz でカクつかない | 7 h | 2.5〜3.5 h |
| 5 | 測ると比べ: ベンチの 3 場面・JVM と wasm の比べの門（e）・予算を外れたら直す・（任意）形を線で描く重ね | 予算と決定性の確かめ | 5 h | 2〜2.5 h |
| 計 | | | 42 h | 22〜26 h |

**引き返す線の手前の手当て**: 積み重ねが倒れたら、まず relax の回（食い込みを戻す分を抜いた目標で解き直す）と、点を解く順を回ごとに前から・後ろからと入れ替える手を確かめる（2D のスパイクでは、この 2 つで箱 12 個の塔が立った。入れ替えが無いと soft step でも 3 秒で倒れた）。

**引き返す線**: 段 2 が 15 h を超えたら、TPS に要る範囲（体 対 動かない箱・部品どうしの粗い当たり。部品は 3〜6 秒で消えるので積み重ねの安定は要らない）で止め、積み重ねの安定は後の段へ回す。その時は 6.2 の「箱 5 段」のテストを後の段へ移し、LÖVE との採点の伸びが小さくなることを報告に書く。

各段の終わりに: その段のテストが緑・`make verify SUITE=affected`・ベンチの数（段 1 から）。レビューは段 2 の後と段 5 の後の 2 回（1 回目で指摘を全部出させ、まとめて直して確かめる）。

後の段（TPS の後・要った時だけ）: 動くカプセルの体とカプセル-カプセル・カプセルの cast +3〜4 h・関節（ヒンジ・固定・ボール）+6〜8 h【推】・凸包（GJK と EPA）+8〜10 h・三角形の mesh の当たり +6〜8 h・2D 版（A3）+8〜12 h。

## 9. 新しい pub の一覧（名前は Rapier・Godot・Box2D・Bevy にそろえる）

置き場は **engine_world**（`CharacterBody3d` と同じ層）。体の id の `EntityId` が engine_world にあり、engine に置くと engine から層を見る向きになる（gates.json の依存の向きに反する）。形（`CollisionShape3d`）・光線（`Ray3d`）・`CollisionWorld3d`・`Quat`・`Mat4` は engine のまま使う。`PortableMath` だけは機種に依らない数の道具なので engine/src/core（`Num` の隣。`Num` の中に入れないのは、`Num.sin` と同じ名前が並んで取り違えやすいため）。1 ファイル 1,200 行の上限に当たる中身は `PhysicsWorld3d.Internal.<役>`（`Solver`・`Narrowphase`・`Broadphase`・`Islands`）へ。引数は World を最後に置く。

| 名前 | 何か | 呼び名の出どころ |
|---|---|---|
| `PhysicsWorld3d`（型） | 物理の World（不変の値） | Box2D `b2World`・Godot `World3D` |
| `PhysicsWorld3d.Settings`・`settings()` | gravity・`solverSubsteps`・眠りのしきい（刻みは持たない） | Rapier `IntegrationParameters`・Box2D `subStepCount` |
| `PhysicsWorld3d.empty(settings, stepSeconds, staticWorld)`・`insert`・`remove`・`step` | 作る・体を足す・消す・1 刻み | Rapier `insert`/`remove`・Box2D `b2World_Step` |
| `PhysicsWorld3d.withSettings`・`withMaterials` | Doc の読み直し | AGENTS.md の動詞の表（`with*`） |
| `PhysicsWorld3d.applyImpulse`・`setLinearVelocity`・`setAngularVelocity`・`setKinematicTarget`・`setPosition`・`wakeUp` | 外から動かす | Rapier `apply_impulse`・`set_next_kinematic_position`・`set_position`・`wake_up` |
| `PhysicsWorld3d.positionOf`・`rotationOf`・`matrixOf`・`interpolatedMatrixOf`・`linearVelocityOf`・`bodies`・`isSleeping` | 読む（`Transform3d` は返さない） | Godot `position`/`quaternion`/`sleeping`・Rapier `translation()`/`rotation()` |
| `PhysicsWorld3d.events`・`CollisionEvent3d`（`Started`・`Stopped`。`removed` の印）・`SensorEvent3d`（同じく `Started`・`Stopped`） | 最後に回った刻みの出来事 | Rapier `CollisionEvent::Started/Stopped`・`REMOVED` |
| `PhysicsWorld3d.castRay`・`castSphere`・`boxesNear` | 光線・球の cast・主役に渡す箱 | Rapier `cast_ray`/`cast_shape` |
| `PhysicsWorld3d.stateHash` | 状態のビットの 64 bit hash | Box2D の CI の hash |
| `RigidBody3d`（型）・`RigidBody3d.BodyType`（`Dynamic`・`Kinematic`・`Fixed`） | 体の作り | Rapier `RigidBodyType` |
| `RigidBody3d.dynamic`・`kinematic`・`fixed` | 作る口 | Rapier `RigidBodyBuilder::dynamic/kinematic_position_based/fixed` |
| `RigidBody3d.withCollider`・`withLinearVelocity`・`withAngularVelocity`・`withRotation`・`withYawDeg` | 値を差し替える | AGENTS.md の動詞の表（`with*`） |
| `Collider3d`（型）・`Collider3d.sphere`・`box`・`capsule`・`withSensor`・`withMaterial`・`withOffset`・`withMass`・`withCollisionLayers` | 体の中の形 | Rapier `Collider`/`ColliderBuilder::mass`・Godot の形の名前と `collision_layer`/`collision_mask`（engine の今の `CollisionShape3d` の sphere/box/capsule にそろえる） |
| `PhysicsMaterial`（`friction`・`restitution`・`density`） | 材質 | Godot `PhysicsMaterial`・Rapier/Box2D の欄の名前 |
| `PhysicsDoc.load`・`PhysicsDoc.loadOr` | `physics.kind.json` を読む（`HitDoc.load`・`ShaderJson.loadOr` にそろえる） | docs/error-handling.md |
| `PortableMath.sin`・`cos`・`atan2`（engine/src/core） | JVM と wasm で同じビットを返す sin/cos/atan2 | Box2D `b2ComputeCosSin`・`b2Atan2` |
| `App.addPhysics3d`・`ViewCtx#fixedAlpha` | 物理を App に繋ぐ・補間の割合 | Bevy `Time<Fixed>::overstep_fraction`・Gaffer の alpha |

作らない物: `withCcd`（CCD は入れない）・`PhysicsBackend`（3.5）。

## 10. 人に決めてほしい事（推す答えつき）

1. **3D は自前（B）で良いか** — 推す: はい。ode4j・JBullet・FFM の Jolt は、書き換える物を不変の World に抱える・ブラウザでの決定性が崩れる・機種の handler を広げる、のどれかに当たる。
2. **決定性はどこまで約束するか** — 推す: 「同じ入力を与えた物理の World は JVM と wasm で同じ・足す順によらない・巻き戻しても同じ」。ゲーム全体のテープを機種をまたいで流すのは約束しない（入力の側の `CharacterBody3d`・`Mat4`・カメラが `Num.sin/cos` を通るため。寄せるなら CPU の絵の SHA が変わる別の計画）。「同じ機械の中だけ」に下げると `PortableMath` は要らなくなるが、GraalVM native と JVM の間でもずれうる。
3. **engine_world の拡張を入れて良いか**（段 4）: `App.addPhysics3d`・物理だけの 2 つ目の貯金（遊びの時計で貯める・ナノ秒の整数）・跳ばした拍で貯金を 0 に戻す・`ViewCtx#fixedAlpha` — 推す: はい。時計で貯めないとポーズで部品が転がり続ける。系の列を Bevy のように 2 本（`Update`・`FixedUpdate`）にする道は変更が大きいので採らない。
4. **物理を engine_world に置く** — 推す: はい（`EntityId` の層に合わせる）。engine に置くなら key を型の引数 `PhysicsWorld3d[k]` にする代金がかかる。
5. **2D はいつ・どれで** — 決まった（11-26）: 自前の 2D 版を B より先に入れる（[engine-physics2d.md](engine-physics2d.md)）。スパイクで dyn4j は JVM と wasm の指紋が分かれ、JBox2D は揃う理由が無く、どちらも不変の World に入らなかった。共通のフェーズ 0（`Rot2`・`PortableMath`・`StateHash`・lint）と `App.addPhysicsXd` の固定刻みと補間は 2D で作り、B が使う。
6. **Box2D 3 の FFM と `PhysicsBackend`** — 推す: どちらも採らない（3.3・3.5）。
7. **主役のカプセルに剛体の球を当てるか** — 推す: TPS では `moving` に箱だけを渡す（部品の球は 1 つ・数秒で消える）。球を正しく扱う要望が出たら `moving` を `List[CollisionShape3d]` に広げる（engine_world の型の変更なので、その時に相談）。

## 11. 参考に見た物（11-26）

- TPS デモ: https://github.com/godotengine/tps-demo （`player/bullet/bullet.gd`・`enemies/red_robot/parts/part.gd`・`enemies/red_robot/red_robot.tscn`・`door/door.gd`・`project.godot`）
- Box2D の決定性: https://box2d.org/posts/2024/08/determinism/
- Rapier の決定性: https://rapier.rs/docs/user_guides/rust/determinism/
- Godot の Jolt: https://docs.godotengine.org/en/4.5/tutorials/physics/using_jolt_physics.html ・ https://github.com/godot-jolt/godot-jolt
- JBox2D の `MathUtils`: https://github.com/jbox2d/jbox2d
- dyn4j: https://github.com/dyn4j/dyn4j （`Transform.rotate` が `Math.cos/sin`）
- ode4j: https://github.com/tzaeschke/ode4j
- JBullet: https://github.com/stephengold/jbullet
- このリポジトリ: plans/browser-spike.md の 4（Float32 は一致・`Math.sin` はずれる）・plans/engine-browser-spikes.md（TeaVM の `StrictMath`）・plans/engine-core-polish.md の 4（`Num` を `StrictMath` に替えない決め）

## 人の決め（2026-11-26）

「おすすめ案で」。決めることの 7 つは推す答えのとおり。2D の計画（engine-physics2d.md）の決めにより、3.2 と 10.5（2D は今は何もしない・両方通れば dyn4j）は「2D を自前で先に入れ、共通のフェーズ 0 と `App.addPhysicsXd`（固定刻みと補間）を 2D で作って 3D が使う」に読み替える。本文の直し（0 節・3.2・6.1・8 節の引き返す線・9 節の出来事の名前・10.5）は 2D の担当がフェーズ 0 の前に済ませた。
