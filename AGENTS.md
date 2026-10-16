## 会話ポリシー

日本語で会話してください。途中報告なども含めて、日本語で回答してください。

言葉づかいには 2 つの層があります。混ぜないでください。

**単語は業界の言葉をそのまま使う。** ゲーム業界・ソフトウェア業界で通じる語を優先し、
カタカナ（和製英語）か英語のまま書く（レイヤー・バージョン・ボタン・オーバーレイ・
スプライト・`Layer` `Version`）。**和語へ言い換えない。造語も作らない。**
読み手はエンジニアです。

**説明は平易に。** 難しい数学用語・専門用語に寄りかからず、何が起きるのかを普通の
言葉で書く（「線形補間する」ではなく「2 つの値の間をなめらかにつなぐ」）。

**独自の比喩で名付けない。** このリポジトリでしか通じない言い回しは、人が読めない
だけでなく grep で辿れなくなる（同じ物が別の字で書かれ、1 つの字が 4 つの意味を持つ）。
コミット時に `bin/fge jargon` が**新しく書いた行だけ**を検査して止める。
言い換え先（と英語）はその WORDS を見る。手動で全量なら `make lint-jargon`。

## 名前の付け方（モジュール・関数・変数）

**英語にすれば安全、ではない。** `bless` `carve` のように、英単語でも
このリポジトリだけの意味を持たせると、初めて読む人にも海外の人にも通じない。
上の言葉づかいの決まりは、そのまま識別子にも当てはまる。

### 1. 同じ物を指す言葉が業界にあるなら、それを使う

探す順番:

1. **ゲーム業界の語** — `sprite` `tilemap` `viewport` `hitbox` `atlas` `tween`
2. **ソフトウェア一般の語** — `cache` `buffer` `snapshot` `pipeline` `handler` `registry`
3. **他のゲームエンジンが同じ物をどう呼んでいるか** — Unity / Unreal / Godot / Bevy。
   同じ物に別の名前を付けない（このエンジンは Bevy の render-from-World の考え方に
   そろえているので、迷ったら Bevy の語を見る）

3 つとも当てはまらない物にだけ、説明的な名前を組み立てる（`silhouettePng` のように、
読んで何をする物か分かる形）。**比喩で名付けない。**

### 2. 動詞は大手の命名規則に合わせる

| 動詞 | 意味 |
|---|---|
| `get*` | 取り出すだけ（安い・失敗しない） |
| `load*` / `fetch*` | 外から取ってくる（遅い・失敗しうる） |
| `build*` / `make*` / `compute*` | 計算して作る |
| `is*` / `has*` / `can*` | Bool を返す |
| `set*` / `with*` | 値を差し替える（`with*` は元を変えず新しい値を返す） |
| `to*` / `as*` | 型を変える（`to*` は作り直す・`as*` は見方を変えるだけ） |

**1 つの動詞に 2 つの意味を持たせない。** `get` が実は読み込みに行く、のような名前は
呼ぶ側が値段を読み違える。

### 3. 迷ったときの決め方

その名前を英語で読んだ人に意味が通るか。通らないなら、業界の語をもう一度探す。

## 設計・実装

- **絵の下限（矩形だけの画面から脱する 5 性質）**: [docs/drawing-floor.md](docs/drawing-floor.md)
- **Flix の決まり（予約語・コメントの流儀）**: [docs/flix-conventions.md](docs/flix-conventions.md)
- **エラー処理（既定値で続ける / `Err` を返す / `bug!` で止める の使い分け）**: [docs/error-handling.md](docs/error-handling.md)
- **z-index の範囲の地図（world / UI / Transition / HUD / デバッグの重なり順の仕切り）**: [docs/z-bands.md](docs/z-bands.md)
- **性能（3 つの門・どこまで直すか・残っている二乗の一覧）**: [docs/performance.md](docs/performance.md)
- engine_world の「やりたいこと → モジュール」逆引きと全モジュール一覧: [docs/module-index.md](docs/module-index.md)
- engine/ 側（描画・音・入力などの土台）のモジュール索引: [docs/engine-module-index.md](docs/engine-module-index.md)
- **API の型・引数はソースを grep する前に** [docs/api-digest.md](docs/api-digest.md)（全 pub 宣言の生成物）を引く
- headless の描き出しを新しい場所で組むときの写経元: [docs/headless-render-recipe.md](docs/headless-render-recipe.md)
- 音の付け方（効果音づくり・鳴らす配線・音の下限チェックリスト）: [docs/audio.md](docs/audio.md)

複雑で大規模な変更の場合は、いきなり実装をせず、レビュー役を立てて、壁打ちして80~90点以上を目指してください。
実装はするだけで満足せず、レビュー役に仕様漏れ・リファクタリング余地が無いかを確認してもらいましょう。

エンジン（engine/ 配下）を拡張するときは、**実施前に必ず相談する**。判断軸は汎用性。

## 仕事の配り方（サブエージェント）

**調べ物・広い検索・独立して進む実装はサブエージェントへ渡す**（軽い物は安いモデルで
足りる）。自分は分解・検証・報告に専念する。試行錯誤の過程を自分の文脈へ流し込むと、
肝心の判断に使える余地が減る。**渡さない**のはエンジン拡張の相談・リリース・コミットと、
受け取った結果の検証（緑の主張は自分で 1 回確かめる）。

