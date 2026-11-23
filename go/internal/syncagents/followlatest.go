package syncagents

// 版によらないスキル（manifest の followLatest）。ゲームの engine の版によらず、手元の最新の
// engine の物へ写し直す。写した engine の版はゲームの .agents-pack.json の followLatest に書く。
//
// WhyNot: ワークスペースのフォルダ（~/flix-games/.claude/skills）に 1 つ置かないのは、Claude Code が
// 上のフォルダの skills を読むのが git のリポの根までで、ゲームはそれぞれが git のリポだから。

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fetchengine"
)

// FollowLatest は manifest の followLatest。
type FollowLatest struct {
	Skills   []string
	Commands []string
}

// loadFollowLatest は manifest の followLatest を読む。キーが無い版の manifest なら空。
func loadFollowLatest(root string, r *Rules) (FollowLatest, error) {
	path := pyJoin(root, r.ManifestPath)
	data, err := os.ReadFile(fsPath(path))
	if err != nil {
		return FollowLatest{}, err
	}
	var m struct {
		FollowLatest *struct {
			Skills   []string `json:"skills"`
			Commands []string `json:"commands"`
		} `json:"followLatest"`
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return FollowLatest{}, fmt.Errorf("%s の followLatest が読めません: %v", path, err)
	}
	if m.FollowLatest == nil {
		return FollowLatest{}, nil
	}
	return FollowLatest{Skills: m.FollowLatest.Skills, Commands: m.FollowLatest.Commands}, nil
}

// versionAtLeast は v が base 以上か。読めない v は base より古いとみなす。
func versionAtLeast(v, base string) bool {
	return v == base || fetchengine.IsNewer(base, v)
}

// heldBack は sync-agents が写さない followLatest のスキル（ゲームが version より新しい engine の物を持つ）。
func heldBack(follow FollowLatest, recorded map[string]string, version string) map[string]string {
	held := map[string]string{}
	for _, name := range follow.Skills {
		if rec, ok := recorded[name]; ok && !versionAtLeast(version, rec) {
			held[name] = rec
		}
	}
	return held
}

// nextFollowLatest は sync-agents が書く followLatest。写したスキルには version を書き、写さなかった物は前のまま。
// WhyNot: 読めない版（--version を渡さない回の unknown）を書かない — 後の回でどの版とも比べられず、ずっと写せなくなる。
func nextFollowLatest(root string, r *Rules, follow FollowLatest, prev, held map[string]string, version string) map[string]string {
	next := map[string]string{}
	for name, v := range prev {
		next[name] = v
	}
	if !fetchengine.IsVersionName(version) {
		return next
	}
	for _, name := range follow.Skills {
		if _, ok := held[name]; ok || !pyIsDir(pyJoin(pyJoin(root, r.SkillsDir), name)) {
			continue
		}
		next[name] = version
	}
	return next
}

// topDir は copyDirs の配り元からの相対パスの最初の要素（skills ならスキルの名前）。
func topDir(rel string) string {
	if i := strings.Index(rel, "/"); i >= 0 {
		return rel[:i]
	}
	return rel
}

// isSkillsEntry は copyDirs の項目がスキルのフォルダを配る物か。
func isSkillsEntry(r *Rules, e manifestEntry) bool {
	return pyPath(e.src) == pyPath(r.SkillsDir)
}

// copyDirExcept は copyDir と同じだが、最初の要素が skip に入る物を写さない。
func copyDirExcept(src, dst string, skip map[string]string) error {
	var failed error
	err := walkRel(src, "", func(rel string, isDir bool) {
		if failed != nil {
			return
		}
		if _, held := skip[topDir(rel)]; held {
			return
		}
		if isDir {
			failed = os.MkdirAll(fsPath(pyJoin(dst, rel)), 0o777)
			return
		}
		failed = copyFile(pyJoin(src, rel), pyJoin(dst, rel))
	})
	if err != nil {
		return err
	}
	return failed
}

// filterTop は一覧から最初の要素が names に入る物を除く。keep が true なら逆に、それだけを残す。
func filterTop(files []string, names map[string]string, keep bool) []string {
	var picked []string
	for _, f := range files {
		if _, in := names[topDir(f)]; in == keep {
			picked = append(picked, f)
		}
	}
	return picked
}

// ReadFollowLatestVersions はゲームの .agents-pack.json の followLatest（スキルの名前 → 写した engine の版）を返す。
// rulesRoot は bin/lint-rules/sync-agents.json を持つ根（engine でもゲームでもよい）。読めなければ空。
func ReadFollowLatestVersions(rulesRoot, game string) map[string]string {
	r, err := LoadRules(rulesRoot)
	if err != nil {
		return nil
	}
	f, _ := loadLedgerFile(pyJoin(pyPath(game), r.LedgerPath))
	return f.FollowLatest
}

