$projectDir = "c:\Users\ADMIN\Desktop\WEBUI\vwrt"
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Safe-Replace-In-File ($filePath) {
    try {
        # Read with explicit UTF-8
        $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)
        
        # Replace namespace strings
        $content = $content -replace 'VWRT_API', 'NTC_WRT_API'
        $content = $content -replace 'vwrt_session', 'ntc_wrt_session'
        $content = $content -replace 'vwrt_user', 'ntc_wrt_user'
        $content = $content -replace 'VWRT', 'NTC_WRT'
        $content = $content -replace 'vwrt', 'ntc_wrt'
        
        # Revert the GitHub Repo URL specifically
        $content = $content -replace 'CHIENNT97/ntc_wrt', 'CHIENNT97/vwrt'
        
        # Write back with explicit UTF-8 (no BOM)
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        Write-Host "Processed: $filePath"
    } catch {
        Write-Warning "Error processing $filePath : $_"
    }
}

# Process all files, filtering out .git and bin, but explicitly including extension-less files
Get-ChildItem -Path $projectDir -Recurse -File | ForEach-Object {
    $file = $_
    $ext = $file.Extension
    $name = $file.Name
    
    # Process only web/code source files
    $shouldProcess = $false
    
    # Check by extension
    if ($ext -in @(".html", ".js", ".lua", ".sh", ".json", ".css")) {
        $shouldProcess = $true
    }
    # Check for extension-less files (common for CGI scripts and uci-defaults)
    elseif ($ext -eq "" -or $ext -eq $null) {
        # Skip directories, binaries, and license files
        if ($name -notmatch '^LICENSE$' -and $name -notmatch '^README$') {
            $shouldProcess = $true
        }
    }
    # Special exact match names
    elseif ($name -eq "99-vwrt-init" -or $name -eq "99-ntc_wrt-init") {
        $shouldProcess = $true
    }
    
    if ($shouldProcess) {
        # Skip git folders and compiler binaries
        if ($file.FullName -notmatch '\\\.git\\' -and $file.FullName -notmatch '\\bin\\') {
            Safe-Replace-In-File $file.FullName
        }
    }
}

Write-Host "Full Refactoring with CGI Scripts Complete!" -ForegroundColor Green
