// DocTable — Doc(JSON) のテーブル。1 行 = 「Studio の editor 宣言 id・監視パス・読み直し」。
// 同じ Doc 一覧を watchFile の配線・一括リロード(F1)・ActiveDocs の名乗りへ別々に
// 手写しすると、足し忘れで「保存しても効かない」「表示中の印が付かない」がすぐ起きる。
// ゲームはテーブル 1 枚だけを書き、3 つの形はここが導出する。
pub mod DocTable {

    /// この行がどの読み直しに載るか。Both が既定。
    pub enum ReloadOn with Eq, ToString {
        case Both        // 保存即反映(watchFile)と F1 の一括の両方
        case Watch       // 保存即反映だけ
        case ReloadAll   // F1 の一括だけ
    }

    /// テーブルの 1 行。docId は project.json の editor 宣言 id(ActiveDocs のキー)。
    /// None の行は監視・リロードはするが Studio には名乗らない。
    ///
    /// 後ろ 2 列は「3 つの形のどれに載るか」。既定(両方に載る・常に名乗る)でよければ
    /// row で作り、外れる行にだけ withoutWatch / withoutReloadAll / withActiveWhen を被せる。
    pub type alias Entry[w] = { docId = Option[String], path = String,
                                reload = w -> w \ {Fs.FileRead},
                                reloadOn = ReloadOn, activeWhen = w -> Bool }

    /// 既定の 1 行 — 保存即反映にも F1 にも載り、常に表示中を名乗る。
    pub def row(docId: String, path: String, reload: w -> w \ {Fs.FileRead}): Entry[w] =
        { docId = Some(docId), path = path, reload = reload,
          reloadOn = ReloadOn.Both, activeWhen = _ -> true }

    /// 名乗らない 1 行 — 監視も F1 もするが Studio の「表示中」には出さない。
    /// この行に withActiveWhen を被せても何も起きない(docId が無い行は名乗りに出ない)。
    pub def unnamedRow(path: String, reload: w -> w \ {Fs.FileRead}): Entry[w] =
        { docId = None, path = path, reload = reload,
          reloadOn = ReloadOn.Both, activeWhen = _ -> true }

    /// 保存を検知しても読み直さない。読み直すと今の表示が壊れる Doc に使う
    /// (UiSpec.reloadAllWithReport はホバー・カーソル・文字送りを捨てる)。
    /// 名乗り(表示中)には出続ける。
    pub def withoutWatch(e: Entry[w]): Entry[w] = { reloadOn = ReloadOn.ReloadAll | e }

    /// F1 の一括では読み直さない。別の行の読み直しが巻き添えで作り直す Doc に使う
    /// (一括で二重に読むと同じ物を数回読みに行く)。名乗り(表示中)には出続ける。
    pub def withoutReloadAll(e: Entry[w]): Entry[w] = { reloadOn = ReloadOn.Watch | e }

    /// 表示中を名乗る条件。場面によって画面から消える Doc に使う
    /// (何でも「表示中」では印の意味が死ぬ)。読み直しの 2 面には効かない。
    pub def withActiveWhen(pred: w -> Bool, e: Entry[w]): Entry[w] = { activeWhen = pred | e }

    /// App.game の reloads(保存即反映の watchFile)へ渡す形。
    /// ReloadAll(F1 だけ)の行は出ない。
    pub def reloads(rows: List[Entry[w]]): List[(String, w -> w \ {Fs.FileRead})] =
        rows |> List.filter(r -> r#reloadOn != ReloadOn.ReloadAll)
             |> List.map(r -> (r#path, r#reload))

    /// テーブルの並び順に Doc を読み直す(App.reloadOn の一括リロードへ渡す形)。
    /// Watch(保存即反映だけ)の行は出ない。導出 Doc(他の Doc の値から作り直す物)は、
    /// 依存先より後ろの行に置くこと。
    pub def reloadAll(rows: List[Entry[w]], world: w): w \ Fs.FileRead =
        rows |> List.filter(r -> r#reloadOn != ReloadOn.Watch)
             |> List.foldLeft((acc, r) -> { let f = r#reload; f(acc) }, world)

    /// ActiveDocs.step へ渡す形(id → パスの列)。いま world で activeWhen を満たす行のうち
    /// docId を持つ物だけが出る。同じ id の行は、行が離れていても最初に現れた位置へ
    /// テーブルの並びのまま束ねる。
    /// 毎フレーム呼ばれる経路なので 1 巡で組む(id ごとの総当たりにしない)。
    pub def activeDocs(rows: List[Entry[w]], world: w): List[(String, List[String])] =
        let add = (acc, r) -> {
            let (order, byId) = acc;
            let shown = { let p = r#activeWhen; p(world) };
            match (r#docId, shown) {
                case (Some(id), true) =>
                    let prev = Map.get(id, byId) |> Option.getWithDefault(Nil);
                    (if (List.isEmpty(prev)) id :: order else order,
                     Map.insert(id, r#path :: prev, byId))
                case _ => acc
            }
        };
        let (order, byId) = List.foldLeft(add, (Nil, Map.empty()), rows);
        List.reverse(order) |> List.map(id ->
            (id, Map.get(id, byId) |> Option.getWithDefault(Nil) |> List.reverse))
}
