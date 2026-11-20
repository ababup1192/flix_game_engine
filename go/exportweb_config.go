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
