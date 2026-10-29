// Progress — 物語の進み具合（依頼の段階）と旗。前の段階へは戻らない（advanceQuest の 1 か所）。
// 仲間の加入は Party の加わった順が正で、ここに旗を持たない。
// 旗は 2 つに分ける: opened = 開けた物（(マップ, objects の id)。その物だけが読む）/
// flags = 名前付きの旗（FlagId。物が立てて、別の物や会話が読む。マップをまたいでよい）。
mod Progress {

    /// 依頼の段階（並びの順に進む）。会話の変数 $quest には nameOf の名前で写る。
    pub enum Quest with Eq, Order, ToString {
        case NotAsked
        case Accepted
    }

    pub def quests(): List[Quest] = Quest.NotAsked :: Quest.Accepted :: Nil

    /// 会話の変数 $quest・Starts の quest= の名前。
    pub def nameOf(q: Quest): String = match q {
        case Quest.NotAsked => "none"
        case Quest.Accepted => "accepted"
    }

    /// 名前 → 段階（知らない名前は None）。
    pub def questOf(name: String): Option[Quest] = quests() |> List.find(q -> nameOf(q) == name)

    pub type alias Rec = { quest = Quest, opened = Set[(MapDoc.MapId, String)], flags = Set[Flag.FlagId] }

    enum ProgressOf(Rec)

    /// 進み具合（外では rec と advanceQuest を通す）。
    pub type alias Progress = ProgressOf

    pub def initial(): Progress = ProgressOf.ProgressOf({ quest = Quest.NotAsked, opened = Set.empty(), flags = Set.empty() })

    pub def rec(p: Progress): Rec = match p { case ProgressOf.ProgressOf(r) => r }

    /// 段階を to へ進める。今が to の 1 つ前の段階の時だけ Some（同じ段階・先の段階・飛び越しは None）。
    pub def advanceQuest(to: Quest, p: Progress): Option[Progress] =
        let before = List.zip(quests(), List.drop(1, quests())) |> List.find(pair -> snd(pair) == to) |> Option.map(fst);
        if (before == Some(rec(p)#quest)) Some(ProgressOf.ProgressOf({ quest = to | rec(p) })) else None

    /// 段階を直に置く（Starts の quest=。遊びの中では advanceQuest を通す）。
    pub def withQuest(q: Quest, p: Progress): Progress = ProgressOf.ProgressOf({ quest = q | rec(p) })

    /// map の objects の id の宝箱・扉を開けたか。
    pub def isOpened(map: MapDoc.MapId, id: String, p: Progress): Bool = Set.memberOf((map, id), rec(p)#opened)

    /// map の objects の id の宝箱・扉を開けた（もう開けていればそのまま）。
    pub def markOpened(map: MapDoc.MapId, id: String, p: Progress): Progress =
        ProgressOf.ProgressOf({ opened = Set.insert((map, id), rec(p)#opened) | rec(p) })

    /// map の objects の ids を開けていない事にする（順番を違えて消えた水晶）。
    pub def unmarkOpened(map: MapDoc.MapId, ids: List[String], p: Progress): Progress =
        let gone = ids |> List.map(id -> (map, id)) |> List.toSet;
        ProgressOf.ProgressOf({ opened = Set.difference(rec(p)#opened, gone) | rec(p) })

    /// map で開けた objects の id（WorldField が当たりと絵に使う）。
    pub def openedIn(map: MapDoc.MapId, p: Progress): Set[String] =
        rec(p)#opened |> Set.filter(pair -> fst(pair) == map) |> Set.map(snd)

    /// 旗が立っているか。
    pub def isFlagSet(flag: Flag.FlagId, p: Progress): Bool = Set.memberOf(flag, rec(p)#flags)

    /// 立っている旗の全部（物の状態を導く WorldObject.stateOf・セーブ）。
    pub def flagsOf(p: Progress): Set[Flag.FlagId] = rec(p)#flags

    /// 旗を立てる（on = true）・下ろす（on = false）。
    pub def withFlag(flag: Flag.FlagId, on: Bool, p: Progress): Progress =
        let flags = if (on) Set.insert(flag, rec(p)#flags) else Set.remove(flag, rec(p)#flags);
        ProgressOf.ProgressOf({ flags = flags | rec(p) })
}
