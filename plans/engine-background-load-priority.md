# 後から届く素材を解く順と予算を engine で吸収する — 計画（相談用・未着手）

状態: 計画（git に入れない）。engine main 9e241ab96（v0.114.0・テンプレートは人物と持ち物を別の Group に分け、描く階の建物の束が届いていれば `Covered(1.0)` で 1 本すぐ解く分岐を足した後）の上。engine の型に手を入れるので、着手の前に人へ相談する（A と B の方針は 11-26 に人の了承済み。ここで決めるのは形と段）。
**事実**はソースか実測（スパイクの worktree `/Users/abab/Desktop/fge-load-prio-spike`・枝 `spike/load-priority-units`・コミットなし・main にマージしない。4.2 の決まりの模擬は同じ worktree の `bench/scene3d/sim_background_load.py`）。**推測**は「推測:」と書く。
レビュー: 1 回目 72 点（必須 7・望ましい 10）→ 全部をこの版で直した。

## 0. 結論

ゲームが手で決めている 4 つ（Group の分け方・`Group#costMs`・優先の並び `priority`・場面ごとの予算）のうち、**3 つを engine が持つ**。予算は「この場面でどれだけ止まってよいか」というゲームの判断なので残す（Unity の `backgroundLoadingPriority` と同じ位置づけ）。

- **A. 見込みを鍵ごとに**: 機種が知っている「鍵の道のバイト数」（`AssetDownloads#sizeOf`）× 学んだ「1 KB あたりの ms」。1 KB あたりの ms は、解くたびに測った ms と KB の和から出す（古い分ほど薄める）。`costMs` はゲームから消える。機種の速さの差は学ぶ値が吸う。
- **B. 近い物から**: 鍵に「要る範囲」（`BackgroundLoad.Place`: `Everywhere` か箱の並び `Within`）を持たせ、ゲームは毎コマ「見る所」（`BackgroundLoad.Order.NearestTo(足元)`）だけを渡す。engine が範囲までの距離で並べ直す（同じ距離なら `keys` の順 = ゲームが並べた大事な順）。
- **予算 `Idle(ms)` の中身を 2 つ直す**:
  1. **収まる物から**: 頭の鍵が収まらなくても、後ろの収まる鍵へ進む（今は頭で止まる。人物が束の後ろで待った原因）。
  2. **範囲の内の重い鍵は「はみ出し」で 1 本だけ始め、はみ出しは間引く**: 範囲の内の鍵が収まらない時、このコマにまだ予算を使い切っていなければ 1 本だけ始める。予算を超えた 1 本の後は、その止まりの 9 倍の時間を空けるまで次のはみ出しをしない。今の「2 秒待って見込みを戻す」（`estimateResetMs`）はこれに置き換えて消す。
  - 止まりの長さの上限: 収まる物は見込みが予算に収まる物だけなので、1 コマあたりの止まりは「予算 × 見込みの外れ」まで（3 節の実測で外れは最大 2.4 倍 → `Idle(45)` で 110 ms 前後。収まる物は間引かないので、人物 3 体なら続く 3 コマで 3 回止まりうる。時間の割合は保証しない）。はみ出し（範囲の内の重い鍵）は 9 倍の間で間引くので、時間の 1 割まで。

- **門（`App.withLoadGate`）を「解けた」まで待つ形に**: 門の名前（道）を持つ鍵が、その Group の `Pending` で Loaded になるまで、門は World を出さない（今は届いたか＝missing だけを見る）。門が止めている鍵は、予算と間引きを問わず 1 コマに 1 本始める。テンプレートの `Covered(1.0)` の分岐と `Bundles.buildingKeysOf`（9e241ab96）は要らなくなる。

数:
- **新しい pub 2 つ**（`BackgroundLoad.Place`・`BackgroundLoad.Order`）。人物も束と同じ `Within` で渡すので、点の周りの箱を作る口は置かない。
- **形の変わる pub 7 つ**（うち 4 つは `*.Internal` でゲームから見えない）: `BackgroundLoad.Group`（`costMs` を消し `loadRangeOf` を足す）・`BackgroundLoad.Pending`（`costMs` を消し `sampleMs`・`sampleKb`・`nextOversizeMs` を足す）・`LoadProgress.AssetDownloads`（`sizeOf` を足す）・`App.Internal.BackgroundLoad.GroupSpec`（`priority` を `order` へ）・`BackgroundLoad.Internal.StepSpec`（`priority` を `order` へ・門の道 `gated` を足す）・`App.Internal.BackgroundLoad.addStep`（step の関数に門の道を渡す）・`App.Internal.LoadWait.Context`（解けていない門の道の集まりを足す）。**消える pub は名前 1 つ**（`BackgroundLoad.Internal.estimateResetMs`）**と欄 2 つ**（`Group#costMs`・`Pending#costMs`。`GroupSpec#priority`・`StepSpec#priority` は `order` への名前替え）。
- **ゲーム（retro3d-horror-starter・main 9e241ab96 から）が書く行: 足す 51・消す 107（正味 −56。src は足す 41・消す 77）**。新しく考えて書く物は `rangeOf` と `boundsSeeing` の 2 つ（13 行）で、残りは Group を 1 つに戻す分と、手で決めていた分（9e241ab96 の建物の分岐を含む）を消す分（7 節の表）。
- 見積もり: **engine 8〜10 時間＋テンプレート 3 時間＋手元のゲーム 5 本 2 時間**（8 節）。

## 1. 今の形と起きた事（事実）

### 1.1 今の決まり（`engine/src/platform/BackgroundLoad/Internal.flix` の `step`・`decodeWithin`・`mayStart`）

- 見込みは **Group に 1 つ**（`Pending#costMs`）。解くたびに `(見込み + min(測った ms, 見込み×3 か 50 の大きい方)) / 2` で置き換わる。
- 解く順は `distinctInOrder(priority ++ Group#keys)` のうち届いた（Downloaded）鍵。
- `Idle(ms)`: 「このコマで使った ms + 見込み」が ms に収まる間だけ始める。**収まらない鍵が来たらそこで止まる**（後ろの鍵へ進まない）。
- `Idle` で届いた鍵を 2 秒（`estimateResetMs`）1 本も始めず、見込みが `Group#costMs` の 2 倍を超えていたら、見込みを `costMs` へ戻す（解きはしない）。
- `Covered(ms)`: 1 本目は見込みを問わず、あとは ms に満たない間。`Paused`: 解かない。
- 「このコマで使った ms」は、機種が届いた 2D の絵の登録に使った ms（`AssetDownloads#spentMs`）と、前の step（ほかの Group）が使った ms（`StepSpec#spentMs`・`stepAll` が渡す）を含む。

### 1.2 起きた事（Galaxy S24 Ultra・テンプレート）

テンプレートの `Controls.decodeBudget` は、遊んでいる最中は「今要る鍵（`wantedKeys`）が届いていれば `Idle(45)`・ほかは `Idle(4)`」。束（primitive 200 個前後）はスマホで 100〜180 ms。

1. 1 階の束を 1 本解く → 見込みが `(35 + 150) / 2 ≈ 92` へ膨らむ。
2. 次の鍵は 92 > 45 で始まらない。**同じ Group の人物（180 KB）も同じ見込み 92 で見られる**ので始まらない。
3. 2 秒たって見込みが 35 へ戻る → 次の束（並びの頭）が始まり、また 92 へ。人物は束が全部終わるまで並びの後ろで待つ。

原因は 3 つ: (a) 見込みが鍵の重さを見ない、(b) 収まらない頭で止まる、(c) 並びをゲームが手で作り、重さの違いを並びに反映できない。A が (a)、予算の決まり 1 が (b)、B が (c) を受け持つ。

当座の手当て（main に入った）: テンプレートは人物と持ち物を別の Group（`Bundles.modelGroup`・`costMs = 25.0`）に分け、その Group を束の Group より先に `withBackgroundLoad` へ足した（前の step の ms が次の予算から引かれるので、順を逆にすると人物が束の後ろに回る）。Group・見込みの数字・足す順の 3 つを、ゲームが不具合の仕組みを知って手で決めている。

