package checkd

// flixlint の常駐の check を使うクライアント (checkd-freshness §3・§4.4・C-2)。
//
// check はいつもこの道 (hooks.json に checkd.server が無いか CHECKD_BACKEND=cli なら素の flix check)。常駐は flixlint の Resident で、lint・refactor の
// 索引と 1 つの JVM・1 つのコンパイラを共有する。答えには「どのソースを検査したか」の版が付き、答えを受けた後に
// ディスクから版を取り直して同じ時だけ使う。違えば頼み直し (retries 回)、それでも合わなければ素の flix check。
//
// 口の形 (protocol 2)・socket の名前・版の式は flixlint の README "Resident server" が正で、testdata/resident は
// flixlint のリリースの test/resident の写し (同じバイト列を読み書きできる事を resident_test.go で確かめる)。

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// residentProtocol は flixlint の常駐と話す口の版。
const residentProtocol = 2

// 常駐のクライアントの終わり方 (flixlint の Resident.client と同じ番号)。
const (
	residentNoServer = 11
	residentLost     = 12
)

// useServer は check を flixlint の常駐に頼むか: hooks.json に checkd.server があり、CHECKD_BACKEND=cli でない時。
func useServer(r *hooks.Rules) bool {
	return r.Checkd.Server.BackendEnvVar != nil && os.Getenv(*r.Checkd.Server.BackendEnvVar) != "cli"
}

// ---- 口 (Java の DataOutputStream の形) ----

// residentRequest は頼み 1 つ。
type residentRequest struct {
	Kind, Root, Identity string
	Settings, Args       []string
}

// residentFrame は答えの枠 1 つ。Tag は 'O' 'E' 'Q' 'V' 'X'。
type residentFrame struct {
	Tag      byte
	Bytes    []byte // O・E
	Ahead    int32  // Q
	Running  string // Q
	Seconds  int32  // Q
	Version  string // V
	ExitCode int32  // X
}

// modifiedUTF8 は Java の writeUTF の中身: NUL は 2 バイト、BMP の外の字は代理対の 2 つを 3 バイトずつ。
func modifiedUTF8(s string) []byte {
	var b []byte
	for _, c := range utf16.Encode([]rune(s)) {
		switch {
		case c != 0 && c < 0x80:
			b = append(b, byte(c))
		case c < 0x800:
			b = append(b, byte(0xc0|c>>6), byte(0x80|c&0x3f))
		default:
			b = append(b, byte(0xe0|c>>12), byte(0x80|(c>>6)&0x3f), byte(0x80|c&0x3f))
		}
	}
	return b
}

// fromModifiedUTF8 は modifiedUTF8 の逆。
func fromModifiedUTF8(b []byte) (string, error) {
	var units []uint16
	for i := 0; i < len(b); {
		c := b[i]
		switch {
		case c < 0x80:
			units = append(units, uint16(c))
			i++
		case c&0xe0 == 0xc0 && i+1 < len(b):
			units = append(units, uint16(c&0x1f)<<6|uint16(b[i+1]&0x3f))
			i += 2
		case c&0xf0 == 0xe0 && i+2 < len(b):
			units = append(units, uint16(c&0x0f)<<12|uint16(b[i+1]&0x3f)<<6|uint16(b[i+2]&0x3f))
			i += 3
		default:
			return "", fmt.Errorf("modified UTF-8 の崩れ (%d バイト目)", i)
		}
	}
	return string(utf16.Decode(units)), nil
}

func writeUTF(w *bytes.Buffer, s string) {
	b := modifiedUTF8(s)
	_ = binary.Write(w, binary.BigEndian, uint16(len(b)))
	w.Write(b)
}

func readUTF(r io.Reader) (string, error) {
	var n uint16
	if err := binary.Read(r, binary.BigEndian, &n); err != nil {
		return "", err
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return "", err
	}
	return fromModifiedUTF8(b)
}

func readInt(r io.Reader) (int32, error) {
	var v int32
	err := binary.Read(r, binary.BigEndian, &v)
	return v, err
}

