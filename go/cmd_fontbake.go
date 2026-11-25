package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fontbake"
	"github.com/ababup1192/flix_game_engine/go/internal/javacmd"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

const fontBakeUsage = `使い方: fge font-bake <ゲームのフォルダ> <出力のフォルダ> [--glyphs collected|all|desktop] [--dev-dir <根からの所>]... [--no-gate] [--collect-only] [--if-stale]
  ゲームが出しうる字（assets の *.yarn・Doc の文字列の値・*.txt / *.csv と、src の .flix の文字列リテラル）を集め、
  project.json の fonts を 1 本ずつ、デスクトップの起動時と同じ距離場のアトラスに生成して書く:
    <出力>/<fonts[].name>.fontatlas   RenderFontCache の形（デスクトップのキャッシュと同じ形・RenderFontCache.decode で読む）
    <出力>/fonts.json                 { "fonts": [{ name, file, textureName, side, glyphs, bytes }], "charset": 字の数 }
  生成したどのアトラスにも無い字が 1 つでもあれば、字と出所（ファイル:行）を出して 1 で終わる（--no-gate で知らせるだけ）。
  ただし開発の道具の所（src/render・src/sim と --dev-dir・.flix の doc = "..." の行）にしか無い字は、漏れても知らせるだけ。
  --glyphs: collected（既定・集めた字＋ASCII）/ all（フォントが持つ BMP の字を全部）/ desktop（デスクトップの glyphs: used と同じ集め方。突き合わせ用）
  --if-stale: <出力>/fonts.json の指紋（engine・字の集合・フォント）が今と同じでアトラスが揃っていれば、作らずに 0 で終わる
              （make font-bake・dist の前。字の漏れがあった回（--no-gate でも）は指紋を書かないので、次も作り直して知らせる）
  各 .fontatlas の隣に .key（フォントの中身・大きさ・作り方の版の印）も書く。デスクトップの起動はこれが合う時だけ読む。
  --collect-only: 生成せずに、集めた字の数と、実行中に字を作る行の知らせだけ出す（engine の古いゲームでも流せる）
  終わりの番号: 0 漏れ無し・1 漏れか失敗・2 呼び方の誤り`

func init() {
	register("font-bake",
		"ブラウザへ同梱するフォントアトラスを生成する（字を集め、漏れがあれば字と出所を出して止める）。font-bake <ゲーム> <出力>",
		cmdFontBake)
}

type fontBakeOpts struct {
	game, out   string
	glyphs      string
	gate        bool
	collectOnly bool
	ifStale     bool
	devDirs     []string
}

func parseFontBakeArgs(rest []string) (fontBakeOpts, error) {
	o := fontBakeOpts{glyphs: "collected", gate: true}
	var pos []string
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		switch {
		case a == "--no-gate":
			o.gate = false
		case a == "--collect-only":
			o.collectOnly = true
		case a == "--if-stale":
			o.ifStale = true
		case a == "--glyphs" && i+1 < len(rest):
			o.glyphs = rest[i+1]
			i++
		case strings.HasPrefix(a, "--glyphs="):
			o.glyphs = strings.TrimPrefix(a, "--glyphs=")
		case a == "--dev-dir" && i+1 < len(rest):
			o.devDirs = append(o.devDirs, rest[i+1])
			i++
		case strings.HasPrefix(a, "--dev-dir="):
			o.devDirs = append(o.devDirs, strings.TrimPrefix(a, "--dev-dir="))
		case strings.HasPrefix(a, "-"):
			return o, fmt.Errorf("知らない旗 %s", a)
		default:
			pos = append(pos, a)
		}
	}
	switch o.glyphs {
	case "collected", "all", "desktop":
	default:
		return o, fmt.Errorf("--glyphs は collected / all / desktop のどれか（%s が来た）", o.glyphs)
	}
	if o.collectOnly && len(pos) == 1 {
		pos = append(pos, "")
	}
	if len(pos) != 2 {
		return o, fmt.Errorf("ゲームのフォルダと出力のフォルダの 2 つが要る")
	}
	o.game, o.out = pos[0], pos[1]
	return o, nil
}

