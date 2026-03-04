param(
[string]$Channel,
    [int]$DurationMinutes,
    [string]$Config,
    [string]$StartAt,
    [switch]$DryRun,
    [switch]$Schedule,
    [switch]$NoRemux
)

# Get the current script's directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Build the path to the Settings subfolder
$SettingsPath = Join-Path $ScriptDir "Settings\IPTVConfigs.ps1"

# Dot-source the config file
. $SettingsPath

# -------------------------------------
# LOGGING INFRASTRUCTURE
# -------------------------------------
$Script:LogDir = Join-Path $ScriptDir "logs"
New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
$Script:LogFile = ""

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    if ($Script:LogFile) {
        Add-Content -Path $Script:LogFile -Value $line
    }
}

# -------------------------------------
# 📺 IPTV TOOLKIT
# -------------------------------------
# FEATURES
# - Record live IPTV
# - Schedule recordings either in Terminal or in Windows Task Scheduler
# - Multiple configs
#
# - Record catchup IPTV based on time of broadcast
# - Download the same time period from multiple channels

function Remux-TSFileToMKV {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TSFilePath
    )

    $mkvPath = [System.IO.Path]::ChangeExtension($TSFilePath, "mkv")
    $ffmpegArgs = "-err_detect ignore_err -fflags +genpts -i `"$TSFilePath`" -map 0 -c copy -avoid_negative_ts make_zero `"$mkvPath`""

    Write-Log INFO "Remuxing to mkv: $mkvPath ..."
    $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -eq 0 -and (Test-Path $mkvPath)) {
        Remove-Item $TSFilePath
        Write-Log SUCCESS "Remux successful. Deleted original .ts file."
        return $mkvPath
    } else {
        Write-Log WARNING "Remux failed. .ts file kept."
        return $null
    }
}

function Get-MediaDuration {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) { return 0 }

    # Try format-level duration first (works for most containers)
    try {
        $output = & ffprobe -v error -show_entries format=duration -of csv=p=0 "$FilePath" 2>$null
        $duration = [double]$output
        if ($duration -gt 0) { return $duration }
    } catch { }

    # Fallback: count video packets ÷ frame rate — works for live IPTV .ts files
    # where duration is not stored in the container headers (Duration: N/A from source)
    try {
        $pktInfo = & ffprobe -v error -select_streams "v:0" -count_packets `
            -show_entries "stream=nb_read_packets,r_frame_rate" `
            -of csv=p=0 "$FilePath" 2>$null
        if ($pktInfo) {
            $parts = $pktInfo -split ','
            $packets = [double]$parts[0]
            $fpsParts = $parts[1] -split '/'
            $fps = [double]$fpsParts[0] / [double]$fpsParts[1]
            if ($packets -gt 0 -and $fps -gt 0) {
                return [math]::Round($packets / $fps, 3)
            }
        }
    } catch { }

    return 0
}

function Merge-TsSegments {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$SegmentPaths,

        [Parameter(Mandatory = $true)]
        [string]$FinalOutputPath
    )

    $dir = Split-Path $FinalOutputPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FinalOutputPath)
    $concatList = Join-Path $dir "${baseName}_concat.txt"

    # Rename the first segment if it would collide with the final output path
    $resolvedSegments = @()
    for ($i = 0; $i -lt $SegmentPaths.Count; $i++) {
        $seg = $SegmentPaths[$i]
        if ($seg -eq $FinalOutputPath) {
            $renamed = Join-Path $dir "${baseName}_seg0.ts"
            Rename-Item -Path $seg -NewName (Split-Path $renamed -Leaf) -Force
            $resolvedSegments += $renamed
        } else {
            $resolvedSegments += $seg
        }
    }

    # Write concat list
    $lines = $resolvedSegments | ForEach-Object { "file '$_'" }
    $lines | Set-Content -Path $concatList -Encoding UTF8

    Write-Log INFO "Concatenating $($resolvedSegments.Count) segments..."
    $process = Start-Process -FilePath "ffmpeg" -ArgumentList "-f concat -safe 0 -i `"$concatList`" -c copy `"$FinalOutputPath`"" -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Log WARNING "Concatenation failed (ffmpeg exit code $($process.ExitCode))."
    }

    # Clean up segment files and concat list
    foreach ($seg in $resolvedSegments) {
        if ((Test-Path $seg) -and $seg -ne $FinalOutputPath) {
            Remove-Item $seg -Force
        }
    }
    if (Test-Path $concatList) { Remove-Item $concatList -Force }
}

