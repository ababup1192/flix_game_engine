// Gate — 払い・タップで選ぶ選択肢（純粋）。組の全部に #act: タグが付いた選択肢はボタンを出さず、
// 入力の案内（Hint）を出して決まった操作を待つ。選んだら Choose(番号) を通すので、セーブ・ロード・戻るはふつうの選択肢と同じ道で戻る。
//
//   -> 上へ払って次へ #act:up                 act = up / down / left / right / tap
//   -> 鍵をタップ #act:tap #at:key            at = tap の当たる物（novel.prompts.json の targets。無ければ頁のどこでも）
//   -> 下へ払って切る #act:down #icon:blade   icon = 案内に添える絵と色（novel.prompts.json の icons）
//   -> 上へ #act:up #mute                     mute = 案内に字を出さない
mod Gate {
    use fge::{Yarn, YarnRunner}
    use Util.Json.Json

    /// 選ぶ操作。Swipe = その向きへ払う、Tap = 当たる物（空なら頁のどこでも）を押して離す。
    pub enum Act with Eq, ToString {
        case Swipe(Gesture.Direction)
        case Tap(String)
    }

    /// ゲートへの入力。Did = 操作をした、Confirm = 決定のキー（tap の選択肢がちょうど 1 つの時だけ選ぶ）。
    pub enum Input with Eq, ToString {
        case Did(Act)
        case Confirm
    }

    /// 選べる 1 つ。index = 選択肢の並びの番号（Choose に渡す）、icon = 案内の絵の名前、caption = 案内の字（mute なら None）。
    pub type alias Choice = { act = Act, index = Int32, icon = Option[String], caption = Option[String] }

    /// 今のゲート。viaLine = 台詞の頁のまま待つ（払うと台詞を送ってから選ぶ）。
    pub type alias Gate = { choices = List[Choice], viaLine = Bool }

    /// act の値（決まった一覧）。
    pub def actNames(): List[String] = "up" :: "down" :: "left" :: "right" :: "tap" :: Nil

    /// vocab.json の tags（act は決まった一覧・at と icon は prompts（vocab.json から見た novel.prompts.json のパス）の鍵・mute は値を取らない）。
    pub def tagsJson(prompts: String): Json =
        let strings = xs -> Json.JArray(xs |> List.map(Json.JString) |> List.toVector);
        let fromPrompts = key -> Json.JObject(Map#{ "from" => Json.JArray(Vector#{ Json.JObject(Map#{ "doc" => Json.JString(prompts), "keys" => Json.JString(key) }) }) });
        Json.JObject(Map#{ "act" => strings(actNames()), "at" => fromPrompts("targets"), "icon" => fromPrompts("icons"), "mute" => strings(Nil) })

    /// 選択肢の組のゲート（組の全部に読める #act があり、選べる物が 1 つ以上ある時だけ。選べない選択肢は並べない）。
    // WhyNot: 選べる物が 0 のゲートを作らない — 案内が 1 つも出ず、何も起きない画面で止まる。ボタンの選択肢なら選べない物を薄く出して止まった訳が見える。
    pub def ofOptions(options: List[YarnRunner.DialogueOption]): Option[List[Choice]] =
        let read = options |> List.zipWithIndex |> List.map(match (i, option) -> actOf(option#line#tags) |> Option.map(act -> (i, option, act)));
        let open = read |> List.filterMap(x -> x) |> List.filter(match (_, option, _) -> option#available)
                        |> List.map(match (i, option, act) -> choiceOf(i, option, act));
        if (List.isEmpty(options) or List.exists(Option.isEmpty, read) or List.isEmpty(open)) None else Some(open)

    def choiceOf(i: Int32, option: YarnRunner.DialogueOption, act: Act): Choice =
        let tags = option#line#tags;
        { act = act, index = i, icon = Yarn.tagOf("icon", tags),
          caption = if (isMuted(tags)) None else Some(option#line#text) }

    def isMuted(tags: List[Yarn.Tag]): Bool = List.exists(tag -> tag#key == "mute", tags)

    def actOf(tags: List[Yarn.Tag]): Option[Act] = match Yarn.tagOf("act", tags) {
        case Some("up")    => Some(Act.Swipe(Gesture.Direction.Up))
        case Some("down")  => Some(Act.Swipe(Gesture.Direction.Down))
        case Some("left")  => Some(Act.Swipe(Gesture.Direction.Left))
        case Some("right") => Some(Act.Swipe(Gesture.Direction.Right))
        case Some("tap")   => Some(Act.Tap(Yarn.tagOf("at", tags) |> Option.getWithDefault("")))
        case _             => None
    }

    /// 入力が選ぶ選択肢の番号（どれにも当たらなければ None）。当たる物の無い tap（Tap("")）は、どこを押した tap でも選ぶ。
    pub def pick(gate: Gate, input: Input): Option[Int32] = match input {
        case Input.Did(act) => gate#choices |> List.find(choice -> accepts(act, choice#act)) |> Option.map(choice -> choice#index)
        case Input.Confirm  => loneTapOf(gate)
    }

    /// tap の選択肢がちょうど 1 つならその番号。
    def loneTapOf(gate: Gate): Option[Int32] = match gate#choices |> List.filter(choice -> isTap(choice#act)) {
        case only :: Nil => Some(only#index)
        case _           => None
    }

    def accepts(done: Act, wanted: Act): Bool = match (done, wanted) {
        case (Act.Tap(_), Act.Tap("")) => true
        case _                         => done == wanted
    }

    def isTap(act: Act): Bool = match act {
        case Act.Tap(_)   => true
        case Act.Swipe(_) => false
    }

    /// 操作の名前（up・down・left・right・tap・tap:当たる物）。
    pub def actText(act: Act): String = match act {
        case Act.Swipe(dir) => String.toLowerCase("${dir}")
        case Act.Tap("")    => "tap"
        case Act.Tap(name)  => "tap:${name}"
    }
}