// RefreshFollowLatest は engine の根 root（版 version）の followLatest のスキルを game の
// .claude/skills・.agents/skills（manifest の copyDirs のうちスキルを配る物）へ写し直し、
// .agents-pack.json を直す。写したスキルの名前を返す。
// game の .agents-pack.json に version 以上の版が書いてあるスキルは触らない。
func RefreshFollowLatest(root, game, version string) ([]string, error) {
	// WhyNot: 規約ファイルの無い engine をエラーにしない — followLatest より前の版で、写す物が無いだけ。
	if !pyIsFile(pyJoin(pyPath(root), pyPath(RulesPath))) {
		return nil, nil
	}
	r, err := LoadRules(root)
	if err != nil {
		return nil, err
	}
	root, game = pyResolve(root), pyPath(game)
	follow, err := loadFollowLatest(root, r)
	if err != nil || len(follow.Skills) == 0 {
		return nil, err
	}
	m, err := loadManifest(root, r)
	if err != nil {
		return nil, err
	}
	var dsts []string
	for _, e := range m[keyCopyDirs] {
		dst := pyJoin(game, e.dst)
		// WhyNot: 配り先の無いゲームにフォルダを作らない — agents-pack を配っていない物（engine を使うだけの
		// フォルダ）に、頼まれていないスキルを増やすことになる。
		if isSkillsEntry(r, e) && pyIsDir(dst) && !isSymlink(dst) && isUnder(game, dst) {
			dsts = append(dsts, e.dst)
		}
	}
	if len(dsts) == 0 {
		return nil, nil
	}
	ledgerPath := pyJoin(game, r.LedgerPath)
	ledger, _ := loadLedgerFile(ledgerPath)
	if ledger.Dirs == nil {
		ledger.Dirs = map[string][]string{}
	}
	if ledger.FollowLatest == nil {
		ledger.FollowLatest = map[string]string{}
	}
	var done []string
	var discard strings.Builder
	for _, name := range follow.Skills {
		src := pyJoin(pyJoin(root, r.SkillsDir), name)
		if !pyIsDir(src) || !isSafeRel(name) {
			continue
		}
		if rec, ok := ledger.FollowLatest[name]; ok && versionAtLeast(rec, version) {
			continue
		}
		files, err := filesUnder(src)
		if err != nil {
			return done, err
		}
		if len(files) == 0 {
			continue
		}
		only := map[string]string{name: ""}
		for i := range files {
			files[i] = name + "/" + files[i]
		}
		for _, d := range dsts {
			dst := pyJoin(game, d)
			if err := pruneDistributed(&discard, game, dst, filterTop(ledger.Dirs[d], only, true), files); err != nil {
				return done, err
			}
			if err := copyDir(src, pyJoin(dst, name)); err != nil {
				return done, err
			}
			ledger.Dirs[d] = unionSorted(filterTop(ledger.Dirs[d], only, false), files)
		}
		ledger.FollowLatest[name] = version
		done = append(done, name)
	}
	if len(done) == 0 {
		return nil, nil
	}
	if err := writeLedger(ledgerPath, ledger.Dirs, ledger.FollowLatest); err != nil {
		return done, err
	}
	return done, nil
}

// checkFollowLatest は版によらないスキルの中のコマンドが followLatest.commands にあるかを見る。
func checkFollowLatest(errOut *strings.Builder, root string, r *Rules) (int, error) {
	follow, err := loadFollowLatest(root, r)
	if err != nil {
		fmt.Fprintf(errOut, "[sync-agents] NG: %v\n", err)
		return 1, nil
	}
	if r.FollowCommand == nil {
		fmt.Fprintf(errOut, "[sync-agents] NG: %s に followLatestCommandPattern がありません\n", RulesPath)
		return 1, nil
	}
	allowed := map[string]bool{}
	for _, c := range follow.Commands {
		allowed[c] = true
	}
	bad := 0
	for _, name := range follow.Skills {
		dir := pyJoin(pyJoin(root, r.SkillsDir), name)
		if !pyIsDir(dir) {
			fmt.Fprintf(errOut, "[sync-agents] NG: manifest の followLatest の %s は %s に実在しません\n", name, r.SkillsDir)
			bad = 1
			continue
		}
		files, err := mdFilesSorted(dir)
		if err != nil {
			return 2, err
		}
		for _, f := range files {
			text, err := readTextStrict(pyJoin(dir, f))
			if err != nil {
				return 2, err
			}
			seen := map[string]bool{}
			var missing []string
			for _, mm := range r.FollowCommand.FindAllStringSubmatch(text, -1) {
				cmd := mm[1] + " " + mm[2]
				if !allowed[cmd] && !seen[cmd] {
					seen[cmd] = true
					missing = append(missing, cmd)
				}
			}
			sort.Strings(missing)
			for _, cmd := range missing {
				fmt.Fprintf(errOut, "[sync-agents] NG: %s の「%s」は manifest の followLatest.commands にありません。"+
					"古い版のゲームにもあるコマンドなら一覧へ足し、無いなら版に依るスキルへ移してください\n",
					pyJoin(pyJoin(r.SkillsDir, name), f), cmd)
				bad = 1
			}
		}
	}
	return bad, nil
}
