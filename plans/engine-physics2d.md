# 2D 物理の API（口）を入れる計画（自前の 2D・dyn4j・JBox2D の比べ）

書いた日: 2026-11-26。状態: スパイク済み・計画だけ（engine は書き換えていない）。engine の拡張なので、フェーズ 1 に入る前に人と相談する。
3D の計画 [engine-physics.md](engine-physics.md)（GO 済み）とそろえる。サンプルとスパイクは `~/Documents/flix_ge_workspace/physics2d_lab`（git の中・push なし。自前の数は全部コミット 736a494 のコードで測った）。

## 0. 一言で

- **推す構成: Flix で自前で書く 2D（案 N）**。region の中で欄ごとの配列（structure of arrays）に詰めて回す形。重さは場面で分かれる: 物 1,000 個の起きた山は JBox2D の 1.6 倍（ブラウザ CPU 4 倍で 31 ms 対 19 ms）。物 500 個は自前が一番軽く出た（6.0 ms・JBox2D 7.2・dyn4j 8.3）が、眠りのしきいが JBox2D の 10 倍緩い（0.1 m/s 対 0.01 m/s）ぶん早く眠った結果で、ソルバーの速さではない。物 100 個は JBox2D の 2.7 倍（1.03 ms 対 0.38 ms。JBox2D は 1 秒足らずで眠り、自前は数秒かかる）。
- **決定性**: 自前は **JVM と wasm で指紋が一致した**（100・500・1,000 個・600 刻み・CPU 1 倍と 4 倍）。JBox2D もこの場面では一致したが、一致する理由が無い（3.3）。**dyn4j は 3 場面とも分かれた**（毎刻み `Math.cos/sin`）。同じ機械の中で 2 回流した指紋は 3 つとも揃う。
- **型で決定性を守る形は、物理の中では効いた**: 向きは `Rot2`（cos・sin の組）、角度から作るのは `PortableMath` を通る口だけ、物理のファイルで `Num.sin` などを書くと lint が止める（当たるのを確かめた）。ただしゲームの側で `Num.cos` を通した組を渡す穴は型では塞げない（6.2）。
- **不変の World に入るのは自前だけ**。dyn4j・JBox2D は中で書き換わる Java の物で step が IO になり、App の純粋な系に入らない。巻き戻し・テープ・指紋は写し出しを書いても接触の控え（warm start）が戻らない（3D の計画の 3.1 と同じ理由）。dyn4j を外す一番の理由もこれ（決定性のずれはリライタで直る見込みがある）。
- **使わないゲームは軽いまま**: 物理のモジュールと jar を持つが呼ばない頁と、どちらも持たない頁で wasm が同じ大きさだった（3,764,579 B・5.2）。engine_world に入れても、呼ばなければ TeaVM が落とし、JVM は類を読み込まない。Java の物理を engine に入れるなら engine_full（依存を持たない決まり）に jar を足すことになり、使わないゲームも取りに行く。
- 置き場は **engine_world**（体の id は `EntityId`）。名前は `PhysicsWorld2d`・`RigidBody2d`・`Collider2d`（3D の計画の 3.2）。今の `Physics2D`・`CollisionShape2D` は改名せずに並ぶ。差し替え口（`PhysicsBackend`）は置かない。
- **この計画は 3D の計画の 3.2（「2D は今は何もしない・JBox2D と dyn4j を試して両方通れば dyn4j」）と 10.5 を覆す**。直す文は 8 節の 2。
- 3D の計画への持ち帰り（6.4）: Flix の record をソルバーの内側の輪で読むと、欄を名前で探す重さで 3〜5 倍遅い。`Array.sortWith` は並んだ入力で二乗になる。1 刻みに逐次の衝撃だけでは箱の塔が倒れ、relax の回で立った。

## 1. サンプル（選んだ物と理由）

**選んだ: 合わさる積み物のパズル「晶洞（ジオード）」**。瓶に石を落とし、同じランクの石が触れると 1 つ上のランクの石になる。ランクは 0〜9、偶数のランクは丸い石（円）・奇数のランクは結晶（正六角形）。題材・名前・絵は独自（果物にしない・洞窟の石と結晶）。

選んだ理由（物理の比べに効く方）:
- 剛体の物理の中核（円-円・円-多角形・多角形-多角形の当たり・積み重ね・摩擦・眠り）を全部使う。ボクセルの 2D（壊れる地形・崩れる砂）の中身はセルの規則で、剛体の物理の比べにならない（dyn4j・JBox2D の得意な所を測れない）。
- 体を足す・消す（合わさる）が毎秒起きるので、不変の World への出し入れと、触れた組を読む API を試せる。
- 物の数を 100・500・1,000 と増やした同じ場面を作りやすい。

遊べる所まで来た: 矢印キーで落とし口を動かし、↓かスペースで落とす（マウスで押した所にも落とす）。合わさると金の光の輪とパーティクルが出て点が入る。ブラウザ版（`build/web-game`）も動く（`debug/web-game.png`）。絵は `gallery/main.png`・`merge.png`、動画は `debug/geode.mp4`（自動で遊ぶ 15 秒・450 KB）。音・遊びの終わり（溢れ）は入れていない（スパイクの外）。テスト 22 本（合わさる・同じ指紋・巻き戻し・眠る・跳ねる高さ・PortableMath のずれ）が緑。

## 2. 比べた構成と測り方

| 名前 | 中身 | 置き場（physics2d_lab） |
|---|---|---|
| N: 自前（配列の版・推す） | 外は不変の World（`Vector[Body]`）。step の頭で体を Float64 の 1 本の配列（stride 13）・接触の点を 1 本の配列（stride 13）へ詰め、region の中で書き換えて回す。ブロードフェーズは sort and sweep・ナローフェーズは円/六角形/箱（分離軸と辺のクリップ・接触の点 2 つまで）・warm start・摩擦・跳ね返り・speculative contact・Baumgarte と relax の回（substep は無し）・島ごとの眠り | `src/phys/Phys2d.flix`（540 行）・`Narrow.flix`（169）・`Shape2d.flix`（41）・`Rot2.flix`（PortableMath を含む 66） |
| N0: 自前（箱詰めの版） | 同じソルバーの写しで、接触の点を record のまま内側の輪で読む版（relax の回を足す前の写し） | `src/phys/Phys2dBoxed.flix`（比べ専用） |
| D: dyn4j 5.0.2 | `World<Body>`・`Geometry.createCircle/Rectangle/Polygon`・`world.step(1)`（刻み 1/60） | `src/bench/JavaPhys.flix` の `Dyn4jSim` |
| B: JBox2D 2.2.1.1 | `World`・`CircleShape`・`PolygonShape`・`world.step(1/60, 8, 3)`（Float32） | 同じファイルの `JBox2dSim` |

取った jar（physics2d_lab の flix.toml の `jar-dependencies`・`lib/external` の中だけ。engine の flix.toml には書いていない。依存は 2 つとも test の junit だけなので、jar 1 本ずつを直に取った）:
- `dyn4j-5.0.2.jar`（487 KB・`org.dyn4j:dyn4j:5.0.2`。5 系の最新）
- `jbox2d-library-2.2.1.1.jar`（286 KB・`org.jbox2d:jbox2d-library:2.2.1.1`）

