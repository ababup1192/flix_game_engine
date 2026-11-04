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

const teavmVersion = "0.14.1"

// teavmArtifact は TeaVM で wasm を作るのに要る jar 1 本（Maven の座標と、取った後に照合する SHA-256）。
type teavmArtifact struct {
	Group, Artifact, Version, SHA256 string
}

// teavmArtifacts は TeaVM 0.14.1 の CLI が要る jar の一式。
// WhyNot: Maven の依存の解決（pom を読んで推移先をたどる）を書かないのは、版を固定して照合するためには一覧を
// ソースに持つ方が確かで、解決器を持つと TeaVM の pom が変わったときに知らせずに別の jar を取りうるため。
var teavmArtifacts = []teavmArtifact{
	{"org.teavm", "teavm-classlib", teavmVersion, "e64a8688d379731ab3af2faea18baf2a42ffa83b2ec8a8dc9d99c9bdb1d03b37"},
	{"org.teavm", "teavm-cli", teavmVersion, "50d43b18a797d659a441c8de4f10cd749b952093ded4118a7d0a4bc94b1812b9"},
	{"org.teavm", "teavm-core", teavmVersion, "de8037b4cb01003945e2ed8e651641c330835e98368a789019f82b322f26151c"},
	{"org.teavm", "teavm-interop", teavmVersion, "ba95d80349e3ba842f6f9cfc834184b0253dfc37f5cae110b7e48d73d2fa8892"},
	{"org.teavm", "teavm-jso", teavmVersion, "421b848c79d161c34e9f178d3d37b35e8efaadada487056c3fd3d4d3de1c172c"},
	{"org.teavm", "teavm-jso-apis", teavmVersion, "171abaff01d9c029218df911470184ed8e30e6b511be6bb03381a924ec4a8c3c"},
	{"org.teavm", "teavm-jso-impl", teavmVersion, "3cf0fabf3c1fbc1362c24d69c7016c31d5a24793e62ea1ffc8eaa3e8fd0d97b3"},
	{"org.teavm", "teavm-metaprogramming-api", teavmVersion, "f7188cb258c6afb69b00d8d3d46c9eec73836882cdd347f17a409d0eaa548e74"},
	{"org.teavm", "teavm-metaprogramming-impl", teavmVersion, "c6c9856887ee6b012dba1c107e26ef5b417ea0d4af8179b409238cb909cc1f96"},
	{"org.teavm", "teavm-platform", teavmVersion, "f03d22d0e144980e3d9e98b03ca171aeede260c4de4f1991cae27fa81a846c9e"},
	{"org.teavm", "teavm-tooling", teavmVersion, "f36e1ea7e080b5c021c7126688315bb973e7421094ffbf58fb2ce101bb81d577"},
	{"org.teavm", "teavm-relocated-libs-asm", teavmVersion, "400496e463dddd878fed2b9b25a66deca2126f71bb68e41f82244b4315006018"},
	{"org.teavm", "teavm-relocated-libs-asm-analysis", teavmVersion, "6bb5ef62ab00d557061d9b04dc4571f711fbe11d339783e55029b37b75d5159c"},
	{"org.teavm", "teavm-relocated-libs-asm-commons", teavmVersion, "d49685681db5039075f2fde01568f2bb6df14a99ef88d39b29df8e701e12e140"},
	{"org.teavm", "teavm-relocated-libs-asm-tree", teavmVersion, "6b475fd62b8ddedfa0808c0c412c311f000a80a13123b6ba07f5da531164fd5b"},
	{"org.teavm", "teavm-relocated-libs-asm-util", teavmVersion, "a41247ca7f023959712be0e713d3f2f5687b4dfeda6b112b2d976494d52cdc57"},
	{"org.teavm", "teavm-relocated-libs-commons-cli", teavmVersion, "0df3cce00582ebeed6f37efb475fe30f76d378642d1268dc7ebbb8049171419d"},
	{"org.teavm", "teavm-relocated-libs-commons-io", teavmVersion, "5e1a666948a40dada1d3fbce41503bad6ce86035662bf131c8df227b30859a79"},
	{"org.teavm", "teavm-relocated-libs-hppc", teavmVersion, "7b82fedf747e0bf5d7a50acece86a8a684901e469165a3c5621c653128df4cd6"},
	{"org.teavm", "teavm-relocated-libs-rhino", teavmVersion, "49cedc9bfcdd44d30b8bc8d1d46d78fb7f8f2044b8c85c9c3f1ece33e94ee7e9"},
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
