[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repositoryRoot "build\windows-release"
$publishDirectory = Join-Path $buildRoot "app"
$automationDirectory = Join-Path $publishDirectory "Automation"
$distributionDirectory = Join-Path $repositoryRoot "dist"
$toolsDirectory = Join-Path $buildRoot "ffmpeg"

& (Join-Path $PSScriptRoot "generate_windows_icon.ps1") -RepositoryRoot $repositoryRoot | Out-Null
& (Join-Path $PSScriptRoot "acquire_ffmpeg_windows.ps1") -OutputDirectory $toolsDirectory | Out-Null
[IO.Directory]::CreateDirectory($distributionDirectory) | Out-Null

if (-not $SkipTests) {
    dotnet test (Join-Path $repositoryRoot "Windows\tests\Cineleaf.Windows.Core.Tests\Cineleaf.Windows.Core.Tests.csproj") -c $Configuration --nologo
    if ($LASTEXITCODE -ne 0) { throw "Windows unit tests failed." }
    $env:CINELEAF_FFMPEG_DIR = $toolsDirectory
    dotnet test (Join-Path $repositoryRoot "Windows\tests\Cineleaf.Windows.Media.IntegrationTests\Cineleaf.Windows.Media.IntegrationTests.csproj") -c $Configuration --nologo
    if ($LASTEXITCODE -ne 0) { throw "Windows media integration tests failed." }
}

dotnet publish (Join-Path $repositoryRoot "Windows\src\Cineleaf.Windows.App\Cineleaf.Windows.App.csproj") -c $Configuration -r win-x64 --self-contained true -o $publishDirectory --nologo
if ($LASTEXITCODE -ne 0) { throw "Windows publish failed." }
dotnet publish (Join-Path $repositoryRoot "Windows\src\Cineleaf.Windows.Automation\Cineleaf.Windows.Automation.csproj") -c $Configuration -r win-x64 --self-contained true -o $automationDirectory --nologo
if ($LASTEXITCODE -ne 0) { throw "Windows automation bridge publish failed." }
Get-ChildItem -LiteralPath $publishDirectory -Filter "*.pdb" -File -Recurse | Remove-Item -Force
[IO.Directory]::CreateDirectory((Join-Path $automationDirectory "mcp\src")) | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot "Automation\mcp\package.json") -Destination (Join-Path $automationDirectory "mcp") -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot "Automation\mcp\package-lock.json") -Destination (Join-Path $automationDirectory "mcp") -Force
Copy-Item -Path (Join-Path $repositoryRoot "Automation\mcp\src\*") -Destination (Join-Path $automationDirectory "mcp\src") -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\setup_cineleaf_mcp.ps1") -Destination $automationDirectory -Force
[IO.Directory]::CreateDirectory((Join-Path $publishDirectory "Tools")) | Out-Null
Copy-Item -LiteralPath (Join-Path $toolsDirectory "ffmpeg.exe") -Destination (Join-Path $publishDirectory "Tools") -Force
Copy-Item -LiteralPath (Join-Path $toolsDirectory "ffprobe.exe") -Destination (Join-Path $publishDirectory "Tools") -Force
Copy-Item -LiteralPath (Join-Path $toolsDirectory "FFmpeg-LICENSE.txt") -Destination (Join-Path $publishDirectory "Tools") -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot "LICENSE") -Destination (Join-Path $publishDirectory "LICENSE.txt") -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot "THIRD_PARTY_NOTICES.md") -Destination $publishDirectory -Force

$portable = Join-Path $distributionDirectory "Cineleaf-0.2.0-beta.1-Windows-x64-Portable.zip"
if (Test-Path -LiteralPath $portable) { Remove-Item -LiteralPath $portable -Force }
Compress-Archive -Path (Join-Path $publishDirectory "*") -DestinationPath $portable -CompressionLevel Optimal

$isccCandidates = @(
    (Join-Path $repositoryRoot "build\inno-6.7.3\ISCC.exe"),
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($null -eq $iscc) { throw "Inno Setup 6 is required to create the installer. Install it, then rerun this script." }
& $iscc "/DSourceDir=$publishDirectory" "/DOutputDir=$distributionDirectory" (Join-Path $repositoryRoot "Windows\installer\Cineleaf.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed." }

$checksumName = "Cineleaf-0.2.0-beta.1-Windows-SHA256SUMS.txt"
$checksumPath = Join-Path $distributionDirectory $checksumName
$artifacts = Get-ChildItem -LiteralPath $distributionDirectory -File | Where-Object { $_.Name -like "Cineleaf-0.2.0-beta.1-Windows-*" -and $_.Name -ne $checksumName }
$lines = $artifacts | Sort-Object Name | ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
[IO.File]::WriteAllLines($checksumPath, $lines, [Text.UTF8Encoding]::new($false))
Get-ChildItem -LiteralPath $distributionDirectory -File | Where-Object { $_.Name -like "Cineleaf-0.2.0-beta.1-Windows-*" } | Select-Object FullName,Length
