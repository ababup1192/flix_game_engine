package main

// audio — 音の名前が 3 つの置き場 (書き出し名 / project.json / コード) でそろっているかを
// 検査するゲート。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var audioExcludedDirs = map[string]bool{
	"build": true, "lib": true, ".git": true, "gallery": true,
	".devbox": true, "node_modules": true, "testdata": true,
}

var callRe = regexp.MustCompile(
	`(?:AudioStreamPlayer|GameEngine\.Audio|Audio)\.` +
		`(?:play|stop|playAudio|stopAudio|setVolume|setPitch|setLooping)\(\s*"([^"]+)"`)

var sfxTupleRe = regexp.MustCompile(`\(\s*"([^"]+)"\s*,`)
var sfxDirRe = regexp.MustCompile(`renderSet\([^)"]*"([^"]+)"`)

type flixFile struct {
	rel  string
	text string
}

func flixFiles(gameDir string) []flixFile {
	var found []flixFile
	var rec func(dir string)
	rec = func(dir string) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		var dirs, files []string
		for _, e := range entries {
			if e.IsDir() {
				if !audioExcludedDirs[e.Name()] {
					dirs = append(dirs, e.Name())
				}
			} else if strings.HasSuffix(e.Name(), ".flix") {
				files = append(files, e.Name())
			}
		}
		sort.Strings(files)
		for _, f := range files {
			full := filepath.Join(dir, f)
			data, err := os.ReadFile(full)
			if err != nil {
				data = nil
			}
			rel, _ := filepath.Rel(gameDir, full)
			found = append(found, flixFile{rel, string(data)})
		}
		sort.Strings(dirs)
		for _, d := range dirs {
			rec(filepath.Join(dir, d))
		}
	}
	rec(filepath.Join(gameDir, "src"))
	return found
}

// renderedPathsOf は renderSet が生成する WAV の game_dir 相対パスを集める。
func renderedPathsOf(files []flixFile) map[string]bool {
	rendered := map[string]bool{}
	for _, f := range files {
		i := strings.Index(f.text, "renderSet")
		if i < 0 {
			continue
		}
		tail := f.text[i:]
		outDir := "assets/sfx"
		if m := sfxDirRe.FindStringSubmatch(tail); m != nil {
			outDir = m[1]
		}
		for _, m := range sfxTupleRe.FindAllStringSubmatch(tail, -1) {
			rendered[outDir+"/"+m[1]+".wav"] = true
		}
	}
	return rendered
}

func isRenderFile(rel string) bool {
	sep := string(os.PathSeparator)
	return strings.Contains(rel, sep+"render"+sep) ||
		strings.HasPrefix(rel, "src"+sep+"render"+sep)
}

func checkAudioGame(root, game string, problems, warnings *[]string) int {
	gameDir := filepath.Join(root, game)
	project, ok := pxlib.AsObject(pxlib.LoadJSON(filepath.Join(gameDir, "project.json")))
	if !ok {
		return 0
	}
	soundsAny, ok := project["sounds"].([]any)
	if !ok {
		return 0
	}

	files := flixFiles(gameDir)
	var gameFiles []flixFile
	for _, f := range files {
		if !isRenderFile(f.rel) {
			gameFiles = append(gameFiles, f)
		}
	}
	rendered := renderedPathsOf(files)
	declared := map[string]string{}
	for _, entryAny := range soundsAny {
		entry, ok := pxlib.AsObject(entryAny)
		if !ok {
			continue
		}
		name, okN := entry["name"].(string)
		path, okP := entry["path"].(string)
		if !okN || !okP {
			continue
		}
		declared[name] = path
		stem := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		if stem != name {
			*problems = append(*problems, fmt.Sprintf(
				"%s/project.json: 論理名 \"%s\" と WAV の茎 \"%s\" が違う"+
					" (path=%s。名前は 1 本にそろえる)", game, name, stem, path))
		}
		if !pxlib.HasFile(filepath.Join(gameDir, path)) && !rendered[path] {
			*problems = append(*problems, fmt.Sprintf(
				"%s/project.json: \"%s\" の %s が無く、書き出しでも作られない", game, name, path))
		}
	}

	declaredPaths := map[string]bool{}
	for _, p := range declared {
		declaredPaths[p] = true
	}
	renderedList := make([]string, 0, len(rendered))
	for p := range rendered {
		renderedList = append(renderedList, p)
	}
	sort.Strings(renderedList)
	for _, path := range renderedList {
		if !declaredPaths[path] {
			*problems = append(*problems, fmt.Sprintf(
				"%s: 書き出しが作る %s がどの sounds の path からも参照されない", game, path))
		}
	}

	for _, f := range gameFiles {
		for _, m := range callRe.FindAllStringSubmatch(f.text, -1) {
			if _, ok := declared[m[1]]; !ok {
				*problems = append(*problems, fmt.Sprintf(
					"%s/%s: 再生呼び出しの \"%s\" が project.json の sounds に無い",
					game, f.rel, m[1]))
			}
		}
	}

	texts := make([]string, len(gameFiles))
	for i, f := range gameFiles {
		texts[i] = f.text
	}
	allCode := strings.Join(texts, "\n")
	names := make([]string, 0, len(declared))
	for n := range declared {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		if !strings.Contains(allCode, "\""+name+"\"") {
			*warnings = append(*warnings, fmt.Sprintf(
				"%s: 論理名 \"%s\" がコードのどこにもリテラルで現れない"+
					" (動的に組んでいるなら無視してよい)", game, name))
		}
	}
	return len(declared)
}

// audioResult は --json 用のまとめ。
type audioResult struct {
	Problems []string `json:"problems"`
	Warnings []string `json:"warnings"`
	Sounds   int      `json:"sounds"`
	Exit     int      `json:"exit"`
}

func runAudio(out *strings.Builder, root string, asJSON bool) int {
	var problems, warnings []string
	soundCount := 0
	for _, game := range pxlib.GameDirsOf(root, func() bool { return pxlib.HasFile(filepath.Join(root, "project.json")) }) {
		soundCount += checkAudioGame(root, game, &problems, &warnings)
	}

	exit := 0
	if len(problems) > 0 {
		exit = 1
	}
	if asJSON {
		emitJSON(out, audioResult{orEmpty(problems), orEmpty(warnings), soundCount, exit})
		return exit
	}
	for _, line := range warnings {
		fmt.Fprintf(out, "注意: %s\n", line)
	}
	if exit == 1 {
		for _, line := range problems {
			fmt.Fprintln(out, line)
		}
		fmt.Fprintf(out, "NG: %d 個の音名のずれ (sounds %d 件を検査)\n", len(problems), soundCount)
		return 1
	}
	fmt.Fprintf(out, "OK: sounds %d 件すべて 3 つの置き場 (書き出し名 / project.json / コード) でそろっている\n", soundCount)
	return 0
}