**場面**（`BenchScene`）: 幅 23.4 m の床と左右の壁（厚さ 1 m の箱）。その中へ N 個（7 つに 4 つが円・2 つが正六角形・1 つが箱。大きさ 0.16〜0.26 m・番号から決める）を 40 列の格子に並べ、重力 10 m/s² で落とす。1/60 秒で 600 刻み（10 秒）。材質は 3 つとも同じ（摩擦 0.5・跳ね返り 0.1）。六角形の頂点は平方根で作り、dyn4j の `createUnitCirclePolygon`（頂点を `Math.cos/sin` で作る）は使わない。
**指紋**: 600 刻みの後、足した順に各体の位置・向き（自前は cos・sin、dyn4j は `Transform` の cos・sin、JBox2D は角度）・速さの Float64 のビットを 64 bit の hash（FNV-1a の掛けと xor）へ流す。
**重さ**: 10 刻みごとに時計を読み、600 刻みの 1 刻みの平均。PC は 3 回流して 2〜3 回目の幅、ブラウザは頁の中で 2 回流した 2 回目。ブラウザは `bin/fge web-bench`（ヘッドレスの Chrome 156・Apple M4 Pro・WebGPU の 1 台だけ）。
**積み重ね**: 一辺 0.5 m の箱を 12 個積んだ塔を 600 刻み置き、一番ずれた箱の横のずれと一番上の箱の中心の高さ（理想 5.75 m）。
入口: `bin/flix run --entrypoint BenchCli.{native,boxed,dyn4j,jbox2d,tower}`（PC）・`./export-variant.sh bench-<名前>` で書き出して `debug/web-bench.sh <名前> <CPU 倍>`（ブラウザ）。生の記録は `debug/bench-jvm-4.txt`（自前の最後の版）・`bench-jvm-3.txt`（dyn4j・JBox2D・箱詰め）・`debug/web-*-cpu*.json`。

注意: PC の自前の行（bench-jvm-4）は負荷 約 50、dyn4j・JBox2D の行（bench-jvm-3）は負荷 約 20〜30 の時に測った。測った間、機械はほかの作業（並んで走る別の担当の java）で負荷が 8〜70 の間を揺れていた。PC の数は幅で書き、比は ±3 割で読む。ブラウザの数は同じ時間帯に続けて流した 3 つの比べとして読む。

## 3. 結果

### 3.1 比べの表

| 観点 | N: 自前（配列） | D: dyn4j | B: JBox2D |
|---|---|---|---|
| `export-web` が通るか | 通る | 通る（リライタの手当て無しで） | 通る（同じく） |
| wasm の増え分（brotli・物理の部分だけ） | +16.8 KB（Phys2d 11.0・Narrow 5.8） | +16.3 KB（org.dyn4j）+ ラッパー 4.3 KB。頁全体では Java の実行環境が +35 KB（dyn4j が引く `java.util` の類） | +25.0 KB（org.jbox2d）+ ラッパー 4.6 KB。頁全体で +27 KB |
| 頁全体の wasm（brotli・比べの頁） | 665 KB | 720 KB | 681 KB |
| ブラウザで動くか | 動く | 動く | 動く |
| 同じ機械で 2 回の指紋 | 揃う | 揃う | 揃う |
| JVM と wasm の指紋 | **揃う**（3 場面・CPU 1 倍と 4 倍） | **分かれる**（3 場面とも） | 揃う（この場面では。理由は無い） |
| PC（JVM）・1 刻み（100 / 500 / 1,000 個） | 0.26〜0.38 / 1.5〜1.7 / 4.2〜7.1 ms | 0.15〜0.18 / 1.2〜1.3 / 2.5〜2.6 ms | 0.12〜0.14 / 1.4〜1.6 / 3.6〜3.7 ms |
| ブラウザ・1 刻み（100 / 500 / 1,000） | 0.25 / 1.5 / 7.4 ms | 0.22 / 1.9 / 4.9 ms | 0.09 / 1.6 / 4.0 ms |
| ブラウザ CPU 4 倍・1 刻み | 1.03 / 6.0 / 31.0 ms | 1.02 / 8.3 / 21.7 ms | 0.38 / 7.2 / 19.3 ms |
| 600 刻みの後に起きている体（100 / 500 / 1,000） | 0 / 0 / 1,000 | 64 / 498 / 1,000 | 0 / 499 / 1,000 |
| 物 1,000 個・2,400 刻み（40 秒）の後半 1,200 刻みの平均（PC） | 0.82 ms（終わりには全部眠る） | 3.5 ms（眠らない） | 0.18 ms（終わりには全部眠る） |
| 箱 12 個の塔（横のずれ・上の箱の高さ） | 0.7 cm・5.72 m（立って眠る） | 0.1 cm・5.62 m（13 cm 沈む） | 0.6 cm・5.86 m（形の皮 0.01 m ぶん浮く） |
| 不変の World に入るか | 入る（`Phys2d.World` は値） | 入らない（`World<Body>` を中で書き換える。step が IO） | 入らない（同じ） |
| コードの量 | 物理 約 820 行（自分で持つ） | ラッパー 約 70 行 | ラッパー 約 75 行 |

読み方:
- 自前が JBox2D より重い所は 2 つ: **眠るまでの時間**（100 個で、JBox2D は 1 秒足らずで全部眠り後半の平均が 0.02 ms、自前は数秒かかる）と、**起きた大きな山**（1,000 個で 1.6 倍）。前者は 6.3 の 5、後者は 6.3 の 1〜3 で詰める。
- 500 個は自前が一番軽く出たが、眠りのしきいが JBox2D の 10 倍緩い条件での数（ソルバーの速さの比べではない）。JBox2D・dyn4j は 499・498 個が起きたまま（山の端で 1 つ動く体が島全体を起こし続ける）。
- 眠った物 1,000 個（全部眠った後）の 1 刻みは、まだ測れていない（2,400 刻みの後半は眠り切る前の刻みを含む）。フェーズ 4 で場面を足して測る。

### 3.2 自前の 2 つの書き方（region の配列の版 と 箱詰めの版・PC）

| 物の数 | 配列の版（N） | 箱詰めの版（N0） | 比 |
|---|---|---|---|
| 100 | 0.26〜0.38 ms | 0.95〜0.98 ms | 約 3 倍 |
| 500 | 1.5〜1.7 ms | 6.9〜7.1 ms | 約 4 倍 |
| 1,000 | 4.2〜7.1 ms | 16〜22 ms | 3〜5 倍 |

箱詰めの版は relax の回を足す前の写しで、ソルバーの回数が 3 回少なく、眠りのしきいも低い（どちらも条件がそろっていない比べ）。JFR で見ると、箱詰めの版の重さの 4 割は `RecordExtend.lookupField(String)`（record の欄を名前で探す所）だった。配列の版に移して消えた（残りは warm start の `Map` の木と、ナローフェーズの `Vector` の作り直し）。「不変のまま素直に書いた版」（region を使わない版）は書いていない。箱詰めの版でも体の欄は region の配列なので、素直な版はこれより遅い【推】。

### 3.3 決定性の中身

最後のコード（736a494）で、自前は 100・500・1,000 個の指紋 `4553400712624381315`・`-3533080028118809195`・`-3203436122206839670` が JVM・wasm（CPU 1 倍・4 倍）で同じ（前の版 a9ea0ba でも 3 つとも一致した）。JBox2D も 3 つとも同じ。dyn4j は 100 個で JVM `-2462309749610280938`・wasm `3924446496569071851` のように 3 つとも違った。

