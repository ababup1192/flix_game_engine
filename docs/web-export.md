# ブラウザ版の書き出し（`bin/fge export-web`）

ゲームをブラウザ（PC の Chrome・スマホのブラウザ）で遊べる形に書き出す口と、project.json の `web` の欄。
起動の画面・素材を後から取る（`web.deferred`）・画面のスティック・指の操作（`web.touchGestures`）は [startup.md](startup.md)、
デスクトップと絵が食い違う所は [backend-parity.md](backend-parity.md) の「ブラウザ（WebGL2）とデスクトップの絵」、書き出した頁を撮るのは [web-capture.md](web-capture.md)。

## 書き出す

- ゲームに `web/WebMain.flix` を置く: `mod WebMain` の `pub def main` で、Main と同じ App を `App.launchWithDevTools(App.DevTools.none(), app)` で、
  `with WebLayer.withProject(".") with WebFs.runFileRead with WebFs.runFileWrite` の上に起こす（rpg-starter の物が写経元）
- `bin/fge export-web <ゲーム>`: 出力は `<ゲーム>/build/web`。静的なサーバーで配る。セーブは localStorage。型検査だけは `--check`
- TeaVM の JSO は `fge.web` の外へ出さない（lint `teavm-jso-outside-fge-web`）
- 書き出しの最後にヘッドレスの Chrome で頁を開き、wasm の compile と最初の数コマで止まれば exit 1（TeaVM は通るのに真っ白になる形を止める）。
  JSO を `Object` を受ける所へ渡さず Java の類に包む。Chrome が無ければ知らせて飛ばす。飛ばすなら `--no-browser-check`（門の中身は [web-capture.md](web-capture.md) の「書き出しの門」）

### engine の作業場で書き出す時

- 先に `make sync-engine-full-web`
- engine の束は中身のハッシュ付きの置き場 `build/fpkg-store/<名前>-<版>-<ハッシュ>/` にある（`make sync-engine-full`・`sync-engine-full-web` が入れる）。
  エントリは置いた後は変わらないので、作り直しの最中も build と export-web は壊れない。掃除は `make fpkg-store-gc`
- engine を作り直した後、版の番号が同じままゲームの束（lib の fpkg と packages.lock の sha）を新しくするのは `make engine-upgrade`
  （版が同じでも中身のハッシュが違えば入れ替えて 1 行言い、packages.lock の sha もそろえる。lib の fpkg や packages.lock を手で替えない）

## フォントアトラスを前もって作る（`bin/fge font-bake`）

`bin/fge font-bake <ゲーム> <出力>` は、yarn・Doc の値・src の文字列リテラルの字を集め、デスクトップと同じアトラスを `<出力>/<fonts[].name>.fontatlas` と `fonts.json` に書く。
どのフォントにも無い字は字と出所（ファイル:行）を出して 1 で止まる（ブラウザで字が出ないのを書き出しの前に止める）。
生成するだけなら Flix から `FontAtlasBake.bakeProject`。字を手で数えて無い字を探さない。

## URL から決まった場面・台本の行で開く

`web/WebMain.flix` で `App.launchWithDevTools(WebLayer.devTools(), app)` にする。

- クエリの最初の鍵が Start の名前で、その鍵と値も含めた全部が引数（`?talk=Lair&line=46` は `start talk talk=Lair line=46`・値の空白や改行もそのまま届く）
- 頁が使う鍵（`input` `size` `orientation` `glcheck` `loadtime` `capture` `fps`）は外す（`App.DevTools.pageQueryKeys`）
- クエリが無ければ先頭の始まり。知らない名前や組めない引数は止めずに先頭の始まりで開いて console.error に 1 行
- 読み方だけの純粋な口は `App.DevTools.startOfQuery`

## スマホで遊べるようにする（十字キー・ボタン・指）

project.json の `web`（`keysDoc`・`virtualPad: { dpad: true, buttons: [{label, action}] }`・`touchGestures: { longPress, swipeLeft, swipeRight, swipeUp, swipeDown }`・`orientation`）を
`bin/fge export-web` が解く（操作の名前はキーの Doc の名前・手本 rpg-starter と sound-novel-starter）。スティックは [startup.md](startup.md) の「ブラウザ版の画面のスティック」。

