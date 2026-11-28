# 頁の JS を細くする — 判断の移し先と、移した先の品質の守り方（設計・2 稿）

> 状態: 設計案（実装なし・engine のファイルは未変更）。1 稿 74 点（必須 5）→ 2 稿 88 点（必須なし）。2 回目の推奨と任意も直した。直した所は末尾の「レビューの反映」。
> 読んだ物: `engine_web/js/*.js`・`engine_web/js/index.html`・`engine_web/java/fge/web/{Deferred,Browser}.java`・
> `engine_web/src/WebLayer.flix`（`downloadsOf`・`policyOfText`・`codeStateOfText`・`onMissingOfText`）・`engine/src/platform/LoadProgress.flix`・
> `engine/src/platform/LoadProgress/Deferred.flix`・`engine_world/src/App/Internal/LoadWait.flix`（`hitsOf`・`joinedOf`）・
> `go/cmd_exportweb.go`（`webBundle`）・`go/exportweb_{deferred,deferredpolicy,splash,gate,page,reuse,browsercheck,tapcheck}.go`・
> `go/internal/cdp`・`plans/web-loading-p4.md`・`plans/web-loading-p5.md`。
> 測った数: Chrome を使う今の Go のテスト 2 本（Chrome を 2 回起動する）が `go test -count=1` で 2.4 秒。1 回の起動は約 1 秒。

## 0. 何を解くか

頁の JS（`fge-web.js` 2,273 行・`fge-sw.js` 327 行・`index.html` の頭の script が Go の文字列で約 70 行）には、
単体テストが 1 本も無いまま、起動と後回しの素材の**判断**が入っている。今日のレビューの必須（取り直す失敗で 20 秒待つ）も JS の中だった。

棚卸しで、同じ判断が何か所にも書かれていることが分かった。特に「届く前に使われた時に待つか」の既定は **4 か所**にある。

| 書いてある所 | 中身 |
|---|---|
| `fge-web.js` の `fgeDeferredPolicy` | フォントは group が無ければ placeholder |
| `fge-web.js` の `fgeNoteMissingSkips` | onMissing が空の texture は待つ（記録の `why` を決める） |
| `go/exportweb_deferred.go` の `webWaitsWhenMissing` | 門の秒の見積もり用に、上の 2 つと Flix の既定を Go で書き直した物 |
| `engine_world/.../LoadWait.flix` の `hitsOf`・`joinedOf`（と `LoadProgress.MissingPolicy` の None の意味） | 絵は None なら待つ・音は Wait の時だけ待つ・group 入りの音は None でも一緒に待つ |

この計画の後は **Go の 1 か所（web 用）と Flix の 1 か所（デスクトップと、Go が埋めない音の空の読み）**の 2 か所になる。
デスクトップ（`LoadProgress.localDownloads`）は後回しを持たないので Flix の None の既定を引き続き使い、web では絵とフォントの None は届かなくなる（Go が埋める）。

種類の見分け（`.fontatlas` で終わればフォント）も、Go の `webDeferredKindOf`・Go の `exportweb_titleassets.go` の `kindOf`・JS の `fgeDeferredPrepare` の 3 か所にある（この計画で JS の分は Go の `kind` を読む形になる。Go の 2 つは書き出しの中の別の用途なので、今回はそのまま）。
bundle.json の約束は Go の `webBundle`（書く）・JS（読む）・JS が字に直して Flix へ渡す約束（`"onMissing\ngroup"`・`"failed:理由"`・`"none"`）の 3 か所で、
それぞれ別に扱われている。

## 1. 今の JS の棚卸し

「判断」= 何をするかを決める所（policy）。「実行」= 決まった事をブラウザの API でする所（mechanism）。
「wasm の前」= TeaVM の instance が手元に来る前（`fgeLoadWasm` が解ける前）に動く必要があるか。
「main の前」= instance はあるが `teavm.exports.main` をまだ呼んでいない間（押す前の後回しの取り物・押した瞬間のロゴ）。

### 1.1 fge-web.js（2,273 行）

| 行 | 機能 | 行数 | 判断 / 実行 | いつ動くか | 今のテスト |
|---|---|---:|---|---|---|
| 6–226 | GL の物の表・テクスチャ・絵を解く | 220 | 実行 | main の後（wasm が呼ぶ） | gallery の描き出し（間接） |
| 227–257 | canvas・`?capture=` の画素 | 30 | 実行 | main の後 | web-capture（間接） |
| 258–397 | WebGPU の pass・描き手の選び分け・WebGL2 への切り替え・全画面 | 140 | 実行（`?backend=` の読みだけ判断） | 押した直後〜 | webgpu-v1-check-web（間接） |
| 398–428 | キーと pointer の表 | 30 | 実行 | main の後 | なし |
| 429–884 | 指の端末: パッド・ジェスチャー・縦横の判定・入力の配線 | 455 | 混在（タップの閾値・長押し 650ms・縦の design を選ぶ式） | wasm の前（パッドとレイアウトは bundle を読んだ直後に組む） | Go の `exportweb_touch_test` はキーの対応だけ |
| 885–904 | 使った素材の記録（`?usedAssets=1`） | 20 | 実行（early の判定は判断） | main の後 | web-check の記録読み（偽の頁で） |
| 905–959 | `?net=4g` の時計・待ちと飛ばしの記録 | 55 | **判断**（既定の写し #2 がここ） | main の前（時計は押した時に始まる） | tapcheck（実ゲームの書き出しでだけ） |
| 960–1019 | 素材の表・ImageBitmap・道の持ち方 | 60 | 実行（メモリを捨てる時の決まりは判断） | wasm の前 | なし |
| 1020–1075 | 音（WebAudio） | 55 | 実行 | wasm の前（押す前に解く） | なし |
| 1076–1099 | 1 コマの CPU の控え | 25 | 実行 | main の後 | なし |
| 1100–1271 | 起動の画面（Splash.flix と同じ配置を canvas に） | 170 | 実行（寸法の式は Splash.flix の写し） | **wasm の前** | なし |
| 1272–1434 | 押した後のロゴ | 165 | **判断**（出すか・残りの秒の見込み・飛ばし方・min/max）＋描画とジングル | main の前（押した瞬間） | なし |
| 1435–1509 | 押す文言の置き場・押せる合図・押した時の波紋・fps の表示 | 75 | 実行 | wasm の後・main の前（fps の表示だけ main の最初のコマから） | なし |
| 1510–1558 | コードの状態・engine の待ちの知らせ・起動の画面を外す時・エラー | 50 | 判断（外す条件 4 つ）＋実行 | main の後 | なし |
| 1559–1671 | 版・取り直し付きの fetch・配る道・アトラスの組み直し・音の取り直し | 110 | **判断**（4 回・500ms×n²・5xx と回線の失敗だけ取り直す・opus を解けなければ wav）＋実行 | **wasm の前** | なし |
| 1672–1898 | 後回しの素材: 状態・届いたか・missing・扱い・行列・取り直し・裏から戻った時 | 225 | **判断の中心**（既定の写し #1 もここ） | main の前（wasm と起動の素材がそろった時に取り始める） | なし |
| 1899–1912 | 起動の取り物の並べ方（`fgeEachLimited`） | 15 | 実行 | wasm の前 | なし |
| 1913–2010 | 起動の進みの棒・wasm を数えながら取る・brotli | 100 | 実行（重みは Go の `boot` が決めている） | wasm の前 | なし |
| 2011–2060 | 落ちた時の関数名 | 50 | 実行 | いつでも | なし |
| 2061–2204 | 起動の順番（bundle を読む→取る→押す→main） | 145 | 判断（順番と押したと見なすイベント）＋実行 | **wasm の前** | web-check（実ゲームで main まで） |
| 2205–2271 | Service Worker の登録・外す・URL を送る | 65 | 判断（登録する条件 3 つ）＋実行 | main の前（押せるようになった後） | なし |

判断が濃いのは **後回し（225）・ロゴ（165 のうち約 70）・fetch の取り直し（約 50）・net=4g の記録（55）**で、合わせて約 400 行。
残りの約 1,850 行は wasm が呼ぶ実行（GL・WebGPU・入力・音）と描画で、「判断を移す」話の外にある。

