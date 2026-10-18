// Package stateshape は、画面の操作や演出の状態を「ありえない組み合わせを作れる形」で持っていないかを見る lint。
//
//	fge-go state-shape [path ...]   名指しの .flix だけ見る (コミット時はステージしたファイル)
//	fge-go state-shape --all        git が知っている .flix を全部見る (古い除外・緩い歯止めもここで裁く)
//	fge-go state-shape --root DIR   リポジトリのルートを差し替える
//	fge-go state-shape --json       1 件ずつ checkres の形 (code・got・want・fix) で出す
//
// 止めるのは 4 つ (code は codes.go)。
//   - bool-fields: 型エイリアスの record に Bool の欄が boolFieldMin 個以上。今の数は boolFieldLimits
//     ("パス::型": 数) に書けばその数まで許す。増えたら止める
//   - option-bool: Option[Bool]
//   - catch-all: stateEnums で名指しした enum への match の `case _ =>` (変数で受ける腕も)。
//     見張り (if) つきの腕と、右辺が述語の形 (predicateRhs: false / None / Nil など) の腕は止めない
//   - view-effect: View のファイル (viewFiles) の def が決まった効果 (IO など大文字の効果) を持つ。
//     効果の変数 (ef など) と \ {} は数えない
//
// 規約は bin/lint-rules/state-shape.json。ゲームの bin/lint-rules/state-shape.local.json には
// stateEnums・boolFieldLimits・exempt ("パス::規則::名前": 理由) だけを書ける。
//
// WhyNot: Flix の構文木を持ち込まないのは、record-wrap・verb-names と同じく文字で読める範囲に
// 規則を絞ったため (コメントと文字列の中身は空白にしてから当てる)。
package stateshape

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "state-shape"

// FileSet はファイルの選び方。
type FileSet struct {
	SkipPrefixes     []string `json:"skipPrefixes"`
	SkipSuffixes     []string `json:"skipSuffixes"`
	BasenamePrefixes []string `json:"basenamePrefixes"`
	Suffixes         []string `json:"suffixes"`
}

// Rules は規約データ。
type Rules struct {
	Note          string            `json:"note"`
	ScopeSuffixes []string          `json:"scopeSuffixes"`
	SkipPrefixes  []string          `json:"skipPrefixes"`
	SkipDirNames  []string          `json:"skipDirNames"`
	BoolFieldMin  int               `json:"boolFieldMin"`
	RecordSkip    FileSet           `json:"recordSkip"`
	ViewFiles     FileSet           `json:"viewFiles"`
	PredicateRhs  string            `json:"predicateRhs"`
	Hints         map[string]string `json:"hints"`

	stateEnums      []string
	boolFieldLimits map[string]int
	limitFrom       map[string]string
	predicate       *regexp.Regexp
	exempt          *lintconf.Exempt
}

// tunable は規約ファイルとゲームのファイルの両方に書ける物 (足して読む・同じ鍵は止める)。
type tunable struct {
	StateEnums      []string       `json:"stateEnums"`
	BoolFieldLimits map[string]int `json:"boolFieldLimits"`
}

var localKeys = map[string]bool{"note": true, "stateEnums": true, "boolFieldLimits": true, "exempt": true}

