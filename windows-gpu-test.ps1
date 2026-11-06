# windows-gpu-test.ps1 - guided NVIDIA GPU test for Windows.
# Run once from an Administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File C:\gpu-test.ps1
# It continues by itself after each restart and writes C:\gpu-logs\REPORT.txt.

$Dir     = 'C:\gpu-logs'
$Report  = "$Dir\REPORT.txt"
$State   = "$Dir\state.txt"
$Running = "$Dir\running.txt"
$Self    = $MyInvocation.MyCommand.Path
$Task    = 'GpuTest'

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Please open PowerShell with "Run as Administrator" and run this again.' -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force $Dir | Out-Null

function Note($text) { Add-Content -Path $Report -Value "$(Get-Date -Format 'HH:mm:ss')  $text" }

function Title($text) {
    Clear-Host
    Write-Host ''
    Write-Host "=== $text ===" -ForegroundColor Cyan
    Write-Host ''
}

function WaitEnter($text) { [void](Read-Host "`n$text, then press Enter") }

function AskYes($question) {
    while ($true) {
        $a = (Read-Host "$question (y/n)").Trim().ToLower()
        if ($a -eq 'y') { return $true }
        if ($a -eq 'n') { return $false }
    }
}

function GetStep {
    if (Test-Path $State) { return [int](Get-Content $State -TotalCount 1) }
    return 1
}

function SetStep($n) { Set-Content -Path $State -Value $n }

function Begin($name) { Set-Content -Path $Running -Value $name }

function Finish { Remove-Item $Running -ErrorAction SilentlyContinue }

function Driver {
    $v = & nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { return "$v".Trim() }
    return 'unknown'
}

function GpuStatus {
    $v = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if (-not $v) { return 'FAIL: NVIDIA GPU not found' }
    if ($v.ConfigManagerErrorCode -ne 0) { return "FAIL: Device Manager error code $($v.ConfigManagerErrorCode)" }
    & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return 'FAIL: nvidia-smi is not answering' }
    return 'OK'
}

function GpuErrors($since) {
    $e = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'nvlddmkm', 'Display', 'Microsoft-Windows-WHEA-Logger'
        StartTime    = $since
    } -ErrorAction SilentlyContinue
    return @($e).Count
}

