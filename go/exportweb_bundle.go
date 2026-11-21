package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// exportWebMediaExts は files に入れない拡張子（絵・音・フォントは images・sounds・アトラスで別に運ぶ）。
var exportWebMediaExts = map[string]bool{
	".ttf": true, ".otf": true, ".png": true, ".jpg": true, ".jpeg": true, ".webp": true,
	".wav": true, ".ogg": true, ".mp3": true,
}

// exportWebDecodedImageExts は 3D の入口のゲームが readBytes で読み、imageDecoder で解く拡張子。project.json の textures の物も files へ入れる。
// textures の物を web.compress が WebP に替えたら readBytes にも WebP が届く（imageDecoder は解ける）。
// WhyNot: textures の物の元の png を別に配らない — 同じ絵を 2 回運び、配る量が増える。
// WhyNot: 2D の入口のゲームでは入れない — 画面に使わない元絵まで束に入り、配る量が増える。
var exportWebDecodedImageExts = map[string]bool{".png": true, ".jpg": true, ".jpeg": true}

// webBundle は bundle.json の形。道は全部ゲームの根から見た `/` 区切り。
type webBundle struct {
	ID            string            `json:"id"`
	Title         string            `json:"title"`
	Files         []string          `json:"files"`
	Images        []string          `json:"images"`
	Sounds        []webSound        `json:"sounds"`
	Design        *webDesign        `json:"design,omitempty"`
	VirtualPad    *webVirtualPad    `json:"virtualPad,omitempty"`
	TouchGestures map[string]string `json:"touchGestures,omitempty"`
	Orientation   string            `json:"orientation,omitempty"`
	// Transcoded は論理の道 → 配る道（WebP・Opus・gzip に替えた物だけ）。頁は配る道で取り、論理の道で素材の表へ入れる。
	Transcoded map[string]string `json:"transcoded,omitempty"`
	// Deferred は「押して始める」の前に取らず、wasm を読んだ後に裏で取る素材（取る順）。files・images・sounds にも載せたまま。
	// WhyNot: files などから抜かない — deferred を知らない古い fge-web.js でも、全部を起動の前に取って動く。
	Deferred []webDeferredEntry `json:"deferred,omitempty"`
	// Splash は頁が「押して始める」の前に描く起動画面の材料（exportweb_splash.go）。
	Splash *webSplash `json:"splash,omitempty"`
	// WasmBrotli は classes.wasm を brotli にした物の道（無ければ頁は classes.wasm を取る）。
	WasmBrotli string `json:"wasmBrotli,omitempty"`
	// Boot は押して始めるまでに取る物の大きさ。頁は進みの棒をこの量の重みで動かす。
	Boot *webStartupBytes `json:"boot,omitempty"`
	// ServiceWorker は頁が sw.js を登録するか（project.json の web.serviceWorker・既定は入れる）。false なら頁は前に登録した物を外す。
	ServiceWorker bool `json:"serviceWorker,omitempty"`
	// StartupBudget は project.json の web.startupBudget の写し（web-check が gh-pages の根や play/ に写したフォルダで読む。why は公開される）。
	StartupBudget *webStartupBudget `json:"startupBudget,omitempty"`
	// EngineVersion は書き出した engine の版（ゲームの flix.toml の版。読めなければ空）。束の外の頁（テープの「はじめから遊ぶ」）が、束の頁が読める URL の旗の書き方を選ぶ。
	EngineVersion string `json:"engineVersion,omitempty"`
	// Checks は書き出しの確かめ（4G のタイトル・押した後の測り）の結果。
	Checks *webBundleChecks `json:"checks,omitempty"`
	// Draft は --draft で門が赤のまま書き出した束か（web-check が拒む）。DraftReasons は赤の理由。
	Draft        bool     `json:"draft,omitempty"`
	DraftReasons []string `json:"draftReasons,omitempty"`
}

// withTouch は頁が起動の前に要る物（design の縦横比・パッド・ジェスチャー・向き）を束に足す。
func (b *webBundle) withTouch(pr exportProject, t webTouch) {
	if pr.DesignWidth > 0 && pr.DesignHeight > 0 {
		b.Design = &webDesign{W: pr.DesignWidth, H: pr.DesignHeight}
	}
	b.VirtualPad = t.VirtualPad
	b.TouchGestures = t.TouchGestures
	if t.Orientation != "any" {
		b.Orientation = t.Orientation
	}
}

func (b webBundle) copyList() []string {
	seen := map[string]bool{}
	var list []string
	add := func(rel string) {
		if !seen[rel] {
			seen[rel] = true
			list = append(list, rel)
		}
	}
	for _, rel := range b.Files {
		add(rel)
	}
	for _, rel := range b.Images {
		add(rel)
	}
	for _, s := range b.Sounds {
		add(s.Path)
	}
	return list
}

// served は論理の道を配る道へ（変換していなければそのまま）。
func (b *webBundle) served(rel string) string {
	if s, ok := b.Transcoded[rel]; ok {
		return s
	}
	return rel
}

