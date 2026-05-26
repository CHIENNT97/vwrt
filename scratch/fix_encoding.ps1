$projectDir = "c:\Users\ADMIN\Desktop\WEBUI\vwrt"
$extensions = @("*.html", "*.js", "*.lua", "*.sh", "*.json", "*.css", "99-ntc_wrt-init")

$latin1 = [System.Text.Encoding]::GetEncoding("iso-8859-1")
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Is-Double-Encoded ($text) {
    $hasExtended = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $code = [int]$text[$i]
        if ($code -gt 255) {
            return $false # Contains valid high-unicode chars, not double-encoded
        }
        if ($code -gt 127) {
            $hasExtended = $true
        }
    }
    return $hasExtended
}

function Fix-File-Encoding ($filePath) {
    try {
        $text = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)
        
        if (Is-Double-Encoded $text) {
            Write-Host "Fixing double-encoding: $filePath"
            $bytes = $latin1.GetBytes($text)
            $fixedText = $utf8.GetString($bytes)
            [System.IO.File]::WriteAllText($filePath, $fixedText, $utf8)
        }
    } catch {
        Write-Warning "Failed to process $filePath : $_"
    }
}

Get-ChildItem -Path $projectDir -Recurse -File | ForEach-Object {
    $file = $_
    foreach ($ext in $extensions) {
        if ($file.Name -like $ext -or $file.Extension -eq $ext.Replace("*", "")) {
            if ($file.FullName -notmatch '\\\.git\\' -and $file.FullName -notmatch '\\bin\\') {
                Fix-File-Encoding $file.FullName
                break
            }
        }
    }
}

Write-Host "Encoding Fix Complete!" -ForegroundColor Green
