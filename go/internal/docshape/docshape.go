// Package docshape はゲームデータの Doc (assets/ の <名前>.<種類>.json) の外形を見る lint。
//
//	fge-go doc-shape [path ...]   名指しのファイルだけ見る (コミット時はステージした物 = 触った Doc だけ)
//	fge-go doc-shape --all        git が知っている Doc を全部見る (古い除外もここで裁く)
//	fge-go doc-shape --root DIR   リポジトリのルートを差し替える
//
// 見る物 (docs/doc-conventions.md の外形のうち、機械で決められる物):
//   - version   整数の version を持つ
//   - note      メモ (noteKeys のどれか。note か //) が空でない
//   - schema    同じ種類のスキーマがある
//   - label     スキーマの各項目 (sections の値と、その中の fields の値) に label か description がある
//
// Doc を渡されたら version・note・schema だけを見る。label はスキーマのファイル自体を渡された
// (ステージされた) ときだけ見る。
// WhyNot: Doc から辿ったスキーマの label まで見ないのは、Doc の値を 1 つ直しただけで、
// その種類のスキーマの全項目をそろえるまでコミットが止まるため (触った物だけ止める)。
//
// スキーマの探し方: そのプロジェクトの project.json の editor.resources[] (pattern が Doc に
// 当たる物の schema。Studio と同じ) → Doc の置き場から assets/ まで上って <種類>.schema.json
// → engine の docs/<種類>.schema.json (fx など engine が持つ種類。engine の場所は
// status.FindEngineDir = makefile-dup と同じ道具: engine のリポ自身なら根 → ENGINE → local.mk →
// Makefile の ENGINE)。
//
// どれが Doc か: パスに assets/ の段を含み、名前が <名前>.<種類>.json で、種類が skipKinds
// (schema・sprite・palette…) でない物。sprite は lint-sprite / palette が見る・palette は生成物。
//
// 規約は bin/lint-rules/doc-shape.json、ゲームの除外は doc-shape.local.json の exempt
// ("パス::version|note|schema|label": 理由)。
package docshape

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "doc-shape"

// Rules は規約データ。すべて JSON から来る。
type Rules struct {
	Note         string   `json:"note"`
	AssetsDir    string   `json:"assetsDir"`
	SkipKinds    []string `json:"skipKinds"`
	SkipPrefixes []string `json:"skipPrefixes"`
	SkipDirNames []string `json:"skipDirNames"`
	NoteKeys     []string `json:"noteKeys"`
	ItemTextKeys []string `json:"itemTextKeys"`
	NestKeys     []string `json:"nestKeys"`
	SchemaSuffix string   `json:"schemaSuffix"`
	ProjectFile  string   `json:"projectFile"`
	// EngineMarker・EngineDocs は engine の docs/ を探す手がかり。空なら engine を探さない
	// (WhyNot: 必須にしないのは、新しい fge-go が配る前の古い doc-shape.json で止まらないため)。
	EngineMarker string `json:"engineMarker"`
	EngineDocs   string `json:"engineDocs"`
	Hint         string `json:"hint"`
	exempt       *lintconf.Exempt
}

// LoadRules は規約と除外を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	ex, err := lintconf.Load(root, Name, &r)
	if err != nil {
		return nil, err
	}
	if r.AssetsDir == "" || len(r.NoteKeys) == 0 || len(r.ItemTextKeys) == 0 || r.SchemaSuffix == "" || r.ProjectFile == "" || strings.TrimSpace(r.Hint) == "" {
		return nil, fmt.Errorf("doc-shape.json には assetsDir・noteKeys・itemTextKeys・schemaSuffix・projectFile・hint が要ります")
	}
	r.exempt = ex
	return &r, nil
}

// split は rel を (プロジェクトの根, assets の段より後ろ) に分ける。assets の段が無ければ ok = false。
func (r *Rules) split(rel string) (project, inner string, ok bool) {
	seg := r.AssetsDir + "/"
	if strings.HasPrefix(rel, seg) {
		return "", rel[len(seg):], true
	}
	if i := strings.Index(rel, "/"+seg); i >= 0 {
		return rel[:i], rel[i+1+len(seg):], true
	}
	return "", "", false
}

