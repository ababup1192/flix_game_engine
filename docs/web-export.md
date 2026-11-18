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

- 強さは project.json の `web.compress`: `audioBitrateKbps`・`uncompressedAudio: [glob]`・`lossyImages: [{glob, quality}]`・`audio` / `images` を false で止める
- 道具は ffmpeg（libopus）と cwebp・dwebp。無ければ圧縮せずに書き出して大きさの表に 1 行

## シナリオを開発者ツールから読まれにくくする（`web.embed`・`web.omit`）

- `web.embed: [glob]`（例 `assets/talk/dialogue.json`）を `bin/fge export-web` が圧縮・符号にして wasm へ埋め込み、ばらのファイルとしては配らない（読む側の `Yarn.loadOr` などは変えない）
- 実行時に読まない元のファイルは `web.omit: [glob]`（例 `assets/talk/*.yarn`）で外す
- 書き出しの最後に平文が書き出し先に残っていないかを見て、残れば止まる
- 鍵も wasm に入るので、wasm を解析する人には読める
