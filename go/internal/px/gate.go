package px

// 色の門: sprite.json が、破ってはいけない色の決まりを守っているかを見る。
// どの sprite.json がどの画風（style）か・その画風で使ってよい色の集合の出どころ・
// 例外（allow）・既存の違反（known）は、ゲームの <名前>.colorgate.json に書く（docs/colorgate.schema.json）。
// 絵の良し悪しは見ない。それは目と依頼主の仕事。

import (
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// gateVersion は読める色の門の版。
const gateVersion = 2

// freeStyle は色の決まりの外（理由を why に書く）。styles に書かなくても使える。
const freeStyle = "free"

// colorGate は読んだ色の門。
type colorGate struct {
	Path    string
	Default string // files に無い sprite.json に当てる画風（省くと files に無い物は止める）
	Styles  map[string]*gateStyle
	Deny    []gateDeny
	Files   map[string]*gateFile
}

// gateStyle は 1 つの画風で使ってよい色の集合と、その出どころ。
type gateStyle struct {
	Label  string            // 外れた色の言い方（例 "Pear36 の外"）
	Colors map[string]string // 色の名前 → #rrggbb（列挙）
	From   string            // 色を引く Doc（ゲームのルートからの相対）
	Path   string            // From の中の場所（"." 区切り。省くと一番外）
	Keys   string            // From から引く色の名前の正規表現（省くと全部）
	hexes  map[string]bool
}

// gateDeny はどの画風でも使わない色。
type gateDeny struct{ Color, Why string }

// gateFile は 1 つの sprite.json（ファイル名）の決まり。
type gateFile struct {
	Style string
	Why   string
	Allow []gateAllow
	Known []string
}

// gateAllow は例外にする色の名前（正規表現）と理由。
type gateAllow struct {
	Keys string
	Why  string
	rx   *regexp.Regexp
}

// gateKind は門の違反の種類。
type gateKind string

const (
	gateNoEntry    gateKind = "no-entry"   // files に無い冊
	gateBadStyle   gateKind = "bad-style"  // styles に無い画風
	gateNoColor    gateKind = "no-color"   // 色票に無い色の名前
	gateDenied     gateKind = "deny"       // どの画風でも使わない色
	gateOutside    gateKind = "outside"    // 画風の色の外
	gateUnreadable gateKind = "unreadable" // 読めない冊
)

// gateFinding は門の違反 1 件。
type gateFinding struct {
	Slot, Sprite, Key string
	Kind              gateKind
	Msg               string
}

// loadColorGate は色の門を読み、色の集合を root（ゲームのルート）から解く。
func loadColorGate(root, path string) (*colorGate, error) {
	full := path
	if !filepath.IsAbs(full) {
		full = filepath.Join(root, path)
	}
	o, err := pxlib.LoadOrdered(full)
	if err != nil {
		return nil, err
	}
	doc, _ := pxlib.Plain(o).(map[string]any)
	g := &colorGate{Path: path, Styles: map[string]*gateStyle{}, Files: map[string]*gateFile{}}
	var probs problemList
	bad := func(where, format string, a ...any) {
		probs = append(probs, problem{where, fmt.Sprintf(format, a...)})
	}
	if v, _ := doc["version"].(float64); int(v) != gateVersion {
		bad("version", "%d と書く", gateVersion)
	}
	styles, _ := doc["styles"].(map[string]any)
	for _, name := range keysOf(styles) {
		so, _ := styles[name].(map[string]any)
		where := "styles." + name
		if name == freeStyle {
			bad(where, "free は決まりの外の名前（styles に書かない）")
			continue
		}
		st := &gateStyle{Label: str(so["label"]), From: str(so["from"]), Path: str(so["path"]), Keys: str(so["keys"]),
			Colors: map[string]string{}, hexes: map[string]bool{}}
		if st.Label == "" {
			bad(where+".label", "外れた色の言い方を書く（例 \"Pear36 の外\"）")
		}
		cols, _ := so["colors"].(map[string]any)
		for k, v := range cols {
			h := pxlib.HexOfValue(v)
			if h == "" {
				bad(where+".colors."+k, "#rrggbb で書く")
				continue
			}
			st.Colors[k] = h
			st.hexes[h] = true
		}
		if st.From != "" {
			var rx *regexp.Regexp
			if st.Keys != "" {
				if rx, err = regexp.Compile(st.Keys); err != nil {
					bad(where+".keys", "正規表現として読めない: %v", err)
				}
			}
			src := pxlib.LoadJSON(filepath.Join(root, st.From))
			if src == nil {
				bad(where+".from", "%s が読めない", st.From)
			}
			if st.Path != "" {
				for _, seg := range strings.Split(st.Path, ".") {
					m, _ := src.(map[string]any)
					src = m[seg]
				}
			}
			m, isObj := src.(map[string]any)
			if src != nil && !isObj {
				bad(where+".path", "%s の %q はオブジェクトでない", st.From, st.Path)
			}
			for k, v := range m {
				if rx != nil && !rx.MatchString(k) {
					continue
				}
				if c, ok := pxlib.RGBAOfValue(v); ok {
					st.hexes[pxlib.HexOfRGBA(c)] = true
				}
			}
		}
		if len(st.hexes) == 0 {
			bad(where, "色が 1 つも無い（colors に列挙するか from で引く）")
		}
		g.Styles[name] = st
	}
	if d, ok := doc["default"]; ok {
		g.Default, _ = d.(string)
		if g.Styles[g.Default] == nil {
			bad("default", "%q が styles に無い（files に無い新しい sprite.json に当てる画風の名前）", g.Default)
		}
	}
	deny, _ := doc["deny"].([]any)
	for i, e := range deny {
		m, _ := e.(map[string]any)
		h := pxlib.HexOfValue(m["color"])
		if h == "" || str(m["why"]) == "" {
			bad(fmt.Sprintf("deny[%d]", i), "color（#rrggbb）と why を書く")
			continue
		}
		g.Deny = append(g.Deny, gateDeny{h, str(m["why"])})
	}
	files, _ := doc["files"].(map[string]any)
	for _, name := range keysOf(files) {
		fo, _ := files[name].(map[string]any)
		where := "files." + name
		f := &gateFile{Style: str(fo["style"]), Why: str(fo["why"])}
		if f.Style != freeStyle && g.Styles[f.Style] == nil {
			bad(where+".style", "%q が styles に無い（free か styles の名前）", f.Style)
		}
		if f.Style == freeStyle && f.Why == "" {
			bad(where+".why", "free にした理由を書く")
		}
		allow, _ := fo["allow"].([]any)
		for i, e := range allow {
			m, _ := e.(map[string]any)
			a := gateAllow{Keys: str(m["keys"]), Why: str(m["why"])}
			aw := fmt.Sprintf("%s.allow[%d]", where, i)
			if a.Why == "" {
				bad(aw+".why", "理由の無い例外は足さない")
			}
			if a.rx, err = regexp.Compile(a.Keys); err != nil || a.Keys == "" {
				bad(aw+".keys", "色の名前の正規表現を書く")
				continue
			}
			f.Allow = append(f.Allow, a)
		}
		if ko, ok := fo["known"].(map[string]any); ok {
			f.Known = strs(ko["keys"])
			if str(ko["why"]) == "" {
				bad(where+".known.why", "既存の違反の理由（直すときの手順）を書く")
			}
		}
		g.Files[name] = f
	}
	if len(probs) > 0 {
		return nil, fmt.Errorf("%s:\n%w", path, probs)
	}
	return g, nil
}

func str(v any) string { s, _ := v.(string); return s }

// gateHint は files に無い sprite.json をどの画風で見るか（spec の style から）。
type gateHint struct {
	Style   string // 色の門の styles の名前（spec の style が門の画風を名指した時）
	Machine bool   // spec の style が機種の決まり（色は検査 style が gate の重さで縛るので、門は deny だけ見る）
}

// CheckDoc は 1 冊の sprite.json（slot はファイル名。assets/ と atelier/ の同じ名前に同じ決まり）を見る。
// files に無い時は、spec の style（hint）・門の default の順に画風を決めて見る（新しい絵のたびに files へ足させない）。
// どれも無ければ止める。known で通した色の名前は known に返す。
func (g *colorGate) CheckDoc(root string, doc *pxlib.Obj, slot string, hint gateHint) (bad []gateFinding, known []string) {
	f := g.Files[slot]
	if f == nil {
		switch {
		case hint.Style != "" && g.Styles[hint.Style] != nil:
			f = &gateFile{Style: hint.Style}
		case hint.Machine:
			f = &gateFile{Style: freeStyle}
		case g.Default != "":
			f = &gateFile{Style: g.Default}
		default:
			return []gateFinding{{Slot: slot, Kind: gateNoEntry,
				Msg: fmt.Sprintf("%s: %s の files に無い（画風 %s のどれかを書くか、門に default を書く）", slot, g.Path, g.styleNames())}}, nil
		}
	}
	var st *gateStyle
	if f.Style != freeStyle {
		if st = g.Styles[f.Style]; st == nil {
			return []gateFinding{{Slot: slot, Kind: gateBadStyle, Msg: fmt.Sprintf("%s: style %q が styles に無い", slot, f.Style)}}, nil
		}
	}
	pal := pxlib.DocPalette(root, pxlib.Plain(doc).(map[string]any), nil, pxlib.AnyColor)
	used := usedKeys(doc)
	keys := make([]string, 0, len(used))
	for k := range used {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	knownSet := map[string]bool{}
	for _, k := range f.Known {
		knownSet[k] = true
	}
	for _, key := range keys {
		sp := used[key]
		h, ok := pal[key]
		v := gateFinding{Slot: slot, Sprite: sp, Key: key}
		if !ok {
			v.Kind, v.Msg = gateNoColor, fmt.Sprintf("%s/%s: 色の名前 %s の色が色票に無い（paletteFile か palette に足す）", slot, sp, key)
			bad = append(bad, v)
			continue
		}
		if d := g.denied(h); d != nil {
			v.Kind, v.Msg = gateDenied, fmt.Sprintf("%s/%s: %s が %s（%s）", slot, sp, key, h, d.Why)
			bad = append(bad, v)
			continue
		}
		if st == nil || st.hexes[h] || f.allowed(key) {
			continue
		}
		if knownSet[key] {
			known = append(known, key)
			continue
		}
		v.Kind, v.Msg = gateOutside, fmt.Sprintf("%s/%s: %s = %s は%s（決まりの色にする。例外なら %s の allow に理由つきで足す）", slot, sp, key, h, st.Label, g.Path)
		bad = append(bad, v)
	}
	return bad, known
}

func (g *colorGate) denied(h string) *gateDeny {
	for i := range g.Deny {
		if g.Deny[i].Color == h {
			return &g.Deny[i]
		}
	}
	return nil
}

func (f *gateFile) allowed(key string) bool {
	for _, a := range f.Allow {
		if a.rx.MatchString(key) {
			return true
		}
	}
	return false
}

func (g *colorGate) styleNames() string {
	names := make([]string, 0, len(g.Styles)+1)
	for n := range g.Styles {
		names = append(names, n)
	}
	sort.Strings(names)
	return strings.Join(append(names, freeStyle), " / ")
}

// usedKeys は使っている色の名前 → 最初に使ったスプライト（Doc に書いた順で見る）。
func usedKeys(doc *pxlib.Obj) map[string]string {
	lv, _ := doc.Get("legend")
	legend := pxlib.LegendOf(lv)
	used := map[string]string{}
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if sprites == nil {
		return used
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
		_, fvals := frames.Items()
		for _, rows := range fvals {
			for _, r := range strs(rows) {
				for _, ch := range r {
					if k, ok := legend.KeyOf[string(ch)]; ok {
						if _, seen := used[string(k)]; !seen {
							used[string(k)] = name
						}
					}
				}
			}
		}
	}
	return used
}