- 自前: 物理の中は足し引き掛け割りと平方根だけ（`Rot2` の組を回して長さ 1 に戻す・六角形の √3 も平方根）。回る順は Vector の並び（スパイクでは足した順 = 振った id の順）で、ブロードフェーズの並べ替えは (左端, 番号) の安定した並べ替え、union-find は小さい番号を根にする。「足す順によらない」はスパイクでは確かめられない（id を足した順に振るため）。engine で `EntityId` の順に並べてから、テスト b で確かめる。
- dyn4j: `Transform.rotate`・`Rotation` が毎刻み `Math.cos/sin` を呼び、TeaVM では JS の `Math` になる。3D の計画の 3.4 の手順 5（リライタ `engine_web/teavm/java/fge/teavmfix/Rewrite.java` で純粋な Java の sin/cos へ付け替えて比べ直す）は試していない。付け替えれば揃う見込みはある【推】。
- JBox2D: 2.2 は回転を角度で持ち `MathUtils.sin/cos`（既定は `StrictMath`）を毎刻み呼ぶので、揃ったのは「この場面の角度で JS の `Math.sin` と `StrictMath.sin` がたまたま全部同じビットだった」から【推】。保証にはならない。

### 3.4 積み重ねと眠り

最初のソルバー（1 刻みに逐次の衝撃 8 回・Baumgarte で食い込みを戻す）は、箱 12 個の塔が 4 秒で倒れた（6 個は傾いたまま眠った）。原因は「食い込みを戻すために足した速さが次の刻みに残り、塔が跳ねて揺れ続ける」こと。位置を進めた後に、食い込みを戻す分を抜いた目標で 3 回解き直す relax の回（Box2D 3 の soft step の最後の回と同じ考え）を足したら、塔は立って 1.5 秒で眠った。点を解く順を回ごとに前から・後ろからと入れ替えるのも合わせて入れた。

relax の後は、積んだ山に 0.05 m/s 前後の揺れが残り、しきい 0.05 m/s・0.08 rad/s（JBox2D は 0.01 m/s）では 100 個の山が 10 秒たっても眠らなかった（レビューで指摘された読み落とし）。眠りの時計を relax の後の速さで見るように直し、しきいを 0.1 m/s・0.15 rad/s に上げて、100 個と 500 個が 10 秒の中で眠るようにした。JBox2D はしきい 0.01 m/s でも 1 秒足らずで眠るので、自前の揺れはまだ大きい。しきいを上げた代わりに、0.1 m/s 未満でゆっくり転がる・滑る石が 0.5 秒で止まり、隣の同じランクの石まで届かないことが起きうる（フェーズ 1 の性質のテストに「坂を転がる石が止まらない」を足して見る）。soft step（substep）に替えれば揺れが減る見込み【推】（6.3 の 5）。

## 4. 推す構成と、その理由

**自前（N）を推す**。理由は重さでなく、このエンジンの約束に合うかで決まる。

1. **JVM と wasm の決定性を、仕組みで守れるのは自前だけ**。dyn4j は測って分かれた（リライタで直る見込みはある）。JBox2D は揃ったが、揃う理由が無い。テープ（flow の記録）・指紋・テープとデッキ（前の版の jar で再生）は「同じ入力で同じ World」が前提。
2. **不変の World に入るのは自前だけ**。render-from-World・巻き戻し・F8 から始める・`Worldline` がそのまま使える。Java の物理は step が IO で、App の系（純粋な `App[w, {}]`）に入れられない（スパイクの比べの頁も `App.launchForBench` が要った）。
3. **重さは合わさる積み物の規模なら足りる**。同時に動くのは 30〜80 個で、自前でも CPU 4 倍に絞った頁で 1 刻み平均 1 ms（物 100 個）。ただし 1 フレームに 2 刻み回るフレームでは 2 ms になり、7 節の予算に余裕は無い。物 1,000 個の起きた山（砂の山の遊び）は JBox2D の 1.6 倍で、フェーズ 4 で詰める。足りない遊びが来たら 7 節の引き返す線で見直す。
4. **使わないゲームの代金が 0**（5.2）。
5. **3D の自前（B）と道具を共有できる**: `Rot2` と `Quat`・`PortableMath`・`StateHash`・`App.addPhysicsXd` の固定刻みと補間・lint。ソルバーそのものは 2D（Baumgarte + relax・substep 無し）と 3D（soft step・`solverSubsteps`）で違うので、共有するのは道具と API の形だけ（8 節の 6）。

dyn4j・JBox2D は「速さと積み重ねの安定の物差し」として `physics2d_lab` の比べの入口に残す（engine には入れない）。

## 5. engine の API の形

### 5.1 置き場と名前

- **engine_world** に置く（3D の `PhysicsWorld3d`・`CharacterBody3d` と同じ層）。体の id は `EntityId`。
- `Rot2`（向きの型）と `PortableMath` は **engine/src/core**（`Quat`・`Num` の隣）。`StateHash`（Float64 のビットを流す 64 bit の FNV-1a）も engine/src/core（3D と共有）。
- 形の型 `Shape2d` を下の層に置き、`PhysicsWorld2d` とナローフェーズの両方が使う（スパイクで `Phys2d` と `Narrow` が互いを見て flixlint の module-cycle に当たったので分けた）。
- 1 ファイル 1,200 行の上限に当たる中身は `PhysicsWorld2d.Internal.<役>`（`Solver`・`Narrowphase`・`Broadphase`・`Islands`）。
- 体は `EntityId` の順に並べて持つ（スパイクは足した順に id を振ったので、足した順と id の順が同じだった。engine ではゲームが id を渡すので、`insert` で id の順の位置へ入れる）。warm start の鍵は `(EntityId, EntityId, 特徴の番号)` の組で持つ（スパイクの `a<<40 | b<<16 | feature` は id が 2^23 を超えるとぶつかる）。