### 1.2 そのほかの頁の JS

| ファイル | 行数 | 判断 / 実行 | いつ動くか | 今のテスト |
|---|---:|---|---|---|
| `fge-sw.js`（Service Worker） | 327 | **判断**（版の確かめ・sums で確かめて入れる・自分の頁か・古い版を消す） | wasm と別の所で動く | なし |
| `fge-sw-off.js` | 20 | 実行 | 同上 | なし |
| `index.html` の頭の script（`exportweb_page.go` の `webHeadScript`） | 約 70 | **判断**（version.txt を待つか・preload・読み直しを 60 秒に 1 回） | 一番先 | 字の検査だけ（`TestStampWebIndex*`） |
| `brotli-decode.js` | 23（外の物） | 実行 | wasm の前 | なし |

## 2. 移し先の案

3 つの案を比べる。どれも GL・WebGPU・入力・音の実行は JS に残す（wasm が JSBody で呼ぶ所で、判断ではない）。

### 案 A: 書き出しの時に決まる判断は Go へ・動いてから決まる判断は JS の「純粋な core」へ（親の案を直した物）

```
 書き出し（Go）                 頁（JS）                                   wasm（Flix）
 ┌──────────────────────┐      ┌──────────────────────────────────┐     ┌──────────────────────┐
 │ 種類・既定を埋めた    │      │ fge-load-core.js（DOM も fetch も │     │ LoadWait: 待つか・    │
 │ onMissing・名前・     │ ───▶ │ 時計も触らない。状態 + イベント   │ ◀── │ 戻すか（今のまま）    │
 │ ロゴが待つ行 を決めて │ JSON │ → 新しい状態 + コマンド）         │ 字  │ 字 → 型（engine の   │
 │ bundle.json に書く    │      ├──────────────────────────────────┤     │ 1 か所でテストする）  │
 │ （format: 2）         │      │ fge-web.js（shell: fetch・DOM・   │     └──────────────────────┘
 └──────────────────────┘      │ 時計・ブラウザのイベントを core へ │
                               │ 渡し、core のコマンドを実行する）  │
                               └──────────────────────────────────┘
```

- **Go が持つ**: 書き出しの時に決まる物（種類・`onMissing` の既定を埋めた値・フォントの `font_<名前>`・ロゴの `waitFor` に当たる行）。
- **core（JS・純粋）が持つ**: 動いてから決まる物のうち、テーブル駆動テストに見合う重さの物だけ（後回しの状態の移り変わり・届いたか・取り直すか・永久の失敗か・ロゴを出すか / 終えるか）。
  関数は `(状態, イベント, 今の時刻) → (状態, コマンド[])` の形（functional core / imperative shell）で、時刻も外から渡す。
- **shell（JS）が持つ**: fetch・createImageBitmap・decodeAudioData・DOM・setTimeout・ブラウザのイベントの配線。条件の少ない軽い判断（起動の画面を外す 4 条件・SW を登録する 3 条件・起動の棒の割り算・縦の design の式）もここに残す（§6）。
- **Flix が持つ**: 今のまま（LoadWait は型とテーブル駆動テストで守られている）。字を型に直す 3 つ（`loadStateOfText`・`policyOfText`・`codeStateOfText`）を engine の 1 か所にまとめ、テストを付ける。

| | |
|---|---|
| 利点 | web の既定が Go の 1 関数になる（門の見積もりも同じ値を読む）。core は DOM が無いので、同じテーブルを何本でも速く流せる。wasm は 1 バイトも太らない。JS の読み手は判断を core の 1 ファイルで読める。core の形のまま、後で Flix へ写す時も同じテーブルが答えになる |
| 欠点 | JS のファイルが 1 本増える（配る時は Go がつなげて 1 本にするので、取る回数は増えない）。core のテストは Chromium 系のブラウザを要る（無い機械では飛ぶ。§4.6）。shell と WebLayer の間の取り違えは、偽の wasm で写した分しか守れない（本物の wasm の門は残す。§4.3） |
| 手間 | 約 18 時間（§5） |
| Windows | Go の側は今の go test のまま動く。ブラウザのテストは `internal/cdp` が `proc_windows.go` を持ち、Chrome か Edge があれば動く（Edge を候補に足す。§4.6） |
| TeaVM | 影響なし（wasm に何も足さない。JSBody の名前と字も変えない） |

### 案 B: 動いてから決まる判断を Flix（wasm の中）へ移す

```
 書き出し（Go）            頁（JS）                          wasm（Flix: WebLayer の後回し）
 bundle.json ───────────▶ fetch と DOM だけ。              状態の移り変わり・届いたか・取り直し・
                          イベントを wasm の export へ ──▶  ロゴを出すか を Flix の enum で持つ。
                          wasm のコマンドを実行 ◀────────  LoadWait の既定と同じモジュールに並ぶ
```

後回しを取り始める時（`fgeDeferredStart` は `wasmReady && bootReady` を待つ）も、押せるようになる時（`await wasmLoad` の後の `fgeSplashReady`）も、
**TeaVM の instance はもう手元にある**。だから案 B は時刻の上では成り立つ。足りないのは「main の前に呼べる入口」で、wasm の前に要る判断は起動の素材の取り直し・起動の棒・起動の画面だけ。

| | |
|---|---|
| 利点 | 判断が型と effect と Flix のテーブル駆動テストの側に入る（このリポの守りが一番厚い所）。既定が LoadWait と同じ言葉で書ける |
| 欠点 | (1) main の前に呼べる export（TeaVM の `@JSExport`）を足し、main の前に静的な初期化が済む事を確かめるスパイクが要る。(2) wasm が太る（状態機械とテーブルで数 KB〜十数 KB の見込み。起動に取る量が増える）。後から wasm を分ける時（P4 の後の話・今は `fgeCode.state` を書く所が無い）は、この部分を先の wasm に入れる約束も要る。(3) 起動の素材の取り直し（wasm の前）は JS に残るので、取り直しの判断が JS と Flix の 2 か所に割れる。(4) engine の構造に触るので相談が要る |
| 手間 | 約 24〜28 時間（export のスパイク・初期化の約束・Flix の状態機械とテスト・JS の配線） |
| Windows | 影響なし（Flix のテストは今のまま） |
| TeaVM | 太る。到達性は export を足した分だけ広がる |

### 案 C: JS のまま形を変える（TypeScript か、Go の中の JS エンジン）

C1: TypeScript に書き替えて型で守る。C2: 純粋な関数だけ抜き、Go の中の JS エンジン（`github.com/dop251/goja`）でテーブルを流す。

| | C1 TypeScript | C2 goja |
|---|---|---|
| 利点 | 型が付く。bundle.json の型を `.d.ts` で書ける | ブラウザが無い機械でもテーブルが流れる（0.1 秒台）。Windows でも必ず動く |
| 欠点 | node も tsc も devbox に無い（`which node` は空）。型の検査の道具が 1 つ増え、型の正が Go と TS の 2 つになる。判断が 4 か所に散っている問題はそのまま | 依存が 1 つ増える（今の go.mod は starlark と flixlint だけ）。ブラウザでない JS エンジンなので、ブラウザの API の違いは見えない。判断の散らばりは解かない |
| 手間 | 約 16 時間＋道具の配線 | 案 A の core に足すだけなら 約 2 時間 |
| TeaVM | 影響なし | 影響なし |

C は「判断がどこにあるか」を変えないので、それだけでは主の問題を解かない。C2 は案 A の core の流し方の**代わりの手**としてだけ残す（§4.6）。

### 比べのまとめ

| | web の既定を 1 か所に | main の前の判断のテスト | wasm の太り | 新しい道具・依存 | engine の相談 | 手間 |
|---|---|---|---|---|---|---|
| A | ○（Go の 1 関数） | ○（core のテーブル） | なし | なし | 字の 3 関数だけ（ステップ 4） | 約 18h |
| B | ○（Flix） | ○（Flix のテスト）。ただし起動の取り直しは JS に残る | あり | `@JSExport` のスパイク | 要る（構造） | 約 26h |
| C1 | × | ○（型） | なし | node・tsc | なし | 約 16h |

