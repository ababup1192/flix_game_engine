package hooks

// hook-session-diet — 廃止。何もしない。
//
// WhyNot: 口ごと消さないのは、settings.json が copyIfAbsent で配られていて、
// 配った先のゲームに呼び出しが残っているため（口が無いとフックが毎回エラーで止まる）。
// 文脈の長さでセッションを切る判断は Claude Code 標準（自動の要約）に任せる —
// 固定のしきい値（130k）は 1M 文脈のモデルでは作業の途中で /clear を促す誤報になった。

import "io"

// RunSessionDiet は何もせず 0 を返す。
func RunSessionDiet(_ io.Writer, _ string, _ io.Reader) int {
	return 0
}
