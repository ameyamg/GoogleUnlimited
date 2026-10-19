# =====================================================================
# Regression Test Suite: PERF-01 (Bounded LRU Cache & SQLite Index Fallback)
# =====================================================================
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$tempDir = Join-Path $env:TEMP "gotohp_test_lru_$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$testDb = Join-Path $tempDir "test_lru.db"

# Import SQLite module
$modulePath = Join-Path $repoDir "Modules\PSSQLite\PSSQLite.psd1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
} else {
    Write-Warning "PSSQLite module not found at $modulePath"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: PERF-01 Bounded LRU Cache & Index Fallback"     -ForegroundColor Green
Write-Host "  Temp DB: $testDb"                                         -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

# Initialize DB with schema & indexes
Invoke-SqliteQuery -DataSource $testDb -Query @"
CREATE TABLE IF NOT EXISTS uploads (
    path         TEXT PRIMARY KEY,
    media_key    TEXT,
    uploaded_at  TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    file_name    TEXT,
    file_size    INTEGER,
    content_hash TEXT
);
CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);
CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);
"@

function Get-FileHashSafe([string]$path) {
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($fs)
        $fs.Close()
        $fs.Dispose()
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
    } catch {
        return $null
    }
}

# State for bounded cache testing
$script:MAX_CACHE_SIZE = 50   # Small threshold for test verification
$script:history    = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:cacheQueue = New-Object 'System.Collections.Generic.Queue[string]'
$script:fileLookup = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:pathSize   = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:pathHash   = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:DB         = $testDb

function Add-ToCache([string]$path, [long]$fileSize = 0, [string]$contentHash = "", [string]$fileName = "") {
    if (-not $path) { return }
    if (-not $fileName) {
        $fileName = [System.IO.Path]::GetFileName($path)
    }

    if (-not $script:history.Contains($path)) {
        while ($script:cacheQueue.Count -ge $script:MAX_CACHE_SIZE) {
            $evicted = $script:cacheQueue.Dequeue()
            if ($evicted) {
                $null = $script:history.Remove($evicted)
                $null = $script:pathSize.Remove($evicted)
                $null = $script:pathHash.Remove($evicted)
            }
        }
        $script:history.Add($path) | Out-Null
        $script:cacheQueue.Enqueue($path)
    }

    if ($fileSize -gt 0) {
        $script:pathSize[$path] = $fileSize
    }
    if ($contentHash) {
        $script:pathHash[$path] = $contentHash
    }
    if ($fileName -and $fileSize -gt 0) {
        if ($script:fileLookup.Count -ge ($script:MAX_CACHE_SIZE * 2)) {
            $script:fileLookup.Clear()
        }
        $script:fileLookup.Add("$fileName|$fileSize") | Out-Null
    }
}

function Test-IsDuplicateUpload([string]$filePath) {
    if ($script:history.Contains($filePath)) {
        $fiCheck = New-Object System.IO.FileInfo($filePath)
        if ($fiCheck.Exists) {
            if ($script:pathSize.ContainsKey($filePath) -and $script:pathSize[$filePath] -gt 0) {
                if ($script:pathSize[$filePath] -ne $fiCheck.Length) {
                    $null = $script:history.Remove($filePath)
                    $null = $script:pathSize.Remove($filePath)
                    $null = $script:pathHash.Remove($filePath)
                    return $false
                }
            }
            if ($script:pathHash.ContainsKey($filePath) -and -not [string]::IsNullOrEmpty($script:pathHash[$filePath])) {
                $curHash = Get-FileHashSafe $filePath
                if ($curHash -and $curHash -ne $script:pathHash[$filePath]) {
                    $null = $script:history.Remove($filePath)
                    $null = $script:pathSize.Remove($filePath)
                    $null = $script:pathHash.Remove($filePath)
                    return $false
                }
            }
        }
        return $true
    }

    $fi = New-Object System.IO.FileInfo($filePath)
    if (-not $fi.Exists) { return $false }
    $name = $fi.Name
    $len = $fi.Length

    $exactDb = Invoke-SqliteQuery -DataSource $script:DB `
        -Query "SELECT file_size, content_hash FROM uploads WHERE path = @p LIMIT 1" `
        -SqlParameters @{ p = $filePath } -ErrorAction SilentlyContinue

    if ($exactDb) {
        $prevSize = if ($exactDb.file_size) { [long]$exactDb.file_size } else { 0 }
        $prevHash = if ($exactDb.content_hash) { [string]$exactDb.content_hash } else { "" }

        if ($prevSize -gt 0 -and $len -gt 0 -and $prevSize -ne $len) {
            return $false
        }
        if ($prevHash) {
            $curHash = Get-FileHashSafe $filePath
            if ($curHash -and $curHash -ne $prevHash) {
                return $false
            }
        }
        Add-ToCache -path $filePath -fileSize $len -contentHash $prevHash -fileName $name
        return $true
    }

    $lookupKey = "$name|$len"
    $mightBeDuplicate = $script:fileLookup.Contains($lookupKey)
    if (-not $mightBeDuplicate) {
        $dbNameCheck = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT 1 FROM uploads WHERE file_name = @fn AND file_size = @fs AND file_size > 0 LIMIT 1" `
            -SqlParameters @{ fn = $name; fs = $len } -ErrorAction SilentlyContinue
        if ($dbNameCheck) {
            $mightBeDuplicate = $true
        }
    }

    if (-not $mightBeDuplicate) {
        return $false
    }

    $candidateHash = Get-FileHashSafe $filePath
    $existing = Invoke-SqliteQuery -DataSource $script:DB `
        -Query "SELECT content_hash FROM uploads WHERE file_name = @fn AND file_size = @fs AND file_size > 0 LIMIT 1" `
        -SqlParameters @{ fn = $name; fs = $len } -ErrorAction SilentlyContinue

    if ($existing -and $existing.content_hash) {
        if ($existing.content_hash -eq $candidateHash) {
            Add-ToCache -path $filePath -fileSize $len -contentHash $candidateHash -fileName $name
            return $true
        }
    } elseif ($existing) {
        Add-ToCache -path $filePath -fileSize $len -contentHash $candidateHash -fileName $name
        return $true
    }

    return $false
}