// LoadRules は規約とゲームの設定を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	ex, err := lintconf.Load(root, Name, &r)
	if err != nil {
		return nil, err
	}
	if len(r.ScopeSuffixes) == 0 || r.BoolFieldMin < 2 || r.PredicateRhs == "" ||
		len(r.ViewFiles.BasenamePrefixes)+len(r.ViewFiles.Suffixes) == 0 {
		return nil, fmt.Errorf("state-shape.json には scopeSuffixes・boolFieldMin (2 以上)・predicateRhs・viewFiles が要ります")
	}
	for _, c := range codes {
		if strings.TrimSpace(r.Hints[c.Name]) == "" {
			return nil, fmt.Errorf("state-shape.json の hints に %s (代わりに何を使うか) が要ります", c.Name)
		}
	}
	if r.predicate, err = regexp.Compile(`^(?:` + r.PredicateRhs + `)$`); err != nil {
		return nil, fmt.Errorf("state-shape.json の predicateRhs が壊れています: %v", err)
	}
	r.exempt = ex
	r.boolFieldLimits = map[string]int{}
	r.limitFrom = map[string]string{}
	rulesRel, localRel := lintconf.Paths(Name)
	seenEnum := map[string]bool{}
	for i, rel := range []string{rulesRel, localRel} {
		body, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			if i == 1 && errors.Is(err, os.ErrNotExist) {
				continue
			}
			return nil, fmt.Errorf("読めません (%s): %v", rel, err)
		}
		if i == 1 {
			var keys map[string]json.RawMessage
			if err := json.Unmarshal(body, &keys); err != nil {
				return nil, fmt.Errorf("JSON として壊れています (%s): %v", rel, err)
			}
			for k := range keys {
				if !localKeys[k] {
					return nil, fmt.Errorf("%s に書けるのは stateEnums・boolFieldLimits・exempt だけです (%q)", rel, k)
				}
			}
		}
		var t tunable
		if err := json.Unmarshal(body, &t); err != nil {
			return nil, fmt.Errorf("JSON として壊れています (%s): %v", rel, err)
		}
		for _, e := range t.StateEnums {
			if seenEnum[e] {
				return nil, fmt.Errorf("stateEnums の %s が 2 度あります", e)
			}
			seenEnum[e] = true
			r.stateEnums = append(r.stateEnums, e)
		}
		for k, n := range t.BoolFieldLimits {
			if !strings.Contains(k, "::") || n < r.BoolFieldMin {
				return nil, fmt.Errorf("%s の boolFieldLimits %q: 鍵は \"パス::型\"、数は boolFieldMin (%d) 以上です", rel, k, r.BoolFieldMin)
			}
			if _, dup := r.boolFieldLimits[k]; dup {
				return nil, fmt.Errorf("boolFieldLimits %s が %s と %s の両方にあります", k, rulesRel, localRel)
			}
			r.boolFieldLimits[k] = n
			r.limitFrom[k] = filepath.ToSlash(rel)
		}
	}
	return &r, nil
}

// InScope はファイル rel を見るか。
func (r *Rules) InScope(rel string) bool {
	if lintconf.HasPrefixAny(rel, r.SkipPrefixes) {
		return false
	}
	for _, d := range strings.Split(path.Dir(rel), "/") {
		for _, s := range r.SkipDirNames {
			if d == s {
				return false
			}
		}
	}
	return hasSuffixAny(rel, r.ScopeSuffixes)
}

func hasSuffixAny(s string, list []string) bool {
	for _, x := range list {
		if strings.HasSuffix(s, x) {
			return true
		}
	}
	return false
}

func (f FileSet) skips(rel string) bool {
	return lintconf.HasPrefixAny(rel, f.SkipPrefixes) || hasSuffixAny(rel, f.SkipSuffixes)
}

func (f FileSet) picks(rel string) bool {
	if f.skips(rel) {
		return false
	}
	return lintconf.HasPrefixAny(path.Base(rel), f.BasenamePrefixes) || hasSuffixAny(rel, f.Suffixes)
}

// Hit は止める 1 件。Key は除外 (と歯止め) の鍵。
type Hit struct {
	Code  string
	Path  string
	Line  int
	Name  string
	Key   string
	Got   int
	Limit int // bool-fields で歯止めがある時はその数・ほかは 0
	Msg   string
}

// target は名指しした enum の解決後 (定義のあるファイルと case の名前)。
type target struct {
	Name  string
	Path  string
	Cases map[string]bool
}