もう 1 つの当座の手当て（9e241ab96）: 人物を分けた後、束の Group には大きい束しか残らず、束を 1 本解くと見込みが Idle(45) を超えて 2 秒戻らない。engine の門は届いたかだけを見るので、上った階で壁と床が無いまま数秒歩けた（スマホと PC で確認）。テンプレートは「描く階の建物の束が届いていれば `Covered(1.0)`」の分岐（`Controls.decodeBudget`）と `Bundles.buildingKeysOf`・テスト `testWaitingBuildingIsStartedRegardlessOfEstimate` を足した。門（`App.Internal.Runner.candidateOf` → `App.Internal.LoadWait.decide`・`hitsOf`）が見るのは `ctx#missing` だけで、`Pending` の Loaded は見ない（`refactor show` で確かめた）。

### 1.3 今のゲームの書き方（`refactor usages` で引いた）

| 使う所 | Group | 優先の並び | 予算 |
|---|---|---|---|
| retro3d-horror-starter（main 9e241ab96）: `src/Bundles.flix` の `schoolGroup`（`costMs` 35）・`modelGroup`（25・WhyNot 6 行）・`groupOf`・`src/Controls.flix` の `loadDocs`（`start` 2 回と `Map.union`）・`withBackgroundLoads`（`withBackgroundLoad` 2 回・どちらも `priority = Resources.read(wantedKeys)`）・`wantedKeys`・`decodeBudget`（9e241ab96 の `Covered(1.0)` の分岐込み）・`Bundles.buildingKeysOf`・`src/Res.flix` の `bundlePending`・`modelPending`・`bundleGroup`・`modelGroup`・`nothingPending`（`Pending` を字で組む）・`withBundlePending`・`withModelPending`・`test/TestBackgroundLoads.flix`（69 行・`pendingOf` が `Pending` を字で組む） | 束 6 と、人物 3＋持ち物 4 の 2 Group | `Controls.wantedKeys`（描く階の束 → 描く階の人物 → 持ち物） | マップ・持ち物の画面は `Covered(40)`・今要る鍵が届いていれば `Idle(45)`・ほかは `Idle(4)` |
| night_school `src/Game.flix:58`・night_school_ps1 `src/Game.flix:52` | テンプレートの分ける前の形（1 Group・`costMs` 35） | 同じ | 同じ |
| haioku `src/GameBoot.flix:24` | 2D の部屋の写真（walks.json の場面） | `Rooms.priorityOf`（今いる場所から歩いて行ける部屋が先・**座標を持たない**） | タップ待ちで次の部屋が届いていれば `Covered(0.0)` |
| blood-scale `game/src/Game.flix:53` `Game.withLairLoading`・bs-speed（同じ形の複製） | 3D の住処 1 本（`lair.glb` 506 KB）・`costMs` 60 | `priority = _ -> Lair3d.keys()`（並びは固定） | タイトルの間は `Idle(80)`（住処 1 本が収まる）。**後の形では初めの値 0.2 ms/KB で見込み 101 ms になり Idle(80) に収まらない。`Listed` なのではみ出しもしない**（9 節で手当て） |

engine の中で `Group` を組むのはテスト 2 ファイル（`engine/test/TestBackgroundLoad.flix`・`engine_world/test/TestAppBackgroundLoad.flix`）だけ。`AssetDownloads` を組むのは `LoadProgress.localDownloads`・`engine_web` の `WebLayer.downloadsOf`・同じテスト 2 ファイルの偽物の 4 か所（テンプレートのテストの偽物は `localDownloads` を `{ … | }` で上書きするので、欄が増えても止まらない）。

## 2. 他のエンジンの呼び方と形

| エンジン | 何をどこで決めるか | ここで採る物 |
|---|---|---|
| **Unreal の World Partition** | 読む物は格子のセル（セルの箱）。ゲームは **streaming source**（既定はプレイヤーのコントローラー）を置くだけで、エンジンが source からの距離と **loading range** でセルを選び、近い順に並べる。1 コマに使う時間は `s.AsyncLoadingTimeLimit`・`s.LevelStreamingActorsUpdateTimeLimit`（ms）で、場面ごとには触らないのが普通。読み終わるまで止めるかは `ShouldBlockOnLoad` | **B の形そのもの**。「見る所」= streaming source（`Order.NearestTo`）・鍵の要る範囲 = セルの箱に loading range を足した物（`Place.Within`）。ただし WP の距離は 2D の格子で、階のある建物には合わない。そこで範囲の箱はゲームが「その鍵が見える所」として渡す（7 節。テンプレートは階と階段室の近く） |
| **Unity の Addressables** | 読む物の単位は **group**（ゲームが手で分ける）。順は読み込みの `AsyncOperation.priority`（`AssetBundle.LoadAssetAsync` などが返す物にゲームが手で付ける）。1 コマの統合の時間は `Application.backgroundLoadingPriority`（Low 2 ms・BelowNormal 4 ms・Normal 10 ms・High 50 ms） | **予算だけ採る**（`DecodeBudget` は今も `backgroundLoadingPriority` に当たる）。group と priority を手で作る形は、今回やめる形そのもの |
| **Godot の ResourceLoader** | `load_threaded_request(path)` で裏の糸に頼み、`load_threaded_get_status` で状態を見る。並びと予算は持たない（糸に任せる） | 状態を見る口（`BackgroundLoad.readiness`）は今もこれに倣う。並び・予算は Godot に無いので引かない |

どれも「1 本の見込み」をゲームに書かせない。Unreal は時間で区切り（始めた仕事は次のコマへ持ち越す）、Unity・Godot は糸で裏に回す。このエンジンの decode は wasm の 1 本の糸で、始めたら途中で切れない（plans/engine-web-glb-worker.md の C 案は見送り）ので、**始める前の見込み**が要る。そこを鍵ごとに学ぶのが A。

## 3. 測った事実（A の単位を決める）

（スパイク: bench/scene3d に テンプレートの glb 13 本の symlink を置き、`make bench-web BENCH=scene3d ARGS='first=glb&keyed=1&warm=1&glb=u_<名前>.glb'` を 3 回ずつ。M4 Pro・Chrome 156 ヘッドレス・WebGPU。`work_max` = その glb を解いたコマの解く仕事の ms）

| 鍵 | バイト（全部） | 絵を除く | 解く ms（3 回） | ms/KB（全部） | ms/KB（絵を除く） |
|---|---|---|---|---|---|
| entrance（起動の束・primitive 107） | 545 KB | 371 KB | 23.0 / 22.8 / 24.3 | 0.042 | 0.062 |
| floor1（起動の束・1 階の建物・primitive 14） | 1,115 KB | 1,039 KB | 46.3 / 46.0 / 45.5 | 0.041 | 0.044 |
| props_1f_a（primitive 194） | 721 KB | 610 KB | 39.0 / 39.7 / 37.3 | 0.054 | 0.064 |
| props_1f_b（primitive 194） | 837 KB | 521 KB | 33.1 / 35.8 / 35.6 | 0.042 | 0.067 |
| upper_a（2・3 階の建物込み・primitive 197） | 2,591 KB | 2,463 KB | 117.8 / 109.7 / 110.4 | 0.043 | 0.045 |
| upper_b（primitive 198） | 960 KB | 550 KB | 36.1 / 36.1 / 36.5 | 0.038 | 0.066 |
| girl_student（骨・アニメ 8） | 178 KB | 167 KB | 18.9 / 19.2 / 19.1 | 0.107 | 0.115 |
| teacher_man（骨・アニメ 7） | 163 KB | 153 KB | 17.3 / 17.6 / 19.7 | 0.108 | 0.115 |
| teacher_woman（骨・アニメ 8） | 175 KB | 164 KB | 18.5 / 18.0 / 18.9 | 0.106 | 0.113 |
| 持ち物 4 本 | 11〜25 KB | 8〜19 KB | 0.8〜1.8 | 0.05〜0.13（64 KB 扱いなら 0.03 以下） | — |

