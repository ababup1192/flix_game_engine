//go:build windows

package heavy

// Windows には exec で置き換える口が無いので委ねない。
const canDelegate = false

func execDelegate(bin string, args []string) error { return nil }
