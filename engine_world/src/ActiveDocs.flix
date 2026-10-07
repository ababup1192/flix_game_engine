// ActiveDocs — 走っているゲームが「いま表示に使っている Doc(JSON)はどれか」を
// debug/active-docs.json に名乗る入口。別プロセスのエディタ(Studio)がこれを読み、
// ファイル一覧の該当ファイルに「表示中」の印を付ける。
// キーは project.json の editor 宣言 id(theme / sprite / kind 等)と一致させる —
// エディタ側がグループの突き合わせに使うため。値はパス 1 本でも列でもよい。
// 全 Doc を常時名乗らないこと: いまの場面で絵や進行に効いている物だけを渡す
// (何でも「表示中」では印の意味が死ぬ)。
pub mod ActiveDocs {
    use Util.Json.Json.{JObject, JString, JArray}

    /// 書き出し先。debug/ は .gitignore 済みの作業用置き場。
    pub def path(): String = "debug/active-docs.json"

    /// entries(editor 宣言 id → 表示中パスの列)をエディタが読む形の JSON にする。
    /// 例: { "active": { "theme": "assets/x.theme.json", "ui": ["a.ui.json", "b.ui.json"] } }
    pub def json(entries: List[(String, List[String])]): String =
        entries
            |> List.map(entry -> { let (id, paths) = entry; (id, pathsJson(paths)) })
            |> List.toMap
            |> fields -> JObject(Map#{"active" => JObject(fields)})
            |> Util.Json.toPrettyString(2)

    /// パス 1 本は文字列、複数は列で書く(エディタはどちらも同じ形に読む)。
    def pathsJson(paths: List[String]): Util.Json.Json =
        match paths {
            case one :: Nil => JString(one)
            case many       => JArray(List.map(JString, many) |> List.toVector)
        }

    /// entries の指紋(id とパスを区切り文字で 1 本に綴じた文字列)。step はまずこれで
    /// 前回と見比べ、変わったフレームだけ JSON を組み直す — JSON の組み立て
    /// (Map・Json の木・整形)を毎フレームやると、名乗りが変わらないフレームでも
    /// 確保だけが積み上がるため。区切りはパスに現れないタブと改行。
    pub def fingerprint(entries: List[(String, List[String])]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(entry -> {
                let (id, paths) = entry;
                StringBuilder.append(id, sb);
                StringBuilder.append("\t", sb);
                List.forEach(p -> {
                    StringBuilder.append(p, sb);
                    StringBuilder.append("\t", sb)
                }, paths);
                StringBuilder.append("\n", sb)
            }, entries);
            StringBuilder.toString(sb)
        }

    /// 毎フレームのシステムから呼ぶ。一覧の指紋が前回書いた物(World の activeDocsWritten)と
    /// 同じなら何もしない — JSON の組み立ても実 IO も、場面が変わった瞬間だけ走る。
    /// 書き込みの失敗は握り潰す(エディタ向けの補助情報で、書けない環境でも
    /// ゲーム本体を止める理由にならない)。
    /// World には `activeDocsWritten = String` の欄を足し、出発点は "" にする
    /// (中身は指紋 — 書いた JSON そのものではない)。
    pub def step(entries: List[(String, List[String])],
                 w: { activeDocsWritten = String | r }): { activeDocsWritten = String | r } \ Fs.FileWrite =
        let current = fingerprint(entries);
        if (current == w#activeDocsWritten) w
        else {
            run {
                discard Fs.WriteFile.write({str = json(entries)}, path())
            } with Fs.WriteFile.runWithFileWrite;
            { activeDocsWritten = current | w }
        }
}
