package refactor

// refactor の code の表（checkres に載せる）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const (
	CodeUsages          = "refactor.usages"
	CodeUnused          = "refactor.unused"
	CodeRefs            = "refactor.refs"
	CodeMatchSites      = "refactor.match-sites"
	CodeFieldSites      = "refactor.field-sites"
	CodeExpand          = "refactor.expand-wildcard"
	CodeRemoveDead      = "refactor.remove-dead"
	CodeAccessor        = "refactor.field-to-accessor"
	CodeRemoveField     = "refactor.remove-field"
	CodeFixConstruction = "refactor.fix-construction"
	CodeAddField        = "refactor.add-field"
	CodeCaseShape       = "refactor.change-case-shape"
	CodeSignature       = "refactor.change-signature"
	CodeMove            = "refactor.move"
	CodePrivate         = "refactor.make-private"
	CodeRemoveParam     = "refactor.remove-param"
	CodeRemoveUse       = "refactor.remove-use"
)

var codes = []checkres.Code{
	{Name: CodeUsages, Level: checklevel.Lint, Metric: "usages", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "def・enum・case・型 alias・record の欄の使われ所の数（呼び出し・参照・読み・書き・組み立て・パターン・型の注記・use）"},
	{Name: CodeUnused, Level: checklevel.Lint, Metric: "unused", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "外から使われない pub の def（参照 0・テストからだけ・同じ mod の中だけ）と、使っていない use の数"},
	{Name: CodeRefs, Level: checklevel.Lint, Metric: "refs", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "def・enum・case の参照の数（宣言は数えない）"},
	{Name: CodeMatchSites, Level: checklevel.Lint, Metric: "match_sites", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "enum（か case）への match の数。--catch-all なら `_`・変数の腕を持つ物だけ"},
	{Name: CodeFieldSites, Level: checklevel.Lint, Metric: "field_sites", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（欄の歯止めは --outside <口の mod> --max 0）", Summary: "record の欄の直の読み書きの数（受け手の型 alias で絞る）"},
	{Name: CodeExpand, Level: checklevel.Lint, Metric: "catch_all_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（書き出せない腕は fix）", Summary: "enum への match の `case _` を残りの case に書き出した後に、人へ回した腕の数"},
	{Name: CodeRemoveDead, Level: checklevel.Lint, Metric: "dead_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（決められない def は fix）", Summary: "テストからだけ・どこからも参照されない pub の def を消した後に、人へ回した数"},
	{Name: CodeAccessor, Level: checklevel.Lint, Metric: "field_sites_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（受け手の型が決まらない・読めない式・型の違う口は fix）", Summary: "record の欄の直の読み書きを口（読み・書き）へ替えた後に、人へ回した数"},
	{Name: CodeRemoveField, Level: checklevel.Lint, Metric: "construction_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（直の読み書きが残れば止める・欄の組が同じ別の型の組み立ては fix）", Summary: "record の型から欄を消し、組み立てからも消した後に、人へ回した数（止めた時は残っている直の読み書きの数）"},
	{Name: CodeFixConstruction, Level: checklevel.Lint, Metric: "construction_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（欄の組が同じ別の型の組み立ては fix）", Summary: "record を組み立てる式の欄を型に合わせた（足した・消した）後に、人へ回した数"},
	{Name: CodeAddField, Level: checklevel.Lint, Metric: "construction_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（欄の組が同じ別の型の組み立ては fix）", Summary: "record の型 alias に欄を足し、組み立てる式にも値を足した後に、人へ回した数"},
	{Name: CodeCaseShape, Level: checklevel.Lint, Metric: "case_sites_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（case を関数として渡す所・消す欄を使う本体は fix。fix があれば書かない）", Summary: "enum の case の欄を足した・消した後に、宣言と形の合わない作る所・当てる所として人へ回した数"},
	{Name: CodeSignature, Level: checklevel.Lint, Metric: "call_sites_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（関数として渡す所・2 回使う引数に式が渡る所・消える引数を使う本体は fix。fix があれば書かない）", Summary: "def の引数の並びを替えた後に、新しい並びで呼べない所として人へ回した数"},
	{Name: CodeMove, Level: checklevel.Lint, Metric: "move_sites_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（元の mod の非 pub の物を使う・移す非 pub の物を外が使う・読めない use は fix。fix があれば書かない）", Summary: "def・型 alias を別の mod へ移した後に、新しい mod を指せない所として人へ回した数"},
	{Name: CodePrivate, Level: checklevel.Lint, Metric: "private_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（外の使い手がいる・どこからも参照されない・名前が入口のファイル（Makefile・json など）に出る・ライブラリの def は fix）", Summary: "外の mod から使われない pub の def から pub を外した後に、人へ回した数"},
	{Name: CodeRemoveParam, Level: checklevel.Lint, Metric: "call_sites_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（本体が使う引数・関数として渡す所は fix。fix があれば書かない）", Summary: "def の使っていない引数を宣言と呼ぶ所から消した後に、人へ回した数"},
	{Name: CodeRemoveUse, Level: checklevel.Lint, Metric: "unused_use_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（同じ行に別の物がある・名前が見つからない use は fix）", Summary: "使っていない use・import（flixlint の unused-use と同じ判定）を消した後に、人へ回した数"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
