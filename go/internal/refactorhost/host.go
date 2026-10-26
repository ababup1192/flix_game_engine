// Package refactorhost は bin/fge refactor が flixlint の道具（github.com/ababup1192/flixlint/go/refactor）に
// 差し込むエンジンの決まり: engine の置き場（status.FindEngineDir）・文書の名指し（doc-refs の規約）・呼び方。
//
// WhyNot: 道具の本体をエンジンに置かない。探す・書き換える道具は Flix のプロジェクトならどれにでも使う物で、
// flixlint に flix-search・flix-refactor として置き、エンジンはこの口で自分の決まりだけを足す。
package refactorhost

import (
	"os"
	"path/filepath"

	"github.com/ababup1192/flix_game_engine/go/internal/docrefs"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
	"github.com/ababup1192/flixlint/go/refactor"
)

// Hooks は bin/fge refactor の口。
func Hooks() refactor.HostHooks {
	return refactor.HostHooks{
		EngineDir: func(root, marker string) string {
			dir, _ := status.FindEngineDir(root, marker)
			return dir
		},
		DocMentions: DocMentions,
		DocCheck:    "bin/fge doc-refs",
		Command:     "bin/fge refactor",
	}
}

// DocMentions は doc-refs の規約（根の物、無ければ engine の物）で、文書（.md と .flix のコメント）が名指す名前を拾う。
// 予定の印・engine の名前は数えない（doc-refs が止めない物）。
func DocMentions(root, engine string) ([]refactor.DocMention, string, bool) {
	rules, err := docrefs.LoadRules(root)
	at := root
	if err != nil && engine != "" {
		rules, err = docrefs.LoadRules(engine)
		at = engine
	}
	if err != nil {
		return nil, "", false
	}
	var out []refactor.DocMention
	for _, f := range append(rules.Docs(root), rules.FlixDocs(root)...) {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(f)))
		if err != nil {
			continue
		}
		for _, r := range rules.Refs(f, string(body)) {
			if r.Kind == docrefs.RefName && !r.Planned && !r.Engine {
				out = append(out, refactor.DocMention{Key: r.Key(), File: f, Line: r.Line})
			}
		}
	}
	return out, at, true
}