| 名前 | 何か | 呼び名の出どころ |
|---|---|---|
| `PhysicsWorld2d`（型・非 pub の enum + `pub type alias`） | 物理の World（不変の値） | Box2D `b2World` |
| `PhysicsWorld2d.Settings`・`settings()` | `gravity`・`iterations`（逐次の回数）・`relaxIterations`・眠りのしきい（刻みは持たない） | Box2D `b2WorldDef` |
| `PhysicsWorld2d.empty(settings, stepSeconds)`・`insert(id, body, w)`・`remove(id, w)`・`step(w)` | 作る・足す・消す・1 刻み（dt を受けない） | Rapier `insert`/`remove` |
| `PhysicsWorld2d.withSettings`・`withMaterials` | Doc の読み直し（次の刻みから使う） | 3D と同じ |
| `PhysicsWorld2d.applyImpulse`・`setLinearVelocity`・`setAngularVelocity`・`setKinematicTarget(id, position, rot, w)`・`setPosition(id, position, rot, w)`・`wakeUp` | 外から動かす（World を最後に） | Rapier `set_next_kinematic_position`・`set_position` |
| `PhysicsWorld2d.positionOf`・`rotationOf`（`Rot2`）・`linearVelocityOf`・`bodies`・`isSleeping`・`interpolatedPoseOf(id, alpha, w)` | 読む（render-from-World） | Godot `position`・Rapier `translation()` |
| `PhysicsWorld2d.events(w)`・`CollisionEvent2d`（`Started`・`Stopped`・`removed` のフラグ）・`SensorEvent2d`（`Started`・`Stopped`） | 直前の 1 刻みの出来事 | Rapier `CollisionEvent` |
| `PhysicsWorld2d.castRay`・`queryPoint` | 光線・点の当たり（当たり層で絞る） | Rapier `cast_ray` |
| `PhysicsWorld2d.stateHash` | 状態のビットの hash（`StateHash` を使う） | Box2D の CI |
| `RigidBody2d.dynamic`・`kinematic`・`fixed`・`withRotation(Rot2)`・`withLinearVelocity`・`withAngularVelocity` | 体の作り（角度は受けない） | Rapier `RigidBodyBuilder` |
| `Collider2d.circle`・`box`・`convex(頂点)`・`withMaterial`・`withSensor`・`withCollisionLayers`・`withMass` | 体の中の形（凸多角形は 8 頂点まで） | Rapier `ColliderBuilder`・Godot `collision_layer` |
| `PhysicsMaterial`（`friction`・`restitution`・`density`）・`PhysicsDoc2d.load`・`loadOr` | 材質と `physics2d.kind.json` | Godot `PhysicsMaterial` |
| `Rot2.identity`・`fromCosSin`・`fromDegrees`・`cos`・`sin`（engine/src/core） | 向き（cos・sin の組） | Box2D 3 `b2Rot` |
| `App.addPhysics2d({ physicsOf, withPhysics, clockOf, onEvents })`・`ViewCtx#fixedAlpha` | App の固定刻みで回す・補間の割合 | 3D の計画の 5.2 と同じ |

3D の計画の `CollisionEvent`・`SensorEvent` は、名前の決まり（3D 専用に `3d`）どおり `CollisionEvent3d`・`SensorEvent3d` に直す（8 節の 2 で 3D の計画を直す時に一緒に）。

**出来事の決め方**（スパイクには無い。フェーズ 2 で作る）: スパイクの `touches` は「この刻みに触れている組（離れ 1 cm 以下）」の一覧で、Started/Stopped の差分ではない。Geode も触れ続けている間に合わせる作りだった。engine では前の刻みの組の集まりと比べ、離れが 1 cm 以下（slop に結びつける）になった刻みに `Started`、離れが余白 2 cm を超えた刻みに `Stopped` を出す（幅を内側に置き、見た目で触れる前に合わさらないようにする）。眠った島の組は「触れたまま」と見て `Stopped` を出さない（Rapier と同じ）。体を消すと `removed` のフラグつきの `Stopped`。

**出来事を落とさない**: 系が step の前に `events` を読む形だと、1 フレームに 2 刻み回った時に 1 刻み目の出来事を落とす。3D の計画の 5.1 と同じく、`App.addPhysics2d` の `onEvents` が刻みごとに `Emit.Events` へ渡し、ゲームの系は `Emit.since` で読む。

ゲームの書き方（スパイクの `Geode` を engine の API で書いた形）:

```flix
// World の欄: physics = PhysicsWorld2d.PhysicsWorld2d・stones = Map[EntityId, Int32]（ランク）
def mergeTouches(started: List[CollisionEvent2d.CollisionEvent2d], w: World): World =
    started |> List.filterMap(CollisionEvent2d.startedPair) |> List.foldLeft((acc, pair) -> mergeIfSameRank(pair, acc), w)

app |> App.withFixedStep(1.0 / 60.0)
    |> App.addPhysics2d({ physicsOf = w -> w#physics, withPhysics = (p, w) -> { physics = p | w },
                          clockOf = w -> w#play, onEvents = Emit.collect(...) })
```

**誤った使い方を止める**（3D の 5.5 と同じ。型 → lint → docs の順）:

| 誤り | 止め方 |
|---|---|
| 可変の dt で物理を進める | 型: `step` が dt を受けない。App: `withFixedStep` が無いのに `addPhysics2d` を呼んだら組み立ての時に `bug!` |
| ゲームが `PhysicsWorld2d.step` を直に呼ぶ | lint-forbid の `physics-step-direct`（3D と共有） |
| 物理のファイルで三角関数 | lint-forbid の `physics-portable-math`（engine の物理のファイル・3D と共有） |
| 入ってきた速さ・衝撃に NaN・無限大 | 捨てて最初の 1 回だけ 1 行言う。中で NaN が出た体は消して `removed` の出来事と 1 行の warn（3D の 4.2 の 6 と同じ） |
| 材質の値が 0 以下・NaN | `PhysicsDoc2d.load` が `Err`、`loadOr` で既定値で続けて 1 行言う |

### 5.2 使わないゲームの wasm と 1 コマ

物理を呼ばない最小の頁（`webvariants/nophys.flix`・箱 1 つを動かすだけ）を、3 つの作業場で書き出して比べた:

| 作業場 | src に物理のモジュール | flix.toml に dyn4j・JBox2D の jar | classes.wasm | brotli |
|---|---|---|---|---|
| physics2d_lab そのまま | ある（Phys2d・Narrow・Geode・比べの入口・Java のラッパー） | ある | 3,764,579 B | 641,262 B |
| 写し A | 無い | ある | 3,764,573 B | 641,399 B |
| 写し B | 無い | 無い | 3,764,579 B | 640,800 B |

3 つとも同じ大きさ（差は数 B・brotli の揺れ 0.1 %）。TeaVM は呼ばれない Flix のモジュールも、classpath にあるだけの jar も落とす。だから engine_world に `PhysicsWorld2d` を入れても、呼ばないゲームのブラウザ版は増えない。

- 1 コマの重さ: `App.addPhysics2d` を呼ばないゲームでは、App が物理のアキュムレータも step も持たない（3D の計画と同じ）。1 コマに足される仕事は 0。
- まだ測っていない代金: engine_world が約 1,000 行増えることで、どのゲームでも `flix check`・ビルドの時間が少し延びる。フェーズ 1 の終わりにテンプレート 1 本の `make check` の時間を前後で測って書く。
- jar: 自前は jar を足さない。Java の物理を engine に入れるなら engine_full の flix.toml に書くことになり、全部のテンプレートとゲームが `make new-game`・版上げのたびに取りに行く。別のパッケージに分けて使うゲームの flix.toml にだけ書く道はあるが、4 節の 1・2 は残る。

### 5.3 眠りと出し入れ（スパイクで分かった事）

- 眠った体どうしの組はナローフェーズを見ず、島をつなぐだけ（ブロードフェーズの円が重なれば同じ島）。
- 体を消すと、近くの眠りの体を起こす（下の石が消えて上の石が宙に浮かないように）。スパイクはブロードフェーズの円で近くを探す。
- 眠った島に起きた体が触れた刻みは、眠っていた体を「その刻みだけ重さ無限」として扱い、次の刻みから動かす（起こした刻みに接触の点が無いまま重力で沈まないように）。
- スパイクの `Geode.advance` は端数を Float64 で貯めて 1 フレーム 4 刻みで切っている。3D の計画が避けると書いた形なので、engine では `App.addPhysics2d` のアキュムレータ（ナノ秒の整数）に替える。

## 6. 型で決定性を守る形（スパイクで効いたか）

### 6.1 入れた物

