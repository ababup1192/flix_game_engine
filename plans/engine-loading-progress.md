# 起動の読み込みで応答なしにしない — 読み込みの進み具合を知らせる effect（rev3・実装済み）

rev2 → rev3（実装のとき）: eff は top-level に置き、同じ名前の mod と組にした（`Fs.FileRead` と同じ形）。
parMapWithProgress の例外は try/catch で受けず、`Result` で返してプールを止めてから投げ直す — Flix では
`report` から戻った後の例外を、その外の try が受けない（テストで確かめた）。api-digest の生成器が mod の外の eff も拾うようにした。
P0 の内訳（fps3d_lab）: main の `loadDocs` 約 1.4 秒・`Res.build` 約 0.2 秒・`bootWorld` の中の `freshWorld` の `reloadAll`（Doc の読み直し）約 2.6〜3.1 秒。
最後の 1 つは「2. bootWorld はほぼ 0」の見立てと違い、`withStarts` を使うゲームは起動のたびに Doc を 2 回読んでいた。
承認を得て、起動では読み直さない形に直した（flow を記録する起動だけ読み直す）。fps3d_lab の main から最初のコマまで: 約 4.3〜4.5 秒 → 約 1.6〜1.7 秒。


rev1 → rev2: 再レビュー 88 点。ホイールを捨てる時期（poll のたび）・並列は `ExecutorCompletionService`（プールは CPU の数・例外で残りを止める）・
poll の時刻の控え・最初の `shouldClose` でまとめる理由・テストの時間切れの書き方を直した。

rev0 → rev1: レビュー 76 点。垂直同期を戻す時期を最初のコマへ移す・並列の待ち方（region の外で待つ・例外・待ち方を Java のキューで書く）・
headless の入口の全リスト（GlOffscreen・描き出し・動画）・最初のコマの後に何もしない理由・読み込み中に溜まった入力を捨てる・空の並び・
名前（`runNoop`・`mapWithProgress`）・テストと工数を直した。

`plans/engine-asset-import.md`（取り込み）と組で使う。取り込みは「読み込みを速くする」、こちらは「読み込みの間もウィンドウを応答させ続ける」。

用語: poll ＝ウィンドウのイベント（入力・閉じる・リサイズ）を OS から受け取ること（`glfwPollEvents`。このリポジトリのコメントでは「イベントを汲む」とも書く）。

## 症状と原因

fps3d_lab の起動で、起動画面が「preparing game...」のまま数秒止まり、macOS のカーソルが応答なしのくるくるになる。
macOS は、アプリがイベントを poll しない時間が数秒続くとこの表示を出す。

`LwjglLayer.withLwjgl` は、ウィンドウ・起動画面・絵・音を用意した**後で**ゲームの本体 `f()` を呼ぶ（LwjglLayer.flix:705）。
本体の中で最初のコマを描くまでの間は、誰も `glfwPollEvents` を呼ばない。ここで走る物は 2 か所ある:

1. **main の中で App.launch より前に走る物**。fps3d_lab は `Game.appWithLoading(Controls.loadDocs())`（Main.flix:11）で、
   引数の `Controls.loadDocs()`（Doc・OBJ・glb の解読）と `appFrom` の中の `Res.build(docs)`（Game.flix:27）が、launch の前に評価される。
2. **App.launch の `bootWorld`**（ゲームの init と startupSystems、または `withStarts` の始まり）。
   fps3d_lab は init が出来上がった値（`App.game` の init）で、startupSystems も無いので、ここはほぼ 0 のはず。

コードを読む限り、fps3d_lab で止まっているのは 1 の方。実装の初めに 1 と 2 を分けて測って確かめる（P0）。
どちらでも同じ仕組みで直せるように設計する。

## 大手のエンジンの作法（短く）

