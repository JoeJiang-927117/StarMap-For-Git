$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$m) { Write-Output ("=== " + $m + " ===") }

# Prefer user-local SDK from dotnet-install.ps1
$localDotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
if (Test-Path (Join-Path $localDotnet 'dotnet.exe')) {
  $env:Path = $localDotnet + ';' + $env:Path
}
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'dotnet not found' }
Write-Output ("DOTNET=" + $dotnet.Source)
& dotnet --list-sdks | ForEach-Object { Write-Output ("SDK=" + $_) }

$root = Join-Path $env:USERPROFILE 'starmap-msix-build'
$srcZip = Join-Path (Get-Location).Path 'starmap-host-src.zip'
if (-not (Test-Path $srcZip)) {
  $srcZip = Join-Path $env:USERPROFILE 'starmap-host-src.zip'
}
if (-not (Test-Path $srcZip)) { throw "Missing starmap-host-src.zip (looked in PWD and HOME)" }

Write-Step "Prepare workspace"
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
New-Item -ItemType Directory -Path $root | Out-Null
Expand-Archive -Path $srcZip -DestinationPath $root -Force

$projDir = Join-Path $root 'host\StarMapHost'
$proj = Join-Path $projDir 'StarMapHost.csproj'
if (-not (Test-Path $proj)) { throw "Project missing: $proj" }

Write-Step "Restore + Publish"
$publishDir = Join-Path $root 'publish'
& dotnet restore $proj
if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed: $LASTEXITCODE" }
& dotnet publish $proj -c Release -r win-x64 --self-contained false -o $publishDir /p:DebugType=None /p:DebugSymbols=false
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed: $LASTEXITCODE" }

$exe = Join-Path $publishDir 'StarMapHost.exe'
if (-not (Test-Path $exe)) { throw "Publish missing StarMapHost.exe" }
$www = Join-Path $publishDir 'www\index.html'
if (-not (Test-Path $www)) { throw "Publish missing www/index.html" }
Write-Output ("PUBLISH_EXE=" + $exe)
Write-Output ("WWW_BYTES=" + (Get-Item $www).Length)

Write-Step "Acquire MakeAppx/SignTool (NuGet SDK BuildTools)"
$toolsDir = Join-Path $root 'tools'
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
$nupkg = Join-Path $toolsDir 'Microsoft.Windows.SDK.BuildTools.nupkg'
$nugetUrl = 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/10.0.26100.1742/microsoft.windows.sdk.buildtools.10.0.26100.1742.nupkg'
if (-not (Test-Path $nupkg)) {
  Write-Output "Downloading SDK BuildTools NuGet..."
  Invoke-WebRequest -Uri $nugetUrl -OutFile $nupkg -UseBasicParsing
}
$extract = Join-Path $toolsDir 'sdkbuildtools'
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
New-Item -ItemType Directory -Path $extract | Out-Null
# nupkg is zip
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extract)

$makeAppx = Get-ChildItem -Path $extract -Recurse -Filter 'MakeAppx.exe' -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '\\x64\\' } |
  Select-Object -First 1 -ExpandProperty FullName
$signTool = Get-ChildItem -Path $extract -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '\\x64\\' } |
  Select-Object -First 1 -ExpandProperty FullName

