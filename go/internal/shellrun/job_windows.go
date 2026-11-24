//go:build windows

package shellrun

import (
	"os"
	"syscall"
	"unsafe"
)

var (
	kernel32                     = syscall.NewLazyDLL("kernel32.dll")
	procCreateJobObjectW         = kernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = kernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = kernel32.NewProc("AssignProcessToJobObject")
)

const (
	jobObjectExtendedLimitInformation = 9
	jobObjectLimitKillOnJobClose      = 0x2000
	processSetQuota                   = 0x0100
	processTerminate                  = 0x0001
)

type ioCounters struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount uint64
	ReadTransferCount, WriteTransferCount, OtherTransferCount    uint64
}

type jobBasicLimit struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type jobExtendedLimit struct {
	BasicLimitInformation jobBasicLimit
	IoInfo                ioCounters
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

// attachKillOnClose は p を KILL_ON_JOB_CLOSE の Job Object に入れ、閉じる関数を返す。fge が落ちても OS が Job の handle を閉じるので、
// 木は残らない。入れられなかった時は何もしない（走らせるのは止めない）。
//
// WhyNot: 子を止めた状態で起こしてから入れる形（CREATE_SUSPENDED）にしない — Go の exec は主スレッドの handle を渡さず、
// 起こし直すのに文書の無い NtResumeProcess が要る。bash が java を起こすまでの数ミリ秒の間に入れれば、木は Job に入る。
func attachKillOnClose(p *os.Process) func() {
	job, _, _ := procCreateJobObjectW.Call(0, 0)
	if job == 0 {
		return func() {}
	}
	var info jobExtendedLimit
	info.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose
	if r, _, _ := procSetInformationJobObject.Call(job, jobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info)); r == 0 {
		syscall.CloseHandle(syscall.Handle(job))
		return func() {}
	}
	h, err := syscall.OpenProcess(processSetQuota|processTerminate, false, uint32(p.Pid))
	if err != nil {
		syscall.CloseHandle(syscall.Handle(job))
		return func() {}
	}
	defer syscall.CloseHandle(h)
	if r, _, _ := procAssignProcessToJobObject.Call(job, uintptr(h)); r == 0 {
		syscall.CloseHandle(syscall.Handle(job))
		return func() {}
	}
	return func() { syscall.CloseHandle(syscall.Handle(job)) }
}
