# 起動の流れと、読み込み中に見せる物

実機の起動は次の順に進む。どこで何が画面に出るかを決めておくと、「起動画面のまま固まって見える」を区切りで直せる。

| 順 | 誰が | 何をする | 画面 |
|---|---|---|---|
| 1 | `LwjglLayer.withProject` | ウィンドウを出す | エンジンの起動画面（`starting up...`） |
| 2 | 同上 | テクスチャ・フォントを読む | エンジンの起動画面（`loading images...` など） |
| 3 | 同上 | 音を読む | 同上（`loading sounds...`） |
| 4 | ゲームの main（`App.loadAndLaunch` に渡す関数） | Doc・形・絵を読む・描く元（Res）を組む | 同上（`preparing game...` のまま。区切れば進む） |
| 5 | `App.loadAndLaunch` / `App.launch` | init・startupSystems・始まり（`withStarts`。Doc は読み直さない。`App.launch` で flow を記録する時だけ読み直す） | 同上 |
| 6 | `App.launch` のループ | 最初のコマ | ゲームの画面 |

4 と 5 を走っている間は、ゲームのループがまだ回っていない。誰もウィンドウのイベントを poll しないので、数秒続くと
macOS は応答なしのくるくるを出す。

## 読み込みを区切る（`LoadProgress`）

例の `LayoutDoc`・`ObjMesh` はゲームの中の名前（engine の物ではない）。

```flix
pub def loadDocs(): Res.Docs \ Fs.FileRead + IO + LoadProgress =
    LoadProgress.report("reading docs...", 0, 0);                    // 区切り 1 つ（本数不明の流れるバー）
    let layout = LayoutDoc.load(LayoutDoc.path());
    let files = LayoutDoc.models(layout)
        |> LoadProgress.mapWithProgress("reading models...", name -> (name, ObjMesh.readFiles(path(name))));
    let meshes = files
        |> LoadProgress.parMapWithProgress("building models...", e -> (fst(e), ObjMesh.build(snd(e))));
    ...
```

- `report(phase, done, total)`: phase は起動画面の字（組み込みのフォントなので英数字）・done / total は今の phase の中の本数。total 0 以下は本数不明。
- `mapWithProgress`: 1 つ作るたびに知らせる。
- `parMapWithProgress`: handler が仕事を回す（`LoadProgress.runTasks`。実機と `HeadlessLoad.handle` は CPU の数までのスレッドで並列・結果の並びは元のまま）。
  待つ間も 50 ms ごとに知らせるので、1 つが長くてもウィンドウが応答する。仕事が例外を投げたら残りを止めて同じ例外で抜ける。
  渡す関数は `IO` だけ — effect の handler はスレッドをまたがないので、`Fs.FileRead` で読む物は先に読んでおく。
- 並列の仕事の中で絵（PNG / JPEG・glb の絵）を解くなら、読み込みの関数の頭で `let dec = LoadProgress.imageDecoder();` と受け取り、
  仕事へ引数で渡す（`Gltf.fromGlbTexturedUsing(dec, limits, bytes)`・`Texture3d.decodeUsing(dec, bytes)`）。仕事の中から op は呼べない。
- 本体のスレッドで、知らせの間が 0.5 秒を超えないように区切る。エンジンは 1 つの区切りの中に割り込めない。
- 自前の handler（テストで知らせを集める時など）は必ず `k` を呼んで返す。RenderTarget を開いたまま（Pass に描いている途中で）`report` を呼ばない。
  `runTasks` は順に回すなら `LoadProgress.runTasksInOrder`、並列に回す handler を書いたら `LoadProgress.Conformance` で決まりを確かめる。

受ける側:

| 経路 | 知らせは |
|---|---|
| 実機（`LwjglLayer.withProject`） | 起動画面を進めて poll する（間引きは 80 ms）。最初のコマの後に来た知らせは何もしない |
| headless の描き出し・動画・flow・テスト | 入口で `HeadlessLoad.handle` を張る（並列・絵を解く・知らせは捨てる）。絵を解かないなら `LoadProgress.runNoop`（順に回す）でもよい |
| `LoadProgress` を使わないゲーム | 何も変わらない |

- 読み込み中に閉じるボタンが押されたら、読み込みの後の最初のコマで、いつもの閉じる処理（`App.withCloseRequest`）が受ける。
- 読み込み中に回したホイールは捨てる。押していたボタンは、一度離すまでエッジにならない。