読み取り:
- **束 6 本は「全部のバイト」で 0.038〜0.054 ms/KB**（真ん中 0.044 から ±2 割）。「絵を除く」は 0.044〜0.067 で幅が広い（ブラウザは glb の中の絵を届いた時に `fgePreholdGlbImages` で先に解くが、それでも絵の多い束ほど 1 KB あたりが重く出る）。**単位は全部のバイトにする**。書き出しの `bundle.json` に道ごとの `bytes` がもうあるので、go の書き出しは替えない。
- **骨とアニメの付いた人物は 1 KB あたり 2.4 倍重い**（0.107）。束から学んだ値では人物を 8 ms と見て、実際は 19 ms（M4 Pro）。スマホでは推測: 見込み 30 ms 前後・実際 60〜90 ms。11 節で扱う（見込みが外れても止まりは 1 体 1 回で、人物が待たされることはない）。
- 持ち物（25 KB 以下）は 2 ms 以下で、1 KB あたりはばらつく（0.05〜0.13）。見込みでは重さの下限を 64 KB に置き（大きめに出る＝安全側）、学ぶ時は 64 KB 未満の鍵を入れない（入れると下限の分だけ 1 KB あたりが下へ引かれる）。
- スマホ（S24）の束は 100〜180 ms（人の実測・束 720〜840 KB）なので 0.12〜0.22 ms/KB。PC との差は 3〜5 倍で、学ぶ値はこの差を吸う。初めの値はスマホ寄りの 0.2 ms/KB にする。
- entrance は `warm=1` が読み込みの時に 1 回解いた後の 2 回目だが、1 KB あたりはほかの束と同じ（形の控えに当たって軽くなってはいない）。

- 骨つきの人物が束より 1 KB あたり重いのは JVM でも同じ向き（テンプレートの `Bundles.modelGroup` の WhyNot: JVM で 1 階の束 22〜26 ms・人物 5 ms）。ブラウザの方が差が大きい（束の 1/2・JVM は 1/5）。

## 4. 形（API）

### 4.1 engine（`BackgroundLoad`）

```flix
/// 鍵が要る範囲（Unreal の World Partition のセルの箱と loading range に当たる）。
/// Everywhere = どこでも要る（持ち物・空など。距離はいつも 0 だが「要る鍵」にはならず、はみ出しは使わない）・
/// Within = 箱のどれかの中に「見る所」が入ったら要る（箱の外では一番近い箱までの距離で並ぶ）。
/// 箱は「物がある所」ではなく「その物が見える・要る所」で渡す（階のある建物は、その階と、その階を覗ける階段室の近く）。
pub enum Place with Eq, ToString {
    case Everywhere
    case Within(List[Mesh3d.Bounds])
}

/// 解く順の決め方（毎コマ World から）。
/// NearestTo = 点（プレイヤーの足元・カメラ）から鍵の範囲までの距離で並べる（同じ距離なら keys の順。要る鍵どうしは keys の前ほど大事）・
/// Listed = 並べた鍵の順（座標を持たない場面の並び。並べなかった鍵はその後ろに keys の順。「要る鍵」は無く、はみ出しは使わない）。
pub enum Order with Eq, ToString {
    case NearestTo(Vec3.Vec3)
    case Listed(List[String])
}

pub type alias Group[r: Type, a: Type] = {
    name = String,
    keys = List[String],
    pathsOf = String -> List[String],
    loadRangeOf = String -> Place,          // 足す（costMs の代わり）
    read = String -> r \ Fs.FileRead,
    decode = r -> Result[String, a] \ IO
}

pub type alias Pending = {
    group = String,
    states = Map[String, LoadProgress.LoadState],
    sentPriority = List[String],
    sampleMs = Float64,        // 解いた ms の和（解くたびに古い分へ 0.7 を掛けてから足す）
    sampleKb = Float64,        // 同じ鍵の KB の和（同じく薄める）。見込みの ms/KB = sampleMs / sampleKb
    nextOversizeMs = Float64,  // 次のはみ出しを始めてよい時刻（0 = いつでも）
    idleSinceMs = Float64      // 今もある欄。届いた鍵を Idle で 1 本も始めなかった最初の時刻（負 = 待っていない）。10 秒の知らせに使う
}
```

- `LoadProgress.AssetDownloads` に `sizeOf = String -> Option[Int32] \ IO` を足す（道 1 本のバイト数・分からない道は `None`）。ブラウザは書き出しの `bundle.json` の deferred の各道の `bytes`（今もある）を返す。`localDownloads` は `None`（step が回らないので使わない）。
- `GroupSpec`（`App.withBackgroundLoad` に渡す物）と `StepSpec`（`step` に渡す物）の `priority` を `order = … -> BackgroundLoad.Order` へ。
- `App.withDecodeBudget`・`DecodeBudget` の形は変えない（中身の決まりだけ 4.2）。`stepAll` も替えない（前の step の ms は今も `spentMs` で渡る）。

### 4.2 1 コマの決まり（`BackgroundLoad.Internal.step`）

鍵の重さと見込み:
- `kb(k)` = 鍵の道のうち **まだ Loaded でない**（Downloaded の）道の `sizeOf` の和 / 1024。どれかが `None` なら「分からない」。
- `est(k) = max(64, kb(k)) × sampleMs / sampleKb`。分からない鍵は `est = ∞`（Idle の 1 では始めない。はみ出しと Covered では始まる）。

学ぶ:
- 解いた鍵の kb が分かっていて 64 以上なら、`took' = min(took, max(est×3, 50))`（今の頭打ちと同じ）として `sampleMs = 0.7×sampleMs + took'`・`sampleKb = 0.7×sampleKb + kb`。64 KB 未満の鍵は学ばない。
- 初めの値は `sampleMs = 0.2 × 256`・`sampleKb = 256`（1 KB あたり 0.2 ms。S24 の束の実測から取った遅い機種の値。束を 1 本解けば、その機種の値が 7 割を超える）。
- 学ぶ値は Pending ごと（= Group ごと）。Group を 2 つ残したゲームは、それぞれが一から学ぶ。

並び:
- 届いた（Downloaded）鍵を `(距離, keys の何番目)` の小さい順。距離は `NearestTo(p)` なら p から範囲の箱までの最短（中なら 0・`Everywhere` は 0）、`Listed(ks)` なら ks の何番目（無ければ ks の長さ）。
- 要る鍵 = `NearestTo` で `Within` の箱のどれかに p が入っている鍵。`Everywhere` と `Listed` の鍵は要る鍵にならない。

予算:
- `Paused`: 始めない（今と同じ）。
- `Idle(ms)`:
  1. **収まる物から**: 並びを前から見て、`このコマで使った ms + est(k) ≤ ms` の鍵を始める。収まらない鍵は飛ばして次を見る。
  2. **はみ出し**: 1 で 1 本も始めず、`このコマで使った ms < ms`、かつ `今 ≥ nextOversizeMs` なら、並びの最初の要る鍵を 1 本だけ始める。
  3. **間引き**: 1 でも 2 でも、解いた 1 本が ms を超えたら `nextOversizeMs = max(nextOversizeMs, 終えた時刻 + 9 × かかった ms)`。1 は止めない（小さい鍵はこの間も出る）。