**おすすめは案 A。** 判断の大半は「書き出しの時に決まる物」で、これは Go に移せば Go の厚いテストに乗る。
残る「動いてから決まる物」は、案 B でも Flix に置けるが、wasm の太り・export のスパイク・取り直しの判断が 2 か所に割れる事の 3 つが重い。
案 A の core は DOM から切り離した純粋な形なので、後で案 B に進む時も、core のテーブルがそのまま Flix のテストの答えになる。

## 3. おすすめ案（A）の詳細

### 3.1 何をどこへ移すか

| 今の場所（fge-web.js / 他） | 中身 | 移す先 | 移した後の JS |
|---|---|---|---|
| `fgeDeferredPrepare` の `/\.fontatlas$/`・`e.image`・`e.sounds` の照合・`e.file` | 種類と役割の見分け | **Go**（`webDeferredKindOf` を正にし、`kind` と `inFiles` を書く） | `d.kind`・`d.inFiles` を読むだけ |
| `fgeDeferredPrepare` の `font_<名前>` の足し | 名前の広げ | **Go**（`names` に全部書く。ステップ 2 で JS と同時に入れる） | `d.names` をそのまま表へ |
| `fgeDeferredPolicy` の「group の無いフォントは placeholder」 | 既定 #1 | **Go**（§3.3 の `withDefaultOnMissing`） | `d.onMissing + "\n" + d.group` を返すだけ |
| `fgeNoteMissingSkips` の「空の texture は待つ」 | 既定 #2 | **Go**（同じ値を読む） | `d.onMissing === "wait"` |
| `webWaitsWhenMissing`（Go の門） | 既定 #3 | **Go**（埋めた値を読む形に。files は待たない） | — |
| `fgeAfterTapPending` の group の照合 | ロゴが待つ行 | **Go**（行に `afterTap: true`） | `d.afterTap` |
| `fgeDeferredState`・`Arrived`・`Missing(Gen)`・`AllArrived`・`IsDeferred`・`fgeSplashDeferredRatio` | 状態の見せ方 | **core**（§3.5 の問いの表） | shell は core の答えを JSBody へ返す |
| `fgeDeferredRequest`・`RetryFailed`・`Restart`・`Pump`・`Fetch`・`Receive` の状態の書き換え・`MarkLoaded`・`Release`・`fgeIsPermanentFailure` | 行列と取り直し | **core**（§3.5 のイベントの表） | shell は fetch・解く・close をして結果をイベントで渡す |
| `fgeFetchBytes` の 4 回・500ms×n²・何を取り直すか | 1 本の中の取り直し | **core**（`computeRetryDelay(err, attempt)`） | shell は答えの通りに待って取り直す |
| `fgeDecodeSound` の「配る道で解けなければ元の wav」 | 音の取り直し | **core**（`shouldRefetchOriginalSound(served, path, err)`） | shell は答えの通りに wav を取る |
| `fgeAfterTapStart` の出す条件・`fgeAfterTapRemainingSeconds`・`fgeAfterTapStep` の終わる条件 | ロゴを出す / 終える | **core**（`decideAfterTap`） | shell は描画・ジングル・入力の捕捉・localStorage |
| `fgeNetGate` の時刻 | 4G で渡す時刻 | **core**（後回しの行が `netHeld` の間は downloading と答える） | shell は setTimeout でイベントを渡す |
| `policyOfText`・`codeStateOfText`・`onMissingOfText`（WebLayer・非 pub） | 字 → 型 | **Flix の engine**（`LoadProgress.Deferred` へ `loadStateOfText` と並べる） | — |

GL・WebGPU・入力・音の実行・起動の画面とロゴの描画・関数名・軽い判断（起動の画面を外す・SW の登録・起動の棒・縦の design）は動かさない（§6）。

### 3.2 bundle.json の約束の形

**正は Go の struct 1 つ**（`go/cmd_exportweb.go` の `webBundle` と `exportweb_deferred.go` の `webDeferredEntry`）。JS と Flix はこれを手で写さず、Go のテストが作る **golden ファイル**を読んで合わせる。

後回しの 1 行（`deferred[]`）は次の形にする（`// 新` `// 変` が変わる欄）。

```jsonc
// 音の行
{ "path": "assets/bgm/town.ogg", "bytes": 182311,
  "kind": "sound",              // 新: image | font | sound | file（Go の webDeferredKindOf が正）
  "inFiles": false,             // 新: files にも載る道か（素材の表に置くか。フォントのアトラスは true）
  "names": ["town"],
  "onMissing": "",              // 変: image と font は既定を埋めた値・sound は書いた値のまま・file はいつも空（§3.3）
  "group": "start", "arrivalSeconds": 4.2,
  "afterTap": true }            // 新: 押した後のロゴがこの行を待つか
// フォントの行
{ "path": "font-atlas/x.fontatlas", "bytes": 40211, "kind": "font", "inFiles": true,
  "names": ["x", "font_x"],     // 変: font_<名前> も Go が入れる
  "onMissing": "placeholder", "group": "", "arrivalSeconds": 2.0, "afterTap": false }
```

束の頭に `"format": 2` を足す。

**読み手ごとの古い形の扱い**:

| 読み手 | format 1（今の束）を読むか | 扱い |
|---|---|---|
| 頁の JS（core） | 読まない | 書き出しの時に `p.Engine/engine_web/js` を写すので、Go と JS は同じチェックアウトからそろう。`format !== 2` は起動の時に止めて「書き出し直してください」と出す |
| Go の web-check（`loadWebBundle` → `runWebCheck` → 門） | **読む**（公開済みの gh-pages の根・play/ の古い束を確かめる） | `loadWebBundle` で `format < 2` を見たら、書き出しと同じ `fillWebDeferredDefaults` を通してから使う（読む時にそろえる） |
| Go の export-web | 自分で書いた物だけ | 書く前に、core のファイルの `var FGE_BUNDLE_FORMAT = 2;` を読み、自分の `webBundleFormat` と違えばその場で止める（「bin/fge-go を作り直す」と出す）。古い `bin/fge-go` と新しい JS の食い違いを、頁を開く前に見つける |

`webBundle.Deferred` のコメントの WhyNot（後回しの行を files などから抜かない — 古い fge-web.js でも全部を起動の前に取って動く）はそのまま残す。
新しい欄は足すだけで、古い JS は知らない欄を読まない。

**3 言語を 1 つに保つ仕組み**:

1. **Go の struct が正**。欄を足す・変える時は Go を直す。
2. **golden ファイル**を Go のテストが作る: `go/testdata/webbundle/<名前>.bundle.json`（新しく作る置き場。今の exportweb のテストに golden は無く、`go/internal/px` の star の golden の作りを写す）。
   小さな偽のゲーム（`go/testdata/webbundle/<名前>/project.json` と数バイトの素材）から束を組む。今の組み立ては `cmd_exportweb.go` の 486〜536 行に散っていて、フォントの行（`placeFontAtlases`・`webFontGroupStarts`）と afterTap（`resolveWebAfterTap` と `splash.AfterTap` の代入）を通らないと golden に出てこない。
   そこで 486〜536 行を 1 つの関数 `assembleWebBundle(game, out, …)` に切り出し（書き出しと golden の両方が呼ぶ）、その後に `fillWebDeferredDefaults` → `marshalWebBundle` を通す。`setWebArrivalSeconds` は `out` の素材の大きさを読むので、テストは `t.TempDir()` の `out` に偽の素材を写してから呼ぶ。
   **変換（cwebp・opus）は通さない**（機械で大きさが揺れて golden が揺れるため）。`go test -run TestWebBundleGolden -update` で書き直し、ふだんは差が出たら赤。
   golden は 4 本: `minimal`（後回し無し）・`deferred-mixed`（絵・files にも載る絵・フォント・音・ループの音・files だけ・group あり / なし・deferredPolicy で files に wait を書いた行）・`after-tap`（custom のロゴ・waitFor・mode none）・`format1`（今の形の束を手で置いた物。web-check の読みの入力）。
3. **golden が JS の読む欄を全部通る**ことを Go のテストで止める: `deferred-mixed` と `after-tap` の JSON の鍵の集まり ⊇ `webDeferredEntry`・`webAfterTap` の json タグの集まり（reflect で読む）。
   `Checks`・`Boot`・`StartupBudget`・`Draft` のような、`buildWebBundle` から作れず JS の判断にも使わない欄は対象にしない。
