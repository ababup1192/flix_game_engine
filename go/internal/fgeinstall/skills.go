package fgeinstall

import (
	"fmt"
	"io"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
	"github.com/ababup1192/flix_game_engine/go/internal/syncagents"
)

// SkillsRefresh は RefreshFollowLatestSkills の 1 ゲームぶんの結果（写したスキルがあった物だけ）。
type SkillsRefresh struct {
	Game   string   `json:"game"`
	Dir    string   `json:"dir"`
	Skills []string `json:"skills,omitempty"`
	Error  string   `json:"error,omitempty"`
}

// RefreshFollowLatestSkills は workspace.json の全部のゲームの版によらないスキル（manifest の followLatest）を、
// 手元の最新の engine の物へ写し直す。返すのは使った engine の版と、写した・写せなかったゲーム。
// WhyNot: 1 本のゲームで写せなくても止めない — 他のゲームの写し直しまで止めると、どれも古いまま残る。
func RefreshFollowLatestSkills() (string, []SkillsRefresh, error) {
	version := NewestInstalled()
	if version == "" {
		return "", nil, nil
	}
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		return version, nil, fmt.Errorf("workspace.json を読めません: %v", err)
	}
	root := fgehome.EngineDir(version)
	var res []SkillsRefresh
	for _, g := range ws.Games {
		skills, err := syncagents.RefreshFollowLatest(root, g.Dir, version)
		switch {
		case err != nil:
			res = append(res, SkillsRefresh{Game: g.Name, Dir: g.Dir, Error: err.Error()})
		case len(skills) > 0:
			res = append(res, SkillsRefresh{Game: g.Name, Dir: g.Dir, Skills: skills})
		}
	}
	return version, res, nil
}

// ReportFollowLatestSkills は RefreshFollowLatestSkills を流して、写したゲームを 1 行ずつ w へ書く。
func ReportFollowLatestSkills(w io.Writer, prefix string) {
	version, res, err := RefreshFollowLatestSkills()
	if err != nil {
		fmt.Fprintf(w, "%s ゲームのスキルを写し直せませんでした: %v\n", prefix, err)
		return
	}
	for _, r := range res {
		if r.Error != "" {
			fmt.Fprintf(w, "%s %s のスキルを写し直せませんでした: %s\n", prefix, r.Game, r.Error)
			continue
		}
		fmt.Fprintf(w, "%s %s のスキル（%s）を engine %s の物に新しくしました（ゲームのリポでコミットしてください）\n",
			prefix, r.Game, strings.Join(r.Skills, "・"), version)
	}
}
