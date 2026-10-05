# Exercise INI section ownership without loading any launch-time code.
$ErrorActionPreference='Stop'
$launcher=Join-Path $PSScriptRoot '../test-portal.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Portal launcher syntax failed.' }
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-PortalIniValues'},$false)
. ([ScriptBlock]::Create($definition.Extent.Text))

function Assert-KeySection([string]$Text,[string]$Key,[string]$ExpectedSection,[string]$ExpectedValue) {
    $section=''; $found=0
    foreach ($line in $Text -split '\r?\n') {
        $trimmed=$line.Trim()
        if ($trimmed -match '^\[([^\]]+)\]') { $section=$Matches[1]; continue }
        if ($trimmed.StartsWith($Key+'=')) {
            ++$found
            if ($section -ne $ExpectedSection -or $trimmed -ne ($Key+'='+$ExpectedValue)) {
                throw "INI key $Key escaped [$ExpectedSection]: $section / $trimmed"
            }
        }
    }
    if ($found -ne 1) { throw "Expected one $Key, got $found" }
}

$inputText="[Previous]`r`nKeep=previous`r`n`r`n`r`n [Core.System]`r`nPaths=old`r`nRetain=yes`r`n`r`n[Next]`r`nAfter=next`r`n"
$output=Set-PortalIniValues $inputText 'Core.System' ([ordered]@{Paths='new';ScriptPaths='scripts'})
Assert-KeySection $output 'Paths' 'Core.System' 'new'
Assert-KeySection $output 'ScriptPaths' 'Core.System' 'scripts'
Assert-KeySection $output 'Keep' 'Previous' 'previous'
Assert-KeySection $output 'Retain' 'Core.System' 'yes'
Assert-KeySection $output 'After' 'Next' 'next'
$output=Set-PortalIniValues "[Previous]`nKeep=previous`n`n[Core.System]" 'Core.System' ([ordered]@{Paths='eof'})
Assert-KeySection $output 'Paths' 'Core.System' 'eof'
$output=Set-PortalIniValues '[Previous]' 'KF2VR.VRHandsBridge' ([ordered]@{bPresentationProbe='False'}) -AddMissing
Assert-KeySection $output 'bPresentationProbe' 'KF2VR.VRHandsBridge' 'False'
$output=Set-PortalIniValues "[KF2VR.VRHandsBridge]`r`nbPresentationProbe=False`r`n" 'KF2VR.VRDemo' ([ordered]@{bRenderDiagnostic='True'}) -AddMissing
Assert-KeySection $output 'bRenderDiagnostic' 'KF2VR.VRDemo' 'True'
Assert-KeySection $output 'bPresentationProbe' 'KF2VR.VRHandsBridge' 'False'
$output=Set-PortalIniValues $output 'KF2VR.VRDemo' ([ordered]@{bRenderDiagnostic='False'}) -AddMissing
Assert-KeySection $output 'bRenderDiagnostic' 'KF2VR.VRDemo' 'False'
# The section is only effective when the class uses the category selected by
# the launcher's -GAMEINI override. config(KFGame) silently selects another
# category even though the physical stock filename is KFGame.ini.
$demoSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../script/KF2VR/Classes/VRDemo.uc') -Raw
if ($demoSource -notmatch '(?m)^class\s+VRDemo\s+extends\s+KFMutator\s+config\(Game\);') {
    throw 'Render diagnostic class must consume the Game category selected by -GAMEINI.'
}
if ($demoSource -notmatch '(?m)^\s*var\s+config\s+bool\s+bRenderDiagnostic;' -or
    $demoSource -match '(?im)^\s*bRenderDiagnostic=True\s*$') {
    throw 'Render diagnostic must remain an opt-in config property with a disabled default.'
}
Write-Output 'Portal INI: 12 focused section/category ownership checks passed.'