- `Rot2`（非 pub の enum + `pub type alias`）: 作る口は `identity`・`normalized`（組を長さ 1 に戻す）・`fromDegrees`（`PortableMath`）の 3 つ。体の向きの欄も作りの欄も `Rot2` だけを受ける。
- `PortableMath.sin/cos`: [-π, π] へ折り返し、四分円で [-π/4, π/4] の多項式（テイラーの 15・16 次）へ近づける。足し引き掛け割りだけ。JVM の `Math.sin` との差は -360〜360 度で 1e-12 未満（テスト緑）。
- lint: ゲームの `bin/lint-rules/forbid.local.json` に `physics-portable-math`（`src/phys/` で `Num.sin|cos|tan|atan2|asin|acos|log|pow`・`Math.`・`Float64.pow|exp|log` を止める）。わざと `Num.sin` を書いたファイルで当たるのを確かめた。`PortableMath.` には当たらない。

### 6.2 効いたか・効かない所

- 効いた: 自前の指紋は JVM と wasm で 3 場面とも同じ（版を替えた 2 回とも）。物理の中で三角関数を使う道が lint で塞がっているので、「どこかで 1 ビットずれた」を探す仕事が要らない。
- **効かない所（穴）**: `Rot2.normalized(c, s)` は pub で、どんな Float64 の組でも受ける。ゲームが `Rot2.normalized(Num.cos(a), Num.sin(a))` と書けば、型は止めない（lint も物理のファイルしか見ない）。engine では名前を `Rot2.fromCosSin` にして「組をそのまま信じる口」だと分かるようにし、ゲームの側に知らせる lint を足すか、docs で守る約束と書くかを決める（8 節の 4）。2D だけのゲームのテープを機種をまたいで流す話は、この穴を塞ぐまで約束しない。
- 型だけでは止まらない物: 回る順（Map・Set の作り直し・`Array.sortWith`）・`Float64.toString` の指紋。回る順はテスト（同じ入力で同じ指紋・足す順を逆にしても同じ指紋）で見る。`Array.sortWith` は engine の lint（`vector-array-sort-quadratic`）がもともと止める（スパイクで当たった）。

### 6.3 高速化と眠り（フェーズ 4 で入れる。スパイクの JFR と測りから）

1. warm start の控えを `Map`（木）から「鍵で並べた配列 + 二分探索」へ（JFR で 1 刻みの 1 割）。
2. ブロードフェーズの並びを前の刻みから持ち越して挿し込みで並べ直す（ほぼ並んだ入力。毎刻みの `List` の並べ替えと `Vector` の作り直しを消す）。
3. ナローフェーズで多角形の world の頂点を組ごとに作り直さない（体ごとに 1 刻み 1 回だけ配列へ）。
4. 眠った物 1,000 個の場面を足して測る（3.1 で測れていない）。
5. 眠るまでの時間: 積んだ山の揺れ（0.05 m/s 前後）を減らす。まず Box2D 3 の soft step（substep 4 回）を 2D にも入れて比べ、揺れが減れば 3D とソルバーの形もそろう（8 節の 6）。
見込み: 1〜3 で物 1,000 個の起きた山が 1.5〜2 倍速く【推】（JBox2D と同じ所まで）。5 で 100 個が 1 秒前後で眠れば、物 100 個の平均は JBox2D に近づく【推】。

### 6.4 3D の計画への持ち帰り

- ソルバーの内側の輪で record を読まない（欄を名前で探すので 3〜5 倍遅い）。3D の 6.1 の「ソルバーは region の中で配列を使う」に「接触の点・体の欄も stride の配列。record・`Map` を輪の中で引かない」を足す。
- 並べ替えは `Sort.sortStableWith` か挿し込み（`Array.sortWith` は並んだ入力で二乗）。
- 2D のスパイクで relax の回だけで塔が立ったので、3D の段 2 の引き返す線（15 h）の手前の手当てとして「まず relax の回」を書き足す。

## 7. フェーズと実時間

見積もりはスパイクの実績から（自前のソルバー・当たり・眠りは、スパイクで高速化と塔の直しを含めて約 3 時間）。engine に移すのは型と API を整え、出来事・kinematic・Doc を足す仕事が主。3D の計画は同じ量に推測 6 h を置いているので、フェーズ 2 は割り引かない。

| フェーズ | 中身 | 届く物 | 目安 |
|---|---|---|---|
| 0 | 2D と 3D の共通の道具: `Rot2`・`PortableMath`・`StateHash`（engine/src/core）・engine の `forbid.json` に `physics-portable-math`・`physics-step-direct`・docs/physics.md の頭 | 決まりが型と lint とテストで守られる | 2 h |
| 1 | `PhysicsWorld2d`・`RigidBody2d`・`Collider2d`・`Shape2d` を engine_world へ（`EntityId` の順の並び・組の鍵・非 pub の型・`Settings`）・テスト a〜d（同じ指紋・足す順を逆にしても同じ・巻き戻し・基準の指紋）と性質のテスト（跳ねる高さ・眠る・塔が立つ）・`make check` の時間を前後で測る | ゲームから円と凸多角形が積める | 4〜5 h |
| 2 | 出来事（前の刻みとの差分で `Started`・`Stopped`・`removed`）・kinematic の体と `setKinematicTarget`・sensor と `SensorEvent2d`・当たり層・`castRay`・`queryPoint`・材質の Doc（`PhysicsDoc2d`・`withMaterials`・`withSettings`）・NaN の決まり | 合わさる遊び・領域・光線が engine の API で書ける | 5〜6 h（割り引かない） |
| 3 | `App.addPhysics2d`（`onEvents` → `Emit.Events`）・遊びの時計で貯める物理のアキュムレータ（ナノ秒の整数）・跳ばしたフレームで 0 に戻す・`ViewCtx#fixedAlpha`・`interpolatedPoseOf`・テスト c2（`onJump` で跳ばして続けた指紋）と「1 フレーム 2 刻みでも出来事を 1 回ずつ読む」 | ポーズで止まる・120 Hz でカクつかない | 3〜4 h（3D の段 4 が先なら 1.5 h） |
| 4 | 高速化と眠り（6.3 の 1〜5）・`bench/physics2d`（この比べの場面と「眠った 1,000 個」）・`make bench-web BENCH=physics2d CPU=4`・JVM と wasm の指紋の門（`gui: true`・release の前に手元で） | 予算と決定性の確かめ | 4〜6 h |
| 5 | 早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本（「同じランクの石が触れたら合わせる」）・engine のリポだけの門は AGENTS.md の検証の節と `testdata/agent-eval/engine-repo.json` | エージェントが API を選べる | 1.5 h |
| 計 | | | 19.5〜24.5 h |

**重さの予算**（フェーズ 4 の門）:

| 場面 | PC（JVM・温まった後） | ブラウザ CPU 4 倍 | 今 |
|---|---|---|---|
| 物 100 個が落ちて積もる 600 刻みの平均 | 0.3 ms 以下 | 0.8 ms 以下 | 0.26〜0.38 ms・1.03 ms |
| 物 1,000 個の起きた山 | 4 ms 以下 | 20 ms 以下 | 4.2〜7.1 ms・31 ms |
| 眠った物 1,000 個 | 0.2 ms 以下 | 1 ms 以下 | 未測 |

