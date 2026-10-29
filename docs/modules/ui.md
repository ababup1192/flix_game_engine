# UI（ui.json・メニュー・スクロール・会話ウィンドウ・フォーカス・ツールチップ）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| メニューを作る（項目列・カーソル・ハイライト） | UiMenu |
| 表示範囲より長い内容をスクロールで覗く（ログ・履歴・一覧） | UiScroll |
| 文章を幅で行に折る（折り返し・wrap）・描く前に行数を数える | RichText（wrapLinesBy） |
| 固定スロットに可変個の項目を流し込む | UiSlots |
| UI を JSON（ui.json）で宣言する | UiDoc / UiSpec |
| 宣言した UI の「名前 → 画面上の矩形」を引く（当たり判定を宣言と共有） | UiDoc（rectsOf / renderWithRects）/ Flex（keyed） |
| UI の箱にドット絵の皮を着せる（九分割スキン。box の skin） | UiExtract（boxPlacedItems）/ UiDoc |
| UI 要素を並べる・整列する | UiLayout / Flex |
| UI の文字欄に実行時の値を差し込む | UiBinding |
| 会話ウィンドウ・文字送りを出す | UiDialog / UiTypewriter（実例: `templates/sound-novel-starter/src/Page.flix`） |
| 会話のシナリオを .yarn（Yarn Spinner の部分集合）で書く・台詞と選択肢を順に出す・話し手やタグを語彙で止める | Yarn（`bin/fge yarn build` が書いた木を loadOr・語彙は vocabJson）/ YarnRunner（start・startAt（.yarn の行まで進める）・step・trace）（実例: `templates/sound-novel-starter/src/Talk.flix`・`templates/sound-novel-starter/src/Stage.flix`） |
| 台本の変数（`$x`）と訪れた数を持ち越す・ゲームから読む／書く・セーブに入れる | YarnStorage（empty・get・set・visitCountOf・toJson・fromJson）/ YarnRunner（startWith・storageOf・withStorage・valueOf） |
| ノベルのセーブ・ロード（読んでいる所に栞を挟み、同じ行・同じ変数から読み直す） | YarnRunner（bookmarkOf・resume・bookmarkToJson・bookmarkFromJson）（実例: `templates/sound-novel-starter/src/World.flix` の saveSlot / loadSlot） |
| 台詞にルビ（ふりがな）を振る（`[ruby=よみ]字[/ruby]`）・ルビつきで折って描く・行数を数える | Yarn（rubiesOf）/ RichText（placeRuby・rubyLineCountBy。句読点は行頭に送らずぶら下げる）（実例: `templates/sound-novel-starter/src/View.flix`） |
| マウスの下の UI 要素を知る | UiFocus。UiDoc の画面の各要素の画面矩形は layoutRects |
| 絵の上に散らばった選べる物を矢印・Tab・ホバーで巡る（キーのフォーカスとホバーを 1 つにする・:focus-visible の枠） | UiFocusNav（Target の列を作るだけ。UiDoc の画面は targetsOfUi。並びの決まったメニューは UiMenu） |
| 説明の窓（ツールチップ）を見ている物の脇の、画面からはみ出さず他の物に重ならない所へ置く | UiTooltip（computePlacement。脇に余地が無い画面は Side.Over で見ている物の上に重ねる。窓の字を折るのは RichText.wrapLinesBy） |
| meta "prefix/N" から番号を読む | UiMeta |

## モジュール 1 行紹介

- **UiDoc** — ui.json 方言の唯一のパーサ。JSON のノード木を Spec へ読み取る。
- **UiSpec** — UiDoc の Spec を UiStore 向けに射影し、spawn / リロードを担う宣言層。
- **UiStore** — UI を作る「部品ごとの表」の束と、その足し引きの基本操作。
- **UiLayout** — 縦か横に並べる指定から、各 UI 要素の画面上の矩形を自動で決める。
- **Flex** — 宣言的なノード木を UiLayout でレイアウトし、描画物の列に落とす薄い汎用層。
- **UiWidget** — UI 要素の「見た目の中身」（箱・文字・スプライト）の属性と操作。
- **UiShape** — 図形 widget の共有語彙（circle / star / line などのパラメトリック図形）。
- **UiExtract** — 配置と表示可否が決まった UI を、描画部が食べられる絵の列に変換する。
- **UiRender** — UI 全体を毎フレーム、そのまま描ける絵の列に変換する入口。
- **UiHierarchy** — UI entity の親子ツリー走査（完全純粋）。
- **UiFocus** — マウス座標の下にある一番手前の UI 要素を見つけて返す。layoutRects で UiDoc の画面の各要素の画面矩形も引ける（hitTestUi と UiFocusNav.targetsOfUi が同じ枠を見る）。
- **UiFocusNav** — 画面の選べる物を名前付きで登録すると、矢印キー・Tab・マウスのホバーでフォーカス（いま見ている物）が巡る。
- **UiTooltip** — 説明の窓（ツールチップ）を、見ている物の脇の「画面からはみ出さず、大事な物に重ならない」所へ置く。
- **UiBinding** — UI のテキスト欄に付けた「差し込み名」を実行時の値に置き換える。
- **UiSlots** — ui.json に用意した固定数のスロットへ、可変個の項目を先頭から流し込む。
- **UiMenu** — 選択メニュー共通の「項目の並べ方」「選択中の見せ方」「カーソルの動かし方」。
- **UiScroll** — 表示範囲より長い内容を位置ひとつで覗く共通の勘定（末尾基準 offset・両端 clamp・▲▼判定）。
- **UiMeta** — UI の目印（meta 文字列）の共通の読み方（接頭辞 + 番号）。
- **UiDialog** — 会話ウィンドウの中身（誰が・何を・どこまで見せたか）と、その進め方。
- **UiTypewriter** — 文章を 1 文字ずつ現す「文字送り」の進み具合を持つ小さな値。
- **Yarn** — 会話のシナリオ（.yarn を Go の `bin/fge yarn build` が書いた木の JSON）を読む codec と、check が読む語彙の書き出し。
  台詞の強制の改行は .yarn に `\n` と書く（木の字に改行が入り、RichText・Text がそこで行を変える。字の `\n` は `\\n`）。
- **YarnRunner** — シナリオの木を直に辿り、台詞・選択肢・コマンド・終わりの出来事を返す純粋な実行器（`<<wait>>` は型で分けた時計の時刻で待つ）。