function Invoke-FfmpegWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InitialCommand,

        [Parameter(Mandatory = $true)]
        [string]$InitialOutputPath,

        [Parameter(Mandatory = $true)]
        [double]$TotalDurationSeconds,

        [Parameter(Mandatory = $true)]
        [scriptblock]$BuildRetryCommand,

        [int]$MaxRetries = 5,

        [int]$MinRemainingSeconds = 10
    )

    # Run the initial command
    Invoke-Expression $InitialCommand

    $segments = @($InitialOutputPath)
    $elapsed = Get-MediaDuration -FilePath $InitialOutputPath

    # Check if we already have enough (2s tolerance)
    if ($elapsed -ge ($TotalDurationSeconds - 2)) {
        return $InitialOutputPath
    }

    $dir = Split-Path $InitialOutputPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InitialOutputPath)

    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        $remaining = $TotalDurationSeconds - $elapsed
        if ($remaining -lt $MinRemainingSeconds) {
            Write-Log INFO "Only $([math]::Round($remaining, 1))s remaining — skipping retry."
            break
        }

        Write-Log INFO "Retry $retry/$MaxRetries — $([math]::Round($remaining, 0))s remaining..."

        $segPath = Join-Path $dir "${baseName}_seg${retry}.ts"
        $retryCmd = & $BuildRetryCommand $remaining $segPath $elapsed

        Invoke-Expression $retryCmd

        $segDuration = Get-MediaDuration -FilePath $segPath
        if ($segDuration -eq 0) {
            Write-Log WARNING "Retry $retry produced empty/corrupt file — stopping retries."
            if (Test-Path $segPath) { Remove-Item $segPath -Force }
            break
        }

        $segments += $segPath
        $elapsed += $segDuration

        if ($elapsed -ge ($TotalDurationSeconds - 2)) {
            Write-Log INFO "Target duration reached after retry $retry."
            break
        }
    }

    # Concatenate if multiple segments
    if ($segments.Count -gt 1) {
        Merge-TsSegments -SegmentPaths $segments -FinalOutputPath $InitialOutputPath
    }

    return $InitialOutputPath
}

# -------------------------------------
# 🎥 RECORD LIVE STREAM
# -------------------------------------
# Record sky_sport_de_mix live for 2 minutes
# Record-LiveIPTV -Config crystal -Channel sky_sport_de_mix -DurationMinutes 2
#
# Wait until 4 May 2025 at 15:00, then record 5 minutes:
# Record-LiveIPTV -Config crystal -Channel canalplus_sport -DurationMinutes 5 -StartAt "2025-05-04:15-00"
#
# Schedule a recording for 4 May 2025 at 15:00, then record 5 minutes:
# Record-LiveIPTV -Config crystal -Channel canalplus_sport -DurationMinutes 5 -StartAt "2025-05-04:15-00" -Schedule

