$ErrorActionPreference = 'Stop'
$src = 'c:\Users\majianwei\Desktop\JiraWinTool_publish\JiraWinTool.exe'
$dst = Join-Path $PSScriptRoot 'JiraWinTool.exe'
Write-Output "Source: $src"
Write-Output "Dest: $dst"
if (Test-Path $src) {
    Copy-Item -Path $src -Destination $dst -Force
    Write-Output 'Copy done'
} else {
    Write-Output 'Source not found'
    Get-ChildItem 'c:\Users\majianwei\Desktop\JiraWinTool_publish\'
}
