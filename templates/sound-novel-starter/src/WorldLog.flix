// WorldLog — バックログと「戻る」の規則（純粋）。
// バックログの行は戻れる所（Saves.Mark）を持ち、その場面へ戻るのは WorldRead.restore（セーブのロードと同じ道）。
mod WorldLog {
    use fge::{Emit, UiScroll}

    /// バックログを開く（一番新しい所から）。
    pub def openLog(w: World.World): World.World \ Emit[World.Event] = World.openPanel(World.Panel.Log(0.0), w)

    /// バックログを遡った量（px。0 = 一番新しい所。開いていなければ 0）。
    pub def offsetOf(w: World.World): Float64 = match w#panel {
        case World.Panel.Log(offset) => offset
        case _                       => 0.0
    }

    /// バックログを delta px 遡る（長さは View が描く高さ）。
    pub def scrollLog(delta: Float64, size: { contentPx = Float64, viewportPx = Float64 }, w: World.World): World.World =
        match w#panel {
            case World.Panel.Log(offset) => { panel = World.Panel.Log(UiScroll.scrollByPx(delta, size, offset)) | w }
            case _                       => w
        }

    /// 1 つ前の行へ戻る（選択肢を出している間は、問いの行へ戻って選び直せる形に）。
    pub def rollback(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        let first = if (World.isChoosing(w)) 0 else 1;
        let target = World.logOf(w) |> List.zipWithIndex |> List.find(match (i, entry) -> i >= first and isJumpable(entry)) |> Option.map(fst);
        match target {
            case Some(k) => jumpTo(res, k, w)
            case None    => World.notice(StoryDoc.Label.NoRollback, w)
        }

    /// バックログの行が戻れる所を持つか。
    pub def isJumpable(entry: World.Entry): Bool = match entry {
        case World.Entry.Said(_, Some(_)) => true
        case World.Entry.Said(_, None)    => false
        case World.Entry.Chose(_)         => false
    }

    /// バックログの k 行目（0 = 一番新しい）の場面へ戻るか尋ねる（戻れない行なら何もしない）。
    pub def askJump(k: Int32, w: World.World): World.World \ Emit[World.Event] =
        match List.nth(k, World.logOf(w)) {
            case Some(entry) if k > 0 and isJumpable(entry) => World.askFor(World.Ask.Jump(k), w)
            case _ => w
        }

    /// バックログの k 行目の場面へ戻る。バックログはその行までに切り詰める（その先は読み直す）。
    pub def jumpTo(res: Res.Res, k: Int32, w: World.World): World.World \ Emit[World.Event] =
        let log = World.logOf(w);
        match List.nth(k, log) {
            case Some(World.Entry.Said(_, Some(mark))) =>
                Emit.emit(World.Event.Rolled);
                World.mapRead(r -> { log = List.drop(k, log) | r }, WorldRead.restore(res, mark, w))
            case _ => w
        }
}
