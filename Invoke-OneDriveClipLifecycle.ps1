#Requires -Version 5.1
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
Set-Location -Path $ScriptDir

<#
.SYNOPSIS
    OneDrive Highlight Clip Lifecycle & Quota Manager.

.DESCRIPTION
    Manages gaming highlight clips sourced from OneDrive once cloud/local storage fills up
    and clips have already been uploaded. Implements a 4-mode lifecycle pipeline:
      1. Audit            - Scans OneDrive clip folders, groups by game & hydration state, and checks upload ledger.
      2. DehydrateLocal   - Frees C: drive space (attrib +U -P) for pending clips while keeping them in OneDrive cloud.
      3. ArchiveUploaded  - Moves uploaded clips out of OneDrive to local cold storage (F:\HighlightArchive or D:\HighlightArchive),
                            freeing BOTH OneDrive cloud quota and C: drive space. Supports optional FFmpeg HEVC compression.
      4. PurgeUploaded    - Removes confirmed uploaded clips after a retention grace period (retaining ledger metadata & URLs).
#>

function Get-ClipGameTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    process {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        if ($base -match '^(?<game>.+?)[-_ ]+\d{4}[\._-]\d{2}[\._-]\d{2}') {
            $clean = ($Matches['game'] -replace '\.exe$', '').Trim()
            return $clean
        }
        if ($base -match '(?i)tekken') {
            return 'TEKKEN 8'
        }
        if ($base -match '^\d{1,2}-\d{1,2}-\d{4}_') {
            return 'Xbox_Legacy_DVR'
        }
        return 'Misc_Highlights'
    }
}

function Get-OneDriveClipInventory {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$OneDriveClipPaths = @(
            (Join-Path -Path $env:OneDrive -ChildPath 'Videos\Xbox Game DVR'),
            (Join-Path -Path $env:OneDrive -ChildPath 'Gaming & Media\Clips & Highlights'),
            (Join-Path -Path $env:OneDrive -ChildPath 'Videos')
        ),

        [Parameter()]
        [string]$LedgerPath = (Join-Path -Path $ScriptDir -ChildPath 'clip_upload_ledger.json')
    )

    begin {
        $ErrorActionPreference = 'Stop'
        $ledgerMap = @{}
        if (Test-Path -LiteralPath $LedgerPath) {
            $ledgerEntries = Get-Content -LiteralPath $LedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in @($ledgerEntries)) {
                if ($null -ne $entry -and $null -ne $entry.FileName) {
                    $ledgerMap[$entry.FileName] = $entry
                }
            }
        }
    }

    process {
        foreach ($folder in $OneDriveClipPaths) {
            if (-not (Test-Path -LiteralPath $folder)) {
                continue
            }

            $isRootVideos = ($folder -eq (Join-Path -Path $env:OneDrive -ChildPath 'Videos'))
            $files = if ($isRootVideos) {
                Get-ChildItem -LiteralPath $folder -File -Filter '*.mp4' -ErrorAction SilentlyContinue
            } else {
                Get-ChildItem -LiteralPath $folder -File -Recurse -Include '*.mp4', '*.mov', '*.mkv' -ErrorAction SilentlyContinue
            }

            foreach ($file in @($files)) {
                $isOffline = [bool]($file.Attributes -band [System.IO.FileAttributes]::Offline)
                $ledgerEntry = if ($ledgerMap.ContainsKey($file.Name)) { $ledgerMap[$file.Name] } else { $null }
                $isUploaded = if ($null -ne $ledgerEntry -and $ledgerEntry.Status -eq 'Uploaded') { $true } else { $false }
                $ageDays = [math]::Round(((Get-Date) - $file.LastWriteTime).TotalDays, 1)

                [PSCustomObject]@{
                    FileName       = $file.Name
                    FullPath       = $file.FullName
                    Game           = Get-ClipGameTitle -FileName $file.Name
                    SizeMB         = [math]::Round(($file.Length / 1MB), 2)
                    SizeBytes      = [int64]$file.Length
                    LastWriteTime  = $file.LastWriteTime
                    AgeDays        = $ageDays
                    HydratedOnDisk = (-not $isOffline)
                    Uploaded       = $isUploaded
                    UploadUrl      = if ($null -ne $ledgerEntry) { $ledgerEntry.UploadUrl } else { $null }
                    UploadedAt     = if ($null -ne $ledgerEntry) { $ledgerEntry.UploadedAt } else { $null }
                }
            }
        }
    }

    end {
    }
}