if (-not $makeAppx) {
  $makeAppx = Get-ChildItem -Path $extract -Recurse -Filter 'MakeAppx.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $signTool) {
  $signTool = Get-ChildItem -Path $extract -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
Write-Output ("MAKEAPPX=" + $makeAppx)
Write-Output ("SIGNTOOL=" + $signTool)
if (-not $makeAppx) { throw 'MakeAppx.exe not found in SDK BuildTools' }
if (-not $signTool) { throw 'signtool.exe not found in SDK BuildTools' }

Write-Step "Assemble package layout"
$layout = Join-Path $root 'layout'
New-Item -ItemType Directory -Path $layout | Out-Null
# Copy publish output into layout root
Copy-Item -Path (Join-Path $publishDir '*') -Destination $layout -Recurse -Force
# Manifest + Assets for MSIX visual elements
$manifestSrc = Join-Path $root 'msix\AppxManifest.xml'
Copy-Item $manifestSrc (Join-Path $layout 'AppxManifest.xml') -Force
$assetsLayout = Join-Path $layout 'Assets'
New-Item -ItemType Directory -Path $assetsLayout -Force | Out-Null
Copy-Item (Join-Path $projDir 'Assets\*.png') $assetsLayout -Force
# Ensure StoreLogo etc present
Get-ChildItem $assetsLayout | ForEach-Object { Write-Output ("ASSET=" + $_.Name) }

Write-Step "MakeAppx pack"
$msixUnsigned = Join-Path $root 'StarMap-For-git-unsigned.msix'
if (Test-Path $msixUnsigned) { Remove-Item -Force $msixUnsigned }
& $makeAppx pack /d $layout /p $msixUnsigned /o
if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed: $LASTEXITCODE" }
Write-Output ("MSIX_UNSIGNED=" + $msixUnsigned + " SIZE=" + (Get-Item $msixUnsigned).Length)

Write-Step "Self-sign certificate"
$certFriendly = 'StarMap-For-git Sideload'
$subject = 'CN=StarMap-For-git'
# Remove prior certs with same subject to keep store clean-ish
Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.Subject -eq $subject } |
  ForEach-Object {
    Write-Output ("REMOVE_OLD_CERT=" + $_.Thumbprint)
    Remove-Item $_.PSPath -Force
  }
$cert = New-SelfSignedCertificate `
  -Type Custom `
  -Subject $subject `
  -KeyUsage DigitalSignature `
  -FriendlyName $certFriendly `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}') `
  -NotAfter (Get-Date).AddYears(5)
Write-Output ("CERT_THUMB=" + $cert.Thumbprint)

$pfx = Join-Path $root 'StarMap-For-git.pfx'
$cer = Join-Path $root 'StarMap-For-git.cer'
$pwdText = 'StarMapSideload!'
$secure = ConvertTo-SecureString -String $pwdText -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

# Trust for current user so Add-AppxPackage accepts it
$trusted = Get-ChildItem Cert:\CurrentUser\TrustedPeople -ErrorAction SilentlyContinue |
  Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
if (-not $trusted) {
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople','CurrentUser')
  $store.Open('ReadWrite')
  $store.Add($cert)
  $store.Close()
  Write-Output 'CERT_TRUSTED=TrustedPeople'
}

Write-Step "Sign MSIX"
$msixSigned = Join-Path $root 'StarMap-For-git.msix'
Copy-Item $msixUnsigned $msixSigned -Force
& $signTool sign /fd SHA256 /a /f $pfx /p $pwdText /tr http://timestamp.digicert.com /td SHA256 $msixSigned
if ($LASTEXITCODE -ne 0) {
  Write-Output 'Timestamp failed; signing without timestamp...'
  & $signTool sign /fd SHA256 /a /f $pfx /p $pwdText $msixSigned
  if ($LASTEXITCODE -ne 0) { throw "signtool failed: $LASTEXITCODE" }
}
Write-Output ("MSIX_SIGNED=" + $msixSigned + " SIZE=" + (Get-Item $msixSigned).Length)

Write-Step "Copy to Desktop"
$desktop = [Environment]::GetFolderPath('Desktop')
$destMsix = Join-Path $desktop 'StarMap-For-git.msix'
$destCer = Join-Path $desktop 'StarMap-For-git.cer'
Copy-Item $msixSigned $destMsix -Force
Copy-Item $cer $destCer -Force
Write-Output ("DESKTOP_MSIX=" + $destMsix)
Write-Output ("DESKTOP_CER=" + $destCer)

# Also keep a copy under build root for CopyToBox
$outDir = Join-Path $env:USERPROFILE 'starmap-msix-out'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Copy-Item $msixSigned (Join-Path $outDir 'StarMap-For-git.msix') -Force
Copy-Item $cer (Join-Path $outDir 'StarMap-For-git.cer') -Force
Copy-Item $pfx (Join-Path $outDir 'StarMap-For-git.pfx') -Force
Write-Output ("OUT_DIR=" + $outDir)

Write-Step "DONE"
Write-Output "INSTALL_CMD=Add-AppxPackage -Path `"$destMsix`""
Write-Output "PASS_BUILD=1"
