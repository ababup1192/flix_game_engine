package status

import (
	"fmt"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/syncagents"
)

// followLatestSkillDirs は版によらないスキルの配り先（agents-pack/manifest.json の copyDirs のうちスキルを配る物）。
// WhyNot: manifest から引かない — manifest は engine にだけあり、ゲームのリポには無い。
var followLatestSkillDirs = []string{".claude/skills", ".agents/skills"}

// followLatestPending は、fge が版によらないスキルを写し直したのにゲームのリポでコミットしていない時の 1 行。
func followLatestPending(c *ctx, out *[]string) {
	recorded := syncagents.ReadFollowLatestVersions(c.root, c.root)
	if len(recorded) == 0 {
		return
	}
	names := make([]string, 0, len(recorded))
	newest := ""
	for name, v := range recorded {
		names = append(names, name)
		if newest == "" || engineVersionLess(newest, v) {
			newest = v
		}
	}
	sort.Strings(names)
	args := []string{"status", "--porcelain", "--"}
	for _, name := range names {
		for _, dir := range followLatestSkillDirs {
			args = append(args, dir+"/"+name)
		}
	}
	if strings.TrimSpace(c.git(args...)) == "" {
		return
	}
	*out = append(*out, fmt.Sprintf("skills   スキルを engine %s の物に新しくしました（コミット待ち）", newest))
}
