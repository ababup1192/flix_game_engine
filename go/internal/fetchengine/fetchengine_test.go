package fetchengine

// 何を守るか: 落とした物が公開されている値と一致すること、持ち越す物が欠けたまま
// 組み上がらないこと、置き場の外へ書けないこと。

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"debug/elf"
	"debug/macho"
	"debug/pe"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/stageengine"
)

// 本物 (bin/lint-rules/stage-engine.json) と同じ形にそろえる — optional の有無や
// @fge-go の有無が違うと、実運用でだけ起きる失敗をテストが踏めない。
const stageRules = `{
  "items": [
    {"src": "@flix-jar", "dest": "bin/flix.jar", "why": "コンパイラ"},
    {"src": "@flix-wrapper", "dest": "bin/flix", "exec": true, "skipOnWindows": true, "owner": "studio", "why": "同梱 JRE を見るラッパ"},
    {"src": "@maven-seed/cache", "dest": "lib/cache", "owner": "studio", "optional": true, "why": "取り寄せた部品"},
    {"src": "@fge-go", "dest": "bin/fge-go", "destWindows": "bin/fge-go.exe", "exec": true, "why": "検査の中身"},
    {"src": "bin/githooks/pre-commit", "dest": "bin/githooks/pre-commit", "why": "ゲートの実体 (exec の印は無い)"},
    {"src": "Makefile", "dest": "Makefile", "why": "バージョンの出どころ"}
  ]
}`

// toolName は、テストを流している機械での検査の中身の置き先 (規約データの dest / destWindows)。
var toolName = map[bool]string{false: "bin/fge-go", true: "bin/fge-go.exe"}[runtime.GOOS == "windows"]

type zipEntry struct {
	body string
	mode os.FileMode
}

// 落とし物を組み立てる。zip の中身は engine/ の 1 段に入っている（本物と同じ形）。
func makeZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	moded := map[string]zipEntry{}
	for name, body := range files {
		moded[name] = zipEntry{body: body, mode: 0o644}
	}
	return makeZipOf(t, moded)
}

