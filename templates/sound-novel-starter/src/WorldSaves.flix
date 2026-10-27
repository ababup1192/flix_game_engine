// WorldSaves — セーブ・ロードの画面の規則（純粋）。
// 画面のページと枠のカーソルは Panel.SaveSlots / LoadSlots が持つ（閉じると消える）。書く中身は WorldRead.slotHere、
// 読むのは WorldRead.restore（バックログから戻るのと同じ道）。
mod WorldSaves {
    use fge::{Emit}

    /// セーブの画面を開く。オートとクイックのページには人が書かないので、書けるページのうち一番新しいデータのページ（無ければ 1）。
    pub def openSave(w: World.World): World.World \ Emit[World.Event] =
        let newest = Saves.latest(w#saves) |> Option.map(fst) |> Option.filter(Saves.isWritable);
        World.openPanel(World.Panel.SaveSlots(Option.getWithDefault(Saves.Tab.Numbered(1), newest), 0), w)

    /// ロードの画面を開く（一番新しいデータのページで。データが無ければ 1）。
    pub def openLoad(w: World.World): World.World \ Emit[World.Event] =
        let newest = Saves.latest(w#saves) |> Option.map(fst);
        World.openPanel(World.Panel.LoadSlots(Option.getWithDefault(Saves.Tab.Numbered(1), newest), 0), w)

    /// 開いている画面のページと枠を差し替える。
    def withSlots(tab: Saves.Tab, i: Int32, w: World.World): World.World = match w#panel {
        case World.Panel.SaveSlots(_, _) => { panel = World.Panel.SaveSlots(tab, i) | w }
        case World.Panel.LoadSlots(_, _) => { panel = World.Panel.LoadSlots(tab, i) | w }
        case _                           => w
    }

    /// ページ tab の i 枠目に書く。
    pub def writeSlot(tab: Saves.Tab, i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match WorldRead.slotHere(w) {
            case Some(slot) =>
                Emit.emit(World.Event.Saved);
                World.notice(StoryDoc.Label.Saved, World.withSaves(Saves.withSlot(tab, i, slot, w#saves), w))
            case None => w
        }

    /// クイックセーブ（クイックのページの先頭へ。前の物は後ろへ押す）。
    pub def quickSave(w: World.World): World.World \ Emit[World.Event] =
        match WorldRead.slotHere(w) {
            case Some(slot) =>
                Emit.emit(World.Event.Saved);
                World.notice(StoryDoc.Label.QuickSaved, World.withSaves(Saves.withPushed(Saves.Tab.Quick, slot, w#saves), w))
            case None => w
        }

    /// 今のページの i 枠目を選ぶ（セーブ: 空なら書き、あれば上書きを尋ねる。ロード: タイトルからはすぐ読み、読んでいる途中なら尋ねる）。
    pub def chooseSlot(i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((tab, _)) =>
                let at = withSlots(tab, i, w);
                let filled = Option.nonEmpty(Saves.slotOf(tab, i, w#saves));
                match w#panel {
                    case World.Panel.SaveSlots(_, _) =>
                        if (not Saves.isWritable(tab)) at
                        else if (filled) World.askFor(World.Ask.Overwrite(tab, i), at)
                        else writeSlot(tab, i, at)
                    case _ =>
                        if (not filled) at
                        else if (World.isReading(w)) World.askFor(World.Ask.Load(tab, i), at)
                        else loadFrom(tab, i, at)
                }
            case None => w
        }

    /// カーソルの枠を選ぶ。
    pub def chooseHere(w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((_, i)) => chooseSlot(i, w)
            case None         => w
        }

    /// 今のページの i 枠目を消すか尋ねる（空なら何もしない）。
    pub def deleteSlot(i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((tab, _)) if Option.nonEmpty(Saves.slotOf(tab, i, w#saves)) => World.askFor(World.Ask.Delete(tab, i), w)
            case _ => w
        }

    /// カーソルの枠を消すか尋ねる。
    pub def deleteHere(w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((_, i)) => deleteSlot(i, w)
            case None         => w
        }

    /// ページ tab の i 枠目を消す（確認のウィンドウの「はい」）。
    pub def removeSlot(tab: Saves.Tab, i: Int32, w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Closed);
        World.notice(StoryDoc.Label.Deleted, World.withSaves(Saves.withoutSlot(tab, i, w#saves), w))

    /// ページを替える（カーソルは先頭へ）。
    pub def withTab(tab: Saves.Tab, w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((now, _)) if now != tab => Emit.emit(World.Event.Moved); withSlots(tab, 0, w)
            case _                            => w
        }

    /// 今の画面のページの並び（セーブの画面は書けるページだけ）。
    pub def tabsOf(w: World.World): List[Saves.Tab] = match w#panel {
        case World.Panel.SaveSlots(_, _) => Saves.writableTabs()
        case _                           => Saves.tabs()
    }

    /// ページを delta ぶん替える（端で回り込む）。
    pub def moveTab(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((now, _)) =>
                let tabs = tabsOf(w);
                let count = List.length(tabs);
                let at = tabs |> List.zipWithIndex |> List.find(match (_, tab) -> tab == now) |> Option.map(fst) |> Option.getWithDefault(0);
                match List.nth(Int32.modulo(at + delta, Int32.max(1, count)), tabs) {
                    case Some(tab) => withTab(tab, w)
                    case None      => w
                }
            case None => w
        }

    /// 枠のカーソルを delta ぶん動かす（端で回り込む。↑↓ は 2 枠 = 1 行、←→ は 1 枠）。
    pub def moveSlotCursor(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((tab, i)) => Emit.emit(World.Event.Moved); withSlots(tab, Int32.modulo(i + delta, Saves.perPage()), w)
            case None           => w
        }

    /// 枠のカーソルを i へ（マウスが乗った物。同じなら音を出さない）。
    pub def pointSlot(i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.slotsOf(w) {
            case Some((tab, at)) if at != i => Emit.emit(World.Event.Moved); withSlots(tab, i, w)
            case _                          => w
        }

    /// ページ tab の i 枠目から読む。[遷移: Title / Reading→Reading]
    pub def loadFrom(tab: Saves.Tab, i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match Saves.slotOf(tab, i, w#saves) {
            case Some(slot) =>
                Emit.emit(World.Event.Loaded);
                World.notice(StoryDoc.Label.Loaded, WorldRead.restore(slot#mark, w))
            case None => w
        }
}