| | 読み込み | 進み具合 | その間の画面 |
|---|---|---|---|
| Bevy | `AssetServer::load` が Handle をすぐ返し、裏の task pool で読む | `is_loaded_with_dependencies`・`bevy_asset_loader` の LoadingState | ゲームの State（Loading → InGame）。毎コマ回る |
| Godot | `ResourceLoader.load_threaded_request` で裏で読む | `load_threaded_get_status(path, progress)` を毎コマ見る | 読み込み用のシーン。毎コマ回る |
| Unity | `SceneManager.LoadSceneAsync`・Addressables | `AsyncOperation.progress` | コルーチンでローディング画面。毎コマ回る |

共通するのは「**読む物は裏のスレッド・本体のループは回り続ける・進み具合は done / total**」。このエンジンは次の理由で、そのままは写せない:

- effect の handler はスレッドをまたがない。裏のスレッドで `Fs.FileRead` を使うには、そのスレッドの中で handler を張り直すことになり、
  flow の記録（`Flow.Record.captureReads` が本体のスレッドの `Fs.FileRead` を拾う）とテストの差し替えの handler から外れる。
- GLFW の `glfwPollEvents` は main スレッドからしか呼べない。poll を裏のスレッドに任せることもできない。
- 最初のコマを描く前は、ループがまだ回っていない（1 の main の読み込みはループの外）。

そこで v1 は「**本体のスレッドで読みながら、区切りごとにエンジンへ進み具合を知らせ、エンジンがその時に poll する**」形にする。
Bevy / Godot の「ループの中で読む」形は案 C として §6 に比べて残す。

## 1. 決めたこと: effect `LoadProgress`（engine）

```flix
/// 起動の読み込みの進み具合を知らせる（区切りごとに 1 回）。受けた側は起動画面を進め、ウィンドウのイベントを poll する。
pub eff LoadProgress {
    /// phase = 今やっていること（起動画面の字）・done / total = その中の何本目 / 全何本（total 0 以下は本数不明の流れるバー）。
    def report(phase: String, done: Int32, total: Int32): Unit
}

/// eff と同じ名前の mod（Fs.FileRead と同じ組の形）。呼ぶ側は LoadProgress.report と LoadProgress.runNoop を同じ名前で書ける。
pub mod LoadProgress {

    /// 知らせを捨てる handler（headless の描き出し・動画・テスト・flow の再生・Studio のプレビュー）。
    pub def runNoop(f: Unit -> a \ ef): a \ ef - LoadProgress

    /// xs を f で 1 つずつ作り、1 つ作るたびに (phase, 作った数, 全部の数) を知らせる（最初に (phase, 0, n)）。空の並びは何も知らせない。
    pub def mapWithProgress(phase: String, f: a -> b \ ef, xs: List[a]): List[b] \ ef + LoadProgress

    /// xs を f で並列に作る（スレッドの数は CPU の数まで・結果の並びは xs のまま）。本体のスレッドは出来上がりを待つ間、
    /// 1 つ届くたびと、何も届かないまま 50 ms が過ぎるたびに知らせる（1 つの要素が長くてもウィンドウが応答し続ける）。
    /// f は IO だけ（Fs.FileRead などの handler はスレッドをまたがないので、ファイルは先に読んでおく）。
    /// f が例外を投げたら、残りを待たずに同じ例外で止まる。空の並びはスレッドを立てずに空を返す。
    pub def parMapWithProgress(phase: String, f: a -> b \ IO, xs: List[a]): List[b] \ IO + LoadProgress
}
```

- 置き場所は engine（契約層。GameEngine.Game・Audio と同じ並び）。捨てる handler の名前は `RenderTarget.runNoop`・`ShaderEffect.runNoop` にそろえる。
- 知らせを集める handler はテストの側に置く（engine の pub を増やさない）。区切り 1 つ（本数不明）は `LoadProgress.report(phase, 0, 0)` を直に呼ぶ。
- **重みは持たない**。起動画面のバーは「今の phase の中の done / total」を出し、phase が替わると字とバーが替わる。
  - WhyNot: phase ごとの重みで全体のバーを 1 本にしない — 重みは手で決める推測で、読む物が増えるとずれて、バーが途中で止まったり飛んだりする。
