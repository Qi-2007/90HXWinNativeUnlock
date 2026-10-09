[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Zig,[string]$Python='python',[switch]$SourceOnly)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'build\rebuilt-core'
$source=Join-Path $root 'native\rebuilt-core'
$original=Join-Path $root 'vendor\nvpermissive-dist-469dc0c\obj\nvpermissive-core.o'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$reference=Join-Path $out 'reference-469dc0c.o'
$overlay=Join-Path $out 'source-orchestration.o'
$object=Join-Path $out 'nvpermissive-rebuilt-hybrid.o'
if (!$SourceOnly) {
    & $Python (Join-Path $PSScriptRoot 'rename-core-exports.py') $original $reference
    if ($LASTEXITCODE -ne 0) { throw 'Pinned export rename failed' }
}
$flags=@('cc','-target','x86_64-freestanding-none','-c','-O2','-g0','-ffreestanding',
    '-fno-builtin','-fno-stack-protector','-fno-pic','-fno-pie','-mcmodel=kernel',
    '-mno-red-zone','-fno-asynchronous-unwind-tables','-fno-unwind-tables',
    '-Wall','-Wextra','-Werror','-o',$overlay,(Join-Path $source 'core.c'))
& $Zig @flags
if ($LASTEXITCODE -ne 0) { throw 'Source core compilation failed' }
$transactions=Join-Path $out 'source-transactions.o'
$transactionFlags=$flags.Clone()
$transactionFlags[$transactionFlags.Length-2]=$transactions
$transactionFlags[$transactionFlags.Length-1]=Join-Path $source 'transactions.c'
& $Zig @transactionFlags
if ($LASTEXITCODE -ne 0) { throw 'Source transactions compilation failed' }
$primitives=Join-Path $out 'source-primitives.o'
$primitiveFlags=$flags.Clone()
$primitiveFlags[$primitiveFlags.Length-2]=$primitives
$primitiveFlags[$primitiveFlags.Length-1]=Join-Path $source 'primitives.c'
& $Zig @primitiveFlags
if ($LASTEXITCODE -ne 0) { throw 'Source primitives compilation failed' }
$vbios=Join-Path $out 'source-vbios.o'
$vbiosFlags=$flags.Clone()
$vbiosFlags[$vbiosFlags.Length-2]=$vbios
$vbiosFlags[$vbiosFlags.Length-1]=Join-Path $source 'vbios.c'
& $Zig @vbiosFlags
if ($LASTEXITCODE -ne 0) { throw 'Source VBIOS compilation failed' }
$falcon=Join-Path $out 'source-falcon.o'
$falconFlags=$flags.Clone()
$falconFlags[$falconFlags.Length-2]=$falcon
$falconFlags[$falconFlags.Length-1]=Join-Path $source 'falcon.c'
& $Zig @falconFlags
if ($LASTEXITCODE -ne 0) { throw 'Source Falcon compilation failed' }
$power=Join-Path $out 'source-power.o'
$powerFlags=$flags.Clone()
$powerFlags[$powerFlags.Length-2]=$power
$powerFlags[$powerFlags.Length-1]=Join-Path $source 'power.c'
& $Zig @powerFlags
if ($LASTEXITCODE -ne 0) { throw 'Source power compilation failed' }
$pmu=Join-Path $out 'source-pmu.o'
$pmuFlags=$flags.Clone()
$pmuFlags[$pmuFlags.Length-2]=$pmu
$pmuFlags[$pmuFlags.Length-1]=Join-Path $source 'pmu.c'
& $Zig @pmuFlags
if ($LASTEXITCODE -ne 0) { throw 'Source PMU compilation failed' }
$booter=Join-Path $out 'source-booter.o'
$booterFlags=$flags.Clone()
$booterFlags[$booterFlags.Length-2]=$booter
$booterFlags[$booterFlags.Length-1]=Join-Path $source 'booter.c'
& $Zig @booterFlags
if ($LASTEXITCODE -ne 0) { throw 'Source booter compilation failed' }
& $Python (Join-Path $PSScriptRoot 'verify-source-boundary.py') $overlay $transactions $primitives $vbios $falcon $power $pmu $booter --out (Join-Path $out 'source-boundary.json')
if ($LASTEXITCODE -ne 0) { throw 'Source primitive boundary check failed' }
$firmware=Join-Path $out 'firmware-data.o'
& $Python (Join-Path $PSScriptRoot 'build-core-firmware.py') --original $original --assets (Join-Path $source 'firmware') --out $firmware
if ($LASTEXITCODE -ne 0) { throw 'Pinned firmware data build failed' }
$sourceObjects=@($overlay,$transactions,$primitives,$vbios,$falcon,$power,$pmu,$booter)
& $Zig cc -target x86_64-linux-gnu -nostdlib -r @sourceObjects $firmware -o $object
if ($LASTEXITCODE -ne 0) { throw 'Source-only relocatable link failed' }
$research=Join-Path $out 'nvpermissive-rebuilt-reference-test.o'
if (!$SourceOnly) {
    $shim=Join-Path $out 'booter-test-shim.o'
    $shimFlags=$flags.Clone();$shimFlags[$shimFlags.Length-2]=$shim
    $shimFlags[$shimFlags.Length-1]=Join-Path $source 'booter-test-shim.c'
    & $Zig @shimFlags
    if ($LASTEXITCODE -ne 0) { throw 'Research shim compilation failed' }
    & $Zig cc -target x86_64-linux-gnu -nostdlib -r @sourceObjects $shim $reference -o $research
    if ($LASTEXITCODE -ne 0) { throw 'Research comparison object link failed' }
}
& $Python (Join-Path $PSScriptRoot 'inspect-core-compatibility.py') $object --out (Join-Path $out 'compatibility.json')
if ($LASTEXITCODE -ne 0) { throw 'Static inspection failed' }
$report=Get-Content (Join-Path $out 'compatibility.json') -Raw | ConvertFrom-Json
$candidate=$report[0]
if ($candidate.missing_required_exports.Count -or $candidate.unsupported_imports.Count -or
    $candidate.unsupported_relocations.Count -or $candidate.relocation_sections_targeting_unallocated_sections.Count) {
    throw 'Hybrid object is structurally incompatible with the ELF loader'
}
if (@($candidate.imports | Where-Object {$_ -notin @('ioread32','iowrite32','memset','memcpy')}).Count -or
    @($candidate.exports | Where-Object {$_ -like 'reference_*' -or $_ -like 'backend_*'}).Count) {
    throw 'Production core includes an original executable backend dependency'
}
$test=Join-Path $out 'source-tests.exe'
& $Zig cc -target x86_64-windows-gnu -O2 -Wall -Wextra -Werror `
    (Join-Path $source 'core.c') (Join-Path $source 'test-core.c') -o $test
if ($LASTEXITCODE -ne 0) { throw 'Source state-machine tests failed to compile' }
$testOutput=& $test 2>&1
$testExit=$LASTEXITCODE
$testOutput | Set-Content (Join-Path $out 'source-tests.log') -Encoding utf8
if ($testExit -ne 0) { $testOutput | Out-Host; throw 'Source state-machine tests failed' }
$testOutput | Out-Host
$transactionTest=Join-Path $out 'transaction-tests.exe'
& $Zig cc -target x86_64-windows-gnu -O2 -Wall -Wextra -Werror `
    (Join-Path $source 'transactions.c') (Join-Path $source 'test-transactions.c') -o $transactionTest