function Record-LiveIPTV {
    param (
        [switch]$NoRemux,

        [string]$Channel,

        [Parameter(Mandatory = $true)]
        [int]$DurationMinutes,

        [Parameter(Mandatory = $true)]
        [string]$Config,

        [string]$StartAt,

        [switch]$DryRun,

        [switch]$Schedule
    )

    if (-not $Global:IPTVConfigs.ContainsKey($Config)) {
        Write-Log ERROR "Invalid config '$Config'. Define it in `\$IPTVConfigs` in your profile."
        return
    }

    $conf = $Global:IPTVConfigs[$Config]

    if (-not $conf.ChannelMap.ContainsKey($Channel)) {
        Write-Log ERROR "Invalid channel name: $Channel. Valid options: $($conf.ChannelMap.Keys -join ', ')"
        return
    }

    $Script:LogFile = Join-Path $Script:LogDir "record_live_${Channel}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Log INFO "Recording session started: $Channel"

    $startTime = $null
    if ($StartAt) {
        try {
            $startTime = [datetime]::ParseExact(
                $StartAt, "yyyy-MM-dd:HH-mm",
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeLocal
            )
        } catch {
            Write-Log ERROR "Invalid -StartAt format. Use yyyy-MM-dd:HH-mm."
            return
        }
    }

    # --- Schedule logic ---
    if ($Schedule) {
        if (-not $StartAt) {
            Write-Log ERROR "You must provide -StartAt with -Schedule. Use format yyyy-MM-dd:HH-mm."
            return
        }

        $taskName = "Record-LiveIPTV_${Channel}_$($startTime.ToString('yyyyMMdd_HHmm'))"

        $scriptPath = $PSCommandPath # Needed to set task up properly

        # Build argument string (quotes around script path, NOT around executable)
        $argString = "-NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Channel $Channel -DurationMinutes $DurationMinutes -Config $Config"
        if ($NoRemux) { $argString += ' -NoRemux' }
        if ($DryRun) { $argString += " -DryRun" }

        # Compose the full /TR string (executable in quotes, arguments after)
        $trString = "`"$pwshPath`" $argString"

        # Debug output
        Write-Log INFO "[DEBUG] Task will run (copy this into Task Scheduler's Action fields to confirm):"
        Write-Log INFO "Program/script: $pwshPath"
        Write-Log INFO "Add arguments: $argString"

        $dateStr = $startTime.ToString("dd/MM/yyyy")
        $timeStr = $startTime.ToString("HH:mm")

        $schtasksCmd = @(
            '/Create',
            '/SC', 'ONCE',
            '/TN', $taskName,
            '/TR', $trString,
            '/ST', $timeStr,
            '/SD', $dateStr,
            '/F'
        )

        Write-Log INFO "Scheduling recording for $Channel at $dateStr $timeStr via Windows Task Scheduler..."
        $out = schtasks.exe @schtasksCmd
        Write-Log INFO $out

        Write-Log INFO "Scheduled task '$taskName' created."
        return
    }

    # --- Start time logic (sleep until start, if StartAt specified) ---
    $DurationSeconds = $DurationMinutes * 60

    if ($StartAt) {
        $now = Get-Date
        Write-Log INFO "Current Time: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Log INFO "Scheduled Start Time: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"

        $delay = ($startTime - $now).TotalSeconds
        if ($delay -le 0) {
            Write-Log ERROR "Start time is in the past. Recording cannot proceed."
            return
        }

        Write-Log INFO "Sleeping until recording of [$Channel] starts at [$($startTime.ToString('yyyy-MM-dd HH:mm'))] for [$DurationMinutes] minute(s)..."
        while ($true) {
            $remaining = [int](($startTime - (Get-Date)).TotalSeconds)
            if ($remaining -le 0) { break }

            $timeStr = [timespan]::FromSeconds($remaining).ToString("mm\:ss")
            Write-Host -NoNewline "`rStarting in $timeStr...  "

            Start-Sleep -Seconds ([Math]::Min(1, $remaining))
        }
        Write-Host ""
        Write-Log INFO "Starting now!"
    }

    # --- Build stream URL ---
    $code = $conf.ChannelMap[$Channel]
    $suffix = if ($conf.AddTsSuffix) { ".ts" } else { "" }
    $url = "$($conf.BaseUrl)/$($conf.Username)/$($conf.Password)/$code$suffix"

    Write-Log INFO "URL being used: $url"

    $outputPath = Join-Path (Join-Path $HOME "Videos") "${Channel}_$(Get-Date -Format 'yyyyMMdd_HHmm').ts"
    $quotedUrl = '"' + $url + '"'
    $quotedOut = '"' + $outputPath + '"'

    $cmd = "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 200M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedUrl -map 0:v? -map 0:a? -t $DurationSeconds -c copy $quotedOut"

    if ($DryRun) {
        Write-Log "DRY-RUN" "Would run command: $cmd"
    } else {
        Write-Log INFO "Recording $Channel now for $DurationMinutes minute(s)..."

        $buildRetryCmd = {
            param($remainingSeconds, $segmentPath, $elapsedSeconds)
            $quotedSeg = '"' + $segmentPath + '"'
            "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 200M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedUrl -map 0:v? -map 0:a? -t $([math]::Ceiling($remainingSeconds)) -c copy $quotedSeg"
        }

        $finalPath = Invoke-FfmpegWithRetry `
            -InitialCommand $cmd `
            -InitialOutputPath $outputPath `
            -TotalDurationSeconds $DurationSeconds `
            -BuildRetryCommand $buildRetryCmd

        if (-not $NoRemux) { Remux-TSFileToMKV -TSFilePath $finalPath } else { Write-Log INFO "NoRemux: skipping remux." }
    }
}

