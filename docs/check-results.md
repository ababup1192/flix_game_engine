# 検査の結果の形（px・snd 共通）

`bin/fge px build|check|snap` と `bin/fge snd build|snap` の検査は、同じ形の結果を返す（Go の `go/internal/checkres`）。
AI が周回の次の手を数で選べるよう、1 件ごとに「何を測り・いくつで・基準はいくつか・あといくつ動かせば合うか・どの op の
どの引数をいくつにするか」を持つ。全部の code の表は [check-codes.md](check-codes.md)（`bin/fge check codes`）。
帯・点・止め時の数は `bin/lint-rules/checkfmt.json`。

## 1 件（result）

```json
{
  "code": "px.ground-contrast",
  "level": "lint",
  "status": "fail",
  "metric": "edge_ground_dL",
  "got": 0.06,
  "want": {"op": ">=", "value": 0.1},
  "unit": "L",
  "ratio": 0.6,
  "gap": 0.04,
  "scope": "frame",
  "where": {"sprite": "slime", "frame": "idle", "x": 3, "y": 9},
  "cause": {"op": "body.ops[1] directional", "script": "sprites[0].parts[0].ops[1]"},
  "fix": {"hint": "外周をランプのもっと暗い段にする…", "try": [{"op": "body.ops[1] directional", "arg": "from", "now": 1, "try": 0}]},
  "msg": "外周と地 #2a2a33 の明るさの差が平均 0.060（0.10 以上にする）"
}
```

| 欄 | 中身 |
|---|---|
| code | 変わらない名前（`px.<検査>[.<規則>][.<測り方>]`・`snd.<検査>[.<測り方>]`）。表に無い code は出ない（テストが止める） |
| level | gate（外れたら書き出さない）・lint・advice |
| status | pass・near（外れているが許容の帯の中）・fail。帯は code ごとに checkfmt.json の `near`（無ければ `nearRatio`） |
| metric・got・unit | 測った物・値・単位（L は Oklab の明るさ・px・count・dBTP・LUFS・ms・samples など） |
| want | 基準の向きと値（`>=`・`<=`・`==`・`range` は min〜max）。向きは表と同じ |
| ratio | 基準に対する割合（1 で合格・遠いほど 0）。dB 系は振幅の比・基準が 0 の数は 1/(1+\|gap\|) |
| gap | got をあといくつ動かせば合格か（符号つき。上げるなら +・下げるなら −） |
| scope | spec（spec 全体）・sequence（コマ列）・frame（コマ全体）・part（部品）・file（書き出した物全体） |
| where | 絵: sprite・frame・x・y・cells（maxCells まで。切ったら cellsTotal）。音: ms（か fromMs〜toMs）・channel |
| cause | 原因の op（`部品.ops[n] 名前`・`voices[0](id).ops[1] 名前`）と spec の中の場所 |
| fix | hint（文）と try（0 個以上の数の候補 {op, arg, now, try, expect}。expect は try にした時の got の見込みで、見込めない物は書かない）。op には宣言を直す疑似の op（`set kind`・`set material`）も入る（宣言の検査は 0.42.0） |

## 1 回のまとめ（summary）

report.json と `--json` の頭の `check.summary`。

| 欄 | 中身 |
|---|---|
| round | 周の比べに入れる検査か。`--only`・`--no-check` は false（`debug/px/<名前>/probe/` に書き、last を触らない） |
| score | 0〜100。fail は level の点（gate 30・lint 8・advice 2）、near はその 0.3 倍を引き、同じ code の 2 件目からは半分ずつ。gate の外れがあれば 40 まで |
| counts | level ごとの near・fail の数 |
| top | 悪い順の上位 5 件（短い形） |
| next | 次の周でまず直す 1〜3 件（全文）。順は 宣言（decl.*）→ gate → fail（spec → コマ列 → コマ全体 → 部品・lint → advice）→ near（1 − ratio の大きい順）。同じ直し方（fix.try の op と arg）で直る物は 1 件 |
| nearWaiting | fail が残る間の near（件数と code だけ。fail が 0 になると next に入る） |
| applied | 絵（音）ごとの当てた検査の組。前の build と組が同じなら `{"id", "changed": false}` だけ、変わった時・最初・`--explain` は full（style・materials・checks・skipped（理由つき））|
| exempt | 外した画素の数 `px`・描いた画素に対する `pct`・前の build との差 `d`。内訳 `units`（pixels: op の Exempt / parts: emissive・poly / rules: lint-sprite / demoted: 重さを下げた件）は増えた時か `--explain` だけ |
| exit | 終了コード（下） |

検査は担当が周の途中で切れない（`--skip` は無い）。外せるのは今までどおり op の Exempt・部品の emissive・sprite.json の
lint-sprite（理由つき）だけで、外した数は毎回 exempt に出る。

## 終了コード

| コード | 意味 |
|---|---|
| 0 | 合格（near と advice だけなら 0） |
| 1 | gate の外れ（near も）。px build は書かない・snd build は WAV を書かない |
| 2 | lint の fail だけ（書き出しはする） |

`px check`（make lint-px と pre-commit の口）は今までどおり 0 か 1。`--strict` を付けた時だけ lint の fail で 2。

## 周回（rounds snap）

`bin/fge px snap` と `bin/fge snd snap` は、周 N の検査を `debug/history/<名前>/rN.check.json` に積み、前の周と code ごとに比べる
（悪くなった → 新しく出た → 良くなった → 消えた。code ごとに一番悪い 1 件の got と件数）。まとめの `stop` は止め時の判定:

| rule | 止める時 |
|---|---|
| clear | 検査を全部満たした（この先の質は検査で測れない。絵を push して目で見てもらう） |
| budget | `--tokens 使った/予算` の使った分が予算の `stop.budgetShare` を超えた |
| no-gain | score が `stop.noGainRounds` 周続けて上がらない |
| same-next | next の 1 件目が `stop.sameNextRounds` 周続けて同じ（手を変えるか、基準を見回り役に聞く） |
| continue | 続ける |

上限の周数（rounds.json の maxRounds）はこれと別に今までどおり効く。`bin/fge px diff <spec> rA rB` も code ごとの差を出す。