function Register-UploadedClip {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$FileName,

        [Parameter()]
        [string]$UploadUrl = '',

        [Parameter()]
        [string]$Platform = 'YouTube',

        [Parameter()]
        [string]$LedgerPath = (Join-Path -Path $ScriptDir -ChildPath 'clip_upload_ledger.json')
    )

    begin {
        $ErrorActionPreference = 'Stop'
        $ledger = [System.Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $LedgerPath) {
            $existing = Get-Content -LiteralPath $LedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($item in @($existing)) {
                if ($null -ne $item) {
                    $ledger.Add($item)
                }
            }
        }
    }

    process {
        $leafName = [System.IO.Path]::GetFileName($FileName)
        if ($PSCmdlet.ShouldProcess($leafName, "Mark clip as Uploaded in ledger ($Platform)")) {
            $existingItem = $ledger | Where-Object { $_.FileName -eq $leafName } | Select-Object -First 1
            $record = [PSCustomObject]@{
                FileName   = $leafName
                Game       = Get-ClipGameTitle -FileName $leafName
                Status     = 'Uploaded'
                Platform   = $Platform
                UploadUrl  = $UploadUrl
                UploadedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
            }

            if ($null -ne $existingItem) {
                $idx = $ledger.IndexOf($existingItem)
                $ledger[$idx] = $record
            } else {
                $ledger.Add($record)
            }
            $record
        }
    }

    end {
        if ($PSCmdlet.ShouldProcess($LedgerPath, 'Save updated clip upload ledger')) {
            $ledger | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LedgerPath -Encoding UTF8
        }
    }
}

