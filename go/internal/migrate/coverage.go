package migrate

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/yarn"
)

// coverage は新しい版の台本の命令の行のうち、どの flow も通らなかった物を並べる（10.2 の (a)）。
// 台本は tape.json の yarn が指すファイルと同じフォルダの .yarn の全部（どの flow も指さないファイルも数える）。
func (c *comparer) coverage(cur *Side) {
	if c.opt.Game == "" {
		c.r.Problems = append(c.r.Problems, "カバー率: 新しい版のゲームのルート（project.json のあるフォルダ）が見つからない。--game で渡すか、--no-coverage で外す")
		return
	}
	covered := map[string]map[int]bool{}
	byRan := map[string]bool{}
	folders := map[string]bool{}
	for _, flow := range sortedKeys(cur.Flows) {
		for _, size := range sortedKeys(cur.Flows[flow]) {
			t := cur.Flows[flow][size]
			if t.Yarn == "" {
				continue
			}
			folders[filepath.ToSlash(filepath.Dir(t.Yarn))] = true
			if covered[t.Yarn] == nil {
				covered[t.Yarn] = map[int]bool{}
				byRan[t.Yarn] = true
			}
			if !t.Has("ranLines") {
				byRan[t.Yarn] = false
			}
			for n := range t.Lines {
				covered[t.Yarn][n] = covered[t.Yarn][n] || !t.Has("ranLines")
			}
			for _, n := range t.RanLines {
				covered[t.Yarn][n] = true
			}
		}
	}
	if len(folders) == 0 {
		c.r.Problems = append(c.r.Problems, "カバー率: 新しい版の tape.json に yarn が無い")
		return
	}
	for _, folder := range sortedKeys(folders) {
		files, _ := filepath.Glob(filepath.Join(c.opt.Game, filepath.FromSlash(folder), "*.yarn"))
		sort.Strings(files)
		for _, file := range files {
			rel := folder + "/" + filepath.Base(file)
			if covered[rel] != nil && !byRan[rel] {
				c.r.Notes = append(c.r.Notes, fmt.Sprintf("カバー率: %s は ranLines の無い記録があるので、通ったノードの行を全部通ったと見た（選ばなかった選択肢の中の行も通った扱い）", rel))
			}
			c.uncoveredIn(file, rel, covered[rel])
		}
	}
}

func (c *comparer) uncoveredIn(file, rel string, covered map[int]bool) {
	data, err := os.ReadFile(file)
	if err != nil {
		c.r.Problems = append(c.r.Problems, "カバー率: "+err.Error())
		return
	}
	nodes, _ := yarn.ParseFile(rel, string(data))
	var cmds []*yarn.Stmt
	for _, n := range nodes {
		collectCommands(n.Body, &cmds)
	}
	for _, s := range cmds {
		if covered[s.Line] {
			continue
		}
		u := Uncovered{Yarn: rel, Line: s.Line, Text: commandText(s)}
		for _, e := range c.acc.Coverage {
			if e.Yarn == rel && e.Line == s.Line && e.Approved && e.Why != "" {
				u.Accepted = true
			}
		}
		c.r.Uncovered = append(c.r.Uncovered, u)
	}
}

func collectCommands(body []*yarn.Stmt, out *[]*yarn.Stmt) {
	for _, s := range body {
		switch s.Kind {
		case "command", "set", "jump", "stop":
			*out = append(*out, s)
		}
		for _, o := range s.Options {
			collectCommands(o.Body, out)
		}
		for _, cl := range s.Clauses {
			collectCommands(cl.Body, out)
		}
	}
}

func commandText(s *yarn.Stmt) string {
	switch s.Kind {
	case "jump":
		return "<<jump " + s.Node + ">>"
	case "stop":
		return "<<stop>>"
	case "set":
		return "<<set " + s.Name + " …>>"
	}
	return "<<" + strings.TrimSpace(s.Name+" "+strings.Join(s.Args, " ")) + ">>"
}