// KindOf は rel が Doc ならその種類を返す。Doc でなければ "" 。
func (r *Rules) KindOf(rel string) string {
	if lintconf.HasPrefixAny(rel, r.SkipPrefixes) || !strings.HasSuffix(rel, ".json") {
		return ""
	}
	if _, _, ok := r.split(rel); !ok || r.inSkipDir(rel) {
		return ""
	}
	parts := strings.Split(path.Base(rel), ".")
	if len(parts) < 3 || parts[0] == "" {
		return ""
	}
	kind := parts[len(parts)-2]
	for _, s := range r.SkipKinds {
		if kind == s {
			return ""
		}
	}
	return kind
}

// isSchema は rel がスキーマ (assets の中の *.schema.json) か。
func (r *Rules) isSchema(rel string) bool {
	if lintconf.HasPrefixAny(rel, r.SkipPrefixes) || !strings.HasSuffix(rel, r.SchemaSuffix) {
		return false
	}
	_, _, ok := r.split(rel)
	return ok && !r.inSkipDir(rel)
}

// inSkipDir はパスの途中に skipDirNames の段 (test など。検査の見本の置き場) があるか。
func (r *Rules) inSkipDir(rel string) bool {
	for _, d := range strings.Split(path.Dir(rel), "/") {
		for _, s := range r.SkipDirNames {
			if d == s {
				return true
			}
		}
	}
	return false
}

// Hit は止める 1 件。Rule は version・note・schema・label のどれか。
type Hit struct {
	Path, Rule, What string
}

func (h Hit) key() string { return h.Path + "::" + h.Rule }

type checker struct {
	root       string
	rules      *Rules
	projects   map[string][]resource
	engineDocs string // engine の docs/ の絶対パス。engine が見つからなければ ""
	hits       []Hit
}

type resource struct{ Pattern, Schema string }

// placeholderRe はテンプレートの project.json の「"designWidth": __W__」のような穴。
var placeholderRe = regexp.MustCompile(`:\s*__[A-Z0-9_]+__`)

// resources はプロジェクトの project.json の editor.resources[]。読めなければ空 (探し方の 2 番目へ落ちる)。
func (c *checker) resources(project string) []resource {
	if res, ok := c.projects[project]; ok {
		return res
	}
	var doc struct {
		Editor struct {
			Resources []resource `json:"resources"`
		} `json:"editor"`
	}
	var res []resource
	if body, err := os.ReadFile(filepath.Join(c.root, filepath.FromSlash(path.Join(project, c.rules.ProjectFile)))); err == nil {
		body = placeholderRe.ReplaceAll(body, []byte(": 0"))
		if json.Unmarshal(body, &doc) == nil {
			res = doc.Editor.Resources
		}
	}
	c.projects[project] = res
	return res
}

func (c *checker) exists(rel string) bool {
	info, err := os.Stat(filepath.Join(c.root, filepath.FromSlash(rel)))
	return err == nil && info.Mode().IsRegular()
}

// findSchema は Doc rel (種類 kind) のスキーマのパス。無ければ "" 。
func (c *checker) findSchema(rel, kind string) string {
	project, _, _ := c.rules.split(rel)
	inProject := strings.TrimPrefix(rel, project+"/")
	if project == "" {
		inProject = rel
	}
	for _, res := range c.resources(project) {
		if ok, _ := path.Match(res.Pattern, inProject); ok && res.Schema != "" {
			if p := path.Join(project, res.Schema); c.exists(p) {
				return p
			}
		}
	}
	top := path.Join(project, c.rules.AssetsDir)
	for dir := path.Dir(rel); ; dir = path.Dir(dir) {
		if p := path.Join(dir, kind+c.rules.SchemaSuffix); c.exists(p) {
			return p
		}
		if dir == top || !strings.HasPrefix(dir, top+"/") {
			break
		}
	}
	if c.engineDocs != "" {
		p := filepath.Join(c.engineDocs, kind+c.rules.SchemaSuffix)
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
			return p
		}
	}
	return ""
}

func (c *checker) add(p, rule, what string) {
	c.hits = append(c.hits, Hit{Path: p, Rule: rule, What: what})
}

