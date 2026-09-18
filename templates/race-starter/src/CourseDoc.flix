// CourseDoc — race.course.json（コースの形）の宣言ドキュメント層。
// コースは「区間の表」1 枚で表す。1 区間 = 同じ曲がり方が続くひとまとまりで、
//   len   … 何行ぶん続くか（1 行 = World.rowPitch = 40px）
//   curve … 1 行ごとに道が曲がっていく強さ（+ が右・0 が直線）。曲がりは行を追うごとに
//           足し上がるので、同じ値が続くほど先の道は急に折れていく（これが 90 度・U 字の正体）。
//   hill  … 1 行ごとに道が起きていく強さ（+ が登り・0 が平ら）。曲がりとまったく同じ数式で
//           2 回足し上がるので、同じ値が続くほど坂は急になり、頂上の先は道が隠れる。
//   width … 道幅（% — 100 が基準の道幅 baseHalfWidth の 2 倍）
//   rail  … ガードレールを立てる側（"none" / "left" / "right" / "out"）。"out" は
//           コーナーの外側（曲がりの向きの反対）— 直線の区間では立たない。
//
// 立ち物（アイテム・コーン・ゲート・振り子バー）の置き場は別 Doc（race.props.json）。
// コースは先頭へ巻き戻して周回する（sectionAt が余りで巻き戻す）。
// 曲がる・はみ出す・周回するの規則はコード（World）側 — ここは「道の形」だけ。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod CourseDoc {
    use Util.Json.Json

    /// コースの区間 1 つ。
    pub type alias Section = {
        len = Int32,
        curve = Float64,
        hill = Float64,
        width = Float64,
        rail = String,
        note = String
    }

    /// コースの形。sections = スタートから先へ 1 区間ずつ。
    pub type alias Rec = {
        version = Int32,
        sections = List[Section]
    }

    // 型検査が record を展開しないため、World が持つ公開の型は enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/race.course.json"

    /// 道幅 100% のときの半幅（px）。区間の width はこれに対する百分率。
    pub def baseHalfWidth(): Float64 = 50.0

    /// 区間が 1 つも無いときの落とし先。直線が延々続くコースになる（画面に穴を開けない）。
    def straight(): Section =
        { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "" }

    /// コード側の既定値。1 周 66 行（周長は行数 × World.rowPitch から導かれる = 2640px）。
    /// リズムは 2 幕。第 1 幕（起承転結）: スタート直線 → 緩い右（教習）→ 登り →
    /// 急な左ヘアピン（試験・外側にガードレール）→ 救済直線 → 右→左の切り返し（見せ場）→ ゴール直線。
    /// 第 2 幕はその鏡像（左へ流して右の 3 連で返す）— 同じ手が左右逆でもう一度試される。
    /// curve の合計も hill の合計も 0（1 周でちょうど向きと高さが戻る）— 空の流れと
    /// 地平線が周回の継ぎ目で飛ばない。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          sections =
              { len = 3, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "スタート直線（スリップ勝負）" }
           :: { len = 4, curve = 6.0, hill = 1.0, width = 100.0, rail = "none", note = "緩い右の登り（膨らみを教える）" }
           :: { len = 2, curve = 0.0, hill = 1.0, width = 100.0, rail = "none", note = "登りきる（2 行目にゲート。頂上の先は道が隠れる）" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "コーンの行" }
           :: { len = 1, curve = 0.0 - 18.0, hill = 0.0 - 1.0, width = 100.0, rail = "none", note = "U 字の入口（下りに入る。ここで速度を決める）" }
           :: { len = 5, curve = 0.0 - 60.0, hill = 0.0 - 1.0, width = 88.0, rail = "out", note = "左の U 字。全速では曲がりきれない（ブレーキかドリフト、でなければ外壁を擦る）" }
           :: { len = 3, curve = 36.0, hill = 0.0, width = 100.0, rail = "none", note = "巻き込みを解いて立ち上がる" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "救済のアイテムの行（下位の逆転口）" }
           :: { len = 2, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "息継ぎ（2 行目にゲート）" }
           :: { len = 3, curve = 20.0, hill = 0.0, width = 100.0, rail = "none", note = "右へ切り込み（見せ場）" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "切り返しの頂点（コーンの行）" }
           :: { len = 1, curve = 0.0 - 18.0, hill = 0.0, width = 100.0, rail = "none", note = "左スナップ" }
           :: { len = 1, curve = 0.0 - 18.0, hill = 0.0, width = 100.0, rail = "none", note = "リスク線上のアイテムの行" }
           :: { len = 1, curve = 10.0, hill = 0.0, width = 100.0, rail = "none", note = "小さく右へフリックして締める" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "ゴール直線のアイテムの行" }
           :: { len = 4, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "長い直線（振り子バーの行を含む）" }
           :: { len = 2, curve = 0.0 - 3.0, hill = 1.2, width = 100.0, rail = "none", note = "ごく緩い左の登り（第 2 幕は鏡像）" }
           :: { len = 2, curve = 0.0, hill = 0.0 - 1.2, width = 100.0, rail = "none", note = "下りの直線" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "コーンの行" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "" }
           :: { len = 1, curve = 10.0, hill = 0.0, width = 100.0, rail = "none", note = "ゲートの行（右ヘアピンの手前）" }
           :: { len = 4, curve = 46.0, hill = 0.0, width = 92.0, rail = "out", note = "右ヘアピン（U 字の鏡。ぎりぎり全速で曲がれる）" }
           :: { len = 3, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "右端の直線（振り子バーの行を含む）" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "コーンの行" }
           :: { len = 2, curve = 0.0 - 8.0, hill = 0.0, width = 100.0, rail = "none", note = "緩い左" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "" }
           :: { len = 1, curve = 0.0 - 8.0, hill = 0.0, width = 100.0, rail = "none", note = "コーナー中のアイテムの行（リスク線）" }
           :: { len = 2, curve = 0.0 - 22.0, hill = 0.0, width = 100.0, rail = "none", note = "左スナップ 2 連" }
           :: { len = 2, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "左端の直線（振り子バーの行を含む）" }
           :: { len = 1, curve = 6.0, hill = 0.0, width = 100.0, rail = "none", note = "" }
           :: { len = 2, curve = 23.0, hill = 0.0, width = 100.0, rail = "out", note = "右へ大きく返す（外側に壁）" }
           :: { len = 1, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "" }
           :: { len = 2, curve = 0.0 - 10.0, hill = 0.0, width = 100.0, rail = "none", note = "最後の左" }
           :: { len = 2, curve = 0.0, hill = 0.0, width = 100.0, rail = "none", note = "ゴール前の直線（スタート行へ繋がる）" }
           :: Nil })

    /// 行の数（コース 1 周の行数）。前進距離を行に写すときの割り算の分母。
    pub def rowCount(doc: Doc): Int32 =
        rec(doc)#sections |> List.foldLeft((acc, s) -> acc + lenOf(s), 0)

    /// 区間の行数（0 以下は 1 行にする — 幅ゼロの区間で表が止まらないように）。
    def lenOf(s: Section): Int32 =
        Int32.max(1, s#len)

    /// 通し行 n（0 始まり・範囲外は先頭へ巻き戻す = 周回）を、コース 1 周の中の行へ写す。
    /// 立ち物の置き場（PropsDoc）も同じ物差しで引く。
    pub def wrapRow(n: Int32, doc: Doc): Int32 =
        let count = rowCount(doc);
        if (count <= 0) 0 else Int32.modulo(Int32.modulo(n, count) + count, count)

    /// 通し行 n が入っている区間と、その区間の中で何行目か。
    /// ここだけが「行 → 区間」を決める唯一の入口。
    pub def sectionAt(n: Int32, doc: Doc): { sec = Section, idx = Int32 } =
        if (rowCount(doc) <= 0) { sec = straight(), idx = 0 }
        else walk(wrapRow(n, doc), rec(doc)#sections)

    def walk(k: Int32, secs: List[Section]): { sec = Section, idx = Int32 } =
        match secs {
            case Nil       => { sec = straight(), idx = 0 }
            case s :: rest => if (k < lenOf(s)) { sec = s, idx = k } else walk(k - lenOf(s), rest)
        }

    /// 通し行 n で道が曲がっていく強さ（+ が右）。
    pub def curveAt(n: Int32, doc: Doc): Float64 =
        (sectionAt(n, doc))#sec#curve

    /// 通し行 n で道が起きていく強さ（+ が登り）。
    pub def hillAt(n: Int32, doc: Doc): Float64 =
        (sectionAt(n, doc))#sec#hill

    /// 通し行 n の道の半幅（px）。細すぎる指定は 10% で止める（車が通れない道を作らない）。
    pub def halfWidthAt(n: Int32, doc: Doc): Float64 =
        baseHalfWidth() * Float64.max(10.0, (sectionAt(n, doc))#sec#width) / 100.0

    /// 通し行 n にガードレールが立っている側（-1 = 左・+1 = 右・0 = 立っていない）。
    /// "out" はコーナーの外側 = 曲がりの向きの反対。直線では外側が決まらないので立たない。
    pub def railSideAt(n: Int32, doc: Doc): Float64 =
        let a = sectionAt(n, doc);
        match a#sec#rail {
            case "left"  => -1.0
            case "right" => 1.0
            case "out"   =>
                let c = a#sec#curve;
                if (c > 0.0) -1.0 else if (c < 0.0) 1.0 else 0.0
            case _       => 0.0
        }

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          sections = sectionsOr(d#sections, root) })

    /// sections（区間の一覧）を読む。配列でない・空のときは既定のコースを使う。
    /// 欄が欠けた区間は、その欄だけ「直線 1 行」の値にする（区間ごと捨てない）。
    def sectionsOr(fallback: List[Section], root: Map[String, Json]): List[Section] =
        Map.get("sections", root)
            |> Option.flatMap(JsonCodec.decodeList(sectionOf))
            |> Option.filter(secs -> not List.isEmpty(secs))
            |> Option.getWithDefault(fallback)

    def sectionOf(json: Json): Option[Section] =
        JsonCodec.expectObject(json) |> Option.map(obj -> {
            let d = straight();
            { len = JsonCodec.intOr("len", d#len, obj),
              curve = JsonCodec.floatOr("curve", d#curve, obj),
              hill = JsonCodec.floatOr("hill", d#hill, obj),
              width = JsonCodec.floatOr("width", d#width, obj),
              rail = JsonCodec.stringOr("rail", d#rail, obj),
              note = JsonCodec.stringOr("note", d#note, obj) }
        })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