物 100 個の行は、1 フレームに 2 刻み回っても 30 fps の線を崩さないよう、今より 2 割下に置いた。予算の値も人に決めてもらう（8 節の 5）。

**引き返す線**: フェーズ 4 の後も物 1,000 個の起きた山がブラウザ CPU 4 倍で 30 ms を超え、かつその規模を毎刻み動かすゲームが決まっていたら、そのゲームだけ JBox2D を engine の外の別のパッケージで包む案を出す（不変の World と JVM/wasm の約束はそのゲームでは捨てる、と書いて人に聞く）。フェーズ 4 が 8 h を超えたら、6.3 の 5（soft step）を後のフェーズへ回し、眠りのしきいで済ませる。

**順**: 2D を 3D より先に入れる（推す）。スパイクのソルバーがそのまま移せ、共通のフェーズ 0 と、`App.addPhysicsXd` の固定刻みと補間（フェーズ 3）を 2D で先に確かめてから 3D が使える。3D の TPS デモが先に要るなら、フェーズ 0 と 3 だけ共通にして 3D から入る。

各フェーズの終わりに: そのフェーズのテストが緑・`make verify SUITE=affected`。レビューはフェーズ 2 の後とフェーズ 4 の後の 2 回（1 回目で指摘を全部出させ、まとめて直して確かめる）。

## 8. 人に決めてほしい事（推す答えつき）

1. **2D は自前（N）で良いか** — 推す: はい。JVM と wasm の決定性を仕組みで守れ、不変の World に入るのは自前だけ。重さは、物 100 個は JBox2D の 2.7 倍・起きた 1,000 個は 1.6 倍（ブラウザ CPU 4 倍。500 個で一番軽く出たのは眠りのしきいが緩いため）。合わさる積み物の規模なら足りるが、100 個の予算に余裕は無い（フェーズ 4 で詰める）。
2. **3D の計画の 3.2 と 10.5（「2D は今は何もしない・両方通れば dyn4j」）を覆し、3D の計画を直して良いか** — 推す: はい。直す所は 3.2 の推す段取り・10.5 の答え・`CollisionEvent`/`SensorEvent` を `3d` つきの名前に・6.1 に「record・`Map` を輪の中で引かない」・段 2 の引き返す線の手前に「まず relax の回」。
3. **2D と 3D のどちらから入れるか** — 推す: 2D から（共通のフェーズ 0 と 3 を 2D で先に作り、3D が使う）。
4. **`Rot2` の組をそのまま受ける口を pub にするか** — 推す: `Rot2.fromCosSin` の名前で pub にし、ゲームの側に `Rot2.fromCosSin(Num.` の形を知らせる lint（止めずに知らせる）を足す。完全には塞げないので、機種をまたぐテープは約束しない。
5. **重さの予算**（7 節の表）— 推す: 表の値。物 100 個の行が今は外れている（1.03 ms 対 0.8 ms）ので、フェーズ 4 で眠りとブロードフェーズを詰めて入れる。
6. **2D のソルバーの形と眠りのしきい** — 推す: しきいは `Settings` に出し既定 0.1 m/s・0.15 rad/s。ソルバーはまず今の Baumgarte + relax（測って塔が立った）で入れ、フェーズ 4 で soft step（substep）を試して、眠るまでの時間と塔のずれが良くなれば替える。替えたら `Settings` の欄を 3D と同じ `solverSubsteps` にそろえ、しきいも Box2D に近い値へ下げる。
7. **engine_world の App の拡張**（フェーズ 3）: `App.addPhysics2d`・物理だけの 2 つ目のアキュムレータ（遊びの時計で貯める・ナノ秒の整数）・跳ばしたフレームで 0 に戻す・`ViewCtx#fixedAlpha`・`onEvents` — 推す: はい（3D の計画の 10.3 と同じ物。先に作った方を後が使う）。
8. **置き場** — 推す: `PhysicsWorld2d` 一式は engine_world、`Rot2`・`PortableMath`・`StateHash` は engine/src/core に pub で足す（engine の拡張）。
9. **形の範囲** — 推す: 円・箱・凸多角形（8 頂点まで）。関節・CCD・凹んだ形・砂（ボクセル）は入れない。砂のゲームが来たら、剛体でなくセルの規則の別の計画にする。
10. **dyn4j・JBox2D の扱い** — 推す: engine に入れない。`physics2d_lab` の比べの入口に物差しとして残す。
11. **physics2d_lab をテンプレートにするか** — 推す: しない（音と遊びの終わりが無い）。フェーズ 2 の後に engine の API で書き直した版を `docs/physics.md` の手本にする。

## 9. 参考に見た物（11-26）

- このスパイク: `~/Documents/flix_ge_workspace/physics2d_lab`（コミット efa3248〜736a494）。
- 3D の計画: [engine-physics.md](engine-physics.md)（3.2 の 2D の見立て・4 節の決まり・5.1 の出来事・5.2 の App の繋ぎ）。
- Box2D 3 の soft step と relax: https://box2d.org/posts/2024/02/solver2d/
- dyn4j: https://github.com/dyn4j/dyn4j（`Transform.rotate` の `Math.cos/sin`）・JBox2D: https://github.com/jbox2d/jbox2d（`MathUtils`）。

## 10. 追加の計測: ギチギチの手触りと高速化・敷き詰めの負荷（11-26 夕方）

人の依頼「スイカゲームのように押し合って動き続ける手触りを出しつつ速くする」と「大きい瓶に石を敷き詰める負荷テスト」で、6.3 の手を順に入れて測った。engine は main（36ba0c7eb・432662ba1 の取り込み後）を `bin/fge use-engine` で向け直してから測り直した。コードは physics2d_lab のコミット ac3c184（段 1）・6f2e7d5（段 2）・fb3bf02（段 3）・6e7c57f（段 4）・99d5213（遊びの設定と負荷の入口）。

### 10.1 手触りで変えた設定

| 欄 | 前（眠る版） | 後（ギチギチの版・遊びの既定） |
|---|---|---|
| ソルバー | 1 刻みに逐次の衝撃 8 回 + relax の回 3 回（Baumgarte） | soft step（Box2D 3 の形）: substep 4 回 × 1 回・毎 substep に warm start と relax・最後に跳ね返り 1 回 |
| 接触のばね | — | 30 Hz・減衰比 10・押し戻しは 3 m/s まで |
| 解く順 | 回ごとに前から・後ろから | 同じ（soft step でも入れないと箱 12 個の塔が 3 秒で倒れた） |
| 眠りのしきい | 0.1 m/s・0.15 rad/s | 0.01 m/s・0.02 rad/s（`Settings` の欄。0 以下で眠らない） |

塔（箱 12 個・600 刻み）: 前は横のずれ 0.7 cm・上の箱 5.72 m、後は 1.1 cm・5.64 m（ばねのぶん 11 cm 沈む。dyn4j の 5.62 m と同じくらい）。積んだ山の速さの二乗平均（揺れの目安・600 刻みの後）は前後とも 0.000〜0.002 m/s で、山が震え続ける形にはならなかった。テスト 22 本（巻き戻しを含む）は全部の段で緑。

### 10.2 段ごとの重さ（起きたまま・眠り無し・600 刻みの 1 刻みの平均）

PC は 2 回り × 2 回の 4 回の一番軽い値（負荷 15〜60 の中で測った）。ブラウザは CPU 4 倍・頁の中の 2 回目。

