package px

// check: 手描きや assets の sprite.json に、build と同じ色の門と形の検査をかける（art-gate と precommit の置き換え）。

import (
	"fmt"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// checkReport は check の結果。
type checkReport struct {
	Gate  []gateFinding   `json:"gate"`
	Known []string        `json:"known"`
	Lint  []violation     `json:"lint"`
	OK    bool            `json:"ok"`
	Check *checkres.Round `json:"check,omitempty"` // 新しい形の結果とまとめ（門の外れも入る）
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
		bad, known := gate.CheckDoc(workRoot, doc, filepath.Base(p))
		for _, b := range bad {
			b.Msg = shown + "/" + b.Msg
			rep.Gate = append(rep.Gate, b)
		}
		for _, k := range known {
			knownSet[filepath.Base(p)+"/"+k] = true
		}
		wrap := wrapSprites(workRoot, filepath.Base(p))
		if sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj); sprites != nil {
			names, vals := sprites.Items()
			for i, n := range names {
				if so, _ := vals[i].(*pxlib.Obj); so != nil && so.GetOr("kind", "") == string(kindTile) {
					wrap[n] = true // sprite.json の kind: tile は端を回して見る
				}
			}
		}
		rep.Lint = append(rep.Lint, lintDoc(full, doc, spriteRules, wrap)...)
		rep.Lint = append(rep.Lint, docDecl(doc, filepath.Base(p), wrap)...)
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
	fmtRules, err := checkres.LoadRules(engineRoot)
	if err != nil {
		return nil, err
	}
	all := append([]violation{}, rep.Lint...)
	for i := range all {
		all[i].Scope = checkres.ScopeFrame
		if all[i].Frame == "" {
			all[i].Scope = checkres.ScopeFile // スプライト全体・Doc 全体の件
		}
	}
	for _, g := range rep.Gate {
		v := newViolation(checkGate, levelGate, 1, checkres.WantAtMost(0), g.Msg)
		v.Rule, v.Sprite, v.Scope = string(g.Kind), g.Sprite, checkres.ScopeFile
		all = append(all, v)
	}
	if seenProbe != nil {
		for _, v := range all {
			seenProbe(v)
		}
	}
	rep.Check = roundOf(all, fmtRules, nil)
	return rep, nil
}

// wrapSprites は art/*.pxsrc.json のうち target が slot の指定で、端を回して描くスプライト
// （tile_preview か scatter_clusters の wrap）の名前。px check もタイルの orphan を build と同じく 3×3 で見る。
func wrapSprites(workRoot, slot string) map[string]bool {
	out := map[string]bool{}
	specs, _ := filepath.Glob(filepath.Join(workRoot, "art", "*.pxsrc.json"))
	for _, path := range specs {
		spec, err := loadSpec(path)
		if err != nil || filepath.Base(spec.Target) != slot {
			continue
		}
		for _, sp := range spec.Sprites {
			for _, call := range sp.Post {
				if call.Name == "tile_preview" {
					out[sp.Name] = true
				}
			}
			if sp.Kind == kindTile {
				out[sp.Name] = true
			}
			for _, f := range sp.Frames {
				for _, p := range sp.partsOf(&reader{}, spec, f) {
					for _, call := range p.Ops {
						if call.Name == "scatter_clusters" && call.Args.bool("wrap") {
							out[sp.Name] = true
						}
					}
				}
			}
		}
	}
	return out
}