- 空の並びで何も知らせないのは、(phase, 0, 0) が「本数不明の流れるバー」の意味と重なるため。
- **`parMapWithProgress` の作り**:
  - プールは `Executors.newFixedThreadPool(availableProcessors)`（スレッドは daemon）。要素ごとに `Callable` を `ExecutorCompletionService` へ submit し、
    本体のスレッドは `poll(50, MILLISECONDS)` で待つ。届けば数を 1 増やして知らせ、時間切れでも同じ数で知らせる（handler が間引くので知らせが多くても描きすぎない）。
    終わった順に届き、例外は `Future.get` の `ExecutionException` で戻るので、自前のキューと Result の包みは要らない。結果は番号の表で xs の並びに戻す。
  - `Callable` は Flix の `new` で作る（`Runnable` は手続きの名前 `run` が Flix の予約語で書けない — `App/Headless.flix` の WhyNot）。
    - WhyNot: region の中で `spawn` しない — region を閉じる所で全部のスレッドを待つので、待つ間に知らせを出せない（fps3d_lab の `Controls.parMap` がこの形）。
    - WhyNot: Flix の `select` と `Channel.timeout` で待たない — `Channel.timeout` は呼ぶたびにスレッドを 1 本立てて眠らせる（標準ライブラリの Channel.flix:46-51）ので、
      50 ms ごとに使うと眠るスレッドが増える。`select` はこのリポジトリに使う例が無い。
  - 例外が届いたら、残りを待たずに `shutdownNow` でプールを止め、同じ例外を投げ直す（時間切れのループが止まらなくなるのを防ぐ）。
    Flix から元の例外を投げ直せるかは P1 の最初に確かめ、だめなら `bug!` に元の例外の字を入れて止める。正常に終わった時も `shutdown` する。
    - WhyNot: 要素ごとに 1 本のスレッドを立てない — N はゲームが決めるので、数百の並びで数百本立つ（docs/performance.md の流儀）。
  - fps3d_lab の `Controls.parMap` はこれに置き換えられる（ゲーム側の作業）。
- 1 つの要素の中がそれでも長い時（本体のスレッドで走る 1 つの関数が数秒）: その関数の中で `report` を呼ぶか、`parMapWithProgress` で裏へ出す。
  エンジンは途中で割り込めない（doc に書く）。目安は「本体のスレッドで知らせの間が 0.5 秒を超えない」。

### 1.1 GL の handler（render_gl・LwjglLayer）

- `withLwjgl` と `withProject` が `LoadProgress` も受ける（`f` の effect から `- LoadProgress` を外す）。`withProject` を呼ぶのはゲームの main だけ。
- `report(phase, done, total)` で今ある `splash` の関数（`RenderSplash.tick`）を呼ぶ。**新しく描く道は作らない** — 間引き（80 ms）・
  起動直後の見合わせ（120 ms）・`FLIX_GE_NO_SPLASH`・`FLIX_GE_SPLASH_SHOT` の撮影・リサイズの描き直しの控え（`rememberFrame`）は、
  全部 `tick` と `drawSplash` が持っている物をそのまま通る。
- **描かなくても poll する**: `tick` は間引きと `disabled()` の時に何もしない（`glfwPollEvents` も呼ばない・Splash.flix:33-37）ので、
  handler は描かなかった時も、前に poll してから 80 ms 以上空いていれば `glfwPollEvents` だけを呼ぶ。`FLIX_GE_NO_SPLASH` でも応答なしにならない。
  poll した時刻の控えは、`drawSplash` の中の poll でも更新する（描いた直後にもう一度 poll しない）。
