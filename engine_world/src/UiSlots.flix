// UiSlots — ui.json に用意した固定数のスロットへ、可変個の項目を先頭から流し込む。
// 動的な行数のメニュー・一覧を、ページを組み直さず setText / setMeta / setVisible だけで作れる。
// 利用例: ui.json に slot0..slotN（各スロットの子に label text）を宣言し、毎フレーム fill で流し込む。
// 規約: 項目のあるスロットは可視 + meta 設定（UiMenu の選択列に載る）、余りは meta を外して不可視
// （display:none でパネルが縮む）。あふれた項目は黙って切り捨てるので、呼び側は overflows で検知して守る。
pub mod UiSlots {

    /// スロット 1 個分の項目。text = 表示文字列（スロットの `label` 子へ）、
    /// meta = 選択時にゲームへ返す目印。None なら見出しなど「選べない行」（UiMenu の項目列に載らない）。
    pub type alias Entry = { text = String, meta = Option[String] }

    /// スロットの配置規約。slotPath = i 番目のスロット（行コンテナ）の名前パス、maxSlots = 宣言した数。
    pub type alias SlotSpec = { slotPath = Int32 -> String, maxSlots = Int32 }

    /// items を先頭スロットから順に流し込む。maxSlots を超えた項目は入らない（overflows で検知）。
    pub def fill(spec: SlotSpec, items: List[Entry], ui: UiStore.UiWorld): UiStore.UiWorld =
        // 項目の列をスロット数ちょうどまで None で伸ばしてから 1 巡する。items のまま zip すると
        // 短い方で打ち切られ、余ったスロットの hideOne が呼ばれずに前回の項目が残る。
        let filled = List.take(spec#maxSlots, items) |> List.map(entry -> Some(entry));
        let blanks = List.repeat(spec#maxSlots - List.length(filled), (None: Option[Entry]));
        List.append(filled, blanks) |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (i, slot) = pair;
            match slot {
                case Some(entry) => fillOne(spec#slotPath(i), entry, acc)
                case None        => hideOne(spec#slotPath(i), acc)
            }
        }, ui)

    /// スロットが足りないか。足りないまま fill すると末尾の項目が表示されないので、
    /// 呼び側はこれで検知して bug! なりスクロール範囲なりで守る。
    pub def overflows(spec: SlotSpec, items: List[Entry]): Bool =
        List.length(items) > spec#maxSlots

    /// 項目のあるスロット: label に文字を入れ、meta を設定（None なら外す）して可視にする。
    def fillOne(slotPath: String, entry: Entry, ui: UiStore.UiWorld): UiStore.UiWorld =
        let withMeta = match entry#meta {
            case Some(meta) => UiStore.setMeta(slotPath, meta, ui)
            case None       => UiStore.clearMeta(slotPath, ui)
        };
        withMeta
            |> UiStore.setText("${slotPath}/label", entry#text)
            |> UiStore.setVisible(slotPath, true)

    /// 余ったスロット: meta を外して選択列から外し、不可視にしてパネルを縮める。
    def hideOne(slotPath: String, ui: UiStore.UiWorld): UiStore.UiWorld =
        ui
            |> UiStore.clearMeta(slotPath)
            |> UiStore.setVisible(slotPath, false)
}