| 段 | 中身 | PC 100 / 500 / 1,000 個 | ブラウザ CPU 4 倍 |
|---|---|---|---|
| 0 | 前のソルバー（relax・段 1 のコード） | 0.29 / 1.72 / 3.84 ms | 1.97 / 14.6 / 31.8 ms |
| 1 | soft step | 0.32 / 1.75 / 3.88 ms | 2.31 / 14.3 / 33.9 ms |
| 2 | warm start の控えを `Map` から並べた配列 + 二分探索（並べるのは `java.util.Arrays.sort(long[])`） | 0.26 / 1.54 / 3.36 ms | （測っていない） |
| 3 | ナローフェーズの多角形の world の頂点を体ごとに 1 刻み 1 回だけ作る | 0.26 / 1.61 / 3.21 ms | （測っていない） |
| 4 | JFR の上位: 姿勢（`Narrow.Pose`）とばねの係数を record からタプルへ | 0.25 / 1.41 / 3.15 ms | 1.65 / 9.5 / 20.2 ms |
| 比べ | JBox2D（眠り無し・`setAllowSleep(false)`） | 0.13 / 1.17 / 3.56 ms | 0.76 / 6.6 / 19.3 ms |

- 段 1 → 4 で、PC は 1,000 個が 3.88 → 3.15 ms（2 割）、ブラウザ CPU 4 倍は 33.9 → 20.2 ms（4 割）。ブラウザの方が record と `Map` の代金が重かった。
- 起きたままの 1,000 個は、PC で JBox2D より軽く（3.15 対 3.56 ms）、ブラウザ CPU 4 倍で JBox2D の 1.05 倍（20.2 対 19.3 ms）まで来た。100 個は 2.2 倍（1.65 対 0.76 ms）・500 個は 1.4 倍のまま。小さい山で負けるのは、1 刻みごとの定まった代金（体を Vector から配列へ詰めて戻す・`List` で並べ替える・`MutList` に点を集める）で、6.3 の 2（並びの持ち越し）の残り。
- 段 2・3 のブラウザの数は書き出しの数を減らすため測っていない（段 1 と段 4 の 2 点だけ）。
- 指紋: 段 1〜4 は手当ての前後で 100・500・1,000 個の指紋が変わらず（`6872247813266521960`・`-4515076696620538792`・`-1939236820763545254`）、JVM と wasm（CPU 1 倍・4 倍）でも同じ。段 0（relax）も `-4281427956772262582` ほかが JVM と wasm で同じ。

### 10.3 敷き詰めの負荷（大きい瓶に降らせ続ける）

`FillBench`: 幅 16.8 m・高さ 24 m の瓶（今の 4 倍）へ 4 刻みごとに 3 個（ランク 0〜1）を降らせ、100 刻みごとに石の数と 1 刻みの平均を出す（合わさりは入れない）。soft step の設定のまま、眠りのしきい 0.01 m/s と眠り無しの 2 通り。

| | 16 ms を超えた石の数 | 途中の値 |
|---|---|---|
| ブラウザ CPU 4 倍・眠り無し | **約 600 個**（525 個 13.8 ms → 600 個 16.9 ms） | 300 個 6.1 ms・825 個 25.6 ms |
| ブラウザ CPU 4 倍・眠りあり | **約 600 個**（600 個 17.1 ms） | 眠り無しとほぼ同じ |
| PC・眠り無し | **約 1,800〜2,300 個**（2 回で揺れた: 1 回目は 2,250 個 10.8 ms の次の区切りで 38 ms、2 回目は 1,800 個で 16.2 ms） | 1,000 個 6〜7 ms |
| PC・眠りあり | **約 3,000 個**（2,925 個 15.0 ms → 3,000 個 22.7 ms） | 1,500 個 8.1 ms |

- 降らせ続けている間は山が 1 つの島につながり、上で落ち続ける石が島全体を起こすので、眠りがあっても全部起きている（`awake` = 石の数）。眠りが効くのは降らせ終えて山が落ち着いた後だけ。
- PC の数は機械の負荷（30〜60）で揺れた。ブラウザ（CPU 4 倍）は 1 刻み 16 ms の線で 600 個が上限で、スマホの 60 fps で遊ぶなら同時に動く石は 300 個（6 ms）ほどまでと読む。
- PC の 1 回目で 2,325 個の区切りが 38 ms に跳ねたのは、1 区切りだけで次で止まった（上限 24 ms で止める作り）。GC か、ほかの作業の重さの揺れ【推】。

### 10.4 動画

- 前後の比べ: `~/Documents/flix_ge_workspace/physics2d_lab/debug/geode-before-after.mp4`（30 秒・左が前・右が後。どちらも石 80 個を瓶に並べた所から始め、並べた直後に同じランクの隣どうしが合わさって連鎖する。左上に設定の名前・石の数・1 刻みの ms（30 コマの平均））。
- 敷き詰め: `~/Documents/flix_ge_workspace/physics2d_lab/debug/geode-stress.mp4`（25 秒・3 倍の瓶（幅 12.6 m・高さ 18 m）に毎コマ 4 個ずつ（ランク 0〜4）1,300 個まで降らせ、合わさりで山が押される所。左上に石の数と 1 刻みの ms）。終わりの方は瓶が溢れ、上で合わさった大きい石が瓶の外へはじき出される（数えた石には外へ落ちた物も入る）。24 秒の時点で 769 個・1 刻み 3.0 ms（PC）。5.4 MB。前後の比べは 3.3 MB。
- 動画の ms は描き出しと同じ JVM の中で 2 刻みを測った値で、機械の負荷で揺れる（表の数とは条件が違う）。

### 10.5 計画への持ち帰り

- 8 節の 6（2D のソルバーの形）は「soft step に替える」で答えが出た: 重さは relax と同じで、塔は立ち、揺れも出ない。ただし soft step でも点を解く順を入れ替えないと塔が倒れる（Box2D 3 は graph coloring で順が変わる【推】）。
- 6.3 の 1・3 と record をタプルへ替える手は効いた（ブラウザで 4 割）。6.3 の 2（並びの持ち越し）と、Vector と配列の詰め替えの代金が、小さい山で JBox2D に負ける残り。
- 予算（7 節）の「物 1,000 個の起きた山・ブラウザ CPU 4 倍 20 ms 以下」は 20.2 ms でほぼ届いた。「物 100 個 0.8 ms 以下」はまだ届かない（1.65 ms）。

## 11. JBox2D が小さい山で速い理由と、取り込んだ手（11-26 夜）

JBox2D 2.2.1.1 は手元の jar を `javap` で読み、ソースは GitHub の頁を読んだ（新しく取った物は無い）。自前は JFR で 1 刻みの中身を並べた（物 100 個・眠り無し）。

### 11.1 速さの理由の上位 3 つと効き目

