package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const teavmVersion = "0.16.0"

// teavmArtifact は TeaVM で wasm を作るのに要る jar 1 本（Maven の座標と、取った後に照合する SHA-256）。
type teavmArtifact struct {
	Group, Artifact, Version, SHA256 string
}

// teavmArtifacts は TeaVM 0.16.0 の TeaVMTool（fge.teavmfix.BuildWasm が呼ぶ）が要る jar の一式。
// WhyNot: Maven の依存の解決（pom を読んで推移先をたどる）を書かないのは、版を固定して照合するためには一覧を
// ソースに持つ方が確かで、解決器を持つと TeaVM の pom が変わったときに知らせずに別の jar を取りうるため。
var teavmArtifacts = []teavmArtifact{
	{"org.teavm", "teavm-classlib", teavmVersion, "329fd2a9cfb3afb453070cb97c12adb5c0ee7b0d943b357188d7dbf9c6bf3dd5"},
	{"org.teavm", "teavm-core", teavmVersion, "c94539912c1b951fa741aecfcb6b4acad75c2e2360dc8859b1edd0c44175608a"},
	{"org.teavm", "teavm-extension-apis", teavmVersion, "9e867f3760b1c8d86cdb18ec70e429c23fd933021c8c3bb0cc0b727eac3202c0"},
	{"org.teavm", "teavm-extension-spi", teavmVersion, "e280bbc31e8d26de2915954990e260871462c146418c7b901249502a1994dde5"},
	{"org.teavm", "teavm-extension-spi-util", teavmVersion, "d94e8d4478c4186d18b657cb67654851d38b9f51d372dc7e7e54e0f3a24347c9"},
	{"org.teavm", "teavm-interop", teavmVersion, "5c8511d71ae6f6d2ca913130393b64a959303e521727b2d9c1a9b1e14519216f"},
	{"org.teavm", "teavm-jso", teavmVersion, "58b337b93924106bf819c45890c7c231a0c740145afe77795f1e0f099f621d71"},
	{"org.teavm", "teavm-jso-apis", teavmVersion, "32d28e39957a41404f53a14c2447d980c7b5074a92414d0972014f448a46fcb2"},
	{"org.teavm", "teavm-jso-impl", teavmVersion, "12688d04e7d2d73036adacd72b74fd8fb44f10283004075fbe68706ccb223b75"},
	{"org.teavm", "teavm-metaprogramming-api", teavmVersion, "00f053ad35ff78312e48eebbf4e1c6cf5f7a1e759b2432ba0b60d6f111bb3bdd"},
	{"org.teavm", "teavm-metaprogramming-impl", teavmVersion, "616d30aa28f7b0180a61c2289b11c77bf84c715bd79f255e1e42400edb5b6d70"},
	{"org.teavm", "teavm-platform", teavmVersion, "999d369ab15aa83c17987d048ba59560759169891de7e13a5a1c2bd93dd060a8"},
	{"org.teavm", "teavm-tooling", teavmVersion, "8335feb227d299bf51ba3862e84eb3a2723ff2e9840a885a7537f6454d44ee31"},
	{"org.teavm", "teavm-relocated-libs-asm", teavmVersion, "59deba713805038fb9ceb76f002e3ae0e9660ec9815875917f08e0a235b7b1a2"},
	{"org.teavm", "teavm-relocated-libs-asm-analysis", teavmVersion, "8ce092f26dc44cffbfd6a23067b0ae43e32f9ddb29efd6e4eed93095a454b04a"},
	{"org.teavm", "teavm-relocated-libs-asm-commons", teavmVersion, "b877abd3af4f9ae2650aa0cb3577fcbdd66a9a1a1181d545d5f1f20070ea5924"},
	{"org.teavm", "teavm-relocated-libs-asm-tree", teavmVersion, "e0bd21e6734b1f060c0553c66fe20292f49d146858aec1f1ecfe21f6417885f6"},
	{"org.teavm", "teavm-relocated-libs-asm-util", teavmVersion, "c69ce1813eaa66643361b70b3f07c13ca924185280c237c832774a2f85eaf431"},
	{"org.teavm", "teavm-relocated-libs-hppc", teavmVersion, "7b82fedf747e0bf5d7a50acece86a8a684901e469165a3c5621c653128df4cd6"},
	{"org.teavm", "teavm-relocated-libs-rhino", teavmVersion, "ea776a11f0233ba9e3fd12faf81cca2101b42443d0d22084e2627898fd7ee76e"},
	{"commons-io", "commons-io", "2.20.0", "df90bba0fe3cb586b7f164e78fe8f8f4da3f2dd5c27fa645f888100ccc25dd72"},
	{"joda-time", "joda-time", "2.12.2", "8d4d807adc8e92a83913d9ccd61e634b4907c78d88f3016d06b3b3d2b4795a02"},
	{"com.jcraft", "jzlib", "1.1.3", "89b1360f407381bf61fde411019d8cbd009ebb10cff715f3669017a031027560"},
}