func makeZipOf(t *testing.T, files map[string]zipEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for name, e := range files {
		head := &zip.FileHeader{Name: "engine/" + name, Method: zip.Deflate}
		head.SetMode(e.mode)
		f, err := w.CreateHeader(head)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write([]byte(e.body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func sumOf(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func releaseJSON(t *testing.T, tag string, names ...string) []byte {
	t.Helper()
	rel := release{TagName: tag}
	for _, n := range names {
		rel.Assets = append(rel.Assets, asset{Name: n, URL: "https://example.test/" + n})
	}
	data, err := json.Marshal(rel)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// 通信の代わり。URL ごとに返す物を決めておく。
func fixedGet(pages map[string][]byte) func(string) ([]byte, error) {
	return func(url string) ([]byte, error) {
		if body, ok := pages[url]; ok {
			return body, nil
		}
		return nil, fmt.Errorf("見に行けません: %s", url)
	}
}

func newOpts(t *testing.T, pages map[string][]byte) *opts {
	t.Helper()
	return &opts{
		repo:     "owner/repo",
		apiBase:  "https://api.test",
		version:  "0.32.0",
		into:     t.TempDir(),
		progress: &strings.Builder{},
		get:      fixedGet(pages),
		runExe:   func(string, ...string) error { return nil },
	}
}

// 今の engine の置き場（持ち越しの写す元）。
func makeCurrent(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bin", "flix"), []byte("#!/bin/sh\nexec ../jre/bin/java -jar ...\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "lib", "cache", "org"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "lib", "cache", "org", "part.jar"), []byte("jar"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func pagesFor(t *testing.T, body []byte) map[string][]byte {
	t.Helper()
	zipName := ZipName("0.32.0")
	return map[string][]byte{
		"https://api.test/repos/owner/repo/releases/tags/v0.32.0": releaseJSON(t, "v0.32.0", zipName, SumsName),
		"https://example.test/" + zipName:                         body,
		"https://example.test/" + SumsName:                        []byte(sumOf(body) + "  " + zipName + "\n"),
	}
}

// 通しで入る: 照合が合い、engine/ の 1 段が外れ、持ち越す物が揃う。
func TestInstallsVerifiedZipAndCarriesStudioOwnedItems(t *testing.T) {
	body := makeZip(t, map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		"bin/flix.jar":                     "jar",
		toolName:                           "tool",
		"Makefile":                         "VERSION := 0.32.0\n",
	})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)

	res, err := install(o)
	if err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	if !res.Installed || res.Version != "0.32.0" {
		t.Fatalf("結果が違う: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(res.Dir, "bin", "flix.jar")); err != nil {
		t.Fatalf("zip の中身が置かれていない: %v", err)
	}
	if _, err := os.Stat(filepath.Join(res.Dir, "bin", "flix")); err != nil {
		t.Fatalf("持ち越す bin/flix が無い: %v", err)
	}
	if _, err := os.Stat(filepath.Join(res.Dir, "lib", "cache", "org", "part.jar")); err != nil {
		t.Fatalf("持ち越す lib/cache がフォルダごと来ていない: %v", err)
	}
	if info, err := os.Stat(filepath.Join(res.Dir, "bin", "flix")); err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("実行ビットが落ちている: %v", err)
	}
	if entries, _ := os.ReadDir(o.into); len(entries) != 1 {
		t.Fatalf("途中の場所が残っている: %v", entries)
	}
}

// zip が持っている実行ビットは、規約データに exec の印が無い物でも残る。
func TestKeepsExecutableBitFromTheZip(t *testing.T) {
	body := makeZipOf(t, map[string]zipEntry{
		"bin/lint-rules/stage-engine.json": {body: stageRules, mode: 0o644},
		"bin/githooks/pre-commit":          {body: "#!/bin/sh\n", mode: 0o755},
		toolName:                           {body: "tool", mode: 0o755},
		"Makefile":                         {body: "VERSION := 0.32.0\n", mode: 0o644},
	})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)

	res, err := install(o)
	if err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	info, err := os.Stat(filepath.Join(res.Dir, "bin", "githooks", "pre-commit"))
	if err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("exec の印が無い実行物の実行ビットが落ちた: %v", err)
	}
	info, err = os.Stat(filepath.Join(res.Dir, "Makefile"))
	if err != nil || info.Mode().Perm()&0o111 != 0 {
		t.Fatalf("走らせない物に実行ビットが付いた: %v", err)
	}
}

// optional な持ち越し物は、今の engine に無くても止めない
// （Maven の種を持たずに組んだ Studio がここで永久に上がらなくなる）。
func TestCarriesOnWithoutAnOptionalItem(t *testing.T) {
	body := makeZip(t, map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		toolName:                           "tool",
		"Makefile":                         "VERSION := 0.32.0\n",
	})
	o := newOpts(t, pagesFor(t, body))
	current := makeCurrent(t)
	if err := os.RemoveAll(filepath.Join(current, "lib")); err != nil {
		t.Fatal(err)
	}
	o.carryFrom = current

	res, err := install(o)
	if err != nil {
		t.Fatalf("optional が無いだけで止まった: %v", err)
	}
	for _, item := range res.CarriedTo {
		if item == "lib/cache" {
			t.Fatal("無い物を持ち越したと言っている")
		}
	}
}

// 今使っている engine と同じ場所へは入れ直さない（名前を付ける直前に消すのがそれ）。
func TestRefusesToReplaceTheEngineItIsCarryingFrom(t *testing.T) {
	body := makeZip(t, map[string]string{"bin/lint-rules/stage-engine.json": stageRules})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = filepath.Join(o.into, "0.32.0")

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), "今使っている engine") {
		t.Fatalf("今の engine の上へ入れ直した: %v", err)
	}
}

