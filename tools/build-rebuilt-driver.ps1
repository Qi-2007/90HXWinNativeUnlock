[CmdletBinding()]
param([string]$MSBuild,[string]$SdkVersion,[switch]$Iommu,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BuildCommon.ps1')
$root=Get-BuildRoot
$worker=Join-Path $root 'build\rebuilt-core\worker-hardware\CMP90HXUnlocker.exe'
$workerManifest=Join-Path (Split-Path -Parent $worker) 'worker-manifest.json'
if (!(Test-Path $workerManifest)) { throw 'Build the tested worker with build-rebuilt-worker.ps1 -EnableHardwareCommands first' }
$state=Get-Content $workerManifest -Raw | ConvertFrom-Json
$hash=(Get-FileHash $worker -Algorithm SHA256).Hash
if (!$state.HardwareCommandsEnabled -or !$state.TestsPassed -or $state.WorkerHash -ne $hash) { throw 'Hardware worker validation stamp mismatch' }
$core=Join-Path $root 'build\rebuilt-core\nvpermissive-rebuilt-hybrid.o'
if ((Get-FileHash $core).Hash -ne $state.CandidateHash) { throw 'Rebuilt core changed; rebuild and retest worker first' }
$workspace=Join-Path $root '.build\rebuilt-driver-workspace'
$driver=Join-Path $workspace 'driver'
$policy=Join-Path $workspace 'build'
$flavor=if($Iommu) {'iommu-driver'} else {'dma-driver'}
$out=Join-Path $root ('build\rebuilt-core\'+$flavor)
if($OutputDirectory) { $out=[IO.Path]::GetFullPath($OutputDirectory) }
New-Item -ItemType Directory -Path $driver,$policy,$out -Force | Out-Null
# Copy only project inputs. Existing production caller policy and SYS files
# are not written by this isolated research build.
foreach($name in @('include','src')) {
    Copy-Item (Join-Path $root ('driver\'+$name)) -Destination $driver -Recurse -Force
}
foreach($name in @('CMP90HXDma.vcxproj','Resource.rc','resource.h','CMP90HXDmaIommu.inf')) {
    Copy-Item (Join-Path $root ('driver\'+$name)) -Destination $driver -Force
}
[IO.File]::WriteAllText((Join-Path $policy 'caller-policy.h'),(Get-CallerPolicyContent $hash),[Text.Encoding]::ASCII)
$MSBuild=Resolve-BuildMSBuild $MSBuild -Driver
$kitRoot=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
$versions=@(Get-ChildItem (Join-Path $kitRoot 'Include') -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName 'km\ntddk.h')) -and
    (Test-Path (Join-Path $_.FullName 'um\windows.h')) -and
    (Test-Path (Join-Path $kitRoot "Lib\$($_.Name)\km\x64\ntoskrnl.lib"))
} | Sort-Object { [version]$_.Name } -Descending)
if($SdkVersion) {
    if (!($versions | Where-Object Name -EQ $SdkVersion)) { throw 'Specified SDK/WDK is incomplete' }
} elseif($versions.Count) { $SdkVersion=$versions[0].Name }
else { throw 'Matching SDK/WDK is required' }
$log=Join-Path $out 'build.log'
$messages=& $MSBuild (Join-Path $driver 'CMP90HXDma.vcxproj') /t:Rebuild /m /p:Configuration=Release /p:Platform=x64 `
    "/p:WindowsTargetPlatformVersion=$SdkVersion" "/p:IommuBackend=$($Iommu.IsPresent.ToString().ToLowerInvariant())" `
    "/p:OutDir=$out\" "/p:IntDir=$workspace\obj-$flavor\" /verbosity:minimal 2>&1
$exit=$LASTEXITCODE
$messages | Set-Content $log -Encoding utf8
if ($exit -ne 0) { $messages | Out-Host; throw 'Isolated research driver build failed' }
$sys=Join-Path $out $(if($Iommu) {'CMP90HXDmaIommu.sys'} else {'CMP90HXDma.sys'})
Assert-DriverCallerPolicy $sys $hash
Copy-Item $worker $out -Force
Copy-Item ($worker+'.config') $out -Force
Copy-Item $core $out -Force
if($Iommu) { Copy-Item (Join-Path $driver 'CMP90HXDmaIommu.inf') $out -Force }
@{WorkerHash=$hash;CoreHash=(Get-FileHash $core).Hash;DriverHash=(Get-FileHash $sys).Hash;
    Signed=$false;Installed=$false;HardwareExecuted=$false;SdkVersion=$SdkVersion} |
    ConvertTo-Json | Set-Content (Join-Path $out 'package-manifest.json') -Encoding utf8
Write-Host "Unsigned research driver with verified worker whitelist: $sys"
