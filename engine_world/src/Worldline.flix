// Worldline — World の軌跡（履歴・巻き戻し・リプレイ・分岐の土台）
// 時間区間の振り付け（歩く→拾う→戻る）は Timeline（別物）。
//
// World は状態の点、Worldline はその点がたどる線。巻き戻しとは世界線を遡ること、
// やり直しとは遡った線を再び下ること。ここは特定の World 型に依存しない `List[a]` 上の
// 純粋な zipper で、過去(past)・現在(current)・未来(future) の三つ組で「今どこにいるか」を保つ。
//
//   past    : 現在より前の状態。先頭が「1つ前」（most-recent-first）。undo で1つ current へ昇る。
//   current : 今の状態（世界線上の現在地）。
//   future  : undo で遡って手放した状態。先頭が「1つ先」。redo で1つ current へ戻す。
//   cap     : past に保つ最大数。record が古い端から捨てる（世界線は無限には遡れない）。
//
// 契約:
//   - record は「新しい現在へ進む」= 現在を past へ積み、future を捨てる（分岐したら未来は無効）。
//   - undo/redo は current と past/future の間で1状態を移すだけ（構造共有ゆえ安価）。
//   - undoBy(k) は k 回遡る。past が尽きたら最古で止まる（clamp）。手放した分は future に積む。
//   - future は cap で刈らない（redo は record までの一時的な線で、次の record で必ず消える）。
//
// 永続 List ゆえ past は tail を構造共有する。N 回ぶんの履歴を持っても各 record は先頭 1 セル追加＋
// cap 超過時の切り詰めだけで、World を丸ごと複製しない — これが巻き戻しが安い理由。

pub mod Worldline {

    pub enum Worldline[a] {
        case Worldline({ past = List[a], current = a, future = List[a], cap = Int32 })
    }

    /// 初期状態 1 点だけの世界線を作る。past/future は空、cap は past の最大保持数。
    /// cap <= 0 は「過去を残さない」= record しても遡れない世界線になる。
    pub def make(initial: a, cap: Int32): Worldline[a] =
        Worldline.Worldline({ past = Nil, current = initial, future = Nil, cap = cap })

    /// 今の状態（世界線上の現在地）。
    pub def current(wl: Worldline[a]): a =
        let Worldline.Worldline(r) = wl;
        r#current

    /// current だけを差し替える（past/future は不動 = 履歴を刻まない補正）。
    /// 遡った現在地に瞬間的な調整（入力エッジ状態の引き継ぎ等）を乗せる時に使う。record と違い
    /// 新しい一手にはならない — 世界線上の位置は変えず、その点の値だけを置き換える。
    pub def replaceCurrent(a: a, wl: Worldline[a]): Worldline[a] =
        let Worldline.Worldline(r) = wl;
        Worldline.Worldline({ current = a | r })

