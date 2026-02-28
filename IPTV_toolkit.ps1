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

    Write-Output "Remuxing to mkv: $mkvPath ..."
    $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -eq 0 -and (Test-Path $mkvPath)) {
        Remove-Item $TSFilePath
        Write-Output "Remux successful. Deleted original .ts file."
        return $mkvPath
    } else {
        Write-Warning "Remux failed. .ts file kept."
        return $null
    }
}

function Get-MediaDuration {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) { return 0 }

    try {
        $output = & ffprobe -v error -show_entries format=duration -of csv=p=0 "$FilePath" 2>$null
        $duration = [double]$output
        return $duration
    } catch {
        return 0
    }
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

    Write-Host "Concatenating $($resolvedSegments.Count) segments..."
    $process = Start-Process -FilePath "ffmpeg" -ArgumentList "-f concat -safe 0 -i `"$concatList`" -c copy `"$FinalOutputPath`"" -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Warning "Concatenation failed (ffmpeg exit code $($process.ExitCode))."
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
            Write-Host "Only $([math]::Round($remaining, 1))s remaining — skipping retry."
            break
        }

        Write-Host "Retry $retry/$MaxRetries — $([math]::Round($remaining, 0))s remaining..."

        $segPath = Join-Path $dir "${baseName}_seg${retry}.ts"
        $retryCmd = & $BuildRetryCommand $remaining $segPath $elapsed

        Invoke-Expression $retryCmd

        $segDuration = Get-MediaDuration -FilePath $segPath
        if ($segDuration -eq 0) {
            Write-Warning "Retry $retry produced empty/corrupt file — stopping retries."
            if (Test-Path $segPath) { Remove-Item $segPath -Force }
            break
        }

        $segments += $segPath
        $elapsed += $segDuration

        if ($elapsed -ge ($TotalDurationSeconds - 2)) {
            Write-Host "Target duration reached after retry $retry."
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
        Write-Error "Invalid config '$Config'. Define it in `\$IPTVConfigs` in your profile."
        return
    }

    $conf = $Global:IPTVConfigs[$Config]

    if (-not $conf.ChannelMap.ContainsKey($Channel)) {
        Write-Error "Invalid channel name: $Channel. Valid options: $($conf.ChannelMap.Keys -join ', ')"
        return
    }

    $startTime = $null
    if ($StartAt) {
        try {
            $startTime = [datetime]::ParseExact(
                $StartAt, "yyyy-MM-dd:HH-mm",
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeLocal
            )
        } catch {
            Write-Error "Invalid -StartAt format. Use yyyy-MM-dd:HH-mm."
            return
        }
    }

    # --- Schedule logic ---
    if ($Schedule) {
        if (-not $StartAt) {
            Write-Error "You must provide -StartAt with -Schedule. Use format yyyy-MM-dd:HH-mm."
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
        Write-Host "`n[DEBUG] Task will run (copy this into Task Scheduler's Action fields to confirm):"
        Write-Host "Program/script: $pwshPath" -ForegroundColor Yellow
        Write-Host "Add arguments: $argString" -ForegroundColor Yellow

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

        Write-Host "`nScheduling recording for $Channel at $dateStr $timeStr via Windows Task Scheduler..."
        $out = schtasks.exe @schtasksCmd
        Write-Host $out

        Write-Host "Scheduled task '$taskName' created."
        return
    }

    # --- Start time logic (sleep until start, if StartAt specified) ---
    $DurationSeconds = $DurationMinutes * 60

    if ($StartAt) {
        $now = Get-Date
        Write-Host "Current Time: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Host "Scheduled Start Time: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"

        $delay = ($startTime - $now).TotalSeconds
        if ($delay -le 0) {
            Write-Error "Start time is in the past. Recording cannot proceed."
            return
        }

        Write-Host "Sleeping until recording of [$Channel] starts at [$($startTime.ToString('yyyy-MM-dd HH:mm'))] for [$DurationMinutes] minute(s)..."
        while ($true) {
            $remaining = [int](($startTime - (Get-Date)).TotalSeconds)
            if ($remaining -le 0) { break }

            $timeStr = [timespan]::FromSeconds($remaining).ToString("mm\:ss")
            Write-Host -NoNewline "`rStarting in $timeStr...  "

            Start-Sleep -Seconds ([Math]::Min(1, $remaining))
        }
        Write-Host "`rStarting now!             "
    }

    # --- Build stream URL ---
    $code = $conf.ChannelMap[$Channel]
    $suffix = if ($conf.AddTsSuffix) { ".ts" } else { "" }
    $url = "$($conf.BaseUrl)/$($conf.Username)/$($conf.Password)/$code$suffix"

    Write-Host "`nURL being used: $url" -ForegroundColor Yellow

    $outputPath = Join-Path (Join-Path $HOME "Videos") "${Channel}_$(Get-Date -Format 'yyyyMMdd_HHmm').ts"
    $quotedUrl = '"' + $url + '"'
    $quotedOut = '"' + $outputPath + '"'

    $cmd = "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 200M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedUrl -map 0:v? -map 0:a? -t $DurationSeconds -c copy $quotedOut"

    if ($DryRun) {
        Write-Host "`n[DryRun] Would run command:"
        Write-Host $cmd -ForegroundColor Cyan
    } else {
        Write-Output "Recording $Channel now for $DurationMinutes minute(s)..."

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

        if (-not $NoRemux) { Remux-TSFileToMKV -TSFilePath $finalPath } else { Write-Host 'NoRemux: skipping remux.' }
    }
}