- **垂直同期を戻す時期を、最初のコマへ移す**: 今は `f()` を呼ぶ前に `glfwSwapInterval(if (hidden) 0 else 1)` で戻している（LwjglLayer.flix:560）。
  このままだと `report` のたびの swap が 1 コマ分待ち（80 ms ごとに 16 ms・読み込みが最大 2 割遅くなる）、macOS でウィンドウが隠れている時は
  swap が 1 秒級で止まる（:557 のコメントの理由）。戻すのを「本体が初めて `shouldClose` を呼んだ時」（ループが回り始める所）へ移す。
  「preparing game...」の 1 枚（:554）はその前なので、今の WhyNot のまま。
- **最初のコマの後に `report` が来たら何もしない**。見分けは「本体が初めて `shouldClose` を呼んだか」の Ref 1 つ（上の垂直同期と同じ Ref）。
  これでよいのは、ループの 1 周で入力を読む所（App.flix:1200-1206）がシステムより前で、そこでは `report` が来ないため — システムの中の `report` は必ず Ref が立った後になる。
  - WhyNot: コマの途中で poll しない — リサイズの callback が、描いている途中の RenderTarget を開いたまま `paintFrame` と swap をしうる。
    1 コマの中の長い処理（ループの中のシステムが重い読み込みをする・F1）は、この計画の対象外（§1.3 の F1 の行と同じ別の話題）。
- **読み込み中に溜まった入力を捨てる**: `report` は入力の callback を付けた後（:610 以降）に来るので、読み込み中のホイールは `scrollDeltaHolder` に溜まる。
  handler は poll した直後に毎回 `scrollDeltaHolder` を 0 に戻す（読み込み中のホイールはずっと捨てる）。
  - WhyNot: 最初の `shouldClose` で 0 に戻さない — `App.loop` は 1 周の中で `shouldClose` より前に `consumeScrollDelta` を読む（App.flix:1206）ので、間に合わない。
  - ボタンは足す物が無い: `launchFrom` が `prevMouseDown` を `isMouseButtonPressed` の値で種にする（App.flix:1076）ので、読み込み中のクリックはエッジにならない。
- 隠しウィンドウ（`FLIX_GE_HIDDEN`・gl-parity）: 今の起動画面と同じ扱い（描く・poll する。垂直同期は止めたまま）。
- **閉じるボタン**: 読み込み中に押されると、`glfwPollEvents` が `glfwWindowShouldClose` を立てる。handler は何もせず、
  読み込みの後の最初のコマで、今と同じ閉じる処理（`App.withCloseRequest` があればその確認、無ければ終了）に任せる。
  - WhyNot: handler の中で読み込みを打ち切って終わらない — 読み込みは純粋な関数の途中で、外から止める道が無い（`bug!` や `System.exit` で
    抜けると音の装置などの後始末が飛ぶ）。打ち切りたい場合の扱いは §7 の論点。
- **GlOffscreen**（動画の描き出しが使う GL の handler）は起動画面を持たないので、`LoadProgress` を受けない。動画の入口は `runNoop` を張る（§1.3）。

### 1.2 App（engine_world）

- App の型と `launch` は変えない。`bootWorld` の中（init・startupSystems・始まり）でゲームが `report` を呼べば、
  `ef` に `LoadProgress` が入り、外側の `LwjglLayer.withProject` が受ける。
- `launch` のコメント（「ここで起動画面を出し直さない」）は残す。出し直すのはバックエンドの handler だけで、App は描かない — これが
  コメントの懸念（間引きも中止スイッチも持たない 2 つ目の経路）への答え。コメントに「進み具合は `LoadProgress.report` で知らせる」と 1 行足す。

### 1.3 headless・テスト・flow・F1・Studio

