package launcher

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// Project は project.json のうち bin/fge が読む欄（plans/windows.md の 4 節）。ほかの欄（題・画面・editor など）は読まない。
type Project struct {
	// Shots は render の場面の名前（source of truth はゲームの Shots.names。ここは使い方に出す写し）。
	Shots []string `json:"shots"`
	// Prebuild は run・render の前に、入力が出力より新しければ作り直す物（パレットなど）。
	Prebuild []Prebuild `json:"prebuild"`
	// Tasks はゲーム固有の作業（bin/fge task <名前>）。
	Tasks map[string]Task `json:"tasks"`
	// Lint は lint に足す作業の名前（中身は Tasks）。
	Lint []string `json:"lint"`
	// Precommit は pre-commit で流す作業の名前（Tasks の名前か engine の検査の名前）。
	Precommit []string `json:"precommit"`
}

// Prebuild は 1 つの作り置き。Deps のどれかが Out より新しい（か Out が無い）時に Entry を流す。
type Prebuild struct {
	Out   string   `json:"out"`
	Deps  []string `json:"deps"`
	Entry string   `json:"entry"`
}

// Task は 1 つのゲーム固有の作業。Entry（ヘッドレスの入口）か Cmd（コマンドの並び）のどちらか 1 つ。
type Task struct {
	Entry string   `json:"entry"`
	Cmd   []string `json:"cmd"`
	About string   `json:"about"`
	// Env は作業に渡す環境変数の既定（K=V の引数と、外の環境変数が上書きする）。
	Env map[string]string `json:"env"`
	// Window は Entry をウィンドウありで流すか（GL を開く入口）。
	Window bool `json:"window"`
}

// LoadProject は root の project.json の bin/fge の欄。project.json が無ければ空の Project（古いゲームは Makefile のまま動く）。
func LoadProject(root string) (Project, error) {
	var p Project
	b, err := os.ReadFile(filepath.Join(root, "project.json"))
	if os.IsNotExist(err) {
		return p, nil
	}
	if err != nil {
		return p, err
	}
	if err := json.Unmarshal(b, &p); err != nil {
		return p, fmt.Errorf("project.json を読めない: %w", err)
	}
	for name, t := range p.Tasks {
		if (t.Entry == "") == (len(t.Cmd) == 0) {
			return p, fmt.Errorf("project.json の tasks.%s は entry か cmd のどちらか 1 つを書く", name)
		}
	}
	for i, pb := range p.Prebuild {
		if pb.Out == "" || pb.Entry == "" {
			return p, fmt.Errorf("project.json の prebuild[%d] は out と entry を書く", i)
		}
	}
	return p, nil
}

// TaskNames は Tasks の名前を並べた物。
func (p Project) TaskNames() []string {
	names := make([]string, 0, len(p.Tasks))
	for n := range p.Tasks {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Stale は pb の Out を作り直す要があるか。Deps に無いファイルがあれば誤り（make の「作り方の無い前提」と同じく止める）。
func (pb Prebuild) Stale(root string) (bool, error) {
	out, err := os.Stat(filepath.Join(root, pb.Out))
	if err != nil {
		return true, nil
	}
	stale := false
	for _, d := range pb.Deps {
		info, err := os.Stat(filepath.Join(root, d))
		if err != nil {
			return false, fmt.Errorf("prebuild の %s の入力 %s がありません（project.json の prebuild を直す）", pb.Out, d)
		}
		if info.ModTime().After(out.ModTime()) {
			stale = true
		}
	}
	return stale, nil
}
