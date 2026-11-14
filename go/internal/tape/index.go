package tape

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	// IndexFile の名は頁に取られているので、置き場の一覧は IndexJSON と呼ぶ。
	IndexJSON  = "tapes.json"
	ReadmeFile = "README.md"
	GamesDir   = "games"
)

// IndexEntry は tapes.json の 1 件 = 乱数のフォルダ 1 つ。
type IndexEntry struct {
	At       string      `json:"at"`
	Name     string      `json:"name"`
	Game     string      `json:"game"`
	Title    string      `json:"title"`
	Commit   string      `json:"commit"`
	GameRepo string      `json:"gameRepo"` // owner/name。取れなければ空
	Unpushed bool        `json:"unpushed,omitempty"`
	Tapes    []IndexTape `json:"tapes"`
}

// IndexTape は 1 件の中のテープ 1 本。Folder は 1 本だけ置いた時は空。
type IndexTape struct {
	Folder string `json:"folder"`
	URL    string `json:"url"`
	Flow   string `json:"flow"`
}

type indexFile struct {
	Entries []IndexEntry `json:"entries"`
}

var (
	ghHTTPSRe = regexp.MustCompile(`^(?:https?|ssh|git)://(?:[^@/]+@)?github\.com(?::\d+)?/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$`)
	ghSCPRe   = regexp.MustCompile(`^(?:[^@/]+@)?github\.com:([A-Za-z0-9-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$`)
	unsafeRe  = regexp.MustCompile(`[^A-Za-z0-9._-]`)
)

// GitHubRepoFromRemote は git の remote の URL（https・ssh・scp 形）から owner/name を返す。github.com でなければ空。
func GitHubRepoFromRemote(u string) string {
	u = strings.TrimSpace(u)
	for _, re := range []*regexp.Regexp{ghHTTPSRe, ghSCPRe} {
		if m := re.FindStringSubmatch(u); m != nil {
			return m[1] + "/" + m[2]
		}
	}
	return ""
}

// tapeMeta は撮ったテープのフォルダから一覧に要る値を読む（読めない値は空）。
type tapeMeta struct {
	Game, Title, Flow, Commit, GameRepo string
	Unpushed                            bool
}

func readTapeMeta(src string) tapeMeta {
	var m tapeMeta
	if raw, err := os.ReadFile(filepath.Join(src, TapeFile)); err == nil {
		var t struct {
			Game   string `json:"game"`
			Title  string `json:"title"`
			Flow   string `json:"flow"`
			Commit string `json:"commit"`
		}
		if json.Unmarshal(raw, &t) == nil {
			m.Game, m.Title, m.Flow, m.Commit = t.Game, t.Title, t.Flow, t.Commit
		}
	}
	// WhyNot: tape.json だけを見ない — Build は commit を頁（index.html）の TAPE に書き、tape.json には書かない。
	if page, err := os.ReadFile(filepath.Join(src, IndexFile)); err == nil {
		if c := commitRe.FindSubmatch(page); c != nil {
			m.Commit = string(c[1])
		}
	}
	if origin, err := gitOut(src, "remote", "get-url", "origin"); err == nil {
		m.GameRepo = GitHubRepoFromRemote(origin)
	}
	if m.GameRepo != "" && m.Commit != "" {
		m.Unpushed = !isOnRemote(src, m.Commit)
	}
	return m
}

// isOnRemote は commit が手元の remote の枝（origin/… 等）のどれかに入っているか。手元に無い commit も入っていない扱い。
func isOnRemote(dir, commit string) bool {
	out, err := gitOut(dir, "branch", "-r", "--contains", commit)
	return err == nil && strings.TrimSpace(out) != ""
}

func loadIndex(site string) ([]IndexEntry, error) {
	raw, err := os.ReadFile(filepath.Join(site, IndexJSON))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f indexFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("置き場の %s を読めない: %w", IndexJSON, err)
	}
	return f.Entries, nil
}

func sortEntries(es []IndexEntry) {
	sort.SliceStable(es, func(i, j int) bool {
		ti, tj := entryTime(es[i]), entryTime(es[j])
		if !ti.Equal(tj) {
			return ti.After(tj)
		}
		return es[i].Name > es[j].Name
	})
}