## 最初のコマの後の読み込み

GPU への転送（絵・形）は GL の文脈がループの中にしか無いので、最初のコマの後に回る。数が多いゲームは、
World にローディング画面（`Screen.Loading` などの case）を持ち、1 コマに少しずつ上げる。
`LoadProgress` の op はループが回る前だけ呼べる。`LoadProgress.imageDecoder()` と `LoadProgress.downloads()` が返した関数の組は、
受け取った後はループの中でも呼べる。ループの中で区切って読むのは `App.withBackgroundLoad`（下の節）。

## ブラウザ版の押す前の画面（`web.startPrompt`）

ブラウザ版は iOS の音の決まり（押した操作の中で AudioContext を起こす）があるので、起動の素材がそろった後に 1 回押してもらう。
その前の画面は、デスクトップの起動画面（`Splash.drawables`: ロゴ・題字 `Flix_GE`・ゲージ・英語の一行）と同じ配置・色・字で
fge-web.js が `#fge-splash` の canvas に描く。押した後も wasm の読み込み（`LoadProgress` の一行と本数）を同じ絵で出し続け、最初のコマで消える。

- 材料: `bin/fge export-web` が `engine/src/render2d/BootFontData.flix`（`make boot-font` の生成物）から組み込みフォントとロゴを PNG にし、
  字の表と一緒に bundle.json の `splash` に入れる。縦の design（`web.portraitDesign`）は押した後に WebLayer が選ぶ物と同じ式で頁も選ぶ。
- ゲージは起動の素材（後回しでない物）の本数。満ちたら一行が `ready` になり、その下に `web.startPrompt`（既定 `"Tap to start"`）の文言と
  指のアイコン（押し込みと輪）を出す。後回しの素材（`web.deferred`）の進み具合は、ゲージの下の細い 2 本目の線（配るバイトの割合）。
- 触ると触った点から波紋が出て、一行が `starting up...` に替わる。`prefers-reduced-motion` の時は文言の点滅・指・波紋を出さない。

### ホーム画面のアイコン（`web.appIcon`）

スマホの「ホーム画面に追加」で出るアイコンは、project.json の `web.appIcon`（ゲームの根からの PNG の道・正方形で 512px 以上が良い）から書き出しが 180・192・512px を作る。
書かなければ上の起動画面のロゴ。名前は project.json の `title`。開き方（全画面・manifest）は [web-export.md](web-export.md) の「ホーム画面に追加して全画面で開く」。

## ブラウザで素材を後から取る（`web.deferred`）

project.json の `"web": { "deferred": ["assets/bgm/*.wav", ...] }` に当たる素材は、ブラウザ版で「押して始める」の前に取らない。
fge-web.js が wasm を読み終えた後に別の行列で取り（同時 2 本・glob の並び順）、押すのを待つ間もゲームの間も取り続ける。

- 書き出し（`bin/fge export-web`）: bundle.json の `deferred` に道と配る大きさ・4G で届く見積もりの秒（`arrivalSeconds`）を書き、終わりの表に次の 2 行を出す
  （読み方は [web-export.md](web-export.md) の「遊べるまでの量を見る」）。
  ```
    起動まで（タッチして開始まで）43 本・回線 2.9 MB（wasm 2.0 MB・素材 0.9 MB・頁 0.04 MB）→ 4G（1.6 Mbps）で約 16.0 秒（前置き 1.5 秒を含む）
    後回し 12 本・8.4 MB → 最後の assets/bg/ending.webp が届くのは約 58 秒目（1 本ずつの時刻は書き出しのログ）
  ```
  当たらない glob・project.json・`web.embed` と `web.omit` の素材・フォントのアトラスに当たる glob は誤りで止まる。
  タイトル画面の背景は後回しにしない（届くまで出ない）。
- 2D の絵は届いたら WebLayer がコマの頭で登録する（`App.withDecodeBudget` の予算の内。既定の `Idle(4)` なら 1 コマに 1 本の道と、4 ms に収まる分）。
  1 本の道を複数の名前で宣言していれば、その道の全部の名前を同じコマで登録する。まだ届いていない絵を描くと「見つからない」で描かれない。