// lintDoc は fge sprite と同じ検査を、対象外の指定（lint-sprite）を当てたうえでかける。
// fge sprite が NG にする件は gate、注意は lint に写す。wrap のスプライトの orphan は 3×3 に並べて見る。
func lintDoc(full string, doc *pxlib.Obj, rules *sprite.Rules, wrap map[string]bool) []violation {
	plain, _ := pxlib.Plain(doc).(map[string]any)
	findings, _, _ := rules.CheckDoc(plain, rules.LegendHexes(sprite.GameDirOf(full), plain), true)
	out := make([]violation, 0, len(findings))
	lv, _ := doc.Get("legend")
	keyOf := pxlib.LegendOf(lv).KeyOf
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if sprites == nil {
		wrap = nil
	}
	for _, name := range sortedKeys(wrap) {
		so, _ := sprites.GetOr(name, nil).(*pxlib.Obj)
		if so == nil {
			continue
		}
		frames, _ := so.GetOr("frames", nil).(*pxlib.Obj)
		if frames == nil {
			continue
		}
		fnames, fvals := frames.Items()
		for i, fname := range fnames {
			g, err := pxlib.GridFromRows(strs(fvals[i]), keyOf)
			if err != nil {
				continue
			}
			for _, v := range wrappedOrphans(g, &checkCtx{SpriteRules: rules}) {
				v.Sprite, v.Frame = name, fname
				out = append(out, v)
			}
		}
	}
	for _, f := range findings {
		if f.Rule == "orphan" && wrap[f.Sprite] {
			continue // 端で回り込んだ塊は 1 枚では 1px に見える（上で 3×3 に並べて見た）
		}
		v := fromFinding(f.Finding)
		v.Sprite, v.Frame = f.Sprite, f.Frame
		if f.Frame == "" {
			v.Msg = f.Text // スプライト全体・Doc 全体の件は fge sprite の行のまま
		}
		out = append(out, v)
	}
	return out
}

// cmdCheck の終了コードは 0（合格）・1（色の門か gate の外れ）。strict なら lint の fail だけで 2
// （make の口と pre-commit は lint で止めない今までの形のまま。周回で使う時は --strict）。
func cmdCheck(out, errOut *strings.Builder, engineRoot, workRoot, gatePath string, paths []string, asJSON, strict bool) int {
	rep, err := checkFiles(engineRoot, workRoot, gatePath, paths)
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	code := 0
	if !rep.OK {
		code = 1
	} else if strict {
		code = rep.Check.Summary.Exit
	}
	if asJSON {
		out.Write(checkres.JSON(rep))
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
	fmt.Fprintf(out, "検査: %s\n", rep.Check.Summary.Line())
	return code
}

// docDecl は手描きの sprite.json の宣言の検査（kind の書き忘れ・lint-sprite の知らない規則名。checkset-design §3: px check は base と decl.*）。
// sprite.json の "kind": "tile" は端を回して見る（wrap に入れる）。
func docDecl(doc *pxlib.Obj, slot string, wrap map[string]bool) []violation {
	plain, _ := pxlib.Plain(doc).(map[string]any)
	known := map[string]bool{}
	for _, r := range []string{"orphan", "connect", "jaggy", "banding", "corner", "silhouette", "palette", "structure"} {
		known[r] = true
	}
	out := lintSpriteDecl(plain, known)
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if sprites == nil {
		return out
	}
	names, vals := sprites.Items()
	for i, n := range names {
		so, _ := vals[i].(*pxlib.Obj)
		if so == nil || strings.HasPrefix(n, "//") {
			continue
		}
		if kv, ok := so.Get("kind"); ok {
			if ks, _ := kv.(string); ks == string(kindTile) {
				wrap[n] = true
			} else if _, ok := lookupKind(spriteKind(ks)); !ok {
				v := declViolation("kind-unknown", 0, checkres.WantEqual(1), fmt.Sprintf("%s/%s: 知らない kind %q（%s）", slot, n, ks, kindNames()))
				v.Sprite = n
				out = append(out, v)
			}
			continue
		}
		k, why := suggestSpriteKind(n, so, wrap)
		v := declViolation("kind-missing", 0, checkres.WantEqual(1), fmt.Sprintf("kind が無い（推した kind %s・根拠 %s）", k, why)).
			fix("sprite に \"kind\" を書く（bin/fge px decl --suggest で案・定義は bin/fge px kinds）", checkres.Try{Op: "set kind", Arg: n, Try: string(k)})
		v.Sprite = n
		out = append(out, v)
	}
	return out
}
