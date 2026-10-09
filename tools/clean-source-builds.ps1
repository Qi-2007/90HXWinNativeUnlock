[CmdletBinding(SupportsShouldProcess=$true)]
param()
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$targets=New-Object 'System.Collections.Generic.List[string]'
function Add-Target([string]$relative) {
    $path=Join-Path $root $relative
    if(Test-Path -LiteralPath $path) { $targets.Add($path) }
}
foreach($name in @('dma-driver','dma-driver-v3.1','dma-driver-v4','dma-driver-v5',
    'gui','gui-v3','gui-v3.1','gui-v4','gui-v5','validated-v1','worker','payload-tests')) {
    Add-Target ('build\rebuilt-core\'+$name)
}
foreach($relative in @('build\core-rebuild','build\csharp-obj','build\gui-obj','build\dma-driver-obj',
    'build\dma-driver','.build\rebuilt-driver-workspace','.build\rebuilt-gui',
    '.build\rebuilt-worker','.build\rebuilt-worker-hardware','.build\caller-validation',
    '.build\unified-name-validation-20261006',
    'native\rebuilt-core\README-history-v3.md','native\rebuilt-core\README-history-v4.md')) {
    Add-Target $relative
}
if(Test-Path -LiteralPath (Join-Path $root '.build')) {
    Get-ChildItem -LiteralPath (Join-Path $root '.build') -Directory -Filter 'legacy-build-names-*' |
        ForEach-Object {$targets.Add($_.FullName)}
}
if(Test-Path -LiteralPath (Join-Path $root 'dist')) {
    Get-ChildItem -LiteralPath (Join-Path $root 'dist') -Force |
        Where-Object Name -Like 'CMP90HX-Control-*' | ForEach-Object {$targets.Add($_.FullName)}
}
if(Test-Path -LiteralPath (Join-Path $root 'build')) {
    Get-ChildItem -LiteralPath (Join-Path $root 'build') -File | Where-Object {
        $_.Extension -in @('.log','.obj','.pdb') -or $_.Name -match '^(CMP90HX(Control|Unlocker)\.|.*Tests\.exe$|caller_auth_test\.exe$|hardware_test\.exe$|state_test\.exe$)'
    } | ForEach-Object {$targets.Add($_.FullName)}
}
$out=Join-Path $root 'build\rebuilt-core'
if(Test-Path -LiteralPath $out) {
    Get-ChildItem -LiteralPath $out -File | Where-Object {
        $_.Name -match '^gui(-v(3|3\.1|4|5))?(-manifest\.json|-package-check\.log)$' -or
        $_.Name -in @('firmware-no-original-check.o','manifest-source-only.json') -or
        $_.Extension -eq '.pdb' -or $_.Name -match '^source-.*\.o$' -or
        $_.Name -in @('booter-test-shim.o','reference-469dc0c.o','reference-469dc0c.renames.json',
            'firmware-data.o','HybridGuiWorkflowTests.exe','source-tests.exe','transaction-tests.exe')
    } | ForEach-Object {$targets.Add($_.FullName)}
}
$plan=@();$bytes=0L;$files=0
# Check every resolved absolute target before deletion. Never follow links.
foreach($path in @($targets | Select-Object -Unique)) {
    $resolved=(Resolve-Path -LiteralPath $path).ProviderPath
    if(!$resolved.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) {throw "Outside workspace: $resolved"}
    $entry=Get-Item -LiteralPath $resolved -Force
    if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Linked target: $resolved"}
    if($entry.PSIsContainer) {
        if(@(Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint).Count) {throw "Linked descendant: $resolved"}
        $contents=@(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force)
        $size=($contents | Measure-Object Length -Sum).Sum;$count=$contents.Count
    } else {$size=$entry.Length;$count=1}
    $plan += [pscustomobject]@{Path=$resolved;Files=$count;Bytes=[long]$size;Removed=$false}
    $bytes+=$size;$files+=$count
}
foreach($item in $plan) {
    if($PSCmdlet.ShouldProcess($item.Path,'Delete obsolete output or build cache')) {
        Remove-Item -LiteralPath $item.Path -Recurse -Force
        $item.Removed=$true
    }
}
if(!$WhatIfPreference) {
    New-Item -ItemType Directory -Path (Join-Path $root 'build') -Force | Out-Null
    @{Files=$files;Bytes=$bytes;Targets=$plan} | ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $root 'build\cleanup-report.json') -Encoding utf8
}
Write-Host ('Cleanup: {0} files, {1:N2} MiB; current v5.1 package preserved.' -f $files,($bytes/1MB))
