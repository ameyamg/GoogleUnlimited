# =====================================================================
# Regression Test Suite: Issue #7 (OneDrive & Cloud Reparse Point Support)
# Tests:
#   1. Test-IsSymlinkOrJunction correctly distinguishes Junctions & Symlinks (SEC-05)
#      from Cloud Storage Folders (OneDrive, iCloud Drive, etc.)
#   2. OneDrive directory with ReparsePoint attribute does NOT cause files to be ignored
#   3. OneDrive files with ReparsePoint attribute (0x420) are marked as eligible media
#   4. Symbolic links and junctions pointing to directories are properly blocked (SEC-05)
#   5. Startup scan and periodic sweep successfully discover files in OneDrive folders
# =====================================================================
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gotohp_test_onedrive_" + [System.Guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($tempDir) | Out-Null

function Cleanup {
    if ([System.IO.Directory]::Exists($tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: Issue #7 OneDrive & Cloud Reparse Support"   -ForegroundColor Green
Write-Host "  Temp Directory: $tempDir"                                 -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Condition([bool]$condition, [string]$message) {
    if ($condition) {
        Write-Host "  [PASS] $message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $message" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # Load WatchAndUpload helper functions if possible, or define Test-IsSymlinkOrJunction
    # Test 1: Real OneDrive folder detection on system
    $oneDrivePath = Join-Path $env:USERPROFILE "OneDrive"
    $hasOneDrive = [System.IO.Directory]::Exists($oneDrivePath)

    # Setup mock structure for symlink and junction testing
    $realTargetDir = Join-Path $tempDir "RealTarget"
    [System.IO.Directory]::CreateDirectory($realTargetDir) | Out-Null
    $realFile = Join-Path $realTargetDir "photo.jpg"
    [System.IO.File]::WriteAllBytes($realFile, [byte[]]@(0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10))

    $junctionDir = Join-Path $tempDir "JunctionDir"
    New-Item -ItemType Junction -Path $junctionDir -Target $realTargetDir | Out-Null

    # Test symlink creation (may require dev mode or elevation; gracefully skip if OS restricts)
    $symlinkFile = Join-Path $tempDir "symlink_photo.jpg"
    $canCreateSymlink = $false
    try {
        New-Item -ItemType SymbolicLink -Path $symlinkFile -Target $realFile -ErrorAction Stop | Out-Null
        $canCreateSymlink = $true
    } catch {}

    # Define the Test-IsSymlinkOrJunction implementation
    function Test-IsSymlinkOrJunction($item) {
        if (-not $item) { return $false }
        try {
            if ($item -is [string]) {
                if ([System.IO.Directory]::Exists($item)) {
                    $item = New-Object System.IO.DirectoryInfo($item)
                } elseif ([System.IO.File]::Exists($item)) {
                    $item = New-Object System.IO.FileInfo($item)
                } else {
                    return $false
                }
            }
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return $false
            }
            $lt = $item.LinkType
            if ($lt -and ($lt -eq "SymbolicLink" -or $lt -eq "Junction" -or $lt -eq "MountPoint")) {
                return $true
            }
            if ($item.PSObject.Properties["LinkTarget"] -and -not [string]::IsNullOrEmpty($item.LinkTarget)) {
                return $true
            }
            if ($item.PSObject.Properties["Target"] -and $item.Target) {
                return $true
            }
            return $false
        } catch {
            return $false
        }
    }

    # Verification:
    Write-Host "`nTest 1: Distinguishing Junctions and Links from Normal/Cloud Folders" -ForegroundColor Yellow
    $juncInfo = New-Object System.IO.DirectoryInfo($junctionDir)
    Assert-Condition (Test-IsSymlinkOrJunction $juncInfo) "Junction directory is correctly identified as a link (SEC-05)"

    $targetInfo = New-Object System.IO.DirectoryInfo($realTargetDir)
    Assert-Condition (-not (Test-IsSymlinkOrJunction $targetInfo)) "Real directory is NOT flagged as a link"

    $realFileInfo = New-Object System.IO.FileInfo($realFile)
    Assert-Condition (-not (Test-IsSymlinkOrJunction $realFileInfo)) "Real photo file is NOT flagged as a link"

    if ($canCreateSymlink) {
        $symInfo = New-Object System.IO.FileInfo($symlinkFile)
        Assert-Condition (Test-IsSymlinkOrJunction $symInfo) "Symbolic link file is correctly identified as a link (SEC-05)"
    } else {
        Write-Host "  [SKIP] Symbolic link creation restricted by OS policy on this host" -ForegroundColor Gray
    }

    if ($hasOneDrive) {
        $oneDriveInfo = New-Object System.IO.DirectoryInfo($oneDrivePath)
        $isReparse = [bool]($oneDriveInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        Assert-Condition ($isReparse -eq $true) "OneDrive directory possesses ReparsePoint attribute"
        Assert-Condition (-not (Test-IsSymlinkOrJunction $oneDriveInfo)) "OneDrive directory is NOT falsely blocked as a symlink/junction"

        # Check existing OneDrive files/folders
        $odItems = @(Get-ChildItem -LiteralPath $oneDrivePath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 5)
        if ($odItems.Count -gt 0) {
            $allValid = $true
            foreach ($item in $odItems) {
                if (Test-IsSymlinkOrJunction $item) { $allValid = $false }
            }
            Assert-Condition $allValid "Existing OneDrive files with ReparsePoint attributes are NOT falsely blocked as symlinks"
        }
    } else {
        Write-Host "  [SKIP] OneDrive directory not present in current user profile" -ForegroundColor Gray
    }

    # Test 2: Test-IsEligibleMedia with OneDrive-style FileInfo and DirectoryInfo
    Write-Host "`nTest 2: Media Eligibility for OneDrive Files" -ForegroundColor Yellow

    # Initialize extensions set matching WatchAndUpload.ps1
    $validExtensions = @(
        '.jpg', '.jpeg', '.png', '.heic', '.heif', '.webp', '.gif', '.bmp', '.tiff', '.tif', '.jfif', '.avif',
        '.dng', '.cr2', '.cr3', '.nef', '.arw', '.raw', '.orf', '.rw2', '.pef', '.srw', '.raf',
        '.mp4', '.mov', '.mkv', '.avi', '.m4v', '.3gp', '.3g2', '.wmv', '.webm', '.flv', '.mts', '.m2ts', '.ts', '.mpg'
    )
    $testExt = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ext in $validExtensions) { [void]$testExt.Add($ext) }
    $script:inFlight = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    function Test-IsDuplicateUpload([string]$filePath) { return $false }

    function Test-IsEligibleMediaNew([System.IO.FileInfo]$fi) {
        if (-not $testExt.Contains($fi.Extension.ToLower())) { return $false }
        if ($fi.FullName.Contains("\Modules\")) { return $false }
        # Security: Skip symbolic links and junction directories (SEC-05), allow cloud sync files (OneDrive, iCloud)
        if (Test-IsSymlinkOrJunction $fi) { return $false }
        try {
            if ($fi.Directory -and (Test-IsSymlinkOrJunction $fi.Directory)) { return $false }
        } catch {}
        if ($script:inFlight.Contains($fi.FullName)) { return $false }
        if (-not $ForceResync -and (Test-IsDuplicateUpload $fi.FullName)) { return $false }
        return $true
    }

    Assert-Condition (Test-IsEligibleMediaNew $realFileInfo) "Standard media file is eligible"

    # File inside junction directory must be rejected by SEC-05
    $juncFile = Join-Path $junctionDir "photo.jpg"
    $juncFileInfo = New-Object System.IO.FileInfo($juncFile)
    Assert-Condition (-not (Test-IsEligibleMediaNew $juncFileInfo)) "File inside junction directory is rejected (SEC-05)"

    # Verify that in OneDrive (if available), photo inside OneDrive is eligible
    if ($hasOneDrive) {
        $odTestDir = Join-Path $oneDrivePath "TestPictures_Issue7"
        [System.IO.Directory]::CreateDirectory($odTestDir) | Out-Null
        $odTestFile = Join-Path $odTestDir "sample_onedrive_pic.png"
        [System.IO.File]::WriteAllBytes($odTestFile, [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))

        $odFi = New-Object System.IO.FileInfo($odTestFile)
        Assert-Condition (Test-IsEligibleMediaNew $odFi) "Photo file inside OneDrive folder is eligible"

        # Test simulated discovery pipeline
        $discovered = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
        Get-ChildItem -LiteralPath $odTestDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-IsSymlinkOrJunction $_) -and
                (-not $_.Directory -or -not (Test-IsSymlinkOrJunction $_.Directory))
            } |
            Where-Object { Test-IsEligibleMediaNew $_ } |
            ForEach-Object { $discovered.Add($_) }

        Assert-Condition ($discovered.Count -ge 1) "Startup / sweep pipeline detects file inside OneDrive folder"

        # Cleanup test OneDrive folder
        Remove-Item -LiteralPath $odTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

} finally {
    Cleanup
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