// 既に揃っている置き場は、落とし直さずに「置いた」として返す
// （展開の直後に落ちた後、押しても毎回失敗する袋小路を作らない）。
func TestTreatsAnAlreadyPlacedEngineAsDone(t *testing.T) {
	body := makeZip(t, map[string]string{"bin/lint-rules/stage-engine.json": stageRules})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)
	dest := filepath.Join(o.into, "0.32.0")
	if err := os.MkdirAll(filepath.Join(dest, "bin", "lint-rules"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "flix.toml"), []byte("[package]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "bin", "lint-rules", "stage-engine.json"), []byte(stageRules), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, filepath.FromSlash(toolName)), []byte("tool"), 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := install(o)
	if err != nil || !res.Installed || res.Dir != dest {
		t.Fatalf("既にある engine を置いた物として返さない: %+v / %v", res, err)
	}
}

// 揃っているように見えても中身が走らないなら、置き直す。
func TestReplacesAnAlreadyPlacedEngineThatDoesNotRun(t *testing.T) {
	body := makeZip(t, map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		toolName:                           "tool",
		"Makefile":                         "VERSION := 0.32.0\n",
	})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)
	dest := filepath.Join(o.into, "0.32.0")
	if err := os.MkdirAll(filepath.Join(dest, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "flix.toml"), []byte("[package]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "bin", "flix"), []byte("#!/bin/sh\nexec devbox run flix\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := install(o)
	if err != nil || !res.Installed {
		t.Fatalf("半端な engine を置き直せない: %v", err)
	}
	if _, err := os.Stat(filepath.Join(res.Dir, "Makefile")); err != nil {
		t.Fatalf("落とした中身に入れ替わっていない: %v", err)
	}
}

// 1 段目の外し方が合わない zip（区切りが \ の Windows 製など）で空の engine を置かない。
func TestRefusesZipWhoseEntriesAllFallAway(t *testing.T) {
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	f, err := w.Create(`engine\bin\flix.jar`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte("jar")); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}

	if err := unzipInto(buf.Bytes(), t.TempDir()); err == nil ||
		!strings.Contains(err.Error(), "取り出せる中身がありません") {
		t.Fatalf("空の中身を通した: %v", err)
	}
}

// 中身が公開されている値と違うなら入れない。
func TestRefusesZipWhoseSumDoesNotMatch(t *testing.T) {
	body := makeZip(t, map[string]string{"bin/lint-rules/stage-engine.json": stageRules})
	pages := pagesFor(t, body)
	pages["https://example.test/"+SumsName] = []byte(strings.Repeat("0", 64) + "  " + ZipName("0.32.0") + "\n")
	o := newOpts(t, pages)
	o.carryFrom = makeCurrent(t)

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), "公開されている値と違います") {
		t.Fatalf("違う zip を受け入れた: %v", err)
	}
	if entries, _ := os.ReadDir(o.into); len(entries) != 0 {
		t.Fatalf("失敗したのに残骸がある: %v", entries)
	}
}

// 照合の相手が添付されていないリリースは受けない。
func TestRefusesReleaseWithoutSums(t *testing.T) {
	body := makeZip(t, map[string]string{"bin/lint-rules/stage-engine.json": stageRules})
	pages := pagesFor(t, body)
	pages["https://api.test/repos/owner/repo/releases/tags/v0.32.0"] = releaseJSON(t, "v0.32.0", ZipName("0.32.0"))
	o := newOpts(t, pages)

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), SumsName) {
		t.Fatalf("照合の相手が無いのに進んだ: %v", err)
	}
}

// 持ち越す物が今の engine に無いなら、欠けたまま組み上げない。
func TestRefusesWhenACarriedItemIsMissing(t *testing.T) {
	body := makeZip(t, map[string]string{"bin/lint-rules/stage-engine.json": stageRules})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = t.TempDir()

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), "持ち越す") {
		t.Fatalf("持ち越す物が無いのに組み上げた: %v", err)
	}
	if entries, _ := os.ReadDir(o.into); len(entries) != 0 {
		t.Fatalf("失敗したのに残骸がある: %v", entries)
	}
}

