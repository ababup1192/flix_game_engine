// ShaderAst.Entry — vertex と frag の入口を言語ごとに組む所: onlyIn をほどき、本文が辿る定義を集め、入口の置き場（emit・varying・属性・output・clipOut）を検査する。
mod ShaderAst.Entry {
    use ShaderAst.{Node, Stmt, Def, Ty, Intrinsic, Interp, Lang, Body, Definition, Statement, FragmentEntry, VertexEntry}
    use ShaderAst.{nameOf, stmtChildren, nodesInStmt, anyStmt, collectOrBug, checkOrBug, directDeps, errorsOf, invalidOrBug, fragCoord, vertexIndex}

    /// sg_clipFromGl（WGSL だけ。GL の clip の z を 0..w へ移す）。
    def clipFromGl(): Def = Def.Extern("sg_clipFromGl", Ty.Vec4, Ty.Vec4 :: Nil, Body.Outside, Body.Text(ShaderGen.Wgsl.clipFromGlSource()), Nil, false)

    /// 入口の本文 body を言語 lang の文だけにした物（onlyIn をほどく）。
    def resolveIn(lang: Lang, body: List[Stmt]): List[Stmt] = body |> List.flatMap(s -> match s {
        case Stmt.Only(l, inner)                   => if (l == lang) resolveIn(lang, inner) else Nil
        case Stmt.If(c, t, e, layout)              => Stmt.If(c, resolveIn(lang, t), resolveIn(lang, e), layout) :: Nil
        case Stmt.For(name, ty, a1, c, b1, layout) => Stmt.For(name, ty, a1, c, resolveIn(lang, b1), layout) :: Nil
        case _                                     => s :: Nil
    })

    /// 入口の本文 body を関数として見た物（検査と、本文が辿る定義を集めるため）。
    def entryAsFunction(body: List[Stmt]): Def = Def.Fn("main", Ty.Void, Nil, body)

    /// 入口の本文 body0 を言語 lang の文だけにした本文と、roots とその本文が辿って使う定義（main を除き、使う前に 1 回ずつ）。
    /// 組む時の検査と、入口の置き場の検査 placement に通す（誤りがあれば止める）。
    def entryOrBug(lang: Lang, roots: List[Def], body0: List[Stmt], placement: List[Stmt] -> List[String]): (List[Def], List[Stmt]) =
        let body = resolveIn(lang, body0);
        let main = entryAsFunction(body);
        let defs = checkOrBug(collectOrBug(lang, roots ::: directDeps(lang, main)));
        let errors = errorsOf(main) ::: helperErrors(defs) ::: placement(body);
        if (List.isEmpty(errors)) (defs, body) else invalidOrBug("ShaderAst: " + String.intercalate("; ", errors))

