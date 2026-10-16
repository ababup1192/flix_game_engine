//go:build windows

package agenteval

// Windows では枠を数えない（--jobs だけで本数を抑える）。理由は slots.go の WhyNot。
const slotsSupported = false

func tryLock(path string) (func(), bool, error) { return func() {}, true, nil }