// engine のラッパで上書きされていたら止める（Studio には nix も devbox も無い）。
func TestRefusesWhenWrapperIsNotTheBundledJreOne(t *testing.T) {
	body := makeZip(t, map[string]string{"bin/lint-rules/stage-engine.json": stageRules})
	o := newOpts(t, pagesFor(t, body))
	current := makeCurrent(t)
	if err := os.WriteFile(filepath.Join(current, "bin", "flix"), []byte("#!/bin/sh\nexec devbox run flix\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	o.carryFrom = current

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), "bin/flix") {
		t.Fatalf("走らないラッパを通した: %v", err)
	}
}

// この環境で走らない fge-go は受けない（zip に入るのは 1 つの OS/CPU 向けだけ）。
func TestRefusesWhenBundledToolDoesNotRun(t *testing.T) {
	body := makeZip(t, map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		"bin/fge-go":                       "not a real binary",
	})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)
	o.runExe = func(string, ...string) error { return fmt.Errorf("exec format error") }

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), "fge-go") {
		t.Fatalf("走らない道具を通した: %v", err)
	}
}

// 検査の中身が zip に無ければ止める（入れた後のゲームで bin/fge が毎回 exit 127 になる）。
func TestRefusesWhenBundledToolIsMissing(t *testing.T) {
	body := makeZip(t, map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		"Makefile":                         "VERSION := 0.32.0\n",
	})
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)

	if _, err := install(o); err == nil || !strings.Contains(err.Error(), "がありません") {
		t.Fatalf("検査の中身の無い engine を置いた: %v", err)
	}
}

// 実行ファイルの頭だけを持つ偽物（debug/macho・elf・pe が OS と CPU を読める最小の形）。
func fakeExe(t *testing.T, goos, arch string) string {
	t.Helper()
	var b bytes.Buffer
	le := binary.LittleEndian
	switch goos {
	case "darwin":
		cpu := map[string]uint32{"arm64": uint32(macho.CpuArm64), "amd64": uint32(macho.CpuAmd64)}[arch]
		for _, v := range []uint32{macho.Magic64, cpu, 0, uint32(macho.TypeExec), 0, 0, 0, 0} {
			_ = binary.Write(&b, le, v)
		}
	case "linux":
		m := map[string]uint16{"arm64": uint16(elf.EM_AARCH64), "amd64": uint16(elf.EM_X86_64)}[arch]
		b.Write([]byte{0x7f, 'E', 'L', 'F', 2, 1, 1, 0})
		b.Write(make([]byte, 8))
		for _, v := range []any{uint16(elf.ET_EXEC), m, uint32(1), uint64(0), uint64(0), uint64(0),
			uint32(0), uint16(64), uint16(56), uint16(0), uint16(64), uint16(0), uint16(0)} {
			_ = binary.Write(&b, le, v)
		}
	case "windows":
		m := map[string]uint16{"arm64": pe.IMAGE_FILE_MACHINE_ARM64, "amd64": pe.IMAGE_FILE_MACHINE_AMD64}[arch]
		dos := make([]byte, 64)
		copy(dos, "MZ")
		le.PutUint32(dos[0x3c:], 64)
		b.Write(dos)
		b.WriteString("PE\x00\x00")
		for _, v := range []any{m, uint16(0), uint32(0), uint32(0), uint32(0), uint16(0), uint16(0x22)} {
			_ = binary.Write(&b, le, v)
		}
		// pe.NewFile は頭の 96 バイトを一度に読むので、短いと EOF になる。
		b.Write(make([]byte, 64))
	default:
		t.Fatalf("偽物を作れない OS: %s", goos)
	}
	return b.String()
}

