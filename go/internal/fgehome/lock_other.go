//go:build !(linux || darwin || freebsd || netbsd || openbsd || dragonfly)

package fgehome

import "os"

// WhyNot: Windows で排他を取らない — 配った engine の道は Windows を対象にしていない（make を要らなくする計画の後）。
func tryLockFile(*os.File) (bool, error) { return false, nil }
func lockFile(*os.File) error            { return nil }
func unlockFile(*os.File)                {}
