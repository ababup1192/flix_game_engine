// UiMenu — 縦並びの選択メニューが共通で使う「項目の並べ方」と「選択中の見せ方」。
// どのメニューも項目の列挙・選択ハイライト・選べない項目の淡色化を書き直さず共有できる。
// 利用例: 行動選択メニュー / ゲームオーバー時の選択肢 / 持ち物リストの選択。
//
// 規約: リスト所有 entity（listPath）直下の子のうち **metas を持つもの** を order 昇順に
// 並べた列が「選択カーソルの項目列」（見出し・区切り等 meta 無しの子は数えない）。
// 動的メニュー（ActionMenu）は空きスロットの meta を `UiStore.clearMeta` で外し、項目数を
// 可視項目へ追随させる（display:none レイアウトと組でパネルが縮む）。

pub mod UiMenu {

    /// listPath 配下の「meta を持つ子」を order 順に列挙する（選択カーソルの項目列）。
    /// listPath が未登録なら空。
    pub def itemIds(listPath: String, ui: UiStore.UiWorld): List[EntityId] =
        match UiStore.idOf(listPath, ui) {
            case None     => Nil
            case Some(id) =>
                UiHierarchy.childrenOf(id, ui#parents, ui#order)
                    |> List.filter(child -> not Option.isEmpty(Map.get(child, ui#metas)))
        }

    /// 項目列の meta 文字列を order 順に集める。
    pub def metas(listPath: String, ui: UiStore.UiWorld): List[String] =
        itemIds(listPath, ui) |> List.filterMap(id -> Map.get(id, ui#metas))

    /// 項目数（meta を持つ子の数）。
    pub def count(listPath: String, ui: UiStore.UiWorld): Int32 =
        List.length(itemIds(listPath, ui))

    /// 選択カーソル位置の meta を取り出す（範囲外は None）。
    pub def metaAtSelection(listPath: String, selection: Int32, ui: UiStore.UiWorld): Option[String] =
        List.nth(selection, metas(listPath, ui))

    /// 項目列の各 text tint を index → 色の関数で塗る（選択ハイライト・disabled 淡色などを
    /// 呼び側が `tintOf` に閉じる）。index は項目列（meta 持ち子）の 0 起点順序。
    /// 例: `idx -> if (idx == sel) accent else normal`（GameOver）。
    pub def applyItemTints(listPath: String, tintOf: Int32 -> Color, ui: UiStore.UiWorld): UiStore.UiWorld =
        itemIds(listPath, ui)
            |> List.zipWithIndex
            |> List.foldLeft((acc, pair) -> {
                let (idx, id) = pair;
                tintById(id, tintOf(idx), acc)
            }, ui)

    /// 項目列の各行の子ノード childName の text を index → 文字列の関数で流し込む
    /// （applyItemTints の文字版）。チェック欄・状態マークなど「行ごとに変わる短い文字」に使う。
    /// 例: `applyItemLabels(listPath, "mark", idx -> markGlyph(markOf(idx)), ui)`。
    /// 対象の子に text が無ければ no-op（setText の性質に従う）。
    pub def applyItemLabels(listPath: String, childName: String,
                            textOf: Int32 -> String, ui: UiStore.UiWorld): UiStore.UiWorld =
        itemIds(listPath, ui)
            |> List.zipWithIndex
            |> List.foldLeft((acc, pair) -> {
                let (idx, id) = pair;
                match UiStore.pathOf(id, acc) {
                    case None       => acc
                    case Some(path) => UiStore.setText("${path}/${childName}", textOf(idx), acc)
                }
            }, ui)

    /// 項目 entity の text tint を差し替える。項目ノード自身が text を持つ形（項目=text ノード）と、
    /// 固定高の行コンテナ配下に `label` text を置く形（項目=box/none コンテナ）の両対応。
    /// どちらの setTextTint も対象に text が無ければ no-op なので、両パスへ流して存在する方だけ塗る。
    def tintById(id: EntityId, tint: Color, ui: UiStore.UiWorld): UiStore.UiWorld =
        match UiStore.pathOf(id, ui) {
            case None       => ui
            case Some(path) =>
                ui
                    |> UiStore.setTextTint(path, tint)
                    |> UiStore.setTextTint("${path}/label", tint)
        }

    // ========================================================================
    // 選択ハイライト箱（塗り箱）の位置合わせ
    // ========================================================================

    /// `applyHighlight` の引数束。
    /// `listPath`: 項目列を所有する entity の名前パス（`UiMenu.itemIds` の起点）。
    /// `highlightPath`: 塗り箱（abs 子）の名前パス。
    /// `sel`: 選択カーソルの index（項目列基準。範囲外は防御的にクランプする）。
    /// `rowPitch`: 行の固定ピッチ（px）。
    /// `inset`: 行セルの内側マージン（px。箱を行セルより少し小さくして隣行と接しないため）。
    pub type alias HighlightArgs = {
        listPath      = String,
        highlightPath = String,
        sel           = Int32,
        rowPitch      = Float64,
        inset         = Float64
    }

    /// 選択行の塗り箱を選択位置へ動かす。箱は listPath 直下に置いた abs 子（highlightPath）で、
    /// 塗り・枠・角丸・寸法は ui.json 側で固定宣言し、ここでは選択 index と行ピッチから
    /// フロー外オフセット（listPath コンテンツ原点基準）だけを決め打ちで再計算する。
    ///
    /// 行ピッチが固定（各行 = 固定高スロット・gap 0）なので、レイアウト結果を読み戻さずに
    /// `y = inset + sel × rowPitch` で決定論的に置ける。
    ///
    /// 項目が無いときは箱を隠す。sel は防御的に [0, count) へクランプする。
    pub def applyHighlight(args: HighlightArgs, ui: UiStore.UiWorld): UiStore.UiWorld =
        match highlightPlacement(count(args#listPath, ui), args#sel, args#rowPitch, args#inset) {
            case None      => UiStore.setVisible(args#highlightPath, false, ui)
            case Some(pos) =>
                ui
                    |> UiStore.setVisible(args#highlightPath, true)
                    |> UiStore.setAbs(args#highlightPath, pos)
        }

    /// 塗り箱のフロー外オフセットを決める純関数（UiWorld 非依存）。
    /// 項目 0 のときは None（箱を隠す）。それ以外は sel を [0, count) にクランプした行の
    /// abs オフセット `{x = inset, y = inset + row × rowPitch}` を返す。
    /// 行ピッチ固定を前提に、レイアウト結果を読み戻さず決定論的に位置を出す（テストはここを pin する）。
    pub def highlightPlacement(itemCount: Int32, sel: Int32, rowPitch: Float64, inset: Float64): Option[Vec2.Vec2] =
        if (itemCount <= 0) None
        else Some({x = inset, y = inset + Int32.toFloat64(clampIndex(itemCount, sel)) * rowPitch})

    /// 選択 index を [0, count) へ収める純関数。項目 0 のときは 0。
    pub def clampIndex(itemCount: Int32, sel: Int32): Int32 =
        if (itemCount <= 0) 0 else Int32.max(0, Int32.min(itemCount - 1, sel))

    /// 項目数が表示スロット数を超えるメニューで、選択 sel が見える範囲の先頭 offset を決める純関数。
    /// 選択行を範囲の中央寄りに保ちつつ [0, count - slots] にクランプする（先頭で 0 停止・末尾で下停止）。
    /// slots に収まるときは常に 0。項目一覧のスクロール範囲と同式。
    pub def scrollOffset(sel: {sel = Int32}, count: {count = Int32}, slots: {slots = Int32}): Int32 =
        if (slots#slots <= 0 or count#count <= slots#slots) 0
        else {
            let maxFirst = count#count - slots#slots;
            let centerOff = (slots#slots - 1) / 2;
            Int32.min(maxFirst, Int32.max(0, sel#sel - centerOff))
        }

    /// 選択カーソルを項目数 [0, count) の範囲へ収める（防御クランプ）。項目 0 のときは 0。
    /// フェーズ遷移や項目数の変動でカーソルが範囲外に取り残されても、確定・ハイライトが破綻しない。
    pub def clampSelection(listPath: String, ui: UiStore.UiWorld): UiStore.UiWorld =
        let sel = UiStore.selectionOf(listPath, ui);
        let clamped = clampIndex(count(listPath, ui), sel);
        if (clamped == sel) ui else UiStore.putSelection(listPath, clamped, ui)

    // ========================================================================
    // カーソル移動とマウス同期（呼び側が Int32 のカーソルを持つ方式）
    // 既存の selection 系（metaAtSelection / clampSelection）は UiStore が選択位置を持つ方式。
    // 1 つのメニューではどちらか片方だけを使う（両方使うと位置が 2 箇所に分かれてずれる）。
    // ========================================================================

    /// カーソルを delta ぶん動かす（端で反対側へ回り込む）。count<=0 なら cursor のまま。
    pub def moveCursor(delta: Int32, count: Int32, cursor: Int32): Int32 =
        if (count <= 0) cursor
        else Int32.modulo(cursor + delta + count, count)

    /// マウス hit の entity が項目列の何番目か（項目列に無ければ None）。
    pub def hitIndexIn(listPath: String, hit: Option[EntityId], ui: UiStore.UiWorld): Option[Int32] =
        hit |> Option.flatMap(id ->
            itemIds(listPath, ui)
                |> List.zipWithIndex
                |> List.findMap(pair -> { let (i, itemId) = pair; if (itemId == id) Some(i) else None }))

    /// カーソル位置の項目の名前パス（項目 0 個や範囲外は None）。ホバー強調の行き先に使う。
    pub def cursorPath(listPath: String, cursor: Int32, ui: UiStore.UiWorld): Option[String] =
        List.nth(cursor, itemIds(listPath, ui))
            |> Option.flatMap(id -> UiStore.pathOf(id, ui))

    /// キーボードとマウスの両方で選ぶメニューの共通規約。キーボードのカーソルを基準にし、
    /// マウスは動いたフレームに項目へ乗っているときだけカーソルをそこへ吸着させる。
    pub def syncCursor(listPath: String, input: { mouseMoved = Bool, hit = Option[EntityId] },
                       cursor: Int32, ui: UiStore.UiWorld): { cursor = Int32, hoverPath = Option[String] } =
        let next = if (input#mouseMoved)
                       hitIndexIn(listPath, input#hit, ui) |> Option.getWithDefault(cursor)
                   else cursor;
        { cursor = next, hoverPath = cursorPath(listPath, next, ui) }
}
