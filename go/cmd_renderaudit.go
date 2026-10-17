package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/renderaudit"
)

func init() {
	// WhyNot: engineOnly にしないのは、表を書くのが配った先のゲームの描き出しだから。
	register("text-audit", "描き出した場面の字の被り・はみ出しの表 (TSV) を、許す物の表を除いて裁く", cmdTextAudit)
	register("z-audit", "描き出した場面の描画物の z が描いてよい層の外に出た表 (TSV) を裁く", cmdZAudit)
}

func renderAuditOptions(rest []string) renderaudit.Options {
	root, rest := declRootFlag(rest)
	table, rest, _ := declValueFlag(rest, "--tsv")
	allow, _, _ := declValueFlag(rest, "--allow")
	return renderaudit.Options{Root: root, Table: table, Allow: allow}
}

func cmdTextAudit(out, errOut *strings.Builder, rest []string, _ bool) int {
	code, err := renderaudit.RunText(out, renderAuditOptions(rest))
	return orAbort(errOut, code, err)
}

func cmdZAudit(out, errOut *strings.Builder, rest []string, _ bool) int {
	code, err := renderaudit.RunZ(out, renderAuditOptions(rest))
	return orAbort(errOut, code, err)
}