// buildWebBundle は project.json と assets/ の下から bundle.json の中身を作る（アトラスは後で足す）。
func buildWebBundle(game, id string, pr exportProject, readsImages bool) (webBundle, error) {
	b := webBundle{ID: id, Title: pr.Title, Files: []string{"project.json"}, Images: []string{}, Sounds: []webSound{}}
	named := map[string]bool{}
	for _, t := range pr.Textures {
		rel, err := checkAssetPath(game, t.Path, "textures[].path")
		if err != nil {
			return b, err
		}
		b.Images = append(b.Images, rel)
		named[rel] = true
		if readsImages && exportWebDecodedImageExts[strings.ToLower(path.Ext(rel))] {
			b.Files = append(b.Files, rel)
		}
	}
	for _, s := range pr.Sounds {
		rel, err := checkAssetPath(game, s.Path, "sounds[].path")
		if err != nil {
			return b, err
		}
		s.Path = rel
		b.Sounds = append(b.Sounds, s)
		named[rel] = true
	}
	root := filepath.Join(game, "assets")
	if dirExists(root) {
		err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			// WhyNot: 点で始まる物（.DS_Store・エディタの控え）を運ばないのは、OS ごとに有る無しが変わり、
			// 同じゲームから違う束ができるため。
			if strings.HasPrefix(d.Name(), ".") {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if d.IsDir() {
				return nil
			}
			rel, err := filepath.Rel(game, p)
			if err != nil {
				return err
			}
			rel = filepath.ToSlash(rel)
			ext := strings.ToLower(path.Ext(rel))
			if named[rel] || (exportWebMediaExts[ext] && !(readsImages && exportWebDecodedImageExts[ext])) {
				return nil
			}
			b.Files = append(b.Files, rel)
			return nil
		})
		if err != nil {
			return b, err
		}
	}
	sort.Strings(b.Files)
	return b, nil
}

// checkAssetPath は project.json の道を `/` 区切りの形にそろえ、ゲームの中に実在するかを見る。
func checkAssetPath(game, raw, field string) (string, error) {
	rel := path.Clean(strings.ReplaceAll(raw, "\\", "/"))
	if raw == "" || path.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, "../") || filepath.IsAbs(raw) {
		return "", fmt.Errorf("project.json の %s がゲームの外か空を指す: %q\n  次: ゲームの根から見た道に直す", field, raw)
	}
	if !fileExists(filepath.Join(game, filepath.FromSlash(rel))) {
		return "", fmt.Errorf("project.json の %s が指す %s が無い。\n  次: 素材を置くか project.json を直す", field, rel)
	}
	return rel, nil
}

func exportAssetPath(out, rel string) string {
	return filepath.Join(out, "assets", filepath.FromSlash(rel))
}

// resetExportOut は出力のフォルダを空にする。前の書き出し（bundle.json がある）か空のフォルダだけを消す。
// WhyNot: 何でも消さないのは、--out の打ち間違いで手で置いた物のフォルダを丸ごと消すため。
func resetExportOut(out string) error {
	entries, err := os.ReadDir(out)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%s を読めない: %v", out, err)
	}
	if len(entries) > 0 && !fileExists(filepath.Join(out, "bundle.json")) {
		return fmt.Errorf("%s に書き出しでない物がある（bundle.json が無い）。\n  次: 空のフォルダか前の書き出しのフォルダを --out に渡す", out)
	}
	if err := os.RemoveAll(out); err != nil {
		return fmt.Errorf("%s を消せない: %v", out, err)
	}
	return os.MkdirAll(filepath.Join(out, "assets"), 0o755)
}

// placeFontAtlases は project.json の fonts ごとに <out>/assets/font-atlas/<name>.fontatlas を置き、files に足す道を返す。
// WhyNot: アトラスの出どころ（--font-atlas-dir か font-bake か）の分岐を呼び手に出さないのは、仮の入口の
// --font-atlas-dir を外す時にここだけ直せば済むようにするため。
func placeFontAtlases(p exportWebPaths, o exportWebOptions, names []string) ([]string, int, error) {
	if len(names) == 0 {
		return nil, 0, nil
	}
	dir := o.FontAtlasDir
	if dir == "" {
		if _, ok := registry["font-bake"]; !ok {
			return nil, 2, errors.New("フォントアトラスの出どころが無い。\n  次: --font-atlas-dir を渡すか、font-bake が入った版の bin/fge で流す")
		}
		dir = filepath.Join(p.Work, "font-atlas")
		if code := runFontBake(p.Game, dir); code != 0 {
			if code != 1 {
				code = 2
			}
			return nil, code, fmt.Errorf("font-bake が止まった（終わりの番号 %d）。\n  次: 上の font-bake の出力を読む", code)
		}
	}
	var files []string
	for _, name := range names {
		src := filepath.Join(dir, name+".fontatlas")
		rel := webFontAtlasRel(name)
		if !fileExists(src) {
			return nil, 1, fmt.Errorf("フォントアトラス %s が無い。\n  次: font-bake で作るか、--font-atlas-dir の中身を確かめる", src)
		}
		if err := copyFile(src, exportAssetPath(p.Out, rel)); err != nil {
			return nil, 1, err
		}
		files = append(files, rel)
	}
	return files, 0, nil
}