// encodeRequest は頼みのバイト列。
func encodeRequest(q residentRequest) []byte {
	var w bytes.Buffer
	_ = binary.Write(&w, binary.BigEndian, int32(residentProtocol))
	writeUTF(&w, q.Kind)
	writeUTF(&w, q.Root)
	writeUTF(&w, q.Identity)
	for _, list := range [][]string{q.Settings, q.Args} {
		_ = binary.Write(&w, binary.BigEndian, int32(len(list)))
		for _, s := range list {
			writeUTF(&w, s)
		}
	}
	return w.Bytes()
}

// encodeFrame は答えの枠のバイト列 (テストで flixlint の reply.hex と比べる)。
func encodeFrame(f residentFrame) []byte {
	var w bytes.Buffer
	w.WriteByte(f.Tag)
	switch f.Tag {
	case 'O', 'E':
		_ = binary.Write(&w, binary.BigEndian, int32(len(f.Bytes)))
		w.Write(f.Bytes)
	case 'Q':
		_ = binary.Write(&w, binary.BigEndian, f.Ahead)
		writeUTF(&w, f.Running)
		_ = binary.Write(&w, binary.BigEndian, f.Seconds)
	case 'V':
		writeUTF(&w, f.Version)
	case 'X':
		_ = binary.Write(&w, binary.BigEndian, f.ExitCode)
	}
	return w.Bytes()
}

// readFrame は答えの枠を 1 つ読む。
func readFrame(r io.Reader) (residentFrame, error) {
	var tag [1]byte
	if _, err := io.ReadFull(r, tag[:]); err != nil {
		return residentFrame{}, err
	}
	f := residentFrame{Tag: tag[0]}
	var err error
	switch f.Tag {
	case 'O', 'E':
		var n int32
		if n, err = readInt(r); err == nil {
			f.Bytes = make([]byte, n)
			_, err = io.ReadFull(r, f.Bytes)
		}
	case 'Q':
		if f.Ahead, err = readInt(r); err == nil {
			if f.Running, err = readUTF(r); err == nil {
				f.Seconds, err = readInt(r)
			}
		}
	case 'V':
		f.Version, err = readUTF(r)
	case 'X':
		f.ExitCode, err = readInt(r)
	default:
		err = fmt.Errorf("知らない枠 %q", f.Tag)
	}
	return f, err
}

// ---- socket の名前・版の式 ----

// socketName は根と identity の socket の名前 (拡張子の前): 「根・改行・identity」の SHA-256 の頭 16 字。
func socketName(root, identity string) string {
	sum := sha256.Sum256([]byte(root + "\n" + identity))
	return hex.EncodeToString(sum[:])[:16]
}

// versionExtra はソースのほかに版に入るファイル。
var versionExtra = []string{"flix.toml", "packages.lock"}

// sourcesVersion はディスクにある今のソースの版 (flixlint の README "Resident server" の Version)。
// src/・test/ の .flix (ファイルの symlink は数え、symlink のディレクトリには入らない。Flix の Bootstrap と同じ) と
// flix.toml・packages.lock。1 件ずつ「根からの相対パス (/ 区切り)・NUL・中身の SHA-256 の 16 進・NUL」を、パスの
// バイト順に並べた全体の SHA-256。
func sourcesVersion(root string) (string, error) {
	var files []string
	for _, dir := range []string{"src", "test"} {
		base := filepath.Join(root, dir)
		if info, err := os.Stat(base); err != nil || !info.IsDir() {
			continue
		}
		err := filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !strings.HasSuffix(d.Name(), ".flix") {
				return nil
			}
			if d.Type()&fs.ModeSymlink != 0 {
				// symlink の先がファイルの時だけ数える (先がディレクトリなら Bootstrap も入らない)
				if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
					return nil
				}
			} else if !d.Type().IsRegular() {
				return nil
			}
			files = append(files, path)
			return nil
		})
		if err != nil {
			return "", err
		}
	}
	for _, f := range versionExtra {
		if info, err := os.Stat(filepath.Join(root, f)); err == nil && info.Mode().IsRegular() {
			files = append(files, filepath.Join(root, f))
		}
	}
	type entry struct{ rel, sum string }
	entries := make([]entry, 0, len(files))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", err
		}
		rel, err := filepath.Rel(root, f)
		if err != nil {
			return "", err
		}
		sum := sha256.Sum256(b)
		entries = append(entries, entry{filepath.ToSlash(rel), hex.EncodeToString(sum[:])})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].rel < entries[j].rel })
	all := sha256.New()
	for _, e := range entries {
		all.Write([]byte(e.rel))
		all.Write([]byte{0})
		all.Write([]byte(e.sum))
		all.Write([]byte{0})
	}
	return hex.EncodeToString(all.Sum(nil)), nil
}

