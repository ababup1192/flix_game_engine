package px

// 絵が何かの宣言（kind）と、kind で当てる検査の束（checkset-design §1〜§3）。
// 宣言は sprite ごとに 1 つ（spec の既定 "kind" と sprite の "kind" で上書き。正は sprite.json の各 sprite の "kind"）。
// 束は Go の型つきの表（綴りの間違いを型で止める）。担当は検査を切れない: 外すのは kind の skip（理由つき）だけで、
// 外した物は applied の skipped に出どころつきで出る。

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// spriteKind は絵の種類。
type spriteKind string

const (
	kindTile       spriteKind = "tile"
	kindCharacter  spriteKind = "character"
	kindProp       spriteKind = "prop"
	kindIcon       spriteKind = "icon"
	kindUI         spriteKind = "ui"
	kindBackground spriteKind = "background"
	kindVFX        spriteKind = "vfx"
)

// kindSkip は kind が外す検査と理由（why は必須）。
type kindSkip struct {
	Ref checkRef
	Why string
}

// kindDef は kind の表の 1 行（定義は判定の形で書く・px kinds と decl の文に同じ表を出す）。
type kindDef struct {
	Kind     spriteKind
	Def      string
	Example  string
	NotThis  string
	Adds     []checkRef // base の上に足す検査（コマ全体の範囲）。どの kind も 1 つ以上
	Skips    []kindSkip
	Wrap     bool // 端が回る（orphan は 3×3・seam を当てる）
	AnimAlws bool // 2 コマ以上ならコマ列の検査を必ず回す
}

var kindTable = []kindDef{
	{Kind: kindTile, Def: "敷き詰めて継ぎ目が出ない物。四方で回る", Example: "床・壁・天井・地面", NotThis: "パズルの駒（敷くが回らない → prop）",
		Adds: []checkRef{{Check: checkSeam}, {Check: checkTileVariantEdge}}, Wrap: true},
	{Kind: kindCharacter, Def: "動く主体（人・敵・動物）。体の部位がある", Example: "主人公・敵", NotThis: "動く仕掛け（→ prop）",
		Adds: []checkRef{{Check: checkAnim}, {Check: checkHighlightReserve}, {Check: checkValueBlobs}}, AnimAlws: true},
	{Kind: kindProp, Def: "置かれる物・仕掛け・アイテムの絵（アイコンより大きい）", Example: "宝箱・扉・駒・アーティファクト",
		Adds: []checkRef{{Check: checkHighlightReserve}, {Check: checkValueBlobs}}},
	{Kind: kindIcon, Def: "おおむね 32px 以下で、地の上に置いて意味を伝える記号", Example: "効果アイコン・カードの印・UI の記号", NotThis: "9 スライスの枠（→ ui）",
		Adds:  []checkRef{{Check: checkBlackOutline}},
		Skips: []kindSkip{{Ref: checkRef{Check: checkFlatRun}, Why: "小さい記号は直線の段が普通"}}},
	{Kind: kindUI, Def: "枠・パネル・ボタン・ゲージ。伸ばす・並べる前提", Example: "窓の枠・ボタン",
		Adds: []checkRef{{Check: checkSeam}}},
	{Kind: kindBackground, Def: "画面の奥に敷く 1 枚（パララックスの層を含む）", Example: "戦闘の背景", NotThis: "背景の中で動く旗（別 sprite の prop か vfx へ分ける）",
		Adds: []checkRef{{Check: checkValueBlobs}, {Check: checkHighlightReserve}}},
	{Kind: kindVFX, Def: "一瞬の効果・粒子・光り", Example: "斬撃・爆発・光り",
		Adds: []checkRef{{Check: checkAnim}}, AnimAlws: true},
}

func lookupKind(k spriteKind) (*kindDef, bool) {
	for i := range kindTable {
		if kindTable[i].Kind == k {
			return &kindTable[i], true
		}
	}
	return nil, false
}