4. **JS の core のテストは同じ golden を入力に使う**（§4.2）。Go が欄の名前を変えると、JS のテーブルが golden を読めずに赤になる。
5. **Flix へ渡す字の約束**（`"queued"`・`"failed:理由"`・`"wait\nstart"`・`"none"` など）は `go/testdata/webbundle/protocol.json` に 1 つのテーブルとして書く:
   `{ "stateTexts": [["queued","Queued"], ...], "policyTexts": [["placeholder\n", "Placeholder", null], ...], "codeTexts": [["none","Loaded"], ...] }`。
   - core のテーブル駆動テストは「core が返す字は全部このテーブルにある」を確かめる。group（`wait\nstart` の `start`）と failed の理由は自由な字なので、onMissing の欄と `failed:` の頭だけを照らす。
   - Flix の側は **Go のテストが Flix のテストのファイルを生成して比べる**: `TestWebProtocolFlixTestIsGenerated` が protocol.json から `engine/test/TestLoadProgressDeferredProtocol.flix`（行ごとに 1 本の `@Test`・今の `TestLoadProgressDeferred.flix` と同じ `def testX(): Unit \ Assert` の形）の中身を作り、ファイルと 1 字でも違えば赤。`-update` で書き直す。
     今の `testKnownStateTextsMapToLoadStates` などの字の表は生成した側と重なるので、ステップ 4 で生成した側に寄せて消す（理由の残る `testUnknownTextIsFailed` のような手書きの物は残す）。
     字をファイルの中から探す形にしない（`"loaded"` はどこにでもあり、`\n` の書き方も違う）。新しい make のターゲットは作らない。

JSON Schema を作って配る形は採らない（§6）。

### 3.3 web の既定を 1 か所にする: `onMissing` の埋め方

Flix の LoadWait の振る舞いを変えないように、埋めるのは絵とフォントだけにし、files は必ず空にする。

| kind | 書いた onMissing | group | 埋めた値 | Flix・門の読み（今と同じ） |
|---|---|---|---|---|
| image | 空 | 何でも | `wait` | 待つ |
| image | placeholder | 何でも | `placeholder` | 描かずに進む |
| font | 空 | 空 | `placeholder` | 先頭のフォントで進む（**今の JS の既定 #1**） |
| font | 空 | あり | `wait` | 待つ（group が効かなくならないように） |
| font | wait / placeholder | 何でも | 書いた値 | 書いた値 |
| sound | 空 | 何でも | **空のまま** | 単独では待たない・group 入りなら一緒に待つ（`joinedOf` は None を待つ側に数える） |
| sound | wait / skip | 何でも | 書いた値 | 書いた値 |
| file | 空 / wait | 何でも | **空** | 待たない（engine は files を待たない。今の `webWaitsWhenMissing` も file は偽） |

WhyNot: 音の空を `skip` に埋めない — `joinedOf` は None の音を group の待ちに入れ、`skip` の音は入れない。埋めると group に入れた BGM が待たれなくなり、エラーも出ない。
WhyNot: files の `wait` を残さない — `onMissingFits` は files に wait を書くのを許しているが、engine も今の門も files を待たない。残すと門の `onMissing == "wait"` が files を待つ物と数える。

### 3.4 JS に残る物

shell（`fge-web.js`）の後回しと起動の部分は「**取って・ほどいて・渡す**」だけになる:

- 取る: `fetch`（core が返した `fetch` のコマンド）・`AbortController`
- ほどく: gzip・アトラスの組み直し・`createImageBitmap`・`decodeAudioData`
- 渡す: 結果を core へイベントとして、core の答えを JSBody（`fgeDeferredState` など）へ、描く物を canvas へ

JSBody から呼ばれる名前（`fgeDeferredState`・`fgeDeferredMissing` など、`Deferred.java` の 12 本）は**名前も字も変えない**。中身が core を呼ぶ 1 行になる。
wasm の側（Java・Flix）はステップ 4 の字の関数の移動のほかに触らない。

core のファイル（`engine_web/js/fge-load-core.js`・見込み 350〜450 行）は DOM・`fetch`・`performance`・`setTimeout`・`window`・`localStorage` を 1 つも呼ばない。ES2017 の範囲で書き、`async` を入れない（goja でも読める形に保つ。§4.6）。
書き出しは `fge-load-core.js` と `fge-web.js` を**つなげて 1 本の `fge-web.js` として配る**（取る回数を増やさない）。つなげた中身から版のハッシュを作り、`go/exportweb_reuse.go` の指紋の入力にも core のファイルを足す（足さないと core だけを直した時に `--reuse` が古い書き出しを使い回す）。

### 3.5 core のイベントとコマンドと問い

shell が core へ渡す物と、core が返す物を全部並べる。今の JS の関数と JSBody はどれかの行に当たる。

**イベント（shell → core。どれも `now` を添える）**

| イベント | 今の JS | core がすること |
|---|---|---|
| `wasmLoaded` | `fgeDeferred.wasmReady = true` | 2 つ目がそろえば取り始める（そろったかの判断は core） |
| `bootAssetsLoaded` | `fgeDeferred.bootReady = true` | 同上 |
| `fetchSettled {path, gen, ok, status, errName, permanent, bytesHeld}` | `fgeDeferredReceive` の終わり・`fgeDeferredFetch` の catch | **1 本の中の取り直し（4 回）を終えた後**に 1 回だけ来る。ok なら downloaded（音は loaded）・ng なら failed（永久か一時かは core の `isPermanentFailure`）。`gen` が古ければ数も状態も変えない |
| `netGateOpened {path, gen}` | `fgeNetGate` の resolve | `?net=4g` の行は、取り終えても arrival の時刻まで downloading と答え、このイベントで進める（音は解いた後なので loaded・ほかは downloaded） |
| `request {paths}` | `fgeDeferredRequest` | 並べた順で行列の頭へ（逆にしない）。一時の失敗で `retryMs` を過ぎた物と released は queued に戻す |
| `markLoaded {path}` | `fgeDeferredMarkLoaded` | loaded にし、絵だけで files に無い行なら `closeBitmap` のコマンドを返す |
| `release {paths, held}` | `fgeDeferredRelease` | shell が「表に持っていた・ImageBitmap にした物ではない」と調べた道（`held`）だけ released にし、`arrivedAtRelease` を控える。`dropBytes` のコマンドを返す |
| `online` | `online` のリスナー | 一時の失敗を全部すぐ queued へ |
| `sweep` | 30 秒ごとの setInterval | `hidden` でなければ、`retryMs` を過ぎた一時の失敗を queued へ |
| `hidden` / `visible` | `visibilitychange` | hidden の時刻を core が控える。visible で一時の失敗を戻し、`staleMs` より長く裏にいたなら、隠れる前に始めた downloading を新しい順に取り直す（`gen` を進め、`abort` のコマンド・`running` を先に減らす） |
| `bytesFetched {n}` | `fgeLoadLog.bytes += n` | ロゴの残りの秒の見込みに使う取る速さの材料 |
| `tapped {captured, seen}` | 押した時の `go` | 4G の時計を始める・ロゴを出すか決める（`?capture=` の頁か・localStorage の「出した」は shell が調べて載せる） |
| `mainStarting` | main の直前の `fgeNetStartClock()` | 4G の時計がまだなら始める（`?capture=` の頁は押さないのでここで始まる）。時計の前に取り終えた行の `openNetGate` をまとめて返す |
| `frame` | ロゴの毎コマ（`fgeAfterTapStep`） | ロゴを終えるか決める（min・max・待つ行がそろった・飛ばし） |
| `skipPressed` | ロゴの間の押し | 300ms を過ぎていれば飛ばす |

**コマンド（core → shell）**: `fetch {path, gen}`・`abort {path}`・`closeBitmap {path}`・`dropBytes {path}`・`showAfterTap {mode, logo, sound}`・`endAfterTap`・`openNetGate {path, gen, at}`（shell は `at` に setTimeout して `netGateOpened` を返す）。

**問い（shell → core。状態を変えない）**