| 経路 | 振る舞い |
|---|---|
| `LoadProgress` を使わないゲーム | 何も変わらない（effect を使わなければ handler も要らない。`withProject` の型の変化は呼ぶ側から見えない） |
| 実機（LwjglLayer） | 知らせのたびに起動画面と poll（§1.1） |
| headless の描き出し・Studio のプレビュー（`App.Headless`・`freshWorld`） | ゲームが自分の入口で `LoadProgress.runNoop` を張る（使うゲームだけ。張り忘れは型の誤りで止まる） |
| 動画（`GlOffscreen`） | 同じく入口で `runNoop` |
| テスト | `runNoop`。知らせの並びを確かめるテストは、テストの側の集める handler |
| flow の記録（`captureReads`） | `captureReads` が受けるのは `Fs.FileRead` だけで、`report` は外へ素通しする。読んだファイルの記録は今と同じ |
| flow の再生・`/start` | `freshWorld` の中で `report` が来ても、呼ぶ側の `runNoop` が捨てる |
| F1・watchFile の読み直し | 読み直しの関数は `w -> w \ {Fs.FileRead}` なので `report` を呼べない（今と同じ）。ループの中の長い読み直しの止まりは別の話題 |

- main の中の読み込み（fps3d_lab の `loadDocs`）は App の外なので、App の経路のどれにも入らない。

## 2. fps3d_lab との役割分担（ゲーム側の作業）

| 時期 | 見せる物 | 中身 |
|---|---|---|
| 最初のコマの前 | エンジンの起動画面（`LoadProgress`） | Doc の読み込み・OBJ / glb の解読（`parMapWithProgress`）・`Res.build` |
| 最初のコマの後 | ゲームのローディング画面（`World.Screen.Loading` / `LoadingView`） | GPU への転送と mip（1 コマに 1 つ。GL の文脈がループの中にしか無い） |

- `Controls.loadDocs` を `report("reading docs...", 0, 0)`・`mapWithProgress("models", …)`・`parMapWithProgress("decoding models", …)` で区切る。
  `Controls.parMap` は `parMapWithProgress` に置き換える。
- `loadDocs` を呼ぶ入口の全部に `runNoop` を張る: `src/E2e.flix`・`src/render/SceneRender.flix:27`・`src/render/VideoRender.flix:43`・
  `test/TestStarts.flix:5` ほか、`loadDocs` を使う所（実装の時に refactor の usages で洗い直す）。実機の main は `withProject` が受けるので張らない。
- 取り込み（`engine-asset-import.md` の I2）が入ると、glb の絵の解読がキャッシュの読みに替わり、この区切りの中身が短くなる。

## 3. テスト

- engine:
  - `mapWithProgress`: 3 つの並びで (p, 0, 3)・(p, 1, 3)・(p, 2, 3)・(p, 3, 3) を知らせ、結果は `List.map` と同じ。空の並びは何も知らせない。
  - `parMapWithProgress`: 結果の並びが xs のまま・届くたびに 1 つずつ増える・最後が (p, n, n)・空の並びは何も知らせず空を返す。
  - 例外: 1 つの要素が例外を投げると、止まらずに同じ例外で落ちる。待つ回数の上限を引数に取る非 pub の関数を作り、テストでは上限を小さくして、
    上限に届いたら失敗として返す（テストが止まらないことを、実時間でなく回数で押さえる）。
  - 時間切れの知らせ: 待つ時間を引数に取る非 pub の関数を作り、テストでは 1 ms にして「同じ done の知らせが 2 回以上来る」を確かめる（sleep の長さに頼らない）。
  - `runNoop` の中で呼んでも何も起きない。
  - 知らせを集める handler はテストの側に書く。
- engine_world: `freshWorld` の startupSystems が `report` を呼ぶゲームを、テストの側の集める handler の中で組み、知らせが届くこと
  （`launch` は音・シェーダー・RenderTarget の handler も要って重いので、`freshWorld` で確かめる）。