// runFontBake は自分の実行ファイルを font-bake 付きで起こす。
// WhyNot: 同じ所の関数として呼ばないのは、font-bake が os.Exit や作業のフォルダを変えても、書き出しの続きに響かないようにするため。
func runFontBake(game, dir string) int {
	exe, err := os.Executable()
	if err != nil {
		ewLogf("自分の実行ファイルが分からない: %v", err)
		return 2
	}
	c := exec.Command(exe, "font-bake", game, dir)
	c.Stdout, c.Stderr = exportWebLog, exportWebLog
	if err := c.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		return 2
	}
	return 0
}

func marshalWebBundle(b webBundle) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(b); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// loadWebBundle は dir の bundle.json を読む。
func loadWebBundle(dir string) (webBundle, error) {
	var b webBundle
	raw, err := os.ReadFile(filepath.Join(dir, "bundle.json"))
	if err != nil {
		return b, err
	}
	if err := json.Unmarshal(raw, &b); err != nil {
		return b, fmt.Errorf("%s/bundle.json を読めない: %v", dir, err)
	}
	return b, nil
}

// exportAssembly は書き出し先に置いた束と、その内訳（アトラス・変換の結果・見つかった変換の道具）。
type exportAssembly struct {
	Bundle  webBundle
	Atlases []string
	Report  webTranscodeReport
	Enc     webEncoders
}

// assembleWebBundle は書き出し先を空にして素材とフォントアトラスを置き、素材を小さくして後回しの列を組む。
func assembleWebBundle(o exportWebOptions, c exportConfig) (exportAssembly, *exportFailure) {
	p, proj := c.Paths, c.Project
	var a exportAssembly
	ewLogf("④ アセットの束 → %s", p.Out)
	prevLossless := loadPreviousLosslessImages(p.Out)
	if err := resetExportOut(p.Out); err != nil {
		return a, exportFail(2, err)
	}
	b, err := buildWebBundle(p.Game, c.ID, proj, usesScene3dEntry(c.Entry))
	if err != nil {
		return a, exportFail(1, err)
	}
	b.EngineVersion = p.Version
	b.Files = c.Strip.without(c.EmbedPlan.withoutHidden(b.Files))
	if len(c.EmbedPlan.Omitted) > 0 {
		ewLogf("  web.omit で配らない: %s", strings.Join(c.EmbedPlan.Omitted, "・"))
	}
	b.withTouch(proj, c.Touch)
	splash, warning := buildWebSplash(p.Engine, c.StartPrompt, c.Touch.PortraitDesign)
	if warning != "" {
		ewLogf("知らせ: %s", warning)
	}
	b.Splash = &splash
	bundled, deferredSet, images := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, rel := range b.copyList() {
		bundled[rel] = true
	}
	for _, rel := range c.DeferredPlan.Paths {
		deferredSet[rel] = true
	}
	for _, rel := range b.Images {
		images[rel] = true
	}
	afterTap, err := resolveWebAfterTap(proj.Web, c.DeferredPolicy, bundled, deferredSet, images)
	if err != nil {
		return a, exportFail(1, err)
	}
	splash.AfterTap = &afterTap
	for _, rel := range b.copyList() {
		if err := copyFile(filepath.Join(p.Game, filepath.FromSlash(rel)), exportAssetPath(p.Out, rel)); err != nil {
			return a, exportFailf(1, "fge export-web: 素材を写せない: %v\n", err)
		}
	}

	ewLogf("⑤ フォントアトラス")
	atlases, code, err := placeFontAtlases(p, o, proj.fontNames())
	if err != nil {
		return a, exportFail(code, err)
	}
	b.Files = append(b.Files, atlases...)
	sort.Strings(b.Files)

	ewLogf("⑥ 素材を小さくする（絵は WebP・音は Opus・アトラスは画素を WebP か gzip）")
	enc := findWebEncoders(p.Engine, c.Compress)
	report := transcodeWebAssets(p.Out, &b, atlases, c.Compress, enc)
	report.Notes = append(report.Notes, c.LosslessNotes...)
	report.AutoLossyLines = buildWebAutoLossySummary(report.Verdicts, c.Compress.Auto, c.Compress.LossyImages, prevLossless)
	logWebAutoLossy(report.Verdicts)
	sizes := newWebSizeTable(p.Out)
	if b.Deferred, _, err = applyWebDeferredPolicy(webDeferredEntries(sizes, &b, c.DeferredPlan.Paths, c.TextureNames), c.DeferredPolicy, &b); err != nil {
		return a, exportFail(1, err)
	}
	setWebArrivalSeconds(sizes, &b)
	return exportAssembly{Bundle: b, Atlases: atlases, Report: report, Enc: enc}, nil
}
