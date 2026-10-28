---
name: wire-doc
description: "まだコードに繋がっていない Doc(JSON) を loader（defaults・fail-open）と Res の欄・Resources.reloadRow で配線し、橋渡しテストを最大 3 本書く。JSON を作ったがまだコードから読んでいないとき、「この Doc を繋いで」と言われたときに使う。"
---

# wire-doc — 未配線 Doc の配線

引数: 未配線の Doc ファイル（例: `assets/foo.kind.json`）。

## 手順

1. 既存の Doc loader を1つ読んで、パターンを確認する
   （`fromJson` 系の変換、`defaults`（既定値はコード側）、fail-open —
   壊れた入力で落とさず既定値へ落とす）。
2. 同じ形で新しい loader を書く。`<種類>.schema.json` が無ければ書き、
   `project.json` の `editor.resources[]` に宣言する。
   Doc 本体には必ず `version` を入れる（無いと Studio の健康診断が警告する）。
   schema は Studio の **sections 方言**で書く（engine リポの `docs/doc-conventions.md`
   「スキーマの書き方」。語彙リファレンス形式では Studio のフォームが読めない）。
3. Doc を `Res`（`<ゲーム>/src/Res.flix`）の欄にし、`with*` を足す。保存即反映は `Controls.docTable` に
   `Resources.reloadRow(id, path, reload, settle)` の行を 1 つ足す（World に収め直す物が無ければ settle は `(_, w) -> w`）。
   Doc を World の欄に置かない（`bin/fge record-wrap` の world-resource が止める）。既存の行をお手本にする。
4. 橋渡しテストを **最大3本** 書く:
   - 壊れた JSON → 既定値へ落ちる
   - 1 フィールド上書き → その値だけ変わる
   - rows があるなら、rows の長さに追随する
   期待値は Doc の既定値（コード側の defaults）から導き、数値リテラルを貼らない。
5. `make check` → `make test` で確認して報告する。
