<# Bounded native policy/header check only; no KFGame/KFEditor/XR runtime. #>
[CmdletBinding()]
param([string]$OutputRoot = (Join-Path $PSScriptRoot '../../../../build/local-test-policy'))
$ErrorActionPreference = 'Stop'
$compiler = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe' |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $compiler) { throw 'MSVC x64 compiler not found.' }
$vcRoot = [IO.Path]::GetFullPath((Join-Path $compiler.Directory.FullName '../../..'))
$sdk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'um/Windows.h') } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK not found.' }
$sdkRoot = Split-Path (Split-Path $sdk.FullName)
$env:INCLUDE = (@((Join-Path $vcRoot 'include')) + @('ucrt','shared','um','winrt' | ForEach-Object { Join-Path $sdk.FullName $_ })) -join ';'
$env:LIB = @((Join-Path $vcRoot 'lib/x64'), (Join-Path $sdkRoot "Lib/$($sdk.Name)/ucrt/x64"), (Join-Path $sdkRoot "Lib/$($sdk.Name)/um/x64")) -join ';'
$output = [IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$test = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../tests/LocalTestPolicyTest.cpp'))
$exe = Join-Path $output 'LocalTestPolicyTest.exe'
& $compiler.FullName /nologo /EHsc /std:c++20 /W4 /MD /DNOMINMAX /DWIN32_LEAN_AND_MEAN "/Fo$(Join-Path $output 'LocalTestPolicyTest.obj')" "/Fe$exe" $test
if ($LASTEXITCODE -ne 0) { throw 'Native local test policy compilation failed.' }
& $exe
if ($LASTEXITCODE -ne 0) { throw 'Native local test policy checks failed.' }
# Compile the actual transport/bridge headers as a translation unit. This is
# not an adapter build, installation, runtime test, or source-text assertion.
$syntax = Join-Path $output 'BridgeSyntax.cpp'
$bridge = (Join-Path $PSScriptRoot 'Bridge.h').Replace('\','/')
[IO.File]::WriteAllText($syntax, "#include `"$bridge`"`n", [Text.Encoding]::ASCII)
& $compiler.FullName /nologo /EHsc /std:c++20 /W4 /MD /DNOMINMAX /DWIN32_LEAN_AND_MEAN /c "/Fo$(Join-Path $output 'BridgeSyntax.obj')" $syntax
if ($LASTEXITCODE -ne 0) { throw 'Native local test transport/bridge header compilation failed.' }
