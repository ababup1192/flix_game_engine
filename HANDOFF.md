# 引き継ぎ（2026-11-27 書いた時点・週の上限 91%）

週の上限（全モデル）が 2026-12-01 01:00（日本時間）に戻るまで作業を止める。再開の手順は [RESUME-PROMPT.md](RESUME-PROMPT.md)。
計画書（`plans/` のうち engine に入れていない物）は private のリポ [ababup1192/flix-plans](https://github.com/ababup1192/flix-plans) に写してある（engine のリポは public なので分けた）。

## 1. 各リポジトリの今

| リポ | 枝・状態 | remote | 次の手 |
|---|---|---|---|
| flix_game_engine | main = W1 取り込み（da66aea74）の上にこの md（push 済み） | ababup1192/flix_game_engine | 下の「engine の枝」を順に取り込む |
| cinder_lab | main = bbaf592・gh-pages 86e3e36（push 済み） | ababup1192/cinder-lab | ピクセル物理は人の判断で止めている。再開は compute の C4 以降の後（案 A: 地形は CPU・飛び散る物を GPU） |
| bistro_lab | main = f7008e7（push 済み） | ababup1192/bistro-lab（private） | `make engine-upgrade` で WebGPU の swap の直し（2579aa0fb）を入れる（ゲームのファイルが変わるので人に一言） |
| demo_repro_lab | main = e5b5d4f（push 済み） | ababup1192/demo-repro-lab（private） | Godot の公開デモ 2 本＋Sponza を素材だけで再現・測り済み（tools/perf/SUMMARY-2026-11-27.md）。ブラウザの 1 コマの CPU は Godot の約 2 倍（Lights 1.1 / 2.1 ms）・最初の絵はこちらが速い。見た目は映り込み・光の数・GI が足りない |
| night_school | main（push 済み） | ababup1192/night-school | 触らない（_plan_stalker.md・art/・UPDATE_PLAN.md は除く決まり） |
| spaceship_lab | remote なし（この機械だけ） | なし | PC で Godot に並ぶ目標の 2 本目（格納庫）。手付かず |

この会話で触っていない repo のうち、push していない commit を持つ物: blood-scale（8）・hd2d_lab（9）・conduit_hive（2）・touhou_rebuild（4）。中身を確かめていないので push していない。

## 2. engine の枝（main に未取り込み・remote へは退避の push 済み・作業は続いているので最新は remote を見る）

| 枝 | 中身 | 状態 | 取り込む時 |
|---|---|---|---|
| worktree-agent-acea528a59b194393 | GPU compute の C0〜C3（Java の API・engine と render_gl の Internal・Dawn のテスト・測りの道具） | 済み・レビュー 86 点 | C1 はいつでも可。C2・C3 は C4（W1 の後）と一緒に |
| worktree-agent-ae9d7c8e070f30a05 | web のベンチ比べ（WebGPU Engine Bench の harness に flix の adapter） | S0〜S7 済み（16 場面・555 配列が元と一致）・残りは quick とレビュー | S7 とレビューの後。full（3.5〜4 時間）は他の重い仕事と重ならない時に |

## 3. 計画の全体と順番

推す順（人の了承済み）: **W1（済み）→ リリース（次）→ 水 G0〜G4 → リリース → L6 → L7 → リリース → 段 1 の残り**。compute の C4〜C6 は W1 の後、描き手の CPU の直しも W1 の後。

| 計画書（plans/） | 状態 | 要点 |
|---|---|---|
| engine-render-look-l5-l7.md | L5 済み（main 098323be7）・L6・L7 は未着手 | L5 = SSAO（`PostStack.withAmbientOcclusion`） |
| engine-wasm-shader-prebake.md | 済み（main da66aea74・wasm −8.3%・遊べるまで 14.5 秒） | 記録に無い材質の形は頂点の色で描く・ShaderVariants の 2 関数を残す（人の了承） |
| engine-water.md | 了承（86 点・必須は直し済み） | 汎用の部品 3 つ＋水のプリセット 1 つ・ゲームが見る API 11＋型 1。windSway は v1 に入れない |
| engine-gpu-compute.md | 了承（90 点）・C0〜C3 済み | 汎用の部品 3 つ・pub 12・1 本目は群れ 8,000 羽。見た目だけ（遊びの規則に使わない） |
| engine-render-cpu-cache.md | 了承（84 点・W1 の後に段 0b から） | 共通の所から持ち越し → 絵の bind group → K9 名札の 2D のまとめ描き。目標: どの場面も three.js の 1/2 以内・K3 と K9 は 1/1.5 以内 |
| engine-web-bench.md | 了承・実装中 | 上のベンチの枝 |
| engine-render-stage1.md | 了承（読み替えた版） | 段 1 の残り（影のカスケードの直しなど） |
| （新・未作成）場所ごとの映り込み（reflection probe・HDR の回転）＋後ろの段に GI の前もって計算した irradiance probe（baked） | 人が次の計画に入れると決めた（11-27）。計画を起こす | Material Testers との並べで一番差が出た所。GI は A（前もって計算した probe・3 つの描き手）を先に、B（SSGI）は TAA と SSR の後の上乗せ、C（ボクセル・SDF の動く GI）は当面やらない |
| （新・未作成）デカール（壁の汚れ・血・弾痕・道路の標示を形を作らずに貼る） | 人が優先して入れたいと決めた（11-27）。計画を起こす | 映り込み・空と並ぶ次の表現力の計画 |
| （新・未作成）空と時間の流れ（procedural sky） | 人が次の計画に入れると決めた（11-27）。計画を起こす | 太陽の位置から空の色・朝昼夕 |
| web-export-showcase-survey.md | 調べ済み | Unity・Godot の web 書き出しの上の方 |

## 4. 分かった事（数字）

- web のベンチ（smoke・M4 Pro・Chrome・WebGPU）: まとめる書き方は three.js と並ぶ（K2・K5）。負けている所: K3 入れ替わり 約 1/4.5（絵の bind group を毎コマ 1,721 回作る）・K9 名札 約 1/27（2D のまとめ描きが絵の替わり目で切れる・1,000 枚で draw 3,003 本）・K7 半透明 1/2.5〜1/16・K8 pick 約 1/60（BVH が無い）・K5 まとめない 約 1/2.7。配る大きさは 1.4 MB（比べる軸にしない）。
- デスクトップの WebGPU の rest 9 ms は CPU でなく GPU の待ち（Bistro を 3840×2160 で GPU 9.4 ms）。swap に記録する直しは 2579aa0fb。画面がロック中の 120 Hz の頭打ちは測り直していない（人: 120 出ていれば良い）。
- compute の測り: 群れ 8,000 羽の格子の 1 刻みは PC 0.10〜0.21 ms・Chrome 0.05〜0.13 ms。CPU で同じ規則は 16〜76 ms。

## 5. 人に聞く事（再開時）

- engine の直しの候補（相談が要る物）: BVH（K8 pick）・render bundle・engine の 2D の助言の行を console に出す出し方・staticGroup の出し入れを「作り直し」と読む知らせ・X2（線形の ACES）。
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