func (c *checker) checkDoc(rel, kind string) {
	body, err := os.ReadFile(filepath.Join(c.root, filepath.FromSlash(rel)))
	if err != nil {
		return
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		// WhyNot: 壊れた JSON をここで止めないのは、読み込みが fail-open で既定値へ落とすのが
		// 規約で、壊れ方は Studio と make check の側が知らせるため。外形だけを見る。
		return
	}
	if v, ok := doc["version"].(float64); !ok || v != float64(int64(v)) {
		c.add(rel, "version", "整数の version がありません")
	}
	hasNote := false
	for _, k := range c.rules.NoteKeys {
		if s, ok := doc[k].(string); ok && strings.TrimSpace(s) != "" {
			hasNote = true
		}
	}
	if !hasNote {
		c.add(rel, "note", fmt.Sprintf("メモ (%s) がありません。いじると何が変わるかを 1〜2 行", strings.Join(c.rules.NoteKeys, " か ")))
	}
	if c.findSchema(rel, kind) == "" {
		c.add(rel, "schema", fmt.Sprintf("スキーマ %s%s がありません (project.json の editor.resources[] にも engine の %s/ にも無い)", kind, c.rules.SchemaSuffix, c.rules.EngineDocs))
	}
}

// checkSchema はスキーマのファイル自体を渡されたときだけ呼ぶ (Doc からは辿らない)。
func (c *checker) checkSchema(rel string) {
	body, err := os.ReadFile(filepath.Join(c.root, filepath.FromSlash(rel)))
	if err != nil {
		return
	}
	var doc struct {
		Sections map[string]any `json:"sections"`
	}
	if json.Unmarshal(body, &doc) != nil {
		return
	}
	var missing []string
	c.walkItems(doc.Sections, "", &missing)
	if len(missing) > 0 {
		sort.Strings(missing)
		c.add(rel, "label", fmt.Sprintf("%s に %s がありません", strings.Join(missing, "・"), strings.Join(c.rules.ItemTextKeys, " か ")))
	}
}

// walkItems は sections (と入れ子の fields) の各項目に label か description があるかを見る。
func (c *checker) walkItems(items map[string]any, prefix string, missing *[]string) {
	for name, v := range items {
		if strings.HasPrefix(name, "//") {
			continue
		}
		item, ok := v.(map[string]any)
		if !ok {
			continue
		}
		has := false
		for _, k := range c.rules.ItemTextKeys {
			if s, ok := item[k].(string); ok && strings.TrimSpace(s) != "" {
				has = true
			}
		}
		if !has {
			*missing = append(*missing, prefix+name)
		}
		for _, nk := range c.rules.NestKeys {
			if sub, ok := item[nk].(map[string]any); ok {
				c.walkItems(sub, prefix+name+".", missing)
			}
		}
	}
}

// Run は fge doc-shape の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	all, files, err := lintconf.Args(root, args)
	if err != nil {
		return 2, err
	}
	c := &checker{root: root, rules: rules, projects: map[string][]resource{}}
	if rules.EngineMarker != "" && rules.EngineDocs != "" {
		if dir, _ := status.FindEngineDir(root, rules.EngineMarker); dir != "" {
			c.engineDocs = filepath.Join(dir, filepath.FromSlash(rules.EngineDocs))
		}
	}
	docs := 0
	for _, rel := range files {
		if kind := rules.KindOf(rel); kind != "" {
			docs++
			c.checkDoc(rel, kind)
		} else if rules.isSchema(rel) && c.exists(rel) {
			c.checkSchema(rel)
		}
	}
	return report(out, errOut, root, rules, c.hits, all, docs), nil
}

func report(out, errOut *strings.Builder, root string, rules *Rules, hits []Hit, all bool, docs int) int {
	live := map[string]bool{}
	var bad []Hit
	for _, h := range hits {
		live[h.key()] = true
		if _, ok := rules.exempt.Why[h.key()]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if all {
		for _, k := range rules.exempt.Stale(root, live) {
			fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、もう鳴る所がありません（消してください）\n", k, rules.exempt.From[k])
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-doc-shape] OK (Doc %d 件 / 除外 %d 件)\n", docs, len(rules.exempt.Why))
		}
		return code
	}
	for _, h := range bad {
		fmt.Fprintf(errOut, "!! %s [%s] %s\n", h.Path, h.Rule, h.What)
	}
	fmt.Fprintf(errOut, "[lint-doc-shape] %d 件。%s\n"+
		"  どうしても残すなら bin/lint-rules/doc-shape.local.json の exempt へ \"パス::version|note|schema|label\" と理由 1 行\n",
		len(bad), rules.Hint)
	return 1
}
