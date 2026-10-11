package syncagents

// 配った物の一覧 (ledger)。copyDirs の配り先で「engine が配った物」と「ゲームが自分で
// 置いた物」を見分けるために、前の回に配ったファイルをゲームのリポに書き残す。
//
// WhyNot: 配り先を丸ごとミラーにしないのは、ゲームが .claude/rules/ などへ自分の
// ファイル (例: art-style.md) を足すため。ミラーにすると engine の一覧に無いそれまで消す。
// WhyNot: 名前の印 (接頭辞) で見分けないのは、配る物の名前がそのまま読み手への入口
// (drawing.md・skill 名) で、印を付けると AGENTS.md や skill の参照を全部書き換えることになるため。

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

const ledgerNote = "bin/fge sync-agents が書く。copyDirs の配り先ごとに engine が配ったファイルの一覧。" +
	"次の配りで、ここに載っていて engine から無くなった物だけを消す（載っていない物はゲームの物として残す）。手で編集しない。"

type ledgerFile struct {
	Version int                 `json:"version"`
	Note    string              `json:"note"`
	Dirs    map[string][]string `json:"dirs"`
}

// loadLedger は前の回の一覧を読む。無い・壊れているときは ok=false（消し込みを飛ばす側へ倒す）。
func loadLedger(path string) (map[string][]string, bool) {
	data, err := os.ReadFile(fsPath(path))
	if err != nil {
		return nil, false
	}
	var f ledgerFile
	if err := json.Unmarshal(data, &f); err != nil || f.Dirs == nil {
		return nil, false
	}
	return f.Dirs, true
}

func writeLedger(path string, dirs map[string][]string) error {
	data, err := json.MarshalIndent(ledgerFile{Version: 1, Note: ledgerNote, Dirs: dirs}, "", "  ")
	if err != nil {
		return err
	}
	return writeTextLF(path, string(data)+"\n")
}

// filesUnder は dir の下のファイルを dir からの相対パスで名前順に返す。
func filesUnder(dir string) ([]string, error) {
	var found []string
	err := walkRel(dir, "", func(rel string, isDir bool) {
		if !isDir {
			found = append(found, rel)
		}
	})
	sort.Strings(found)
	return found, err
}

// unionSorted は 2 つの一覧を重ねて名前順に返す。
func unionSorted(a, b []string) []string {
	seen := map[string]bool{}
	var all []string
	for _, s := range append(append([]string{}, a...), b...) {
		if !seen[s] {
			seen[s] = true
			all = append(all, s)
		}
	}
	sort.Strings(all)
	return all
}

// pruneDistributed は前の回に配って今回の配り元に無い物だけを dst から消す。
func pruneDistributed(out *strings.Builder, game, dst string, prev, current []string) error {
	keep := map[string]bool{}
	for _, rel := range current {
		keep[rel] = true
	}
	for _, rel := range prev {
		if keep[rel] || !isSafeRel(rel) {
			continue
		}
		d := pyJoin(dst, rel)
		// WhyNot: 途中に symlink があれば消さないのは、辿ると配り先の外の木を消しに行くため。
		if hasSymlinkBetween(dst, rel) {
			continue
		}
		info, err := os.Lstat(fsPath(d))
		if err != nil || info.IsDir() {
			continue
		}
		if err := os.Remove(fsPath(d)); err != nil {
			return err
		}
		fmt.Fprintf(out, "[sync-agents] 消しました: %s (配り元にありません)\n",
			strings.TrimPrefix(d, game+"/"))
		removeEmptyParents(dst, rel)
	}
	return nil
}

// isSafeRel は一覧の 1 行が配り先の中を指すか（手で書き換えられた一覧で外を消さない）。
func isSafeRel(rel string) bool {
	if rel == "" || strings.HasPrefix(rel, "/") {
		return false
	}
	for _, part := range strings.Split(rel, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func hasSymlinkBetween(dst, rel string) bool {
	parts := strings.Split(rel, "/")
	cur := dst
	for _, part := range parts[:len(parts)-1] {
		cur = pyJoin(cur, part)
		if isSymlink(cur) {
			return true
		}
	}
	return false
}

// removeEmptyParents は消した物の親が空になったら dst の手前まで畳む
// (配り元から skill のフォルダごと無くなったとき、空のフォルダを残さない)。
func removeEmptyParents(dst, rel string) {
	parts := strings.Split(rel, "/")
	for i := len(parts) - 1; i > 0; i-- {
		dir := pyJoin(dst, strings.Join(parts[:i], "/"))
		if names, err := dirEntryNames(dir); err != nil || len(names) > 0 || os.Remove(fsPath(dir)) != nil {
			return
		}
	}
}
