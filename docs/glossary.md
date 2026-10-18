# 用語集 — UI の言葉とコード側の名前の対応

Studio の画面に出す名詞と、その中身の対応表。**一つの概念に言い方は一つ。**
Studio は名詞を発明しない。UI に出す名詞は、この表にある語か、ゲームが project.json の
`editor.resources` で宣言したタイトルだけ(宣言されたタイトルは括弧の前をそのまま使い、
言い換えない)。表に無い名詞を出したくなったら、先にこの表へ足す。

English の列は、将来この UI を英語化するときの対訳。日本語と 1 対 1 で対応させる。

ここに載るのは**使う語だけ**。使ってはいけない語のリストは `bin/lint-rules/jargon.json` の
words だけが持つ(この表には置かない)。

## 文の決め方

- **それをするとどうなるかが分かる言葉を使う**。読んで意味が取れず、説明が要る言葉は使わない
- コード側の名前(promote / family / slot / entityId 等)はコード・ログ・make の世界のもの。UI に出さない
- ひらがなを多用しない。実在ゲーム名を説明に使わない
- 案内の文は、して欲しい**行動**を言う(機能の一覧にしない)
- 次の一歩が無い画面を作らない — 案内カードには必ず押せるボタンを添える
- 案内は普通の説明文で書く。セリフ調・体言止めの演出をしない
- 未実装には「◇これから」チップを付ける。押したら何になる予定かを一言で返す
  (押しても何も起きないボタンを置かない)

## 入口 — 新しいゲームを作る

