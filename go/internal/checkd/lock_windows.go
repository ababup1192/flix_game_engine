//go:build windows

package checkd

// lockHeld は Windows では「空いている」と答える。stop の後に次の常駐を起こすまで待つ所だけが読むので、
// socket が消えた所で待つのをやめる。
// WhyNot: LockFileEx で確かめない — Java の FileChannel.tryLock が Windows で取る範囲と合わせた確かめが無く、
// 外れると空かない lock を 10 秒待ち続ける。
func lockHeld(string) bool { return false }