    /// frag の入口 e の定義と本文（entryOrBug）。
    pub def fragmentOrBug(lang: Lang, e: FragmentEntry): (List[Definition], List[Statement]) =
        let inputs = e#inputs |> List.map(v -> v#name) |> List.toSet;
        entryOrBug(lang, e#declarations, e#body, body -> fragmentPlacementErrors(body, inputs, e#writesColor))

    /// vertex の入口 e の定義と本文（entryOrBug。WGSL は sg_clipFromGl を足す）。
    pub def vertexOrBug(lang: Lang, e: VertexEntry): (List[Definition], List[Statement]) =
        let outputs = e#outputs |> List.map(v -> v#name) |> List.toSet;
        let attributes = e#attributes |> List.map(a -> a#name) |> List.toSet;
        entryOrBug(lang, (if (lang == Lang.Wgsl) clipFromGl() :: Nil else Nil) ::: e#declarations, e#body,
                   body -> vertexPlacementErrors(body, outputs, attributes))

    /// 入口が辿る関数の中で、入口の本文だけで使える物を使う誤り。
    def helperErrors(defs: List[Def]): List[String] = defs |> List.filterMap(d -> match d {
        case Def.Fn(name, _, _, fb) if List.exists(usesEntryOnly, fb) => Some("${name} が入口の本文の外で emit・frontFacing・varying・属性・output・clipOut・onlyIn を使う")
        case _                                                         => None
    })

    /// 文 s と、その中のブロックの文の全部。
    def collectStmts(s: Stmt): List[Stmt] = s :: (stmtChildren(s) |> List.flatMap(collectStmts))

    /// checks のうち真の物の文。
    def failed(checks: List[(Bool, String)]): List[String] = checks |> List.filterMap(c -> if (fst(c)) Some(snd(c)) else None)

    /// found のうち names に無い名前を , でつないだ字（無ければ空の字）。
    def unknownNames(names: Set[String], found: List[String]): String =
        found |> List.filter(n -> not Set.memberOf(n, names)) |> List.distinct |> String.intercalate(", ")

    def varyingName(n: Node): Option[String] = match n {
        case Node.Varying(name, _, _) => Some(name)
        case _                        => None
    }

    def attributeName(n: Node): Option[String] = match n {
        case Node.Attribute(name, _) => Some(name)
        case _                       => None
    }

    def isEmitEnd(s: Stmt): Bool = match s {
        case Stmt.Emit(_, false) => true
        case _                   => false
    }

    def isClipOut(s: Stmt): Bool = match s {
        case Stmt.ClipOut(_) => true
        case _               => false
    }

    def isAffineOutput(s: Stmt): Bool = match s {
        case Stmt.Output(_, _, Interp.Affine, _) => true
        case _                                   => false
    }

    def outputName(s: Stmt): Option[String] = match s {
        case Stmt.Output(name, _, _, _) => Some(name)
        case _                          => None
    }

    /// frag の入口の本文の置き場の誤り（emit は本文の最後だけ・if と for の中に emit を置かない・色を出さない入口は emit しない・
    /// 読む varying は inputs にある・属性・output・clipOut を使わない）。
    def fragmentPlacementErrors(body: List[Stmt], inputs: Set[String], writesColor: Bool): List[String] =
        let all = body |> List.flatMap(collectStmts);
        let nodes = body |> List.flatMap(nodesInStmt);
        let unknown = unknownNames(inputs, List.filterMap(varyingName, nodes));
        failed((List.exists(isEmitEnd, List.take(List.length(body) - 1, body)), "emit が本文の最後の文でない") ::
               (List.count(isEmitEnd, all) > List.count(isEmitEnd, body), "emit が if・for の中にある（emitAndReturn を使う）") ::
               (not writesColor and List.exists(isEmit, all), "色を出さない frag が emit する") ::
               (unknown != "", "frag が inputs に無い varying を読む: " + unknown) ::
               (List.exists(isVertexOnly, all) or List.exists(n -> Option.nonEmpty(attributeName(n)), nodes), "frag が属性・output・clipOut を使う") :: Nil)

    /// vertex の入口の本文の置き場の誤り（clipOut は本文のif・for の外に 1 回だけ・Affine の varying は clipOut の後に書く・書く varying は outputs にある・
    /// 読む属性は attributes にある・emit・frontFacing・varying の読みを使わない）。
    def vertexPlacementErrors(body: List[Stmt], outputs: Set[String], attributes: Set[String]): List[String] =
        let all = body |> List.flatMap(collectStmts);
        let nodes = body |> List.flatMap(nodesInStmt);
        let unknownOutputs = unknownNames(outputs, List.filterMap(outputName, all));
        let unknownAttributes = unknownNames(attributes, List.filterMap(attributeName, nodes));
        failed((List.count(isClipOut, body) != 1 or List.count(isClipOut, all) != 1, "clipOut が本文のif・for の外に 1 回だけでない") ::
               (List.takeWhile(s -> not isClipOut(s), body) |> List.flatMap(collectStmts) |> List.exists(isAffineOutput), "Affine の varying を clipOut の前に書く") ::
               (unknownOutputs != "", "vertex が outputs に無い varying を書く: " + unknownOutputs) ::
               (unknownAttributes != "", "vertex が attributes に無い属性を読む: " + unknownAttributes) ::
               (List.exists(isEmit, all) or List.exists(isFragmentOnlyNode, nodes), "vertex が emit・frontFacing・varying を使う") :: Nil)

    /// 文 s（中のブロックの文も）に p が真の文があるか。
    def containsStmt(p: Stmt -> Bool, s: Stmt): Bool = p(s) or List.exists(containsStmt(p), stmtChildren(s))

    def isFragmentOnlyNode(n: Node): Bool = match n {
        case Node.Intrinsic(Intrinsic.FrontFacing, _) => true
        case Node.Varying(_, _, _)                    => true
        case _                                        => false
    }

    def isEmit(s: Stmt): Bool = match s {
        case Stmt.Emit(_, _) => true
        case _               => false
    }

    def isVertexOnly(s: Stmt): Bool = match s {
        case Stmt.Output(_, _, _, _) => true
        case Stmt.ClipOut(_)         => true
        case _                       => false
    }

    def isOnly(s: Stmt): Bool = match s {
        case Stmt.Only(_, _) => true
        case _               => false
    }

    /// 文 s が入口の本文の中だけで使える物（emit・frontFacing・varying・属性・output・clipOut・onlyIn）を使うか。
    def usesEntryOnly(s: Stmt): Bool =
        containsStmt(t -> isEmit(t) or isVertexOnly(t) or isOnly(t), s) or anyStmt(n -> isFragmentOnlyNode(n) or Option.nonEmpty(attributeName(n)), s)

    /// 入口が辿る定義 defs が画素の位置（r3d_fragCoord）を読むか。
    pub def readsFragCoord(defs: List[Definition]): Bool = List.exists(d -> nameOf(d) == nameOf(fragCoord()), defs)

    /// 入口が辿る定義 defs が頂点の番号（r3d_vertexIndex）を読むか。
    pub def readsVertexIndex(defs: List[Definition]): Bool = List.exists(d -> nameOf(d) == nameOf(vertexIndex()), defs)

    /// 入口の本文 body か、それが辿る関数 defs が四角の角（quadCorner）を読むか。
    pub def readsQuadCorner(defs: List[Definition], body: List[Statement]): Bool =
        let isCorner = (n: Node) -> match n {
            case Node.Intrinsic(Intrinsic.QuadCorner, _) => true
            case _                                       => false
        };
        let inFn = (d: Def) -> match d {
            case Def.Fn(_, _, _, fb) => List.exists(anyStmt(isCorner), fb)
            case _                   => false
        };
        List.exists(anyStmt(isCorner), body) or List.exists(inFn, defs)

    /// 入口の本文が表裏（frontFacing）を読むか（入口が辿る関数の中では使えないので本文だけを見る）。
    pub def readsFrontFacing(body: List[Statement]): Bool =
        body |> List.exists(anyStmt(n -> n == Node.Intrinsic(Intrinsic.FrontFacing, Ty.Bool)))
}
