package px

// check: 手描きや assets の sprite.json に、build と同じ色の門と形の検査をかける（art-gate と precommit の置き換え）。

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// CheckReport は check の結果。
type CheckReport struct {
	Gate  []GateViolation `json:"gate"`
	Known []string        `json:"known"`
	Lint  []Violation     `json:"lint"`
	OK    bool            `json:"ok"`
}

// CheckFiles は sprite.json の並びに色の門と形の検査をかける。paths は workRoot からの相対か絶対。
func CheckFiles(engineRoot, workRoot, gatePath string, paths []string) (*CheckReport, error) {
	if gatePath == "" {
		var err error
		if gatePath, err = findGate(workRoot); err != nil {
			return nil, err
		}
	}
	gate, err := LoadColorGate(workRoot, gatePath)
	if err != nil {
		return nil, err
	}
	spriteRules, err := sprite.LoadRules(engineRoot)
	if err != nil {
		return nil, err
	}
	rep := &CheckReport{OK: true}
	knownSet := map[string]bool{}
	for _, p := range paths {
		full := p
		if !filepath.IsAbs(full) {
			full = filepath.Join(workRoot, p)
		}
		shown := filepath.ToSlash(filepath.Dir(p))
		doc, err := pxlib.ReadOrdered(full)
		if err != nil {
			rep.Gate = append(rep.Gate, GateViolation{Slot: filepath.Base(p), Kind: "unreadable", Msg: fmt.Sprintf("%s: 読めない（%v）", p, err)})
			continue
		}
		bad, known := gate.CheckDoc(workRoot, doc, filepath.Base(p))
		for _, b := range bad {
			b.Msg = shown + "/" + b.Msg
			rep.Gate = append(rep.Gate, b)
		}
		for _, k := range known {
			knownSet[filepath.Base(p)+"/"+k] = true
		}
		rep.Lint = append(rep.Lint, lintDoc(doc, spriteRules)...)
	}
	for k := range knownSet {
		rep.Known = append(rep.Known, k)
	}
	sort.Strings(rep.Known)
	rep.OK = len(rep.Gate) == 0
	return rep, nil
}

// lintDoc は各コマに sprite の形の規則をかける（報告だけ）。
func lintDoc(doc *pxlib.Obj, rules *sprite.Rules) []Violation {
	legend := map[string]pxlib.Key{}
	if lo, ok := doc.GetOr("legend", nil).(*pxlib.Obj); ok {
		keys, vals := lo.Items()
		for i, ch := range keys {
			if s, ok := vals[i].(string); ok {
				legend[ch] = pxlib.Key(s)
			}
		}
	}
	var out []Violation
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if sprites == nil {
		return nil
	}
	names, vals := sprites.Items()
	for i, name := range names {
		so, _ := vals[i].(*pxlib.Obj)
		if so == nil {
			continue
		}
		frames, _ := so.GetOr("frames", nil).(*pxlib.Obj)
		if frames == nil {
			continue
		}
		fnames, fvals := frames.Items()
		for j, fname := range fnames {
			g, _ := pxlib.GridFromRows(strs(pxlib.Plain(fvals[j])), legend)
			if g.W == 0 {
				continue
			}
			for _, f := range rules.CheckFrame(g) {
				out = append(out, Violation{Check: "sprite:" + f.Rule, Level: Lint, Sprite: name, Frame: fname,
					X: f.At.X, Y: f.At.Y, HasAt: f.HasAt, Cells: f.Cells, Msg: f.Msg})
			}
		}
	}
	return out
}

func cmdCheck(out, errOut *strings.Builder, engineRoot, workRoot, gatePath string, paths []string, asJSON bool) int {
	rep, err := CheckFiles(engineRoot, workRoot, gatePath, paths)
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	code := 0
	if !rep.OK {
		code = 1
	}
	if asJSON {
		data, _ := json.MarshalIndent(rep, "", "  ")
		out.Write(append(data, '\n'))
		return code
	}
	for _, g := range rep.Gate {
		fmt.Fprintln(out, g.Msg)
	}
	if len(rep.Known) > 0 {
		gp := gatePath
		if gp == "" {
			gp, _ = findGate(workRoot)
		}
		fmt.Fprintf(out, "既存の違反（known。直すときに決まりへ寄せる）: %d 色 — %s\n", len(rep.Known), gp)
	}
	if len(rep.Lint) > 0 {
		fmt.Fprintf(out, "形の検査（注意だけ・bin/fge sprite と同じ規則）: %d 件。最初は %s\n", len(rep.Lint), rep.Lint[0].String())
	}
	if rep.OK {
		fmt.Fprintln(out, "色の門: OK")
	} else {
		fmt.Fprintf(out, "色の門: NG %d 件\n", len(rep.Gate))
	}
	return code
}