// ---- 常駐を探し、起こし、頼む ----

// residentSetup は 1 つのパッケージの常駐に話すのに要る物。
type residentSetup struct {
	flixJar, shimJar, java, identity, socket, log string
}

// prepareResident は flix.jar・shim の jar・identity・socket を揃える。
func prepareResident(r *hooks.Rules, root, pkg string) (residentSetup, error) {
	var s residentSetup
	out, err := exec.Command("env", "FLIX_PRINT_JAR=1", flixBin(root, pkg)).Output()
	if err != nil {
		return s, fmt.Errorf("flix.jar の場所が分からない: %v", err)
	}
	s.flixJar = strings.TrimSpace(string(out))
	if s.shimJar, err = shimJar(r); err != nil {
		return s, err
	}
	s.java = javaCmd(root)
	flixSum, err := cachedSum(r, s.flixJar)
	if err != nil {
		return s, err
	}
	shimSum, err := cachedSum(r, s.shimJar)
	if err != nil {
		return s, err
	}
	s.identity = "flix=" + flixSum + " shim=" + shimSum
	cache, err := os.UserCacheDir()
	if err != nil {
		return s, err
	}
	s.socket = filepath.Join(cache, "flixlint", socketName(pkg, s.identity)+".sock")
	s.log = strings.TrimSuffix(s.socket, ".sock") + ".log"
	return s, nil
}

