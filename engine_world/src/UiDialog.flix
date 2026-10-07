// UiDialog — 会話ダイアログの中身（誰が・何を・どこまで見せたか）を持つ値と、その進め方。
// 「開く→文字送り→決定キーで送る→最後の行で閉じる」の定番の流れを、ゲーム側の分岐なしで共有できる。
// 本文は RichText のスパン列なので、名前だけ色を変える・強調語だけ太くする、ができる。
// 利用例: openWith(lines) を状態に持ち、毎フレーム step、決定キーで advance。
// 枠と話者は apply が UiStore へ刻み、本文は視点側が visibleBody を RichText.place で描く
// （スパンの色分け描画は UiStore の 1 色テキストでは表せないため）。
pub mod UiDialog {

    /// 会話 1 行。speaker = 話者名（空文字なら地の文）、body = 本文のスパン列。
    pub type alias Line = { speaker = String, body = List[RichText.Span] }

    /// 会話の進行状態。lines = 残りの行（先頭が表示中）、reveal = 表示中の行の文字送り。
    /// lines が空 = ダイアログは閉じている。
    pub type alias Dialog = { lines = List[Line], reveal = UiTypewriter.Reveal }

    /// 会話ダイアログの投影先の名前パス束。root = ダイアログ全体（開閉で可視切替）、speaker = 話者の text ノード。
    pub type alias Paths = { root = String, speaker = String }

    /// 閉じた会話ダイアログ。
    pub def closed(): Dialog =
        { lines = Nil, reveal = UiTypewriter.start("") }

    /// 行の列で会話を開く。先頭行の文字送りが 0 文字から始まる。空リストなら閉じたまま。
    pub def openWith(lines: List[Line]): Dialog =
        match lines {
            case Nil       => closed()
            case line :: _ => { lines = lines, reveal = UiTypewriter.start(RichText.plainText(line#body)) }
        }

    /// ダイアログが開いているか。開いている間はゲーム側で移動などの入力を止める判定に使う。
    pub def isOpen(dialog: Dialog): Bool =
        not List.isEmpty(dialog#lines)

    /// 表示中の行（閉じていれば None）。
    pub def currentLine(dialog: Dialog): Option[Line] =
        List.head(dialog#lines)

    /// 表示中の行の文字送りが終わっているか（閉じていれば true）。
    pub def lineDone(dialog: Dialog): Bool =
        UiTypewriter.isDone(dialog#reveal)

    /// いま見えている本文（文字送りの途中まで）。視点側が RichText.place で描く。
    pub def visibleBody(dialog: Dialog): List[RichText.Span] =
        match currentLine(dialog) {
            case None       => Nil
            case Some(line) => RichText.take(UiTypewriter.visibleCount(dialog#reveal), line#body)
        }

    /// 毎フレーム呼ぶ: 表示中の行の文字送りを進める。閉じていれば何もしない。
    pub def step(cps: {cps = Float64}, dt: Float64, dialog: Dialog): Dialog =
        if (isOpen(dialog))
            { reveal = UiTypewriter.step(cps = cps#cps, dt, dialog#reveal) | dialog }
        else
            dialog

    /// 決定キー 1 回分の送り: 文字送り中なら全文へ飛ばし、見え終わっていれば次の行へ、
    /// 最後の行なら閉じる。
    pub def advance(dialog: Dialog): Dialog =
        if (not isOpen(dialog))
            dialog
        else if (not UiTypewriter.isDone(dialog#reveal))
            { reveal = UiTypewriter.skip(dialog#reveal) | dialog }
        else
            openWith(List.drop(1, dialog#lines))

    /// 会話ダイアログの枠を UiStore へ刻む: 開いていれば root を可視にして話者を流し込み、
    /// 閉じていれば root を隠すだけ。本文（スパン列）は visibleBody を視点側が描く。
    pub def apply(paths: Paths, dialog: Dialog, ui: UiStore.UiWorld): UiStore.UiWorld =
        match currentLine(dialog) {
            case None       => UiStore.setVisible(paths#root, false, ui)
            case Some(line) =>
                ui
                    |> UiStore.setVisible(paths#root, true)
                    |> UiStore.setText(paths#speaker, line#speaker)
        }
}