function StartLog($name) {
    $path = "$Dir\monitor-$name-$(Get-Date -Format 'HHmmss').csv"
    $fields = 'timestamp,driver_version,pstate,clocks.gr,clocks.mem,power.draw,temperature.gpu,utilization.gpu,memory.used'
    Start-Process nvidia-smi -WindowStyle Hidden -ArgumentList "--query-gpu=$fields --format=csv,noheader,nounits -l 5 -f `"$path`""
    return $path
}

function StopLog($path) {
    Stop-Process -Name nvidia-smi -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Test-Path $path)) { return 'no GPU log recorded' }
    $rows = @(Get-Content $path | ForEach-Object { ,($_ -split ',') } | Where-Object { $_.Count -ge 9 })
    if ($rows.Count -eq 0) { return 'GPU log is empty' }
    $mx = {
        param($col)
        $vals = foreach ($r in $rows) {
            $n = 0.0
            if ([double]::TryParse($r[$col].Trim(), [ref]$n)) { $n }
        }
        ($vals | Measure-Object -Maximum).Maximum
    }
    return "max temp $(& $mx 6) C, max power $(& $mx 5) W, max GPU use $(& $mx 7) %, max memory clock $(& $mx 4) MHz, max VRAM $(& $mx 8) MiB"
}

# Shared by FurMark and the game: start logging, wait, record the result.
function LoadTest($name, $minutes) {
    $start = Get-Date
    $log = StartLog $name
    Begin $name
    WaitEnter "Run it for $minutes minutes"
    $mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
    $problem = AskYes 'Did you see a black screen, driver reset, freeze, crash or blue screen'
    $summary = StopLog $log
    $errs = GpuErrors $start
    Finish
    $word = 'PASS'
    if ($problem -or $errs -gt 0) { $word = 'FAIL' }
    elseif ($mins -lt $minutes) { $word = 'NOT COMPLETED' }
    Note "$name : $word, $mins min, you saw a problem: $problem, GPU errors logged: $errs, driver $(Driver), $summary"
    if ($mins -lt $minutes) { Note "$name : ran shorter than the planned $minutes minutes" }
}

# A crash or forced restart in the middle of a test leaves this file behind.
if (Test-Path $Running) {
    Note "INTERRUPTED: Windows restarted or the script stopped during '$(Get-Content $Running -TotalCount 1)'. Count this as a FAIL."
    Finish
}

while ($true) {
    switch (GetStep) {

        1 {
            Title 'Step 1 of 9: Setup and clock fix'
            Note "Test started. Driver $(Driver)."
            reg add 'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' /v RealTimeIsUniversal /t REG_DWORD /d 1 /f | Out-Null
            Set-TimeZone -Id 'India Standard Time'
            Set-Service w32time -StartupType Automatic
            Start-Service w32time -ErrorAction SilentlyContinue
            powercfg /h off
            $gsp = & nvidia-smi -q 2>$null | Select-String 'GSP'
            if ($gsp) { Note "GSP line: $(("$gsp").Trim())" } else { Note 'GSP line: none shown' }

            # Bring this script back automatically after every restart.
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoExit -ExecutionPolicy Bypass -File `"$Self`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
            Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

            Write-Host 'Done. The clock fix needs a restart, and this script will reopen after you log in.'
            WaitEnter 'Close your other programs'
            SetStep 2
            Restart-Computer -Force
            exit
        }

        2 {
            Title 'Step 2 of 9: Check the clock'
            w32tm /resync /force | Out-Null
            Write-Host "Windows now says: $(Get-Date -Format 'dddd dd MMM yyyy, hh:mm tt')"
            Write-Host ''
            $ok = AskYes 'Is that the correct time'
            Note "Clock correct after fix: $ok"
            SetStep 3
        }

        3 {
            Title 'Step 3 of 9: FurMark on the current driver'
            if ((Driver) -notlike '528*') {
                Note "Old-driver FurMark skipped: driver is already $(Driver)"
            } else {
                Start-Process 'https://geeks3d.com/furmark/'
                Write-Host 'Your browser opened the FurMark page.'
                Write-Host '1. Download and install FurMark.'
                Write-Host '2. Choose the RTX 4050, 1920x1080, and start the stress test.'
                Write-Host '3. Stop early if the temperature stays above 90 C.'
                WaitEnter 'When FurMark is running'
                LoadTest 'FurMark-old-driver' 15
                Write-Host ''
                WaitEnter 'Close FurMark'
            }
            SetStep 4
        }

        4 {
            Title 'Step 4 of 9: Update the NVIDIA driver'
            Start-Process 'https://www.nvidia.com/Download/index.aspx'
            Write-Host 'Your browser opened the NVIDIA driver page.'
            Write-Host '1. Search for: GeForce RTX 40 Series (Notebooks), Windows 11, Game Ready driver.'
            Write-Host '2. Download and install it. Do not restart from the installer.'
            WaitEnter 'When the install has finished'
            Note "Driver after update step: $(Driver)"
            Set-Content -Path "$Dir\restarts.txt" -Value 0
            SetStep 5
            Write-Host 'Restarting now. The script will reopen after you log in.'
            Start-Sleep -Seconds 5
            Restart-Computer -Force
            exit
        }

        5 {
            Title 'Step 5 of 9: Three restarts'
            $count = [int](Get-Content "$Dir\restarts.txt" -TotalCount 1)
            Write-Host 'Waiting 20 seconds for the GPU to settle...'
            Start-Sleep -Seconds 20
            $status = GpuStatus
            Note "Check after restart $count : $status, driver $(Driver)"
            if ($count -lt 3) {
                $count++
                Set-Content -Path "$Dir\restarts.txt" -Value $count
                Write-Host "GPU check: $status"
                Write-Host "Restart $count of 3 happens in 10 seconds. The script will reopen after you log in."
                Start-Sleep -Seconds 10
                Restart-Computer -Force
                exit
            }
            SetStep 6
        }

        6 {
            Title 'Step 6 of 9: Open and close Steam three times'
            if (Test-Path 'HKCU:\Software\Valve\Steam') {
                Write-Host 'The script does this for you. It takes about 5 minutes, so please wait.'
                $start = Get-Date
                $log = StartLog 'Steam'
                Begin 'Steam open and close'
                foreach ($i in 1..3) {
                    Write-Host "Round $i of 3..."
                    Start-Process explorer.exe 'steam://open/main'
                    Start-Sleep -Seconds 60
                    $status = GpuStatus
                    Note "Steam round $i : $status"
                    Start-Process explorer.exe 'steam://exit'
                    Start-Sleep -Seconds 30
                }
                $summary = StopLog $log
                Finish
                Note "Steam : GPU errors logged: $(GpuErrors $start), $summary"
            } else {
                Note 'Steam test skipped: Steam is not installed'
            }
            SetStep 7
        }

        7 {
            Title 'Step 7 of 9: FurMark on the new driver'
            Write-Host 'Start FurMark again: RTX 4050, 1920x1080, stress test.'
            Write-Host 'Stop early if the temperature stays above 90 C.'
            WaitEnter 'When FurMark is running'
            LoadTest 'FurMark-new-driver' 15
            Write-Host ''
            WaitEnter 'Close FurMark'
            SetStep 8
        }

        8 {
            Title 'Step 8 of 9: Play a real game'
            Write-Host 'Install a game if needed. Hogwarts Legacy or Diablo IV are best.'
            Write-Host 'Include a loading screen and a save reload.'
            Write-Host 'Check Task Manager > Performance: the NVIDIA GPU should show load.'
            $game = Read-Host "`nType the game's name, or press Enter to skip the game test"
            if ($game) {
                WaitEnter 'When the game is running'
                LoadTest "Game-$($game -replace '[^A-Za-z0-9]', '')" 30
            } else {
                Note 'Game test skipped'
            }
            SetStep 9
        }

        9 {
            Title 'Step 9 of 9: Saving the logs'
            $since = (Get-Date).AddDays(-2)
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'nvlddmkm', 'Display', 'Microsoft-Windows-WHEA-Logger', 'Microsoft-Windows-Kernel-Power'; StartTime = $since } -ErrorAction SilentlyContinue |
                Format-List TimeCreated, ProviderName, Id, LevelDisplayName, Message | Out-File "$Dir\events.txt"
            Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $since } -ErrorAction SilentlyContinue |
                Format-List TimeCreated, ProviderName, Id, Message | Out-File "$Dir\app-errors.txt"
            Copy-Item 'C:\Windows\System32\winevt\Logs\System.evtx' $Dir -ErrorAction SilentlyContinue
            Copy-Item 'C:\Windows\Minidump\*' $Dir -ErrorAction SilentlyContinue
            & nvidia-smi -q 2>$null | Out-File "$Dir\nvidia-smi.txt"
            Start-Process dxdiag -ArgumentList "/t $Dir\dxdiag.txt" -Wait
            Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
            Note 'Test finished.'
            Remove-Item $State -ErrorAction SilentlyContinue

            Write-Host 'All done. Your results:' -ForegroundColor Green
            Write-Host ''
            Get-Content $Report
            Write-Host ''
            Write-Host 'Now shut down, boot Linux, and tell Claude: check windows logs'
            exit
        }
    }
}
