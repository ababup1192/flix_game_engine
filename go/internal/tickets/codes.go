package tickets

// tickets stats の code の表（checkres に載せる）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flixlint/go/checklevel"
	"github.com/ababup1192/flixlint/go/checkres"
)

const (
	CodeFilled    = "tickets.filled"
	CodeRegressed = "tickets.regressed"
	CodeCause     = "tickets.cause"
)

var codes = []checkres.Code{
	{Name: CodeFilled, Level: checklevel.Advice, Metric: "filled_ratio", Unit: "ratio", Op: checkres.AtLeast,
		Rule: "tickets.json filledMin", Summary: "閉じたチケットのうち regressedBy が unknown でない割合"},
	{Name: CodeRegressed, Level: checklevel.Advice, Metric: "regressed_ratio", Unit: "ratio", Op: checkres.AtMost,
		Rule: "tickets.json regressedMax", Summary: "regressedBy の埋まったチケットのうち、前の直しが生んだ割合"},
	{Name: CodeCause, Level: checklevel.Advice, Metric: "tickets_caused", Unit: "count", Op: checkres.AtMost,
		Rule: "tickets.json causeMax", Summary: "1 つの直し（コミット・チケット）が生んだチケットの数"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