$passed = 0
$failed = 0

function Assert-Condition([string]$testName, [bool]$condition) {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $testName" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # Test 1: Add 100 items with MAX_CACHE_SIZE = 50
    $dummyFiles = @()
    for ($i = 1; $i -le 100; $i++) {
        $filePath = Join-Path $tempDir "file_$i.jpg"
        [System.IO.File]::WriteAllBytes($filePath, [byte[]](,65 * 100))
        $hash = Get-FileHashSafe $filePath
        $dummyFiles += $filePath

        # Save to database
        Invoke-SqliteQuery -DataSource $testDb `
            -Query "INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES (@p, @k, @fn, @fs, @h)" `
            -SqlParameters @{ p = $filePath; k = "KEY_$i"; fn = "file_$i.jpg"; fs = 100; h = $hash }

        Add-ToCache -path $filePath -fileSize 100 -contentHash $hash -fileName "file_$i.jpg"
    }

    # Test 1: Cache count is capped at MAX_CACHE_SIZE
    Assert-Condition "In-memory cache history does not exceed MAX_CACHE_SIZE (Count: $($script:history.Count))" ($script:history.Count -eq $script:MAX_CACHE_SIZE)
    Assert-Condition "Cache queue length matches MAX_CACHE_SIZE (Count: $($script:cacheQueue.Count))" ($script:cacheQueue.Count -eq $script:MAX_CACHE_SIZE)

    # Test 2: Early items (e.g. file_1.jpg) were evicted from in-memory cache
    $evictedFile = $dummyFiles[0] # file_1.jpg
    Assert-Condition "Oldest item (file_1.jpg) is evicted from in-memory history" (-not $script:history.Contains($evictedFile))

    # Test 3: Recent item (file_100.jpg) remains in in-memory cache
    $recentFile = $dummyFiles[99] # file_100.jpg
    Assert-Condition "Most recent item (file_100.jpg) is present in in-memory history" ($script:history.Contains($recentFile))

    # Test 4: Querying evicted item falls back to SQLite and returns true
    $isDup = Test-IsDuplicateUpload $evictedFile
    Assert-Condition "Evicted item recognized as duplicate via indexed SQLite query" ($isDup -eq $true)

    # Test 5: Evicted item was repopulated into in-memory cache
    Assert-Condition "Queried evicted item repopulated into in-memory cache" ($script:history.Contains($evictedFile))
    Assert-Condition "Cache size still bounded at MAX_CACHE_SIZE after repopulation" ($script:history.Count -le $script:MAX_CACHE_SIZE)

    # Test 6: In-place modification of evicted item detected
    # Evict file_2.jpg by filling cache
    $evictedFile2 = $dummyFiles[1] # file_2.jpg
    # Modify file_2.jpg size on disk
    [System.IO.File]::WriteAllBytes($evictedFile2, [byte[]](,66 * 200))
    $isDupMod = Test-IsDuplicateUpload $evictedFile2
    Assert-Condition "Modified evicted file returns false (NOT duplicate) on SQLite size check" ($isDupMod -eq $false)

    # Test 7: Cross-platform deduplication with cache miss
    $crossDir = Join-Path $tempDir "CrossPlatform"
    New-Item -ItemType Directory -Path $crossDir -Force | Out-Null
    $crossFile = Join-Path $crossDir "file_50.jpg" # Identical name and content as file_50.jpg
    [System.IO.File]::WriteAllBytes($crossFile, [byte[]](,65 * 100))
    $script:fileLookup.Clear() # Simulate total cache eviction of fileLookup
    $isCrossDup = Test-IsDuplicateUpload $crossFile
    Assert-Condition "Cross-platform duplicate detected via SQLite index even with empty fileLookup" ($isCrossDup -eq $true)

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  RESULTS: $passed Passed, $failed Failed"                     -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
    Write-Host "==========================================================" -ForegroundColor Cyan

    if ($failed -gt 0) { exit 1 }
    exit 0
} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