// bin/dist/ のある zip は、流している機械に合う物が bin/fge-go(.exe) に置き直され、他の機械向けは消える。
func TestInstallPutsTheToolForThisMachine(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" && runtime.GOOS != "windows" {
		t.Skip("偽物の頭を作れない OS")
	}
	files := map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		"bin/fge-go":                       fakeExe(t, "darwin", "arm64"),
		"bin/fge-go.exe":                   fakeExe(t, "windows", "amd64"),
		"bin/dist/fge-go-darwin-amd64":     fakeExe(t, "darwin", "amd64"),
		"bin/dist/fge-go-linux-amd64":      fakeExe(t, "linux", "amd64"),
		"bin/dist/fge-go-linux-arm64":      fakeExe(t, "linux", "arm64"),
		"Makefile":                         "VERSION := 0.32.0\n",
	}
	body := makeZip(t, files)
	o := newOpts(t, pagesFor(t, body))
	o.carryFrom = makeCurrent(t)

	res, err := install(o)
	if err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	goos, arch, ok := targetOf(filepath.Join(res.Dir, filepath.FromSlash(toolName)))
	if !ok || goos != runtime.GOOS || arch != runtime.GOARCH {
		t.Fatalf("この機械向けに置き直されていない: %s/%s", goos, arch)
	}
	if _, err := os.Stat(filepath.Join(res.Dir, "bin", "dist")); err == nil {
		t.Fatal("他の機械向けの bin/dist/ が残っている")
	}
}

func stagingWith(t *testing.T, files map[string]string) (string, *stageengine.Rules) {
	t.Helper()
	dir := t.TempDir()
	writeAt(t, filepath.Join(dir, "bin", "lint-rules", "stage-engine.json"), stageRules)
	for rel, body := range files {
		writeAt(t, filepath.Join(dir, filepath.FromSlash(rel)), body)
	}
	rules, err := stageengine.LoadRules(dir)
	if err != nil {
		t.Fatal(err)
	}
	return dir, rules
}

