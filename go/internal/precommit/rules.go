package precommit

// 規約データ (bin/lint-rules/precommit.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "precommit.json")

// Matcher はステージしたパスの絞り込み。1 つの Matcher の中は AND
// （suffixes と prefixes を両方書いたら両方に当たるパスだけ）、AnyOf は OR。
// exceptPrefixes に当たるパスは、ほかの条件に当たっても外す。
type Matcher struct {
	AnyOf          []Matcher `json:"anyOf"`
	Suffixes       []string  `json:"suffixes"`
	Prefixes       []string  `json:"prefixes"`
	ExceptPrefixes []string  `json:"exceptPrefixes"`
	Substrings     []string  `json:"substrings"`
	Basenames      []string  `json:"basenames"`
}

// Match は 1 つのパスが当たるかを返す。
func (m Matcher) Match(path string) bool {
	if anyPrefix(path, m.ExceptPrefixes) {
		return false
	}
	if len(m.AnyOf) > 0 {
		for _, sub := range m.AnyOf {
			if sub.Match(path) {
				return true
			}
		}
		return false
	}
	if len(m.Suffixes) > 0 && !anySuffix(path, m.Suffixes) {
		return false
	}
	if len(m.Prefixes) > 0 && !anyPrefix(path, m.Prefixes) {
		return false
	}
	if len(m.Substrings) > 0 && !anySubstring(path, m.Substrings) {
		return false
	}
	if len(m.Basenames) > 0 && !anyBasename(path, m.Basenames) {
		return false
	}
	return true
}

func anySuffix(path string, list []string) bool {
	for _, s := range list {
		if strings.HasSuffix(path, s) {
			return true
		}
	}
	return false
}

func anyPrefix(path string, list []string) bool {
	for _, s := range list {
		if strings.HasPrefix(path, s) {
			return true
		}
	}
	return false
}

func anySubstring(path string, list []string) bool {
	for _, s := range list {
		if strings.Contains(path, s) {
			return true
		}
	}
	return false
}

// anyBasename はパスの末尾の名前が一覧のどれかか。
// WhyNot: filepath.Base を使わないのは、末尾が / のパスで手前の名前を拾ってしまい、
// ディレクトリを同名のファイルと取り違えるため。
func anyBasename(path string, list []string) bool {
	for _, s := range list {
		if path == s || strings.HasSuffix(path, "/"+s) {
			return true
		}
	}
	return false
}

// Check は 1 本の検査の呼び方。
type Check struct {
	ID    string   `json:"id"`
	Sub   string   `json:"sub"`
	Flags []string `json:"flags"`
	Pass  string   `json:"pass"`
	When  Matcher  `json:"when"`
}

// StagedImages は今回ステージした画像を裁くときの決まり。
type StagedImages struct {
	Sub                 string   `json:"sub"`
	ImageExts           []string `json:"imageExts"`
	GalleryPrefix       string   `json:"galleryPrefix"`
	GalleryMaxFileBytes int64    `json:"galleryMaxFileBytes"`
	AllowedPrefixes     []string `json:"allowedPrefixes"`
	AllowedSubstrings   []string `json:"allowedSubstrings"`
	AllowedSuffixes     []string `json:"allowedSuffixes"`
	AllowedExact        []string `json:"allowedExact"`
}

// Allowed は追跡してよい置き場か。
func (s StagedImages) Allowed(path string) bool {
	if anyPrefix(path, s.AllowedPrefixes) {
		return true
	}
	if anySuffix(path, s.AllowedSuffixes) {
		return true
	}
	for _, e := range s.AllowedExact {
		if path == e {
			return true
		}
	}
	return anySubstring(path, s.AllowedSubstrings)
}

// IsImage は拡張子が画像か（大文字小文字は区別しない）。
func (s StagedImages) IsImage(path string) bool {
	return anySuffix(strings.ToLower(path), s.ImageExts)
}

// DocsSync は配線検査 (make check-docs-sync) を走らせる条件。
type DocsSync struct {
	Target string  `json:"target"`
	When   Matcher `json:"when"`
}

// LocalGate はゲーム固有の検査を走らせる make の口。ゲームの Makefile に target が
// 在るときだけ、ステージしたファイルを 1 行 1 つで書いた一時ファイルのパスを STAGED_FILE に渡して流す。
// WhyNot: 固有の検査（例: ドット絵の色の門）を precommit.json の checks に足さないのは、
// あれが engine から配る共通の表で、ゲームごとの道具（python の台本など）を名指しできないため。
type LocalGate struct {
	Target string `json:"target"`
}

// FailOpen は make が使えないときに飛ばす旨を知らせる文面。
type FailOpen struct {
	MakeMissing           string `json:"makeMissing"`
	TargetMissing         string `json:"targetMissing"`
	TargetMissingExitCode int    `json:"targetMissingExitCode"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	StagedImages StagedImages `json:"stagedImages"`
	Checks       []Check      `json:"checks"`
	DocsSync     DocsSync     `json:"docsSync"`
	LocalGate    LocalGate    `json:"localGate"`
	FailOpen     FailOpen     `json:"failOpen"`
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、規約ファイルを消しただけで
// 検査の並びや置き場の決まりが別物に化けたまま緑になる穴を作らないため。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var r Rules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", path, err)
	}
	missing := ""
	switch {
	case len(r.Checks) == 0:
		missing = "checks"
	case len(r.StagedImages.ImageExts) == 0:
		missing = "stagedImages.imageExts"
	case r.StagedImages.GalleryMaxFileBytes == 0:
		missing = "stagedImages.galleryMaxFileBytes"
	case r.DocsSync.Target == "":
		missing = "docsSync.target"
	case r.FailOpen.MakeMissing == "":
		missing = "failOpen.makeMissing"
	}
	if missing != "" {
		return nil, fmt.Errorf("規約ファイルに %s がありません (%s)", missing, path)
	}
	for _, c := range r.Checks {
		if c.Pass != "matched" && c.Pass != "none" {
			return nil, fmt.Errorf("checks[%s].pass は matched か none です (%s)", c.ID, path)
		}
	}
	return &r, nil
}
