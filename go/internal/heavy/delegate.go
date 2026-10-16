package heavy

// 委ね: heavy だけは、マシンに入っているいちばん新しいリリースの heavy に流させる。
//
// WhyNot: heavy は作業場ごとの道具ではなく、マシン全体で 1 つの順番を守る仕組みなので、
// 作業場ごとに版が違うと古い方の決まり（枠 1 本だけ・長い物の見分けなし）に新しい方が
// 合わせ続けることになる。0.35.26 の直後は、上げていない作業場の短い物が 1 日で
// 合計 6 時間あまり長い物の後ろで待った。委ね先をリリースの置き場
// (~/.flix_ge_studio/engines/<版>) だけに限るのは、開発中のビルドを全員に配らないため。

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Revision は heavy の作りの版。決まり（枠・長い物の見分け・記録）を変えたら 1 つ上げる。
// 0.35.26 の枠 2 本が 2、記録と委ねが入った 0.35.30 が 3、長い物の枠が 2 本になった 0.35.33 が 4。0.35.29 以前のリリースは
// --revision を知らないので 0 と読む。
const Revision = 4

// DelegatedEnv は委ねた先で立つ印。委ねた先がもう一度委ねないように見る。
const DelegatedEnv = "FGE_HEAVY_DELEGATED"

// NoDelegateEnv を 1 にすると委ねない（heavy そのものを直している人が手元のビルドを試すとき）。
const NoDelegateEnv = "FGE_HEAVY_NO_DELEGATE"

// noDelegateFile が ~/.flix_ge_studio にあると、マシンの全員が委ねない。
//
// WhyNot: 環境変数のほかにファイルの止めスイッチを置くのは、新しいリリースの heavy に
// 不具合があったとき、十数本のエージェントの環境変数を一斉に変えることはできないため。
const noDelegateFile = "heavy-no-delegate"

// newestRelease は engines/ のうち版の番号がいちばん大きいリリースの fge-go を返す。
func newestRelease(home string) string {
	entries, err := os.ReadDir(filepath.Join(home, "engines"))
	if err != nil {
		return ""
	}
	best, bestPath := []int(nil), ""
	for _, e := range entries {
		v := parseVersion(e.Name())
		if v == nil {
			continue
		}
		path := filepath.Join(home, "engines", e.Name(), "bin", "fge-go")
		if info, err := os.Stat(path); err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			continue
		}
		// 入れている途中の版（Makefile がまだ無い）は飛ばす。
		if _, err := os.Stat(filepath.Join(home, "engines", e.Name(), "Makefile")); err != nil {
			continue
		}
		if best == nil || versionLess(best, v) {
			best, bestPath = v, path
		}
	}
	return bestPath
}

func parseVersion(s string) []int {
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return nil
	}
	v := make([]int, 3)
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return nil
		}
		v[i] = n
	}
	return v
}

func versionLess(a, b []int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// revisionOf は fge-go の heavy の作りの版を聞く。答えなければ 0。
func revisionOf(bin string) int {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, bin, "heavy", "--revision")
	c.Env = append(os.Environ(), DelegatedEnv+"=1")
	out, err := c.Output()
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return 0
	}
	return n
}

// delegateTarget は委ねる先の fge-go を返す（委ねないなら ""）。
//
// 委ねるのは fge heavy の入口だけ。compare と use-engine はプロセスの中で Hold を呼ぶので、
// その作業場の版の作りのまま並ぶ。
func delegateTarget() string {
	if !canDelegate || os.Getenv(DelegatedEnv) != "" || os.Getenv(NoDelegateEnv) == "1" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	studio := filepath.Join(home, ".flix_ge_studio")
	if _, err := os.Stat(filepath.Join(studio, noDelegateFile)); err == nil {
		return ""
	}
	bin := newestRelease(studio)
	if bin == "" {
		return ""
	}
	if self, err := os.Executable(); err == nil {
		a, _ := filepath.EvalSymlinks(self)
		b, _ := filepath.EvalSymlinks(bin)
		if a != "" && a == b {
			return ""
		}
	}
	if revisionOf(bin) <= Revision {
		return ""
	}
	return bin
}
