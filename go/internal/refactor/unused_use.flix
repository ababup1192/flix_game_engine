/// bin/fge refactor が使っていない use・import を探すのに流す flixlint の規則（Go に埋め込み、build/refactor/ に書いて
/// 流す。ゲームの lint/rules.flix の unused-use と同じ判定: flixlint の Flixlint.Flix.uses・namesUsed・isUnused）。
/// 手で直さない（go/internal/refactor/unused_use.flix が元）。
mod RefactorUnusedUse {
    use Flixlint.{RuleSet, customRule}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{ customRule({ id = "unused-use", check = unusedUse }) })
    })

    def unusedUse(facts: Facts): List[Violation] =
        let ast = Flixlint.Facts.ast(facts);
        let used = Flixlint.Flix.namesUsed(ast);
        Flixlint.Flix.uses(ast) |> List.filter(Flixlint.Flix.isUnused(used))
            |> List.map(u -> Flixlint.Flix.violation(ast, "unused-use", u#node, u#line, "brings in ${u#name}, which the module never uses",
                "bin/fge refactor remove-use"))
}
