// Talk — 会話のシナリオ（assets/talk/*.yarn）とコードの繋ぎ。
// 台詞・話し手・選択肢はシナリオ、話し手の呼び名は StoryDoc、どのノードから読み始めるかはここ（コード）。
// 話し手・タグ・開くノードの名前の正はこの enum で、bin/fge yarn build の check は vocab で書き出した語彙を読む
// （書き直すのは make talk-vocab。TestDocs が書き出しとファイルの一致を見る）。
//
//   assets/talk/novel.yarn ──bin/fge yarn build assets/talk──▶ assets/talk/dialogue.json ──load──▶ World#dialogue
mod Talk {

    use fge::{Yarn}

    /// 話し手（シナリオの「me: 台詞」の左）。地の文は話し手を書かない。
    pub enum Speaker with Eq, ToString {
        case Me, Master, Butler, Dealer
    }

    pub def speakers(): List[Speaker] = List#{Speaker.Me, Speaker.Master, Speaker.Butler, Speaker.Dealer}

    pub def speakerId(speaker: Speaker): String = match speaker {
        case Speaker.Me     => "me"
        case Speaker.Master => "master"
        case Speaker.Butler => "butler"
        case Speaker.Dealer => "dealer"
    }

    /// コードが開くノード（それ以外のノードはシナリオの <<jump>> で辿る）。
    pub enum Node with Eq, ToString {
        case Arrival
    }

    pub def nodeName(node: Node): String = match node {
        case Node.Arrival => "arrival"
    }

    /// 「誰かを疑う」選択肢の目印（#suspect。選ぶと館の灯りがひとつ消える）。
    pub def suspectTag(): String = "suspect"

    /// 選択肢が疑う選択か。
    pub def isSuspect(line: Yarn.Line): Bool = Option.nonEmpty(Yarn.tagOf(suspectTag(), line#tags))

    pub def dialoguePath(): String = "assets/talk/dialogue.json"

    pub def vocabPath(): String = "assets/talk/vocab.json"

    /// シナリオを読む。読めない・壊れている時はノードの無いシナリオ（World が直し方を語る 1 行を出す）。
    pub def load(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), dialoguePath())

    /// build の check が読む語彙。
    pub def vocabOf(): Yarn.Vocab =
        { speakers = Yarn.namesOf(speakerId, speakers()),
          nodes = Yarn.namesOf(nodeName, List#{Node.Arrival}),
          tags = (suspectTag(), Nil) :: Nil,
          commands = Nil }

    /// 語彙を assets/talk/vocab.json に書く（make talk-vocab）。
    pub def vocab(): Unit \ IO = run { println(if (Yarn.writeVocab(vocabPath(), vocabOf())) "[talk] 語彙を書いた: ${vocabPath()}" else "[talk] 語彙を書けない: ${vocabPath()}") } with Fs.FileWrite.runWithIO
}
