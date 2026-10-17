---
name: render-loop
description: "絵を直すときの進め方。ヘッドレス生成で場面を生成して目視で批評し、一度に 1 つだけ直して前後を並べて見せるループを出す。絵・演出・手触りを直すとき、「見た目を直して」「ここが変」と言われたとき、make render SHOT= / make render-all / make diff を使うとき、どこから直すか候補を出すときに使う。"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

# 絵の開発ループ（生成）

決定的な場面をヘッドレス生成で `debug/` に生成し（スナップショットの外）、目視で批評 → 修正 → 再生成を回す。

## 見る前に数値（bench → img-digest → 目視の順）

生成した絵を毎回目視すると 1 枚数千トークン燃える。じょうごで絞る:

1. まず `make -C templates/<name> reference-check`（リファレンス画像とのハッシュ突き合わせ）。**全一致ならここで終わり** —
   digest も目視も要らない
2. 不一致の名前が出た時だけ、その名前を渡して数値で当たりを付ける:
   ```
   bin/fge digest reference/ gallery/ battle.png   # 名前を挙げた絵だけ要約
   bin/fge digest old.png new.png               # 2 枚だけ比べる
   ```
   差分画素率・変化した領域・色数・明るさが数行で出る
3. **画像を開くのは最終確認の 1 回だけ**

- 機械的リファクタ（分割・Doc 化）は「前後の PNG バイト一致」で見た目不変を証明する
- リグレッション防護はリファレンス画像（`gallery/` vs `reference/` のバイト比較）に任せる

## 描き出すのは触った 1 枚だけ

ゲーム側（テンプレ側）の描き出しは 3 つに分かれている。**既定の手は「1 枚だけ」**:

| やりたいこと | コマンド |
|---|---|
| 直した場面 1 枚だけ | `make render SHOT=title` |
| 何枚か | `make render SHOT="title walk clear"` |
| 全部（リファレンス画像と突き合わせる直前） | `make render-all` |

素の `make render` は使い方を出して失敗する。**どの場面を見たいかは自分で決めてから打つ。**

ループ中に全部描き直すと、直した 1 か所を見るのに他の場面のコンパイルと生成の時間を丸ごと払う。
`make render-all` を打つのは `make reference-check` でハッシュを突き合わせる直前と、
リリース前・engine を直した後の退行検知だけ。

## 描き出すのは触ったテンプレだけ

engine リポでテンプレを横断するときも同じで、ルートの `make render-all` は全テンプレを
描き直して実時間 150 秒かかる。ループを回している間は
`make render-changed`（git で変更のあったテンプレだけ。engine 側を直したときは全テンプレが対象）を使う。
ルート側も素の `make render` は使い方を出して失敗する（全部なら `make render-all`・並列なら
`render-par`・変更のあったテンプレだけなら `render-changed`）。

## 一度に 1 つだけ直す

直す所が複数見えても、**一度に 1 つだけ直す**。並びを揃えるため・リストを消化するために
手を広げない（絵に限らず、手触りやテンポも同じ）。

## どれを直すかは人が決める

**選ぶのは人の仕事。** 遊ぶ人から見て目立つ順に候補を**3 つまで**並べる
（1 つ 1 行 + 生成した絵か再現手順）。人は番号で答えれば済む。

コードを見ても、遊ぶ人に何が見えているかは判らない。だから**何を選ぶかをレビュー役に聴かない**。
レビュー役に聴くのは「選んだ 1 つの直し方が 90 点か」だけ。

**ただし壊れている物は聴かずに先に直す** — 落ちる・黒い穴・スナップショットの退行は好みの問題ではない。

## 直したら前後を並べて見せる

`make diff DIR=<game>`。変わった絵だけ `debug/diff/` に「左=前・右=後」で生成できる。
**ファイル名を並べるだけにしない** — 人が 2 枚を切り替えて差を探す羽目になる。

## ループ GIF を生成したら継ぎ目を確かめる

完全ループを狙う GIF（コマ 0 に戻る演出）を生成したら、目視の前に
`make lint-loop`（または `bin/fge loop <framesディレクトリ>`）で
最終コマ→0 コマの継ぎ目が浮いていないか機械検査する。fade・wipe など
最初から戻らない演出は対象外。

## 描き出し / リファレンス画像の作り方（まだ無いゲームに足すとき）

配管一式（SceneRender entrypoint・flix.toml・フォント・HeadlessRender 呼び出し）の写経元は
docs/headless-render-recipe.md。リファレンス画像の更新は `make -C templates/<name> reference-update`（bin/reference-update.sh）、
比較は `make -C templates/<name> reference-check`（bin/reference-check.sh）。git に入るのは SHA256SUMS.txt と title.png だけ。
守ることは 2 つ: 調整中の画は `debug/` 行きの別 entrypoint に分けてリファレンス画像を汚さない・
テストは検証だけ（描き出しは `SceneRender.all` の仕事）。

## 手順

```
- [ ] 1. 壊れている物（落ちる・黒い穴・スナップショット退行）が無いか見た。あれば聴かずに直す
- [ ] 2. 直す場面を 1 枚だけ描き出して目視した（make -C <game> render SHOT=<場面名>）
- [ ] 3. 候補を 3 つまでに絞って人に出した（1 つ 1 行 + 絵か再現手順）
- [ ] 4. 選ばれた 1 つだけを直した（他に手を広げていない）
- [ ] 5. make diff DIR=<game> で前後を並べて見せた
```

絵の部品選びは `docs/art-ref/visual-dict.md`。絵の下限 5 性質は docs/drawing-floor.md が正（`.claude/rules/drawing.md` はその生成物）。
