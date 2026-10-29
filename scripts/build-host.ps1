# Build StarMapHost (WebView2) for Windows x64
$ErrorActionPreference = 'Stop'
$proj = Join-Path $PSScriptRoot '..\host\StarMapHost\StarMapHost.csproj'
if (-not (Test-Path $proj)) { throw "Missing $proj" }
dotnet restore $proj
dotnet publish $proj -c Release -r win-x64 --self-contained false -o (Join-Path $PSScriptRoot '..\dist\host')
Write-Host "Published to dist\host\StarMapHost.exe"
