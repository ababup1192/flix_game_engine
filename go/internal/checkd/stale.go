package checkd

// 起きた後に依存（lib の engine の束）が置き換わった常駐を止める。
//
// flixlint の常駐（0.9.0 まで）はコンパイラを依存のパスで持ち続け、パスが同じなら作り直さない。make sync-engine-full は
// lib/github/…/<名前>-<版>.fpkg の symlink を同じ名前のまま新しい束へ張り替えるので、常駐は古い engine で check し、
// 索引（bin/fge refactor）を作り続けていた（CHECKD=0 の素の flix check は通るのに、新しい型や欄が「無い」と言われる）。

import (
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// depFile は常駐が起きた時に読んだはずの依存のファイル 1 つ。
type depFile struct {
	path    string
	changed time.Time
}

// newestDep は pkg の lib/github の下の .fpkg・.toml のうち、一番後に置かれた物。
// 置かれた時刻は symlink そのものと先のファイルの mtime・ctime の一番遅い物（張り替えは symlink だけが新しくなる）。
// WhyNot: lib/external の jar は見ない。engine の jar は名前に中身の hash を持ち、替われば名前（依存のパス）が替わるので
// 常駐は自分で作り直す。Maven の jar は常駐の中の Bootstrap が起きた後に置くので、見ると初回の check の後に必ず 1 回止めていた。
// lib/cache（Maven の取り物の共有の置き場）も見ない。
func newestDep(pkg string) (depFile, bool) {
	var best depFile
	found := false
	_ = filepath.WalkDir(filepath.Join(pkg, "lib", "github"), func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(d.Name(), ".fpkg") && !strings.HasSuffix(d.Name(), ".toml") {
			return nil
		}
		if t, ok := placedAt(path); ok && (!found || t.After(best.changed)) {
			best, found = depFile{path, t}, true
		}
		return nil
	})
	return best, found
}

func placedAt(path string) (time.Time, bool) {
	l, err := os.Lstat(path)
	if err != nil {
		return time.Time{}, false
	}
	times := []time.Time{l.ModTime(), changedAt(l)}
	if s, err := os.Stat(path); err == nil {
		times = append(times, s.ModTime(), changedAt(s))
	}
	t := times[0]
	for _, x := range times[1:] {
		if x.After(t) {
			t = x
		}
	}
	return t, true
}

// staleReason は socket の常駐が pkg の今の依存より前に起きていれば、その訳（置き換わったファイル）。
// 常駐の起きた時刻は socket の時刻（Resident が起きる時に bind し、その後は書き換えない）。
func staleReason(socket, pkg string) (string, bool) {
	info, err := os.Lstat(socket)
	if err != nil || info.Mode()&fs.ModeSocket == 0 {
		return "", false
	}
	dep, ok := newestDep(pkg)
	if !ok || !dep.changed.After(info.ModTime()) {
		return "", false
	}
	rel, err := filepath.Rel(pkg, dep.path)
	if err != nil {
		rel = dep.path
	}
	return fmt.Sprintf("%s が常駐の起きた %s より後（%s）に置き換わった", rel, info.ModTime().Format("15:04:05"), dep.changed.Format("15:04:05")), true
}

// StopStaleResident は pkg の常駐（check・lint・refactor の索引が共有する 1 本）が、起きた後に置き換わった依存を
// 持ったままなら止め、そう 1 行 w へ言う。止めたら true（次の check・索引が新しい依存で起こし直す）。
// 常駐が居ない・支度ができない・新しい時は何もしない。
func StopStaleResident(r *hooks.Rules, root, pkg string, w io.Writer) bool {
	if r.Checkd.Server.BackendEnvVar == nil {
		return false
	}
	s, err := prepareResident(r, root, pkg)
	if err != nil {
		return false
	}
	return stopIfStale(r, s, pkg, w)
}

func stopIfStale(r *hooks.Rules, s residentSetup, pkg string, w io.Writer) bool {
	why, stale := staleReason(s.socket, pkg)
	if !stale {
		return false
	}
	fmt.Fprintf(w, "[checkd] %s の常駐は古い依存を持っている（%s）。止めて起こし直す\n", shortPkg(pkg), why)
	stopSocket(r, s.socket, pkg, s.identity)
	return true
}

func shortPkg(pkg string) string {
	if home, err := os.UserHomeDir(); err == nil {
		if rel, err := filepath.Rel(home, pkg); err == nil && !strings.HasPrefix(rel, "..") {
			return "~/" + rel
		}
	}
	return pkg
}

// stopSocket は socket の常駐に stop を頼み、socket が消えて lock が空くまで待つ（待ちは最大 10 秒）。
// WhyNot: stop の答えを受けただけで戻らない。常駐は答えた後に socket を消して抜けるので、すぐ起こした次の常駐が
// 「lock を持つ別の常駐が居る」で抜け、check が素の flix check に落ちていた。
func stopSocket(r *hooks.Rules, socket, pkg, identity string) {
	conn, err := net.DialTimeout("unix", socket, seconds(*r.Checkd.Daemon.ConnectTimeoutSec))
	if err == nil {
		if _, err := conn.Write(encodeRequest(residentRequest{Kind: "stop", Root: pkg, Identity: identity})); err == nil {
			_ = conn.SetReadDeadline(time.Now().Add(seconds(*r.Checkd.Daemon.ConnectTimeoutSec)))
			for {
				f, err := readFrame(conn)
				if err != nil || f.Tag == 'X' {
					break
				}
			}
		}
		conn.Close()
	}
	lock := strings.TrimSuffix(socket, ".sock") + ".lock"
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Lstat(socket); os.IsNotExist(err) && !lockHeld(lock) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}