- render_gl: handler は GL が要るので自動のテストにしない。人の目の確認:
  - 撮影（`FLIX_GE_SPLASH_SHOT`）で phase の字とバーが進むこと。
  - 5 秒かかる読み込みの試作で、カーソルがくるくるにならないこと（`FLIX_GE_NO_SPLASH=1` でも）。
  - 読み込み中に垂直同期が 0 のままで、最初のコマから 1 になること（読み込みの時間が延びない）。
  - 読み込み中にウィンドウを最小化しても止まらないこと。
  - 読み込み中にホイールを回しても、最初のコマで一度に出ないこと。
- gl-parity と render-all が変わらない（知らせの無い起動は今と同じ）。

## 4. 文書・早見表・お題・移行メモ

- AGENTS.core の早見表に 1 行: 「起動の読み込みが数秒かかる → `LoadProgress.mapWithProgress` / `parMapWithProgress` で区切る（ウィンドウが応答なしにならない）」。
- agent-eval のお題 1 本: 「起動時の読み込みでカーソルがくるくるになる」→ 当たり = 読み込みを `LoadProgress` で区切り、headless の入口に `runNoop`。
  外れ = 起動画面を自分で描く・スレッドを自分で立てて poll する。
- forbid.json: 候補なし（1 行の正規表現で見分けられない）。
- 移行メモ（入る版）: 「`LoadProgress` が増えた（使わなければ何もしない）」「使うゲームは headless・動画・テストの入口に `runNoop`」の 2 行。
- docs: 起動の流れ（ウィンドウ → 起動画面 → 絵と音 → ゲームの本体 → 最初のコマ）と、どこで何を見せるかの表。
  取り込みの計画で新しく作る `docs/assets.md` に入れる。取り込みより先に入るなら、`docs/startup.md` として新しく作り、後で assets.md から指す。

## 5. 進め方と工数

| フェーズ | 中身 | 工数 |
|---|---|---|
| P0 | fps3d_lab で main の読み込みと `bootWorld` の時間を分けて測る（ゲームの main に時刻の 2 行を足した試作。コミットしない） | 0.25 日 |
| P1 | `LoadProgress`（eff・`runNoop`・`mapWithProgress`・`parMapWithProgress` の待ち方・プール・例外）とテスト | 1.5 日 |
| P2 | LwjglLayer の handler（poll だけの道・垂直同期の移動・最初のコマの後は何もしない・溜まった入力を捨てる・`withProject` の型）・launch のコメント | 0.75 日 |
| P3 | fps3d_lab に入れて確かめる（ゲーム側。入口の `runNoop`・別の作業と順番を相談） | 0.5 日 |
| 文書 | 早見表・お題・移行メモ・api-digest・起動の流れの文書 | 0.25 日 |

合計 3.25 日。

## 6. ほかの案と比べて

| 案 | 中身 | 良い所 | 困る所 |
|---|---|---|---|
| A（入れた） | 起動画面の字を「preparing game...」にする | 1 行 | くるくるは消えない |
| **B（この計画）** | 区切りごとに知らせて、エンジンが poll する | 小さい・main と bootWorld の両方で働く・記録とテストの経路が変わらない | 見せるのはエンジンの起動画面（ゲームの画風ではない）。区切りはゲームが入れる |
| C | `App.withLoadSteps(steps)`: 最初のコマの後、ループが 1 コマに 1 つずつ `w -> w \ {Fs.FileRead, IO}` を回し、ゲームのローディング画面を出す（Bevy の LoadingState・Godot の読み込みシーンに近い） | ゲームの画風で見せられる・ループが回るので poll の心配が無い | init が「まだ読んでいない World」を作れる形にゲームを組み替える（fps3d_lab の `Res.build` は docs を前提にしている）。記録の start の行に途中で読んだファイルを足す・`freshWorld` は全部を続けて回す、の決まりが要る。工数 3〜4 日 |
| D | 裏のスレッドで読む（本体のスレッドは起動画面を回す） | 1 つの長い処理でも滑らか | effect の handler がスレッドをまたがない（`Fs.FileRead` の差し替え・記録が外れる）。poll は main スレッド専用なので、裏で読む側を IO だけに絞るしかない — B の `parMapWithProgress` がその形で同じ得を取る |

