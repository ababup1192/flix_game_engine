package compare

import "testing"

func TestEnvRefCatchesShellDefaultForm(t *testing.T) {
	m := envRefRe.FindStringSubmatch(`java_cmd="${JAVA:-java}"`)
	if m == nil || m[1] != "JAVA" {
		t.Fatalf("match=%v", m)
	}
}

func TestEnvRefCatchesFlixGetenv(t *testing.T) {
	m := envRefRe.FindStringSubmatch(`Flow.Cli.envOr("FLOW_OUT", "x")`)
	if m == nil || m[3] != "FLOW_OUT" {
		t.Fatalf("match=%v", m)
	}
}
