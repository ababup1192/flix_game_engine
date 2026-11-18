//go:build windows

package checkd

// lockHeld は Windows では見ない（checkd の常駐は Windows で使わない。docs/checkd.md の「対象外」）。
func lockHeld(string) bool { return false }