B を先に入れ、ゲームの画風のローディング画面が要るゲームが出たら C を足す（B と C は両立する）。

## 7. 人に決めてほしいこと

1. **案 B でよいか**（ゲームの画風でローディング画面を出す案 C は後に回す）。
2. **読み込み中の閉じるボタン**: 読み込みの後に今と同じ閉じる処理へ任せる（確認のあるゲームは確認が出る）でよいか。
   すぐ終わらせたいなら、`report` が「閉じるが押された」を返し、`mapWithProgress` などが残りを飛ばして呼ぶ側へ伝える形が要る（工数 +0.5 日）。
3. **入れる版**: I0 と同じ 0.74.0 にするか、次の版にするか。
4. **P0 の計測**: fps3d_lab の main に時刻の 2 行を足して測ってよいか（コミットしない試作。fps3d_lab は別の作業が編集中）。

## 8. 記録する起動でも読み直さない（make debug・Studio の DEBUG 付きプレイ）— 口の形 rev1（レビュー 88 点・実装済み）

実装で入れたレビューの残り: `expect` は始まりの行を書いた時だけ・`# fp` も書く・env の判定は `debugOf` / `pathOf` をそのまま呼ぶ・
`watchFile` は reloadPaths が None の時は None のまま。`make debug` 相当の起動で main から最初のコマまで 4.3〜4.5 秒 → 1.8〜1.95 秒。

rev0 → rev1: レビュー 72 点。reload が読むパスを DocTable の全部の行から取る（分からない時は今の形へ戻す）・始まりの @パス 引数も拾う・
start の直後に指紋を書いて再生で比べる・記録しないと env で分かる時は控えない・名前を loadAndLaunch に。

### 困っていること
`make debug` は `DEBUG=true` で起動し、`FLOW_RECORD` が空なら flow を記録する。記録する起動は `bootWorld` が
`freshWorld`（`reloadAll`）で Doc を全部読み直し、`captureReads` で読んだ中身を start の行に載せる（再生が同じ Doc で始まるため）。
fps3d_lab ではこの読み直しが約 2.7 秒あり、`\ Fs.FileRead` だけの経路なので LoadProgress も届かない。

### 口: `App.loadAndLaunch`

```flix
/// loadApp で App を組んで launch する。flow を記録する起動では、loadApp が Fs.FileRead で読んだ中身を start の行に載せ、
/// Doc を読み直さない（App.launch に組み終えた App を渡すと、記録する起動は Doc を読み直す）。
pub def loadAndLaunch(loadApp: Unit -> App[w, ef] \ ef2): Unit \ (ef + ef2 + GameEngine.Game + GameEngine.Audio
        + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + Fs.FileWrite + IO)
```

- 名前: 動く順（読む → launch）のまま。`load*` は「外から取ってくる・遅い」で意味が合う。Bevy / Godot / Unity に同じ物は無い。
- ゲームの main（fps3d_lab）: `run { App.loadAndLaunch(() -> Game.appWithLoading(Controls.loadDocs()) |> … |> App.withDebug(App.debugFromEnv())) } with LwjglLayer.withProject(".") with …`。
  `loadDocs` の `LoadProgress` は ef2 に入り、外の `withProject` が受ける。
- `App.launch` は残す。直に呼ぶゲームは今と同じ（記録する起動は読み直す・しない起動は読み直さない）。