| 問い | 今の JS / JSBody | 答え |
|---|---|---|
| `isDeferred(nameOrPath)` | `Deferred.isDeferred` | Bool |
| `stateText(nameOrPath)` | `Deferred.state` | protocol.json の字（released は queued・failed は `failed:理由`） |
| `missingText()` | `Deferred.missing` | 届いていない名前（無ければ道）を改行でつないだ字 |
| `missingGen()` | `Deferred.missingGen` | missing が変わるたびに増える数 |
| `policyText(name)` | `Deferred.policy` | `onMissing + "\n" + group`（表に無ければ `"\n"`） |
| `codeStateText()` | `Deferred.codeState` | いつも `"none"`（後から取る wasm を書く所は今無い。口だけ持つ） |
| `isAfterTapShowing()` | `Deferred.isSplashShowing` | Bool |
| `hasArrived(name)` | `fgeNoteUsed` の early・`fgeNoteMissingSkips` | Bool |
| `isAllArrived()` | `?deferred=all` の待ちのループ | Bool |
| `deferredRatio()` | `fgeSplashDeferredRatio` | 0..1 か null |


`setLoadWait`・`clearLoadWait`（JSBody 12 本のうち 2 本）は記録だけで判断が無いので shell に残す。

**core の instance の外の純粋な関数**: 1 本の中の取り直しは core を作る前（`bundle.json` そのものを取る時・起動の素材）にも要るので、次の 3 つは core のファイルの top-level に置き、bundle を要らない形にする。

| 関数 | 今の JS | 答え |
|---|---|---|
| `fgeComputeRetryDelay(err, attempt, tuning)` | `fgeFetchBytes` | 待つ ms か「取り直さない」 |
| `fgeIsPermanentFailure(err)` | 同名 | Bool（core の `fetchSettled` も使う） |
| `fgeShouldRefetchOriginalSound(served, path, err)` | `fgeDecodeSound` | Bool |

### 3.6 擬似コード

**Go（書き出し側）** — `setWebArrivalSeconds`（`cmd_exportweb.go` 536 行あたり）の後に呼ぶ。web-check の `loadWebBundle` も format 1 の束に同じ関数を通す。

```go
// fillWebDeferredDefaults は後回しの行に、頁と engine が読み替えずに使える値を書く
// （種類・files にも載るか・既定を埋めた onMissing・フォントのアトラスの名前・ロゴが待つか）。
func fillWebDeferredDefaults(b *webBundle) {
	waitFor := map[string]bool{}
	if at := b.afterTapOrNil(); at != nil && at.Mode != "none" {
		for _, g := range at.WaitFor {
			waitFor[g] = true
		}
	}
	files := setOf(b.Files)
	for i := range b.Deferred {
		e := &b.Deferred[i]
		e.Kind = webDeferredKindOf(e.Path, b)
		e.InFiles = files[e.Path]
		e.OnMissing = withDefaultOnMissing(e.Kind, e.OnMissing, e.Group)
		if e.Kind == "font" {
			e.Names = withFontTextureNames(e.Names) // "x" → "x", "font_x"（ステップ 2 から）
		}
		e.AfterTap = e.Group != "" && waitFor[e.Group]
	}
	b.Format = webBundleFormat // 2
}

// withDefaultOnMissing は §3.3 の表。音は書いた値のまま・files はいつも空。
func withDefaultOnMissing(kind, written, group string) string {
	switch {
	case kind == "file":
		return ""
	case kind == "sound" || written != "":
		return written
	case kind == "font" && group == "":
		return "placeholder"
	default:
		return "wait"
	}
}

// webWaitsWhenMissing（門の見積もり）は埋めた値だけを見る。
func webWaitsWhenMissing(e webDeferredEntry) bool { return e.Kind != "file" && e.OnMissing == "wait" }
```

**JS（core と shell）**

```js
// fge-load-core.js — DOM も fetch も時計も呼ばない。now は呼ぶ側が渡す。
var FGE_BUNDLE_FORMAT = 2;  // export-web が読んで自分の format と比べる
function fgeMakeLoadCore(bundle, tuning) {
  if (bundle.format !== FGE_BUNDLE_FORMAT) throw fgeFormatError(bundle.format);
  var t = Object.assign({ limit: 2, retryMs: 5000, staleMs: 2000, attempts: 4 }, tuning);
  var s = { entries: (bundle.deferred || []).map(fgeEntryOf), queue: [], running: 0,
            wasm: false, boot: false, started: false, hiddenAt: -1, bytes: 0, tappedAt: -1 };
  return {
    // イベントを受けて状態を進め、shell が実行するコマンドを返す。
    on: function (ev, now) {
      var cmds = [];
      switch (ev.type) {
        case "wasmLoaded":       s.wasm = true; break;
        case "bootAssetsLoaded": s.boot = true; break;
        case "fetchSettled":     settle(s, ev, now, cmds); break;   // gen が古ければ何もしない
        case "release":          release(s, ev.paths, ev.held, cmds); break;
        case "visible":          restartStale(s, now, t, cmds); break;
        // …（§3.5 の表の残り）
      }
      startIfReady(s);                                              // wasm と boot がそろった時だけ
      return cmds.concat(pump(s, t));                               // [{ do: "fetch", path, gen }, …]
    },
    stateText:  function (nameOrPath) { return stateTextOf(find(s, nameOrPath)); },
    missingText: function () { return s.entries.filter(notArrived).flatMap(namesOrPath).join("\n"); },
    policyText: function (name) { var e = byName(s, name); return e ? e.onMissing + "\n" + e.group : "\n"; }
    // …（§3.5 の問いの表の残り）
  };
}

// fge-web.js（shell）— core のコマンドを実行するだけ。
function fgeRunCommands(cmds) {
  cmds.forEach(function (c) {
    if (c.do === "fetch") fgeFetchAndUnpack(c).then(
      function (held) { fgeRunCommands(fgeLoad.on({ type: "fetchSettled", path: c.path, gen: c.gen, ok: true, bytesHeld: held }, performance.now())); },
      function (err)  { fgeRunCommands(fgeLoad.on({ type: "fetchSettled", path: c.path, gen: c.gen, ok: false, status: err.status,
                                                    errName: err.name, permanent: !!err.permanent }, performance.now())); });
    else if (c.do === "abort") fgeAbort(c.path);
    else if (c.do === "closeBitmap") fgeCloseBitmap(c.path);
  });
}
function fgeDeferredState(nameOrPath) { return fgeLoad.stateText(nameOrPath); }   // Deferred.java から呼ばれる名前は変えない
function fgeDeferredPolicy(name) { return fgeLoad.policyText(name); }
```

**Flix（読む側）** — `WebLayer.policyOfText`・`codeStateOfText`・`onMissingOfText` を engine の `LoadProgress.Deferred` へ移して pub にし、テストを付ける（engine の変更なのでステップ 4 の前に相談）。

```flix
// engine/src/platform/LoadProgress/Deferred.flix
/// 頁の扱いの字（"onMissing\ngroup"・無い欄は空）を MissingPolicy へ。知らない onMissing は種類の既定（None）。
pub def policyOfText(text: String): LoadProgress.MissingPolicy =
    let parts = String.split(regex = "\n", text);
    let nonEmpty = s -> if (String.isEmpty(s)) None else Some(s);
    { onMissing = List.head(parts) |> Option.flatMap(nonEmpty) |> Option.flatMap(onMissingOfText),
      group     = List.nth(1, parts) |> Option.flatMap(nonEmpty) }

/// 後から取る wasm の状態の字（"none" は分けていない束 = Loaded）。
pub def codeStateOfText(text: String): LoadProgress.LoadState = match text {
    case "none" => LoadProgress.LoadState.Loaded
    case other  => loadStateOfText(other)
}

// engine/test/TestLoadProgressDeferredProtocol.flix — go/testdata/webbundle/protocol.json から Go のテストが生成する（手で直さない）
@Test
def testPolicyTextPlaceholderWithoutGroup(): Unit \ Assert =
    Assert.assertEq(expected = { onMissing = Some(LoadProgress.OnMissing.Placeholder), group = None },
                    LoadProgress.Deferred.policyOfText("placeholder\n"))

@Test
def testPolicyTextWaitWithGroup(): Unit \ Assert =
    Assert.assertEq(expected = { onMissing = Some(LoadProgress.OnMissing.Wait), group = Some("start") },
                    LoadProgress.Deferred.policyOfText("wait\nstart"))
```

