# 再開用のプロンプト（週の上限が戻った後に、新しい会話の最初に貼る）

下の枠の中をそのまま貼る。

```text
flix_game_engine の作業を再開する。別のマシンなら先に HANDOFF.md の 7 節（用意）を済ませる。まず engine の根の HANDOFF.md を全部読み（8 節の人の決め事も守る）、make status の 1 画面を見て、今の状態を 10 行で私に言ってから進めて。

進め方（全体のオーケストレーション）:
1. 担当（サブエージェント）の取り込み
   - git の枝 worktree-agent-* のうち main に入っていない物を一覧にし、HANDOFF.md の表と照らす。
   - W1 の枝: 止まった所から担当を立て直して最後まで（計画は plans/engine-wasm-shader-prebake.md）。済んだら自分で make verify SUITE=affected SINCE=main を流し、緑なら main へ取り込む。push は私に聞く。
   - ベンチの枝（web_engine_compare）: 残りの段とレビューを担当に任せる。full を流す前に私に一言。
2. W1 が入った後に並べて始める（同じパッケージを 2 人に触らせない）
   - compute の C4〜C6（plans/engine-gpu-compute.md・C0〜C3 の枝を土台に）
   - 描き手の CPU の直し（plans/engine-render-cpu-cache.md・まだ了承を取っていなければ先に私に決め事を聞く）
   - その後にリリース（/release）、続けて水の G0〜G4（plans/engine-water.md）
3. 担当への依頼文には必ず: AGENTS.md の refactor の表・画素の差が出たら止めて報告・枝にだけコミット・main への取り込みと push はしない・区切りごとにコミット・最後にレビュー役で 80 点以上・refactor の回数と grep の理由を報告、を入れる。worktree は make worktree-seed から。
4. 自分は分解・検証・報告に専念する。緑の主張は自分で 1 回確かめる。報告は日本語で、表と短い段落で。
5. 週の上限を時々 get_usage で見て、90% を超えたら担当を絞り、97% で HANDOFF.md を書き直して push し、この再開のプロンプトを最新にする。

守る事: HANDOFF.md の 6 節（push と公開は 1 回ずつ了承・engine の拡張は先に相談・--no-verify と素の git stash は使わない・起動したゲームは PID で止める 等）。
```
