package engineuses

import (
	"strings"
	"testing"
)

var engine = map[string]bool{"App": true, "Color": true, "Render": true, "Vec2": true}

func TestPublicTopNamesTakesOnlyOutermostPub(t *testing.T) {
	src := "pub mod Render.Layer { pub enum Inner }\nmod Hidden { }\npub type alias Size = Int32\n"
	got := PublicTopNames(src)
	if !got["Render"] || !got["Size"] || got["Inner"] || got["Hidden"] {
		t.Fatalf("got %v", got)
	}
}

func TestRewriteAddsUsePerMod(t *testing.T) {
	src := "mod View {\n\n    use World.Cell\n\n    def f(): Color = Color.darken(Render.x)\n}\n"
	got := Rewrite(src, "flix_game_engine", engine, map[string]bool{"Cell": true, "World": true})
	want := "mod View {\n\n    use flix_game_engine::{Color, Render}\n    use World.Cell\n\n    def f(): Color = Color.darken(Render.x)\n}\n"
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRewriteIsIdempotent(t *testing.T) {
	src := "mod View {\n    def f(): Color = Color.white\n}\n"
	once := Rewrite(src, "m", engine, map[string]bool{})
	if twice := Rewrite(once, "m", engine, map[string]bool{}); twice != once {
		t.Fatalf("not idempotent:\n%s\n---\n%s", once, twice)
	}
}

func TestRewriteSkipsCommentsStringsAndGameNames(t *testing.T) {
	src := "mod M {\n    // App は使わない\n    def f(): String = \"Render ${Vec2.zero}\"\n    def g(): Color = Color.red\n}\n"
	got := Rewrite(src, "m", engine, map[string]bool{"Color": true})
	if !strings.Contains(got, "use m::Vec2\n") || strings.Contains(got, "App") && !strings.Contains(got, "// App") {
		t.Fatalf("got:\n%s", got)
	}
}

func TestRewriteCountsMatchCases(t *testing.T) {
	src := "mod M {\n    def f(x: Int32): Int32 = match x { case Render.Px(v) => v }\n}\n"
	if got := Rewrite(src, "m", engine, map[string]bool{}); !strings.Contains(got, "use m::Render\n") {
		t.Fatalf("got:\n%s", got)
	}
}

func TestFixEngineUsesQualifiesBareEngineUse(t *testing.T) {
	src := "mod M {\n    use Color.darken\n    use World.Cell\n}\n"
	got := fixEngineUses(src, "m", engine, map[string]bool{"World": true})
	if !strings.Contains(got, "use m::Color.darken") || !strings.Contains(got, "    use World.Cell") {
		t.Fatalf("got:\n%s", got)
	}
}

func TestDeclaredNamesIgnoresMatchCases(t *testing.T) {
	got := declaredNames("enum Dir { case Up, Down }\ndef f(): Int32 = match x { case Color.Red => 1 }\nimport java.awt.Font\n")
	if !got["Up"] || !got["Down"] || !got["Font"] || got["Color"] {
		t.Fatalf("got %v", got)
	}
}
