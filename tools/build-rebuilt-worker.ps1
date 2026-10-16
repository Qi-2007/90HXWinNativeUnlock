[CmdletBinding()]
param([string]$MSBuild,[switch]$EnableHardwareCommands)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BuildCommon.ps1')
$root=Get-BuildRoot
$candidate=Join-Path $root 'build\rebuilt-core\nvpermissive-rebuilt-hybrid.o'
if (!(Test-Path -LiteralPath $candidate)) { throw 'Run build-rebuilt-core.ps1 first' }
$hash=(Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=Get-Content (Join-Path $root 'build\rebuilt-core\manifest.json') -Raw | ConvertFrom-Json
if ($manifest.CandidateHash.ToLowerInvariant() -ne $hash) { throw 'Candidate manifest hash mismatch' }
$research=Join-Path $root 'build/rebuilt-core/nvpermissive-rebuilt-reference-test.o'
$researchHash=(Get-FileHash $research).Hash.ToLowerInvariant()
if($manifest.ResearchHash.ToLowerInvariant() -ne $researchHash) {throw 'Research reference manifest mismatch'}
$flavor=if($EnableHardwareCommands) {'worker-hardware'} else {'worker'}
$temp=Join-Path $root ('.build\rebuilt-'+$flavor+'\src')
$out=Join-Path $root ('build\rebuilt-core\'+$flavor)
New-Item -ItemType Directory -Path $temp,$out -Force | Out-Null
Copy-Item -Path (Join-Path $root 'src\*') -Destination $temp -Recurse -Force
$native=Join-Path $temp 'NativeCore.cs'
$text=[IO.File]::ReadAllText($native)
$old='if(actual!=Hash && actual!=ManagedHash)'
if (!$text.Contains($old) -or !$text.Contains('return actual==ManagedHash;')) { throw 'NativeCore pinning layout changed; review required' }
$text=$text.Replace($old,'if(actual!=Hash && actual!=ManagedHash && actual!="'+$hash+'" && actual!="'+$researchHash+'")')
$text=$text.Replace('return actual==ManagedHash;','return actual==ManagedHash || actual=="'+$hash+'" || actual=="'+$researchHash+'";')
# Test-only helper entry points, restricted to known original/candidate names.
$helperEntries=@'
                foreach(string helper in new string[]{"nvperm_boot_inputs_prepare","nvperm_boot_inputs_release","nvperm_boot_inputs_metadata_legacy_for_fb_size","nvperm_boot_inputs_metadata_legacy","nvperm_session_check_identity","elf_find_signature","ga102_read_local_memory_size","sec2_is_accessible","rebuilt_inputs_prepare","rebuilt_inputs_release","rebuilt_inputs_metadata","rebuilt_inputs_metadata_feature","rebuilt_session_identity","rebuilt_find_signature","rebuilt_local_memory_size","rebuilt_sec2_accessible","vbios_extract_fwsec","fwsec_ucode_free","rebuilt_vbios_fwsec","rebuilt_fwsec_free","nvperm_fwsec_execute_frts_managed","nvperm_gsp_falcon_reset_managed","rebuilt_fwsec_execute","rebuilt_reset_managed","nvperm_gr_power_enable","nvperm_media_fuse_probe","rebuilt_gr_power","rebuilt_media_probe","pmu_devinit_execute","rebuilt_pmu_devinit","vbios_extract_vde","rebuilt_vbios_vde","rebuilt_booter_test","reference_booter_test"}) {
                    int index=Array.FindIndex(names,delegate(Symbol s){return s.Name==helper && s.Section!=0;});
                    if(index>=0) exports[helper]=Abi.Forward(resolved[index]);
                }
'@
$flushMarker='if (!CoreNative.FlushInstructionCache(CoreNative.GetCurrentProcess(),image,new UIntPtr(cursor)))'
if(!$text.Contains($flushMarker)) {throw 'Research helper export location changed'}
$text=$text.Replace($flushMarker,$helperEntries+[Environment]::NewLine+'                '+$flushMarker)
[IO.File]::WriteAllText($native,$text,(New-Object Text.UTF8Encoding($false)))
# Default research worker accepts only offline commands. A separate opt-in
# hardware-capable build keeps the existing FullUnlockEngine workflow intact.
$program=Join-Path $temp 'Program.cs'
$text=[IO.File]::ReadAllText($program)
$marker='if (options.ContainsKey("log"))'
if (!$text.Contains($marker)) { throw 'Program command gate layout changed; review required' }
if (!$EnableHardwareCommands) {
    $text=$text.Replace($marker,'if(command!="self-test" && command!="core-test" && command!="rebuilt-test" && command!="quadro-test") throw new IOException("Rebuilt research worker permits offline tests only.");'+[Environment]::NewLine+'                '+$marker)
}
$fullUnlock=Join-Path $temp 'FullUnlock.cs'
$flow=[IO.File]::ReadAllText($fullUnlock)
$flow=$flow.Replace('"469dc0c managed-handoff"','"GA102 source v5.1 managed-handoff (check core hash)"')
[IO.File]::WriteAllText($fullUnlock,$flow,(New-Object Text.UTF8Encoding($false)))
$text=$text.Replace('if (command == "self-test")','if (command == "rebuilt-test") return RebuiltCoreTests.Run(options["reference"], options["core"]);'+[Environment]::NewLine+'                if (command == "quadro-test") return RebuiltCoreTests.RunQuadro(options["core"]);'+[Environment]::NewLine+'                if (command == "self-test")')
[IO.File]::WriteAllText($program,$text,(New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $root 'native\rebuilt-core\RebuiltCoreTests.cs') (Join-Path $temp 'RebuiltCoreTests.cs') -Force
$MSBuild=Resolve-BuildMSBuild $MSBuild
Assert-BuildFramework
& $MSBuild (Join-Path $temp 'CMP90HXUnlockProgram.csproj') /t:Rebuild /m /p:Configuration=Release /p:Platform=x64 "/p:OutputPath=$out\" "/p:IntermediateOutputPath=$temp\obj\" /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw 'Research worker build failed' }
$exe=Join-Path $out 'CMP90HXUnlocker.exe'
$original=Join-Path $root 'vendor\nvpermissive-dist-469dc0c\obj\nvpermissive-core.o'
foreach ($command in @('self-test','core-test','quadro-test','rebuilt-test')) {
    $arguments=@($command)
    if($command -eq 'core-test' -or $command -eq 'quadro-test') { $arguments+=@('--core',$candidate) }
    elseif($command -eq 'rebuilt-test') { $arguments+=@('--reference',$original,'--core',$research) }
    $output=& $exe @arguments 2>&1
    $exit=$LASTEXITCODE
    $output | Set-Content (Join-Path $out ($command+'.log')) -Encoding utf8
    if ($exit -ne 0) { $output | Out-Host; throw "$command failed" }
    $output | Select-Object -Last 2 | Out-Host
}
@{CandidateHash=$hash;WorkerHash=(Get-FileHash $exe).Hash;
    HardwareCommandsEnabled=[bool]$EnableHardwareCommands;TestsPassed=$true;
    DriverCallerWhitelistUpdated=$false;HardwareExecuted=$false} |
    ConvertTo-Json | Set-Content (Join-Path $out 'worker-manifest.json') -Encoding utf8
Write-Host "Pinned research worker: $exe (hardware commands enabled: $EnableHardwareCommands)"