## 4. 品質の守り方

### 4.1 移した先（Go）

- `withDefaultOnMissing` は §3.3 の表をそのまま Go のテーブル駆動テストにする（9 行・1 行 1 本。「file + wait → 空」を含む）。
- `webWaitsWhenMissing` に「file + wait → 待たない」の 1 本を足す。
- `fillWebDeferredDefaults` は golden `deferred-mixed`・`after-tap` で守る（`kind`・`inFiles`・`names`・`afterTap`・`onMissing` の組み合わせが全部入る）。
- web-check の古い形: golden `format1` を `loadWebBundle` に読ませ、門の答え（`webTapWaitOf` の出力）が今の答えと同じ事を 1 本で確かめる。
- golden の網羅（§3.2 の 3）・Flix のテストの生成（§3.2 の 5）・export-web の format の突き合わせ（§3.2 の表）は Go のテスト 3 本。

### 4.2 JS の core: テーブル駆動テストを headless Chrome で流す

テストハーネスは今の `go/internal/cdp`（自前の CDP。外の依存は無い）を使い、**ブラウザは 1 回だけ起動**し、1 枚の頁で全部のテーブルを流す。

- 頁: Go の `httptest` が `fge-load-core.js`・`core-runner.js`（テストの側にだけ置く小さなテーブルの流し手）・golden の束・テーブルを配る。
- テーブル: `go/testdata/webload/*.cases.json`。1 行は「golden の名前・イベントの列（時刻付き）・最後に聞く問いと答え・返るはずのコマンド」。

```jsonc
{ "name": "取り直す失敗は failed と答え、queued と言わない",
  "bundle": "deferred-mixed",
  "events": [ {"at": 0, "type": "wasmLoaded"}, {"at": 0, "type": "bootAssetsLoaded"},
              {"at": 10, "type": "fetchSettled", "path": "assets/bg/town.png", "gen": 1, "ok": false, "status": 503} ],
  "expect": { "stateTextPrefix": {"town": "failed:"}, "commands": [] } }
```

- 確かめる事（見込み 50〜70 行）: 2 つがそろうまで取り始めない・状態の移り変わり（queued → downloading → downloaded → loaded・released・failed の永久 / 一時）・
  `stateText` の字（全部が protocol.json にある）・`missingText` と `missingGen`・`policyText`（golden ごと）・
  `gen` が古い `fetchSettled` で数も状態も変わらない・取り直しの間（`retryMs` 前は戻さない・後は戻す・online / sweep / visible）・
  裏から戻った時の取りかけの取り直し（新しい順・`running` の数）・`request` の並び・`release` と `arrivedAtRelease`・`markLoaded` の `closeBitmap`・
  `?net=4g` の行が `netGateOpened` まで downloading（音の行は loaded へ・ほかは downloaded へ）・`mainStarting` で時計が始まる `?capture=` の頁・`computeRetryDelay`（5xx と回線は取り直す・408 と 429 も・ほかの 4xx は取り直さない・解けない絵は取り直さない）・
  `shouldRefetchOriginalSound`・ロゴを出す / 出さない / 終える（取る速さ・min / max・飛ばしの 300ms・永久に失敗した行は待たない）。
- 偽にする物: 時刻（イベントの `at`）だけ。fetch は呼ばない（core が返すコマンドを答えと比べる）。
- 今日の必須（取り直す失敗で 20 秒待つ）はテーブルの 1 行目で止まる。

速さの見込み: ブラウザの起動 約 1 秒（測った値）＋ テーブル 70 行の流し 0.2 秒未満 ＋ Go のテストの組み立て ≒ **2 秒**。

### 4.3 JS の shell: 偽の束と偽の wasm で起動を通すシナリオテスト

本物の `fge-web.js`（core とつないだ物）と本物の `index.html`（頭の script ごと）を使い、wasm と回線を偽にする。

- **偽の `wasm-gc-runtime.js`**: `TeaVM.wasmGC.load` が道でも生のバイトでも（`wasmBrotli` の時）受けて `{ exports: { main: … } }` を返す 30 行ほどの物。
  main は `WebLayer.downloadsOf` の使われ方を写した engine のふりをする: 毎コマ `missingGen` を見て `missing` を読み、使う名前を `request` し、
  届いた絵に `markLoaded` を呼び、解いた後回しの files を `release` し、`setLoadWait` を知らせる。答えを `window.fgeTestLog` に積む。Flix を組まないので数秒で回る。
- **偽のサーバー**（Go の `httptest`）: `version.txt` も配る。道ごとに「200・503 を n 回の後に 200・404・遅らせる・途中で切る」を返せる。取った回数を道ごとに数える。
- **シナリオ間で持ち越さない**: シナリオごとに新しい `httptest` のサーバー（port が変わる＝ origin が変わるので localStorage・Service Worker・キャッシュが分かれる）。
  偽の束は `serviceWorker: false`（SW のシナリオは §6 の別の小さなステップ）。`AddInitScript` は新しいタブごとに入れ、タブを閉じれば積み上がらない。
- **cdp の拡張**: 今の `OpenPage` は毎回ブラウザを起動し、1 つのブラウザで新しいタブを開く API が無い。`Target.createTarget` で同じブラウザにタブを足す API と、
  タブを前に出す（`Page.bringToFront`。出さないと rAF が回らない — `page.go` の WhyNot）API を足す（`browserWS` は既にあり、`pageWS` と同じ取り方でタブの ws を引ける）。
- シナリオ（見込み 8 本）:
  1. 後回し無しの束で、押す → main → 起動の画面が外れる
  2. 後回しの絵が 503 を続けた後に届く → engine のふりが `failed:…` を見て、`request` の取り直しで `loaded` を見る（`retryMs` の後）
  3. 404 の後回し → `failed:` のまま取り直さない（取った回数で確かめる）
  4. 後回しのフォント（group 無し）→ `fgeDeferredPolicy` が `placeholder\n`・届いたら素材の表に入る（`inFiles`）
  5. ロゴ: waitFor の group が届くまで出る・届いたら min の後に終わる・押して飛ばせる
  6. `?net=4g`: `arrivalSeconds` まで loaded と言わない（tuning で秒を縮める）
  7. 起動の素材の 1 本が 503 を 3 回 → 4 回目で通って起動する / 4 回とも 503 → エラーの知らせ
  8. `bundle.format` が 1 → 「書き出し直してください」で止まる
- **時間を縮めるフック**: `window.fgeLoadTuning`（`AddInitScript` で入れる）を core が 1 回だけ読む。
  WhyNot: フックを `?query` にしない — 配った頁の URL で誰でも取り直しの間を変えられる。`AddInitScript` はテストハーネスからしか入れられない。
- **偽の wasm の限界**: shell と本物の WebLayer の間の取り違えは、engine のふりに写した分しか守れない。だから release の門には、
  本物の wasm で後回しを待つ書き出し（web-check の `--browser` と tapcheck）を残す。
- 速さの見込み: ブラウザ 1 回 ＋ シナリオごとに新しいタブ（1〜2 秒）≒ **12〜18 秒**。

### 4.4 約束のずれを止める門

| 門 | 何を止めるか | どこで流すか |
|---|---|---|
| `TestWebBundleGolden` | Go の書く形が golden から変わった（`-update` で意図して書き直す） | go-test・precommit（`go/exportweb*` か `go/cmd_exportweb.go` が変わった時） |
| `TestWebBundleGoldenCoversReadFields` | JS が読む欄を足したのに golden が通っていない | 同上 |
| `TestWebExportFormatMatchesCore` | `webBundleFormat` と core の `FGE_BUNDLE_FORMAT` の食い違い | 同上と `engine_web/js/` が変わった時 |
| `TestWebLoadCoreCases`（§4.2） | core が golden を読めない・答えが変わった | precommit（`engine_web/js/` か `go/testdata/webbundle/` か `go/testdata/webload/` が変わった時） |
| `TestWebProtocolFlixTestIsGenerated` | protocol.json と Flix のテストのずれ | go-test・precommit（protocol.json か生成先が変わった時） |
| `TestWebShellScenarios`（§4.3） | shell の配線（core を呼び忘れる・JSBody の名前を変える） | `FGE_WEB_SCENARIOS=1` の時だけ流す（`make go-test` は `go test ./...` を -short 無しで流すので、-short では止まらない）。`webload-shell` の門がこの変数を立てる・release |
| web-check `--browser`・tapcheck（今ある物） | 本物の wasm と shell の取り違え | release |