func kindNames() string {
	var ns []string
	for _, d := range kindTable {
		ns = append(ns, string(d.Kind))
	}
	return strings.Join(ns, "・")
}

// inferKind は宣言の無い sprite の kind を推す（根拠つき。当たらなければ prop と unknown）。
func inferKind(sp *spriteSpec, spec *specDoc) (spriteKind, string, bool) {
	for _, call := range sp.Post {
		if call.Name == "tile_preview" {
			return kindTile, "tile_preview", true
		}
	}
	if len(sp.Frames) > 0 {
		for _, p := range sp.partsOf(&reader{}, spec, sp.Frames[0]) {
			for _, call := range p.Ops {
				switch {
				case call.Name == "scatter_clusters" && call.Args.bool("wrap"):
					return kindTile, "scatter_clusters の wrap", true
				case call.Name == "nine_slice" || call.Name == "frame_box" || call.Name == "bevel_box":
					return kindUI, call.Name, true
				}
			}
		}
	}
	if sp.Roles != nil || sp.posed {
		return kindCharacter, "roles か pose", true
	}
	if max(sp.Size.W, sp.Size.H) <= 32 {
		return kindIcon, fmt.Sprintf("大きさ %dx%d（32 以下）", sp.Size.W, sp.Size.H), true
	}
	return kindProp, "当てはまる根拠が無い", false
}

// resolvedKind は sprite の kind と出どころ（declared・inferred）。
type resolvedKind struct {
	Kind   spriteKind
	By     string // declared・inferred
	Reason string // 推した根拠（inferred の時）
	Known  bool   // 推せたか（false は prop へ倒した）
}

func resolveKind(sp *spriteSpec, spec *specDoc) resolvedKind {
	if sp.Kind != "" {
		return resolvedKind{Kind: sp.Kind, By: "declared", Known: true}
	}
	k, why, ok := inferKind(sp, spec)
	return resolvedKind{Kind: k, By: "inferred", Reason: why, Known: ok}
}

// frameRefs は kind の束を当てたコマ全体の検査の並び（base ∪ add − skip）と、外した物。
func (rk resolvedKind) frameRefs(base []checkRef) (refs []checkRef, skipped []kindSkip) {
	def, _ := lookupKind(rk.Kind)
	has := map[string]bool{}
	for _, r := range append(append([]checkRef{}, base...), def.Adds...) {
		if has[r.String()] || r.Check == checkAnim || r.Check == checkTileVariantEdge {
			continue // コマ列・種の比べは build が別に回す
		}
		has[r.String()] = true
		refs = append(refs, r)
	}
	var kept []checkRef
	for _, r := range refs {
		if s, ok := rk.skips(r); ok {
			skipped = append(skipped, s)
			continue
		}
		kept = append(kept, r)
	}
	return kept, skipped
}

// skips は r を kind が外すか（op の Checks から来た分も消す）。
func (rk resolvedKind) skips(r checkRef) (kindSkip, bool) {
	def, _ := lookupKind(rk.Kind)
	for _, s := range def.Skips {
		if s.Ref.Check == r.Check && (s.Ref.Rule == "" || s.Ref.Rule == r.Rule) {
			return s, true
		}
	}
	return kindSkip{}, false
}

// adds は kind が足す検査か。
func (rk resolvedKind) adds(c checkName) bool {
	def, _ := lookupKind(rk.Kind)
	for _, r := range def.Adds {
		if r.Check == c {
			return true
		}
	}
	return false
}

