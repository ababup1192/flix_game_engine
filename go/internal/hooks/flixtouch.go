package hooks

// hook-flix-touch — このセッションが .flix を編集したパッケージへ印だけ残す。
//
// 検査は一切しない（常駐へ CHECK は送らない）。印は
// ~/.cache/flix-checkd/<パッケージのハッシュ>/touched-<session_id のハッシュ> で、
// この印があるパッケージだけが hook-flix-work で差し戻しの対象になる。
//
// WhyNot: ここで検査しないのは、作業ツリーを複数のエージェントが並行で汚すため。
// 他人が編集中の（赤くて当然の）パッケージを拾うと、無関係な赤で他人のターンを止める。

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// RunFlixTouch は印を置き、ついでに常駐が居なければ起動だけ頼む。
// 何も判定しないので、返すのは 0 か（規約が読めないときの）2 だけ。
func RunFlixTouch(errOut io.Writer, root string, in io.Reader) int {
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r, err := LoadRules(root)
	if err != nil {
		fmt.Fprintf(errOut, "# hook-flix-touch: %v\n", err)
		return 2
	}
	var paths []string
	for _, p := range payload.EditedPaths(r) {
		if strings.HasSuffix(p, ".flix") {
			paths = append(paths, p)
		}
	}
	session := payload.SessionID()
	if len(paths) == 0 || session == "" {
		return 0
	}
	for _, path := range paths {
		pkg := FindPkg(r, absolutize(payload, root, path))
		if pkg == "" {
			continue
		}
		sd := StateDir(r, pkg)
		if err := os.MkdirAll(sd, 0o755); err != nil {
			continue
		}
		marker := filepath.Join(sd, "touched-"+SessionHash(r, session))
		if f, err := os.OpenFile(marker, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
			f.Close()
		}
		// 既にある印も「まだ触っている」印として鮮度を更新する。
		now := time.Now()
		_ = os.Chtimes(marker, now, now)
		sweepOldMarkers(r, sd)
		if !DaemonAlive(r, pkg) {
			// 温め直しの数秒を作業の区切りまで持ち越さない。増やしすぎの歯止めは
			// ReserveDaemon → tooBusy が持つ。
			ReserveDaemon(r, root, pkg)
		}
		ReserveDecls(pkg)
	}
	return 0
}

// ReserveDecls は、そのパッケージで refactor show を使ったこと（宣言の索引がある）があれば、裏で
// `fge refactor index --decls` を切り離して起動する。次の show が直したファイルの宣言を引いても待たずに済む。
// 同じ根で流れている間は、起動した側（decls.lock）が何もせずに降りる。
//
// WhyNot: show を使ったことの無いパッケージでは起動しない。索引は常駐の JVM で数秒の CPU を使うので、
// 探す口を使わない人の保存ごとに払わせない。
func ReserveDecls(pkg string) {
	if _, err := os.Stat(filepath.Join(pkg, "build", "refactor", "spans-resolved.decl.tsv")); err != nil {
		return
	}
	self, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(self, "refactor", "index", "--decls", "--root", pkg)
	cmd.Dir = pkg
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return
	}
	_ = cmd.Process.Release()
}

// SessionHash は印のファイル名に使うセッションの短い指紋。
func SessionHash(r *Rules, session string) string {
	sum := sha1.Sum([]byte(session))
	return hex.EncodeToString(sum[:])[:*r.Checkd.StateHashLen]
}

// absolutize はパッチ本文の相対パスを絶対パスにする。
// WhyNot: プロセスの cwd だけを見ないのは、apply_patch のパスがターンの cwd 基準で
// 来るため。ペイロード → CLAUDE_PROJECT_DIR → プロセスの cwd の順に、実在する物を優先する。
func absolutize(p Payload, root, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	cwd, _ := os.Getwd()
	var cands []string
	for _, base := range []string{p.str("cwd"), os.Getenv("CLAUDE_PROJECT_DIR"), root, cwd} {
		if base != "" {
			cands = append(cands, filepath.Join(base, path))
		}
	}
	for _, c := range cands {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	if len(cands) > 0 {
		return cands[0]
	}
	return path
}

// sweepOldMarkers は古い印を掃除する。
// WhyNot: 溜めっぱなしにしないのは、セッションが増え続けて印が居座るため。
func sweepOldMarkers(r *Rules, sd string) {
	entries, err := os.ReadDir(sd)
	if err != nil {
		return
	}
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), "touched-") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if time.Since(info.ModTime()).Seconds() > *r.Checkd.MarkerTTLSec {
			_ = os.Remove(filepath.Join(sd, e.Name()))
		}
	}
}