ゲームの側はキーとクリックのまま。canvas の指は次のように読み替わる:

| 指 | 届く物 |
|---|---|
| タップ | 離した時のクリック |
| 縦のドラッグ | ホイール |
| 横のドラッグ | 横と決まった所で左ボタンを押し、指に付いて動かす（`mouseDown` と `cursor`） |
| 長押し | 動かさずに置いてから離した時 |
| 縦の払い | 離した時に swipeUp / swipeDown のキーも出す（ホイールは出したまま） |

### 長押しを Esc（戻るのキー）と取り違えない

キーの Doc に指の長押しだけの操作（例 `touchHold` = `["Menu"]`。ほかの操作と重ねず、キーボードでまず押さないキー）を足し、`web.touchGestures.longPress` をその操作の名前にする。
ゲームは `App.justPressed` でそのキーを読み、押した所は `frame#cursor`（手本 sound-novel-starter の `Rail.judge`）。
`longPress` を戻るのキーにすると、押しの出ていないフレームのキーボードの Esc も指の長押しとして読まれる。

## スマホの時だけ字とボタンを大きくする（`Display.SizeClass`）

- View は `ctx#display#sizeClass == Display.SizeClass.Small`（`ViewCtx#display` に画面の大きさ・`designScale`・最後の pointer も）
- 当たりを取る系は同じ並べ方を `frame#sizeClass` から引く（World の結果を区分で変えない）
- 大きさは Doc に出す（手本 sound-novel-starter の `novel.small.json`・`Layout.Fit`）
- PC から確かめるのは、描き出しの ctx を `{ display = { sizeClass = Display.SizeClass.Small | ctx#display } | ctx }` にするか、ブラウザ版の頁を `?size=small&input=touch` で開く

## 縦の画面で起動する（`web.portraitDesign`）

project.json の `web.portraitDesign: { "width": 540, "minHeight": 960 }` で、スマホ（区分 Small）を縦に持ってブラウザで開いた時だけ、幅を固定・高さは描き先の比から決めた縦の design で起動する（`orientation` は `any`）。

- View は `ViewCtx#display#orientation`（起動の時の design の向き）と `ViewCtx#visible#size`、当たりは `Display.orientationOf(frame#viewport)` と `frame#viewport` から同じ並べ方を引く
- 確かめ方: PC では頁の `?orientation=portrait`、デスクトップは `FLIX_GE_PORTRAIT=1`、画面なしの描き出しは `Display.phonePortrait(view, design)` と `ProjectLoader.portraitConfigOf`（手本 sound-novel-starter の `portrait-<場面>`）

### 窓の余り（レターボックス・ピラーボックス）を背景で塗る

窓の比が design と違う時の余り（PC の横長の窓に縦の design を出した時の左右など）を、黒でなく背景で塗るのは `App.withLetterboxView((ctx, w) -> 絵)`。
design の大きさの画面に描くつもりの絵（ぼかした背景だけ）を返すと、engine がそれを Pass（`fge_letterbox`）に描き、縦横比を保って窓いっぱいに広げて余りにだけ見せる。

- GL・WebGPU・ブラウザとも同じ。design の中・HUD・デバッグの重ねは今まで通り
- 余りの無いコマ・画面なしの描き出し・テストでは呼ばれない
- 手本は sound-novel-starter の View の letterbox

## 書き出しを小さくする（`web.compress`）

`bin/fge export-web` は書き出し先の中だけで、png → WebP（既定は劣化なし）・wav → Opus・アトラス → 画素だけ劣化なしの WebP（戻してバイト一致を確かめた時だけ・ほかは gzip）に替える（assets/ とデスクトップは変わらない）。

