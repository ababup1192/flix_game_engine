package stateshape

// state-shape の code の表（checkres に載せる）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const (
	CodeBoolFields = "state-shape.bool-fields"
	CodeOptionBool = "state-shape.option-bool"
	CodeCatchAll   = "state-shape.catch-all"
	CodeViewEffect = "state-shape.view-effect"
)

var codes = []checkres.Code{
	{Name: CodeBoolFields, Level: checklevel.Gate, Metric: "bool_fields", Unit: "count", Op: checkres.AtMost,
		Rule: "state-shape.json boolFieldMin・state-shape.local.json boolFieldLimits", Summary: "状態の record の Bool の欄の数（今の数までは歯止めの表で許し、増えたら止める）"},
	{Name: CodeOptionBool, Level: checklevel.Gate, Metric: "option_bool", Unit: "count", Op: checkres.AtMost,
		Rule: "state-shape.local.json exempt", Summary: "Option[Bool]（3 つの状態を名前の無い型で持つ）"},
	{Name: CodeCatchAll, Level: checklevel.Gate, Metric: "catch_all_arms", Unit: "count", Op: checkres.AtMost,
		Rule: "state-shape.local.json stateEnums", Summary: "名指しした状態の enum への match の `case _ =>`（case を足しても型検査が知らせない）"},
	{Name: CodeViewEffect, Level: checklevel.Gate, Metric: "concrete_effects", Unit: "count", Op: checkres.AtMost,
		Rule: "state-shape.json viewFiles", Summary: "View の def が決まった効果（IO など）を持つ"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