| UI の言葉 | English | 意味 | コード側の名前・実体 |
|---|---|---|---|
| ジャンル | Genre | 新しいゲームの入口のカード。何を含むかは「含む: …」の行に書く | family(/genesis/families) |
| テンプレート | Template | 動く最小ゲーム。選ぶと複製される(ランダム生成はしない) | templates/(starter) |
| エッセンス | Essence | その世界を一行で表した文。遊びにもアセットの方向性にも反映される | `AGENTS.local.md` |
| プロンプト | Prompt | AI に貼る文。公式プロンプトは骨格と完了条件を書き込んだ下書き(UI では「依頼文」と書かない) | /prompt/* |
| アレンジ | Customize | 生まれたゲームのパラメータを変えて、自分のものにしていく行為 | — |
| 昇格 | Promote to template | 良く育ったゲームを templates/ 入りさせて、ジャンルの公式テンプレートにする(◇これから) | — |

## アトリエ — アセットと値を触る部屋

| UI の言葉 | English | 意味 | コード側の名前・実体 |
|---|---|---|---|
| アトリエ | Atelier | 下の 4 部屋の総称。部屋は迷わないための区切りで、行き来は妨げない | storehouse / picks / extend / archive |
| パラメータを変える | Tune parameters | 値を保存即反映で変える部屋 | storehouse |
| パラメータ | Parameter | そこで触れる値(速さ・色・文言など) | Doc のフィールド |
| アセットを切り替える | Swap assets | いまのアセットを別のアセットと見比べて切り替える部屋 | picks / swap |
| アセットスロット | Asset slot | assets/ のパス = 差し替え点。スロットは動かず、中身が替わる | slot |
| 候補 | Candidate | 採用前の試作 | atelier/*.json |
| 候補を作る | Generate candidates | AI に頼んで候補を増やす操作(プロンプトを作って渡す) | /prompt/atelier |
| これを使う(採用) | Use this | 候補の中身をアセットスロットへ移す操作。移った候補は候補ではなくなる | promote(swap・候補ファイル削除) |
| バージョン(v1, v2…) | Version | 保存・採用のたび積まれる過去の中身。前の中身は消えない(「↩ v3 に戻す」) | `atelier/archive/<base>.vN.<kind>.json` / `draft/sketch/<名前>/vN.json` |
| クイック編集 | Quick edit | アセットをその場で直すポップアップ(グリッド・カーブ・音のスライダー) | PixelEditor / MapEditor |
| ゲームを広げる | Extend game | ゲームの構造(コードと Doc の形)が変わるプロンプト。検査つき | extend(/prompt/extend) |
| シーンを足す / メカニクスを足す / アセットの種類を足す | Add scene / mechanic / asset type | 「ゲームを広げる」の 3 つの入口 | kind=scene / mechanic / material |
| アーカイブ(する) | Archive | 使わない候補と過去バージョンの置き場(へ送る)。何も捨てない | atelier/archive/ |
| 候補に戻す | Restore | アーカイブから候補の列へ | /atelier/restore |
| 選んだ組み合わせで試す | Try combination | 複数の候補を、何も書き換えずに組み合わせて走らせて比べる(◇これから) | — |

## 絵を見る・直す

| UI の言葉 | English | 意味 | コード側の名前・実体 |
|---|---|---|---|
| 描き出す | Render | シーンから PNG/GIF を作る操作。UI では「焼く」と書かない(bake はフォント・テクスチャのアトラスを前もって作ることだけを指す) | `make render-all` / `POST /render` | <!-- jargon-ok: 禁じている語そのものを引用して定義している行 -->
| ラフ | Sketch | 人が手で描く下書き。生成された絵と見比べる相手 | `draft/sketch/<名前>/` |
| アノテーションチケット | Annotation ticket | 絵の上で矩形を囲って一言書いた直しの依頼。済んだら `bin/fge tickets close` で archive/ へ下げ、直したコミットと regressedBy（どの前の直しで生まれたか）を ledger（`reports/tickets/closed.jsonl`）に残す | `debug/annotations/` |
| リファレンス画像 | Reference image | 前に「これで正しい」と決めた画面の絵。いまの絵と比べて、変わっていたら知らせる | `templates/*/reference/` |
| 見た目が変わりました | Visuals changed | リファレンス画像との自動比較の知らせ。前と今を見比べられる(見なくてもよい) | /journey/changes |
| 前 / 今 | Before / After | 見比べの 2 枚のラベル | `reference/archive/<scene>.vN.png` / `reference/<scene>` |

## 全体のナビゲーション

| UI の言葉 | English | 意味 | コード側の名前・実体 |
|---|---|---|---|
| 次のやること | Next step | 状態検知から次の一歩を 1 枚だけ出す誘導 | journey(/journey/state) |
| すべてのファイル | All files | 全ファイルの一覧とコード編集への入口。どの部屋にも置く | /files |
| ミニプレイヤー | Mini player | 走っているゲームを Studio 内に小さく映す枠(アトリエの間だけ出る) | — |

## ゲーム側の言葉 — Studio が発明していない語

Studio の UI にも出るが、Studio の概念ではなくゲーム業界・ソフトウェア業界の語。
**和語へ言い換えない**(コマ・脚本・素材・マス ではなく下の表の語を使う)。

| UI の言葉 | English | 意味 |
|---|---|---|
| シーン | Scene | ゲームの 1 画面ぶんの絵と状態(Unity / Godot と同じ語) |
| スクリプト | Script | ノベルの台詞と進行を書いた JSON |
| カット | Cut | スクリプトの中の 1 区切り(再生を始められる単位) |
| フレーム | Frame | アニメーション・GIF の 1 枚 |
| セル | Cell | タイルマップの 1 マス。座標は cell coordinates |
| タイル | Tile | セルに置く 1 枚の絵 |
| レイヤー | Layer | 重ねて描く面(マップエディタの編集対象) |
| アセット | Asset | assets/ に置く絵・音・フォント |
| スプライト | Sprite | 1 枚の絵として動かせる描画物 |
| パレット | Palette | そのゲームで使う色の一覧 |
| フォーム | Form | Doc を項目ごとに編集する入力欄の並び |
| プレビュー | Preview | 保存した中身を映して見せる表示 |
| 実機 | Live game | 別のウィンドウで走っている本物のゲーム(Studio 内の映しではない方) |