- 強さは project.json の `web.compress`: `audioBitrateKbps`・`uncompressedAudio: [glob]`・`lossyImages: [{glob, quality}]`・`fontAtlasScale`・`wasmBrotli`・`audio` / `images` を false で止める
- 道具は ffmpeg（libopus）と cwebp・dwebp。無ければ圧縮せずに書き出して大きさの表に 1 行
- アトラスの距離場は既定で辺を 1/2 に縮める（`fontAtlasScale: 0.5`・量は約半分・スマホの画面で見分けがつかない）。1 で縮めない。0.5 より下は込んだ漢字の縁が欠けるので受け付けない
- wasm は brotli（最も強い 11）にした `classes.wasm.br` と解き手 `brotli-decode.js`（google/brotli・MIT）を一緒に配り、頁が自分で戻す（gzip より 4 割ほど小さい・置き場が gzip しか配らなくても効く）。解けない時は `classes.wasm` を取る。道具は brotli（無ければ gzip のまま配って知らせる）。止めるのは `wasmBrotli: false`
- wasm の名前の区画（関数名・素の量の 2〜3 割）は `classes.names` へ抜いて配る。頁は止まった時だけそれを取り、stack の `wasm-function[番号]` に名前を付けて console へ出す

### 遊べるまでの量を見る

書き出しの終わりの表に、押して始めるまでに取る物（起動の素材と wasm）の回線の量と、4G（1.6 Mbps・往復 150 ms）での秒数の見積もりが出る。16 秒を超えると知らせる（止めない）。後回し（`web.deferred`）の 1 本ずつが何秒目に届くかは書き出しのログに出る。

```
  起動まで（タッチして開始まで）43 本・回線 2.9 MB（wasm 2.0 MB・素材 0.9 MB・頁 0.04 MB）→ 4G（1.6 Mbps）で約 16.0 秒（前置き 1.5 秒を含む）
```

減らすのは、タイトルより後で使う絵・音を `web.deferred` へ、タイトルで使わないフォントを `web.deferredFonts` へ回すのが先（アトラスは `fontAtlasScale` の既定 0.5 で縮めてある）。頁は進みの棒をこの量の重みで動かし、wasm まで読み終えてから「タッチして開始」を出す。

## シナリオを開発者ツールから読まれにくくする（`web.embed`・`web.omit`）

- `web.embed: [glob]`（例 `assets/talk/dialogue.json`）を `bin/fge export-web` が圧縮・符号にして wasm へ埋め込み、ばらのファイルとしては配らない（読む側の `Yarn.loadOr` などは変えない）
- 実行時に読まない元のファイルは `web.omit: [glob]`（例 `assets/talk/*.yarn`）で外す
- 書き出しの最後に平文が書き出し先に残っていないかを見て、残れば止まる
- 鍵も wasm に入るので、wasm を解析する人には読める

## GitHub Pages に出す（`make web-pages-stage`）

ゲームの足元で `make web-pages-stage DEST=<サブフォルダ>`。gh-pages の枝の `<DEST>/` に置いてコミットするまでで、push は人が打つ（最後に 1 行出る）。
手で gh-pages の worktree を作って写さない。中でやる事:

1. 書き出し: `build/web-pages` を消して `bin/fge export-web` で作り直す（手元で曲を足した `build/web` の残りを公開へ回さない）。
   書き出し済みのフォルダを置くなら `SRC=<フォルダ>`（写し方を変えた書き出し。手本は `bench/hd2d_town` の `make explore-pages`）
2. 音の検査: 音のファイル（ogg・mp3・wav・opus・webm…）・`bundle.json` の `sounds`・`deferred` の音が 1 本でもあれば止める。
   外から持ってきた BGM・効果音は配る許しが要る物が多い（[audio.md](audio.md)）。自分で作った音・許しのある素材だけなら `AUDIO=ok`
3. gh-pages の worktree: その枝の worktree があれば使い、無ければ `<ゲーム>/build/gh-pages` に作る（枝が無ければ何も無い枝として作る）。
   未コミットの変更がある worktree には置かない。`.nojekyll` を置く（Jekyll は `_` で始まるファイルを配らない）