    /// 新しい現在へ進む。今の current を past へ積み（cap で古い端を切り詰め）、future を捨てる。
    /// future を捨てるのは「遡った先で別の一手を指したら、辿らなかった未来は無効になる」ため。
    pub def record(a: a, wl: Worldline[a]): Worldline[a] =
        let Worldline.Worldline(r) = wl;
        Worldline.Worldline({
            past = List.take(r#cap, r#current :: r#past),
            current = a,
            future = Nil
            | r
        })

    /// 1 回遡る。past が空なら何もしない（最古で止まる）。手放した current は future へ積む。
    pub def undo(wl: Worldline[a]): Worldline[a] =
        let Worldline.Worldline(r) = wl;
        match r#past {
            case Nil     => wl
            case p :: ps =>
                Worldline.Worldline({ past = ps, current = p, future = r#current :: r#future | r })
        }

    /// 1 回下る（やり直し）。future が空なら何もしない。手放した current は past へ戻す。
    pub def redo(wl: Worldline[a]): Worldline[a] =
        let Worldline.Worldline(r) = wl;
        match r#future {
            case Nil     => wl
            case f :: fs =>
                Worldline.Worldline({ past = r#current :: r#past, current = f, future = fs | r })
        }

    /// k 回遡る。past が尽きたら最古で止まる（k が履歴長を超えても最古に clamp）。
    /// k <= 0 は現状維持。dodge の popHistory(k) と同じ端条件を、undo の反復で表す。
    pub def undoBy(k: Int32, wl: Worldline[a]): Worldline[a] =
        if (k <= 0 or not canUndo(wl)) wl
        else undoBy(k - 1, undo(wl))

    /// k 回下る。future が尽きたら最新で止まる。undoBy の対。
    pub def redoBy(k: Int32, wl: Worldline[a]): Worldline[a] =
        if (k <= 0 or not canRedo(wl)) wl
        else redoBy(k - 1, redo(wl))

    /// 遡れるか（past が空でないか）。
    pub def canUndo(wl: Worldline[a]): Bool =
        let Worldline.Worldline(r) = wl;
        not List.isEmpty(r#past)

    /// 下れるか（future が空でないか）。
    pub def canRedo(wl: Worldline[a]): Bool =
        let Worldline.Worldline(r) = wl;
        not List.isEmpty(r#future)

    /// 遡れる回数（past の長さ）。
    pub def pastLength(wl: Worldline[a]): Int32 =
        let Worldline.Worldline(r) = wl;
        List.length(r#past)

    /// 下れる回数（future の長さ）。
    pub def futureLength(wl: Worldline[a]): Int32 =
        let Worldline.Worldline(r) = wl;
        List.length(r#future)

    /// 世界線上の総状態数（past + current + future）。
    pub def length(wl: Worldline[a]): Int32 =
        let Worldline.Worldline(r) = wl;
        List.length(r#past) + 1 + List.length(r#future)

    // ── 観測系: 世界線を時間順の1本の列として眺め、区間や絶対位置で読む ──
    // record/undo/redo が「今どこか」を動かすのに対し、ここは線そのものを外から
    // 観察する読み取り専用の操作。位置は最古=0・現在地=pastLength・最新=length-1 の絶対番号で数える。
    // 利用例: 履歴をまとめて GIF に描き出す / 一定区間だけ取り出して解析する / 任意地点へ一気に移動する。
    // 注意: past は新しい順に持つので、時間順に見せるときは反転して current・future を繋ぐ。

    /// 世界線を時間順（最古→最新）に平らにした列。GIF・タイムラインデバッガ・スクラブが
    /// 「線を 1 本の配列として眺める」ための原反。past を反転し、current・future を後ろに繋ぐ。
    pub def toList(wl: Worldline[a]): List[a] =
        let Worldline.Worldline(r) = wl;
        List.append(List.reverse(r#past), r#current :: r#future)

    /// 時間順に平らにした列の絶対添字区間 [fromIdx, toIdx) を取り出す（GIF・区間解析用）。
    /// 0 が最古・length-1 が最新の座標系（`scrubTo` と同じ）。範囲は列の両端へ clamp し、
    /// fromIdx >= toIdx なら空。cap で切り詰められた最古より前は列に無い（遡れない）。
    pub def slice(fromIdx: Int32, toIdx: Int32, wl: Worldline[a]): List[a] =
        let flat = toList(wl);
        let lo = Int32.max(0, fromIdx);
        let hi = Int32.min(List.length(flat), toIdx);
        if (hi <= lo) Nil
        else List.take(hi - lo, List.drop(lo, flat))

    /// 世界線上の絶対位置 n（0 = 最古、pastLength = 現在地、length-1 = 最新）へ移動する。
    /// undoBy/redoBy の絶対版: 現在地との差分だけ undo か redo する。n は [0, length-1] に
    /// clamp。past/future の構造は保たれ、cap で切り詰められた最古より前へは戻れない
    /// （undoBy と同じ端条件）。record と違い新しい一手にはならない — 線上の位置を移すだけ。
    pub def scrubTo(n: Int32, wl: Worldline[a]): Worldline[a] =
        let here = pastLength(wl);
        let target = Int32.max(0, Int32.min(length(wl) - 1, n));
        if (target < here) undoBy(here - target, wl)
        else if (target > here) redoBy(target - here, wl)
        else wl
}
