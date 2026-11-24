package javacmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bundledEngine は配った engine（go/ が無く mk/jdk.mk がある）と、置き場（FGE_HOME）を作る。
func bundledEngine(t *testing.T) string {
	t.Setenv("FGE_HOME", t.TempDir())
	engine := filepath.Join(t.TempDir(), "engines", "0.108.0")
	write(t, filepath.Join(engine, "Makefile"), "VERSION := 0.108.0\n")
	write(t, filepath.Join(engine, "mk", "jdk.mk"), "FGE_JDK_VENDOR  := zulu\nFGE_JDK_VERSION := 25.0.3\n")
	return engine
}

func bundledJava() string {
	return filepath.Join(os.Getenv("FGE_HOME"), "jdk", "zulu-25.0.3", "bin", exe())
}

// 配った engine では、PATH の java が動いても置き場の JDK を使う。
func TestResolveUsesHomeJDKForBundledEngine(t *testing.T) {
	engine := bundledEngine(t)
	write(t, bundledJava(), "")
	t.Setenv("JAVA", "")
	withJavaWorks(t, func(string) bool { return true })
	if got := mustResolve(t, engine); got != bundledJava() {
		t.Errorf("got %q", got)
	}
}

// 配った engine で置き場の JDK が無ければ、PATH の java へ移らず fge engines install を案内する誤り。
func TestResolveFailsForBundledEngineWithoutJDK(t *testing.T) {
	engine := bundledEngine(t)
	t.Setenv("JAVA", "")
	withJavaWorks(t, func(c string) bool {
		_, err := os.Stat(c)
		return c == "java" || err == nil
	})
	_, err := Resolve(engine)
	if err == nil || !strings.Contains(err.Error(), "fge engines install 0.108.0") {
		t.Errorf("err = %v", err)
	}
}

// 配った engine でも、JAVA の名指しが勝つ。
func TestResolvePrefersJavaEnvForBundledEngine(t *testing.T) {
	engine := bundledEngine(t)
	write(t, bundledJava(), "")
	t.Setenv("JAVA", "/opt/jdk/bin/java")
	withJavaWorks(t, func(string) bool { return true })
	if got := mustResolve(t, engine); got != "/opt/jdk/bin/java" {
		t.Errorf("got %q", got)
	}
}

// 壊れた mk/jdk.mk は、PATH の java へ移らず誤り。
func TestResolveFailsForBrokenJDKSpec(t *testing.T) {
	engine := bundledEngine(t)
	write(t, filepath.Join(engine, "mk", "jdk.mk"), "FGE_JDK_VENDOR := zulu\n")
	t.Setenv("JAVA", "")
	withJavaWorks(t, func(string) bool { return true })
	if got, err := Resolve(engine); err == nil {
		t.Errorf("誤りになりません: %q", got)
	}
}

// mk/jdk.mk の無い engine は、go/ が無くても今までの順（PATH の java）。
func TestResolveKeepsPathJavaForBundleWithoutJDKSpec(t *testing.T) {
	t.Setenv("JAVA", "")
	engine := t.TempDir()
	write(t, filepath.Join(engine, "Makefile"), "VERSION := 0.103.0\n")
	withJavaWorks(t, func(string) bool { return true })
	if got := mustResolve(t, engine); got != "java" {
		t.Errorf("got %q", got)
	}
}

// 配った engine の BundleBin は置き場の JDK の bin。
func TestBundleBinIsHomeJDKBin(t *testing.T) {
	engine := bundledEngine(t)
	write(t, bundledJava(), "")
	withBrokenPathJava(t)
	if got, ok := BundleBin(engine); !ok || got != filepath.Dir(bundledJava()) {
		t.Errorf("got %q ok=%v", got, ok)
	}
}

// clone した engine（go/ がある）では BundleBin は無い。
func TestBundleBinIsAbsentForClonedEngine(t *testing.T) {
	engine := bundledEngine(t)
	write(t, filepath.Join(engine, "go", "go.mod"), "module x\n")
	if _, ok := BundleBin(engine); ok {
		t.Error("clone した engine で ok です")
	}
}