// resolveEnums は stateEnums ("名前" か "パス::名前") の定義を files から探す。
func (r *Rules) resolveEnums(texts map[string]string, order []string) ([]target, error) {
	var out []target
	for _, spec := range r.stateEnums {
		want, name := "", spec
		if i := strings.Index(spec, "::"); i >= 0 {
			want, name = spec[:i], spec[i+2:]
		}
		var found []target
		for _, p := range order {
			if want != "" && p != want {
				continue
			}
			for _, e := range enums(texts[p]) {
				if e.Name == name {
					found = append(found, target{Name: name, Path: p, Cases: e.Cases})
				}
			}
		}
		switch {
		case len(found) == 0:
			return nil, fmt.Errorf("stateEnums の %s の定義 (enum %s) が見つかりません", spec, name)
		case len(found) > 1:
			var ps []string
			for _, f := range found {
				ps = append(ps, f.Path)
			}
			return nil, fmt.Errorf("stateEnums の %s は %s にあります。\"パス::%s\" の形で 1 つに決めてください", spec, strings.Join(ps, "・"), name)
		}
		out = append(out, found[0])
	}
	return out, nil
}

// contextAt は位置 pos の持ち主の名前 (record の欄なら 型.欄・enum なら enum の名前・def ならその名前)。
func contextAt(pos int, recs []record, ens []enumDecl, ds []def) string {
	for _, rc := range recs {
		if pos >= rc.From && pos < rc.To {
			field := ""
			for _, f := range rc.Fields {
				if rc.From+f.At <= pos {
					field = f.Name
				}
			}
			return rc.Name + "." + field
		}
	}
	for _, e := range ens {
		if pos >= e.From && pos < e.To {
			return e.Name
		}
	}
	name := ""
	for _, d := range ds {
		if d.At < pos {
			name = d.Name
		}
	}
	if name == "" {
		return "top"
	}
	return name
}

var optionBoolRe = regexp.MustCompile(`\bOption\[\s*Bool\s*\]`)
var bindRe = regexp.MustCompile(`^(?:_|[a-z]\w*)$`)

// Scan は 1 ファイルの本文から止める候補を拾う (除外・歯止めはまだ当てない)。
func (r *Rules) Scan(rel, text string, targets []target) []Hit {
	code := Blank(text)
	recs := records(rel, code)
	ens := enums(code)
	ds := defs(code)
	var hits []Hit

	if !r.RecordSkip.skips(rel) {
		for _, rc := range recs {
			var bools []string
			for _, f := range rc.Fields {
				if strings.TrimSpace(f.Type) == "Bool" {
					bools = append(bools, f.Name)
				}
			}
			if len(bools) >= r.BoolFieldMin {
				hits = append(hits, Hit{Code: CodeBoolFields, Path: rel, Line: rc.Line, Name: rc.Name,
					Key: rel + "::" + rc.Name, Got: len(bools),
					Msg: fmt.Sprintf("%s の Bool の欄 %d 個 (%s)", rc.Name, len(bools), strings.Join(bools, "・"))})
			}
		}
	}

	for _, m := range optionBoolRe.FindAllStringIndex(code, -1) {
		ctx := contextAt(m[0], recs, ens, ds)
		hits = append(hits, Hit{Code: CodeOptionBool, Path: rel, Line: lineOf(code, m[0]), Name: ctx,
			Key: rel + "::option-bool::" + ctx, Got: 1, Msg: fmt.Sprintf("%s が Option[Bool] を持つ", ctx)})
	}

	if len(targets) > 0 {
		local := map[string]bool{}
		for _, e := range ens {
			local[e.Name] = true
		}
		for _, mb := range matches(code) {
			var used []string
			for _, t := range targets {
				if local[t.Name] && t.Path != rel {
					continue // このファイルに同じ名前の別の enum がある
				}
				re := regexp.MustCompile(`\b` + regexp.QuoteMeta(t.Name) + `\.([A-Z]\w*)`)
				hit := false
				for _, a := range mb.Arms {
					for _, c := range re.FindAllStringSubmatch(a.Pat, -1) {
						if t.Cases[c[1]] {
							hit = true
						}
					}
				}
				if hit {
					used = append(used, t.Name)
				}
			}
			if len(used) == 0 {
				continue
			}
			for _, a := range mb.Arms {
				if a.Guarded || !bindRe.MatchString(a.Pat) || r.predicate.MatchString(a.Rhs) {
					continue
				}
				ctx := contextAt(mb.At, recs, ens, ds)
				rhs := a.Rhs
				if len([]rune(rhs)) > 40 {
					rhs = string([]rune(rhs)[:40]) + "…"
				}
				hits = append(hits, Hit{Code: CodeCatchAll, Path: rel, Line: a.Line, Name: ctx,
					Key: rel + "::catch-all::" + ctx, Got: 1,
					Msg: fmt.Sprintf("%s への match に取りこぼしの腕 `case %s => %s`", strings.Join(used, "・"), a.Pat, rhs)})
			}
		}
	}

	if r.ViewFiles.picks(rel) {
		for _, d := range ds {
			effs := concreteEffects(d.Effect)
			if len(effs) == 0 {
				continue
			}
			hits = append(hits, Hit{Code: CodeViewEffect, Path: rel, Line: lineOf(code, d.At), Name: d.Name,
				Key: rel + "::view-effect::" + d.Name, Got: len(effs),
				Msg: fmt.Sprintf("View の def %s が効果 %s を持つ", d.Name, strings.Join(effs, " + "))})
		}
	}
	return hits
}

