[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AllowedRoot,
    [string]$McpInstallRoot
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath($AllowedRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "AllowedRoot must be an existing directory." }
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $scriptRoot
$installedMcp = Join-Path $scriptRoot "mcp"
$repositoryMcp = Join-Path $repositoryRoot "Automation\mcp"
$sourceMcp = if (Test-Path -LiteralPath (Join-Path $installedMcp "package.json")) { $installedMcp } else { $repositoryMcp }
if (-not (Test-Path -LiteralPath (Join-Path $sourceMcp "package.json"))) { throw "Cineleaf MCP files were not found." }
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($null -eq $npm) { throw "Node.js 20 or later is required for MCP. Install Node.js, then run this script again." }
$mcp = if ([string]::IsNullOrWhiteSpace($McpInstallRoot)) { Join-Path $env:LOCALAPPDATA "Cineleaf\Automation\mcp" } else { [IO.Path]::GetFullPath($McpInstallRoot) }
$nativeCli = $env:CINELEAF_AUTOMATION_CLI
if ([string]::IsNullOrWhiteSpace($nativeCli)) {
    $installedCli = Join-Path $scriptRoot "Cineleaf.Automation.exe"
    $repositoryCli = Join-Path $repositoryRoot "Windows\src\Cineleaf.Windows.Automation\bin\Release\net8.0-windows10.0.19041.0\win-x64\Cineleaf.Automation.exe"
    $nativeCli = if (Test-Path -LiteralPath $installedCli) { $installedCli } else { $repositoryCli }
}
$nativeCli = [IO.Path]::GetFullPath($nativeCli)
if (-not (Test-Path -LiteralPath $nativeCli -PathType Leaf)) { throw "The native Cineleaf automation bridge was not found. Build it in Release or set CINELEAF_AUTOMATION_CLI." }
[IO.Directory]::CreateDirectory((Join-Path $mcp "src")) | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceMcp "package.json") -Destination $mcp -Force
Copy-Item -LiteralPath (Join-Path $sourceMcp "package-lock.json") -Destination $mcp -Force
Copy-Item -Path (Join-Path $sourceMcp "src\*") -Destination (Join-Path $mcp "src") -Force
& $npm.Source ci --omit=dev --prefix $mcp
if ($LASTEXITCODE -ne 0) { throw "MCP dependency installation failed." }
$configuration = [ordered]@{
    mcpServers = [ordered]@{
        cineleaf = [ordered]@{
            command = (Get-Command node).Source
            args = @((Join-Path $mcp "src\index.js"), "--root", $root, "--cli", $nativeCli)
        }
    }
}
$output = Join-Path $mcp "cineleaf-mcp-config.json"
[IO.File]::WriteAllText($output, ($configuration | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Output "MCP installed. Copy the cineleaf entry from: $output"
