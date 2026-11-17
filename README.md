# OneDrive Highlight Clip Lifecycle Manager

Automated storage and lifecycle management for gaming highlight clips captured to OneDrive (`Videos\Xbox Game DVR` and `Gaming & Media\Clips & Highlights`).

## Lifecycle Pipeline

1. **Audit (`-Action Audit`)**
   Scans OneDrive clip directories, categorizes clips by game title, measures total OneDrive cloud usage vs. locally hydrated `C:` drive usage, and cross-references `clip_upload_ledger.json`.
2. **Remove Duplicates (`-Action RemoveDuplicates`)**
   Identifies identical byte-size captures, verifies SHA-256 hashes (for hydrated files) or normalized timestamps (for cloud-only files), and removes redundant copies.
3. **Cold-Storage Offload (`-Action ArchiveUploaded`)**
   Moves uploaded or aged clips out of OneDrive into `F:\HighlightArchive\<Game>\<YYYY-MM>\`, immediately freeing **both** OneDrive cloud storage and `C:` drive space.
   - Use `-HydratedOnly` to move only locally cached files without triggering OneDrive downloads of cloud-only files.
   - Use `-CompressOnArchive` to transcode raw DVR clips to H.265/HEVC (`libx265 -crf 23`) during archival.
4. **Local Dehydration (`-Action DehydrateLocal`)**
   Runs `attrib.exe +U -P` on pending/recent clips so they remain available in OneDrive cloud while reclaiming local `C:` disk space.
5. **Safe Purge (`-Action PurgeUploaded`)**
   Deletes confirmed uploaded clips from OneDrive after a retention window (`-MinAgeDays`), sending them to the 30-day OneDrive Recycle Bin while keeping upload URLs in `clip_upload_ledger.json`.

## Usage Examples

```powershell
Set-Location "g:\My Drive\Antigravity\Projects\onedrive cleanup"
. .\Invoke-OneDriveClipLifecycle.ps1

# 1. Inspect current OneDrive clip usage
Invoke-OneDriveClipLifecycle -Action Audit

# 2. Record a newly uploaded clip in the ledger
Register-UploadedClip -FileName "TEKKEN 8-2026_11_13-03_47_59.mp4" -UploadUrl "https://youtube.com/shorts/example"

# 3. Archive uploaded clips (or local clips older than 30 days) to F:\HighlightArchive
Invoke-OneDriveClipLifecycle -Action ArchiveUploaded -ArchiveRoot "F:\HighlightArchive" -MinAgeDays 30 -IncludeUnmarkedOlderThanMinAge -HydratedOnly

# 4. Dehydrate local clips older than 7 days to free C: space
Invoke-OneDriveClipLifecycle -Action DehydrateLocal -MinAgeDays 7
```