# -------------------------------------
# 🕒 RECORD CATCH-UP STREAM (SINGLE CHANNEL)
# -------------------------------------
# Record canalplus_sport from 4 May 2025 at 15:00 local time for 3 minutes
# Record-CatchupIPTV -config trex -Channel canalplus_sport -StartAt "2025-05-04:15-00" -DurationMinutes 3
#
# -------------------------------------
# 🕒 RECORD CATCH-UP STREAM (MULTIPLE CHANNELS)
# -------------------------------------
# Record canalplus_sport and sky_sport_de_mix for the same time chunk
# Starts at 4 May 2025, 15:00 local time, each for 3 minutes
# Record-CatchupIPTV -config trex -MultiChannel canalplus_sport,sky_sport_de_mix -StartAt "2025-05-04:15-00" -DurationMinutes 3
# Current limitation: all channels must be on the same config
#
# -------------------------------------
# 🔍 DRY RUN TO SHOW FFmpeg COMMAND
# -------------------------------------
# Just print the ffmpeg command without executing
# Record-CatchupIPTV -config trex -Channel sky_sport_it_motogp -StartAt "2025-05-04:15-00" -DurationMinutes 3 -DryRun

function Record-CatchupIPTV {
    param (
        [string]$Channel,
        [string[]]$MultiChannel,

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
        Write-Error "Invalid config '$Config'. Define it in `\$IPTVConfigs` in your profile."
        return
    }

    $conf = $Global:IPTVConfigs[$Config]

    $channelsToRecord = @()
    if ($MultiChannel) {
        foreach ($chan in $MultiChannel) {
            if (-not $conf.ChannelMap.ContainsKey($chan)) {
                Write-Error "Invalid channel: $chan"
                return
            }
        }
        $channelsToRecord = $MultiChannel
    } elseif ($Channel) {
        if (-not $conf.ChannelMap.ContainsKey($Channel)) {
            Write-Error "Invalid channel: $Channel"
            return
        }
        $channelsToRecord = @($Channel)
    } else {
        Write-Error "You must specify either -Channel or -MultiChannel."
        return
    }

    try {
        $startTime = [datetime]::ParseExact($StartAt, "yyyy-MM-dd:HH-mm", [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Write-Error "Invalid -StartAt format. Use yyyy-MM-dd:HH-mm"
        return
    }

    $now = Get-Date
    if ($startTime -ge $now) {
        Write-Error "StartAt time must be in the past. Catch-up recording only works for already aired programs."
        return
    }

    $centralEuropeanZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Central European Standard Time")
    $utcTime = $startTime.ToUniversalTime()
    $convertedTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcTime, $centralEuropeanZone)
    $encodedStart = $convertedTime.ToString("yyyy-MM-dd:HH-mm")

    $outputFolder = Join-Path $HOME "Videos"
    $DurationSeconds = $DurationMinutes * 60
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $lastChan = $channelsToRecord[-1]

    foreach ($chan in $channelsToRecord) {
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
                Write-Error "Unknown CatchupFormatStyle: $formatStyle"
                return
            }
        }

        $quotedUrl = '"' + $url + '"'
        $quotedOut = '"' + $outputPath + '"'
        $cmd = "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 400M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedUrl -map 0:v? -map 0:a? -t $DurationSeconds -c copy $quotedOut"

        if ($DryRun) {
            Write-Host "`n[DryRun] Would run command:"
            Write-Host $cmd -ForegroundColor Cyan
        } else {
            Write-Host "`nCatch-up URL being used: $url" -ForegroundColor Yellow
            Write-Output "Recording $chan at $convertedTime CET for $DurationMinutes minute(s)..."

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

                $retryCmd = "ffmpeg -analyzeduration 20000000 -probesize 20000000 -rtbufsize 400M -user_agent `"Mozilla/5.0`" -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts -i $quotedRetryUrl"
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

            if (-not $NoRemux) { Remux-TSFileToMKV -TSFilePath $finalPath } else { Write-Host 'NoRemux: skipping remux.' }
        }

        if ($channelsToRecord.Count -gt 1 -and $chan -ne $lastChan) {
            Start-Sleep -Seconds 3
        }
    }
}

function Remove-Recording-Tasks {
    $allText = (schtasks /query /fo LIST /v) -join "`n"

    # Split into per-task blocks and keep only Record-LiveIPTV_ ones
    $blocks = ($allText -split '(?m)(?=^TaskName:)') | Where-Object { $_ -match 'Record-LiveIPTV_' }

    if (-not $blocks) {
        Write-Host "No Record-LiveIPTV tasks found."
        return
    }

    $removed = 0
    foreach ($block in $blocks) {
        $taskName = if ($block -match '(?m)^TaskName:\s+(.+)') { $Matches[1].Trim() } else { continue }
        $lastRun  = if ($block -match '(?m)^Last Run Time:\s+(.+)') { $Matches[1].Trim() } else { '' }
        $nextRun  = if ($block -match '(?m)^Next Run Time:\s+(.+)') { $Matches[1].Trim() } else { '' }

        if (($nextRun -eq '' -or $nextRun -eq 'N/A') -and $lastRun -ne '' -and $lastRun -ne 'N/A') {
            Write-Host "Deleting completed task: $taskName"
            schtasks /delete /tn "$taskName" /f | Out-Null
            $removed++
        }
    }

    if ($removed -eq 0) {
        Write-Host "No completed Record-LiveIPTV tasks needed deletion."
    } else {
        Write-Host "$removed completed Record-LiveIPTV task(s) deleted."
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    # Script dot-sourced: skip auto-run
}
elseif ($Channel -and $DurationMinutes -and $Config) {
    Record-LiveIPTV -Channel $Channel -DurationMinutes $DurationMinutes -Config $Config -StartAt $StartAt -DryRun:$DryRun.IsPresent -Schedule:$Schedule.IsPresent -NoRemux:$NoRemux.IsPresent
}