| 順 | JBox2D の手 | 自前で重かった所（JFR） | 取り込んだ形 | 効き目（PC 1 刻み 100 / 500 / 1,000 個） |
|---|---|---|---|---|
| 1 | ブロードフェーズは動的な AABB の木（`DynamicTree`）で、体ごとにぴったりの AABB を持つ。多角形の当たり（`b2CollidePolygons`）は片方の軸で離れたら止める | 体を囲む円で組を選んでいた。床と壁の箱は囲む円の半径が 12〜15 m で、全部の体と組になり、毎刻みナローフェーズ（多角形の分離軸）を回していた。100 個の山で 1 刻みの 3 割 | 体ごとの AABB（多角形は world の頂点の端）で掃く・多角形の分離軸を片方で離れたら止める（コミット 1e34a7a） | 0.25 → 0.20・1.41 → 1.17・3.15 → 2.46 ms |
| 2 | 体（`Body`）と接触（`Contact`）は中で書き換える物で、刻みをまたいで持ち越す。毎刻み作り直さない | World を `Vector[Body]` で持ち、毎刻み体の record を全部作り直していた（record の欄を名前で探して書き戻す代金）。100 個で 1 刻みの 3 割 | World を欄ごとの Vector（`state` stride 8・`props` stride 5・`ids`・`shapes`・`tags`）にし、体の record は読む口（`bodies`）だけが作る（コミット fef52a0） | 0.22 → 0.16・1.13 → 0.86・2.41 → 1.84 ms |
| 3 | ソルバーの内側の輪は float の欄を直に読む素の Java のループ | Flix の region の輪でも、閉包の呼び出し・タプルの戻り値・境界の確かめが残る | 接触のソルバーの内側の輪だけを Java の `fge2d.SoftSolver`（状態を持たない static な関数。double の配列を受けて書き換える）にした（同じコミット・`solver=softjava`） | 0.16 → 0.15・0.86 → 0.73・1.84 → 1.60 ms |

まだ JBox2D に残る差: 接触を持ち越すので、毎刻みの点の集め直し（`MutList` の record）・warm start の控えの並べ替えと二分探索・`List` での並べ替えが無い。オブジェクトの pool（`org.jbox2d.pooling`）で毎刻み new しない。float で配列が半分。ばね無しの逐次の衝撃（8 回）と 2 点の接触を一度に解く block solver（`Mat22` の `K`・`normalMass`）。

### 11.2 (a)・(b)・(c) の重さ（起きたまま・眠り無し・600 刻みの平均）

PC は 2 回り × 2 回の一番軽い値（負荷 12〜25）。ブラウザは CPU 4 倍・頁の中の 2 回目（同じ時間帯に続けて流した）。

| 案 | PC 100 / 500 / 1,000 個 | ブラウザ CPU 4 倍 | 指紋（JVM と wasm） |
|---|---|---|---|
| 10 節の段 4（取り込む前） | 0.25 / 1.41 / 3.15 ms | 1.65 / 9.5 / 20.2 ms | 一致 |
| (a) Flix のまま JBox2D の手を写す（AABB・早く止める・World を欄ごとの Vector に） | **0.16 / 0.86 / 1.84 ms** | **1.16 / 6.7 / 15.2 ms** | 一致（`-3799106374836966887`・`-873240878633481281`・`-3450701262187370632`） |
| (b) (a) + ソルバーの内側の輪だけ Java | **0.15 / 0.73 / 1.60 ms** | **0.90 / 5.4 / 11.7 ms** | 一致。しかも (a) と同じ指紋（同じ式を同じ順で書いたので、Flix と Java でビットが同じ） |
| (c) JBox2D のソースの一部を写す | 試していない（下） | — | — |
| 比べ: JBox2D（眠り無し） | 0.13 / 1.28 / 3.01 ms | 0.71 / 6.5 / 20.2 ms | 一致（この場面では） |

- 500 個と 1,000 個は (a) だけで JBox2D より軽くなった（ブラウザ CPU 4 倍の 1,000 個: 15.2 対 20.2 ms）。100 個は (a) で 1.6 倍、(b) で 1.27 倍まで詰まった。
- (b) の Java のクラスは wasm で 1.8 KB（brotli 0.7 KB）。TeaVM がそのまま wasm にした。
- 巻き戻しのテスト・決定性のテスト（22 本）は (a)・(b) とも緑。塔（箱 12 個）も変わらない（soft step で横のずれ 0.5 cm）。
- (c): JBox2D は BSD-2 条項（`Copyright (c) 2014, Daniel Murphy`。写すなら著作権の表示と条件の文を残す）。ただし中身は float で、回転を毎刻み `MathUtils.sin/cos` で作り（`Sweep.getTransform`）、体と接触を書き換える物の上に組まれている。写すと double に直す・三角関数を `Rot2` に替える・不変の World との境目を作り直すことになり、ほぼ (a)・(b) を書き直すのと同じ仕事になる。取り入れる価値があるのは 2 点の接触を一度に解く block solver の考えだけで、これは Box2D 本体（MIT）の式から書く方が出どころが素直。だから (c) は試さず、block solver はフェーズ 4 で Box2D から写す候補にした。

### 11.3 Java の内側の輪の決定性と置き場

- 決定性の根拠: Java 17 から浮動小数はいつも strict（JEP 306。`strictfp` が既定になり、FMA で縮めない）。TeaVM は double の四則を wasm の f64 の命令にする（IEEE 754 の丸め）。`Math.max/min` は NaN と -0.0 の扱いまで決まっている。測って、JVM と wasm・Flix と Java の 4 通りで指紋が同じだった。
- 決まり: Java の側でも `Math.sin/cos/atan2`・float・`Math.fma` を使わない。lint-forbid の `physics-portable-math` を `.java` にも当てる（forbid は `.java` を見られる）。
- 置き場（層を置く物差し）: Java のクラスは抽象の層でなく、1 つの実装の中身の書き方なので、物差し（実装が 2 つある所にだけ層を置く）には当たらない。ただし engine_world は今は Flix だけのパッケージで、Java は render_gl（`fge-gl` の jar・Release に置いて URL で配る）と engine_web（TeaVM）にしか無い。engine に入れるなら、(1) `fge-gl` の jar に入れて版を上げる、(2) 物理だけの jar を別に作る、のどちらかで、配る物が増える。physics2d_lab では `jar-dependencies` を `url:file` で書くと export-web の組み立てが受けず、127.0.0.1 の http で渡した（engine に入れる時はこの手間は無い）。
- 推す: **(a) を本筋にする**（Flix だけで、500 個以上は JBox2D より軽い）。(b) は物 100 個の予算（ブラウザ CPU 4 倍 0.8 ms）にまだ届かない時の最後の手として残し、入れるなら置き場（`fge-gl` の jar か物理だけの jar か）を相談する。(b) の Java は (a) と同じ指紋を出すので、Flix の版をテストの正にしたまま、速い版として差し替えられる。

## 人の決め（2026-11-26）

「おすすめ案で」。8 節の 11 個は推す答えのとおり。ただし 10・11 節の計測で答えが進んだ所は新しい方に読み替える:
- 1: 自前（N）。速さの本筋は 11 節の (a)（AABB・SoA の World）。(b) の Java のソルバーは物 100 個の予算に届かない時の最後の手で、入れる前に置き場を相談する。
- 6: ソルバーは soft step（substep 4 回・解く順の入れ替えつき）、眠りのしきいの既定は 0.01 m/s・0.02 rad/s（10 節で塔が立ち、揺れも出ないと確かめた）。`Settings` の欄は 3D と同じ `solverSubsteps`。
- 2・3・7・8: 3D の計画（engine-physics.md）の 3.2 と 10.5 を直し、2D から入れる。engine_world の App の拡張と engine/src/core の `Rot2`・`PortableMath`・`StateHash` の追加は了承（engine の拡張）。
