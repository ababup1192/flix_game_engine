package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// exportProject は project.json のうち書き出しが読む欄。
type exportProject struct {
	Title        string          `json:"title"`
	DesignWidth  int             `json:"designWidth"`
	DesignHeight int             `json:"designHeight"`
	Web          json.RawMessage `json:"web"`
	Textures     []webTexture    `json:"textures"`
	Sounds       []webSound      `json:"sounds"`
	Fonts        []struct {
		Name string `json:"name"`
	} `json:"fonts"`
}

func (pr exportProject) fontNames() []string {
	var names []string
	for _, f := range pr.Fonts {
		if f.Name != "" {
			names = append(names, f.Name)
		}
	}
	return names
}

func loadExportProject(game string) (exportProject, error) {
	var pr exportProject
	data, err := os.ReadFile(filepath.Join(game, "project.json"))
	if err != nil {
		return pr, fmt.Errorf("project.json を読めない: %v", err)
	}
	if err := json.Unmarshal(data, &pr); err != nil {
		return pr, fmt.Errorf("project.json を読めない: %v\n  次: JSON の形を直す", err)
	}
	return pr, nil
}

type webTexture struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type webSound struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Looping bool   `json:"looping"`
	// 以下は書き出しが wav から読んで束に書く（秒）。Seconds は元の長さ・LoopStart と LoopEnd は smpl のループ（終わりを含まない）。
	Seconds   float64 `json:"seconds,omitempty"`
	LoopStart float64 `json:"loopStart,omitempty"`
	LoopEnd   float64 `json:"loopEnd,omitempty"`
}

// readWebEntry は web/WebMain.flix の字（読めなければ空）。
func readWebEntry(game string) string {
	entry, err := os.ReadFile(filepath.Join(game, "web", "WebMain.flix"))
	if err != nil {
		return ""
	}
	return string(entry)
}

// usesScene3dEntry は入口の字 entry が 3D の入口を使うか。
func usesScene3dEntry(entry string) bool {
	return strings.Contains(entry, "WebLayer.withProject3d(")
}

// scene3dEntryWarning は、src が Scene3d を使うのに web/WebMain.flix が 2D の入口のままなら知らせる 1 行を返す（無ければ空）。
// WhyNot: 止めない — 3D の場面を持たない画面だけを書き出すゲームもあり、走らせれば初回に警告も出る。
func scene3dEntryWarning(game, entry string) string {
	if !strings.Contains(entry, "WebLayer.withProject(") {
		return ""
	}
	found := false
	_ = filepath.WalkDir(filepath.Join(game, "src"), func(path string, d fs.DirEntry, err error) error {
		if err != nil || found || d.IsDir() || filepath.Ext(path) != ".flix" {
			return nil
		}
		text, readErr := os.ReadFile(path)
		found = readErr == nil && strings.Contains(string(text), "Scene3d.")
		return nil
	})
	if !found {
		return ""
	}
	return "src が Scene3d を使っていますが web/WebMain.flix は WebLayer.withProject のままです。3D を描くなら WebLayer.withProject3d へ替えてください"
}

// exportFailure は書き出しの段が止まった時の終わりの番号と、errOut へ書く字（改行まで含む）。
// discard は消す書き出し先（空なら消さない）。
type exportFailure struct {
	code    int
	text    string
	discard string
}

func exportFail(code int, err error) *exportFailure {
	return &exportFailure{code: code, text: fmt.Sprintf("fge export-web: %v\n", err)}
}

func exportFailf(code int, format string, a ...any) *exportFailure {
	return &exportFailure{code: code, text: fmt.Sprintf(format, a...)}
}

// discarding は書き出し先 out を消してから止める形にする。
func (f *exportFailure) discarding(out string) *exportFailure {
	f.discard = out
	return f
}

// exportConfig は書き出しの前に読んで検査した物の一式（project.json の web 欄・道・後回しの計画）。
type exportConfig struct {
	Paths          exportWebPaths
	Java           string
	Project        exportProject
	ID, Entry      string
	Touch          webTouch
	Compress       webCompress
	StartPrompt    string
	ServiceWorker  bool
	Budget         webStartupBudget
	EmbedPlan      webEmbedPlan
	LosslessNotes  []string
	Strip          webStripPlan
	TextureNames   map[string][]string
	DeferredPlan   webDeferredPlan
	DeferredFonts  []string
	DeferredPolicy webDeferredPolicy
}

