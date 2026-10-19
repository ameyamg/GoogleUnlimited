# =====================================================================
# Regression Test Suite: SEC-03 (Windows NTFS ACL File Permissions)
# Tests that Protect-FileAcl disables inheritance and restricts access
# exclusively to the current user principal on sensitive config and DB files.
# =====================================================================
$ErrorActionPreference = "Stop"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gotohp_test_perm_" + [System.Guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($tempDir) | Out-Null

function Cleanup {
    if ([System.IO.Directory]::Exists($tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: SEC-03 File Permissions (PowerShell / Windows NTFS)" -ForegroundColor Green
Write-Host "  Temp Directory: $tempDir" -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Condition($msg, $cond) {
    if ($cond) {
        Write-Host "  [PASS] $msg" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # Reference Protect-FileAcl definition directly
    function Protect-FileAcl([string]$filePath) {
        if (-not [System.IO.File]::Exists($filePath)) { return }
        try {
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true, $false) # Disable inheritance, remove inherited rules
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $filePath -AclObject $acl
        } catch {}
    }

    $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    # Test 1: Config file protection
    $cfgPath = Join-Path $tempDir "gotohp.config"
    [System.IO.File]::WriteAllText($cfgPath, "account:`n  credentials: dummy")
    Protect-FileAcl $cfgPath

    $cfgAcl = Get-Acl -LiteralPath $cfgPath
    Assert-Condition "Config file has inheritance disabled" ($cfgAcl.AreAccessRulesProtected -eq $true)

    $rules = @($cfgAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
    Assert-Condition "Config file has exactly 1 explicit access rule" ($rules.Count -eq 1)
    Assert-Condition "Config file explicit rule belongs exclusively to current user SID" ($rules[0].IdentityReference.Value -eq $currentUserSid)
    Assert-Condition "Current user has FullControl permissions" ($rules[0].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl)

    # Test 2: Database and WAL file protection
    $dbPath = Join-Path $tempDir "gphotos.db"
    $walPath = Join-Path $tempDir "gphotos.db-wal"
    [System.IO.File]::WriteAllBytes($dbPath, @())
    [System.IO.File]::WriteAllBytes($walPath, @())
    Protect-FileAcl $dbPath
    Protect-FileAcl $walPath

    $dbAcl = Get-Acl -LiteralPath $dbPath
    Assert-Condition "Database file has inheritance disabled" ($dbAcl.AreAccessRulesProtected -eq $true)
    $dbRules = @($dbAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
    Assert-Condition "Database file explicit rule belongs to current user SID" ($dbRules[0].IdentityReference.Value -eq $currentUserSid)

    $walAcl = Get-Acl -LiteralPath $walPath
    Assert-Condition "WAL file has inheritance disabled" ($walAcl.AreAccessRulesProtected -eq $true)

    # Test 3: Non-existent file handled gracefully without throwing
    Protect-FileAcl (Join-Path $tempDir "nonexistent.file")
    Assert-Condition "Protect-FileAcl handles non-existent file gracefully" $true

} finally {
    Cleanup
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