func entryTime(e IndexEntry) time.Time {
	if t, err := time.Parse(time.RFC3339, e.At); err == nil {
		return t
	}
	t, _ := ParseName(e.Name)
	return t
}

// readPublishedLog は published.jsonl の行を読む（無ければ空）。
func readPublishedLog(path string) ([]Published, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []Published
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var p Published
		if err := json.Unmarshal([]byte(line), &p); err != nil {
			return nil, fmt.Errorf("%s の %d 行目を読めない: %w", path, n, err)
		}
		out = append(out, p)
	}
	return out, sc.Err()
}

// entriesFromPublished は published.jsonl の行を乱数のフォルダごとの 1 件にまとめる（repo が違う行は飛ばす）。
// title・flow・ゲームのリポジトリは source のフォルダから読み、読めなければ game 名で代える。
func entriesFromPublished(recs []Published, repo string) []IndexEntry {
	var order []string
	byName := map[string]*IndexEntry{}
	for _, r := range recs {
		if r.Repo != "" && !strings.EqualFold(r.Repo, repo) {
			continue
		}
		if _, ok := ParseName(r.Name); !ok {
			continue
		}
		meta := readTapeMeta(r.Source)
		e, ok := byName[r.Name]
		if !ok {
			e = &IndexEntry{At: r.At, Name: r.Name, Game: r.Game, Commit: r.Commit, Title: meta.Title, GameRepo: meta.GameRepo}
			if e.Game == "" {
				e.Game = meta.Game
			}
			if e.Commit == "" {
				e.Commit = meta.Commit
			}
			if e.Title == "" {
				e.Title = e.Game
			}
			if e.GameRepo != "" && e.Commit != "" {
				e.Unpushed = !isOnRemote(r.Source, e.Commit)
			}
			byName[r.Name] = e
			order = append(order, r.Name)
		}
		e.Tapes = append(e.Tapes, IndexTape{Folder: folderFromURL(r.URL, r.Name), URL: r.URL, Flow: meta.Flow})
	}
	out := make([]IndexEntry, 0, len(order))
	for _, n := range order {
		out = append(out, *byName[n])
	}
	return out
}

// folderFromURL は …/tapes/<name>/<フォルダ名>/ のフォルダ名（1 本だけ置いた URL なら空）。
func folderFromURL(u, name string) string {
	_, rest, ok := strings.Cut(u, "/"+TapesDir+"/"+name+"/")
	if !ok {
		return ""
	}
	return strings.Trim(rest, "/")
}

// gameKey は games/<key>.md の名前。
func gameKey(game string) string {
	if game == "" {
		return "unknown"
	}
	return unsafeRe.ReplaceAllString(game, "_")
}

func entryDate(e IndexEntry) string {
	if t, err := time.Parse(time.RFC3339, e.At); err == nil {
		return t.Format("2006-01-02 15:04")
	}
	if t, ok := ParseName(e.Name); ok {
		return t.Format("2006-01-02")
	}
	return e.Name
}

func countTapes(es []IndexEntry) int {
	n := 0
	for _, e := range es {
		n += len(e.Tapes)
	}
	return n
}

// groupByGame は新しい順の entries をゲームごとに分け、ゲームの並び（最新のテープが新しい順）と一緒に返す。
func groupByGame(es []IndexEntry) ([]string, map[string][]IndexEntry) {
	sorted := append([]IndexEntry(nil), es...)
	sortEntries(sorted)
	var keys []string
	by := map[string][]IndexEntry{}
	for _, e := range sorted {
		k := gameKey(e.Game)
		if _, ok := by[k]; !ok {
			keys = append(keys, k)
		}
		by[k] = append(by[k], e)
	}
	return keys, by
}

func gameHeading(latest IndexEntry) string {
	title := latest.Title
	if title == "" || title == latest.Game {
		return latest.Game
	}
	return fmt.Sprintf("%s（%s）", title, latest.Game)
}

