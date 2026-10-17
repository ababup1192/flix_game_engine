// Package lintconf は「エンジンの規約データ + ゲームの除外」を読む lint の共通部。
//
// 規約は bin/lint-rules/<名前>.json (エンジンが配る・追従で上書きされる)、ゲーム固有の
// 除外は bin/lint-rules/<名前>.local.json (配り元に無いので sync で残る) の {"exempt": {...}}。
// 除外の鍵は "パス::何か"、値は残す理由 1 行。
//
// WhyNot: doc-shape・makefile-dup・verb-names でそれぞれ読み込みを書かないのは、
// 「local に規約本体を書けない」「同じ鍵を両方に書いたら止める」の決まりが 3 つで
// ずれないようにするため。既にある lint (forbid・quadratic…) は自前のまま。
package lintconf

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Paths は規約ファイルとゲームの除外ファイルの置き場 (リポの根からの相対)。
func Paths(name string) (rules, local string) {
	return filepath.Join("bin", "lint-rules", name+".json"),
		filepath.Join("bin", "lint-rules", name+".local.json")
}

// Exempt は除外の表。From は鍵がどちらのファイルに書いてあったか。
type Exempt struct {
	Why  map[string]string
	From map[string]string
}

// Load は <名前>.json を v へ読み、両方のファイルの exempt を足して返す。
// 規約ファイルが読めなければエラー (空の規約で黙って通さない)。
func Load(root, name string, v any) (*Exempt, error) {
	rulesRel, localRel := Paths(name)
	data, err := os.ReadFile(filepath.Join(root, rulesRel))
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", rulesRel, err)
	}
	ex := &Exempt{Why: map[string]string{}, From: map[string]string{}}
	for i, rel := range []string{rulesRel, localRel} {
		body, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			if i == 1 && errors.Is(err, os.ErrNotExist) {
				continue
			}
			return nil, fmt.Errorf("読めません (%s): %v", rel, err)
		}
		var f struct {
			Exempt map[string]string `json:"exempt"`
		}
		if err := json.Unmarshal(body, &f); err != nil {
			return nil, fmt.Errorf("JSON として壊れています (%s): %v", rel, err)
		}
		for k, why := range f.Exempt {
			if !strings.Contains(k, "::") || strings.TrimSpace(why) == "" {
				return nil, fmt.Errorf("%s の除外 %q: 鍵は \"パス::何か\"、値は残す理由 1 行です", rel, k)
			}
			if _, dup := ex.Why[k]; dup {
				return nil, fmt.Errorf("除外 %s が %s と %s の両方にあります", k, rulesRel, localRel)
			}
			ex.Why[k] = why
			ex.From[k] = filepath.ToSlash(rel)
		}
	}
	return ex, nil
}

// Stale は除外のうち、もう鳴らない物。このリポに無いファイルの鍵は数えない
// (エンジンの除外がゲームにも同じ規約ファイルで配られ、そこでは必ず空振りするため)。
func (e *Exempt) Stale(root string, live map[string]bool) []string {
	var out []string
	for k := range e.Why {
		p := k[:strings.Index(k, "::")]
		info, err := os.Stat(filepath.Join(root, filepath.FromSlash(p)))
		if !live[k] && err == nil && info.Mode().IsRegular() {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// Args は引数を「--all か」と名指しのファイル (根からの相対・/ 区切り) に分ける。
// --all なら git が知っているファイルを全部返す (lib/ と build/ は外す)。
func Args(root string, args []string) (all bool, files []string, err error) {
	for _, a := range args {
		switch {
		case a == "--all":
			all = true
		case !strings.HasPrefix(a, "--"):
			files = append(files, RelTo(root, a))
		}
	}
	if !all {
		return false, files, nil
	}
	cmd := exec.Command("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	cmd.Dir = root
	body, err := cmd.Output()
	if err != nil {
		return true, nil, fmt.Errorf("git ls-files が失敗しました: %v", err)
	}
	files = nil
	for _, p := range strings.Split(string(body), "\x00") {
		if p != "" && !strings.HasPrefix(p, "lib/") && !strings.HasPrefix(p, "build/") {
			files = append(files, p)
		}
	}
	sort.Strings(files)
	return true, files, nil
}

// RelTo は p を根からの相対 (/ 区切り) にする。
func RelTo(root, p string) string {
	if filepath.IsAbs(p) {
		if rel, err := filepath.Rel(root, p); err == nil {
			return filepath.ToSlash(rel)
		}
	}
	return filepath.ToSlash(filepath.Clean(p))
}

// HasPrefixAny は s が一覧のどれかで始まるか。
func HasPrefixAny(s string, list []string) bool {
	for _, p := range list {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}