- 音は届くまで鳴らない（`GameEngine.Audio.audioSeconds` は届く前も bundle.json の `sounds[].seconds` の元の長さを返す。届いたかは `downloads#missing()` に名前があるかで見分ける）。
  ループの音（環境音・BGM）は鳴らせと言われた事を覚えておき、届いたら最後の音量・高さで鳴らす。一発の効果音は鳴らさず進む。
  1 本の道を複数の名前で宣言した音は、1 回取って全部の名前で鳴らせる。取れなかった音は名前ごとに 1 回警告する。
- 取れなかった素材（回線が切れた）は、fge-web.js が間を置いて取り直す（頼まれた時は 5 秒・タブが表に戻った時・回線が戻った時・30 秒ごと）。
  404 などの 4xx（束に無い・道の誤り）は取り直さない。
- ゲームの側は読み込みの頭で `let downloads = LoadProgress.downloads();` と受け取り、`downloads#missing()`（まだ届いていない
  textures・sounds の名前）・`downloads#stateOf(道)`・`downloads#request(道の並び)`（行列の頭へ）を使う。
  `setBudget` と `spentMs` は App の step が呼ぶ（ゲームは呼ばない）。`release(道の並び)` は生のバイトを捨てる（`BackgroundLoad` が鍵を解いた後に呼ぶ）。
  デスクトップと画面なしは `LoadProgress.localDownloads()`（全部 Loaded・missing は空）なので、後回しが無いのと同じに動く。
- `?fge=loadtime` を付けて開くと、console に後回しの 1 本ごとの届いた時刻と「押すまでに取った量」が出る。

### フォントを後から取る（`web.deferredFonts`）

タイトルで使わないフォント（配信のコメント欄のゴシック体など）は、`"web": { "deferredFonts": ["gothic", "gothic_bold"] }` で
押して始めた後に取れる（名前は `fonts[].name`。全部のフォントは後回しにできない）。アトラスは後回しの列の頭に入る
（`deferredPolicy` で group を付けたフォントは、その group の最初の素材の前）。取る位置を替えるには `web.deferred` の列に `"font:<名前>"` の行を書く
（例 `"deferred": ["assets/bg/*.webp", "assets/bgm/*.wav", "font:gothic"]`。その行の位置で取る。`deferredFonts` に無い名前は止まる）。

- 届くまでは、その名前に起動時に読めた最初のフォント（fonts の並びで先頭）を代わりに当てて出す。代わりのフォントのアトラスに無い字は届くまで出ない。届いたらコマの頭で 1 本ずつ本物に替える
- 上げ終えるまで `downloads#missing()` にフォントの名前が並ぶ。字の形がそろうまで台詞へ進ませたくないゲームは、背景の待ちと同じ所でこの名前も待つ
  （例: 届いていない背景・環境音の名前に `"gothic"`・`"gothic_bold"` を足して暗転で待つ）

### 届く前に使ったコマを engine が出さない（`web.deferredPolicy`）

App のループ（`App.launch*`）は、進めた World が描く絵・フォントにまだ届いていない物があると、そのコマを出さずに待つ。
押した瞬間から 1.5 秒の間に当たった時は、押す前の場面へ戻して待ち、届いたら押した入力を渡し直す（押し直さずに始まる）。
それ以外の所で当たった時は、前の World のまま止まって待つ。20 秒届かなければ諦めて、その名前は描かずに進む（console に 1 行）。
Backspace（パッドの B）で押した時の待ちをやめる（ゲームの戻るのキーに替えるのは `App.withLoadWaitCancelKeys(キーの列)`）。デスクトップ・テスト・描き出しは待たない（missing がいつも空）。

- 一発の効果音は既定で待たない（鳴らさず進む）。ループの音（BGM・環境音）も既定で待たない（届いたら鳴る）。後回しのフォントも既定で待たない（届くまで最初のフォントで出す）
- 扱いを替えるのは `"web": { "deferredPolicy": [{ "match": "<後回しの道の glob か font:名前>", "onMissing": "wait|placeholder|skip", "group": "<組>" }] }`（先の行が勝つ）。
  絵とフォントは `wait`・`placeholder`（待たずに描かずに進む）、音は `wait`・`skip`。`group` を付けると、押した時の待ちで同じ組の残りも一緒に待つ
