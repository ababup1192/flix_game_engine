# 並べ替えの二乗をなくす — 計画

## なぜ

Flix 0.78 の標準ライブラリの並べ替え（`List`・`Vector`・`Array`・`Chain`・`MutList` の `sort`・`sortBy`・`sortWith`）は、どれも
`Array.sortWithin` の単純なクイックソート（Lomuto・基準は範囲の最後の要素）を呼ぶ。入力が並んでいる時と、鍵が全部同じ時に、
比べる回数が数の二乗になり、再帰も数の深さになる。安定でもない。

3D の描く順（`Render3d.inDrawOrder`。`ScenePlan.materialsInOrder` から）がこれを踏んでいた。鍵は (program, 来た順) で、ほとんどいつも並んだ入力になる。
PLATEAU の都市（1 棟 = 1 個・形がみな違うので batch が物とほぼ同数）で:

| 物の数 | 0.91.0 | 並べ替えを直した試作 |
|---|---|---|
| 2,000 | 46〜52 ms | 13 ms |
| 4,000 | 161 ms | 27 ms |
| 12,546 | 360 ms 以上 | 93〜97 ms |

人の判断（2026-11-11）: 下の 1〜3 を入れる。Flix への報告は下書きを人に見せてから。

## やる事

1. **描く順は振り分けにする**: `Render3d.inDrawOrder` を、鍵（program）ごとに来た順で集め、鍵の小さい順につなぐ形に替える（`Map[Int32, List[a]]` など）。
   描く順は今と 1 つも変わらない（鍵が同じ物は来た順）。呼び手は `materialsInOrder` の 1 か所。
2. **エンジン共通の安定な並べ替えを 1 つ用意する**: どんな入力でも n log n の安定な並べ替え（マージソート）を、エンジンの共通の置き場（core の
   リスト・コレクションの補助がある所。無ければ一番近い既存のモジュール）に足す。名前は AGENTS.md の命名の決まりに従う
   （例: `sortStableBy(keyOf, xs)` と比べる関数を渡す形。Flix の標準の `sortBy`・`sortWith` に合わせた引数の順）。
   - エンジンの `List.sort`・`sortBy`・`sortWith`（と `Vector`・`Array` などの同じ物）の使う所を `bin/fge refactor usages` で全部洗い出し、置き換える。
     置き換えで順が変わる所（今は安定でない並べ替えに頼っていて、同じ鍵の物の順が入力で変わっていた所）は、安定になる事で順が決まる。
     絵の順が変わる所があれば、`make gl-parity` と reference で分かるので、変わった所と理由を報告する。
   - 「来た順の番号を鍵に足して安定にしている」所は、番号を外してよい（安定な並べ替えなら要らない）。外したら WhyNot のコメントも直す。
   - テンプレ（`templates/*`）と bench の .flix も対象に入れるか調べ、入れるなら同じ形で置き換える。
3. **lint で戻さない**: `bin/lint-rules/forbid.json` に、標準の並べ替え（`List.sort(`・`List.sortBy(`・`List.sortWith(`・`Vector.sort…`・`Array.sort…` など）を
   止める規則を 1 行ずつ足す（代わりの物＝2 の関数）。ゲームの側にも効くかは今の forbid の仕組みに従う（ゲームに効くなら agents-pack にも案内）。

## 決まり

- pub の型と関数の形は変えない（足すのは可）。
- 絵は変えない: `make gl-parity` の全場面が今と同じ値・`make reference-check` が一致。変わった所があれば、上の「安定になった事で順が決まった」かどうかを確かめて報告する。
- テスト: 足した並べ替えに、並んだ入力・逆順・全部同じ鍵・空・1 個・安定（同じ鍵の物が来た順のまま）・大きい入力（10 万個でも速い）のテスト。
  `inDrawOrder` に、鍵が同じ物は来た順・鍵の小さい順のテスト。当たるパッケージのテストが緑。
- コメントは WhyNot。経緯は書かない。コミット・push・版上げ・リリースはしない。

## 測り方

- PLATEAU の都市 `~/Documents/flix_ge_workspace/plateau_city`（公開版 0.91.0 の lib を持つ）で、作業ツリーの fpkg を差し替えて:
  `PLATEAU_MODEL=3k_each PLATEAU_LIMIT=<N> START="preset name=aerial3k" FLIX_GE_FRAME_STATS=1 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 make run RUN_SECONDS=90`
  の `間隔 avg`（2 行目以降）を N = 1000・2000・4000・全部（PLATEAU_LIMIT なし）で。1 km の版（`PLATEAU_MODEL=each START="preset name=aerial"`）も。
- 箱庭 `~/Documents/flix_ge_workspace/lamplighter` の 1 コマ（今 約 5.1 ms）が変わらないこと。
- 差し替えの手順と、測った後に lib/ と packages.lock を公開版に戻す手順は、`plans/engine-scene3d-cpu.md` の「測り方」と同じ。

## 報告に書く事

- 足した関数の名前と場所・置き換えた所の数（パッケージごと）・置き換えなかった所と理由
- forbid に足した規則
- テストの本数と結果・`make gl-parity`・`make reference-check`・`make sync-engine-full`
- 都市と箱庭の 1 コマの表（前と後）
- 他にも並んだ入力で二乗になっていた所が見つかったか（2D の描く順など）