if ($LASTEXITCODE -ne 0) { throw 'Transaction tests did not compile' }
$transactionOutput=& $transactionTest 2>&1
$transactionExit=$LASTEXITCODE
$transactionOutput | Set-Content (Join-Path $out 'transaction-tests.log') -Encoding utf8
if ($transactionExit -ne 0) { $transactionOutput | Out-Host; throw 'Source transaction tests failed' }
$transactionOutput | Out-Host
if (!$SourceOnly) {
    & $Python (Join-Path $PSScriptRoot 'verify-plm-payload.py') --core $original --exe $transactionTest --out (Join-Path $out 'payload-tests')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned payload comparison failed' }
}
$sourceHashes=@{}
foreach($name in @('core.c','core.h','transactions.c','primitives.c','vbios.c','falcon.c','power.c','pmu.c','booter.c')) {
    $sourceHashes[$name]=(Get-FileHash (Join-Path $source $name)).Hash
}
@{Kind='ga102-source-v5';Version='5.1';OriginalHash='b533b7b245ed606c151ca336b9a6bacebe935e3ec478246e879c668a4dd98a6a';
    CandidateHash=(Get-FileHash $object).Hash;ZigVersion="$(& $Zig version)";
    SourceHash=(Get-FileHash (Join-Path $source 'core.c')).Hash;
    HeaderHash=(Get-FileHash (Join-Path $source 'core.h')).Hash;
    TransactionsHash=(Get-FileHash (Join-Path $source 'transactions.c')).Hash;
    SourceHashes=$sourceHashes;FirmwareBackend='six pinned GPU firmware data assets; no original host machine code';
    ResearchHash=$(if(!$SourceOnly){(Get-FileHash $research).Hash}else{$null});
    FirmwareManifestHash=(Get-FileHash (Join-Path $source 'firmware/manifest.json')).Hash;
    HardwareValidated=$false;CompilerArguments=$flags} | ConvertTo-Json -Depth 4 |
    Set-Content (Join-Path $out $(if($SourceOnly){'manifest-source-only.json'}else{'manifest.json'})) -Encoding utf8
Write-Host "Source core built: $object"
Write-Host 'Production core has source-only host logic and pinned GPU firmware data.'
