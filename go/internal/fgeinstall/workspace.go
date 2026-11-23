package fgeinstall

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// WorkspaceAgentsSrc は engine の根から見た、ワークスペースのフォルダへ写す AGENTS.md。
const WorkspaceAgentsSrc = "agents-pack/workspace/AGENTS.md"

// workspaceClaudeMD はゲームの CLAUDE.md と同じ形の 1 行。
const workspaceClaudeMD = "@AGENTS.md\n"

// WorkspaceSync は SyncWorkspaceFolder の結果。
type WorkspaceSync struct {
	Dir           string `json:"dir"`
	EngineVersion string `json:"engineVersion,omitempty"`
	Updated       bool   `json:"updated"`
	// MissingSource は手元の最新の engine が agents-pack/workspace/AGENTS.md を持たない（それより前の版）。
	MissingSource bool `json:"missingSource,omitempty"`
}

// SyncWorkspaceFolder はワークスペースのフォルダ（workspace.json の dir）を作り、手元の最新の engine の
// agents-pack/workspace/AGENTS.md を写し、CLAUDE.md を @AGENTS.md の 1 行で置く。中身が同じなら書かない。
// create が false の時は、フォルダが既にある時だけ写し直す。
func SyncWorkspaceFolder(create bool) (WorkspaceSync, error) {
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		return WorkspaceSync{}, fmt.Errorf("workspace.json を読めません: %v", err)
	}
	res := WorkspaceSync{Dir: ws.Dir}
	if info, err := os.Stat(ws.Dir); err != nil || !info.IsDir() {
		if !create {
			return res, nil
		}
		if err := os.MkdirAll(ws.Dir, 0o755); err != nil {
			return res, fmt.Errorf("%s を作れません: %v", ws.Dir, err)
		}
		res.Updated = true
	}
	version := NewestInstalled()
	if version == "" {
		return res, nil
	}
	res.EngineVersion = version
	src, err := os.ReadFile(filepath.Join(fgehome.EngineDir(version), WorkspaceAgentsSrc))
	if errors.Is(err, os.ErrNotExist) {
		// WhyNot: fge に文を埋め込んで代わりに置かない — engine の版と合わない書き方を Claude に読ませることになる。
		res.MissingSource = true
		return res, nil
	}
	if err != nil {
		return res, err
	}
	for _, f := range []struct {
		name string
		body []byte
	}{{"AGENTS.md", src}, {"CLAUDE.md", []byte(workspaceClaudeMD)}} {
		changed, err := writeIfDifferent(filepath.Join(ws.Dir, f.name), f.body)
		if err != nil {
			return res, err
		}
		res.Updated = res.Updated || changed
	}
	return res, nil
}

func writeIfDifferent(path string, body []byte) (bool, error) {
	if old, err := os.ReadFile(path); err == nil && bytes.Equal(old, body) {
		return false, nil
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return false, fmt.Errorf("%s を書けません: %v", path, err)
	}
	return true, nil
}
