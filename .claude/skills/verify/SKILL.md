---
name: verify
description: "コード変更後に、変えたパッケージだけのテストと実機での動作確認を順番に行う（人が /verify で呼ぶ）"
disable-model-invocation: true
allowed-tools:
  - "Bash(make test-*)"
  - "Bash(make check*)"
  - "Bash(bin/flix *)"
---

# 変更後の検証

**テストは絞って速く回す。全量の検証はリリース直前の 1 回だけ**（AGENTS.md の「検証」・`/release`）。
ここでは全量（`make test ALL=1`）は流さない。まとめて流す口は `make verify SUITE=<名前>`: 作業中の既定は `quick`
（型検査・precommit の素振り・lint・配線の検査）、`test`・`release`・`gui` はリリースの前。

flix は `bin/flix`・`bin/fge`・make から流す。`java -jar bin/flix.jar` を直に叩くと
Maven の取り物の置き場（lib/cache）を通らず、依存を取りに行って止まる。

## 手順

### ステップ 1: テスト

変更が波及したパッケージだけ `make test-<name>` を流す（例: `make test-engine`・`make test-engine_world`・
`make test-rpg-starter`）。テストを持たないパッケージ（templates など）は `make check` か、そのフォルダで `bin/flix check` で足りる。

- **緑**: ステップ 2 へ
- **赤**: `.test-logs/<名前>.log` から失敗したテストとエラーを省かずに報告して**止まる**。ステップ 2 には進まない。
  コンパイルエラーなら `/compile-fix` を引く

### ステップ 2: 動作確認

テストが緑になった後、ゲームのフォルダで `make run` を人に流してもらい、ビルドエラーや動きの問題が無いかを確かめてもらう。
自分で起動した時は、確かめ終えたら PID で止めて `ps` で消えたのを見る。

## 注意事項

- テストが赤のまま動作確認へ進まない
- エラーメッセージは省略せず、直すのに要る情報を全部含める
