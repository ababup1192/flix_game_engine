/// make refactor-smoke の規則: flixlint が engine の新しい型を使うゲームで facts を作り、規則を流し切れるかだけを見る。
mod SmokeLint {
    use Flixlint.{RuleSet, customRule, allowIn}
    use Flixlint.Facts.Facts
    use Flixlint.Violation.Violation
    use Flixlint.Names.Fn

    pub def rules(): RuleSet = Flixlint.ruleSet(List#{
        Flixlint.customs(List#{
            customRule({ id = "smoke-shift", check = shiftReaders })
                |> allowIn(Fn.Shot_shiftY, "lensShift を読む def（facts に欄の読みが出た目印）")
        })
    })

    /// lensShift を読む def を 1 つずつ出す（allowIn で消えれば、Names に名前が出て facts が欄の型を解けている）。
    def shiftReaders(facts: Facts): List[Violation] =
        Flixlint.Facts.defs(facts)
            |> List.filter(d -> d#fn == Fn.Shot_shiftY)
            |> List.map(d -> Flixlint.Violation.atDef(facts, "smoke-shift", d, "reads lensShift", "allowIn で消える"))
}
