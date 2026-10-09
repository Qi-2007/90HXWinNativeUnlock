[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Zig,
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $root '.build\core-rebuild-sources'
$out=Join-Path $root 'build\core-rebuild'
New-Item -ItemType Directory -Path $work,$out -Force | Out-Null
function Fetch-Pinned([string]$Name,[string]$Url,[string]$Commit) {
    $path=Join-Path $work $Name
    if (!(Test-Path -LiteralPath $path)) {
        & git init $path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        & git -C $path remote add origin $Url
        if ($LASTEXITCODE -ne 0) { throw 'git remote failed' }
    }
    & git -C $path cat-file -e "$Commit`^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        & git -C $path fetch --depth 1 $Url $Commit
        if ($LASTEXITCODE -ne 0) { throw "Cannot fetch $Url at $Commit" }
    }
    & git -C $path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw 'Pinned checkout failed' }
    $dirty=@(& git -C $path status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw "Source checkout is modified: $path" }
    return $path
}
$wild=Fetch-Pinned 'wildflash' 'https://github.com/WildFlash1st/cmp90hx-unlock-for-windows.git' 'c033b6d90f44b5381ee561197986345f6e20191a'
$efi=Fetch-Pinned 'gnu-efi' 'https://github.com/ncroxon/gnu-efi.git' '3cf072ace613e4459a0308b06309f4072cf4aa36'
$object=Join-Path $out 'wildflash-unlock-v3n.o'
$log=Join-Path $out 'compile.log'
# Compile stage only, with all upstream unlock_v3n flags. This does NOT
# link firmware blobs or gnu-efi, produce a bootable EFI, or port the ABI.
$compilerArgs=@('cc','-target','x86_64-linux-gnu','-c','-fno-stack-protector',
    '-fpic','-fshort-wchar','-mno-red-zone','-O2',
    '-I',(Join-Path $efi 'inc'),'-I',(Join-Path $efi 'inc\x86_64'),
    '-DEFI_FUNCTION_WRAPPER','-DRELEASE_BUILD','-DMULTI_CARD',
    '-DPCIE_GEN2_REJOIN','-DFULL_NOGEN2','-o',$object,
    (Join-Path $wild 'src\unlock_v2.c'))
$messages=& $Zig @compilerArgs 2>&1
$compileExit=$LASTEXITCODE
$messages | Out-File -LiteralPath $log -Encoding utf8
if ($compileExit -ne 0) { throw "Compilation failed. See $log" }
$version=& $Zig version
@{WildFlashCommit='c033b6d90f44b5381ee561197986345f6e20191a';
  GnuEfiCommit='3cf072ace613e4459a0308b06309f4072cf4aa36';
  ZigVersion="$version"; CompilerArguments=$compilerArgs;
  ObjectSha256=(Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash;
  Stage='compile-only; not a Windows replacement core'} |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'build-manifest.json') -Encoding utf8
& $Python (Join-Path $PSScriptRoot 'inspect-core-compatibility.py') `
    (Join-Path $root 'vendor\nvpermissive-dist-469dc0c\obj\nvpermissive-core.o') `
    $object --out (Join-Path $out 'compatibility.json')
if ($LASTEXITCODE -ne 0) { throw 'Static compatibility inspection failed' }
Write-Host "Compiled research object: $object"
Write-Host 'Not a Windows replacement core. Review compatibility.json before any further porting.'