- `Covered(ms)`: 並びの頭は見込みを問わず始め、あとは ms に満たない間続ける（今と同じ。並びだけ新しい物）。
- 「このコマで使った ms」は今と同じ（機種の絵の登録 + 前の step + この step）。前の step（別の Group）が予算を使い切ったコマでは、2 のはみ出しは起きない。
- 知らせ: はみ出しの無い鍵（`Order.NearestTo` の Group で範囲が `Everywhere` の鍵と、`Order.Listed` の Group の全部の鍵）が、届いた後 Idle の予算で 10 秒 1 本も始まらなかったら、`Log.warn` で 1 回だけ「`<group>` の `<鍵>` は届いて 10 秒、Idle で始まらない（見込み N ms・予算 M ms）。遊んでいる最中に要るなら `loadRangeOf` で `Within` を返すか、暗転・メニューで `Covered` を返す」。`Within` の鍵は範囲の外で待つのが正しいので知らせない（テンプレートの 1 階で upper_a・upper_b が待つのは意図した待ち）。`idleSinceMs` は今の「負 = 待っていない」のまま使い、「知らせた」は `-2.0` で持つ（`nextIdleSince` は -2 を上書きしないので 2 度出ない）。
- 頼み直し（ダウンロードの行列の頭へ）: まだ届いていない鍵を同じ並び（距離と keys の順）で作り、最後に頼んだ並び（`sentPriority`）と違う時だけ頼む。
- **門**: `App.withLoadGate` が返した名前（道）のうち、まだ Loaded でない鍵が持つ道を「門の道」として `StepSpec#gated` で渡す（`stepAll` がこのコマの World から 1 回作る）。門の道を持つ鍵は、予算（`Paused` も含む）と間引きを問わず、1 コマに 1 本だけ並びの頭より先に始める。門の側（`App.Internal.LoadWait.hitsOf`）は、missing に加えて「どれかの Group の Pending で Loaded でない鍵が持つ道」も待つ名前に数える。門が止めている間は前の場面のまま World を出さないので、ここでの止まりは画面に動きとして見えない。

WhyNot（決まりに書く）:
- 見込みを鍵ごとに覚えない — 鍵は 1 回しか解かないので、鍵ごとに覚えても次に使う所が無い。学ぶのは機種の速さ（1 KB あたり）だけ。
- 範囲の内を軽い順に並べない — 軽い物は 1 の「収まる物から」で並びを問わず先に出る。並びが効くのは重い物どうしのはみ出しの順で、そこは軽さより大事さ（テンプレートでは 2 階の建物の入った upper_a が、小物だけの upper_b より先）。大事さはゲームが `keys` の順で言う。
- 距離を高さで重くしない — 真上の階の箱は、1 階に立つと高さの差（約 3 m）だけで「近い」に入る。範囲の箱はもう「見える所」（階と階段室の近く）なので、箱の外の距離が効くのは頼む順と、要る鍵でない物の収まる順だけ。テンプレートでは 1 階の鍵はみな距離 0 で、2 階の鍵がその次に来るのは意図どおり。
- 門の鍵を予算に従わせない — 門はもう World を止めていて、止まりは画面に動きとして出ない。予算に従わせると、門は「解けるまで」待つので、待ちが見込みの戻りの分だけ延びる（9e241ab96 が塞いだ形）。
- はみ出しの間を時間で決めない（2 秒など）— 止まりの長さは機種で 5 倍違う。止まった長さの 9 倍を空ければ、どの機種でもはみ出しの止まりは時間の 1 割に収まる。
- 間引きで 1 の収まる物を止めない — 止めると、見込みより重かった人物 1 体の後に、ほかの人物と持ち物が 9 倍の間だけ待つ（起きた事の形に戻る）。1 の止まりは「予算 × 見込みの外れ」までで、外れは学ぶ値が 1〜2 本で詰める。
- `Everywhere` ではみ出さない — 範囲を書かないゲーム（今の書き方から移っただけのゲーム・既定の `Idle(4)`）で、遊んでいる最中に重い部屋を解き始めない（今の `testDefaultIdleNeverDecodesAHeavyRoom` を保つ）。
- 分からない大きさを 0 にしない — 0 → 64 KB 扱いだと、学んだ後は 1〜3 ms と見られ、`Idle(4)` にも収まって重い鍵を始めうる。
- Loaded の道を重さに足さない — 機種が届いた時に解いた絵（haioku の部屋の jpg など）は decode でほとんど時間を食わず、足すと見込みが何倍にもふくれる。

### 4.3 engine が決める事・ゲームに残す事

| 決める物 | 今 | 後 |
|---|---|---|
| Group の分け方 | ゲーム（重さの違う物を別 Group にし、足す順まで気にする） | **要らない**（1 Group で重さの違う鍵が混ざってよい） |
| 1 本の見込み | ゲーム（`costMs`・遅い機種の値を手で） | **engine**（バイト数 × 学んだ ms/KB） |
| 優先の並び | ゲーム（`priority` の並びを手で） | **engine**（範囲と見る所から）。ゲームは範囲と見る所を渡す |
| 場面ごとの予算 | ゲーム | **ゲームのまま**（止まってよい長さは遊びの判断）。ただし「今要る鍵が届いているか」で予算を替える分岐は要らなくなる |

## 5. 場面の表（retro3d-horror-starter・後の形）

前提: 予算は 7 節の後の形（マップ・持ち物の画面は `Covered(40)`・ほかは `Idle(45)`）。鍵の順（keys）は 束（floor1・entrance・props_1f_a・props_1f_b・upper_a・upper_b）→ 人物（girl・teacher_man・teacher_woman）→ 持ち物 4。
起動の素材は floor1 と entrance（`web.deferred` に無い）。人物は 3 人とも 1 階で、範囲は束と同じ「1 階を描く所」なので、1 階にいる間は 3 人とも要る鍵。
数字は 4.2 の決まりを写した模擬（`sim_background_load.py`）で出した。実際の ms は PC が 3 節の実測、スマホは推測（束 0.18 ms/KB = 人の実測 100〜180 ms から・人物は PC の 4 倍・upper_a は 466 ms）。コマは 16.7 ms と止まった分。

| 場面 | 要る鍵 | PC（M4 Pro） | スマホ（S24・推測） | 順と予算の食い違い |
|---|---|---|---|---|
| **押した直後・昇降口に立つ**（1 階） | props_1f_a・props_1f_b・人物 3（1 階を描く所） | 0 ms: girl・teacher_man（見込み 36・25）。39 ms: teacher_woman と持ち物 4。束は初めの値では見込み 144 で始めない。65 ms: props_1f_a をはみ出しで（39 ms）。105 ms: props_1f_b（はみ出し・35 ms）。**0.1 秒で全部・止まりは 1 コマ 40 ms 前後まで** | 0 ms: girl（見込み 36・実際 76）。78 ms: 持ち物 4。0.77 秒: props_1f_a（はみ出し・130 ms）。0.90 秒: teacher_man（実際 70）。0.98 秒: teacher_woman（見込み 45・実際 74）。2.07 秒: props_1f_b（はみ出し・151 ms）。**止まり 70〜150 ms が 5 回・人物は 1 秒以内に 3 人・2.1 秒で全部** | **無い**。人物は束の後ろで待たない（今は束が全部済むまで待つ）。小物の束 2 本は 2.1 秒以内に出る |
| **1 階の廊下を奥へ歩く** | 1 階の束と人物（済み） | 届いていれば上と同じ。4G でまだ届いていない鍵は、近い順に頼み直す（今の並びは「描く階の束 → 人物」の固定） | 同じ | 無い |
| **1 階の階段室の 4 m 内**（2 階の範囲に入る） | upper_a・upper_b | upper_a（建物入り・keys が前）をはみ出しで 113 ms → 1 秒空けて upper_b（見込み 51・はみ出し 36 ms）。今も Idle(45)・見込み 35 で upper_a を始めるので、止まりの長さは今と同じ | upper_a 466 ms → 4.2 秒空けて upper_b 173 ms。直前の props_1f_b のはみ出しの間（最大 1.36 秒）が残っていても、upper_a は 4 m 内に入ってから 1.9 秒以内に済む | 建物: 4 m 内から 2 階の床まで約 10 m（ramp 2 本と踊り場）で、走って 4.2 秒（`walk.kind.json` の dashSpeed 2.4）なので、**建物は着く前に解ける**。**残る穴**: スマホで走って上ると、upper_b の小物が着いてから 2 秒前後遅れて出る（今も見込みの戻し 2 秒ごとで同じくらい。11 節） |
| **2 階の床へ着いた時に upper_a がまだ解けていない**（4G で届くのが遅れた時など） | upper_a | 門が前の場面のまま止め、upper_a を予算を問わずすぐ始める（113 ms） | 門が止まる長さは upper_a の 466 ms 前後（推測）。止まっている間は World を出さないので、壁の無い 2 階は見えない | 無い（今は届いた時点で門が開き、壁と床の無い 2 階を歩けた） |
| **2 階を歩く** | upper_a・upper_b・props_1f_a・props_1f_b（2 階と共通の小物が入っている） | 済み | 済み（階段で間に合わなければ、はみ出しの間の後に） | 無い |
| **紙のマップ・持ち物の画面を開いた間**（`Covered(40)`） | （予算が Covered なので見ない） | 届いた鍵を近い順に、1 本目は見込みを問わず・あとは 40 ms に満たない間。遠い階の束もここで済む | 1 コマに 1 本（130〜470 ms のコマが、幕の下で続く）。今と同じ | 無い |
| **暗転**（ゲームが暗転の間 `Covered` を返す形。テンプレートには暗転が無く、haioku・novel 系が使う） | 同上 | 同上 | 同上 | 無い。haioku は `Order.Listed` のまま、今の `Covered(0.0)` の差し込みで次の部屋を 1 本 |