- 撮る頁（旗 `capture:<n>`）で画素を比べる時は旗 `deferred:all` を足す（`web-capture --dev capture:6,deferred:all`）（後回しが全部届いてから main を呼ぶ。撮るコマの番号が待ちでずれない）
- 待つ間の表示: 押した時の待ちに入ったら、押した点（キーなら画面の真ん中）から波紋を 1 回。待ちが 0.5 秒を超えたら画面の右下に小さな輪（届いた割合の弧と回る光の点・字は出さない・20 秒を超えたら回り方がゆっくりになる）。
  z は `ZBand.loadingBase`（HUD より手前・デバッグより奥）。替えるのは `App.withLoadingIndicator(App.LoadingIndicator.Custom(f))`（自分のフォントで字を出す時。z は `ZBand.loadingBase` から上に置き、後回しの絵とフォントは使わない — 使うと待ちが明けない）・出さないのは `Hidden`（波紋も出さない）。
  選んだ行を光らせるなど World の側で手応えを出すなら `App.withLoadWait` で `LoadWait#pressed`・`waited`・`progress` を写す
- 頁の `window.fgeLoadWait` が今の待ち（理由・名前・待った秒・届いた割合・押した時の待ちか）。起動の画面は、待ちの無いコマを初めて出した時に 0.25 秒で薄れさせて外す
- 待ちの記録: `window.fgeMissingWaits`（待ちごとに `pressed` = 押した所へ戻して待った・`stopped` = 前の場面のまま止まった、と名前・コマ数）。
  4G の届き方で確かめるのは頁の `?fge=4g`（[web-export.md](web-export.md) の「4G の届き方でタイトルを回す」）。`stopped` が出たら直す物（group を付ける・取る順を直す・`placeholder` にする）

### 押した後のロゴ（`web.splash`）

「タッチして開始」を押した後、**待つ物が残る時だけ** engine のロゴ（Flix_GE）を出す。待つ物は `web.splash.waitFor` の group（既定は `deferredPolicy` に最初に出てくる group）。
group が無いゲームは出ない。届くまでの見込みが `minSeconds` より短い時も出さない（ロゴで押した後の待ちを延ばさない）。

- 最短 `minSeconds`（既定 1.2 秒）・待つ物が届いたら切り上げ・上限 `maxSeconds`（既定 3 秒・3 秒より長くはできない）。押すかキーで飛ばせる（押した拍から 0.3 秒は数えない）
- 同じ書き出しの版で 1 度出したら（飛ばしても）localStorage に残し、2 回目からは出さない。localStorage を使えない頁は待つ物が残る時だけ出す
- 出している間、engine は World を進めず音も当てない（タイトルの BGM と演出の時計がロゴの裏で始まらない）。入力のエッジも捨てる
- 動き: ロゴが下から浮き、光が横切り、「Flix_GE」が 1 字ずつ出る。音は WebAudio で作る短いジングル（取る物は増えない）
- `"splash": { "afterTap": "none" }` で出さない・`"custom"` で絵と音を替える（`"logo"`・`"sound"` は束の中で後回しでない道。動きは engine の物）。
  動きまで自分の物にしたいゲームは `none` にしてタイトルの場面で出す。撮る頁（旗 `capture`）では出さない

### ループの中で区切って読む（`BackgroundLoad`・`App.withBackgroundLoad`）

後回しにした 3D の部屋のように、届いてから解く（glb を読む・絵を貼る）物は、鍵ごとのグループ（`BackgroundLoad.Group`）にまとめる。
ブラウザでは、押す前に届いていた鍵も `start` の結果には入らず、ゲームが始まってから予算の内で解く（届き方の速さで起動の待ちが変わらないように）。
重い鍵は既定の `Idle(4)` では始まらないので、暗転の間などに `App.withDecodeBudget` で `Covered` を返して解かせる。

```flix
// 読み込みの頭: 起動の素材だけで組める鍵を解き、残り（まだ届いていない鍵と、押す前に届いていた後回しの鍵）は待ちの表（Pending）に載せる。Pending は resources 側に置く
let (rooms, pending) = BackgroundLoad.start(Rooms.group(doc, LoadProgress.imageDecoder()));
let downloads = LoadProgress.downloads();

// Game.app: 毎コマ予算の内で解き、解けた鍵を store で置く
App.make(...)
    |> App.withDecodeBudget(Controls.decodeBudget)           // Paused / Idle(ms) / Covered(ms) を World から
    |> App.withBackgroundLoad({ group = Rooms.group(doc, decoder), downloads = downloads,
                                pendingOf = h -> h#resources#roomsPending,
                                withPending = (p, h) -> ...,  store = (key, result, h) -> ...,
                                priority = h -> Controls.roomPriority(h) })
    |> App.withMissingAssets({ downloads = downloads, missingOf = h -> h#resources#missing,
                              withMissing = (m, h) -> ... })   // 2D の絵と音のまだ届いていない名前
```

