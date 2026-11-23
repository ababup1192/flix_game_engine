// Package fgehome は、配った engine を使う人の手元の置き場（~/.flix_ge）の場所と、そこに置くファイルの形を決める。
//
//	~/.flix_ge/                    FGE_HOME で替えられる
//	  bin/fge                      全体の fge
//	  engines/<版>/                engine の zip を開いた物（.complete があれば開き終えている）
//	  jdk/<配り元>-<版>/bin/java    JDK
//	  latest.json                  Release の最新の版の控え
//	  workspace.json               ゲームの一覧
//	  .lock                        engines と jdk を書く間の排他
//
// 決まりの本文は plans/onboarding.md の 2.1・2.4・2.5。
package fgehome

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// CompleteMarker は開き終えた engine と JDK のフォルダに置くファイルの名前。
const CompleteMarker = ".complete"

// JDKSpecFile は engine の根から見た、その版の JDK を決めるファイル。
const JDKSpecFile = "mk/jdk.mk"

// Home は置き場の根。FGE_HOME があればそれ、無ければ ~/.flix_ge。
// WhyNot: home が引けない時に空を返さず "." の下にする — 呼び手がパスを組んだ時に根（/engines）を指さないため。
func Home() string {
	if v := os.Getenv("FGE_HOME"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".flix_ge"
	}
	return filepath.Join(home, ".flix_ge")
}

func EnginesDir() string              { return filepath.Join(Home(), "engines") }
func EngineDir(version string) string { return filepath.Join(EnginesDir(), version) }
func JDKRoot() string                 { return filepath.Join(Home(), "jdk") }
func LatestPath() string              { return filepath.Join(Home(), "latest.json") }
func WorkspacePath() string           { return filepath.Join(Home(), "workspace.json") }
func LockPath() string                { return filepath.Join(Home(), ".lock") }
func BinDir() string                  { return filepath.Join(Home(), "bin") }

// IsComplete は dir が開き終えた物か（.complete があるか）。
func IsComplete(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, CompleteMarker))
	return err == nil
}

// IsBundle は engine の根が配った engine か（go/ を持たない）。Makefile:53 の IS_BUNDLE と同じ見方。
func IsBundle(engineDir string) bool {
	if engineDir == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(engineDir, "Makefile")); err != nil {
		return false
	}
	_, err := os.Stat(filepath.Join(engineDir, "go"))
	return errors.Is(err, os.ErrNotExist)
}

// JDKSpec は mk/jdk.mk の中身。
type JDKSpec struct {
	Vendor  string
	Version string
}

// Name は置き場のフォルダ名（<配り元>-<版>）。
func (s JDKSpec) Name() string { return s.Vendor + "-" + s.Version }

// Dir は置き場の中の JDK のフォルダ。
func (s JDKSpec) Dir() string { return filepath.Join(JDKRoot(), s.Name()) }

// Java は置き場の中の java の実行ファイル。
func (s JDKSpec) Java() string {
	name := "java"
	if os.PathSeparator == '\\' {
		name = "java.exe"
	}
	return filepath.Join(s.Dir(), "bin", name)
}

// ReadJDKSpec は engine の根の mk/jdk.mk を読む。無ければ ok=false（clone した engine の大半と、mk/jdk.mk より前の版）。
// 読む形は `FGE_JDK_VENDOR := zulu` と `FGE_JDK_VERSION := 25.0.3` の 2 行（`=`・`?=` も受ける）。
func ReadJDKSpec(engineDir string) (JDKSpec, bool, error) {
	f, err := os.Open(filepath.Join(engineDir, JDKSpecFile))
	if errors.Is(err, os.ErrNotExist) {
		return JDKSpec{}, false, nil
	}
	if err != nil {
		return JDKSpec{}, false, err
	}
	defer f.Close()
	return parseJDKSpec(f)
}

func parseJDKSpec(f io.Reader) (JDKSpec, bool, error) {
	var spec JDKSpec
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		key, val, ok := makeAssignment(sc.Text())
		if !ok {
			continue
		}
		switch key {
		case "FGE_JDK_VENDOR":
			spec.Vendor = val
		case "FGE_JDK_VERSION":
			spec.Version = val
		}
	}
	if err := sc.Err(); err != nil {
		return JDKSpec{}, false, err
	}
	if spec.Vendor == "" || spec.Version == "" {
		return JDKSpec{}, false, errors.New(JDKSpecFile + " に FGE_JDK_VENDOR と FGE_JDK_VERSION の両方が要ります")
	}
	return spec, true, nil
}

// makeAssignment は make の `KEY := 値` の 1 行を読む（注釈の行・空の行は ok=false）。
func makeAssignment(line string) (key, val string, ok bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", "", false
	}
	for _, op := range []string{":=", "?=", "="} {
		if i := strings.Index(line, op); i > 0 {
			key = strings.TrimSpace(line[:i])
			val = strings.TrimSpace(line[i+len(op):])
			if j := strings.Index(val, "#"); j >= 0 {
				val = strings.TrimSpace(val[:j])
			}
			return key, val, key != "" && !strings.ContainsAny(key, " \t")
		}
	}
	return "", "", false
}

// Latest は latest.json の形。
type Latest struct {
	Version   string    `json:"version"`
	CheckedAt time.Time `json:"checkedAt"`
}

// ReadLatest は控えを読む。無い・壊れている時は ok=false（止めない）。
func ReadLatest() (Latest, bool) {
	b, err := os.ReadFile(LatestPath())
	if err != nil {
		return Latest{}, false
	}
	var l Latest
	if json.Unmarshal(b, &l) != nil || l.Version == "" {
		return Latest{}, false
	}
	return l, true
}

// WriteLatest は控えを tmp に書いてから差し替える。
func WriteLatest(l Latest) error {
	b, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(LatestPath(), append(b, '\n'))
}

// Game は workspace.json の 1 行。
type Game struct {
	Name string `json:"name"`
	Dir  string `json:"dir"`
}

// Workspace は workspace.json の形。
type Workspace struct {
	Version int    `json:"version"`
	Dir     string `json:"dir"` // ワークスペースのフォルダ（既定 ~/flix-games）
	Games   []Game `json:"games"`
}

// ReadWorkspace は一覧を読む。無ければ空の一覧（Dir は既定）。
func ReadWorkspace() (Workspace, error) {
	b, err := os.ReadFile(WorkspacePath())
	if errors.Is(err, os.ErrNotExist) {
		return Workspace{Version: 1, Dir: DefaultWorkspaceDir()}, nil
	}
	if err != nil {
		return Workspace{}, err
	}
	var w Workspace
	if err := json.Unmarshal(b, &w); err != nil {
		return Workspace{}, err
	}
	if w.Dir == "" {
		w.Dir = DefaultWorkspaceDir()
	}
	return w, nil
}

// WriteWorkspace は一覧を tmp に書いてから差し替える。
func WriteWorkspace(w Workspace) error {
	if w.Version == 0 {
		w.Version = 1
	}
	b, err := json.MarshalIndent(w, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(WorkspacePath(), append(b, '\n'))
}

// AddGame は dir を一覧に足す（同じ dir があれば名前だけ差し替える）。
func (w *Workspace) AddGame(g Game) {
	for i := range w.Games {
		if w.Games[i].Dir == g.Dir {
			w.Games[i].Name = g.Name
			return
		}
	}
	w.Games = append(w.Games, g)
}

// DefaultWorkspaceDir は ~/flix-games。
func DefaultWorkspaceDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "flix-games"
	}
	return filepath.Join(home, "flix-games")
}

func writeFileAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}
