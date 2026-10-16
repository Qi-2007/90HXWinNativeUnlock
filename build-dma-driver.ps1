[CmdletBinding()]
param([string]$MSBuild,[string]$SdkVersion,[switch]$Clean,[switch]$Iommu)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'tools\BuildCommon.ps1')
& (Join-Path $PSScriptRoot 'build.ps1') -IfNeeded | Out-Host
$callerHash=Write-CallerPolicy
$MSBuild=Resolve-BuildMSBuild $MSBuild -Driver
$kitRoot=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
$versions=@(Get-ChildItem -LiteralPath (Join-Path $kitRoot 'Include') -Directory | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName 'km\ntddk.h')) -and
    (Test-Path -LiteralPath (Join-Path $kitRoot "Lib\$($_.Name)\km\x64\ntoskrnl.lib")) -and
    (Test-Path -LiteralPath (Join-Path $_.FullName 'um\windows.h'))
} | Sort-Object { [version]$_.Name } -Descending)
if ($SdkVersion) {
    if (!($versions | Where-Object Name -EQ $SdkVersion)) { throw "SDK/WDK $SdkVersion is incomplete: require km/ntddk.h, km/x64/ntoskrnl.lib and um/windows.h." }
} elseif ($versions.Count) { $SdkVersion=$versions[0].Name }
else { throw 'No matching SDK/WDK headers and kernel libraries found. Install WDK, not only Windows SDK.' }
Write-Host "MSBuild: $MSBuild"
Write-Host "SDK/WDK: $SdkVersion; Kits root: $kitRoot"
$target=if($Clean) {'/t:Rebuild'} else {'/t:Build'}
& $MSBuild (Join-Path $PSScriptRoot 'driver\CMP90HXUnlockNative.vcxproj') $target /m /p:Configuration=Release /p:Platform=x64 "/p:WindowsTargetPlatformVersion=$SdkVersion" "/p:IommuBackend=$($Iommu.IsPresent.ToString().ToLowerInvariant())" /verbosity:minimal | Out-Host
if ($LASTEXITCODE -ne 0) { throw "WDK driver build failed: $LASTEXITCODE" }
$sys=Join-Path $PSScriptRoot $(if($Iommu) {'build\iommu-driver\CMP90HXDmaIommu.sys'} else {'build\native-driver\CMP90HXUnlockNative.sys'})
if (!(Test-Path -LiteralPath $sys)) { throw 'Build produced no CMP90HXUnlockNative.sys.' }
if ((Assert-Gen2Validated) -ne $callerHash) { throw 'Gen2 changed during driver build; retry.' }
Assert-DriverCallerPolicy $sys $callerHash
$worker=Get-Gen2ProjectOutput
Copy-Item -LiteralPath $worker,($worker+'.config') -Destination (Split-Path -Parent $sys) -Force
if($Iommu) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'driver\CMP90HXDmaIommu.inf') -Destination (Split-Path -Parent $sys) -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\iommu-driver-test.md') -Destination (Join-Path (Split-Path -Parent $sys) 'README.md') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD_PARTY_NOTICES.md') -Destination (Split-Path -Parent $sys) -Force
    $core=Join-Path $PSScriptRoot 'vendor\nvpermissive-dist-469dc0c\obj\nvpermissive-core.o'
    if(Test-Path -LiteralPath $core) { Copy-Item -LiteralPath $core -Destination (Split-Path -Parent $sys) -Force }
    Write-Host 'PnP experimental package staged. Generate/sign its catalog after signing the SYS. Install via the INF, not sc.exe.'
}
Get-FileHash -Algorithm SHA256 $sys
Write-Host 'Unsigned experimental driver built. Sign it before installation. No driver loaded or boot settings changed.'