// loadExportConfig は道を決め、project.json の web 欄を全部読んで検査し、後回しの計画まで組む。
// WhyNot: web 欄の誤りを束を作る所まで待って言わない — 組み立てと TeaVM に数分かかった後に止まる。
func loadExportConfig(o exportWebOptions) (exportConfig, *exportFailure) {
	var c exportConfig
	p, code, err := resolveExportWebPaths(o)
	if err != nil {
		return c, exportFail(code, err)
	}
	c.Paths = p
	if c.Java, err = exportWebJava(p.Engine); err != nil {
		return c, exportFail(1, err)
	}
	if c.Project, err = loadExportProject(p.Game); err != nil {
		return c, exportFail(1, err)
	}
	proj := c.Project
	if c.Touch, err = resolveWebTouch(p.Game, proj.Web); err != nil {
		return c, exportFail(1, err)
	}
	if err = checkPadPlacesFit(c.Touch.VirtualPad, proj.DesignWidth, proj.DesignHeight); err != nil {
		return c, exportFail(1, err)
	}
	if c.Compress, err = resolveWebCompress(proj.Web); err != nil {
		return c, exportFail(1, err)
	}
	if c.Compress.Auto, err = loadWebAutoLossyRules(p.Engine); err != nil {
		return c, exportFail(2, err)
	}
	c.Compress.DataImages = loadWebShaderTextures(p.Game, proj)
	if c.StartPrompt, err = resolveWebStartPrompt(proj.Web); err != nil {
		return c, exportFail(1, err)
	}
	embed, err := resolveWebEmbed(proj.Web)
	if err != nil {
		return c, exportFail(1, err)
	}
	if c.ServiceWorker, err = resolveWebServiceWorker(proj.Web); err != nil {
		return c, exportFail(1, err)
	}
	if c.Budget, err = resolveWebStartupBudget(proj.Web); err != nil {
		return c, exportFail(1, err)
	}
	if c.Paths.AppIcon, err = resolveWebAppIcon(p.Game, proj.Web); err != nil {
		return c, exportFail(1, err)
	}
	c.ID = o.ID
	if c.ID == "" {
		c.ID = filepath.Base(p.Game)
	}
	c.Entry = readWebEntry(p.Game)
	early, err := buildWebBundle(p.Game, c.ID, proj, usesScene3dEntry(c.Entry))
	if err != nil {
		return c, exportFail(1, err)
	}
	if c.EmbedPlan, err = planWebEmbed(early, embed); err != nil {
		return c, exportFail(1, err)
	}
	if c.LosslessNotes, err = checkWebLosslessGlobs(early.Images, c.Compress); err != nil {
		return c, exportFail(1, err)
	}
	keep, err := resolveWebKeep(proj.Web)
	if err != nil {
		return c, exportFail(1, err)
	}
	if c.Strip, err = planWebStrip(p.Game, early.Files, keep, c.EmbedPlan); err != nil {
		return c, exportFail(1, err)
	}
	early.Files = c.Strip.without(early.Files)
	if fail := c.planDeferred(&early); fail != nil {
		return c, fail
	}
	for _, line := range c.DeferredPlan.Warnings {
		ewLogf("知らせ: %s", line)
	}
	if line := scene3dEntryWarning(p.Game, c.Entry); line != "" {
		ewLogf("%s", line)
	}
	return c, nil
}

// planDeferred は web.deferred・web.deferredFonts・web.deferredPolicy を読み、束の下書き early から後回しの計画を組む。
func (c *exportConfig) planDeferred(early *webBundle) *exportFailure {
	proj := c.Project
	deferredOrder, err := resolveWebDeferred(proj.Web)
	if err != nil {
		return exportFail(1, err)
	}
	c.TextureNames = textureNamesByPath(proj)
	if c.DeferredPlan, err = planWebDeferred(*early, deferredOrder.Globs, c.EmbedPlan, proj.fontNames(), c.TextureNames); err != nil {
		return exportFail(1, err)
	}
	if c.DeferredFonts, err = resolveWebDeferredFonts(proj.Web, proj.fontNames()); err != nil {
		return exportFail(1, err)
	}
	if err := checkDeferredFontNames(c.DeferredFonts, c.TextureNames, early.Sounds); err != nil {
		return exportFail(1, err)
	}
	if c.DeferredPolicy, err = resolveWebDeferredPolicy(proj.Web); err != nil {
		return exportFail(1, err)
	}
	fontGroupAt := webFontGroupStarts(c.DeferredPlan.Paths, c.DeferredFonts, c.DeferredPolicy, early, c.TextureNames)
	if c.DeferredPlan, c.TextureNames, err = withDeferredFonts(c.DeferredPlan, c.DeferredFonts, deferredOrder.Fonts, fontGroupAt, c.TextureNames); err != nil {
		return exportFail(1, err)
	}
	earlyEntries := webDeferredEntries(newWebSizeTable(""), early, c.DeferredPlan.Paths, c.TextureNames)
	_, lines, err := applyWebDeferredPolicy(earlyEntries, c.DeferredPolicy, early)
	if err != nil {
		return exportFail(1, err)
	}
	c.DeferredPlan.Warnings = append(c.DeferredPlan.Warnings, lines...)
	if rows := placeholderImageRowsWithoutWhy(earlyEntries, c.DeferredPolicy, early); len(rows) > 0 {
		msg := fmt.Sprintf("web.deferredPolicy の %s が後回しの絵を placeholder にしているのに why が無い（届くまで描かずに進み、押した後に黒いコマが出る）。\n  次: 絵は待たせる（onMissing を消す）か、行に \"why\": \"<理由>\" を書く", quotedList(rows))
		// WhyNot: --draft でも止める — draft は門（秒と 4G のタイトル）の赤を残す口で、web 欄の書き落としは書き出す前に直せる。
		if c.Budget.Declared {
			return exportFailf(1, "fge export-web: %s\n", msg)
		}
		ewLogf("★ %s（web.startupBudget を書くと止まる・移行が終わる版から全部止まる）", msg)
	}
	return nil
}
