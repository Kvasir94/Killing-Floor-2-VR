# Official NVIDIA SDK; review third_party/NVIDIA-DLSS-LICENSE.txt before use.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $repo 'third_party/ngx'
$pins = Get-Content (Join-Path $PSScriptRoot 'ngx-pins.json') -Raw | ConvertFrom-Json
if (-not (Test-Path (Join-Path $dest '.git'))) {
    git clone --depth 1 --branch $pins.version --filter=blob:none --sparse https://github.com/NVIDIA/DLSS.git $dest
    if ($LASTEXITCODE -ne 0) { throw 'Official NGX clone failed' }
    git -C $dest sparse-checkout set --no-cone /LICENSE.txt /README.md /include/ /lib/Windows_x86_64/x64/nvsdk_ngx_s.lib /lib/Windows_x86_64/rel/nvngx_dlss.dll
    if ($LASTEXITCODE -ne 0) { throw 'NGX sparse checkout failed' }
}
if ((git -C $dest rev-parse HEAD).Trim() -ne $pins.commit) { throw 'NGX commit differs from pin' }
foreach ($entry in $pins.files_sha256.PSObject.Properties) {
    if ((Get-FileHash (Join-Path $dest $entry.Name)).Hash -ne $entry.Value) { throw "NGX input differs: $($entry.Name)" }
}
Write-Output "Verified NGX $($pins.version): headers, library, runtime and license"
