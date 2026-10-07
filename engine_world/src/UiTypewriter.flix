// UiTypewriter — 文章を1文字ずつ現す「文字送り」の進み具合を持つ小さな値。
// どのメッセージダイアログでも、進行・早送り・完了判定・文言切替の検出を書き直さずに共有できる。
// 利用例: start(text) を状態に持ち、毎フレーム step で進め、visibleText を UiStore.setText で流し込む。
// 制約: 文字は UTF-16 単位で数える。かな・漢字は 1 文字だが、絵文字（サロゲートペア）は途中で割れ得る。
pub mod UiTypewriter {

    /// 文字送りの進み具合。text = 表示したい全文、shown = 見えている文字数（dt を足し込むため小数で持つ）。
    pub type alias Reveal = { text = String, shown = Float64 }

    /// 全文の文字数（UTF-16 単位）。
    def charCount(text: String): Int32 =
        String.toList(text) |> List.length

    /// 0 文字（何も見えていない）から始める。
    pub def start(text: String): Reveal =
        { text = text, shown = 0.0 }

    /// 最初から全文が見えている状態を作る。
    pub def done(text: String): Reveal =
        { text = text, shown = Int32.toFloat64(charCount(text)) }

    /// cps（1 秒あたりの文字数。60 が読みやすい目安）× dt だけ進める。全文で止まる。
    pub def step(cps: {cps = Float64}, dt: Float64, reveal: Reveal): Reveal =
        let total = Int32.toFloat64(charCount(reveal#text));
        { shown = Float64.min(total, reveal#shown + cps#cps * dt) | reveal }

    /// 全文表示へ飛ばす（決定キーでの早送り）。
    pub def skip(reveal: Reveal): Reveal =
        done(reveal#text)

    /// 全文が見え終わったか。
    pub def isDone(reveal: Reveal): Bool =
        reveal#shown >= Int32.toFloat64(charCount(reveal#text))

    /// いま見えている文字数（整数）。スパン列など文字列以外の見せ方をする側が
    /// RichText.take などに渡して使う。
    pub def visibleCount(reveal: Reveal): Int32 =
        Num.floorInt(reveal#shown)

    /// いま見えている先頭部分の文字列。UiStore.setText へそのまま渡せる。
    pub def visibleText(reveal: Reveal): String =
        String.toList(reveal#text)
            |> List.take(visibleCount(reveal))
            |> List.map(Char.toString)
            |> List.foldLeft(String.concat, "")

    /// 表示すべき全文が変わったら最初からやり直し、同じなら現状維持（文言切替の検出）。
    pub def sync(text: String, reveal: Reveal): Reveal =
        if (text == reveal#text) reveal else start(text)
}
