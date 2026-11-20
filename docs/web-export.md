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

### 作業フォルダとホームのパスを wasm に残さない

Flix はゲームの .flix の位置（`bug!`・match の網羅漏れ・`???` で出す位置）を、書き出しの作業フォルダの絶対パスのまま定数に残す。
`bin/fge export-web` は TeaVM に渡す前の jar で、絶対パスで始まり `/project/src/`・`/project/test/`（Windows は `\` の形）の後に続いて `.flix` で終わる位置を `game/...` の形へ置き換える（`--work` を渡しても・Windows でも同じ）。

- その後 jar の定数プールと、wasm（`classes.wasm`・`classes.names`）の 2 回、`/Users/<名前>/`・`/home/<名前>/`・`C:\Users\<名前>\`・`C:/Users/<名前>/` の形と、手元の `$HOME`・作業フォルダ・ゲームの絶対パスを探す。残っていれば書き出し先に何も置かずに止まる（exit 1）
- 止まった時に出るのは件数と場所（`jar` / `wasm` / `names`）だけ。残った字は `--show-leaks` を付けた時だけ手元の画面に出る（ログを人や CI に貼っても名前が広がらない）
- 「次:」の行は 2 通り: `.flix` の位置が残ったなら置き換えの漏れなので engine に報告する（ゲームの側で避ける手は要らない）。それ以外はゲームのコードか素材の字に絶対パスが書いてあるので、ゲームの根からの相対の道に直す
- 止まった時の console の位置は `game/src/<ファイル>.flix` で読める。engine の位置は前から `flix_game_engine-<版>.fpkg:src/...` の形
- デスクトップの配布（`make dist-*`）の jar は置き換えない（利用者の手元で動き、例外の stack にもともとパスが出る作り）

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

`bin/fge export-web` は書き出し先の中だけで、png → WebP（写真寄りの絵は劣化あり・ほかは劣化なし）・wav → Opus・アトラス → 画素だけ劣化なしの WebP（戻してバイト一致を確かめた時だけ・ほかは gzip）に替える（assets/ とデスクトップは変わらない）。

- 強さは project.json の `web.compress`: `audioBitrateKbps`・`uncompressedAudio: [glob]`・`lossyImages: [{glob, quality}]`・`losslessImages: [{glob, why}]`・`fontAtlasScale`・`wasmBrotli`・`audio` / `images` を false で止める
- 道具は ffmpeg（libopus）と cwebp・dwebp。無ければ圧縮せずに書き出して大きさの表に 1 行
- アトラスの距離場は既定で辺を 1/2 に縮める（`fontAtlasScale: 0.5`・量は約半分・スマホの画面で見分けがつかない）。1 で縮めない。0.5 より下は込んだ漢字の縁が欠けるので受け付けない
- wasm は brotli（最も強い 11）にした `classes.wasm.br` と解き手 `brotli-decode.js`（google/brotli・MIT）を一緒に配り、頁が自分で戻す（gzip より 4 割ほど小さい・置き場が gzip しか配らなくても効く）。解けない時は `classes.wasm` を取る。道具は brotli。止めるのは `wasmBrotli: false`
  - brotli は PATH → engine の devbox → Homebrew と nix の profile の bin → nix の store（`/nix/store/*-brotli-<版>/bin/brotli` の版の新しい物）の順に探す。Finder から開いた Studio のように PATH が細くても、手で PATH を足さずに見つかる。
  - どこにも無い時は gzip のまま配り、`★ wasm を brotli にできず …4G（1.6 Mbps）で起動が約 N 秒遅くなる` を書き出しの途中と終わりの両方に出す（止めない）。
- wasm の名前の区画（関数名・素の量の 2〜3 割）は `classes.names` へ抜いて配る。頁は止まった時だけそれを取り、stack の `wasm-function[番号]` に名前を付けて console へ出す

### 写真寄りの絵は既定で lossy（`losslessImages`）

何も書かなくても、写真・塗りの絵・3D から撮った絵のような png は劣化ありの WebP（画質 90）にする。lossless のままだと起動の量の大半を絵が占める（インターネットダンジョンは絵 154 枚のうち塗りの絵 135 枚を lossy にした分が、4G の 58.9 → 22.0 秒の大半）。

**判定**（数は `bin/lint-rules/export-web.json` の `autoLossy`）: 次の全部に当たる png
1. lossless の WebP にした大きさが 48 KB 以上（小さい絵は lossy にしても秒がほとんど減らず、崩れる危うさだけが残る）
2. `lossyImages` にも `losslessImages` にも当たらない
3. 不透明な画素（α が 224 以上）だけで数えた色が 1,024 色を超える。ドット絵（パレットで数十〜数百色）・字や線・単色の UI（地と字の色とその間の中間色で数百色）はここで外れる。写真・塗り・3D の絵はグラデーションとノイズで数千色を超える
4. データとして読む絵でない: 名前に `normal` `_n.` `height` `mask` `lut` `ramp` を含む物（部分一致。`abnormal` `trampoline` も外れるが、外れる向きは lossless のままなので崩れない）と、assets/ の下の JSON の ShaderDoc が `tex` `blur` `texSize` で読むテクスチャ（シェーダーが値を読むので、見た目の差が小さくても結果が変わる）。.flix のコードで組んだ ShaderDoc は読めないので、名前の形か `losslessImages` で外す

透明の多い絵（不透明が 8 割未満・立ち絵など）も lossy にする。cwebp の lossy の α は劣化なしで、`-exact` で透明の所の色も残す。

| 書いてある物 | 扱い |
|---|---|
| `lossyImages` に当たる絵 | 書いた quality で lossy（既定の判定より先。`losslessImages` にも当たっても lossy） |
| `losslessImages` に当たる絵 | lossless。`why`（理由 1 行）は必須。当たる png の無い glob と、当たる png が全部 `lossyImages` にも当たる glob は誤りで、組む前に止まる |
| どちらにも当たらない png | 上の判定で、写真寄りなら画質 90 の lossy・ほかは lossless |
| jpg | 今まで通り（`lossyImages` に当たる物だけ WebP にする） |

**書き出しの表に毎回出る物**:
```
  絵: 既定で lossy にした 135 枚（2.1 MB → 0.6 MB）・うち透明の多い絵 16 枚
      色数の少なかった 3 枚: assets/ui/frame.png（1,180 色）・...
      崩したくない物は "losslessImages": [{ "glob": "...", "why": "..." }]・見比べは bin/fge web-image-diff
```
- 色数の少なかった絵ほど、字・線・UI を取り違えた危うさが高い。名前が出たら一度 `web-image-diff` で見る
- `losslessImages` に当たった写真寄りの絵は枚数・量・4G の秒を、シェーダーが読む絵で外した物は名前を出す
- `lossyImages` の glob が消しても配る絵の変わらない物（画質 90 で写真寄りの png だけに当たる・当たる絵が全部前の glob に取られている）なら「消しても配る絵が変わらない」と知らせる（消さなくてもよい）
- 1 つの `losslessImages` の glob が png の 6 割以上に当たる時（png が 5 枚以上）は知らせる。全部を lossless にして既定を外す形になっている
- 1 枚ずつの色数・不透明の割合・大きさは書き出しのログ（`[export-web]   既定で lossy …`）。書き出しの report のファイルはまだ無い（起動の秒の予算の門と一緒に入る）
- 前の書き出し（同じ `--out` の `bundle.json`）で lossless だった絵（WebP が VP8L の物と、png のまま配った物）を lossy に替えた時だけ、`★ 前の書き出しでは lossless だった絵 N 枚を既定で lossy にした` を 1 回出す。前の書き出しが無い `--out` では出ない

**見比べ**: `bin/fge web-image-diff <ゲーム> [--out <png>] [--limit 12] [--explicit]` が、同じ判定で詰めた絵の元・lossy・差（8 倍に強めた、α を掛けた色の差）を 1 枚ずつ横に並べた PNG を書く（色数の少ない順・真ん中の 320 画素四方を 1:1 で切り出す）。`--explicit` は `lossyImages` で明示した絵も並べる。画素の差の門（reference の SHA256SUMS・gl-capture）はデスクトップの描き出しを見ていて、ブラウザの書き出しの絵を見ない。判定の誤りは人がこれで見るまで気づかない。

**古い engine**: `web.compress` の読み手は知らない鍵で止まる。`losslessImages` を書いた project.json は 0.104.0 以前の `bin/fge export-web` では止まる（engine を上げてから書く）。

### 動く時に読まない形は配らない（`web.keep`）

`bin/fge export-web` は assets/ の下の `*.schema.json`（Studio とエディタだけが読む）と制作の元ファイル（`.blend` `.blend1` `.psd` `.kra` `.aseprite` `.ase` `.xcf`）を既定で束から外し、表に `外した` の 1 行を出す。

- ゲームが動く時に読むなら `web.keep: [glob]`（例 `"keep": ["assets/editor.schema.json"]`）で戻す。当たるファイルの無い glob は誤り
- `.md`・`.txt` は外さず、束に入れた本数と量を `知らせ:` の 1 行で出すだけ（字の一覧・クレジット・台本を .txt で読むゲームがあり、起動の確かめはタイトルまでしか見ないので、外して壊れても気づけない）。読まない物は `web.omit` へ
- 前からある `web.omit: ["assets/*.schema.json"]` は重なっても誤りにならない（消してよい）

### 遊べるまでの量を見る

書き出しの終わりの表に、押して始めるまでに取る物（起動の素材と wasm）の回線の量と、4G（1.6 Mbps・往復 150 ms）での秒数の見積もりが出る。予算と比べて止めるのは下の「起動の予算」。後回し（`web.deferred`）の 1 本ずつが何秒目に届くかは書き出しのログに出る。

```
  起動まで（タッチして開始まで）43 本・回線 2.9 MB（wasm 2.0 MB・素材 0.9 MB・頁 0.04 MB）→ 4G（1.6 Mbps）で約 16.0 秒（前置き 1.5 秒を含む）
```

もう 1 本の数字が、開いてすぐ押した人が**押してから最初の場面が動くまで**待つ秒の見積もり（人の要件: ローディングを飛ばした先で待たせない）。
後回しは「タッチして開始」の頃から列の順に取るとして、押した後のロゴが待つ group（`web.splash.waitFor`）があればその最後が届く秒、
無ければ engine が待ちうる後回し（絵・`onMissing: wait` の物・group を付けたフォント）の最初と最後が届く秒を出す。押した後のロゴの上限（3 秒）を超えると知らせる。

```
  押してから動くまで（開いてすぐ押した時・4G）: 約 0.3〜2.9 秒（最初に届く待つ物 assets/bg/desk_room.jpg から、待つ物 8 本の最後まで。最初の場面が使う物で決まる）
```

超えたら、すぐ要る物を `web.deferred` の頭へ並べ替えるか後回しから外す。ロゴと待ちの合計が、後回しにしない時の起動の秒を超える物は後回しにしない。
後回しのフォントのアトラスは、書かなければ列の頭で取る（`deferredPolicy` で group を付けたフォントは、その group の最初の素材の前）。
最初の場面で使わないフォントが待ちを延ばしている時は、`web.deferred` の列に `"font:<名前>"` の行を書くと、その位置で取る（例 `["assets/bg/*.webp", "assets/bgm/*.wav", "font:round"]`。名前は `web.deferredFonts` にも書く）。

減らすのは、タイトルより後で使う絵・音を `web.deferred` へ、タイトルで使わないフォントを `web.deferredFonts` へ回すのが先（アトラスは `fontAtlasScale` の既定 0.5 で縮めてある）。どれを回すかは下の「後回しの候補を出す」が出す。頁は進みの棒をこの量の重みで動かし、wasm まで読み終えてから「タッチして開始」を出す。

### 起動の予算（`web.startupBudget`）と公開前の門

書き出しは最後に **遊べるまで（すぐ押した時・4G）** の 1 本の数字を予算と比べ、超えたら止まる。

```
遊べるまで（すぐ押した時） = 起動の秒 + max(0, 押してから動くまで − ロゴが覆う秒)
```

- 起動の秒: 上の「起動まで」の行
- 押してから動くまで: 書き出しの確かめ ⑨'' が、既定の頁を `?net=4g` で開いて「タッチして開始」を押し、すぐタイトルで `startKeys`（既定 Enter）を押して、押した時の待ちが明けるまでを測る（開始を押してから数える）。
  門に入れるのは、測った値と、押した後のロゴが待つ group の最後が届く見積もり（group が無ければ 0 秒）の大きい方（4G のまねの届く秒は決まっていて、同じ束を 3 回測って同じ秒だった）。測れなかった時（Chrome が無い・`--no-browser-check`・古い頁・上限まで待ってもコマが進まない・headless が遅くタイトルで押せたのが待つ後回しの届いた後だった）は見積もりだけで決め、★ で知らせる（赤にはしない）。group を付けていても、group が空か group の外に待つ後回しがあって測っていなければ ★
- ロゴが覆う秒: 押した後のロゴが出る時だけ、`maxSeconds`（上限 3 秒）。頁がロゴを出すのは `web.splash` の group を待ち、その group の届く見積もりが `minSeconds`（既定 1.2 秒）以上の時だけ（group の無いゲーム・`afterTap: "none"` は 0）
- すぐ要る物を後回しへ回しても、ロゴで覆えない分は起動から押した後へ移るだけで数字は減らない

```json
"startupBudget": { "seconds": 16, "why": "", "startKeys": ["Enter"] }
```

- `seconds` は既定 16（1〜120）。16 を超えるなら `why` が要り、書き出しと web-check のたびに `★ 予算 N 秒` で出る。**`why` は bundle.json に写るので公開される**
- `startKeys` は ⑨'' がタイトルで押すキー（`Enter`・`Space`・`Escape`・矢印・英字 1 字。1 つずつ数コマ空けて押す）。タイトルの既定の行が「はじめから」でないゲームは書く（合わないと「待ちの記録が無い」と出て測れない）
- 後回しの絵を `deferredPolicy` で `onMissing: "placeholder"` にする行は `why` が要る（届くまで描かずに進み、押した後に黒いコマが出るため）
- ⑨'（`?net=4g` のタイトルの 120 コマ）で、タイトルが届いていない後回しの物を待って止まったら、それも止める（タイトルで使う物は後回しにしない）

止まった時は、門の理由と「次に打つ手」（4G の秒が減る順に 3 つまで: 押した後の待ち・後回しの候補・brotli）が出て、**書き出し先は消える**（手で写す道へ赤の書き出しを残さない）。

| 旗 | 赤の時 |
|---|---|
| 無し | 次に打つ手を出して書き出し先を消し、exit 1 |
| `--draft` | 書き出し、bundle.json に `"draft": true` と理由。web-check が拒むので公開できない（作業中に開くだけ・`make tape` の書き出しはこれ）。緑なら旗無しと同じ物 |

- `--reuse` で使い回す時も門を計算し直す。`--draft` は指紋に入るので、draft の書き出しを旗無しで使い回さない
- **移行（0.106.0 の間）**: project.json に `startupBudget` を書いていないゲームは、手元の書き出しを止めず ★ で知らせる（止まる 3 本＝血鱗・インターネットダンジョン・片手間迷宮が予算内か why 付きで通った次の版から止まる）。公開の側（web-check・`make web-pages-stage`・テープの play/）は最初から既定 16 秒で止める
- 逃げ道は 2 つだけ: 中身を直す（次に打つ手）か、理由付きで予算を上げる（`why`）。`wasmBrotli: false` も `startupBudget` を消すのも逃げ道にならない（gzip の大きさで秒に入る・消すと既定 16 秒）

### 手で置く時（`bin/fge web-check`）

書き出したフォルダを自分で gh-pages の根・`site/`・別のリポ（LP など）の `play/` へ写す時は、写す前に必ず流す:

```
bin/fge web-check <書き出したフォルダ>
```

束のファイルだけから計算し直す（project.json は見ない・予算は bundle.json の `startupBudget`、無ければ既定 16 秒）。止めるのは:

- 遊べるまでが予算を超えた（押した後は、書き出しの時に測った値 `checks.tapWaitSeconds` と group の見積もりの大きい方）
- `sums.json` と中身が合わない・`version.txt` が合わない（書き出した後に束を替えた。bundle.json を手で書き換えた形も）・頁が取るのに無いファイル
- wasm に作業フォルダやホームのパスの形
- draft のマーカー・書き出しの時に 4G のタイトルで止まった記録

頁が取らない控え（Opus の代わりの元の wav）が無いのは知らせだけ。`sums.json` に無い足したファイルは数えない。書き出しの時の 4G の確かめを飛ばした束は ★（`--browser` で Chrome を起こして流し直せる）。

- `index.html` は `sums.json` に入れていない（版を書き込むので）ので、web-check も中身を見ない。`index.html` を書き出しの後に手で直しても止まらない
- 写す先のリポで改行を CRLF に替えると `sums.json` と合わず赤になる。写す先の `.gitattributes` に `* -text`（少なくとも `*.json`・`*.js`・`*.wasm` に `-text`）を書く
- `bin/fge tape publish` は、`bin/fge tape --play` で門を通した play/ をそのまま置く。publish の前に束を替えたら `bin/fge tape --play` で頁を作り直す（publish は門を掛け直さない）

- fge の hook の無いリポ（LP・home-tape-live など）や、hook の走らない gh-pages の worktree（相対の `core.hooksPath` は worktree の根に `bin/githooks` が無い）は pre-commit で守れない。写す前に手で流す
- ゲームのリポに束をコミットする時は、pre-commit がステージした `bundle.json`・`classes.wasm`・`classes.wasm.br`・`sums.json` から束のフォルダを選んで流す
- GitHub Actions には入れていない（runner に engine が無い）

### 後回しの候補を出す（`--apply-deferred`）

書き出しの最後のブラウザの確かめ（⑨）は、既定の頁を `?capture=120&usedAssets=1` で開き、タイトルの 120 コマ（2 秒・入力は送らない）の間に
ゲームが使った素材を記録する。記録するのは engine_web で、描いた絵の名前（スプライト・タイルマップ・面が読む絵・Scene3d の材質とビルボードの絵・
フォントの字は `font_<名前>`）・鳴らした音の名前・読んだファイルの道。起動で取る素材のうち、その間に使わなかった物が後回しの候補になり、
書き出しの終わりの表の後ろに、大きい順・project.json に貼れる形で出る。

```
  後回しの候補（タイトルの 120 コマで使わなかった起動の素材）4 本・66.5 KB → 起動 約 14.6 → 14.2 秒（4G）
    "deferred": ["assets/sfx/ui_*.wav", "assets/cast/_sample_plain.png"]
    大きい順（届く時刻は今の後回しの列の後ろに足した時）:
        42.5 KB  音       26.4 秒目  assets/sfx/ui_save.wav（ui_save）
```

- glob は同じフォルダ・同じ拡張子・同じ頭の名前（最初の `_` か `-` まで）でまとめる。まとめるのは、その glob がタイトルで使った物に当たらない時だけ。
  確かめるのは今の束の中だけなので、後でそのフォルダにタイトルの絵を足すと、それも後回しになる
- 届く時刻は、今の `web.deferred` の列の後ろに足した時の 4G（1.6 Mbps）での見積もり（後回しは列の順に取る）
- `"deferredFonts"` の候補は字を 1 字も描かなかったフォント。fonts が全部後回しになる時は先頭の 1 本を外す（届くまでの字の代わりに使う）
- 貼る形に入れるのは絵・音・フォントだけ。読まなかったファイル（`.glb` など）は `読まなかったファイル` の段に並べるだけで、`--apply-deferred` でも足さない
  （ファイルの読み込みは後回しの物を待たず、届く前に読むと Err になる。届いたかを見てから読む `BackgroundLoad` の物だけ手で足す）。Doc（`.json`・`.yarn` など）はその段にも出さない
- 後回しの絵と音を届く前に描こうとした・鳴らそうとした時は `知らせ: 後回しの … を、タイトルの 120 コマの間に届く前に使おうとした` の 1 行（読んだファイルは数えない。裏の読み込みは届いたかを見てから読む。後回しのフォントは届くまで先頭のフォントで描くので、これも数えない）
- 記録の全部（名前・道 → 初めて使ったコマ）は作業フォルダの `title-assets.json`

**4G の届き方でタイトルを回す（`?net=4g`）**: ⑨ の続きで、後回しのあるゲームは既定の頁を `?capture=120&net=4g` でもう 1 回開く。
頁は後回しの 1 本ずつを、書き出しが `bundle.json` に書いた `arrivalSeconds`（4G で届く見積もりの秒・押した時から数える）まで渡さない。
タイトルの間に engine が前の場面のまま止まって待った所（`window.fgeMissingWaits` の `stopped`）と、待つはずの物を描かずに進んだ所
（`window.fgeMissingSkips` の `gaveUp`）を `知らせ:` で出し、表の後ろに 1 行の数を出す。止まった・諦めた所があれば門が赤になる（上の「起動の予算」）。結果は bundle.json の `checks.title4g` に残る。
手で開く時も `?net=4g` を付ければ同じ届き方になる（開いてすぐ押した形）。届く秒は書き出しの時の列の順で決めた物で、engine が待って列の頭へ回した物も早く届かない（待ちは本物より長めに出る・悲観側）。`window.fgeMissingWaits` は旗が無くても積む。

**確かめ方**: 候補には、タイトルで押した時だけ使う物（カーソル・決定の音）と、タイトルの直後の場面で使う物も出る。後回しにした物は届くまで黒い・鳴らない。
外してから貼るか、ゲームが `LoadProgress` の `downloads#missing()` で待つ（[startup.md](startup.md) の「ブラウザで素材を後から取る」）。
貼った後は書き出し直した頁を開き、押してすぐタイトルを抜けて、黒いまま・鳴らないままの所が無いかを見る。

**書き込む**: `bin/fge export-web <ゲーム> --apply-deferred` で、候補を project.json の `web.deferred`・`web.deferredFonts` の後ろへ足す
（もうある物は足さない・字の並びと他の欄はそのまま・`// deferred` の説明に 1 文足す）。書き換えるのは project.json の 1 か所で、差分は git で見る。
足した glob は列の末尾に入るので、末尾に `"font:<名前>"` の行を置いていたゲームは、足した後に行を末尾へ戻す（そのままだと足した素材より先にフォントを取る）。
書き出し直すと後回しで配られる。何も聞かずに入れる仕組みにはしていない（タイトルの直後に使う物まで入るので、選ぶのは担当）。
`--no-browser-check`・`--check` とは一緒に使えず、`--reuse` でも組み直す。

音は Fs の表（`Fs.FileRead.readBytes`）に入らない。音の長さは `GameEngine.Audio.audioSeconds` で聞く（届く前の後回しの音も `bundle.json` の `sounds[].seconds` で答える。[audio.md](audio.md) の「音の長さをゲームのコードで使う」）。

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
   続けて gh-pages の worktree に触る前に `bin/fge web-check`（`SRC=` の時は `--browser` も）。赤ならそこで止める（上の「手で置く時」）
3. gh-pages の worktree: その枝の worktree があれば使い、無ければ `<ゲーム>/build/gh-pages` に作る（枝が無ければ何も無い枝として作る）。
   未コミットの変更がある worktree には置かない。`.nojekyll` を置く（Jekyll は `_` で始まるファイルを配らない）
4. コミット: `pages: <DEST> に <ゲーム> の書き出しを置く（ゲーム <commit>・engine <版>）`。中身が前と同じならコミットしない
5. 開けるかの確かめ: 置いた頁を `<DEST>/index.html?capture=3` の道でヘッドレスの Chrome に開かせる（サブフォルダの道で素材を取れない形を止める）。飛ばすなら `NO_BROWSER_CHECK=1`
6. 最後に出る物: 手元で配るコマンド（`bin/py3 -m http.server 8000 --bind 0.0.0.0 --directory <worktree>`）と PC・スマホで開く URL・`git -C <worktree> push origin gh-pages`・公開後の URL

- 枝や worktree を替えるのは `BRANCH=`・`PAGES_WT=`。gh-pages の根の `index.html`（頁の一覧）は手で直す
- 手元で配ったサーバーは見終えたら Ctrl-C で止める（残った物は `make strays` で見つかる）
- Windows では流せない（bash の道具）

## 起動の始まりと 2 回目からの起動（preload・Service Worker・`web.serviceWorker`）

ゲームの側で直す所は無い。書き出しの頁が自分でやる。

### 版の確かめと preload

頁の物は全部 `?v=<版>` の付いた URL で取る。書き出しは 1 本ずつのファイルの sha256 の表 `sums.json` を置き、版はその `sums.json` の sha256 の頭 12 字（`version.txt` にも書く）。`index.html` は置き場のキャッシュで古い物が出ることがあるので、
頁の起動役は `version.txt` をキャッシュを使わずに取り、その版で `fge-web.js` などを読む（取れない・3 秒で返らない時は書き出した時の版）。

`index.html` の head の起動役は、起動の最初に要る物（`bundle.json`・`classes.wasm.br` と `brotli-decode.js`（brotli が無ければ `classes.wasm`）・2 本の js）の
`<link rel=preload>` をその版で出す。いつ出すか:

| 頁 | preload を出す時 |
|---|---|
| `index.html` を今ネットから取った（`transferSize > 0`） | すぐ（書き出した時の版と置き場の版は同じなので、`version.txt` を待たない） |
| `index.html` が HTTP キャッシュから出た | `version.txt` の答えの後（古い版の URL を先に取ると、置き場は新しい中身を返し、その 1 回分が無駄になる） |
| Service Worker が受け持つ | すぐ（下の節） |

`fetch()` で取る物は `as="fetch"` と `crossorigin`、`<script>` で読む物は `as="script"` だけ。違えると preload した物が使われず 2 回取る。
片手間迷宮（4G・1.6 Mbps・往復 150 ms の測り）で、押せるまでが 28.6 → 28.0 秒。4G では回線の太さで決まるので効きは小さく、効くのは往復の遅い回線と、起動の物の少ないゲーム（往復の分が起動の多くを占める時）。

iOS の Safari で `navigation.transferSize` が 0 のままの版では、いつも `version.txt` の答えを待ってから出す（壊れはせず、往復 1 回分遅いだけ）。

### Service Worker（2 回目からの起動）

書き出しは根に `sw.js`（元は `engine_web/js/fge-sw.js`）を置き、頁は「タッチして開始」を出した後に書き出しのフォルダの scope で登録する。
GitHub Pages は全部のファイルに `max-age=600` を付けるので、Service Worker が無いと 10 分を過ぎた次の起動は全部のファイルに確かめ（304）が走る
（片手間迷宮で 3.7 秒・素材の多いゲームでは 9 秒）。Service Worker があると 10 分の前も後も 0.1〜0.2 秒で押せる。

| 何を | どう |
|---|---|
| 版の付いた物（`?v=<版>`） | 版ごとのキャッシュ（名前は `fge-sw:<束の id>:<書き出しのフォルダの道>:v<版>`）から返す |
| `version.txt` | 毎回ネットへ行く。ネットが無い時は最後に取れた版を返す（キャッシュに揃っていればネット無しで遊べる） |
| `index.html` | Service Worker が覚えている版のキャッシュから返し、同時に版を確かめる。頁は書き出した時の版ですぐ起動し、版が違えば押して始める前に 1 回だけ読み直す。版を上げた後の最初の起動は毎回この読み直しが入る（押した後は読み直さず、次に開いた時に新しい版） |
| 古い版のキャッシュ | 今の版で起動した頁（version.txt が答えた時だけ）が Service Worker に知らせて消す。同じゲームの別のタブが開いている間は消さない（版が上がった所で消すと、古い版のまま遊んでいる頁が後から取る物が置き場の新しい中身になる） |
| 初めての頁 | 登録の前に取った物は、頁が URL を Service Worker へ送り、HTTP キャッシュにある物だけを写す（ネットへは取りに行かない。iOS の Safari は大きい物を HTTP キャッシュに残さないことがあり、その分は次に開いた時に入る）。後から取る後回しの素材は Service Worker が受け持って入れる |
| キャッシュへ入れる時 | 中身の sha256 がその版の `sums.json` と合う物だけ入れる。`sums.json` そのものは、その sha256 の頭 12 字が版と同じことで確かめる（置き場の入れ替えは拠点とファイルごとに混ざり、新しい版の URL に古い中身が届く。入れたら次の版まで残るため） |

- 版が上がると全部の URL の `?v=` が替わるので、版を上げた後の最初の起動は全部を取り直す（Service Worker の有無で同じ）
- 同じドメインに複数のゲームを置いても、scope とキャッシュの名前は書き出しのフォルダごとに分かれる。根に置いたゲームの Service Worker は、サブフォルダのゲームの頁の物を受けずに素のネットへ回す
- 開くたびに `sw.js` の更新の確かめが 1 本ネットへ行く（`updateViaCache: "none"`。直した `sw.js` を置き場の max-age を待たずに届けるため）。起動を待たせない
- 止めるのは project.json の `web.serviceWorker: false`。その書き出しは自分を外す `sw.js`（`engine_web/js/fge-sw-off.js`）を置く
- 全員から外す手順: `web.serviceWorker: false` で書き出し直し、そのまま置く（**`sw.js` は消さずに残す**）。登録済みの人は次に頁を開いた時の更新の確かめで外す `sw.js` を受け取り、
  そのキャッシュを消して登録を外す（新しい頁を押す前の画面まで読まなくても外れる）。`sw.js` を消すと、Chrome も Safari も 404 では登録を外さず、古い Service Worker が残る
  - 外す `sw.js` は fetch を受けないので、開いたまま遊んでいる頁はそのまま続き、その頁が後から取る物も素のネットから来る
  - 外す `sw.js` を置いた直後の 1 回目の頁は、まだ前の Service Worker が出す（更新の確かめがその頁と並んで走るため）。素のネットになるのはその次に開いた時から。前の物が頁を壊していた時は、もう 1 回開けば抜けられる
- 壊れた時に抜け出す口: 頁の URL に `?sw=0` を付けて開くと、その頁は全部をキャッシュを使わずにネットから取り、Service Worker が登録を外してキャッシュを消す。登録とキャッシュを外して作り直させる口で、`?sw=0` を付けずに開けば登録し直す。登録に失敗した時は Service Worker 無しで今まで通り動く
- sandbox の iframe（opaque origin）のように Service Worker を読めない頁でも、Service Worker 無しで今まで通り動く
- `?capture=<n>` の頁は登録しない（描き出しの検査に前の書き出しを持ち越さない）
- セーブ（localStorage）は Service Worker のキャッシュと別の所にあり、消しても残る
- 手元で `127.0.0.1:8000/` の根に別のゲームを配り直すと、前のゲームの Service Worker（scope が `/`）が前の `index.html` を 1 回出してから読み直す（version.txt が違うため）。気になる時は `?sw=0` で開く
- 書き出した後のフォルダの中身を替えない（替えるなら書き出し直す）。`sums.json` と合わない物はキャッシュに入らず、その物だけ 2 回目からも毎回ネットから取る
- `classes.wasm.br` を `Content-Encoding: br` で配る置き場（GitHub Pages は違う）では、ブラウザが解いた後の中身が表と合わず、wasm だけ毎回ネットから取る（壊れはしない）
- 同じドメインのゲームはオリジンの保存量を分け合う（iOS の Safari は特に少ない）。キャッシュは版ごとに 1 組だけ残る
- iOS の Safari は、しばらく操作の無いサイトの Service Worker とキャッシュを消すことがある（Safari の 7 日の決まり。localStorage のセーブも同じ決まりの内）。消された後は初めての時と同じに取る

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
| `?net=4g` | 後回しの 1 本ずつを `bundle.json` の `arrivalSeconds`（4G・1.6 Mbps・往復 150 ms での見積もり・押した時から数える）まで渡さない。`window.fgeMissingSkips` も積む（上の節） |
| `&deferred=all` | 後回しの素材が全部届いてから main を呼ぶ（`?capture=` で画素を比べる頁に付ける。engine の待ちで撮るコマがずれない・[startup.md](startup.md)） |
| `?sw=0` | Service Worker の登録を外し、そのキャッシュを消す（「起動の始まりと 2 回目からの起動」） |
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