function Invoke-OneDriveClipLifecycle {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [ValidateSet('Audit', 'DehydrateLocal', 'ArchiveUploaded', 'PurgeUploaded', 'RemoveDuplicates')]
        [string]$Action = 'Audit',

        [Parameter()]
        [string]$ArchiveRoot = 'F:\HighlightArchive',

        [Parameter()]
        [int]$MinAgeDays = 0,

        [Parameter()]
        [switch]$IncludeUnmarkedOlderThanMinAge,

        [Parameter()]
        [switch]$HydratedOnly,

        [Parameter()]
        [switch]$CompressOnArchive,

        [Parameter()]
        [string]$LedgerPath = (Join-Path -Path $ScriptDir -ChildPath 'clip_upload_ledger.json')
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        try {
            $inventory = @(Get-OneDriveClipInventory -LedgerPath $LedgerPath)

            if ($Action -eq 'Audit') {
                $totalGB = [math]::Round((($inventory | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
                $hydrated = @($inventory | Where-Object { $_.HydratedOnDisk })
                $hydratedGB = [math]::Round((($hydrated | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
                $uploaded = @($inventory | Where-Object { $_.Uploaded })
                $uploadedGB = [math]::Round((($uploaded | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)

                $byGame = $inventory | Group-Object -Property Game | ForEach-Object {
                    [PSCustomObject]@{
                        Game       = $_.Name
                        ClipCount  = @($_.Group).Count
                        TotalGB    = [math]::Round((($_.Group | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
                        HydratedGB = [math]::Round((($_.Group | Where-Object { $_.HydratedOnDisk } | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
                        Uploaded   = @($_.Group | Where-Object { $_.Uploaded }).Count
                    }
                } | Sort-Object -Property TotalGB -Descending

                [PSCustomObject]@{
                    Timestamp          = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
                    TotalClips         = $inventory.Count
                    OneDriveCloudGB    = $totalGB
                    LocalHydratedCount = $hydrated.Count
                    LocalHydratedGB    = $hydratedGB
                    MarkedUploaded     = $uploaded.Count
                    MarkedUploadedGB   = $uploadedGB
                    ArchiveDestination = $ArchiveRoot
                    BreakdownByGame    = $byGame
                }
                return
            }

            if ($Action -eq 'RemoveDuplicates') {
                $sameSizeGroups = @($inventory | Group-Object -Property SizeBytes | Where-Object { $_.Count -gt 1 })
                foreach ($grp in $sameSizeGroups) {
                    $seenKeys = @{}
                    foreach ($clip in @($grp.Group | Sort-Object -Property LastWriteTime)) {
                        $normKey = ($clip.FileName -replace '[_-]', '').ToLowerInvariant()
                        $key = if ($clip.HydratedOnDisk) {
                            (Get-FileHash -LiteralPath $clip.FullPath -Algorithm SHA256).Hash
                        } else {
                            "$normKey|$($clip.SizeBytes)"
                        }
                        if ($seenKeys.ContainsKey($key)) {
                            $original = $seenKeys[$key]
                            if ($PSCmdlet.ShouldProcess($clip.FullPath, "Remove duplicate of '$($original.FileName)' (free $($clip.SizeMB) MB)")) {
                                Remove-Item -LiteralPath $clip.FullPath -Force
                                [PSCustomObject]@{
                                    Action      = 'RemoveDuplicates'
                                    DuplicateOf = $original.FileName
                                    RemovedFile = $clip.FileName
                                    FreedMB     = $clip.SizeMB
                                    Status      = 'Success'
                                }
                            }
                        } else {
                            $seenKeys[$key] = $clip
                        }
                    }
                }
                return
            }

            $candidates = @($inventory | Where-Object {
                $ageMatch = ($_.AgeDays -ge $MinAgeDays)
                $hydrationMatch = if ($HydratedOnly) { $_.HydratedOnDisk } else { $true }
                if ($IncludeUnmarkedOlderThanMinAge -and $MinAgeDays -gt 0) {
                    $ageMatch -and $hydrationMatch -and ($_.Uploaded -or ($_.AgeDays -ge $MinAgeDays))
                } elseif ($Action -eq 'DehydrateLocal') {
                    $_.HydratedOnDisk -and $ageMatch
                } else {
                    $_.Uploaded -and $ageMatch -and $hydrationMatch
                }
            })

            foreach ($clip in $candidates) {
                switch ($Action) {
                    'DehydrateLocal' {
                        if ($PSCmdlet.ShouldProcess($clip.FullPath, "Dehydrate local OneDrive copy (free $($clip.SizeMB) MB on C:)")) {
                            & attrib.exe +U -P $clip.FullPath
                            [PSCustomObject]@{
                                Action    = 'DehydrateLocal'
                                FileName  = $clip.FileName
                                FreedMB   = $clip.SizeMB
                                Target    = 'OneDrive Cloud-Only'
                                Status    = 'Success'
                            }
                        }
                    }

                    'ArchiveUploaded' {
                        $monthFolder = $clip.LastWriteTime.ToString('yyyy-MM')
                        $destDir = Join-Path -Path $ArchiveRoot -ChildPath (Join-Path -Path $clip.Game -ChildPath $monthFolder)
                        $destPath = Join-Path -Path $destDir -ChildPath $clip.FileName

                        if ($PSCmdlet.ShouldProcess($clip.FullPath, "Move out of OneDrive to Cold Storage '$destPath' (free $($clip.SizeMB) MB OneDrive quota)")) {
                            if (-not (Test-Path -LiteralPath $destDir)) {
                                $null = New-Item -Path $destDir -ItemType Directory -Force
                            }

                            if ($CompressOnArchive) {
                                $ffmpegCmd = Get-Command -Name 'ffmpeg' -ErrorAction SilentlyContinue
                                if ($null -eq $ffmpegCmd) {
                                    throw 'FFmpeg not found on PATH for -CompressOnArchive.'
                                }
                                & ffmpeg -hide_banner -loglevel error -y -i $clip.FullPath -c:v libx265 -crf 23 -preset fast -c:a aac -b:a 192k $destPath
                                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $destPath)) {
                                    Remove-Item -LiteralPath $clip.FullPath -Force
                                } else {
                                    throw "FFmpeg compression failed for $($clip.FullPath)"
                                }
                            } else {
                                Move-Item -LiteralPath $clip.FullPath -Destination $destPath -Force
                            }

                            [PSCustomObject]@{
                                Action    = if ($CompressOnArchive) { 'ArchiveCompressedHEVC' } else { 'ArchiveMoved' }
                                FileName  = $clip.FileName
                                Game      = $clip.Game
                                FreedMB   = $clip.SizeMB
                                Target    = $destPath
                                Status    = 'Success'
                            }
                        }
                    }

                    'PurgeUploaded' {
                        if ($PSCmdlet.ShouldProcess($clip.FullPath, "Delete uploaded clip from OneDrive (free $($clip.SizeMB) MB OneDrive quota)")) {
                            Remove-Item -LiteralPath $clip.FullPath -Force
                            [PSCustomObject]@{
                                Action    = 'PurgeUploaded'
                                FileName  = $clip.FileName
                                Game      = $clip.Game
                                FreedMB   = $clip.SizeMB
                                Target    = 'Deleted (OneDrive Recycle Bin 30d)'
                                Status    = 'Success'
                            }
                        }
                    }
                }
            }
        }
        catch [System.IO.FileNotFoundException] {
            Write-Error -Message "Clip file not found during lifecycle execution: $($_.Exception.Message)"
        }
        catch {
            Write-Error -Message "Lifecycle error: $($_.Exception.Message)"
        }
        finally {
        }
    }

    end {
    }
}