- 予算（`App.withDecodeBudget`・既定は `Idle(4)`）: `Paused` = 解かない（文字送り中など画面が動いている）・
  `Idle(ms)` = 「このコマで使った ms + 1 本の見込み（`Group#costMs`）」が ms に収まる鍵だけ始める（タップ待ち・タイトル）・
  `Covered(ms)` = 1 本目は見込みを問わず始め、あとは ms に満たない間続ける（暗転中）。見込みは解くたびに測った値との平均で置き換わる
  （1 回の値は見込みの 3 倍で頭打ち）。`Idle` で届いた鍵を 2 秒始めず、見込みが `Group#costMs` の 2 倍を超えていたら、見込みを `Group#costMs` へ戻す（解きはしない）。
  目安は glb と jpg の部屋 1 つで PC 100 ms 前後・スマホはその 3〜5 倍なので、部屋は暗転（`Covered`）で解く形にする。
  タップ待ち・タイトルの間に部屋を解きたいゲームだけが、その間を `Idle(150.0)` などへ上げる。
  ブラウザでは届いた 2D の絵を登録する量も同じ予算に従う（step が毎コマ `AssetDownloads#setBudget` へ渡し、登録に使った ms は
  `AssetDownloads#spentMs` で解く側の ms に足すので、1 コマで予算を 2 回使わない）。グループが複数あっても、前のグループが使った ms を次へ渡すので予算は 1 コマに 1 つ。
- 解いた鍵の道の生のバイトは捨てる（`AssetDownloads#release`。まだ解いていない鍵も使う道は残す）。捨てた道は `stateOf` が `Queued` と言い、
  頼まれたら取り直すので、別のグループや作り直した `start` が同じ道を使っても `Waiting` になる（Fs で直に読み直すと無い）。
- 使う所では `BackgroundLoad.readiness(鍵, pending, 待った秒, 上限の秒)` で `Ready` / `Waiting` / `GaveUp(理由)` を見る（判定だけで待たない）。
  取れなかった鍵は上限を待たずに `GaveUp`。store には取れない・解けない鍵が `Err` で 1 回来る。
- step を回すのは実機のふつうのコマだけ（F8 の停止・リモートのコマ・`App.traceFrame`・描き出し・flow は回さない）。
  デスクトップと画面なしは `localDownloads` で `start` が全部読み、表は全部 Loaded なので、step は毎コマ同じ World を返す。
- テストで偽の downloads を流すなら、コマの間に `App.stepBackgroundLoad(app, w)` を呼ぶ（実機と同じ予算で全部の step を当てる）。

## ブラウザ版の画面のスティック（`web.virtualPad.stick`）

project.json の `"web": { "virtualPad": { "stick": true, "buttons": [...] } }` で、指の端末（coarse pointer）のパッドの左のゾーンに
画面のスティック（Unity の On-Screen Stick・Godot の VirtualJoystick に当たる物）を出す。ゲームの側は実機のパッドと同じく `frame#leftStick` を読むだけ。

- 左のゾーンのどこに指を置いても、そこが台の中心になる（floating）。置いていない間はゾーンの下寄りに薄く出る。
- 倒した向きと強さは、実機のパッドの左スティックと同じ生の軸（台の半径の 0.4 倍の CSS px で長さ 1）として `GamepadMap.stickOf` を通る。
  遊び 0.18・長さ 0..1・右が +x・上が +y・小数 4 桁は実機のパッドと同じ。
- 画面のスティックに指が載っている間は、左スティックは画面のスティックの値（実機のパッドの左スティックは見ない。右スティックは実機のまま）。指を離すと実機のパッドに戻る。
- 上下左右のキーは押さない（ブラウザの実機のパッドと同じ）。メニューを上下左右のキーで動かすゲームは、タップかボタンで選べるようにする。
- `dpad` とは一緒に書けない（どちらも左のゾーン。書き出しで止まる）。`buttons` とは一緒に使える（左手でスティック・右手でボタン）。
  スティックだけなら `keysDoc` は要らない。
- 左のゾーンで 2 本目に置いた指は、スティックを掴み直さない。向きを替えた時・タブが裏に回った時は、十字キーと同じく指を全部離す。
- PC で確かめる時は頁を `?fge=touch` で開き、左のゾーンをマウスで押して動かす。

