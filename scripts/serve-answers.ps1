# Serve PRACTICE_ANSWERS.html on a local static server and open it (Windows 11).
#   powershell -ExecutionPolicy Bypass -File scripts\serve-answers.ps1        # whole key
#   powershell -ExecutionPolicy Bypass -File scripts\serve-answers.ps1 02     # ONLY scenario 02
#   (or: make serve-answers  /  make serve-answers N=02)
# Scoping to one scenario keeps you from seeing answers to drills you haven't done yet.
param([string]$N = "")
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$file = "PRACTICE_ANSWERS.html"
$src  = Join-Path $root $file
if (-not (Test-Path $src)) {
    Write-Error "$file not found in repo root."
    exit 1
}

# Optional scenario number. Empty => serve the full key (back-compat).
if ($N) {
    $pad = "{0:D2}" -f [int]$N   # normalise 2 -> 02 to match the repo's numbering
    $content = Get-Content -Raw $src
    $first = $content.IndexOf("<details>")
    $last  = $content.LastIndexOf("</details>")
    $header = $content.Substring(0, $first)
    $footer = $content.Substring($last + "</details>".Length)
    $body   = $content.Substring($first, $last + "</details>".Length - $first)

    $block = [regex]::Matches($body, '(?s)<details>.*?</details>') |
             Where-Object { $_.Value -match "<h2[^>]*>$pad - " } |
             Select-Object -First 1
    if (-not $block) {
        Write-Error "no scenario '$pad' in $file (scenarios are 01-12)."
        exit 1
    }

    $scopedDir = Join-Path ([System.IO.Path]::GetTempPath()) ("answers-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $scopedDir | Out-Null
    Set-Content -Path (Join-Path $scopedDir $file) -Value ($header + $block.Value + "`n" + $footer) -NoNewline
    $root = $scopedDir
    Write-Host "Scoped to scenario $pad only (other answers are not served)."
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