func writeAt(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func allTargets(t *testing.T) map[string]string {
	return map[string]string{
		"bin/fge-go":                   fakeExe(t, "darwin", "arm64"),
		"bin/fge-go.exe":               fakeExe(t, "windows", "amd64"),
		"bin/dist/fge-go-darwin-amd64": fakeExe(t, "darwin", "amd64"),
		"bin/dist/fge-go-linux-amd64":  fakeExe(t, "linux", "amd64"),
		"bin/dist/fge-go-linux-arm64":  fakeExe(t, "linux", "arm64"),
	}
}

func TestPickFgeGoReadsWhatEachToolRunsOn(t *testing.T) {
	cases := map[string][2]string{
		"darwin":  {"darwin", "arm64"},
		"windows": {"windows", "amd64"},
		"linux":   {"linux", "arm64"},
	}
	for name, c := range cases {
		path := filepath.Join(t.TempDir(), "x")
		writeAt(t, path, fakeExe(t, c[0], c[1]))
		goos, arch, ok := targetOf(path)
		if !ok || goos != c[0] || arch != c[1] {
			t.Errorf("%s: %s/%s (%v)", name, goos, arch, ok)
		}
	}
}

func TestPickFgeGoPutsTheLinuxOneAtTheToolName(t *testing.T) {
	dir, rules := stagingWith(t, allTargets(t))
	if err := pickFgeGo(rules, dir, "linux", "amd64"); err != nil {
		t.Fatal(err)
	}
	goos, arch, _ := targetOf(filepath.Join(dir, "bin", "fge-go"))
	if goos+"/"+arch != "linux/amd64" {
		t.Fatalf("linux/amd64 向けに置き直されていない: %s/%s", goos, arch)
	}
}

func TestPickFgeGoKeepsOnlyTheToolForThisMachine(t *testing.T) {
	dir, rules := stagingWith(t, allTargets(t))
	if err := pickFgeGo(rules, dir, "darwin", "amd64"); err != nil {
		t.Fatal(err)
	}
	var left []string
	_ = filepath.WalkDir(filepath.Join(dir, "bin"), func(p string, d os.DirEntry, err error) error {
		if err == nil && strings.HasPrefix(d.Name(), "fge-go") {
			left = append(left, d.Name())
		}
		return nil
	})
	if len(left) != 1 || left[0] != "fge-go" {
		t.Fatalf("他の機械向けが残っている: %v", left)
	}
}

func TestPickFgeGoPutsTheWindowsOneAtExe(t *testing.T) {
	dir, rules := stagingWith(t, allTargets(t))
	if err := pickFgeGo(rules, dir, "windows", "amd64"); err != nil {
		t.Fatal(err)
	}
	goos, _, _ := targetOf(filepath.Join(dir, "bin", "fge-go.exe"))
	if goos != "windows" {
		t.Fatalf("bin/fge-go.exe が windows 向けでない: %s", goos)
	}
}

// 0.102.0 までの zip（CI の linux 向け 1 つだけ）は、機械の名前と入っている物を言って止める。
func TestPickFgeGoNamesTheMachineWhenNothingFits(t *testing.T) {
	dir, rules := stagingWith(t, map[string]string{"bin/fge-go": fakeExe(t, "linux", "amd64")})
	err := pickFgeGo(rules, dir, "darwin", "arm64")
	if err == nil || !strings.Contains(err.Error(), "darwin/arm64") || !strings.Contains(err.Error(), "linux/amd64") {
		t.Fatalf("合う物が無いのに分かる言葉で止まらない: %v", err)
	}
}

// 頭の読めない置き先（sh など）は、決めつけずに後の --version に任せる。
func TestPickFgeGoLeavesAnUnreadableToolToTheRunCheck(t *testing.T) {
	dir, rules := stagingWith(t, map[string]string{"bin/fge-go": "#!/bin/sh\n"})
	if err := pickFgeGo(rules, dir, "darwin", "arm64"); err != nil {
		t.Fatalf("読めないだけで止めた: %v", err)
	}
}

// zip の中の ../ で置き場の外へ書かせない。
func TestRefusesZipEntryThatEscapesTheDestination(t *testing.T) {
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	f, err := w.Create("engine/../../escaped.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()

	if err := unzipInto(buf.Bytes(), dest); err == nil {
		t.Fatal("置き場の外を指す名前を通した")
	}
}

// 見に行くだけ: 今のバージョンより新しいときだけ available。
func TestCheckReportsOnlyNewerVersions(t *testing.T) {
	pages := map[string][]byte{
		"https://api.test/repos/owner/repo/releases/latest": releaseJSON(t, "v0.32.0", ZipName("0.32.0"), SumsName),
	}
	for _, tc := range []struct {
		current string
		want    bool
	}{
		{"0.31.0", true},
		{"0.32.0", false},
		{"0.33.0", false},
	} {
		o := newOpts(t, pages)
		o.check = true
		o.asJSON = true
		o.current = tc.current
		var out, errOut strings.Builder
		if code, err := runCheck(&out, &errOut, o); code != exitDone || err != nil {
			t.Fatalf("current=%s: code=%d err=%v (%s)", tc.current, code, err, errOut.String())
		}
		var res checkResult
		if err := json.Unmarshal([]byte(out.String()), &res); err != nil {
			t.Fatal(err)
		}
		if res.Available != tc.want {
			t.Fatalf("current=%s: available=%v を期待 %v", tc.current, res.Available, tc.want)
		}
	}
}

// タグの読み方。
func TestVersionFromTag(t *testing.T) {
	for _, tc := range []struct{ tag, want string }{
		{"v0.32.0", "0.32.0"},
		{"0.32.0", "0.32.0"},
		{"nightly", ""},
		{"v../etc", ""},
	} {
		if got := VersionFromTag(tc.tag); got != tc.want {
			t.Fatalf("%s: %q を期待 %q", tc.tag, got, tc.want)
		}
	}
}

// フォルダ名として置いてよい字。
func TestIsVersionName(t *testing.T) {
	for _, tc := range []struct {
		name string
		want bool
	}{
		{"0.31.0", true},
		{"0.32.0-rc1", true},
		{"", false},
		{"..", false},
		{"a/b", false},
		{"C:", false},
		{"0.31 0", false},
		{"CON", false},
		{strings.Repeat("0", 65), false},
	} {
		if got := IsVersionName(tc.name); got != tc.want {
			t.Fatalf("%q: %v を期待 %v", tc.name, got, tc.want)
		}
	}
}

// バージョンの前後は数字の列として比べる（字の順で 0.9.0 > 0.31.0 と読み違えない）。
func TestIsNewer(t *testing.T) {
	for _, tc := range []struct {
		current, candidate string
		want               bool
	}{
		{"0.9.0", "0.31.0", true},
		{"0.31.0", "0.9.0", false},
		{"0.31.0", "0.31.0", false},
		{"0.31", "0.31.1", true},
		{"0.31.0", "0.32.0-rc1", false},
		{"nightly", "0.32.0", false},
	} {
		if got := IsNewer(tc.current, tc.candidate); got != tc.want {
			t.Fatalf("%s → %s: %v を期待 %v", tc.current, tc.candidate, got, tc.want)
		}
	}
}

// SHA256SUMS.txt の読み方。人が書いた覚え書きを値として拾わない。
func TestSumFor(t *testing.T) {
	text := strings.Repeat("a", 64) + "  other.zip\n" +
		strings.Repeat("b", 64) + "  target.zip\n" +
		"abc  target.zip\n"
	if got := SumFor(text, "target.zip"); got != strings.Repeat("b", 64) {
		t.Fatalf("値が違う: %q", got)
	}
	if got := SumFor(text, "missing.zip"); got != "" {
		t.Fatalf("無い名前で値が出た: %q", got)
	}
	if got := SumFor("zzzz  target.zip\n", "target.zip"); got != "" {
		t.Fatalf("16 進でない値を拾った: %q", got)
	}
	binary := strings.Repeat("c", 64) + " *target.zip\n"
	if got := SumFor(binary, "target.zip"); got != strings.Repeat("c", 64) {
		t.Fatalf("印つきの形が読めない: %q", got)
	}
}

// 本物の規約データでも通ること（見本の作り物とずれたら気づく）。
func TestRealStageRulesCarryOnlyStudioOwnedItems(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "stage-engine.json"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "bin", "lint-rules"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bin", "lint-rules", "stage-engine.json"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	rules, err := stageengine.LoadRules(dir)
	if err != nil {
		t.Fatal(err)
	}
	carried := map[string]bool{}
	for _, it := range rules.Items {
		if it.OwnedByStudio() {
			carried[it.DestOf(false)] = it.Optional
		}
	}
	// bin/flix は必須 (無ければ Studio でゲームがビルドできない)、
	// 取り寄せた部品は optional (種を持たないマシンでも上げられる)。
	if optional, ok := carried["bin/flix"]; !ok || optional {
		t.Fatalf("bin/flix の持ち越しが必須でない: %v", carried)
	}
	if optional, ok := carried["lib/cache"]; !ok || !optional {
		t.Fatalf("lib/cache の持ち越しが optional でない: %v", carried)
	}
	if destForSrc(rules, "@fge-go", false) != "bin/fge-go" {
		t.Fatalf("検査の中身の置き先が引けない: %q", destForSrc(rules, "@fge-go", false))
	}
}

// zip の 1 段目 (engine/) を外す。
func TestStripTopDir(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"engine/bin/flix", "bin/flix"},
		{"engine/Makefile", "Makefile"},
		{"engine/", ""},
		{"engine", ""},
	} {
		if got := stripTopDir(tc.in); got != tc.want {
			t.Fatalf("%q: %q を期待 %q", tc.in, got, tc.want)
		}
	}
}
