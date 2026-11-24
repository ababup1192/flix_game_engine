package fgehome

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// Lock は path のファイルで排他を取り、外す関数を返す。他の fge が持っている間は、
// progress に待っている旨を 1 行出してから待つ。
func Lock(path string, progress io.Writer) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	busy, err := tryLockFile(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	if busy {
		if progress != nil {
			fmt.Fprintf(progress, "[fge] 別の fge が %s を書いています。終わるのを待ちます\n", filepath.Dir(path))
		}
		if err := lockFile(f); err != nil {
			f.Close()
			return nil, err
		}
	}
	return func() {
		unlockFile(f)
		f.Close()
	}, nil
}

// MakeReadOnly は dir の下の全部から書き込みの権限を外す。
// WhyNot: symlink を辿って chmod しない — 指す先が置き場の外なら、利用者のファイルの権限を変えてしまう。
func MakeReadOnly(dir string) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		return os.Chmod(path, info.Mode().Perm()&^0o222)
	})
}

// RemoveReadOnly は MakeReadOnly した dir を、書けるように戻してから消す。
// WhyNot: os.RemoveAll だけにしない — 一般ユーザーでは書けないフォルダの中を消せずに止まる。
func RemoveReadOnly(dir string) error {
	if _, err := os.Lstat(dir); os.IsNotExist(err) {
		return nil
	}
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil
		}
		if info, err := d.Info(); err == nil {
			_ = os.Chmod(path, info.Mode().Perm()|0o700)
		}
		return nil
	})
	return os.RemoveAll(dir)
}
