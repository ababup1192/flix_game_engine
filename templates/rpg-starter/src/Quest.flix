// Quest — 依頼の段階（並びの順に進む。前へは戻らない = Progress.advanceQuest）。
// マップ Doc の人と小物が「どの段階の間だけ出るか」（MapDoc.Span）もこの値で書くので、Progress から外に置く
// （Progress はマップの名前 MapDoc.MapId を使うため、MapDoc が Progress を使うと輪になる）。
pub mod Quest {

    /// NotAsked = 依頼の前 / Accepted = 受けた / BossDown = 坑道の奥のボスを倒した（泉に水が戻る）/ Reported = 村長に報告した。
    /// 会話の変数 $quest には nameOf の名前で写る。
    pub enum Quest with Eq, Order, ToString {
        case NotAsked
        case Accepted
        case BossDown
        case Reported
    }

    /// 進む順に全部。
    pub def all(): List[Quest] = Quest.NotAsked :: Quest.Accepted :: Quest.BossDown :: Quest.Reported :: Nil

    /// 会話の変数 $quest・Starts の quest=・セーブ・マップ Doc の questFrom / questUntil の名前。
    pub def nameOf(q: Quest): String = match q {
        case Quest.NotAsked => "none"
        case Quest.Accepted => "accepted"
        case Quest.BossDown => "bossdown"
        case Quest.Reported => "reported"
    }

    /// 名前 → 段階（知らない名前は None）。
    pub def questOf(name: String): Option[Quest] = all() |> List.find(q -> nameOf(q) == name)

    /// 名前の一覧（知らせる文に並べる）。
    pub def names(): String = all() |> List.map(nameOf) |> List.join(" / ")
}
