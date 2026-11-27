# 引き継ぎ（2026-11-27 14 時ごろ・週の上限 95% で人が止めた）

週の上限（全モデル）が 2026-12-01 01:00（日本時間）に戻るまで作業を止める。再開の手順は [RESUME-PROMPT.md](RESUME-PROMPT.md)。
計画書（`plans/` のうち engine に入れていない物）は private のリポ [ababup1192/flix-plans](https://github.com/ababup1192/flix-plans) に写してある（engine のリポは public なので分けた）。測りの結果は flix-plans の `results/2026-11-27-m4pro.md`、別の機械での測りの手順は `MEASURE-2026-11-27.md`。

## 1. 各リポジトリの今

| リポ | 枝・状態 | remote | 次の手 |
|---|---|---|---|
| flix_game_engine | main = この md（下の 4 つの取り込みの上・push 済み） | ababup1192/flix_game_engine | 2 節の枝・3 節の順 |
| flix-plans | main（push 済み） | ababup1192/flix-plans（private） | 別の機械の測りの結果を `results/` に足す |
| cinder_lab | main = bbaf592・gh-pages 86e3e36（push 済み） | ababup1192/cinder-lab | ピクセル物理は人の判断で止めている。再開は compute の C4 以降の後（案 A: 地形は CPU・飛び散る物を GPU） |
| bistro_lab | main = f7008e7（push 済み） | ababup1192/bistro-lab（private） | `make engine-upgrade` で WebGPU の swap の直し（2579aa0fb）以降を入れる（ゲームのファイルが変わるので人に一言） |
| demo_repro_lab | main = e5b5d4f（push 済み） | ababup1192/demo-repro-lab（private） | Godot の公開デモ 2 本＋Sponza を素材だけで再現・測り済み（tools/perf/SUMMARY-2026-11-27.md） |
| night_school | main（push 済み） | ababup1192/night-school | 触らない（_plan_stalker.md・art/・UPDATE_PLAN.md は除く決まり） |
| spaceship_lab | remote なし（この機械だけ） | なし | PC で Godot に並ぶ目標の 2 本目（格納庫）。手付かず |

この会話で触っていない repo のうち、push していない commit を持つ物: blood-scale（8）・hd2d_lab（9）・conduit_hive（2）・touhou_rebuild（4）。中身を確かめていないので push していない。

**11-27 に main へ入った物**: d1dc7d095 描き手の CPU の直し（C1・C3・組み込みフォント・W-1 案 A）と測りの口 `bin/fge web-perf`／f4486b6bb デカール D0〜D1（`Decal3d`・pub 3・レビュー 91 点）／3a186b06d W-1 案 B（dynamic offset・GL の層の jar は fge-gl-7b7278214ad7）／6b55d1379 毎コマ作って捨てる値の直し（字の組み・材質の変種）。どれも枝に main を合わせて `make verify SUITE=affected SINCE=main` が緑。

## 2. engine の枝（main に未取り込み・remote へ push 済み）

| 枝 | 中身 | 状態 | 次の手 |
|---|---|---|---|
| worktree-agent-a481e18ac9e6ff039（6a93519f0・「途中:」） | デカール D2（半透明のしみも SSAO を受ける）・D3（docs・早見表・お題・gl-parity の場面） | D2 済み（engine・engine_tools・render_gl のテスト緑・鍵の字 +ab・`MaterialFields#screenAoOnBlend` はゲームが触れない）・D3 は docs の節・早見表 3 行・お題 3 本まで。gl-parity の 2 場面は書いたが型検査も gl-parity も未（サンドボックスで glfwInit が止まった）・許容差・backend-parity・migrations・お題の当たり・verify・レビューが残り | 残りを担当に → 門 → 取り込み |
| spike/text-layout-cache | 字の組みをコマをまたいで控えるスパイク（main に入れない）。17b28d046 = 案 1・036fa6a2e = 案 2 | 案 1 で K9 22.6 → 20.6 ms（1 回）・GC は減らない。案 2 は未測 | 別の機械で案 2 を測る → 本体にするかを人に相談（pub の案は 4 節） |
| worktree-agent-acdcbb34ba5db3691 | compute の C4（群れを MultiMesh3d で描く） | 401 で担当が止まった。worktree にコミットしていない変更が 7 ファイル＋新しいファイル（main の案 B と WebGpuRenderer.flix がぶつかる） | 再開時に差分を読み、今の main の上で担当に立て直させる |
| worktree-agent-acea528a59b194393 | GPU compute の C0〜C3 | 済み・レビュー 86 点（main d94198714 に取り込み済み） | — |
| worktree-agent-ae9d7c8e070f30a05 | web のベンチ比べ `bench/web_engine_compare`（three.js などと同じ場面 K1〜K9） | 全段済み・レビュー 90 点。full の前の後片付け 4 つが残る | 後片付け → main へ → full（3.5〜4 時間）は重い仕事と重ならない時に |

## 3. 計画の全体と順番

推す順（人の了承済み）: **リリース（次・W1 以降の分）→ 水 G0〜G4 → リリース → L6 → L7 → リリース → 段 1 の残り**。並べて: 描き手の CPU の直しの続き・デカールの残り・空の計画。

| 計画書（plans/） | 状態 | 要点 |
|---|---|---|
| engine-render-cpu-cache.md | 段 0・0b・S・C1・C3・W-1（案 A → 案 B）済み | 次: ① 2c の条件を測る（決め 2）② C4（PostStack の入力の表とレビューを先に）③ 15 節の候補（BVH・render bundle・半透明の並べの持ち越し）は相談。K3 は 43.5 → 約 30 ms |
| engine-decals.md | 了承・D0〜D1 済み・D2・D3 は 2 節の枝 | D4 は D0 の測りの後・D5 は L6 の後 |
| engine-reflection-probes.md | 1 回目のレビュー 66 点の指摘を直した所 | 2 回目のレビュー → 人の了承 |
| （未作成）空と時間の流れ（procedural sky） | 人が次の計画に入れると決めた | 映り込みの probe より先に（probe が空を映す） |
| engine-water.md | 了承（86 点） | 汎用の部品 3 つ＋水のプリセット 1 つ |
| engine-gpu-compute.md | 了承（90 点）・C0〜C3 済み・C4 は 2 節の止まった枝 | |
| engine-render-look-l5-l7.md | L5 済み・L6・L7 は未着手 | |
| （未作成）超解像 | 人と話した順: 内側の解像度を分ける → FSR1 型（1 コマだけ）→ 動的な解像度 → TAA と動きベクトル → FSR2 系 | うちに合わせる 4 点: CPU の直しより後・UI と字は拡大しない・ドット絵と PS1 風は整数倍の最近傍のまま・FSR2 系は WebGPU だけ。手本に pmndrs/upscaler（MIT・若い）は読むだけ |
| engine-web-bench.md | 実装済み（上のベンチの枝） | |
| engine-render-stage1.md | 了承（読み替えた版） | 段 1 の残り |

## 4. 分かった事（数字）

- **11-27 は機械の重さで絶対値が大きく揺れた**（ほかの担当の門と重なり load average 3〜68）。同じ時に同じ手順で取った前後の比べは使えるが、別の時刻の値どうし・three.js との比は並べない。正式な比は別の機械で three.js と同じ時間帯に取る（flix-plans の MEASURE-2026-11-27.md）。
- K3（2,000 個がそれぞれ別の材質）: 43.5 → C1+C3 40.7 → 案 A 36.7 → 案 B 約 30 ms（案 B の前後は同じ手順で 35.0 / 34.7 → 31.3 / 30.1・createBindGroup 1 コマ約 2,080 → 約 3）。案 B は見込み（33 ms）より効いた。プロファイルの割合（2.78%）より、作る物の数を断った効き（JS との行き来・GC に散らばった分）が大きい。
- K9（名札 1,000 枚）: 24.1 → 22.6 ms（字の組みの直し）・GC 約 27% のまま。字ごとに DrawCmd と Vec2 4 個を作るのが残る。スパイク案 1 で 20.6 ms。
- 見込み: 計画の直しを全部入れて K3 は three.js の約 1/2。1/1.5 から先は BVH や値の持ち方を変える作りの直しが要る。K9 は 1/2 に遠い（描き物 1 個約 20 µs の作りの値段）。
- 字の組みの控えの本体にする時の pub の案: engine に外から作らせない型 `Text.Layout` と `buildLayout`・`layoutMatches`・`layoutToDrawables`（今の `toDrawables` は同じ意味で残す）。控えの置き場は engine の lint が HashMap と System を止めるので engine_world の TileCache。
- デカール: 10 万三角形の的に 1 枚 3.65 ms（JVM）・64 枚の作り直し 96 ms → 弾痕は当たった時に 1 枚ずつ。使わないゲームの wasm は増えない。試しの絵（PS1 風の廊下）で頂点の色の明るさに馴染む事を見た。
- デスクトップの WebGPU の rest 9 ms は GPU の待ち（Bistro 3840×2160 で GPU 9.4 ms）。compute の群れ 8,000 羽の 1 刻みは PC 0.10〜0.21 ms・Chrome 0.05〜0.13 ms。

## 5. 人に聞く事（再開時）

- 字の組みの控え（engine の拡張・4 節の pub の案）を本体にするか。別の機械で案 2 を測った後に。
- engine の直しの候補（相談が要る物）: BVH（K8 pick・K5）・render bundle・半透明の並べの持ち越し・K9-c（1 draw に複数の絵）・`DrawCmd` の Vec2 を受けない入口・X2（線形の ACES）。
- 超解像の計画を起こすか（3 節の順）。
- bistro_lab に `make engine-upgrade` を打ってよいか。

## 6. 守る事（人の決まり）

- push と公開は 1 回ずつ人の了承が要る。ダウンロード・永久の削除・engine の拡張は先に相談。
- `--no-verify`・素の `git stash`・外への投稿は使わない。起動したゲームは PID で止めて ps で確かめる。
- 担当には refactor の表を渡し、画素の差が出たら止めさせ、枝にだけコミットさせて取り込みは自分でやる。
- 外のデモのコードは持ってこない（規約で許された素材だけ）。Sponza は git と配る物に入れない。

## 7. 別のマシンで始める用意

1. `git clone` で engine（public）と、要る物だけ: [flix-plans](https://github.com/ababup1192/flix-plans)（private）・[demo-repro-lab](https://github.com/ababup1192/demo-repro-lab)・[bistro-lab](https://github.com/ababup1192/bistro-lab)・[cinder-lab](https://github.com/ababup1192/cinder-lab)。ゲームは `~/Documents/flix_ge_workspace/` に置く（engine の docs と担当の依頼文がその場所を前提にしている）。
2. 計画書を戻す: `rsync -a <flix-plans>/plans/ <engine>/plans/`。
3. devbox を入れ、engine の根で `devbox shell`（flix 0.78.0・JDK・go が入る。`bin/flix` は devbox の flix.jar を自分で探す）。
4. `make hooks`（pre-commit を配線）→ `make status` で 1 画面を確かめる。worktree を立てたら最初に `make worktree-seed`。
5. git の外の大きい素材は取り直す（どれもダウンロードの許可を人に取ってから）:
   - ベンチの元のリポ: `bench/web_engine_compare` の Makefile が `build/upstream` へ取る（[endel/webgpu-webgl-benchmarks](https://github.com/endel/webgpu-webgl-benchmarks)）。Sponza の glb もその手順。
   - Bistro の glb: bistro_lab の README / plans/engine-bistro-gap.md の取り方。
   - Godot のデモの素材: demo_repro_lab の `assets/CREDITS.md`（godot-demo-projects の commit 281a99f・MIT）。
6. Claude の memory（`~/.claude/projects/...`）は移らない。効き続ける決め事は 8 節に写した。

## 8. 人の決め事・好み（memory から・効き続ける物）

- 日本語で。単語は業界の言葉のまま・説明は平易に・独自の比喩で名付けない。URL は `[URL](URL)` の形（全角かっこにつなげない）。
- 見積もりは実時間で（「◯日」と言わない）。
- engine の計画は汎用の部品・低レイヤーは Internal・ゲームに見せる pub は少なく、各々に「いつ使うか」1 行。デモの機能を並べない。
- engine の穴は 型 → lint → docs の順で塞ぐ。
- 複雑な変更はレビュー役で 80〜90 点を目指す。レビューは最大 3 回、80 点以上で必須が直れば GO。
- 担当が生きているかは最後に書いた時刻と SendMessage で確かめる。区切りごとにコミットさせる。
- 起動したゲームは PID で止めて ps で確かめる。
- ピクセル物理（cinder_lab）は止めている。Studio は凍結（engine の計画に Studio の機能を前提にしない）。
- 配る先はブラウザが本命。性能は「Godot・three.js と並ぶ」を目標に、表現力とパフォーマンスで比べる（配る大きさは比べる軸にしない）。

## 9. 作業の注意点（11-27 の作業で踏んだ物）

**環境・道具**
- python3 は前に `DEVELOPER_DIR=/Library/Developer/CommandLineTools` を付ける（nix の apple-sdk がシムを乗っ取る）。git commit も同じ（pre-commit の check-docs-sync が python3 を使う）。
- flix は `bin/flix`・`bin/fge`・make から流す。`java -jar bin/flix.jar` を直に叩くと Maven へ取りに行き 429 で止まる。worktree を立てたら最初に `make worktree-seed`。
- 層（render_gl・engine_world・engine_tools）の型検査は `make sync-layers` の後に `.layers/<名前>` で `../../bin/flix check`。ゲーム側へ engine の直しを届けるのは `make sync-engine-full`（ゲームの lib は `make engine-upgrade` まで古いまま）。
- foreground の `sleep` は止められる。待つ時は until の繰り返しか、background で流して通知を待つ。
- `cd` で worktree の中へ入ると、その後の作業場所がそこへ移る。終わったら engine の根へ戻る。

**コミットの門（pre-commit）で止まる物**
- `bin/fge jargon`: 新しく書いた行の独自語。「焼く」→「前もって計算する（bake）」など。コミットの前に `bin/fge jargon <ファイル>` で素振りする。 jargon-ok: 止まる語の例として挙げている
- go-test の `TestNoUnbracedVariableBeforeWideChar`: sh で全角の字の直前の変数は `${名前}` と書く（`$log）` は不可）。
- pub や doc コメントを触ったら `make api-digest` を同じコミットに。docs を触ったら `make check-docs-sync`。

**測る時**
- 測る前に `make strays` と `ps`（java・Chrome）と load average を見る。担当が残した java（headless の Bistro など）が GPU を取り合うと、数字が数倍ずれる（11-27 に 1 コマ 10 ms → 41 ms）。
- デスクトップの WebGPU は、画面がロック中・表示が眠っている時に 120 Hz（8.33 ms）へ張り付く。余裕を見るなら GL か画面を起こして測る。
- 描き手どうしは rest・submit・swap で比べない（GPU を待つ時間の入る区間が違う）。1 コマの間隔と `FLIX_GE_GPU_TIMER=1` の GPU の時間で比べる。
- ベンチの full（3.5〜4 時間）は、ほかの重い仕事（門・書き出し・型検査）と重ねない。

**ブラウザ版の書き出し（W1 の後）**
- `web/WebMain.flix` を持つゲームは `web/shader-variants.json`（使ったシェーダーの組の記録）が要る。無いと書き出しが止まる（`--draft` の時だけ既定の一式で書き出す）。記録は `bin/fge run` / `bin/fge debug` で遊ぶと書き足される。表に無い組は頂点の色で描かれ、console.error が 1 行出る（web-load-check が赤にする）。

**担当（サブエージェント）の扱い**
- 同じパッケージを 2 人に触らせない。今は「描き手の CPU の直し（WebGpuMaterials・SceneList・ScenePlan・StaticRows・2D）」と「compute の C4 以降（新しいモジュール・WebGpuRenderer.prepare の頭・MultiMesh3d の欄）」に分けてある。
- 担当の最後の報告は 1 回だけ届く。background の仕事を残して止まった担当は、続きを SendMessage で頼み直す。レビュー役の点数は書き手の報告より後に届くことが多いので、レビュー役へ直接「main へ送って」と頼む。
- 担当の緑の主張は、取り込む前に自分で `make verify SUITE=affected SINCE=<取り込む前の main>` を流して確かめる（11-27 は L5 の後に自分の書いた sh の誤りが 1 件赤になった）。
- 計画書（`plans/`）は git の外。直したら flix-plans の写しも更新する（README の rsync の 1 行）。

**engine の計画と API の形（人の指摘・11-27）**
- 水の計画の初版は、ゲームに見せる pub が 43 個あった。人の指摘は 3 つ: AI がこれを使い分けられるか・性能のための低レイヤーは呼びにくく（private・Internal）できないか・今回のデモに引っ張られていないか。書き直して 11＋型 1 になった（compute も 12）。
- 計画を書く時の物差し:
  - 使い道ごとの専用の API を並べず、汎用の部品を少数作り、使い道はその上のプリセットにする（水 = 頂点の変位・奥行きの差・depth prepass の 3 つ＋水のプリセット 1 つ）。
  - 低レイヤー（pipeline・bind group・kernel・評価器・格子）は `*.Internal` に置き、lint `app-internal` の対象に足してゲームから呼べなくする。
  - ゲームに見せる pub は 1 つずつ「いつ使うか」を 1 行で書き、計画書に数を出す（節ごとに数をそろえる）。
  - 動詞は大手の命名に合わせる（`get*` は安い・`build*` / `compute*` は計算して作る）。名前は業界の語（Unity・Godot・Bevy）。
  - 早見表（agents-pack/AGENTS.core.md）の 1 行と agent-eval のお題（正しい道を期待し、Internal や手組みを avoid にする）を計画の段階で書く。
  - 需要が無い API は足さない（windSway は今のゲームに使う所が 0 件だったので docs の例にした）。
  - デモの機能の表から逆算しない。部品の形は複数の使い道を当てた表で決める（compute は群れ・粒子・FFT の海・セルの 4 つで決めた）。
- 計画のレビューでも「汎用さ・AI が迷わないか・Internal の切り方」を採点の軸に入れる。

**誤った書き方を止める順: 型 → lint → docs（人の決め・11-25）**
- engine の穴（ゲームや AI が誤って書ける所）は、まず型で書けなくする。型で無理なら lint（`bin/lint-rules/forbid.json` の 1 行の正規表現＋代わりの物・`app-internal`）で止める。最後に docs と早見表に書く。docs だけで済ませない。
- 型で止める書き方:
  - 外から作らせない値は、pub mod の中の非 pub の enum＋`pub type alias`（Flix 0.78。書き方は `/flix-docs`）。
  - 取り違えやすい 2 種類は型の目印で分ける（compute の `Simulation3d[Elements]` / `[Cells]`）。
  - 足し忘れを止めたい表は enum にして網羅の match で引く（compute のプリセットは enum のデータにし、engine の CPU の規則と render_gl の kernel の両方が網羅の match で引く → プリセットを足すと両方の層がコンパイルで止まる）。
  - 遊びの規則に使わせたくない物は、状態や位置を返す pub を作らない（compute は GPU から読む関数を作らない）。
- lint で止めた例（11-27 に足した物）: `render3d-shader-entry-by-hand`（シェーダーの入口を手で書かない）・`render3d-shader-source-direct` と `web-shader-runtime-provider`（W1）・`scene3d-screen-inputs-in-game` と `ssao-custom-spec`（L5）・compute の `webgpu-java-outside-engine`。古い書き方も forbid に 1 行足して止める。
- 新しい型や lint を足したら、早見表に 1 行とお題 1 本を足し、`make agent-eval ONLY=<お題>` が当たるのを確かめる（engine のリポだけの口は AGENTS.md の検証の節と `testdata/agent-eval/engine-repo.json`）。
- **ヘッドレスの Chrome が起動しなくなった（11-27 13:28 から）**: `--dump-dom` の空の頁でもログを出さずに固まる。Chrome の更新ではない。画面のロックが長いと macOS が起動を待たせる、という推測は未確認。web-perf・web-load-check・gl-capture-check が止まるので、再開したら最初に 1 回起こして確かめる。
- **測りは機械の重さを書いてから**: 担当を並べると load average が 60 を超え、同じ書き出しの K3 が 23 ms と 43 ms の間で揺れた。測る担当には各回の load average を書かせ、10 を超える回は捨てさせる。測る間は門を走らせない。
- **担当の測りの写しは worktree に残させない**: `bench/web_engine_compare` の写しや `debug/` が git の外に残ると、`make verify SUITE=affected` が「全部の門」を選ぶ。scratchpad へ退けてから門を流す。
- **取り込みの前に枝へ main を合わせる**: 担当の枝は古い main から出ているので、`git merge main` を枝の側でしてから `make verify SUITE=affected SINCE=main` を流し、緑なら main で `--no-ff` の取り込み。
- **担当は refactor が 1 回落ちると grep へ戻りがち**（11-27 のスパイクで 11 回）。依頼文に「索引の作り直しで 1 回落ちても refactor を打ち直す」と書く。