// Report は 1 回の検査の結果。
type Report struct {
	Bad   []Hit
	Stale []string // 古い除外・緩い歯止め (--all の時だけ)
	Files int
}

// Check は files を見て、除外と歯止めを当てた結果を返す。enum の定義は all (git の全ファイル) から探す。
func (r *Rules) Check(root string, files, all []string, wholeRepo bool) (*Report, error) {
	texts := map[string]string{}
	var order []string
	read := func(rel string) bool {
		if _, ok := texts[rel]; ok {
			return true
		}
		if !r.InScope(rel) {
			return false
		}
		abs := filepath.Join(root, filepath.FromSlash(rel))
		// WhyNot: symlink を見ないのは、同じ .flix を別名で指しているだけの物を 2 度数えないため。
		if info, err := os.Lstat(abs); err != nil || !info.Mode().IsRegular() {
			return false
		}
		body, err := os.ReadFile(abs)
		if err != nil {
			return false
		}
		texts[rel] = string(body)
		order = append(order, rel)
		return true
	}
	var targets []target
	if len(r.stateEnums) > 0 {
		for _, rel := range all {
			read(rel)
		}
		var err error
		if targets, err = r.resolveEnums(texts, order); err != nil {
			return nil, err
		}
	}
	rep := &Report{}
	var hits []Hit
	for _, rel := range files {
		if !read(rel) {
			continue
		}
		rep.Files++
		hits = append(hits, r.Scan(rel, texts[rel], targets)...)
	}
	live := map[string]bool{}
	for _, h := range hits {
		live[h.Key] = true
		if h.Code == CodeBoolFields {
			if lim, ok := r.boolFieldLimits[h.Key]; ok {
				h.Limit = lim
				if h.Got <= lim {
					if h.Got < lim {
						rep.Stale = append(rep.Stale, fmt.Sprintf("%s の歯止めは %d ですが今は %d 個です（%s の boolFieldLimits を %d に下げてください）",
							h.Key, lim, h.Got, r.limitFrom[h.Key], h.Got))
					}
					continue
				}
			}
			rep.Bad = append(rep.Bad, h)
			continue
		}
		if _, ok := r.exempt.Why[h.Key]; !ok {
			rep.Bad = append(rep.Bad, h)
		}
	}
	if !wholeRepo {
		rep.Stale = nil
		return rep, nil
	}
	for _, k := range r.exempt.Stale(root, live) {
		rep.Stale = append(rep.Stale, fmt.Sprintf("%s は %s の exempt に載っていますが、もう鳴る所がありません（消してください）", k, r.exempt.From[k]))
	}
	var keys []string
	for k := range r.boolFieldLimits {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		p := k[:strings.Index(k, "::")]
		if info, err := os.Stat(filepath.Join(root, filepath.FromSlash(p))); err != nil || !info.Mode().IsRegular() {
			continue
		}
		if !live[k] {
			rep.Stale = append(rep.Stale, fmt.Sprintf("%s は %s の boolFieldLimits に載っていますが、もう鳴る所がありません（消してください）", k, r.limitFrom[k]))
		}
	}
	return rep, nil
}