「人物だけ出て小物が出ない」・「小物だけ出て人物が出ない」の両方が起きないことの決まり:
- 要る鍵は、届いた後、前のはみ出しの止まりの合計 × 9 の時間の内に必ず始まる（収まらなくても、はみ出しで始まる）。
- 要る鍵でない鍵は、収まる物として出るか、範囲に入るか、マップ（Covered）まで待つ。待つのは「重くて、今は見えない物」だけで、待ちが 10 秒続けば engine が 1 行知らせる。
- 見込みより重かった 1 本は次のはみ出しを遅らせるが、収まる物（人物・持ち物）は止めない。

## 6. 決定性

- step を回すのはブラウザの実機のふつうのコマだけ（F8 の停止・リモートのコマ・`App.traceFrame`・描き出し・flow・画面なしの `HeadlessLoad`・デスクトップは回さない。今と同じ）。デスクトップと画面なしは `localDownloads` で `start` が全部を読み、表は全部 Loaded なので、新しい欄（`sampleMs`・`sampleKb`・`nextOversizeMs`）は `start` が書いた初めの値のまま変わらない。`make determinism`（台本の記録と画面なしの再生の World の比べ）と World の要約は動かない。
- `Pending` に関数を持たせない決まり（World の要約が反射で resources まで辿る）は保つ。`Place` と `Order` は値（箱と点と文字の並び）で、`Pending` には入れない（`Group` と `GroupSpec` にだけ入る）。
- 並びは `(距離, keys の何番目)` で必ず 1 つに決まる（Map の回る順に頼らない）。`TestBackgroundLoad` に「同じ距離は keys の順」のテストを 1 本。
- ブラウザでどのコマに何を解くかは、今も届く速さと時計（`nowMs`）で変わる。ここは決定性の門の外のまま（今と同じ）。知らせの `Log.warn` もブラウザの step の中だけ。
- 門の「解けた」まで待つ分も、デスクトップと画面なしは表が全部 Loaded で、解けていない門の道は空のまま。門の答えは今と同じ（missing だけ）で、`make determinism` は動かない。
- `Stored#replay`（押した所の控えへ store を当て直す関数）は、step が作った新しい `Pending`（見込みの欄も入った値）と結果をそのまま当てる。時計を読み直さないので、当て直しで見込みの値は揺れない。

## 7. ゲームが書く行（retro3d-horror-starter・main 9e241ab96 から）

推す形: Group を 1 つに戻し、手で決めていた分（Group 分け・costMs・足す順の WhyNot・wantedKeys・予算の分岐）を全部消す。

| ファイル | 今 | 後 | 足す | 消す |
|---|---|---|---|---|
| `src/Bundles.flix` | `schoolGroup`（doc＋2 行）・`modelGroup`（WhyNot 6 行・doc＋2 行）・`groupOf` の頭と `costMs = costMs`・`buildingKeysOf`（doc＋2 行） | `group(layout, cast, bundles, items, loader)` 1 つ（doc＋keys の 1 行）・`groupOf` の `loadRangeOf = key -> rangeOf(layout, cast, bundles, key)`・新しい `rangeOf`（人物の鍵は `Within(School.boundsSeeing(layout, その人物の階))`（今の `wantedKeys` の「描く階にいる人物」と同じ意味）・持ち物は `Everywhere`・束は `Within(entry#floors \|> List.flatMap(School.boundsSeeing(layout)))`。doc＋5 行） | 10 | 18 |
| `src/School.flix` | `visibleFloors` の本文 4 行（`stairReach` の内か） | 新しい `boundsSeeing(layout, floor)`（その階の床の箱と、その階につながる階段室を `stairReach` 広げた箱。doc＋6 行）・`visibleFloors` を「`boundsSeeing` の箱が足元を含む階」に組み直す（2 行）。決まりは `boundsSeeing` の 1 か所 | 9 | 4 |
| `src/Controls.flix` `loadDocs` | Group 2 つと `start` 2 回と `Map.union`（5 行） | Group 1 つと `start` 1 回（2 行） | 2 | 5 |
| `src/Controls.flix` `withBackgroundLoads` | `withBackgroundLoad` 2 回（`priority` 2 か所）・足す順の WhyNot 2 行・doc 2 行（14 行） | 1 回・`order = Resources.read((_, w) -> BackgroundLoad.Order.NearestTo(World.feetOf(w)))`（7 行） | 7 | 14 |
| `src/Controls.flix` `wantedKeys` | doc＋7 行 | 消す | 0 | 8 |
| `src/Controls.flix` `decodeBudget` | doc 3・WhyNot 4・本文 7（`downloaded`・`buildingKeys` の let・建物の `Covered(1.0)` と wanted の分岐） | doc 1・WhyNot 1・`if (World.isMapOpen(w) or World.isItemsOpen(w)) Covered(40.0) else Idle(45.0)` | 4 | 14 |
| `src/Res.flix` | `bundlePending`・`modelPending`・`bundleGroup`・`modelGroup` の欄（型 3 か所・doc 2 行・build 1 行）・`nothingPending`（`Pending` を字で）・`withBundlePending`・`withModelPending` | `pending`・`group` の欄・`nothingPending` を新しい欄で・`withPending` 1 つ | 9 | 11 |
| `test/TestBackgroundLoads.flix` | `pendingOf` が `costMs`・`idleSinceMs` を組む・Group 2 つ・`testPersonIsDecodedWhileBundleEstimateIsHigh`・`testWaitingPersonRaisesTheBudget`・`testWaitingBuildingIsStartedRegardlessOfEstimate`・`buildingBundles()`（decodeBudget の分岐を見る） | `pendingOf` を新しい欄で・Group 1 つ・偽の downloads に `sizeOf`・「人物は、収まらない束の後ろでもそのコマで解かれる」に書き替え・`testWaitingPersonRaisesTheBudget` と建物のテスト 2 つは消す（分岐が無い。建物は engine の門のテストが見る） | 10 | 33 |
| `src/Game.flix` | `Controls.withBackgroundLoads(docs)` | そのまま | 0 | 0 |

計 **足す 51・消す 107（正味 −56）**。うち src は足す 41・消す 77。新しく考えて書く物は `rangeOf` と `boundsSeeing` の 2 つ（13 行）で、残りは消すか置き替え。`tools/glb_bundle.py` と `bundles.json` は替えない。`Controls.loadGate`（建物の束の道を返す）はそのまま使う（engine が「解けた」まで待つ）。