// shimJar は flixlint の shim の jar (無ければリリースから取り、sha256 が合う時だけ置く)。
func shimJar(r *hooks.Rules) (string, error) {
	sv := r.Checkd.Server
	path := filepath.Join(hooks.CacheDir(r), "flixlint", *sv.FlixlintVersion, *sv.ShimJar)
	if sum, err := fileSum(path); err == nil && sum == *sv.ShimSHA256 {
		return path, nil
	}
	url := strings.NewReplacer("{version}", *sv.FlixlintVersion, "{jar}", *sv.ShimJar).Replace(*sv.ShimURL)
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("flixlint の shim を取れない (%s): %v", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("flixlint の shim を取れない (%s): %s", url, resp.Status)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	got := sha256.Sum256(body)
	if hex.EncodeToString(got[:]) != *sv.ShimSHA256 {
		return "", fmt.Errorf("flixlint の shim (%s) の sha256 が hooks.json の checkd.server.shimSha256 と違うので置かない", url)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	part := path + ".part"
	if err := os.WriteFile(part, body, 0o644); err != nil {
		return "", err
	}
	return path, os.Rename(part, path)
}

// javaCmd は bin/flix と同じ決め方の java: PATH の java が動かなければエンジンの devbox の jdk。
func javaCmd(root string) string {
	if exec.Command("java", "-version").Run() == nil {
		return "java"
	}
	return filepath.Join(root, ".devbox", "nix", "profile", "default", "bin", "java")
}

func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// cachedSum はファイルの SHA-256 を、パス・大きさ・mtime の鍵で checkd の置き場に覚えて返す (flix.jar は数十 MB)。
func cachedSum(r *hooks.Rules, path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	key := sha256.Sum256([]byte(fmt.Sprintf("%s %d %d", path, info.Size(), info.ModTime().UnixNano())))
	kept := filepath.Join(hooks.CacheDir(r), "hash", hex.EncodeToString(key[:16]))
	if b, err := os.ReadFile(kept); err == nil {
		return strings.TrimSpace(string(b)), nil
	}
	sum, err := fileSum(path)
	if err != nil {
		return "", err
	}
	_ = os.MkdirAll(filepath.Dir(kept), 0o755)
	_ = os.WriteFile(kept, []byte(sum+"\n"), 0o644)
	return sum, nil
}

// startResident は flixlint の常駐を切り離して起こす (ログは socket の隣)。
func startResident(r *hooks.Rules, s residentSetup, pkg string) error {
	sv := r.Checkd.Server
	if err := os.MkdirAll(filepath.Dir(s.socket), 0o755); err != nil {
		return err
	}
	log, err := os.OpenFile(s.log, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer log.Close()
	args := append([]string{}, sv.JavaOpts...)
	args = append(args, fmt.Sprintf("-Xmx%dm", *sv.HeapMB), "-cp", s.flixJar+string(os.PathListSeparator)+s.shimJar,
		"flixlint.Resident", "server", "--socket", s.socket, "--root", pkg, "--identity", s.identity,
		"--idle-minutes", strconv.Itoa(*sv.IdleMinutes), "--run-limit", strconv.Itoa(*sv.RunLimitSec))
	cmd := exec.Command(s.java, args...)
	cmd.Dir = pkg
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, log, log
	hooks.Detach(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

// residentAnswer は常駐の check の答え。
type residentAnswer struct {
	code         int
	stdout       []byte
	stderr       []byte
	version      string
	waitedBehind int
}

// askResident は常駐に check を頼み、答えを読む。つながらなければ errNoServer。
// 時間切れは自分の走行が始まってから (Q 0 から) 数える。
func askResident(r *hooks.Rules, s residentSetup, pkg string, connectWait time.Duration) (residentAnswer, error) {
	var a residentAnswer
	var conn net.Conn
	var err error
	deadline := time.Now().Add(connectWait)
	for {
		conn, err = net.Dial("unix", s.socket)
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		return a, errNoServer
	}
	defer conn.Close()
	if _, err := conn.Write(encodeRequest(residentRequest{Kind: "check", Root: pkg, Identity: s.identity})); err != nil {
		return a, errNoServer
	}
	work := seconds(*r.Checkd.Daemon.WorkTimeoutSec)
	_ = conn.SetReadDeadline(time.Now().Add(work))
	var out, errb bytes.Buffer
	for {
		f, err := readFrame(conn)
		if err != nil {
			return a, errLost
		}
		switch f.Tag {
		case 'O':
			out.Write(f.Bytes)
		case 'E':
			errb.Write(f.Bytes)
		case 'Q':
			if f.Ahead == 0 {
				_ = conn.SetReadDeadline(time.Now().Add(work))
			} else if int(f.Ahead) > a.waitedBehind {
				a.waitedBehind = int(f.Ahead)
			}
		case 'V':
			a.version = f.Version
		case 'X':
			a.code, a.stdout, a.stderr = int(f.ExitCode), out.Bytes(), errb.Bytes()
			if a.code == residentNoServer {
				return a, errNoServer
			}
			return a, nil
		}
	}
}

var (
	errNoServer = errors.New("常駐が居ない")
	errLost     = errors.New("常駐が走行の途中で居なくなった")
)

// serverCheck は flixlint の常駐で check し、版がディスクと合う答えだけを使う。合わなければ頼み直し、
// それでも駄目なら素の flix check。常駐が居なければ 1 回だけ起こす。
func serverCheck(r *hooks.Rules, out, errOut *strings.Builder, root, pkg string) int {
	s, err := prepareResident(r, root, pkg)
	if err != nil {
		debugLog(errOut, "flixlint の常駐の支度ができない ("+err.Error()+") → 素の check へ")
		return runFallback(root, pkg, "check")
	}
	sv := r.Checkd.Server
	t0 := time.Now()
	started := false
	retries := 0
	for {
		a, err := askResident(r, s, pkg, 0)
		if err != nil && !started {
			debugLog(errOut, "flixlint の常駐が居ない ("+err.Error()+") → 起こす: "+s.log)
			started = true
			if err = startResident(r, s, pkg); err == nil {
				a, err = askResident(r, s, pkg, seconds(*r.Checkd.Daemon.SpawnWaitSec))
			}
		}
		if err != nil {
			debugLog(errOut, "flixlint の常駐と話せない ("+err.Error()+") → 素の check へ")
			logCheck(r, pkg, "fallback", -1, "", retries, time.Since(t0))
			return runFallback(root, pkg, "check")
		}
		now, verr := sourcesVersion(pkg)
		if verr == nil && a.version != "" && a.version == now {
			writeServerMark(r, pkg, s)
			os.Stderr.Write(a.stderr)
			out.Write(a.stdout)
			debugLog(errOut, fmt.Sprintf("version=%s retry=%d", a.version, retries))
			logCheck(r, pkg, "server", a.code, a.version, retries, time.Since(t0))
			return a.code
		}
		if retries >= *sv.Retries {
			debugLog(errOut, fmt.Sprintf("答えの版 %s がディスクの %s と %d 回合わない → 素の check へ", a.version, now, retries+1))
			logCheck(r, pkg, "fallback", a.code, a.version, retries, time.Since(t0))
			return runFallback(root, pkg, "check")
		}
		retries++
		debugLog(errOut, fmt.Sprintf("検査の間にソースが変わった (答え %s・今 %s) → 頼み直す (%d 回目)", a.version, now, retries))
	}
}

// logCheck は 1 回の check を daemon.log に 1 行残す (C-2 の数え上げ: 版が合わず頼み直した数・素の CLI に落ちた数)。
func logCheck(r *hooks.Rules, pkg, how string, code int, version string, retries int, took time.Duration) {
	f, err := os.OpenFile(filepath.Join(stateDir(r, pkg), "daemon.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s check via=%s exit=%d version=%s retry=%d %.2fs\n",
		time.Now().Format(time.RFC3339), how, code, version, retries, took.Seconds())
}

// Shared は lint・refactor の索引がこの check と同じ常駐を使うための値（同じ flix.jar・shim の jar なら identity が同じで、
// socket も同じ 1 本になる。ヒープと寿命は先に起こした方の物になるので、どちらも同じ値を渡す）。
type Shared struct {
	FlixJar, ShimJar    string
	HeapMB, IdleMinutes int
}

// SharedServer は hooks.json の checkd.server から Shared を作る。節が無いか jar を用意できなければ err。
func SharedServer(r *hooks.Rules, engineRoot, pkg string) (Shared, error) {
	if r.Checkd.Server.BackendEnvVar == nil {
		return Shared{}, errors.New("hooks.json に checkd.server が無い")
	}
	out, err := exec.Command("env", "FLIX_PRINT_JAR=1", flixBin(engineRoot, pkg)).Output()
	if err != nil {
		return Shared{}, fmt.Errorf("flix.jar の場所が分からない: %v", err)
	}
	shim, err := shimJar(r)
	if err != nil {
		return Shared{}, err
	}
	sv := r.Checkd.Server
	return Shared{FlixJar: strings.TrimSpace(string(out)), ShimJar: shim, HeapMB: *sv.HeapMB, IdleMinutes: *sv.IdleMinutes}, nil
}

// serverMark は、そのパッケージの check を流した常駐の記録（状態の置き場の server。stop・stop-all と、編集フックの
// 「常駐が居るか」が読む）。
type serverMark struct{ socket, pkg, identity string }

func writeServerMark(r *hooks.Rules, pkg string, s residentSetup) {
	_ = os.WriteFile(filepath.Join(stateDir(r, pkg), "server"), []byte(s.socket+"\n"+pkg+"\n"+s.identity+"\n"), 0o644)
}

func readServerMark(dir string) (serverMark, bool) {
	b, err := os.ReadFile(filepath.Join(dir, "server"))
	if err != nil {
		return serverMark{}, false
	}
	f := strings.SplitN(strings.TrimRight(string(b), "\n"), "\n", 3)
	if len(f) != 3 {
		return serverMark{}, false
	}
	return serverMark{socket: f[0], pkg: f[1], identity: f[2]}, true
}

// stopServer はそのパッケージの記録の常駐に stop を頼む（居なかった時は false）。記録はどちらでも消す。
func stopServer(r *hooks.Rules, pkg string) bool {
	dir := hooks.StateDir(r, pkg)
	m, ok := readServerMark(dir)
	if !ok {
		return false
	}
	defer os.Remove(filepath.Join(dir, "server"))
	conn, err := net.DialTimeout("unix", m.socket, seconds(*r.Checkd.Daemon.ConnectTimeoutSec))
	if err != nil {
		return false
	}
	defer conn.Close()
	if _, err := conn.Write(encodeRequest(residentRequest{Kind: "stop", Root: m.pkg, Identity: m.identity})); err != nil {
		return false
	}
	_ = conn.SetReadDeadline(time.Now().Add(seconds(*r.Checkd.Daemon.ConnectTimeoutSec)))
	for {
		f, err := readFrame(conn)
		if err != nil {
			return false
		}
		if f.Tag == 'X' {
			return f.ExitCode == 0
		}
	}
}
