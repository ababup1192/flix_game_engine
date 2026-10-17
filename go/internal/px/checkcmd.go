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

// checkReport は check の結果。
type checkReport struct {
	Gate  []gateFinding `json:"gate"`
	Known []string      `json:"known"`
	Lint  []violation   `json:"lint"`
	OK    bool          `json:"ok"`
}

// checkFiles は sprite.json の並びに色の門と形の検査をかける。paths は workRoot からの相対か絶対。
func checkFiles(engineRoot, workRoot, gatePath string, paths []string) (*checkReport, error) {
	if gatePath == "" {
		var err error
		if gatePath, err = findGate(workRoot); err != nil {
			return nil, err
		}
	}
	gate, err := loadColorGate(workRoot, gatePath)
	if err != nil {
		return nil, err
	}
	spriteRules, err := sprite.LoadRules(engineRoot)
	if err != nil {
		return nil, err
	}
	rep := &checkReport{OK: true}
	knownSet := map[string]bool{}
	for _, p := range paths {
		full := p
		if !filepath.IsAbs(full) {
			full = filepath.Join(workRoot, p)
		}
		shown := filepath.ToSlash(filepath.Dir(p))
		doc, err := pxlib.LoadOrdered(full)
		if err != nil {
			rep.Gate = append(rep.Gate, gateFinding{Slot: filepath.Base(p), Kind: gateUnreadable, Msg: fmt.Sprintf("%s: 読めない（%v）", p, err)})
			continue
		}
		bad, known := gate.CheckDoc(workRoot, doc, filepath.Base(p), gateHint{})
		for _, b := range bad {
			b.Msg = shown + "/" + b.Msg
			rep.Gate = append(rep.Gate, b)
		}
		for _, k := range known {
			knownSet[filepath.Base(p)+"/"+k] = true
		}
		rep.Lint = append(rep.Lint, lintDoc(full, doc, spriteRules)...)
	}
	for k := range knownSet {
		rep.Known = append(rep.Known, k)
	}
	sort.Strings(rep.Known)
	rep.OK = len(rep.Gate) == 0
	for _, v := range rep.Lint {
		if v.Level == levelGate {
			rep.OK = false
		}
	}
	return rep, nil
}

// lintDoc は fge sprite と同じ検査を、対象外の指定（lint-sprite）を当てたうえでかける。
// fge sprite が NG にする件は gate、注意は lint に写す。
func lintDoc(full string, doc *pxlib.Obj, rules *sprite.Rules) []violation {
	plain, _ := pxlib.Plain(doc).(map[string]any)
	findings, _, _ := rules.CheckDoc(plain, rules.LegendHexes(sprite.GameDirOf(full), plain), true)
	out := make([]violation, 0, len(findings))
	for _, f := range findings {
		v := fromFinding(f.Finding)
		v.Sprite, v.Frame = f.Sprite, f.Frame
		if f.Frame == "" {
			v.Msg = f.Text // スプライト全体・Doc 全体の件は fge sprite の行のまま
		}
		out = append(out, v)
	}
	return out
}

func cmdCheck(out, errOut *strings.Builder, engineRoot, workRoot, gatePath string, paths []string, asJSON bool) int {
	rep, err := checkFiles(engineRoot, workRoot, gatePath, paths)
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
	ng, notes := 0, 0
	for _, v := range rep.Lint {
		if v.Level == levelGate {
			ng++
			fmt.Fprintln(out, v.String())
		} else {
			notes++
		}
	}
	if notes > 0 {
		fmt.Fprintf(out, "形の検査の注意（bin/fge sprite と同じ規則・対象外を当てた後）: %d 件（--json で全部）\n", notes)
	}
	if len(rep.Gate) == 0 {
		fmt.Fprintln(out, "色の門: OK")
	} else {
		fmt.Fprintf(out, "色の門: NG %d 件\n", len(rep.Gate))
	}
	if ng > 0 {
		fmt.Fprintf(out, "形の検査: NG %d 件\n", ng)
	}
	return code
}
