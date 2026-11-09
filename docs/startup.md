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

## ブラウザで素材を後から取る（`web.deferred`）

project.json の `"web": { "deferred": ["assets/bgm/*.wav", ...] }` に当たる素材は、ブラウザ版で「押して始める」の前に取らない。
fge-web.js が wasm を読み終えた後に別の行列で取り（同時 2 本・glob の並び順）、押すのを待つ間もゲームの間も取り続ける。

- 書き出し（`bin/fge export-web`）: bundle.json の `deferred` に道と配る大きさを書き、大きさの表に「起動 m 本・y MB／後回し n 本・x MB」を出す。
  当たらない glob・project.json・`web.embed` と `web.omit` の素材・フォントのアトラスに当たる glob は誤りで止まる。
  タイトル画面の背景は後回しにしない（届くまで出ない）。
- 2D の絵は届いたら WebLayer がコマの頭で登録する（`App.withDecodeBudget` の予算の内。既定の `Idle(4)` なら 1 コマに 1 本の道と、4 ms に収まる分）。
  1 本の道を複数の名前で宣言していれば、その道の全部の名前を同じコマで登録する。まだ届いていない絵を描くと「見つからない」で描かれない。
- 音は届くまで鳴らない（`audioSeconds` は 0 を返す。使う側は `downloads#missing()` に名前があるかで見分ける）。
  ループの音（環境音・BGM）は鳴らせと言われた事を覚えておき、届いたら最後の音量・高さで鳴らす。一発の効果音は鳴らさず進む。
  1 本の道を複数の名前で宣言した音は、1 回取って全部の名前で鳴らせる。取れなかった音は名前ごとに 1 回警告する。
- 取れなかった素材（回線が切れた）は、fge-web.js が間を置いて取り直す（頼まれた時は 5 秒・タブが表に戻った時・回線が戻った時・30 秒ごと）。
  404 などの 4xx（束に無い・道の誤り）は取り直さない。
- ゲームの側は読み込みの頭で `let downloads = LoadProgress.downloads();` と受け取り、`downloads#missing()`（まだ届いていない
  textures・sounds の名前）・`downloads#stateOf(道)`・`downloads#request(道の並び)`（行列の頭へ）を使う。
  `setBudget` と `spentMs` は App の step が呼ぶ（ゲームは呼ばない）。`release(道の並び)` は生のバイトを捨てる（`BackgroundLoad` が鍵を解いた後に呼ぶ）。
  デスクトップと画面なしは `LoadProgress.localDownloads()`（全部 Loaded・missing は空）なので、後回しが無いのと同じに動く。
- `?loadtime=1` を付けて開くと、console に後回しの 1 本ごとの届いた時刻と「押すまでに取った量」が出る。

### ループの中で区切って読む（`BackgroundLoad`・`App.withBackgroundLoad`）

後回しにした 3D の部屋のように、届いてから解く（glb を読む・絵を貼る）物は、鍵ごとのグループ（`BackgroundLoad.Group`）にまとめる。

```flix
// 読み込みの頭: 届いている鍵だけ解き、残りは待ちの表（Pending）に載せる。Pending は resources 側に置く
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