gates.json には新しい門の id として `webload-core`（約 2 秒・precommit・input は `engine_web/js/`・`go/testdata/webbundle/`・`go/testdata/webload/`）と
`webload-shell`（約 15 秒・manual / release）を足す（今の `go-test` は 1 つの門なので、その下に入れる形ではなく別の id にする）。
103 行あたりのブラウザ版の行の input にも `engine_web/js/` を足し、`bin/fge test-select` が選べるようにする。
この 2 つは engine のリポでだけ打てる口なので、AGENTS.md の「検証」の節に 1 行と `testdata/agent-eval/engine-repo.json` にお題を 1 本足す（ゲームへ配る早見表には入れない）。

### 4.5 pre-commit の秒

| 変えた物 | 流れる物 | 秒 |
|---|---|---|
| `engine_web/js/fge-load-core.js` か `fge-web.js` | webload-core | 約 2 秒 |
| `go/exportweb*.go`・`go/cmd_exportweb.go` | go の main パッケージのテスト（今と同じ）＋ golden | 今＋0.1 秒 |
| `engine/src/platform/LoadProgress/*` か protocol.json | 生成の比べ（Go）＋ Flix の `TestLoadProgressDeferred*`（今の門） | 今＋0.1 秒 |

シナリオテスト（約 15 秒）は precommit に入れない。

### 4.6 ブラウザが無い時・Windows

- `chromeCandidates` の Windows に Edge（`Microsoft\Edge\Application\msedge.exe`・Chromium 系なので CDP がそのまま通る）を足す。Windows の機械にはまず入っているので、goja より安く Windows で流せる。
- 見つからない時は今の `skipWithoutChrome` の流儀どおり飛ばす。ただし `go test` の Skip は `-v` 無しでは見えないので、
  **precommit の側（`bin/fge precommit`）が `webload-core` を選んだ時にブラウザがあるかを先に見て、無ければ「core のテストを飛ばした」を 1 行出す**（緑のまま黙らない）。
- それでも Windows で飛ぶ人が多いと分かったら、§2 の C2（goja）で core のテーブルだけ流す道を足す（core はそのまま goja で読める形に保ってある）。

## 5. ステップの順と見積もり

壊さずに移す順。各ステップの終わりに次の 2 つを確かめる（秒の測りは 1 秒近く揺れるので使わない — P5 の「実装で決めた事」）:

- **bundle.json から決まる見積もり**: 門の `webTapWaitOf` の出力と、web-check の判定が変わらない。
- **頁の記録**: `?net=4g` で開いた時の `window.fgeMissingWaits`・`window.fgeMissingSkips` の中身（名前・kind・why）が変わらない。
  ゲームは 2 本使う。(1) **リポの中の偽のゲーム**（golden の `after-tap` と同じ project.json。最初の場面で後回しを待ち、group と waitFor を持つ）を `templates/` の外の `testdata/web-thin-game/` に置き、`bin/fge export-web` で書き出す — ロゴの道もここで通る。
  (2) インターネットダンジョン（別のリポ・group の無いゲーム。P5 で 0.106.0 で書き出し直した物）を、作業中の engine をつないだ workspace で書き出す（`make engine-upgrade` の前の作業コピーを指す手順を、ステップ 0 で `docs/web-export.md` に 1 行書く）。
  sound-novel-starter は最初の場面が後回しを使わず記録が出ないので使わない。

| ステップ | すること | 確かめ | 実時間 |
|---|---|---|---|
| 0 | テストハーネス: cdp に同じブラウザでタブを足す口・前に出す口・Edge の候補。core のテーブルの流し手・偽の TeaVM・偽のサーバー。今の `fge-web.js` に対してシナリオ 1・2・3・7 を先に書く（今の振る舞いの記録） | 今の JS でシナリオが緑（2 は今日直した後の振る舞い） | 3.5h |
| 1 | `assembleWebBundle` の切り出し。Go が `kind`・`inFiles`・`onMissing` の埋めた値・`afterTap` を書く（`names` と `format` はまだ — `names` を広げると今の JS がさらに `font_` を足して `font_font_x` になり、同じ format 2 の中で `names` が 2 通りになるため）。golden の置き場と 4 本・`-update`。門の `webWaitsWhenMissing` を埋めた値に。web-check の `loadWebBundle` が format 1 を埋めて読む | `exportweb_gate_test` と golden `format1` の答えが同じ・bundle.json の差は足した欄だけ・今の JS のままで記録が同じ | 3.0h |
| 2 | JS が Go の値を読む（`fgeDeferredPrepare`・`fgeDeferredPolicy`・`fgeNoteMissingSkips`・`fgeAfterTapPending` の判断を消す）。同じコミットで Go が `names` を広げ、`format: 2` を書き始める。JS は `format` を確かめる。export-web が `FGE_BUNDLE_FORMAT` を突き合わせる | シナリオ 1〜8 が緑・記録が同じ・後回しの候補の出力（`exportweb_titleassets.go` の `UsedLate` は `e.Names` と照らす）の差は `font_` の名前の分だけ（直る方向） | 1.5h |
| 3 | core を抜く（§3.5 の表の全部）。書き出しが 2 本をつないで配り、`--reuse` の指紋に足す。テーブル 50〜70 行 | テーブルが緑・シナリオが緑・記録が同じ・つないだ js の大きさの差が ±3KB | 5.0h |
| 4 | （**相談の後**）`policyOfText`・`codeStateOfText`・`onMissingOfText` を engine の `LoadProgress.Deferred` へ。protocol.json と Flix のテストの生成 | `make test-engine` の該当・`make sync-engine-full-web` が通る | 1.5h |
| 5 | 門の配線（gates.json・test-select・precommit の「飛ばした」の 1 行）・`docs/web-export.md` に core と約束の節・AGENTS.md の検証の節に 1 行とお題 1 本 | `make verify SUITE=affected` が新しい門を選ぶ・engine-repo のお題が当たる | 1.5h |
| — | レビュー（ステップ 1 の後・ステップ 3 の後・出す前の 3 回）と直し | | 2.5h |
| | **合計** | | **約 18.5 時間** |

見積もりの根拠: P4 の頁と go のステップ（S3〜S5: 後回しの API・`?net=4g`・ロゴ）を 7〜9 時間と見積もった（見積もりの数で、実績ではない）。この計画はそれと同じ範囲の JS を全部読み替え、テストハーネスと golden の仕組みを新しく作るので、その 2 倍ほどと見た。

ステップ 0 で今の振る舞いを先にシナリオとして書き留めるので、ステップ 2・3 で振る舞いが変わればそこで赤になる。
ステップ 1 は今の JS が新しい欄を読まないので、ステップ 1 だけ入れても頁は今と同じに動く。ステップ 2 から `format: 2` を要る。

## 6. やらない事