- WhyNot（束の範囲を tools/glb_bundle.py が bundles.json に書かない）: 「その階を描く所」は School の決まり（階段室から `stairReach` = 4 m）で、Python にも書くと 2 か所になる。範囲は物の置き場所ではなく「見える所」なので、見える所を決めている School から出し、`visibleFloors` もその上に組み直して決まりを 1 か所にする。人の考え（bundles.json に範囲）とずれるので 13 節で伺う。
- WhyNot（人物の範囲を「足元から何 m」にしない）: 廊下では遠くの人物も見えるので、m で切ると遅い機種で「見えているのに出ない」が残る（今の `wantedKeys` は「描く階にいる人物」を要る鍵にしている）。人物も束と同じ `boundsSeeing` で、決まりは 1 か所のまま。
- 持ち物の glb（12〜26 KB）は `Everywhere`: 見込みは 64 KB 扱いで PC 3 ms・スマホ 13 ms 前後。束の後ろで待たない。

haioku（座標を持たない 2D の部屋）は `priority = h -> Rooms.priorityOf(…)` を `order = h -> BackgroundLoad.Order.Listed(Rooms.priorityOf(…))`・Group に `loadRangeOf = _ -> BackgroundLoad.Place.Everywhere` の 2 行。予算（`Covered(0.0)` の差し込み）はそのまま。night_school・night_school_ps1 はテンプレートの分ける前の形なので、上の表から Group を戻す行（Res・loadDocs の 2 回）を除いた分。

### 7.1 比べた別案: 要る鍵をゲームが字の並びで渡す（B を採らない形）

`GroupSpec` に `wanted = w -> List[String]`（要る鍵の集まり）を置き、engine は A と予算の決まり 2 つだけを持つ形。

| | B（この計画） | 別案 W |
|---|---|---|
| 新しい pub | 2（`Place`・`Order`） | 0 |
| テンプレートが新しく書く物 | `rangeOf`・`boundsSeeing`（13 行）。`wantedKeys` を消す | `wantedKeys` を残す（8 行）。`rangeOf`・`boundsSeeing` は要らない |
| テンプレートの 5 節の場面 | — | **同じ時刻で解ける**（人物も束も「その階を描く所」で、要る鍵の集まりが `wantedKeys` と同じ） |
| まだ届いていない鍵を頼む順 | 範囲までの距離（近い階・近い人物が先） | 要る鍵 → keys の順 |
| 階の無い場面（洞窟・町・sea_cave_walk・stack_town のような広い所） | 物の箱を `Within` で渡すだけ。近い順は engine | ゲームが足元から距離を測って要る鍵を作る（今の priority を手で作るのと同じ） |
| 人の了承（11-26）との合い方 | 「engine が距離で並べ直す・ゲームが priority を手で作らない」に合う | 合わない（要る鍵の並びを手で作る） |

B を採る。W との差は 2 つだけ: **まだ届いていない鍵を頼む順**（B は範囲までの距離・W は要る鍵 → keys の順）と、**階の無い広い場面**（B は箱を渡すだけ・W はゲームが距離を測って要る鍵を作る）。テンプレートだけなら W の方が pub が 2 つ少なく、時刻も同じ。W の方が良いと人が判断すれば、4.2 の「要る鍵」を `wanted` に替えるだけで、A と予算の決まりと門はそのまま使える（13 節）。

## 8. 段と見積もり

直近の実績: plans/engine-web-glb-worker.md の段 2（pub の口を 1 組にして engine のテスト 45 か所と bench を移す）が 5〜6 時間の見込みで 1 日のうちに済んだ・web-loading-p4 の App の口の足し（3 つの builder と Rec の欄）が 2〜3 時間・この計画の段 0（bench の 39 回と模擬）が 1 時間。

| 段 | 中身 | 緑とする測り | 大きさ |
|---|---|---|---|
| **0. 単位の確かめと模擬**（済み） | 3 節の 13 本の測り・5 節の模擬 | 単位（全部のバイト）で束の 1 KB あたりが ±2 割に収まる | 済み（1 時間） |
| **1. engine の中身** | 4.1 の型と 4.2 の決まり（`Internal.step`・`decodeWithin`・並び・学ぶ・はみ出し・間引き・10 秒の知らせ）・`estimateResetMs` を消す・`StepSpec`・`GroupSpec` の `order`・`localDownloads` に `sizeOf`。門の「解けた」まで待つ分（`stepAll` が門の道を作る・`LoadWait.Context` と `hitsOf`・step の関数の型）。今のテスト 9 本の書き替えと新しいテスト 12 本（12 節）。`App.flix` は 1,221 行で max-lines の例外ちょうどなので、`withBackgroundLoad` の doc は行数を増やさず書き替える | `make test-engine`・`make sync-layers` の後 `.layers/engine_world` で `flix test`（TestAppBackgroundLoad） | 6〜7 時間 |
| **2. ブラウザの sizeOf** | `engine_web/java/fge/web/Deferred.java` に `sizeOf(path)`（分からなければ -1 を返し、Flix の側で `None`）・`fge-web.js` が deferred の表の `bytes` を返す・`WebLayer.downloadsOf` に 1 行 | テンプレートのブラウザ版で 4G（`?fge=4g`）の起動 → 押す → 1 階を奥へ歩く を 3 回。人物が届いてから 1 秒以内に出る・束を解いたコマが 1 コマに 1 本（`?fge=fps`） | 1 時間 |
| **3. 型 → lint → docs** | `docs/startup.md` の「ループの中で区切って読む」を書き替え（予算の節の 167〜176 行・コード例 152〜162 行の `priority` を `order` へ・`costMs` の目安の字を消す）・`make api-digest`・`go/exportweb_deferred.go` の知らせの「costMs の目安」の字を「予算の節」へ（356・371 行・`fge-go` を作り直す）・`docs/migrations/0.115.0.md` の節（9 節）・forbid 2 行・`agents-pack/AGENTS.core.md` の早見表の 162 行目を差し替え・`agents-pack/agent-eval/engine.json` にお題 1 本・`make check-docs-sync` | ゲームの足元で `make agent-eval ONLY=background-load-nearest-first` が当たる | 1.5 時間 |
| **4. テンプレート** | 7 節の表 | `make check`・`make test`（TestBackgroundLoads と visibleFloors の今のテストが通る）・web-capture の絵が 0 px（出たら入れる前に止めて人へ）・段 2 の手を S24 で人に 1 回（人物が束の後ろで待たない） | 3 時間 |
| **5. 手元のゲーム** | night_school・night_school_ps1（テンプレートと同じ置き替え）・haioku（7 節の 2 行）・blood-scale/game と bs-speed（9 節: `order = _ -> Order.Listed(Lair3d.keys())`・`loadRangeOf = _ -> Everywhere`・`costMs` を消す・タイトルの予算を `Covered(0.0)` へ）。リリースと engine-upgrade の後 | 各ゲームの `make check` と、ブラウザ版で 1 回歩く（blood-scale はタイトルの間に住処が解けて、押した後に待たない） | 2 時間 |

engine の段（1〜3）で **8〜10 時間**（門の分で +1〜2 時間）。リリースは `/release` の手順で別に（今回の計画には入れない）。

## 9. 移行（今のゲームの書き方が止まる所）と移行メモ

止まる所（コンパイルで止まる。順に直せば通る）:

| 前 | 後 | 止まり方 |
|---|---|---|
| `Group` の `costMs = 35.0` | 消す。`loadRangeOf = key -> …` を足す。**遊んでいる最中に重い鍵を解くゲームは `Within`**（人物はその人物が見える所の箱）。暗転・メニューの `Covered` でだけ解くゲームと、座標の無い場面は `_ -> BackgroundLoad.Place.Everywhere` | record の欄が合わない（forbid が先に代わりを出す） |
| `withBackgroundLoad({ …, priority = h -> 鍵の並び })` | 3D は `order = h -> BackgroundLoad.Order.NearestTo(足元)`・座標の無い場面は `order = h -> BackgroundLoad.Order.Listed(鍵の並び)` | record の欄が合わない |
| `Pending` を字で組んでいる（`costMs = …, idleSinceMs = …`） | `sampleMs = 51.2, sampleKb = 256.0, nextOversizeMs = 0.0, idleSinceMs = -1.0`（engine の初めの値。0 にすると見込みが全部 0 になり Idle で全部を始める）。鍵のある表をテストで手で組まず、`BackgroundLoad.start` を通して作る | record の欄が合わない |
| テストの偽の `AssetDownloads` を字で全部組んでいる | `sizeOf = _ -> checked_ecast(None)` を足す（`localDownloads()` を `{ … \| }` で上書きしている偽物は止まらない） | record の欄が合わない |
| 重さの違う鍵を別 Group に分けていた・足す順を気にしていた | 1 Group に戻してよい（見込みは鍵ごと）。分けたままでも動くが、学ぶ値は Group ごとに一から | 止まらない |
| 予算で「今要る鍵が届いていれば Idle(45)・ほかは Idle(4)」と分けていた | **範囲（`Within`）を書いたゲームだけ**、遊んでいる最中を 1 つの `Idle(ms)` にしてよい（要る鍵は engine がはみ出しで始める）。範囲を書かずに `Everywhere` だけのゲームは、重い鍵が Idle では始まらないので、暗転・メニューで `Covered` を返す形を残す | 止まらない（10 秒の知らせが出る） |
| `Order.Listed` の Group の鍵を、タイトルなどの `Idle(ms)` に収まる見込みで解いていた（blood-scale・bs-speed: `costMs` 60・`Idle(80)`・`lair.glb` 506 KB） | 推す: (a) タイトルの間を `Covered(0.0)`（1 本目だけ見込みを問わず始める）に替える。初めの値 0.2 ms/KB だと見込みは 101 ms で `Idle(80)` に収まらず、`Listed` ははみ出さないので、替えないと押すまで解けない。(c) engine は 10 秒の知らせを `Listed` の Group の鍵にも出す（4.2）ので、替え忘れはコンソールの 1 行で分かる | 止まらない（10 秒の知らせが出る） |
| 門（`withLoadGate`）の鍵を、予算の分岐で先に解いていた（テンプレートの 9e241ab96 の `Covered(1.0)`・`buildingKeysOf`） | 消してよい。engine が門の鍵を「解けた」まで待ち、予算を問わず始める | 止まらない |

`docs/migrations/0.115.0.md`（版は出す時の番号）に上の表と、テンプレートから作ったゲームの置き替え（7 節の表の前と後）を載せる。

forbid の 2 行（`bin/lint-rules/forbid.json`）:

```json
{ "id": "background-load-cost-ms", "suffixes": [".flix"], "prefixes": ["src/", "templates/"],
  "skip": ["src/engine/", "src/engine_world/", "src/engine_tools/", "src/render_gl/"], "skipDirs": ["build", "lib"],
  "whenProject": "BackgroundLoad\\.", "pattern": "\\bcostMs\\s*=|\\bpriority\\s*=\\s*(Resources\\.read|\\w+\\s*->)",
  "hint": "BackgroundLoad.Group の costMs と withBackgroundLoad の priority は無くなった: 見込みは engine が鍵のバイト数から出し、順は engine が範囲から並べる。Group に loadRangeOf = key -> BackgroundLoad.Place.Within(箱)（人物もその人物が見える所の箱。暗転とメニューでだけ解くなら Everywhere）・withBackgroundLoad に order = h -> BackgroundLoad.Order.NearestTo(足元)（座標の無い場面は Order.Listed(鍵の並び)）。重さの違う鍵を Group に分けなくてよい（engine の docs/migrations/0.115.0.md）" },
{ "id": "background-load-nearest-without-range", "suffixes": [".flix"], "prefixes": ["src/", "templates/"],
  "skip": ["src/engine/", "src/engine_world/", "src/engine_tools/", "src/render_gl/"], "skipDirs": ["build", "lib"],
  "whenProject": "Order\\.NearestTo", "notice": true, "pattern": "\\bloadRangeOf\\s*=\\s*_\\s*->\\s*(BackgroundLoad\\.)?(Place\\.)?Everywhere\\b",
  "hint": "Order.NearestTo で並べるのに、鍵の範囲が全部 Everywhere: 近い順にならず、重い鍵は Idle では始まらない（はみ出しは Within の範囲の内の鍵だけ）。束と人物は見える所の箱を Within で返す（engine の docs/startup.md の予算の節）" }
```

agents-pack の早見表（`AGENTS.core.md` の 162 行目を差し替え）:

| ブラウザ版で後回しにした 3D の部屋・束・人物を、近い物から区切って読む | `BackgroundLoad.start` + `App.withBackgroundLoad`（Group に `loadRangeOf`・`order = Order.NearestTo(足元)`・見込みと順は engine）+ 予算 `App.withDecodeBudget`（範囲を書けば遊んでいる最中は 1 つの `Idle(ms)`・暗転とメニューは `Covered`・engine の `docs/startup.md`） |

agent-eval のお題（`agents-pack/agent-eval/engine.json`）:

```json
{ "id": "background-load-nearest-first",
  "prompt": "ブラウザ版の 3D ゲームで、後から届く校舎の glb の束（1 本 600 KB）と人物の glb（1 体 180 KB）を BackgroundLoad で解いている。スマホで人物が束の後ろで何秒も待つ。プレイヤーの近くの物から、軽い人物を先に出したい。Group と App.withBackgroundLoad に何を書く？",
  "expect": [
    { "re": "loadRangeOf", "why": "鍵ごとの要る範囲を Group の loadRangeOf で渡す" },
    { "re": "Order\\.NearestTo", "why": "順は withBackgroundLoad の order = Order.NearestTo(足元) で engine が並べる" },
    { "re": "Place\\.Within", "why": "束も人物も、見える所の箱を Within で渡す" } ],
  "avoid": [
    { "re": "costMs\\s*=", "why": "見込みは engine が鍵のバイト数から出す（costMs は無くなった）" },
    { "re": "priority\\s*=\\s*(\\w+\\s*->|Resources)", "why": "手で並べた priority は無くなった（座標の無い場面だけ Order.Listed）" } ] }
```

## 10. やらない事

- **C 案（暗転やメニューで engine が自分で Covered にする）**: やらない。engine が「画面が隠れている」を知る所が無い（暗転はゲームの View・engine_world の Transition・メニューの幕と、ゲームごとに違う）。知るには `Transition` を使っていることを前提にするか、新しい口が要る。今回の後、テンプレートの予算は 2 行で、ゲームが書く量の問題は残らない。 ただし門（`withLoadGate`）は engine がもう受け取っている合図なので、「門が止めている間は予算を問わず解く」はこの計画に入れた（4.2）。
- **既定の予算（`Idle(4)`）を替える**: やらない。範囲を書かないゲームは今と同じく重い鍵を遊んでいる最中に解かない（4.2 の WhyNot）。
- **1 つの glb を数コマに分けて解く**（plans/engine-web-glb-worker.md の C 案）: やらない。はみ出しの止まりは残る（スマホで束 1 本 100〜470 ms を、時間の 1 割まで）。
- **カメラを engine が描いた Scene3d から拾う**（ゲームが `order` を書かない形）: やらない。前のコマの描く物に step が頼ることになり（step は描く前に回る）、Scene3d を複数描く画面・2D の画面・マップの上の 3D で、どのカメラか決められない。ゲームの 1 行（`order`）の方が読めて試せる。
- **範囲を毎コマ World から作る**（`loadRangeOf` に World を渡す）: やらない。範囲は読み込みの頭で作った Group に閉じる。動き回る人物の範囲は置き場所の初めの値のまま、layout.json・characters.kind.json の保存即反映（F1・watchFile）でも範囲は古いまま。テンプレートの人物は動かず、人物の glb は保存即反映でも読み直さない（今の `reloadCast` の WhyNot）ので困らない。歩き回る人物が多いゲームは `Everywhere`（軽いので収まる物として出る）。
- **ダウンロードの行列の順を近い順に毎コマ組み直す**: 並びが変わった時だけ頼む（今の `sentPriority` の決まりのまま）。歩くたびに人物の順が入れ替わると頼み直しが増えるが、JS の行列の並べ替えだけで軽い（推測）。重ければ「頭の 4 本が替わった時だけ」に絞る（段 2 の測りで見る）。