func cmdFontBake(out, errOut *strings.Builder, rest []string, _ bool) int {
	o, err := parseFontBakeArgs(rest)
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n%s\n", err, fontBakeUsage)
		return 2
	}
	game, err := filepath.Abs(o.game)
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
		return 1
	}
	if _, err := os.Stat(filepath.Join(game, "project.json")); err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %s に project.json が無い（ゲームの根を渡す）\n", game)
		return 2
	}
	cs, notices, err := fontbake.Collect(game, append(append([]string{}, fontbake.DefaultDevDirs...), o.devDirs...))
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: 字を集められない: %v\n", err)
		return 1
	}
	fmt.Fprintf(out, "[font-bake] 集めた字 %d（ASCII を足して %d）\n", len(cs.Origins), len([]rune(cs.WithASCII())))
	for _, n := range notices {
		fmt.Fprintf(out, "[font-bake] 知らせ: %s の字は実行中に作られ、集めた字の集合の外（ブラウザでは出ないことがある）: %s\n", n.At, n.What)
	}
	if o.collectOnly {
		return 0
	}
	outDir, err := filepath.Abs(o.out)
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
		return 1
	}
	runner, err := newFontBakeRunner(game)
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
		return 1
	}
	if o.ifStale {
		if inputs, err := bakeInputs(runner, game, o.glyphs, cs); err == nil && fontbake.IsFresh(outDir, inputs) {
			fmt.Fprintf(out, "[font-bake] 新しい（engine・字の集合・フォントが前に生成した時と同じ）— 作り直さない: %s\n", outDir)
			return 0
		}
	}
	glyphsArg := map[string]string{"all": "--all", "desktop": "--used"}[o.glyphs]
	if glyphsArg == "" {
		charset := filepath.Join(game, "build", "font-bake", "charset.txt")
		if err := os.MkdirAll(filepath.Dir(charset), 0o755); err == nil {
			err = os.WriteFile(charset, []byte(cs.WithASCII()), 0o644)
		}
		if err != nil {
			fmt.Fprintf(errOut, "fge font-bake: 字の集合を書けない: %v\n", err)
			return 1
		}
		glyphsArg = charset
	}
	jar, err := runner.EnsureJar()
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
		return 1
	}
	baked, err := runner.Bake(jar, glyphsArg, outDir)
	if err != nil {
		fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
		return 1
	}
	atlases := make([]*fontbake.Atlas, 0, len(baked))
	for _, b := range baked {
		a, err := fontbake.ReadAtlas(b.Name, b.Path)
		if err != nil {
			fmt.Fprintf(errOut, "fge font-bake: %v\n", err)
			return 1
		}
		atlases = append(atlases, a)
		fmt.Fprintf(out, "[font-bake] %-10s %5d 字  %dx%d  %s（gzip で %s）  集めた字のうち無い字 %d\n",
			a.Name, len(a.Glyphs), a.Side, a.Side, humanBytes(a.Bytes), humanBytes(gzipSize(a.Path)), fontbake.MissingIn(cs, a))
	}
	var gameLeaks, devLeaks []fontbake.Leak
	for _, l := range fontbake.FindLeaks(cs, atlases) {
		if l.Dev {
			devLeaks = append(devLeaks, l)
		} else {
			gameLeaks = append(gameLeaks, l)
		}
	}
	inputs := ""
	// WhyNot: --no-gate の回でも漏れがあれば指紋を書かない — 書くと、後で門ありの --if-stale が新しいと見て漏れを言わずに抜ける。
	if len(gameLeaks) == 0 {
		if inputs, err = bakeInputs(runner, game, o.glyphs, cs); err != nil {
			fmt.Fprintf(out, "[font-bake] 知らせ: 指紋を作れない（次の --if-stale も作り直す）: %v\n", err)
		}
	}
	if err := writeFontsManifest(outDir, atlases, len([]rune(cs.WithASCII())), inputs); err != nil {
		fmt.Fprintf(errOut, "fge font-bake: fonts.json を書けない: %v\n", err)
		return 1
	}
	for _, a := range atlases {
		if !fileExists(a.Path + ".key") {
			fmt.Fprintf(out, "[font-bake] 知らせ: %s.key が無い — ゲームの engine が古く .key を書かない（ブラウザは読めるが、デスクトップの起動は読まない）\n", a.Path)
		}
	}
	if len(devLeaks) > 0 {
		fmt.Fprintf(out, "[font-bake] 知らせ: 止めない字 %d 字がアトラスに無い（開発の道具の所にしか無い字か、私用領域の字。遊ぶ画面に出すなら直す）:\n", len(devLeaks))
		for _, l := range devLeaks {
			fmt.Fprintf(out, "  %s\n", fontbake.FormatLeak(l))
		}
	}
	if len(gameLeaks) == 0 {
		fmt.Fprintf(out, "[font-bake] 漏れ無し — %s へ %d 本書いた\n", outDir, len(atlases))
		return 0
	}
	w := errOut
	if !o.gate {
		w = out
	}
	fmt.Fprintf(w, "fge font-bake: 字の漏れ %d 字 — どのフォントのアトラスにも無い（フォントがその字を持たない。ブラウザでは出ない）:\n", len(gameLeaks))
	for _, l := range gameLeaks {
		fmt.Fprintf(w, "  %s\n", fontbake.FormatLeak(l))
	}
	fmt.Fprintln(w, "  直し方: 字を持つフォントに替えるか project.json の fonts に足す・その字を書き換える。"+
		"開発の道具だけが使う所なら --dev-dir <その所> を渡す。")
	if !o.gate {
		return 0
	}
	return 1
}

