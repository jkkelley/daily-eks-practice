# Serve PRACTICE_ANSWERS.html on a local static server and open it (Windows 11).
# Usage: powershell -ExecutionPolicy Bypass -File scripts\serve-answers.ps1
#        (or: make serve-answers)
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$file = "PRACTICE_ANSWERS.html"
if (-not (Test-Path (Join-Path $root $file))) {
    Write-Error "$file not found in repo root."
    exit 1
}

$port = if ($env:PORT) { [int]$env:PORT } else { Get-Random -Minimum 8000 -Maximum 8999 }
$url  = "http://127.0.0.1:$port/$file"
Write-Host "Serving the sealed answer key at:  $url"
Write-Host "(Ctrl+C to stop)"
Start-Process $url | Out-Null
Set-Location $root

# Prefer Python's http.server if available; otherwise fall back to a tiny .NET listener.
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }

if ($py) {
    & $py.Source -m http.server $port --bind 127.0.0.1
}
else {
    Write-Host "Python not found - using the built-in PowerShell static server."
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    try {
        while ($listener.IsListening) {
            $ctx  = $listener.GetContext()
            $rel  = $ctx.Request.Url.LocalPath.TrimStart('/')
            if ([string]::IsNullOrEmpty($rel)) { $rel = $file }
            $path = Join-Path $root $rel
            if (Test-Path $path -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($path)
                if ($path -match '\.html?$') { $ctx.Response.ContentType = "text/html; charset=utf-8" }
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $ctx.Response.StatusCode = 404
            }
            $ctx.Response.OutputStream.Close()
        }
    } finally {
        $listener.Stop()
    }
}