- **GL・WebGPU・入力・音・関数名の JS は動かさない**。wasm が JSBody で呼ぶ実行で、判断ではない。行数で言えば JS の約 8 割は残る。「2 千行を細くする」は「判断を core と Go に集める」の意味で、行数を減らす事は目当てにしない。
- **軽い判断は core に入れない**: 起動の画面を外す 4 条件・SW を登録する 3 条件・起動の棒の割り算・縦の design の式。テーブル駆動テストより API の方が大きくなる。
- **起動の画面の寸法の式（Splash.flix の写し）と縦の design の式（`ProjectLoader.portraitDesignOf` の写し）を 1 つにしない**。押す前は wasm の main が動かないので JS で描くしかない。ずれの守りは別の計画（押す前の頁の絵と、wasm の起動の画面の絵を並べて比べる描き出し、または同じ入出力のテーブルを Flix と JS の両方に置く）。
- **案 B（wasm の中へ移す）は今は採らない**。理由は §2 の 3 つ（太り・export のスパイク・取り直しが 2 か所に割れる）。core の形のまま置くので、後で進む時の答えは残る。
- **TypeScript・JSON Schema は入れない**。node も tsc も devbox に無く、型の正を 2 つ持つ事になる。正は Go の struct、写しの守りは golden とテーブルで行う。
- **goja は今は入れない**（§4.6 の条件が出たら入れる）。
- **取り直しの数（4 回・500ms×n²・5 秒・30 秒・2 秒）を bundle.json へ出さない**。ゲームごとに変える値ではなく、Doc の流儀の「外に出す物」に当たらない。core の既定として 1 か所に置き、テストの時だけ `fgeLoadTuning` で縮める。
- **`fge-sw.js` と `index.html` の頭の script はこの計画で形を変えない**。判断は濃いが、後回しと既定の散らばりとは別の話。テストハーネスができた後に、SW の 3 シナリオ（登録・2 回目の起動がキャッシュから・版を上げた時に古い版を消す）を足す別の小さなステップにする（見込み 2 時間）。
- **JSBody の名前と字を変えない**（ステップ 4 で Flix の側の読みを engine へ移すだけ）。wasm を組み直さずにステップ 0〜3 を進められる。

## 人に決めてもらう事

1. ステップ 4（`policyOfText`・`codeStateOfText`・`onMissingOfText` を engine の `LoadProgress.Deferred` の pub にする）は engine の変更。入れてよいか。入れない時は WebLayer に残し、生成する Flix のテストは置けない（engine_web にテストの置き場が無い）ので、字の約束は core のテーブルだけで守る。
2. シナリオテスト（約 15 秒）は precommit に入れず manual / release にする案でよいか。
3. cdp の拡張（同じブラウザでタブを足す・Edge を候補に）は go の中の変更で engine の Flix には触らない。このまま進めてよいか。

## レビューの反映（1 稿 74 点への指摘）

| 指摘 | 直した所 |
|---|---|
| M1 files の wait を門が数える | §3.3 で file はいつも空に埋める・`webWaitsWhenMissing` に `Kind != "file"`・§4.1 にテスト 1 本 |
| M2 web-check は古い束を Go で読む | §3.2 に読み手ごとの古い形の表。`loadWebBundle` が format 1 を埋めて読む・golden `format1` |
| M3 `alsoFile` でフォントが表に入らない | 欄を `inFiles`（全部の kind）に。シナリオ 4 と golden に入れた |
| M4 案 B の前提の誤り | §1 に「wasm の前 / main の前」を分けた。§2 案 B を「instance はある・足りないのは main の前の入口」に直し、退ける理由を 3 つに絞った |
| M5 core のイベントの不足 | §3.5 にイベント・コマンド・問いの表を置き、JSBody 12 本と JS の呼び手を全部当てた |
| R1 `net4gSeconds` | やめた。残りの秒は core が動いてから求める |
| R2 afterTap が nil / none | `fillWebDeferredDefaults` が `b.Splash.AfterTap` を見て nil・none を扱う |
| R3 段 1 で names が二重 | `names` の広げをステップ 2 へ |
| R4 cdp のタブ・持ち越し | §4.3 に cdp の拡張とシナリオ間の分け方。ステップ 0 を 3.5h に |
| R5 偽の wasm の限界 | §4.3 に engine のふりの写し元・道とバイトの両方・version.txt・本物の wasm の門を残す |
| R6 秒の確かめは揺れる | §5 の確かめを見積もりと記録の中身に・ゲームをインターネットダンジョンに |
| R7 golden の流儀 | 新しく作る置き場と書いた・網羅は JS が読む欄に絞った・変換を通さない |
| R8 字を探す検査が弱い | Flix のテストを生成して比べる形に |
| R9 format の食い違い | export-web が core の `FGE_BUNDLE_FORMAT` を読んで止める |
| R10 指紋と gates.json | §3.4 と §4.4 |
| R11 「4 か所を 1 つに」 | §0 で「Go の 1 か所と Flix の 1 か所」に |
| R12 薄い判断の API | §2・§6 で core から外した |
| R13 Edge | §4.6 |
| R14 見積もり | 18.5h に・根拠を 1 行 |
| O1〜O5 | 棚卸しの行の区切り・JSON の例・写しの守りの行き先・Skip の見え方・gates.json の id |
| 言葉づかい | イベント・コマンド・テストハーネス・golden ファイル・シナリオテスト・テーブル駆動テスト・ステップ・移す に。関数名を `decideAfterTap`・`fgeMakeLoadCore`・`stateText`・`missingText`・`policyText`・`withDefaultOnMissing`・`fillWebDeferredDefaults` に |

## レビューの反映（2 稿 88 点・必須なしへの推奨と任意）

| 指摘 | 直した所 |
|---|---|
| P1 1 本の取り直しは core を作る前にも要る | §3.5 に「core の instance の外の純粋な関数」の表（top-level・bundle 不要） |
| P2 4G の時計は main の直前にも始まる | §3.5 に `mainStarting`。時計の前に取り終えた行の `openNetGate` をまとめて返す |
| P3 音の行の netGateOpened の行き先 | 音は loaded・ほかは downloaded と書き、テーブルの確かめに足した |
| P4 golden の流れでフォントと afterTap が出ない | `assembleWebBundle` を切り出して書き出しと golden が呼ぶ（ステップ 1）。out に素材を写す |
| P5 -short が効かない | `FGE_WEB_SCENARIOS=1` の時だけ流す |
| P6 インターネットダンジョンだけでは足りない | リポの中の偽のゲーム（group・waitFor あり）を足し、2 本で確かめる。書き出しの手順も 1 行 |
| O1 Flix のテストの形 | `Unit \ Assert` の形に・今の字の表は生成した側に寄せて消す |
| O2 Go の 3 つ目の種類の見分け | §0 に足した・ステップ 2 の確かめに候補の出力の差 |
| O3 tapped に載せる物 | `tapped {captured, seen}` |
| O4 format を書く時 | ステップ 2 へ |
| O5 protocol の照らし方 | onMissing の欄と `failed:` の頭だけ |
| O6 言葉づかい | 「の口」を API に・「段」をステップに・fps の表示の時 |

## 決めた事（11-21・人が「おすすめで」）

- 人に決めてもらう事の 3 つ: (1) `LoadProgress.Deferred` の文字列を読む 3 関数を pub にする（する）。(2) 偽の wasm のシナリオのテストはリリースの時だけ（そうする）。(3) cdp の拡張（タブ・Windows の Edge）は要るまで足さない。
- 目標は「JS にはブラウザの API を叩く副作用だけ」。スパイク（枝 worktree-agent-a521e4553d9b58e47・a68a01cc）の数字で寄せ先を組み合わせにする:
  - wasm が届いた後の判断（後回し・押した後のロゴ・待ち）は本体の wasm の Flix へ（brotli 後 +12 KB・4G +0.06 秒・1 回の問い 0.4 µs・200 個で 0.06 ms／CPU 4 倍で 0.25 ms・main の前でも呼べた）。
  - 起動の前の段と SW は案 A の小さな JS core のまま（1.8〜2.3 KB）。
  - 外した案: Go（490 KB・7.7 µs）・TinyGo syscall/js（27 µs）。TinyGo //export（29 KB・0.8 µs）は 3 つ目の言語になるので、起動前の段を wasm にする時は Flix の別 wasm（68 KB）を先に測る。
  - Flix へ寄せるには engine の構造の変更が要る（WebLayer に入口・fge.web の口・BuildWasm の入口。Flix 0.80 に @Export が無く、入口から届かない def は落ちる）→ 入れる前に相談。
- 起動前の段のスパイク（11-21・枝 worktree-agent-a93612780e739a3d6・cfaba454）: 4G・rpg-starter の本物の束で「タッチして開始」まで JS 8.71 秒／TinyGo（頁に埋める）8.83／TinyGo（別ファイル 19 KB）8.96／Flix（頁に埋める）8.98／Flix（別 41 KB）9.03。判断の wasm が届くまで preload を出せない分だけ遅れる。2 回目は ±30 ms。SW を起こすたびの上乗せは TinyGo +1.5 ms・Flix +6 ms。→ 起動前の段と SW は JS の core のまま。TinyGo は devbox から外した（5cd70ceb）。