// BuildReadme は置き場の根の README.md（ゲームごとの見出しと子ページへのリンク）を作る。
func BuildReadme(es []IndexEntry) string {
	var b strings.Builder
	b.WriteString("# テープの置き場\n\n")
	fmt.Fprintf(&b, "bin/fge tape publish が置いたテープの一覧（%d 日を過ぎた物は外れる）。この README と %s/ は publish が %s から毎回作り直すので、手で書き足さない。\n", KeepDays, GamesDir, IndexJSON)
	keys, by := groupByGame(es)
	if len(keys) == 0 {
		b.WriteString("\nいま置いてあるテープは無い。\n")
	}
	for _, k := range keys {
		list := by[k]
		fmt.Fprintf(&b, "\n## [%s](%s/%s.md)\n\n", gameHeading(list[0]), GamesDir, k)
		fmt.Fprintf(&b, "テープ %d 本（publish %d 回）・最新 %s\n", countTapes(list), len(list), entryDate(list[0]))
	}
	return b.String()
}

// BuildGamePage は games/<game>.md（そのゲームのテープを新しい順に、日付・頁・flow・撮った版へのリンクつきで）を作る。
func BuildGamePage(es []IndexEntry) string {
	sorted := append([]IndexEntry(nil), es...)
	sortEntries(sorted)
	var b strings.Builder
	if len(sorted) > 0 {
		fmt.Fprintf(&b, "# %s\n\n", gameHeading(sorted[0]))
	}
	b.WriteString("[← 一覧](../README.md)\n\n新しい順。版はテープを撮った commit のゲームのリポジトリ（GitHub の tree）。\n")
	for _, e := range sorted {
		fmt.Fprintf(&b, "\n## %s", entryDate(e))
		if e.Title != "" && e.Title != e.Game && e.Title != sorted[0].Title {
			fmt.Fprintf(&b, " %s", e.Title)
		}
		b.WriteString("\n\n")
		if v := versionLine(e); v != "" {
			fmt.Fprintf(&b, "- 版: %s\n", v)
		}
		for _, tp := range e.Tapes {
			label := tp.Folder
			if label == "" {
				label = "テープ"
			}
			fmt.Fprintf(&b, "- [%s](%s)", label, tp.URL)
			if tp.Flow != "" {
				fmt.Fprintf(&b, " — `%s`", tp.Flow)
			}
			b.WriteString("\n")
		}
	}
	return b.String()
}

func versionLine(e IndexEntry) string {
	if e.Commit == "" {
		return ""
	}
	v := e.Commit
	if e.GameRepo != "" {
		v = fmt.Sprintf("[%s](https://github.com/%s/tree/%s)", e.Commit, e.GameRepo, e.Commit)
	}
	if e.Unpushed {
		v += " (push されていない)"
	}
	return v
}

// writeListings は tapes.json・README.md・games/ を置き場の根に書き直し、書いた物の相対パスと本文を返す。
func writeListings(site string, es []IndexEntry) ([]string, map[string]string, error) {
	sorted := append([]IndexEntry(nil), es...)
	sortEntries(sorted)
	raw, err := json.MarshalIndent(indexFile{Entries: sorted}, "", "  ")
	if err != nil {
		return nil, nil, err
	}
	files := map[string]string{IndexJSON: string(raw) + "\n", ReadmeFile: BuildReadme(sorted)}
	paths := []string{IndexJSON, ReadmeFile}
	keys, by := groupByGame(sorted)
	for _, k := range keys {
		p := GamesDir + "/" + k + ".md"
		files[p] = BuildGamePage(by[k])
		paths = append(paths, p)
	}
	// WhyNot: games/ を足し書きしない — 30 日で全部外れたゲームの頁が、消えたテープを指したまま残る。
	if err := os.RemoveAll(filepath.Join(site, GamesDir)); err != nil {
		return nil, nil, err
	}
	for _, p := range paths {
		full := filepath.Join(site, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return nil, nil, err
		}
		if err := os.WriteFile(full, []byte(files[p]), 0o644); err != nil {
			return nil, nil, err
		}
	}
	return paths, files, nil
}