// kindsText は bin/fge px kinds の本文。
func kindsText() string {
	var b strings.Builder
	b.WriteString("kind（pxsrc の \"kind\"・sprite ごとの \"kind\" で上書き。sprite.json の各 sprite の \"kind\" が正）:\n")
	for _, d := range kindTable {
		var adds []string
		for _, r := range d.Adds {
			adds = append(adds, r.String())
		}
		fmt.Fprintf(&b, "  %-10s %s（例 %s", d.Kind, d.Def, d.Example)
		if d.NotThis != "" {
			fmt.Fprintf(&b, "・例でない物 %s", d.NotThis)
		}
		fmt.Fprintf(&b, "）\n             足す検査: %s", strings.Join(adds, "・"))
		for _, s := range d.Skips {
			fmt.Fprintf(&b, "・外す: %s（%s）", s.Ref, s.Why)
		}
		b.WriteString("\n")
	}
	b.WriteString("\nどの kind でも当てる検査（base）: ")
	var base []string
	for _, r := range append(append([]checkRef{}, frameChecks...), techFrameChecks...) {
		base = append(base, r.String())
	}
	for _, r := range specChecks {
		base = append(base, r.String())
	}
	sort.Strings(base)
	b.WriteString(strings.Join(base, "・") + "\n")
	b.WriteString("宣言の無い sprite は推した kind で回し、advice px.decl.kind-missing に貼れる 1 行を出す。\n")
	return b.String()
}

func kindEnum() []any {
	var out []any
	for _, d := range kindTable {
		out = append(out, string(d.Kind))
	}
	return out
}

// cmdDeclSuggest は宣言の無い sprite に推した kind の案を出す（pxsrc は spec から・sprite.json は大きさと wrap から）。
func cmdDeclSuggest(out, errOut *strings.Builder, workRoot string, paths []string) int {
	for _, p := range paths {
		full := p
		if !filepath.IsAbs(full) {
			full = filepath.Join(workRoot, p)
		}
		if strings.HasSuffix(p, ".pxsrc.json") {
			spec, err := loadSpec(full)
			if err != nil {
				fmt.Fprintf(errOut, "px decl: %v\n", err)
				return 1
			}
			for _, sp := range spec.Sprites {
				if sp.Kind != "" {
					continue
				}
				k, why, ok := inferKind(sp, spec)
				mark := ""
				if !ok {
					mark = "（推せない: 定義を見て選ぶ）"
				}
				fmt.Fprintf(out, "%s %s: \"kind\": \"%s\"  ← %s%s\n", p, sp.Name, k, why, mark)
			}
			continue
		}
		doc, err := pxlib.LoadOrdered(full)
		if err != nil {
			fmt.Fprintf(errOut, "px decl: %v\n", err)
			return 1
		}
		wrap := wrapSprites(workRoot, filepath.Base(p))
		sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
		if sprites == nil {
			continue
		}
		names, vals := sprites.Items()
		for i, n := range names {
			so, _ := vals[i].(*pxlib.Obj)
			if so == nil || so.Has("kind") || strings.HasPrefix(n, "//") {
				continue
			}
			k, why := suggestSpriteKind(n, so, wrap)
			fmt.Fprintf(out, "%s %s: \"kind\": \"%s\"  ← %s\n", p, n, k, why)
		}
	}
	return 0
}

// suggestSpriteKind は sprite.json の sprite 1 つの kind を、大きさ・コマの数・wrap から推す。
func suggestSpriteKind(name string, so *pxlib.Obj, wrap map[string]bool) (spriteKind, string) {
	frames, _ := so.GetOr("frames", nil).(*pxlib.Obj)
	w, h := 0, 0
	if frames != nil && frames.Len() > 0 {
		_, fv := frames.Items()
		rows := strs(fv[0])
		h = len(rows)
		if h > 0 {
			w = len([]rune(rows[0]))
		}
	}
	switch {
	case wrap[name]:
		return kindTile, "tile_preview か scatter_clusters の wrap"
	case frames != nil && frames.Len() >= 2 && max(w, h) > 32:
		return kindCharacter, fmt.Sprintf("%d コマ・%dx%d（動く主体か vfx かは見て決める）", frames.Len(), w, h)
	case max(w, h) <= 32 && w > 0:
		return kindIcon, fmt.Sprintf("大きさ %dx%d（32 以下）", w, h)
	}
	return kindProp, "当てはまる根拠が無い（定義を見て選ぶ）"
}