### 中の作り
- `loadAndLaunch`: 先に env を読み、記録しないと env だけで分かる時（`DEBUG` が無い、または `FLOW_RECORD=0`）は `loadApp()` を
  そのまま呼んで `launchWith(app, None)`。それ以外は `Flow.Record.captureReads(loadApp)` で (app, 読んだ中身) を得て `launchWith(app, Some(中身))`。
  （ゲームが `withDebug(true)` を env に依らず付けていると、env では分からず None になり、今と同じ読み直す形で記録する。遅いが正しい）
- App の Rec に非 pub の意味の欄 `reloadPaths = Option[List[String]]` を足す（`freshWorld` の読み直しが読むパスが分かる時だけ Some）。
  `makeWith` は Some(Nil)・`watchFile` は Some に path を足す・`reloadOn`（自前の関数）は None・`withDocTable` は reloadOn の後で
  Some(全部の行の path。ReloadAll だけの行も含む) に置き直す。
- `launchWith(app, captured)` の起動の World と start の行:
  | 記録 | captured | reloadPaths | 起動の World | start の行のファイル |
  |---|---|---|---|---|
  | しない | どれでも | どれでも | init + 起動時の系 + 始まり | — |
  | する | Some(main) | Some(paths) | `captureReads(bootWorld(.., false))` | main ∪ boot で読んだ物 ∪ paths のうち両方に無い物を読んで足す（同じパスは main を優先） |
  | する | Some(main) | None（自前の reloadOn） | `captureReads(bootWorld(.., true))`（今と同じ） | boot で読んだ物（今と同じ） |
  | する | None（launch を直に呼ぶ） | どれでも | 同上（今と同じ） | 同上 |
- 記録する時は、start の行の直後に `expect fp=<起動の World の指紋>` を書く（`withFingerprint` がある時）。再生は `buildStart`
  （`freshWorld` を start の行のファイルで回す）の後にこの行で比べるので、「Doc が同じなら reloadAll(init) == init」が崩れるゲームは、
  再生がその場で理由つきで止まる（黙ってずれない）。launch を直に呼ぶ経路にも書く（再生の確かめが 1 行増えるだけ）。
- `readBytes`（glb）と Java を直に呼んで読む物は、今も拾わない（今の記録と同じ。再生はディスクから読む）。

### 再生の正しさ
- 記録: 起動の World = init（main が読んだ Doc から）+ 起動時の系 + 始まり。start の行 = main と始まりで読んだ中身 + reload が読む全部のパス。
- 再生: `buildStart` = 再生の main の init → `freshWorld` の `reloadAll` を start の行のファイルで回す → 始まり。
- 一致の前提「Doc が同じなら reloadAll(init) == init」は、記録しない起動を読み直さない形（§7 の後の直し）と同じ。崩れたら `expect fp` で止まる。
- 再生がどの App を使うかはゲーム次第（fps3d_lab の E2e は `Game.app`＝遊びから、実機の main は `appWithLoading`＝ローディングの画面から）。
  これは今もある違いで、この直しでは変わらない。

### 確かめる経路とテスト
- engine_world（非 pub の `launchWith` の起動の部分を、GL なしで回せる関数に切り出して確かめる）:
  1. 記録して、ディスクの Doc を書き換えてから再生しても、start の行の中身で同じ World（指紋）になる
  2. main が読まない ReloadAll だけの行のパスも start の行に載る
  3. `START="… k=@file"` の @file が start の行に載る
  4. 自前の `reloadOn` のゲームは今と同じ（読み直して拾う）
  5. 記録しない起動は余分に読む回数が 0
  6. loadApp の `LoadProgress.report` が外の handler に届く
  7. start の直後に `expect fp` が書かれ、World がずれる再生はそこで止まる
- 実機: fps3d_lab の `make debug` で main から最初のコマまでの前後・記録 → Doc を変える → `make flow` で再生が通る 1 往復。
- 変えない経路: flow の再生・`/start`・テストの `freshWorld`・Studio の DEBUG 付きプレイ（main が loadAndLaunch を使えば速い経路）。
