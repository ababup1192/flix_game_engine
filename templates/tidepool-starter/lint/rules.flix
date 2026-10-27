/// このゲームの決まりのうち、型と名前解決が要る物（flixlint の規則）。流すのは make lint-flixlint（make lint も束ねる）。
///
/// 層と、呼んでよい向き（矢印の向きだけ。逆は止める）:
///
///     App の境目（Main・Game・E2e・Starts・src/render/）── どれを呼んでもよい
///        ↓
///     入力の境目（Controls）── キーと押し所から規則を呼ぶ。押し所を選ぶのに View の木も読む
///        ↓
///     View（src/View*.flix・src/*View.flix と viewFiles）── 描くだけ。World は入口（viewEntries）だけが受け、
///        ↓                                              中の部品は入口が組んだ値（View.In など）を受ける
///     規則の側（World・Doc・形の表…）── View と Controls を呼ばない
///
/// 加えて src/ のファイルどうしは輪を作らない（A が B を使い、B が A を使う形。型を使うのも数える）。
/// 2 つのファイルが同じ型を要るなら、その型を下の層のファイル（どちらも使ってよい側）へ移す。
/// App の境目どうし（Game が E2e の flow の語彙を読み、E2e の入口が Game の App を流す）だけは輪に数えない。
///
/// テストの形（test-calc・test-branch）は quality-assurance スキルの「期待値は Doc の既定値か直の値で書く」を機械で止める物。
///
/// 名前は flixlint が作る Flixlint.Names から取るので、消えた def を指す allowIn はコンパイルで止まる。
/// 規則の本文はテンプレートどうしで同じ。ゲームごとに変えるのは「このゲームの表」の節だけ。
mod GameLint {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Facts.{Facts, Def}
    use Flixlint.Violation.Violation
    use Flixlint.Names.{Fn, Type}

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "view-no-world", check = viewNoWorld })
                |> allowIn(Fn.View_frame, "描く入口（App の view が World を渡す）。View.inputOf で In を組んで部品へ渡す")
                |> allowIn(Fn.View_inputOf, "World から View の In を組む口（View の中で World を読むのは入口とここだけ。Controls も押し所を選ぶのに呼ぶ）"),
            customRule({ id = "rule-to-view", check = ruleToView }),
            customRule({ id = "module-cycle", check = moduleCycle }),
            customRule({ id = "pub-no-caller", check = pubNoCaller })
                |> allowIn(Fn.E2e_play, "Makefile の口（make flow）が名前で呼ぶ入口")
                |> allowIn(Fn.E2e_vocab, "Makefile の口（make flow-vocab）と bin/headless-run が名前で呼ぶ入口")
                |> allowIn(Fn.E2e_jobs, "描き出しの常駐（HEADLESS_RESIDENT=1）が名前で呼ぶ入口の束")
                |> allowIn(Fn.SceneRender_all, "Makefile の口（make render-all）が名前で呼ぶ入口")
                |> allowIn(Fn.SceneRender_one, "Makefile の口（make render）が名前で呼ぶ入口")
                |> allowIn(Fn.SceneRender_jobs, "描き出しの常駐（HEADLESS_RESIDENT=1）が名前で呼ぶ入口の束")
                |> allowIn(Fn.Palette_write, "Makefile の口（make palette）が flix run --entrypoint で呼ぶ入口")
                |> allowIn(Fn.Solve_main, "Makefile の口（make solve）が名前で呼ぶ入口")
                |> allowIn(Fn.VideoAuditEntries_runAll, "動画の見回りが名前で呼ぶ入口の束（make video-entries の生成物）"),
            customRule({ id = "test-calc", check = testCalc }),
            customRule({ id = "test-branch", check = testBranch })
                |> allowIn(Fn.Fixtures_board, "テストの盤の格子の書き誤りは bug! で止める（値で分けない）")
                |> allowIn(Fn.TestTrace_testForecastMatchesWhatWaitingDoes, "性質テストの決まり（待ったフレームならどの拍でも崩れない式）。崩れた拍だけ説明を返す")
                |> allowIn(Fn.TestTrace_testAtMostOneMoveAndOneTideSoundPerFrame, "性質テストの決まり（どのフレームでも音の数が崩れない式）。崩れた拍だけ説明を返す")
        })
    })

    // ── このゲームの表 ──

    /// src/View*.flix・src/*View.flix のほかに View の層に数えるファイル（描く部品だけを持つファイル）。
    def viewFiles(): Set[String] = Set#{}

    /// 入力の境目のファイル。
    def inputFiles(): Set[String] = Set#{"src/Controls.flix"}

    /// App の境目のファイル（src/render/ の下はいつも App の境目）。
    def appFiles(): Set[String] = Set#{"src/Main.flix", "src/Game.flix", "src/E2e.flix", "src/Starts.flix", "src/Solve.flix"}

    // ── 層 ──

    def isViewFile(file: String): Bool =
        Set.memberOf(file, viewFiles())
            or (String.startsWith(prefix = "src/", file) and not String.startsWith(prefix = "src/render/", file)
                and (String.startsWith(prefix = "src/View", file) or String.endsWith(suffix = "View.flix", file)))

    def isInputBoundary(file: String): Bool = Set.memberOf(file, inputFiles())

    def isAppBoundary(file: String): Bool =
        Set.memberOf(file, appFiles()) or String.startsWith(prefix = "src/render/", file)

    def isRuleSide(file: String): Bool =
        String.startsWith(prefix = "src/", file) and not isViewFile(file) and not isInputBoundary(file) and not isAppBoundary(file)

    /// View の層の def は World.World を受けない（引数の型のどこか。record・Option・エイリアスの中も）。
    /// World を受けるのは App が呼ぶ入口と、World から In を組む口だけ（allowIn に理由）。
    def viewNoWorld(facts: Facts): List[Violation] =
        Flixlint.Facts.defs(facts)
            |> List.filter(d -> isViewFile(d#file))
            |> List.filter(d -> Flixlint.Facts.argTypesDeepOf(facts, d#fn) |> List.exists(a -> a#tycon == Type.World_World))
            |> List.map(d -> Flixlint.Violation.atDef(facts, "view-no-world", d, "takes World.World",
                "View の部品は World を丸ごと受けない。入口（View.frame・hud）が View.inputOf で組んだ In か、要る値だけを受ける"))

    /// 逆向きの呼び出しを止める: 規則の側 → View・規則の側 → 入力の境目・View → 入力の境目。
    def ruleToView(facts: Facts): List[Violation] =
        Flixlint.Facts.calls(facts) |> List.filterMap(c ->
            match (Flixlint.Facts.defOf(facts, c#caller), Flixlint.Facts.defOf(facts, c#callee)) {
                case (Some(caller), Some(callee)) if isRuleSide(caller#file) and isViewFile(callee#file) =>
                    Some(Flixlint.Violation.atCall(facts, "rule-to-view", c,
                        "規則の側は View を呼ばない。規則も View も要る値（大きさ・並び・z の順）は規則の側のファイルへ移し、View がそれを呼ぶ"))
                case (Some(caller), Some(callee)) if isRuleSide(caller#file) and isInputBoundary(callee#file) =>
                    Some(Flixlint.Violation.atCall(facts, "rule-to-view", c,
                        "規則の側は入力の境目（Controls）を呼ばない。Doc を読む・入力を流して場面を作る所は App の境目（Game・Starts）に置く"))
                case (Some(caller), Some(callee)) if isViewFile(caller#file) and isInputBoundary(callee#file) =>
                    Some(Flixlint.Violation.atCall(facts, "rule-to-view", c,
                        "View は入力の境目（Controls）を呼ばない。入力が決めた値は World に置き、View は In で受ける"))
                case _ => None
            })

    /// src/ のファイルどうしの輪。A の def が B の def を呼ぶか、A の def の引数・戻り値や A の型の中身に B の型が出たら A → B。
    /// A → B で、B から辿って A へ戻れる所を 1 つずつ出す（同じ向きの 2 つ目からは出さない）。
    def moduleCycle(facts: Facts): List[Violation] =
        let inSrc = f -> String.startsWith(prefix = "src/", f);
        let typeFiles = Flixlint.Facts.typeAliases(facts) |> List.map(a -> (Flixlint.Facts.typeName(facts, a#typeAlias), a#file))
            |> List.append(Flixlint.Facts.enums(facts) |> List.map(e -> (Flixlint.Facts.enumName(facts, e#ofEnum), e#file)))
            |> List.toMap;
        let fileOfType = t -> Map.get(Flixlint.Facts.typeName(facts, t), typeFiles);
        let byCall = Flixlint.Facts.calls(facts) |> List.filterMap(c ->
            match (Flixlint.Facts.defOf(facts, c#caller), Flixlint.Facts.defOf(facts, c#callee)) {
                case (Some(a), Some(b)) => Some((a#file, b#file, a#fn, c#line))
                case _ => None
            });
        let byDefType = Flixlint.Facts.defs(facts) |> List.flatMap(d ->
            (Flixlint.Facts.argTypesDeepOf(facts, d#fn) |> List.map(a -> a#tycon))
                |> List.append(Set.toList(Flixlint.Facts.retTypesDeepOf(facts, d#fn)))
                |> List.filterMap(t -> fileOfType(t) |> Option.map(f -> (d#file, f, d#fn, d#line))));
        // WhyNot: App の境目どうしを数えない。flow の入口（E2e.play）は Makefile が名前で呼ぶので E2e に置くしかなく、
        // 同じ App を実機と flow で組む（Game.app が E2e の語彙を足す）と、どちらへ寄せても輪が残る。
        let counted = (a, b) -> inSrc(a) and inSrc(b) and a != b and not (isAppBoundary(a) and isAppBoundary(b));
        let edges = List.append(byCall, byDefType) |> List.filter(e -> { let (a, b, _, _) = e; counted(a, b) });
        let declared = typeEdges(facts, fileOfType) |> List.filter(e -> { let (a, b) = e; counted(a, b) });
        let adj = List.append(edges |> List.map(e -> { let (a, b, _, _) = e; (a, b) }), declared)
            |> List.foldLeft((m, e) -> { let (a, b) = e; Map.insertWith(Set.union, a, Set#{b}, m) }, Map.empty());
        let reach = a -> reachFrom(adj, Set.empty(), a :: Nil);
        let firstUse = edges |> List.foldLeft((m, e) -> { let (a, b, _, _) = e; if (Map.memberOf((a, b), m)) m else Map.insert((a, b), e, m) }, Map.empty());
        Map.toList(firstUse) |> List.filterMap(p -> {
            let ((a, b), (_, _, fn, line)) = p;
            if (Set.memberOf(a, reach(b)))
                Some(Flixlint.Violation.inBody(facts, "module-cycle", fn, line, "${a} uses ${b}, and ${b} leads back to ${a}",
                    "依存は一方通行にする。両方が要る型・値は下の層のファイル（どちらからも使ってよい側）へ移し、下の層から上を呼ばない"))
            else None
        })

    /// 型の宣言の中身の向き: enum の case と、エイリアスの中に別のファイルの型が出る所。
    def typeEdges(facts: Facts, fileOfType: Type -> Option[String]): List[(String, String)] =
        let enumFiles = Flixlint.Facts.enums(facts) |> List.map(e -> (e#ofEnum, e#file)) |> List.toMap;
        let fromCases = Flixlint.Facts.caseTypesDeep(facts) |> List.filterMap(c ->
            match (Map.get(c#ofEnum, enumFiles), fileOfType(c#tycon)) {
                case (Some(a), Some(b)) => Some((a, b))
                case _ => None
            });
        let fromAliases = Flixlint.Facts.typeAliases(facts) |> List.flatMap(a ->
            Set.toList(Flixlint.Facts.aliasTypesAllOf(facts, a#typeAlias)) |> List.filterMap(t -> fileOfType(t) |> Option.map(b -> (a#file, b))));
        List.append(fromCases, fromAliases)

    /// todo から辿れるファイル。
    def reachFrom(adj: Map[String, Set[String]], seen: Set[String], todo: List[String]): Set[String] = match todo {
        case Nil => seen
        case x :: rest =>
            if (Set.memberOf(x, seen)) reachFrom(adj, seen, rest)
            else reachFrom(adj, Set.insert(x, seen), List.append(Set.toList(Map.getWithDefault(x, Set.empty(), adj)), rest))
    }

    /// src/ の pub な def のうち、定義元の mod の外（src/ と test/ のどこか）からは呼ばれない物（名前で渡すのも呼び出しに数える）。
    /// src/Main.flix（プログラムの入口 main）は見ない。
    def pubNoCaller(facts: Facts): List[Violation] =
        let fromOutside = Flixlint.Facts.calls(facts) |> List.filter(c ->
            match (Flixlint.Facts.defOf(facts, c#caller), Flixlint.Facts.defOf(facts, c#callee)) {
                case (Some(caller), Some(callee)) => caller#module != callee#module
                case _                            => false
            }) |> List.map(c -> c#callee) |> List.toSet;
        Flixlint.Facts.defs(facts)
            |> List.filter(d -> d#isPub and String.startsWith(prefix = "src/", d#file) and d#file != "src/Main.flix"
                and not Set.memberOf(d#fn, fromOutside))
            |> List.map(d -> Flixlint.Violation.atDef(facts, "pub-no-caller", d, "has no caller outside its module",
                "外の mod から呼ばれない pub は pub を外すか消す（bin/fge refactor make-private・remove-dead）。Makefile や常駐が名前で呼ぶ入口だけ allowIn に理由を書く"))

    /// test/ のテストの本体と、呼ぶ所が 1 か所だけの test/ の手伝いの def で、値を加工する List の関数を呼ぶ所。
    def testCalc(facts: Facts): List[Violation] =
        let callSites = Flixlint.Facts.calls(facts) |> List.foldLeft((m, c) -> Map.insertWith((a, b) -> a + b, c#callee, 1, m), Map.empty());
        let sharedHelper = fn -> Map.getWithDefault(fn, 0, callSites) >= 2;
        let shaping = Set#{Fn.List_map, Fn.List_flatMap, Fn.List_filter, Fn.List_filterMap, Fn.List_count, Fn.List_sum,
                           Fn.List_sumWith, Fn.List_fold, Fn.List_foldLeft, Fn.List_foldRight};
        Flixlint.Facts.calls(facts)
            |> List.filter(c -> Set.memberOf(c#callee, shaping) and inTest(facts, c#caller) and not sharedHelper(c#caller))
            |> List.map(c -> Flixlint.Violation.atCall(facts, "test-calc", c,
                "テストの中で値を加工しない（List.map・sum・fold・filter・count など）。期待値は Doc の既定値か直の値で書き、本体の口が返す値をそのまま assertEq で比べる（quality-assurance）。要る形を作る口が本体に無ければ本体に足す"))

    /// test/ の中の分岐: if・match と、Some と None・Ok と Err を分ける getWithDefault・fold。
    def testBranch(facts: Facts): List[Violation] =
        let reason = "テストで分けない。Option・Result は Some(…)・Ok(…) のまま assertEq で比べ、作る値は本体の型と関数で 1 通りに決める（quality-assurance）";
        let splitting = Set#{Fn.Option_getWithDefault, Fn.Option_fold, Fn.Result_getWithDefault};
        let byBranch = Flixlint.Facts.branches(facts)
            |> List.filter(b -> inTest(facts, b#fn))
            |> List.map(b -> Flixlint.Violation.inBody(facts, "test-branch", b#fn, b#line, "branches with ${b#kind}", reason));
        let byCall = Flixlint.Facts.calls(facts)
            |> List.filter(c -> Set.memberOf(c#callee, splitting) and inTest(facts, c#caller))
            |> List.map(c -> Flixlint.Violation.atCall(facts, "test-branch", c, reason));
        byBranch ::: byCall

    def inTest(facts: Facts, fn: Fn): Bool =
        Flixlint.Facts.defOf(facts, fn) |> Option.exists(d -> String.startsWith(prefix = "test/", d#file))
}