# -------------------------------------
# 🕒 RECORD CATCH-UP STREAM
# -------------------------------------
# Single channel: Record canalplus_sport from 4 May 2025 at 15:00 local time for 3 minutes
# Record-CatchupIPTV -Config trex -Channel canalplus_sport -StartAt "2025-05-04:15-00" -DurationMinutes 3
#
# Multiple channels: Record the same time window sequentially
# Record-CatchupIPTV -Config trex -Channel canalplus_sport,sky_sport_de_mix -StartAt "2025-05-04:15-00" -DurationMinutes 3
#
# Dry run: just print the ffmpeg command without executing
# Record-CatchupIPTV -Config trex -Channel sky_sport_it_motogp -StartAt "2025-05-04:15-00" -DurationMinutes 3 -DryRun

function Record-CatchupIPTV {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Channel,

        [switch]$NoRemux,

        [string]$StartAt,  # Format: yyyy-MM-dd:HH-mm

        [Parameter(Mandatory = $true)]
        [int]$DurationMinutes,

        [Parameter(Mandatory = $true)]
        [string]$Config,

        [int]$CustomDuration = 300,

        [switch]$DryRun
    )

    if (-not $Global:IPTVConfigs.ContainsKey($Config)) {
        Write-Log ERROR "Invalid config '$Config'. Define it in `\$IPTVConfigs` in your profile."
        return
    }

    $conf = $Global:IPTVConfigs[$Config]

    foreach ($chan in $Channel) {
        if (-not $conf.ChannelMap.ContainsKey($chan)) {
            Write-Log ERROR "Invalid channel: $chan"
            return
        }
    }

    try {
        $startTime = [datetime]::ParseExact($StartAt, "yyyy-MM-dd:HH-mm", [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Write-Log ERROR "Invalid -StartAt format. Use yyyy-MM-dd:HH-mm"
        return
    }

    $now = Get-Date
    if ($startTime -ge $now) {
        Write-Log ERROR "StartAt time must be in the past. Catch-up recording only works for already aired programs."
        return
    }

    $sanitizedStart = $StartAt -replace '[^a-zA-Z0-9]', '_'
    $Script:LogFile = Join-Path $Script:LogDir "record_catchup_${sanitizedStart}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Log INFO "Catch-up recording session started: $StartAt"

    $providerZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($conf.CatchupTimezone)
    $utcTime = $startTime.ToUniversalTime()
    $convertedTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcTime, $providerZone)
    $encodedStart = $convertedTime.ToString("yyyy-MM-dd:HH-mm")

    $outputFolder = Join-Path $HOME "Videos"
    $DurationSeconds = $DurationMinutes * 60
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $lastChan = $Channel[-1]

    foreach ($chan in $Channel) {
        $code = $conf.ChannelMap[$chan]
        $outputPath = Join-Path $outputFolder "${chan}_${timestamp}.ts"
        $formatStyle = $conf.CatchupFormatStyle
        if (-not $formatStyle) { $formatStyle = "query" }  # Default fallback

        switch ($formatStyle) {
            "query" {
                $url = "$($conf.CatchupUrl)?username=$($conf.Username)&password=$($conf.Password)&stream=$code&start=$encodedStart&duration=$CustomDuration"
            }
            "path" {
                $url = "$($conf.BaseUrl)/timeshift/$($conf.Username)/$($conf.Password)/$CustomDuration/$encodedStart/$code.ts"
            }
            default {
                Write-Log ERROR "Unknown CatchupFormatStyle: $formatStyle"
                return
            }
        }

        $quotedUrl = '"' + $url + '"'
        $quotedOut = '"' + $outputPath + '"'
        $cmd = "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 400M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedUrl -map 0:v? -map 0:a? -t $DurationSeconds -c copy $quotedOut"

        if ($DryRun) {
            Write-Log "DRY-RUN" "Would run command: $cmd"
        } else {
            Write-Log INFO "Catch-up URL being used: $url"
            Write-Log INFO "Recording $chan at $convertedTime for $DurationMinutes minute(s)..."

            $buildRetryCmd = {
                param($remainingSeconds, $segmentPath, $elapsedSeconds)

                # Advance start time by the minutes already recorded
                $advanceMinutes = [math]::Floor($elapsedSeconds / 60)
                $newStart = $convertedTime.AddMinutes($advanceMinutes)
                $newEncodedStart = $newStart.ToString("yyyy-MM-dd:HH-mm")

                # Sub-minute offset to skip overlap
                $ssOffset = [math]::Floor($elapsedSeconds) % 60

                switch ($formatStyle) {
                    "query" {
                        $retryUrl = "$($conf.CatchupUrl)?username=$($conf.Username)&password=$($conf.Password)&stream=$code&start=$newEncodedStart&duration=$CustomDuration"
                    }
                    "path" {
                        $retryUrl = "$($conf.BaseUrl)/timeshift/$($conf.Username)/$($conf.Password)/$CustomDuration/$newEncodedStart/$code.ts"
                    }
                }

                $quotedRetryUrl = '"' + $retryUrl + '"'
                $quotedSeg = '"' + $segmentPath + '"'

                $retryCmd = "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 400M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedRetryUrl"
                if ($ssOffset -gt 0) {
                    $retryCmd += " -ss $ssOffset"
                }
                $retryCmd += " -map 0:v? -map 0:a? -t $([math]::Ceiling($remainingSeconds)) -c copy $quotedSeg"
                $retryCmd
            }

            $finalPath = Invoke-FfmpegWithRetry `
                -InitialCommand $cmd `
                -InitialOutputPath $outputPath `
                -TotalDurationSeconds $DurationSeconds `
                -BuildRetryCommand $buildRetryCmd

            if (-not $NoRemux) { Remux-TSFileToMKV -TSFilePath $finalPath } else { Write-Log INFO "NoRemux: skipping remux." }
        }

        if ($Channel.Count -gt 1 -and $chan -ne $lastChan) {
            Start-Sleep -Seconds 3
        }
    }
}

