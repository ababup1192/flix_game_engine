// Talk — シナリオ（assets/talk/*.yarn）とコードの繋ぎ。
// 話し手・最初に開くノード・コマンドの名前の正はここ（コマンドの意味は Stage）。bin/fge yarn build の check は
// この語彙を書き出した assets/talk/vocab.json を読む（書き直すのは make talk-vocab。TestDocs が一致を見る）。
//
//   assets/talk/natsukusa.yarn ──bin/fge yarn build assets/talk──▶ assets/talk/dialogue.json ──load──▶ World#dialogue
mod Talk {
    use fge::{Yarn}

    /// 話し手（シナリオの「chinatsu: 台詞」の左）。地の文は話し手を書かない。
    pub enum Speaker with Eq, ToString {
        case Chinatsu, Me
    }

    pub def speakers(): List[Speaker] = Speaker.Chinatsu :: Speaker.Me :: Nil

    pub def speakerId(speaker: Speaker): String = match speaker {
        case Speaker.Chinatsu => "chinatsu"
        case Speaker.Me       => "me"
    }

    /// コードが開くノード（それ以外はシナリオの <<jump>> で辿る）。
    pub enum Node with Eq, ToString {
        case Opening
    }

    pub def nodeName(node: Node): String = match node {
        case Node.Opening => "Station"
    }

    pub def dialoguePath(): String = "assets/talk/dialogue.json"

    pub def vocabPath(): String = "assets/talk/vocab.json"

    /// シナリオを読む。読めない・壊れている時はノードの無いシナリオ（World が直し方を語る 1 行を出す）。
    pub def load(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), dialoguePath())

    /// build の check が読む語彙。
    pub def vocabOf(): Yarn.Vocab =
        { speakers = Yarn.namesOf(speakerId, speakers()),
          nodes = Yarn.namesOf(nodeName, Node.Opening :: Nil),
          tags = Nil,
          commands = Stage.commandNames() }

    /// 語彙を assets/talk/vocab.json に書く（make talk-vocab）。
    pub def vocab(): Unit \ IO = run { println(if (Yarn.writeVocab(vocabPath(), vocabOf())) "[talk] 語彙を書いた: ${vocabPath()}" else "[talk] 語彙を書けない: ${vocabPath()}") } with Fs.FileWrite.runWithIO
}
