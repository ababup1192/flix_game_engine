// TextDoc — assets/rpg.text.json（話し手の呼び名・メニューの言葉・知らせの言葉）の Doc 層。
// 会話の台詞は Yarn（assets/talk/rune.yarn）。ここは画面の枠に出す短い言葉だけ。
// fail-open — 読めない・欠けた言葉はコードの既定の言葉で出す。
mod TextDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// メニューの言葉の名前（rpg.text.json の menu の鍵）。
    pub enum MenuText with Eq, Order, ToString {
        case NewGame
        case Continue
        case Credit
        case QuitAsk
        case Yes
        case No
        case Talk
        case Spell
        case Status
        case Items
        case Equip
        case Search
        case Buy
        case Sell
        case Leave
        case Weapon
        case Armor
        case Unequip
        case Level
        case Hp
        case Mp
        case Atk
        case Agi
        case Defense
        case Gold
        case Fight
        case Defend
        case Flee
        case TheEnd
    }

    def menuKeyOf(m: MenuText): String = match m {
        case MenuText.NewGame => "newGame"
        case MenuText.Continue => "continue"
        case MenuText.Credit => "credit"
        case MenuText.QuitAsk => "quitAsk"
        case MenuText.Yes => "yes"
        case MenuText.No => "no"
        case MenuText.Talk => "talk"
        case MenuText.Spell => "spell"
        case MenuText.Status => "status"
        case MenuText.Items => "items"
        case MenuText.Equip => "equip"
        case MenuText.Search => "search"
        case MenuText.Buy => "buy"
        case MenuText.Sell => "sell"
        case MenuText.Leave => "leave"
        case MenuText.Weapon => "weapon"
        case MenuText.Armor => "armor"
        case MenuText.Unequip => "unequip"
        case MenuText.Level => "level"
        case MenuText.Hp => "hp"
        case MenuText.Mp => "mp"
        case MenuText.Atk => "atk"
        case MenuText.Agi => "agi"
        case MenuText.Defense => "defense"
        case MenuText.Gold => "gold"
        case MenuText.Fight => "fight"
        case MenuText.Defend => "defend"
        case MenuText.Flee => "flee"
        case MenuText.TheEnd => "theEnd"
    }

    def menuDefaultOf(m: MenuText): String = match m {
        case MenuText.NewGame => "はじめから"
        case MenuText.Continue => "つづきから"
        case MenuText.Credit => "2026  ルーネの泉 せいさく いいんかい"
        case MenuText.QuitAsk => "ゲームを おわりますか？"
        case MenuText.Yes => "はい"
        case MenuText.No => "いいえ"
        case MenuText.Talk => "はなす"
        case MenuText.Spell => "じゅもん"
        case MenuText.Status => "つよさ"
        case MenuText.Items => "どうぐ"
        case MenuText.Equip => "そうび"
        case MenuText.Search => "しらべる"
        case MenuText.Buy => "かう"
        case MenuText.Sell => "うる"
        case MenuText.Leave => "やめる"
        case MenuText.Weapon => "ぶき"
        case MenuText.Armor => "よろい"
        case MenuText.Unequip => "はずす"
        case MenuText.Level => "レベル"
        case MenuText.Hp => "HP"
        case MenuText.Mp => "MP"
        case MenuText.Atk => "ちから"
        case MenuText.Agi => "すばやさ"
        case MenuText.Defense => "みのまもり"
        case MenuText.Gold => "ゴールド"
        case MenuText.Fight => "たたかう"
        case MenuText.Defend => "ぼうぎょ"
        case MenuText.Flee => "にげる"
        case MenuText.TheEnd => "おわり"
    }

    /// 知らせの言葉の名前（rpg.text.json の notice の鍵）。{name}・{n}・{item}・{gold} は fill が埋める。
    pub enum NoticeText with Eq, Order, ToString {
        case Healed
        case MpHealed
        case NoEffect
        case NotHere
        case UseEquip
        case KeyItem
        case Nobody
        case Nothing
        case BuyAsk
        case SellAsk
        case ChestOpened
        case ItemGot
        case GoldGot
        case ChestEmpty
        case BagFull
        case Locked
        case Unlocked
        case NotNeeded
        case LeverOn
        case LeverOff
        case GateShut
        case PlatePressed
        case GateRaised
        case RockHint
        case CrystalLit
        case CrystalAll
        case CrystalReset
        case CrystalShining
        case TorchLit
        case TorchNotHere
        case CartStuck
        case NoMp
        case NoSpells
    }

    def noticeKeyOf(m: NoticeText): String = match m {
        case NoticeText.Healed => "healed"
        case NoticeText.MpHealed => "mpHealed"
        case NoticeText.NoEffect => "noEffect"
        case NoticeText.NotHere => "notHere"
        case NoticeText.UseEquip => "useEquip"
        case NoticeText.KeyItem => "keyItem"
        case NoticeText.Nobody => "nobody"
        case NoticeText.Nothing => "nothing"
        case NoticeText.BuyAsk => "buyAsk"
        case NoticeText.SellAsk => "sellAsk"
        case NoticeText.ChestOpened => "chestOpened"
        case NoticeText.ItemGot => "itemGot"
        case NoticeText.GoldGot => "goldGot"
        case NoticeText.ChestEmpty => "chestEmpty"
        case NoticeText.BagFull => "bagFull"
        case NoticeText.Locked => "locked"
        case NoticeText.Unlocked => "unlocked"
        case NoticeText.NotNeeded => "notNeeded"
        case NoticeText.LeverOn => "leverOn"
        case NoticeText.LeverOff => "leverOff"
        case NoticeText.GateShut => "gateShut"
        case NoticeText.PlatePressed => "platePressed"
        case NoticeText.GateRaised => "gateRaised"
        case NoticeText.RockHint => "rockHint"
        case NoticeText.CrystalLit => "crystalLit"
        case NoticeText.CrystalAll => "crystalAll"
        case NoticeText.CrystalReset => "crystalReset"
        case NoticeText.CrystalShining => "crystalShining"
        case NoticeText.TorchLit => "torchLit"
        case NoticeText.TorchNotHere => "torchNotHere"
        case NoticeText.CartStuck => "cartStuck"
        case NoticeText.NoMp => "noMp"
        case NoticeText.NoSpells => "noSpells"
    }

    def noticeDefaultOf(m: NoticeText): String = match m {
        case NoticeText.Healed => "{name}の HPが {n} かいふくした！"
        case NoticeText.MpHealed => "{name}の MPが {n} かいふくした！"
        case NoticeText.NoEffect => "しかし なにも おこらなかった。"
        case NoticeText.NotHere => "いまは つかえない。"
        case NoticeText.UseEquip => "そうびで つけかえてね。"
        case NoticeText.KeyItem => "だいじな ものは つかえない。"
        case NoticeText.Nobody => "そっちには だれも いない。"
        case NoticeText.Nothing => "なにも みつからなかった。"
        case NoticeText.BuyAsk => "{item}を {n}こで {gold}G だよ。\nかうかい？"
        case NoticeText.SellAsk => "{item}を {n}こ うると {gold}G だよ。\nうるかい？"
        case NoticeText.ChestOpened => "たからばこを あけた！"
        case NoticeText.ItemGot => "{item}を てにいれた！"
        case NoticeText.GoldGot => "{gold}G を てにいれた！"
        case NoticeText.ChestEmpty => "たからばこは からっぽだ。"
        case NoticeText.BagFull => "しかし もちものが いっぱいで もてない。"
        case NoticeText.Locked => "とびらには かぎが かかっている。"
        case NoticeText.Unlocked => "{item}で とびらを あけた！"
        case NoticeText.NotNeeded => "{name}には いまは ひつようない。"
        case NoticeText.LeverOn => "レバーを ひいた。\nどこかで ガラガラと おとが した。"
        case NoticeText.LeverOff => "レバーを もとに もどした。\nどこかで ガラガラと おとが した。"
        case NoticeText.GateShut => "てつごうしが おりている。\nちかくに しかけが ありそうだ。"
        case NoticeText.PlatePressed => "カチッ と おとが した。\nどこかで ガラガラと おとが した。"
        case NoticeText.GateRaised => "ゴゴゴ…\nどこかで てつごうしが あがった！"
        case NoticeText.RockHint => "おおきな いわだ。\nおせば うごきそうだ。"
        case NoticeText.CrystalLit => "すいしょうが あおく ひかった！"
        case NoticeText.CrystalAll => "すいしょうが いっせいに かがやいた！\nみずうみに いしが うかびあがった！"
        case NoticeText.CrystalReset => "すいしょうの ひかりが きえた…"
        case NoticeText.CrystalShining => "すいしょうが あおく ひかっている。"
        case NoticeText.TorchLit => "{item}に ひを ともした。\nあたりが あかるく なった！"
        case NoticeText.TorchNotHere => "ここは じゅうぶん あかるい。"
        case NoticeText.CartStuck => "トロッコは うごかない。\nレールが ふさがっている。"
        case NoticeText.NoMp => "MPが たりない。"
        case NoticeText.NoSpells => "{name}は じゅもんを おぼえていない。"
    }


    /// 戦いの伝言の名前（rpg.text.json の battle の鍵）。{name}・{target}・{n}・{lv} は battleText が埋める。
    pub enum BattleText with Eq, Order, ToString {
        case Appear
        case Attack
        case FoeDamaged
        case AllyDamaged
        case Critical
        case Miss
        case FoeDown
        case AllyDown
        case Defend
        case Guard
        case Sweep
        case Run
        case Fled
        case Blocked
        case NoFlee
        case Won
        case Exp
        case GoldGot
        case LevelUp
        case Wiped
        case Cast
        case UseItem
        case AllyHealed
        case AllyMpHealed
        case FoeHealed
        case MpShort
        case ItemGone
        case NoEffect
        case Asleep
        case Woke
        case SleepAct
        case FellAsleep
        case SleepMiss
        case Learned
    }

    def battleKeyOf(m: BattleText): String = match m {
        case BattleText.Appear => "appear"
        case BattleText.Attack => "attack"
        case BattleText.FoeDamaged => "foeDamaged"
        case BattleText.AllyDamaged => "allyDamaged"
        case BattleText.Critical => "critical"
        case BattleText.Miss => "miss"
        case BattleText.FoeDown => "foeDown"
        case BattleText.AllyDown => "allyDown"
        case BattleText.Defend => "defend"
        case BattleText.Guard => "guard"
        case BattleText.Sweep => "sweep"
        case BattleText.Run => "run"
        case BattleText.Fled => "fled"
        case BattleText.Blocked => "blocked"
        case BattleText.NoFlee => "noFlee"
        case BattleText.Won => "won"
        case BattleText.Exp => "exp"
        case BattleText.GoldGot => "goldGot"
        case BattleText.LevelUp => "levelUp"
        case BattleText.Wiped => "wiped"
        case BattleText.Cast => "cast"
        case BattleText.UseItem => "useItem"
        case BattleText.AllyHealed => "allyHealed"
        case BattleText.AllyMpHealed => "allyMpHealed"
        case BattleText.FoeHealed => "foeHealed"
        case BattleText.MpShort => "mpShort"
        case BattleText.ItemGone => "itemGone"
        case BattleText.NoEffect => "noEffect"
        case BattleText.Asleep => "asleep"
        case BattleText.Woke => "woke"
        case BattleText.SleepAct => "sleepAct"
        case BattleText.FellAsleep => "fellAsleep"
        case BattleText.SleepMiss => "sleepMiss"
        case BattleText.Learned => "learned"
    }

    def battleDefaultOf(m: BattleText): String = match m {
        case BattleText.Appear => "{name}が あらわれた！"
        case BattleText.Attack => "{name}の こうげき！"
        case BattleText.FoeDamaged => "{target}に {n}ポイントの ダメージ！"
        case BattleText.AllyDamaged => "{target}は {n}ポイントの ダメージを うけた！"
        case BattleText.Critical => "かいしんの いちげき！"
        case BattleText.Miss => "しかし {target}は もう いない。"
        case BattleText.FoeDown => "{target}を たおした！"
        case BattleText.AllyDown => "{target}は たおれてしまった！"
        case BattleText.Defend => "{name}は みを まもっている。"
        case BattleText.Guard => "{name}は みを かためている。"
        case BattleText.Sweep => "{name}は あばれまわった！"
        case BattleText.Run => "{name}は にげだした！"
        case BattleText.Fled => "うまく にげきれた！"
        case BattleText.Blocked => "しかし まわりこまれてしまった！"
        case BattleText.NoFlee => "しかし にげられない！"
        case BattleText.Won => "まものたちを やっつけた！"
        case BattleText.Exp => "それぞれ {n}ポイントの けいけんちを かくとく！"
        case BattleText.GoldGot => "{n}ゴールドを てにいれた！"
        case BattleText.LevelUp => "{name}は レベル{lv}に あがった！"
        case BattleText.Wiped => "ぜんめつ してしまった…"
        case BattleText.Cast => "{name}は {spell}を となえた！"
        case BattleText.UseItem => "{name}は {item}を つかった！"
        case BattleText.AllyHealed => "{target}の HPが {n} かいふくした！"
        case BattleText.AllyMpHealed => "{target}の MPが {n} かいふくした！"
        case BattleText.FoeHealed => "{target}の キズが {n} ふさがった！"
        case BattleText.MpShort => "しかし MPが たりない！"
        case BattleText.ItemGone => "しかし {item}は もう なかった！"
        case BattleText.NoEffect => "しかし なにも おこらなかった。"
        case BattleText.Asleep => "{name}は ねむっている。"
        case BattleText.Woke => "{name}は めを さました！"
        case BattleText.SleepAct => "{name}は あやしい こなを まきちらした！"
        case BattleText.FellAsleep => "{target}は ねむってしまった！"
        case BattleText.SleepMiss => "しかし {target}には きかなかった！"
        case BattleText.Learned => "{name}は {spell}を おぼえた！"
    }

    /// 話し手の声の高さ（文字送りの音。rpg.text.json の speakers の voice）。
    pub enum Voice with Eq, Order, ToString {
        case Low
        case Mid
        case High
    }

    /// Doc の voice の名前 → 声の高さ。
    def voiceNamed(name: String): Option[Voice] = match name {
        case "low"  => Some(Voice.Low)
        case "mid"  => Some(Voice.Mid)
        case "high" => Some(Voice.High)
        case _      => None
    }

    /// speakers = 会話の話し手の id → 呼び名、voices = 話し手の id → 声の高さ（書いていない話し手は無い）、
    /// menu = メニューの言葉の鍵 → 字、notice = 知らせの言葉の鍵 → 字、
    /// battle = 戦いの伝言の鍵 → 字、credits = エンディングのスタッフの字（上から 1 行ずつ。空の行は間を空ける。{lv}・{gold} は EndingView が埋める）、
    /// problems = 読めずに飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, speakers = Map[String, String], voices = Map[String, Voice], menu = Map[String, String],
                           notice = Map[String, String], battle = Map[String, String], credits = List[String], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum TextDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = TextDocOf

    pub def rec(d: Doc): Rec = match d { case TextDocOf.TextDocOf(r) => r }

    pub def path(): String = "assets/rpg.text.json"

    def defaults(): Doc = TextDocOf.TextDocOf({ version = 1, speakers = Map.empty(), voices = Map.empty(), menu = Map.empty(), notice = Map.empty(), battle = Map.empty(), credits = Nil, problems = Nil })

    /// 話し手の呼び名（書いていなければ id のまま。地の文の空の id は空）。
    pub def speakerName(id: String, d: Doc): String = Map.getWithDefault(id, id, rec(d)#speakers)

    /// 話し手の声の高さ（voice を書いていない話し手・地の文の空の id は Mid）。
    pub def voiceOf(id: String, d: Doc): Voice = Map.getWithDefault(id, Voice.Mid, rec(d)#voices)

    /// 話し手の id の一覧（名前の順）。会話の語彙（Talk.vocabOf）の話し手はこれ。
    pub def speakerIds(d: Doc): List[String] = rec(d)#speakers |> Map.keysOf |> Set.toList

    /// メニューの言葉（書いていなければコードの既定）。
    pub def menuText(m: MenuText, d: Doc): String = Map.getWithDefault(menuKeyOf(m), menuDefaultOf(m), rec(d)#menu)

    /// 知らせと戦いの伝言の字に埋める値の名前（rpg.text.json の {name}・{target}・{n}・{lv}・{item}・{gold}）。
    pub enum Placeholder with Eq, Order, ToString {
        case Name
        case Target
        case N
        case Lv
        case Item
        case Gold
        case Spell
    }

    /// 字の中の {鍵} の鍵。
    def placeholderKeyOf(p: Placeholder): String = match p {
        case Placeholder.Name   => "name"
        case Placeholder.Target => "target"
        case Placeholder.N      => "n"
        case Placeholder.Lv     => "lv"
        case Placeholder.Item   => "item"
        case Placeholder.Gold   => "gold"
        case Placeholder.Spell  => "spell"
    }

    /// 字の {鍵} を values で埋める。
    def fillIn(values: List[(Placeholder, String)], text: String): String =
        values |> List.foldLeft((acc, pair) -> String.replace(src = "{${placeholderKeyOf(fst(pair))}}", dst = snd(pair), acc), text)

    /// 知らせの言葉（書いていなければコードの既定）の {鍵} を values で埋めた字。
    pub def noticeText(m: NoticeText, values: List[(Placeholder, String)], d: Doc): String =
        fillIn(values, Map.getWithDefault(noticeKeyOf(m), noticeDefaultOf(m), rec(d)#notice))

    /// 戦いの伝言（書いていなければコードの既定）の {鍵} を values で埋めた字。
    pub def battleText(m: BattleText, values: List[(Placeholder, String)], d: Doc): String =
        fillIn(values, Map.getWithDefault(battleKeyOf(m), battleDefaultOf(m), rec(d)#battle))

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let (speakers, speakerProblems) = catalogOf("speakers", "name", root);
        let (menu, menuProblems) = catalogOf("menu", "text", root);
        let (notice, noticeProblems) = catalogOf("notice", "text", root);
        let (battle, battleProblems) = catalogOf("battle", "text", root);
        let (voices, voiceProblems) = voicesOf(root);
        let (credits, creditProblems) = creditsOf(root);
        TextDocOf.TextDocOf({ version = JsonCodec.intOr("version", d#version, root),
                  speakers = speakers, voices = voices, menu = menu, notice = notice, battle = battle, credits = credits,
                  problems = List.flatten(speakerProblems :: voiceProblems :: menuProblems :: noticeProblems :: battleProblems :: creditProblems :: Nil) })

    /// credits の list（1 行 = { text }）を上からの字の並びへ。text の無い行は飛ばして問題に挙げる。
    def creditsOf(root: Map[String, Json]): (List[String], List[String]) =
        let rows = Map.get("credits", root)
            |> Option.flatMap(JsonCodec.decodeList(json -> Some(json)))
            |> Option.getWithDefault(Nil)
            |> List.map(row -> JsonCodec.expectObject(row) |> Option.flatMap(obj -> Map.get("text", obj)) |> Option.flatMap(JsonCodec.expectString));
        let problems = rows |> List.zipWithIndex |> List.filterMap(match (i, text) ->
            if (Option.isEmpty(text)) Some("[text] credits の ${i + 1} 行目に text が無いので飛ばす") else None);
        (rows |> List.filterMap(x -> x), problems)

    /// エンディングのスタッフの字（{鍵} を values で埋めた物。上から）。
    pub def creditLines(values: List[(Placeholder, String)], d: Doc): List[String] =
        rec(d)#credits |> List.map(fillIn(values))

    /// speakers の行の voice（low / mid / high）。書いていない行は飛ばし、知らない名前は Mid で出すと問題に挙げる。
    def voicesOf(root: Map[String, Json]): (Map[String, Voice], List[String]) =
        let named = Map.get("speakers", root)
            |> Option.flatMap(JsonCodec.decodeStringMap(json -> Some(json)))
            |> Option.getWithDefault(Map.empty())
            |> Map.filterMap(row -> JsonCodec.expectObject(row) |> Option.flatMap(obj -> Map.get("voice", obj)) |> Option.flatMap(JsonCodec.expectString));
        let problems = named |> Map.toList |> List.filter(pair -> Option.isEmpty(voiceNamed(snd(pair))))
            |> List.map(match (key, name) -> "[text] speakers の '${key}' の voice '${name}' は low / mid / high でないので mid で出す");
        (named |> Map.filterMap(voiceNamed), problems)

    /// catalog の節（鍵 → { field: 字 }）を 鍵 → 字 へ。字の欄が無い行は捨て（その鍵は既定の字で出る）、捨てた行を問題に挙げる。
    def catalogOf(section: String, field: String, root: Map[String, Json]): (Map[String, String], List[String]) =
        let decoded = Map.get(section, root)
            |> Option.flatMap(JsonCodec.decodeStringMap(json -> Some(json)))
            |> Option.getWithDefault(Map.empty())
            |> Map.map(row -> JsonCodec.expectObject(row) |> Option.flatMap(obj -> Map.get(field, obj)) |> Option.flatMap(JsonCodec.expectString));
        let problems = decoded |> Map.toList |> List.filterMap(match (key, text) ->
            if (Option.isEmpty(text)) Some("[text] ${section} の '${key}' に ${field} が無いので既定の字で出す") else None);
        (decoded |> Map.filterMap(x -> x), problems)

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