### スティックとボタンの大きさと置き場所（ゲームの HUD の絵にそろえる）

ゲームの HUD がスティックとボタンの絵を自分で描いている時は、`stick` を `true` の代わりに `{…}` にし、`buttons[]` の 1 個ずつにも
同じ欄を書くと、横のゾーンへ並べる代わりにゲームの画面（canvas）の上の指定の所へ重ねる。

```json
"web": {
  "keysDoc": "assets/player.keys.json",
  "virtualPad": {
    "stick": { "size": 204, "anchor": "BottomLeft", "offset": { "x": 132, "y": 138 }, "visible": false },
    "buttons": [
      { "label": "つかう", "action": "use", "size": 156, "anchor": "BottomRight", "offset": { "x": 108, "y": 138 }, "visible": false },
      { "label": "もちもの", "action": "bag", "size": 114, "anchor": "BottomRight", "offset": { "x": 276, "y": 84 }, "visible": false }
    ]
  }
}
```

| 欄 | 意味 |
|---|---|
| `size` | 丸の直径（design px） |
| `anchor` | 基準の角。`TopLeft`・`TopRight`・`BottomLeft`・`BottomRight` |
| `offset` | 角から丸の**中心**までの距離（design px・`x` と `y` は内へ向かって正）。HUD の絵の中心と同じ値を書けばそろう |
| `visible` | 省略は `true`。`false` は絵を出さず、指を受ける当たりだけを置く（ゲームの HUD の絵をそのまま使う） |

- 値はどれも design px。頁は design を canvas に縦横比を保って真ん中に収めた時の拡大（描き手の余りの黒と同じ）を掛けて CSS px にするので、
  端末の大きさが変わっても HUD の絵と重なったまま。当たりは丸より 12 CSS px 広い。
- 置き場所を書いたスティックは、指を置いた所へ台が動かない（台の中心は書いた所のまま。倒した量は直径の 0.4 倍で長さ 1）。
- 置き場所を書いた時は、canvas を縮めて横のゾーンを空けない（画面いっぱいのまま、その上に重ねる）。
- `stick` と `buttons` の**全部に書くか、全部から消すか**のどちらか（混ぜると書き出しで止まる）。`dpad`・`web.portraitDesign` とは一緒に書けない。
  `size`・`anchor`・`offset` の 3 つはそろえて書く。丸が design の外へはみ出す値も書き出しで止まる。
- 欄を書かなければ、今までどおり左右のゾーンに並ぶ（束も頁の動きも変わらない）。
- HUD の絵のボタンにゲームの側の当たり（クリック）も置いているなら、そのままでよい。指は重ねた当たりが受けてキーを押し、canvas には届かない（二重に押されない）。

## ブラウザ版の指の操作（`web.touchGestures`）

project.json の `"web": { "keysDoc": "assets/<名前>.keys.json", "touchGestures": { "swipeUp": "advance" } }` の値はキーの Doc の操作の名前。
`bin/fge export-web` がキーに解き、fge-web.js が canvas の上の指の動きでそのキーを 1 回押す。ゲームの側はキーを読むだけ。

| 名前 | いつ出るか |
|---|---|
| `longPress` | 動かさずに 650ms 以上置いてから離した時（タップの代わり） |
| `swipeLeft` / `swipeRight` | 横へ 60 CSS px 以上・縦の 1.5 倍以上動かして離した時 |
| `swipeUp` / `swipeDown` | 縦へ 60 CSS px 以上・横の 1.5 倍以上動かして離した時 |

- 画面の端（24 CSS px）から始まった払いは出さない（OS の「戻る」・通知・ホームの指と重なる）。
- 縦のドラッグは、割り当ての有無に関わらず動かしている間ホイール（40 CSS px で 1 刻み・指を下へ引くと上へ回した向き）を出す。
  縦の払いで送るゲームは、読む画面でホイールに別の意味（上で履歴を開く など）を持たせない。履歴の画面のスクロールはホイールで受けてよい。
- 縦のドラッグは、決まった所で左ボタンを離す（置いた直後は押している）ので、払いがクリックとして重ねて届くことはない。
- パッドのゾーンに置いた指とは別に追う。スティックを持ったまま canvas に置いた指も、タップ・置いている間の押しになる（[web-export.md](web-export.md) の指の表）。