// Result は 1 件を checkres の形にする。
func (r *Rules) Result(h Hit) checkres.Result {
	want := checkres.WantAtMost(0)
	fix := checkres.Fix{Hint: r.Hints[h.Code]}
	if h.Code == CodeBoolFields {
		lim := h.Limit
		if lim == 0 {
			lim = r.BoolFieldMin - 1
		}
		want = checkres.WantAtMost(float64(lim))
		fix.Try = []checkres.Try{{Op: "type alias " + h.Name, Arg: "Bool の欄", Now: h.Got, Try: lim}}
	}
	res := checkres.New(h.Code, 0, checkres.Measure{Got: float64(h.Got), Want: want}, nil, h.Msg)
	res.Scope = "file"
	res.Cause = checkres.Cause{Op: h.Name, Script: fmt.Sprintf("%s:%d", h.Path, h.Line)}
	res.Fix = fix
	return res
}

// jsonReport は --json の形。
type jsonReport struct {
	Results []checkres.Result `json:"results"`
	Stale   []string          `json:"stale"`
	Files   int               `json:"files"`
	Exit    int               `json:"exit"`
}

// Run は fge state-shape の本体。引数に --json があれば checkres の形で出す。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	asJSON := false
	for _, a := range args {
		if a == "--json" {
			asJSON = true
		}
	}
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	wholeRepo, files, err := lintconf.Args(root, args)
	if err != nil {
		return 2, err
	}
	all := files
	if !wholeRepo && len(rules.stateEnums) > 0 {
		if _, all, err = lintconf.Args(root, []string{"--all"}); err != nil {
			return 2, err
		}
	}
	rep, err := rules.Check(root, files, all, wholeRepo)
	if err != nil {
		return 2, err
	}
	code := 0
	if len(rep.Bad) > 0 || len(rep.Stale) > 0 {
		code = 1
	}
	if asJSON {
		jr := jsonReport{Results: []checkres.Result{}, Stale: rep.Stale, Files: rep.Files, Exit: code}
		if jr.Stale == nil {
			jr.Stale = []string{}
		}
		for _, h := range rep.Bad {
			jr.Results = append(jr.Results, rules.Result(h))
		}
		out.Write(checkres.Compact(jr))
		return code, nil
	}
	for _, s := range rep.Stale {
		fmt.Fprintf(errOut, "  %s\n", s)
	}
	if len(rep.Bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-state-shape] OK (%d ファイル / 名指しの enum %d / 歯止め %d / 除外 %d)\n",
				rep.Files, len(rules.stateEnums), len(rules.boolFieldLimits), len(rules.exempt.Why))
		}
		return code, nil
	}
	byCode := map[string][]Hit{}
	for _, h := range rep.Bad {
		byCode[h.Code] = append(byCode[h.Code], h)
	}
	for _, c := range codes {
		hs := byCode[c.Name]
		for _, h := range hs {
			res := rules.Result(h)
			fmt.Fprintf(errOut, "!! %s:%d [%s] %s (%s)\n", h.Path, h.Line, h.Code, h.Msg, res.Short())
		}
		if len(hs) > 0 {
			fmt.Fprintf(errOut, "   代わりに: %s\n", rules.Hints[c.Name])
		}
	}
	fmt.Fprintf(errOut, "[lint-state-shape] %d 件。どうしても残すなら bin/lint-rules/state-shape.local.json の exempt へ "+
		"\"パス::規則::名前\" と理由 1 行（Bool の欄の数は boolFieldLimits の \"パス::型\" に今の数）\n", len(rep.Bad))
	return 1, nil
}