func (a teavmArtifact) fileName() string { return a.Artifact + "-" + a.Version + ".jar" }

func (a teavmArtifact) mavenURL() string {
	return "https://repo1.maven.org/maven2/" + strings.ReplaceAll(a.Group, ".", "/") + "/" +
		a.Artifact + "/" + a.Version + "/" + a.fileName()
}

// teavmJars は TeaVM の jar 一式の道を名前の順で返す。FLIX_GE_TEAVM_DIR があればそこの *.jar を全部、
// 無ければ Maven Central から利用者のキャッシュへ取って SHA-256 を照合した物。
func teavmJars(log io.Writer) ([]string, error) {
	if dir := os.Getenv("FLIX_GE_TEAVM_DIR"); dir != "" {
		jars, _ := filepath.Glob(filepath.Join(dir, "*.jar"))
		if len(jars) == 0 {
			return nil, fmt.Errorf("FLIX_GE_TEAVM_DIR（%s）に jar が無い。\n  次: 中身を確かめるか、FLIX_GE_TEAVM_DIR を外して Maven から取らせる", dir)
		}
		sort.Strings(jars)
		return jars, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return nil, fmt.Errorf("キャッシュの置き場が分からない: %v\n  次: FLIX_GE_TEAVM_DIR に TeaVM の jar のフォルダを渡す", err)
	}
	dir := filepath.Join(base, "flix_game_engine", "teavm", teavmVersion)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("%s を作れない: %v", dir, err)
	}
	var jars []string
	for _, a := range teavmArtifacts {
		p := filepath.Join(dir, a.fileName())
		if sum, err := fileSHA256(p); err == nil && sum == a.SHA256 {
			jars = append(jars, p)
			continue
		}
		fmt.Fprintf(log, "[export-web] 取る: %s\n", a.mavenURL())
		if err := downloadVerified(a.mavenURL(), p, a.SHA256); err != nil {
			return nil, fmt.Errorf("%s を取れない: %v\n  次: ネットワークを確かめるか、FLIX_GE_TEAVM_DIR に jar のフォルダを渡す", a.fileName(), err)
		}
		jars = append(jars, p)
	}
	sort.Strings(jars)
	return jars, nil
}

// downloadVerified は url を一時のファイルへ取り、SHA-256 が合った時だけ dst へ置く。
// WhyNot: dst へ直に書かないのは、途中で切れた jar や SHA の合わない jar がキャッシュに残ると、
// キャッシュのフォルダを FLIX_GE_TEAVM_DIR に渡した時に照合を通らない jar を掴むため。
func downloadVerified(url, dst, want string) error {
	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".part-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), resp.Body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return fmt.Errorf("SHA-256 が合わない（期待 %s・実際 %s）", want, got)
	}
	return os.Rename(tmp.Name(), dst)
}

func fileSHA256(path string) (string, error) {
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

// findTeavmJar は jars から artifact の jar を引く（名前に版のある Maven の形と、版の無い手置きの形の両方）。
func findTeavmJar(jars []string, artifact string) string {
	for _, j := range jars {
		b := filepath.Base(j)
		if b == artifact+".jar" || b == artifact+"-"+teavmVersion+".jar" {
			return j
		}
	}
	return ""
}

// readZipEntry は jar（zip）の中の 1 本を読む。
func readZipEntry(jar, name string) ([]byte, error) {
	z, err := zip.OpenReader(jar)
	if err != nil {
		return nil, err
	}
	defer z.Close()
	for _, f := range z.File {
		if f.Name != name {
			continue
		}
		r, err := f.Open()
		if err != nil {
			return nil, err
		}
		defer r.Close()
		return io.ReadAll(r)
	}
	return nil, fmt.Errorf("%s の中に %s が無い", jar, name)
}
