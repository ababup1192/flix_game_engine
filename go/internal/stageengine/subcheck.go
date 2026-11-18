package stageengine

// 組み上げたバンドルの検査データ (bin/lint-rules/*.json) が名乗るサブコマンドが、
// 一緒に入れた bin/fge-go に実在するかを照合する。
//
// WhyNot: 規約データの新しさだけを見ないのは、この 2 つが別々の経路で入るため
// (JSON は git の作業ツリーから・バイナリは bin/dist から)。片方だけ新しいと、
// 配った先は「宣言はあるのに入口が無い」状態になり、precommit が毎回 exit 2 になる。

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// checkStagedSubs は照合して、足りない入口があれば理由を errOut へ書いて false を返す。
func checkStagedSubs(out, errOut *strings.Builder, opts Options) bool {
	// 走らせる先の OS が違うバイナリは、ここでは起こせない (Windows 版を mac で組むとき)。
	if opts.Windows && runtime.GOOS != "windows" {
		fmt.Fprintln(out, "-- 入口の照合: 飛ばしました (Windows 版はこの OS で起こせません)")
		return true
	}
	ext := ""
	if opts.Windows {
		ext = ".exe"
	}
	bin := filepath.Join(opts.Out, "bin", "fge-go"+ext)
	if opts.AllPlatforms {
		// WhyNot: bin/fge-go を決め打ちで起こさない — 中身は darwin/arm64 向けで、CI (linux) では走らない。
		// 照合するのは同じソースから組んだ 5 種の 1 つなので、組んでいるこの機械の物で足りる。
		host, err := hostToolIn(opts.Out)
		if err != nil {
			fmt.Fprintf(errOut, "[stage-engine] 入口の照合ができません: %v\n", err)
			return false
		}
		bin = host
	}
	if _, err := os.Stat(bin); err != nil {
		fmt.Fprintf(errOut, "[stage-engine] 入口の照合ができません: %s がありません\n", bin)
		return false
	}

	declared, err := declaredSubs(filepath.Join(opts.Out, "bin", "lint-rules"))
	if err != nil {
		fmt.Fprintf(errOut, "[stage-engine] 入口の照合ができません: %v\n", err)
		return false
	}
	known, err := binarySubs(bin, opts.Out)
	if err != nil {
		fmt.Fprintf(errOut, "[stage-engine] 入口の照合ができません: %v\n", err)
		return false
	}

	var missing []string
	for _, sub := range declared {
		if !known[sub] {
			missing = append(missing, sub)
		}
	}
	if len(missing) > 0 {
		fmt.Fprintf(errOut,
			"[stage-engine] 検査データが名乗る入口が bin/fge-go にありません: %s\n"+
				"               バイナリが規約データより古いままです。engine で make go-build してから組み直してください。\n",
			strings.Join(missing, " "))
		return false
	}
	fmt.Fprintf(out, "-- 入口の照合: %d 個そろっています\n", len(declared))
	return true
}

// declaredSubs は lint-rules の JSON が名乗るサブコマンド名を集める。
func declaredSubs(rulesDir string) ([]string, error) {
	entries, err := os.ReadDir(rulesDir)
	if err != nil {
		return nil, fmt.Errorf("検査データの場所が読めません (%s): %v", rulesDir, err)
	}
	seen := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(rulesDir, e.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("%s が読めません: %v", path, err)
		}
		var doc any
		if err := json.Unmarshal(raw, &doc); err != nil {
			return nil, fmt.Errorf("%s が JSON として読めません: %v", path, err)
		}
		collectSubs(doc, seen)
	}
	names := make([]string, 0, len(seen))
	for name := range seen {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, nil
}

// collectSubs は入れ子の JSON を辿って "sub" の値を拾う。
func collectSubs(node any, into map[string]bool) {
	switch v := node.(type) {
	case map[string]any:
		if sub, ok := v["sub"].(string); ok && sub != "" {
			into[sub] = true
		}
		for _, child := range v {
			collectSubs(child, into)
		}
	case []any:
		for _, child := range v {
			collectSubs(child, into)
		}
	}
}

// binarySubs は組み上げたバイナリ自身に一覧を言わせる。
func binarySubs(bin, bundle string) (map[string]bool, error) {
	// WhyNot: 絶対パスに直してから渡すのは、下で Dir を移すため。相対パスのままだと
	// 移した先から解決し直され、バンドルの中のバンドルを探しに行く
	// (Studio は絶対パスを渡すので踏まず、engine の make bundle-zip だけが踏む)。
	abs, err := filepath.Abs(bin)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(abs, "--list")
	// WhyNot: バンドルの中で走らせるのは、engineOnly のサブコマンドが
	// 「engine のリポかどうか」で一覧から消えるため。配った先と同じ見え方で照合する。
	root, err := filepath.Abs(bundle)
	if err != nil {
		return nil, err
	}
	cmd.Dir = root
	// WhyNot: 根を FGE_ROOT で渡すのは、bin/dist/ の物は自分の置き場の親の親 (bin/) を根と読むため。
	cmd.Env = append(os.Environ(), "FGE_ROOT="+root)
	stdout, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%s --list が走りません: %v", bin, err)
	}
	known := map[string]bool{}
	for _, line := range strings.Split(string(stdout), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			known[name] = true
		}
	}
	return known, nil
}
