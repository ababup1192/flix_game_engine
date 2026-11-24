# install.ps1 — 全体の fge を $env:FGE_HOME（既定 %USERPROFILE%\.flix_ge）\bin\fge.exe に入れる（Windows・Release に添える）。
#
#   irm https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.ps1 | iex
#
# $FgeVersion の行は make release-publish（release-fge-assets）が添える時に埋める。空なら latest の Release から取る。
# FGE_DOWNLOAD_URL で取り先（fge-windows-amd64.exe と fge-SHA256SUMS.txt を置いた所）を替えられる。
#
# WhyNot: ユーザーの PATH を書き換えない — install.sh と同じく、足す 1 行を出すだけにする（利用者の環境を勝手に触らない）。
# WhyNot: Git for Windows が無い時に先へ進まない — ゲームを作る・版を上げるのに git が要り、hooks と engine の sh は
#   Git Bash の上で動かす（plans/windows.md 0 節）。入れずに進むと最初の fge new で止まる。
# WhyNot: exit で終えない — irm | iex は今の PowerShell の中で流れるので、exit は利用者の端末ごと閉じる。throw で止める。
# WhyNot: 出す文と文字列を日本語で書かない — Windows PowerShell 5.1 は BOM の無い UTF-8 を ANSI の符号で読み、
#   CP1252 では UTF-8 の続きのバイトが “ ” に化けて文字列が途中で閉じる。BOM を付けると irm | iex の 1 行目が壊れる。
#   日本語はコメント（化けても構文は崩れない）にだけ書く。
$ErrorActionPreference = 'Stop'

$FgeVersion = ''

function Stop-Install([string]$Message) {
    throw "install.ps1: $Message"
}

function Find-GitBash {
    $candidates = @()
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $candidates += $env:CLAUDE_CODE_GIT_BASH_PATH }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $root) { continue }
        $candidates += (Join-Path $root 'Git\bin\bash.exe')
        $candidates += (Join-Path $root 'Programs\Git\bin\bash.exe')
    }
    # WhyNot: PATH の bash.exe を探さない — System32\bash.exe は WSL を起こす物で、Git Bash ではない。
    # git.exe は <Git>\cmd\git.exe なので、2 つ上が Git for Windows の根。
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $candidates += (Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe')
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if ($arch -ne 'AMD64') {
    Stop-Install "fge is not built for this CPU ($arch). Windows builds are amd64 only."
}

$bash = Find-GitBash
if (-not $bash) {
    Write-Host 'Git for Windows (Git Bash) was not found. Install it first, then run this again:'
    Write-Host '  winget install --id Git.Git -e'
    Write-Host '  (or download it from https://git-scm.com/download/win)'
    Write-Host 'If Git is installed somewhere else, set CLAUDE_CODE_GIT_BASH_PATH to its bin\bash.exe.'
    Stop-Install 'Git for Windows (Git Bash) is required.'
}

$releases = 'https://github.com/ababup1192/flix_game_engine/releases'
if ($env:FGE_DOWNLOAD_URL) {
    $base = $env:FGE_DOWNLOAD_URL.TrimEnd('/')
} elseif ($FgeVersion) {
    $base = "$releases/download/v$FgeVersion"
} else {
    $base = "$releases/latest/download"
}

$fgeHome = if ($env:FGE_HOME) { $env:FGE_HOME } else { Join-Path $env:USERPROFILE '.flix_ge' }
$bin = Join-Path $fgeHome 'bin'
$name = 'fge-windows-amd64.exe'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('fge-install-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

# WhyNot: Invoke-WebRequest の進み具合を出さない — Windows PowerShell 5.1 は進み具合の表示で取得が数倍遅くなる。
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    $shown = if ($FgeVersion) { $FgeVersion } else { '(latest)' }
    Write-Host "Downloading fge $shown (windows/amd64): $base/$name"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile (Join-Path $tmp $name)
    } catch {
        Stop-Install "could not download $base/$name ($($_.Exception.Message))"
    }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/fge-SHA256SUMS.txt" -OutFile (Join-Path $tmp 'sums')
    } catch {
        Stop-Install "could not download $base/fge-SHA256SUMS.txt ($($_.Exception.Message))"
    }

    $want = $null
    foreach ($line in Get-Content -LiteralPath (Join-Path $tmp 'sums')) {
        $f = $line.Trim() -split '\s+', 2
        if ($f.Count -eq 2 -and ($f[1] -eq $name -or $f[1] -eq "*$name")) { $want = $f[0].ToLower() }
    }
    if (-not $want) { Stop-Install "fge-SHA256SUMS.txt has no line for $name" }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tmp $name)).Hash.ToLower()
    if ($want -ne $got) { Stop-Install "SHA256 mismatch for ${name}: expected $want, got $got" }

    # WhyNot: 一時フォルダから直に置かない — 別のドライブだと写している途中の fge.exe が見える。隣に置いてから差し替える。
    # WhyNot: 今の fge.exe を消してから置かない — 走っている exe は消せないが名前は替えられる（plans/windows.md 11 節）。
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $dest = Join-Path $bin 'fge.exe'
    $staged = Join-Path $bin '.fge.new.exe'
    Copy-Item -LiteralPath (Join-Path $tmp $name) -Destination $staged -Force
    if (Test-Path -LiteralPath $dest) {
        $old = "$dest.old"
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $dest -Destination $old -Force
    }
    Move-Item -LiteralPath $staged -Destination $dest -Force
    Write-Host "Installed: $dest"
} finally {
    $ProgressPreference = $oldProgress
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = $false
foreach ($p in @(($env:Path -split ';') + ($userPath -split ';'))) {
    if ($p -and ($p.TrimEnd('\') -ieq $bin.TrimEnd('\'))) { $onPath = $true }
}
if (-not $onPath) {
    Write-Host ''
    Write-Host 'Add fge to your user PATH (paste this line into PowerShell, then open a new terminal):'
    Write-Host "  [Environment]::SetEnvironmentVariable('Path', '$bin;' + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')"
}
if ($fgeHome -ne (Join-Path $env:USERPROFILE '.flix_ge')) {
    Write-Host 'You changed the install folder, so also set FGE_HOME for your user (fge reads it):'
    Write-Host "  [Environment]::SetEnvironmentVariable('FGE_HOME', '$fgeHome', 'User')"
}
Write-Host "Git Bash: $bash"
Write-Host ''
Write-Host 'Next: fge dashboard'
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host 'If you do not have Claude Code yet, install it first: irm https://claude.ai/install.ps1 | iex'
}
