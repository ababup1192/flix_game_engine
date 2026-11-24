package fgeinstall

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fetchengine"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

const (
	exitDone     = 0
	exitProblem  = 1
	exitBadUsage = 2
)

const enginesUsage = `使い方: fge engines                     手元の engine の版と、Release の最新
        fge engines install <版|latest>   engine と、その版の JDK を取る（あれば何もしない）
        fge engines remove <版>           engine を消す（使っているゲームがあれば止める）`

// EngineEntry は fge engines の 1 行。
type EngineEntry struct {
	Version      string `json:"version"`
	Dir          string `json:"dir"`
	JDK          string `json:"jdk,omitempty"`
	JDKInstalled bool   `json:"jdkInstalled,omitempty"`
}

// ListResult は fge engines の結果。
type ListResult struct {
	Installed   []EngineEntry `json:"installed"`
	Latest      string        `json:"latest,omitempty"`
	LatestError string        `json:"latestError,omitempty"`
	Newer       bool          `json:"newer"`
}

// RunEngines は fge engines の本体。
func RunEngines(out, errOut *strings.Builder, args []string, asJSON bool, e *Env) int {
	if len(args) == 0 {
		return runList(out, errOut, asJSON, e)
	}
	switch args[0] {
	case "install":
		if len(args) != 2 {
			fmt.Fprintln(errOut, enginesUsage)
			return exitBadUsage
		}
		res, err := e.Install(args[1])
		if err != nil {
			fmt.Fprintf(errOut, "!! %v%s\n", err, diskHint(err))
			return exitProblem
		}
		if asJSON {
			return emit(out, res)
		}
		writeInstallSummary(out, res)
		return exitDone
	case "remove":
		if len(args) != 2 {
			fmt.Fprintln(errOut, enginesUsage)
			return exitBadUsage
		}
		res, err := e.Remove(args[1])
		if err != nil {
			fmt.Fprintf(errOut, "!! %v\n", err)
			return exitProblem
		}
		if asJSON {
			return emit(out, res)
		}
		fmt.Fprintf(out, "[fge engines] engine %s を消しました\n", res.Version)
		if res.RemovedJDK != "" {
			fmt.Fprintf(out, "[fge engines] 他の版が使っていない JDK %s も消しました\n", res.RemovedJDK)
		}
		return exitDone
	case "-h", "--help", "help":
		fmt.Fprintln(out, enginesUsage)
		return exitDone
	}
	fmt.Fprintln(errOut, enginesUsage)
	return exitBadUsage
}

func writeInstallSummary(out *strings.Builder, res InstallResult) {
	if res.EngineWasSet {
		fmt.Fprintf(out, "[fge engines] engine %s は既にあります: %s\n", res.Version, relHome(res.EngineDir))
	} else {
		fmt.Fprintf(out, "[fge engines] engine %s を置きました: %s\n", res.Version, relHome(res.EngineDir))
	}
	if res.JDK == "" {
		return
	}
	if res.JDKWasSet {
		fmt.Fprintf(out, "[fge engines] JDK %s は既にあります: %s\n", res.JDK, relHome(res.JDKDir))
	} else {
		fmt.Fprintf(out, "[fge engines] JDK %s を置きました: %s\n", res.JDK, relHome(res.JDKDir))
	}
}

func runList(out, errOut *strings.Builder, asJSON bool, e *Env) int {
	res := ListResult{Installed: []EngineEntry{}}
	for _, v := range InstalledVersions() {
		entry := EngineEntry{Version: v, Dir: fgehome.EngineDir(v)}
		if spec, ok, _ := fgehome.ReadJDKSpec(entry.Dir); ok {
			entry.JDK = spec.Name()
			entry.JDKInstalled = fgehome.IsComplete(spec.Dir())
		}
		res.Installed = append(res.Installed, entry)
	}
	latest, ok, err := e.RefreshLatest(false)
	if ok {
		res.Latest = latest.Version
	}
	if err != nil {
		res.LatestError = err.Error()
	}
	newest := ""
	if n := len(res.Installed); n > 0 {
		newest = res.Installed[n-1].Version
	}
	res.Newer = res.Latest != "" && (newest == "" || fetchengine.IsNewer(newest, res.Latest))
	if asJSON {
		return emit(out, res)
	}
	if len(res.Installed) == 0 {
		fmt.Fprintf(out, "手元の engine: ありません（%s）\n", relHome(fgehome.EnginesDir()))
	} else {
		fmt.Fprintln(out, "手元の engine:")
		for _, en := range res.Installed {
			jdk := ""
			switch {
			case en.JDK != "" && en.JDKInstalled:
				jdk = "  JDK " + en.JDK
			case en.JDK != "":
				jdk = "  JDK " + en.JDK + " が無い → fge engines install " + en.Version
			}
			fmt.Fprintf(out, "  %s%s\n", en.Version, jdk)
		}
	}
	switch {
	case res.Latest == "":
		fmt.Fprintf(out, "Release の最新: 引けませんでした（%s）\n", res.LatestError)
	case res.Newer:
		fmt.Fprintf(out, "Release の最新: %s（新しい版が出ています → fge engines install %s）\n", res.Latest, res.Latest)
	default:
		fmt.Fprintf(out, "Release の最新: %s\n", res.Latest)
	}
	if res.Latest != "" && res.LatestError != "" {
		fmt.Fprintf(errOut, "[fge engines] Release に問い合わせられなかったので、前の控えを出しています（%s）\n", res.LatestError)
	}
	return exitDone
}

// RunSelfUpdate は fge self-update の本体。
func RunSelfUpdate(out, errOut *strings.Builder, args []string, asJSON bool, e *Env) int {
	if len(args) != 0 {
		fmt.Fprintln(errOut, "使い方: fge self-update")
		return exitBadUsage
	}
	res, err := e.SelfUpdate()
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem
	}
	if asJSON {
		return emit(out, res)
	}
	if res.AlreadyThere {
		fmt.Fprintf(out, "[fge self-update] %s は既に最新（%s）です\n", relHome(res.Path), res.Version)
	} else {
		fmt.Fprintf(out, "[fge self-update] %s を %s に差し替えました\n", relHome(res.Path), res.Version)
	}
	return exitDone
}

func emit(out *strings.Builder, v any) int {
	b, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintf(out, "{\"error\":%q}\n", err.Error())
		return exitProblem
	}
	out.Write(b)
	out.WriteString("\n")
	return exitDone
}
