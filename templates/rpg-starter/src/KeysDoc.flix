// KeysDoc — assets/rpg.keys.json（キーの割り当て）の Doc 層。
// 「どのキーがどの操作か」だけを外に出す。1 つの操作に複数キーを並べられる（矢印と WASD の両対応）。
// fail-open — 読めない・欄が空・全部知らない名前のときは、その操作だけコードの既定へ落とす。
mod KeysDoc {
    use fge::{Dir4, DocJson, InputMap, JsonCodec}
    use fge::GameEngine.Key
    use Util.Json.Json

    /// 操作ごとのキーの列。
    pub type alias Rec = {
        version = Int32,
        up = List[Key],      // 上へ歩く・カーソルを上へ
        down = List[Key],    // 下へ歩く・カーソルを下へ
        left = List[Key],    // 左へ歩く
        right = List[Key],   // 右へ歩く
        confirm = List[Key], // 決定・話す・調べる・文字送り
        cancel = List[Key],  // 取消（メニューも開く）
        problems = List[String] // 読めずに捨てた名前・既定へ落とした操作（Res.problemsOf が言う）
    }
    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum KeysDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = KeysDocOf
    pub def rec(d: Doc): Rec = match d { case KeysDocOf.KeysDocOf(r) => r }

    pub def path(): String = "assets/rpg.keys.json"

    /// コード側の既定（assets/rpg.keys.json と同じ割り当て）。
    pub def defaults(): Doc =
        KeysDocOf.KeysDocOf({ version = 1,
                  up = Key.Up :: Key.W :: Nil,
                  down = Key.Down :: Key.S :: Nil,
                  left = Key.Left :: Key.A :: Nil,
                  right = Key.Right :: Key.D :: Nil,
                  confirm = Key.Z :: Key.Enter :: Key.Space :: Nil,
                  cancel = Key.X :: Key.Backspace :: Nil, problems = Nil })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let (up, upProblems) = keysOr("up", d#up, root);
        let (down, downProblems) = keysOr("down", d#down, root);
        let (left, leftProblems) = keysOr("left", d#left, root);
        let (right, rightProblems) = keysOr("right", d#right, root);
        let (confirm, confirmProblems) = keysOr("confirm", d#confirm, root);
        let (cancel, cancelProblems) = keysOr("cancel", d#cancel, root);
        KeysDocOf.KeysDocOf({ version = JsonCodec.intOr("version", d#version, root),
                  up = up, down = down, left = left, right = right, confirm = confirm, cancel = cancel,
                  problems = List.flatten(upProblems :: downProblems :: leftProblems :: rightProblems :: confirmProblems :: cancelProblems :: Nil) })

    /// 欄の文字列列 → キーの列と知らせる行。知らない名前はその 1 個だけ捨て、列ごと空になる形だけ既定へ落とす。欄が無ければ黙って既定。
    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): (List[Key], List[String]) =
        let names = Map.get(field, root) |> Option.flatMap(element -> JsonCodec.decodeList(JsonCodec.expectString, element));
        match names {
            case None        => (fallback, Nil)
            case Some(given) =>
                let keys = InputMap.keysOf(given);
                let unknown = given |> List.filter(name -> List.isEmpty(InputMap.keysOf(name :: Nil)));
                let dropped = if (List.isEmpty(unknown)) Nil else "[keys] ${field} の知らないキー '${List.join(", ", unknown)}' は捨てる" :: Nil;
                if (List.isEmpty(keys)) (fallback, List.append(dropped, "[keys] ${field} のキーが 1 つも無いので既定のキー" :: Nil))
                else (keys, dropped)
        }

    /// d の方向へ歩く・カーソルを動かすキーの列。
    pub def dirKeys(k: Rec, d: Dir4.Dir4): List[Key] = match d {
        case Dir4.Dir4.Up    => k#up
        case Dir4.Dir4.Down  => k#down
        case Dir4.Dir4.Left  => k#left
        case Dir4.Dir4.Right => k#right
    }
}