function Remove-Recording-Tasks {
    $Script:LogFile = Join-Path $Script:LogDir "remove_tasks_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Log INFO "Removing completed recording tasks..."

    $allText = (schtasks /query /fo LIST /v) -join "`n"

    # Split into per-task blocks and keep only Record-LiveIPTV_ ones
    $blocks = ($allText -split '(?m)(?=^TaskName:)') | Where-Object { $_ -match 'Record-LiveIPTV_' }

    if (-not $blocks) {
        Write-Log INFO "No Record-LiveIPTV tasks found."
        return
    }

    $removed = 0
    foreach ($block in $blocks) {
        $taskName = if ($block -match '(?m)^TaskName:\s+(.+)') { $Matches[1].Trim() } else { continue }
        $lastRun  = if ($block -match '(?m)^Last Run Time:\s+(.+)') { $Matches[1].Trim() } else { '' }
        $nextRun  = if ($block -match '(?m)^Next Run Time:\s+(.+)') { $Matches[1].Trim() } else { '' }

        if (($nextRun -eq '' -or $nextRun -eq 'N/A') -and $lastRun -ne '' -and $lastRun -ne 'N/A') {
            Write-Log INFO "Deleting completed task: $taskName"
            schtasks /delete /tn "$taskName" /f | Out-Null
            $removed++
        }
    }

    if ($removed -eq 0) {
        Write-Log INFO "No completed Record-LiveIPTV tasks needed deletion."
    } else {
        Write-Log INFO "$removed completed Record-LiveIPTV task(s) deleted."
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    # Script dot-sourced: skip auto-run
}
elseif ($Channel -and $DurationMinutes -and $Config) {
    Record-LiveIPTV -Channel $Channel -DurationMinutes $DurationMinutes -Config $Config -StartAt $StartAt -DryRun:$DryRun.IsPresent -Schedule:$Schedule.IsPresent -NoRemux:$NoRemux.IsPresent
}