func newFontBakeRunner(game string) (fontbake.Runner, error) {
	engine, _ := status.FindEngineDir(game, "mk/game.mk")
	if engine == "" {
		engine = repoRoot()
	}
	flixJar := os.Getenv("FLIX_JAR")
	if flixJar == "" {
		cands := []string{filepath.Join(engine, "bin", "flix.jar"), filepath.Join(repoRoot(), "bin", "flix.jar")}
		if gitOut, err := exec.Command("git", "-C", engine, "rev-parse", "--path-format=absolute", "--git-common-dir").Output(); err == nil {
			cands = append(cands, filepath.Join(filepath.Dir(strings.TrimSpace(string(gitOut))), "bin", "flix.jar"))
		}
		for _, c := range cands {
			if info, err := os.Stat(c); err == nil && info.Mode().IsRegular() {
				flixJar = c
				break
			}
		}
	}
	if flixJar == "" {
		return fontbake.Runner{}, fmt.Errorf("flix.jar が見つからない（engine の bin/flix.jar を置くか FLIX_JAR で名指す）")
	}
	java, err := javacmd.Resolve(engine)
	if err != nil {
		return fontbake.Runner{}, err
	}
	return fontbake.Runner{GameDir: game, FlixJar: flixJar, Java: java, Log: os.Stderr}, nil
}

// bakeInputs は生成した物が古いかを決める指紋（fontbake.InputsKey）を今の jar の指紋で作る。
func bakeInputs(runner fontbake.Runner, game, glyphs string, cs *fontbake.Charset) (string, error) {
	jarKey, err := runner.JarKey()
	if err != nil {
		return "", err
	}
	return fontbake.InputsKey(game, jarKey, glyphs, cs.WithASCII())
}

// writeFontsManifest は fonts.json を書く。inputs が空なら指紋を書かない（次の --if-stale は作り直す）。
func writeFontsManifest(outDir string, atlases []*fontbake.Atlas, charset int, inputs string) error {
	type entry struct {
		Name        string `json:"name"`
		File        string `json:"file"`
		TextureName string `json:"textureName"`
		Side        int    `json:"side"`
		Glyphs      int    `json:"glyphs"`
		Bytes       int64  `json:"bytes"`
	}
	m := struct {
		Fonts   []entry `json:"fonts"`
		Charset int     `json:"charset"`
		Inputs  string  `json:"inputs,omitempty"`
	}{Fonts: []entry{}, Charset: charset, Inputs: inputs}
	for _, a := range atlases {
		m.Fonts = append(m.Fonts, entry{a.Name, filepath.Base(a.Path), "font_" + a.Name, a.Side, len(a.Glyphs), a.Bytes})
	}
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(outDir, "fonts.json"), append(data, '\n'), 0o644)
}

func gzipSize(path string) int64 {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write(data)
	_ = zw.Close()
	return int64(buf.Len())
}