## 11. 危険と控え

- **バイト数が解く重さに比べ合わない鍵**（3 節の人物: 2.4 倍）: 人物は見込みより重く、スマホで 1 体 70 ms 前後止まる（推測・5 節の模擬で 2 回）。止まるのは 1 体 1 回で、待たされることはない。学ぶ値は KB で重みを付けた和なので、人物 1 体で束から学んだ値が動くのは 1〜2 割。人物が多いゲーム（10 体以上）で止まりが目立ったら、glb の骨とアニメの数を重さに足す（書き出しと JS の 1 か所・engine の型は変えない）。今回は入れない。
- **階段で upper_b が遅れる**: スマホで upper_a（466 ms）の後は 4.2 秒空く。走って上ると upper_b の小物が着いてから 2 秒前後遅れて出る（建物は間に合う・5 節）。今の 2 秒の戻しと比べて悪くはならないが、良くもならない。upper_b は小物だけで門の道に入らないので、門の手当て（4.2）では塞がらない。塞ぐなら `Controls.loadGate` に upper_b の道も足す（その時は着いた所で 173 ms 前後止まる）。
- **upper_a が 2.6 MB**: primitive は 197 で `export-web` の 200 個の知らせに掛からないが、2・3 階の建物の頂点で重い。束の知らせを「primitive の数かバイト数（1.5 MB）」にするのは別の小さな直し（書き出しの go の 1 か所）。テンプレートの束の分け方はこの計画では替えない。
- **学ぶ値が 1 回の止まり（GC・初めての JIT）で上がる**: 頭打ちで最大 3 倍まで、次の 1〜2 本で戻る。上がっている間も小さい鍵（人物・持ち物）はまだ収まり、要る鍵ははみ出しで始まって測り直される。要る鍵でない重い鍵はマップか暗転（Covered）まで待つ（今の `Idle(4)` と同じ）。

## 12. テスト（engine/test/TestBackgroundLoad・engine_world/test/TestAppBackgroundLoad）

書き替える（今の決まりを見ている物）: `testIdleResetsAnInflatedEstimateWithoutDecoding`（消す）・`testIdleUpdatesTheEstimateForTheNextFrame`・`testOneSlowDecodeIsCappedInTheEstimate`・`testIdleDoesNotStartAKeyOverTheBudget`・`testIdleDecodesWhileTheEstimateFits`・`testDecodesInPriorityOrder`・`testDuplicatedPriorityDecodesOnce`・`testPriorityIsSentOnlyWhenItChanges`・`testPriorityRequestsAFailedKeyAgain`（`Listed` で書き替え）。`testDefaultIdleNeverDecodesAHeavyRoom` は `Everywhere` で同じ意図のまま残す。

足す（1 テスト 1 つの事）:
- 小さい鍵が、収まらない大きい鍵の後ろでも Idle で始まる（起きた事そのもの）
- 見込みはバイト数に比例する（同じ学んだ値で 2 倍の鍵は 2 倍）・Loaded の道のバイトは数えない
- 大きさの分からない鍵は Idle の収まる物として始まらない
- 解いた ms と KB が次の見込みに 7 割入る・1 回の値は 3 倍で頭打ち・64 KB 未満の鍵は学ばない
- 範囲までの距離が近い順・同じ距離なら keys の順（Map の回る順に頼らない）
- 範囲の内の重い鍵は、このコマに予算が残っていれば 1 本だけ始まる・要る鍵どうしは keys の順
- 予算を超えた 1 本の後は、止まりの 9 倍の時間を空けるまで次のはみ出しを始めない
- 長い間は、後の短い止まりで縮まない（`nextOversizeMs` は大きい方）
- 間を空けている間も、収まる鍵は始まる
- `Everywhere` と `Listed` の鍵ははみ出さない（既定の `Idle(4)` で重い鍵を始めない）
- 前の step（別の Group）がこのコマの予算を使い切っていたら、はみ出さない（TestAppBackgroundLoad）
- まだ届いていない鍵は近い順で頼み、並びが同じなら頼み直さない
- Idle で 10 秒始まらない鍵は 1 回だけ知らせる（2 度出さない）
- `Listed` の Group の鍵が Idle で 10 秒始まらなければ知らせる（blood-scale の形）
- 門の道を持つ鍵が解けていない間は、門が World を出さない（TestAppBackgroundLoad・届いて Downloaded のままでも止まる）
- 門の鍵は、見込みと間引きと予算（`Paused` も）を問わず 1 コマに 1 本始まる
- `Covered` の 1 本目（見込みを問わず始める鍵）は新しい並び（距離と keys の順）の頭で決まる
- 学ぶ時の 1 回の値は「見込みの 3 倍か 50 ms の大きい方」で頭打ちになる（初めの値のままの小さい見込みでも 50 ms までは入る）

## 13. 人に決めてほしい事（推す答えつき）

1. **B（範囲と見る所）か、別案 W（要る鍵をゲームが字で渡す）か** — 推す: B（11-26 の了承どおり）。テンプレートだけなら W の方が pub が 3 つ少なく時刻も同じ（7.1）。B の得は階の無い広い場面と、4G で近い物から頼む所。
2. **束の範囲をどこで作るか** — 推す: テンプレートの `School.boundsSeeing`（Flix）。`visibleFloors` もその上に組み直して決まりを 1 か所にする。
   別案: 人の考えどおり `tools/glb_bundle.py` が bundles.json に書く（その時は `stairReach` を layout.json へ移し、Python と Flix の両方が読む。Flix は 7 行減り、Python が 20 行前後と layout.json の 1 欄増える）。
3. **人物の範囲** — 推す: 束と同じ `Within(School.boundsSeeing(layout, その人物の階))`（今の `wantedKeys` と同じ意味。2 回目のレビューの指摘で 10 m の `around` から替えた）。
4. **はみ出しの間（止まりの 9 倍）・初めの値（0.2 ms/KB）・知らせまでの 10 秒を engine の private な定数にする** — 推す: はい。ゲームに出すと、また「機種ごとの数字を手で」に戻る。
5. **人物（骨・アニメ）の重さの補正を今回入れない** — 推す: 入れない（11 節）。
6. **階段で upper_b（小物だけの束）が遅れる穴を今回塞がない** — 推す: 塞がない。建物の束は門が「解けた」まで待つ（4.2）ので、壁と床の無い階は歩けない。小物は着いてから 2 秒前後で出る。塞ぐならゲームの `loadGate` に upper_b を足すだけ（engine は替えない）。
7. **版** — 推す: 0.115.0（pub の record の欄が変わり、ゲームのコンパイルが止まるので minor を上げる）。

## 14. レビューの記録

- 1 回目 72 点（必須 7・望ましい 10）→ 全部直した。
- 2 回目 86 点（1 回目の必須 7 は全部直った・新しい必須 3）→ 3 つとも直した: 10 秒の知らせを `Everywhere` の鍵だけにし「知らせた」を -2 で持つ／人物の範囲を `Within(boundsSeeing(その人物の階))` にして `around` を消した（新しい pub は 2 つ・5 節の数字は模擬で出し直し）／移行メモの Pending の値を初めの値にし、表は `start` を通して作ると書いた。0 節の止まりの上限は「1 コマあたり・時間の割合は保証しない」に直した。
- 残る望ましい（直していない）: `visibleFloors` を `boundsSeeing` に組み直す所で、階段の途中と箱の境で今の答えと同じかのテストを段 4 に 1 本・床の箱の y の上の端の含み方を決めて書く（7.1 の W との差の言い切りは 3 回目の後に入れた）。
- 3 回目 82 点 → 必須 2（9e241ab96 を取り込み、門を「解けた」まで待つ形に・blood-scale と bs-speed を移行の範囲に）と望ましい 9 を全部入れた。4 回目の採点はしていない。