並行で走らせるときは**同じパッケージを 2 人に触らせない**（型検査は Stop /
SubagentStop で走り、他人が編集中の赤で止まる。常駐 repl の数の上限は
[docs/checkd.md](docs/checkd.md)）。設定でサブエージェントが使えないときは、
黙って全部自分でやらず**止まっていることを人へ言う**。

## コーディングポリシー

コードには **How** / テストコードには **What** / コミットログには **Why** / コードコメントには **WhyNot**

特にコードコメントは WhyNot を重視し、How・What を書かない。実装の由来や旧実装などの歴史背景も書かない。

## 絵と音

**`RawDraw.box` を並べただけの画面は未完成。** 求めるのは 5 性質（面に階調か質感 / 主役が背景から
分離 / 層が分かれている / 時間が流れている / 形が物として読める）で、**どの画風で満たすかは自由**。
画風はゲームごとに決め直す（既定は無い。テンプレどうしでもそろえない）。
図形プリミティブ（RawDraw）は材料。View は完成品の部品で組む。

絵を書く前に必ず `/visual-dict` を引く（本文は `.claude/skills/visual-dict/`。
まず `SKILL.md` の手順、部品選びは `reference.md` と `unused-parts.md`）。
下限の全文は [docs/drawing-floor.md](docs/drawing-floor.md)。
音も絵と同じ強さで意識する（[docs/audio.md](docs/audio.md)）。

lint 群（矩形だけの View・色票・画像の量・画素の並び・コマ間）は保存時とコミット時の
フックが自動で走らせる。手動で回す口の一覧は `make help`。

### 生成した絵は git に入れない

生成した `gallery/` と `reference/*.png` は git 管理外。人に見せる絵は
[docs/gallery/](docs/gallery/README.md) へ選んでコピー、退行検知は
`templates/*/reference/SHA256SUMS.txt`（例外は Studio が読む `reference/title.png` のみ）。
違反はコミット時に pre-commit ゲートが止める（配線 `make hooks`、理屈ごと `bin/fge precommit`）。

## 検証

現状把握は、セッション開始時に自動で流れる `make status` の 1 画面から。
git log 掘りやテスト回し直しから始めない。

**新しい仕組み（API・make の口・lint）を入れたら**、`agents-pack/AGENTS.core.md` の早見表に 1 行と
`agents-pack/agent-eval/engine.json` にお題を 1 本足し、ゲームの足元で `make agent-eval ONLY=<お題>` が当たるのを確かめる。
古い書き方は `bin/lint-rules/forbid.json`（1 行の正規表現 + 代わりの物）で止める。
リリースの後は、ゲームを追随させてから `make agent-eval-release`（全部のお題を 3 回・約 20 分・`docs/agent-eval.md`）で前の版と比べる。ゲートではない（知らせるだけ）。

**テストは絞って速く回す。全量の検証はリリース直前の 1 回だけ。**
変更が波及したパッケージだけ `make test-<name>`、それ以外は `flix check` で足りる。
テストの範囲・書き方は `/quality-assurance`、リリース手順は `/release`。

## Doc（`*.kind.json`）の流儀

ゲームの値は、なるべくコードに直書きせず **Doc へ外に出す**。外に出せばエディタ
（flix_ge_studio）でフォームやスライダーから触れて、**走らせながらその場で変えられる**。

- **外に出す物**: 繰り返し調整する数値（テンポ・閾値・収支・確率）、個数が増減するデータ
  （配置・敵・アイテム）、色テーマ、文言
- **外に出さない物**: 描画アルゴリズム・演出の形、導出できる値、一度決めたら触らない構造。
  **振る舞い（ルール・当たり判定・生成）はコードのまま**

判断軸は「保存即反映で調整できると嬉しいか」。ロジックを JSON に書き始めたら設計の匂い。
外形規約・分け方・スキーマ方言は `/doc-design` と [docs/doc-conventions.md](docs/doc-conventions.md)。

## スキル

| いつ | 必ず引く |
|---|---|
| 新しいゲームを作り始めるとき・画風がまだ決まっていないとき | `/style-interview` |
| View / 背景 / キャラ / エフェクトを書く**前** | `/visual-dict` |
| ドット絵（画素を 1 つずつ置く絵）で行くと決まった後 | `/retro-pixel` |
| ドット絵のキャラ・生き物を描く・直す・自己批評するとき（顔は faces.md・歩きは animation.md） | `/px-character` |
| Flix を書く前・テストを書く前 | `/flix-docs` |
| コンパイルエラーが出たら | `/compile-fix` |
| テストを設計するとき | `/quality-assurance` |
| Doc(JSON) を新設・拡張するとき | `/doc-design` |
| 絵・演出を直すとき | `/render-loop` |
| templates/ を足す・直すとき | `/add-template` |
| バージョンを上げる・公開するとき | `/release` |

**絵を書き始める前に `/visual-dict` を引いていない場合、その作業は未着手として扱う。**

### スキルを持たないエージェントへ

`/名前` の中身は**ただの markdown**。どのエージェントでも `.claude/skills/<名前>/SKILL.md` を
直接読めば同じ内容が手に入る。規約の本文は `docs/` とこのファイルに一本化してあり、
`.claude/rules/*.md` は `make rules` の生成物、`CLAUDE.md` は `@AGENTS.md` の 1 行。
配線の崩れは `make check-docs-sync` が検査する。**規約を直したら本文の方を直す。**