4. コミット: `pages: <DEST> に <ゲーム> の書き出しを置く（ゲーム <commit>・engine <版>）`。中身が前と同じならコミットしない
5. 開けるかの確かめ: 置いた頁を `<DEST>/index.html?capture=3` の道でヘッドレスの Chrome に開かせる（サブフォルダの道で素材を取れない形を止める）。飛ばすなら `NO_BROWSER_CHECK=1`
6. 最後に出る物: 手元で配るコマンド（`bin/py3 -m http.server 8000 --bind 0.0.0.0 --directory <worktree>`）と PC・スマホで開く URL・`git -C <worktree> push origin gh-pages`・公開後の URL

- 枝や worktree を替えるのは `BRANCH=`・`PAGES_WT=`。gh-pages の根の `index.html`（頁の一覧）は手で直す
- 手元で配ったサーバーは見終えたら Ctrl-C で止める（残った物は `make strays` で見つかる）
- Windows では流せない（bash の道具）

## ブラウザで重さを測る

### 頁の旗（どのゲームの書き出しでも同じに使える）

`bin/fge export-web` の頁（`engine_web/js/fge-web.js`）が読む物。テンプレート（rpg-starter・sound-novel-starter）でも bench でも同じに使える。

| 旗 | 出る物 |
|---|---|
| `?fps=1` | 左上に fps・CPU の ms（中央値）・描き手（`webgpu` / `webgl2`） |
| `?backend=webgl2` | WebGPU を使わず WebGL2 で描く（既定は WebGPU。取れなければ WebGL2 に落ちるので、`?fps=1` の描き手の欄で確かめる） |
| `?glcheck=1` | GL の呼び出しごとに `getError` を見て console に出す（WebGL2 の時） |
| `?loadtime=1` | 絵の解読の時間と、最初のコマまでの ms を console に出す |
| `?capture=<n>` | dt を 1/60 に固定し、n コマ目を撮る合図を出す（[web-capture.md](web-capture.md)） |
| `?size=small&input=touch`・`?orientation=portrait` | スマホの区分・指の入力・縦の design で開く（上の節） |

`WebLayer.devTools()` で起こすゲームは、ここに無い鍵をクエリの最初に置くと Start の名前として読む（知らない名前なら先頭の始まりで開いて console.error に 1 行）。
ゲームの側の旗を足す時は、Start の名前と重ねない。

### ゲームごとの旗（engine の物ではない）

`bench/hd2d_town` の `?debug=1`（CPU と GPU の時間・draw の数の HUD）・`?shadow=<画素>`・`?dof=0`・`?post=0`（描き方の重さの差し替え。`web/WebMain.flix`）・
`?dpr=<数>`・`?measure=1`（押せるまでと最初のコマまでの時間。`make explore-web` が差し込む `web/measure.js`）は、そのゲームが自分で読んでいる。
ほかのゲームで同じ物が要るなら、そのゲームの `web/WebMain.flix` で読む（draw の数を画面に出すのは `App.withDiagnostics` と `FrameDiagnostics.summaryLines`。[performance.md](performance.md) の §11）。

### 読み方と比べ方

- **GPU の時間はブラウザでは出ない**: WebGPU の描き手は GPU の時間を測っていない（`frame#diagnostics` の `gpuNs` は None）。WebGL2 でも query を作れない。
  見るのは fps と CPU の ms。GPU の重さを詰めるのはデスクトップの GL の `gpuNs` で
- **draw の内訳**: `draw2dCounts`・`scene3dCounts#batchBreaks` の読み方は [performance.md](performance.md) の「draw call がまとまらない時の読み方」。ブラウザでも同じ数が出る
- **前と後は同じ場所・同じ向き・同じ旗で比べる**: 町の広場と路地のように描く物の量が違う所どうしを並べると、ブラウザとデスクトップの差に見えてしまう。
  開始の場所を URL か Start の名前で決めて、同じ所から測る（デスクトップとの比べも同じ場所で）
- **ヘッドレスの Chrome で数を取る**のは `make bench-web BENCH=<名前>`（bench の頁だけ）。スマホの数の代わりにはならない
- **スマホは人に URL を開いてもらうしかない**: 同じ Wi-Fi で `http://<この機械の IP>:8000/<道>/?fps=1`（上の `make web-pages-stage` の最後の行）か、公開した URL を渡して、
  左上の fps と CPU の ms を読んでもらう（何秒か置いてからの値）。機種と OS の版も聞く
