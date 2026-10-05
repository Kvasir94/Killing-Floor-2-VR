<# Offline source contracts for the hand inventory lifecycle: the supported
   weapon boundary, and the sold/dropped/destroyed recovery path in
   VRHandInventory. This reads UnrealScript text only. It does not compile the
   SDK, launch KF2, SteamVR or a headset, and it is not gameplay acceptance.

   extract/kf2_classes.json (a local, gitignored dump of the installed
   Development/Src class tree) is used when present to prove the boundary
   against the real class hierarchy. Those checks are reported as skipped
   rather than passing when the dump is absent. #>
[CmdletBinding()]
param([string]$ClassDump)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $ClassDump) { $ClassDump = Join-Path $project 'extract/kf2_classes.json' }

function Read-Source([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    return [regex]::Replace($text, '(?s)/\*.*?\*/|(?m)//[^\r\n]*', '')
}
function Assert-True([bool]$Value, [string]$Reason) {
    if (-not $Value) { throw $Reason }
}
function Get-Block([string]$Source, [string]$Declaration) {
    $match = [regex]::Match($Source, $Declaration)
    if (-not $match.Success) { throw "Missing source declaration: $Declaration" }
    $start = $Source.IndexOf('{', $match.Index + $match.Length)
    if ($start -lt 0) { throw "Missing block: $Declaration" }
    $depth = 1
    for ($i = $start + 1; $i -lt $Source.Length; ++$i) {
        if ($Source[$i] -eq '{') { ++$depth }
        elseif ($Source[$i] -eq '}') {
            --$depth
            if ($depth -eq 0) { return $Source.Substring($start + 1, $i - $start - 1) }
        }
    }
    throw "Unclosed block: $Declaration"
}

$bridgePath = Join-Path $project 'script/KF2VR/Classes/VRHandsBridge.uc'
$inventoryPath = Join-Path $project 'script/KF2VR/Classes/VRHandInventory.uc'
$registryPath = Join-Path $project 'script/KF2VR/Classes/VRHeldInventory.uc'
$bridge = Read-Source $bridgePath
$inventory = Read-Source $inventoryPath
$registry = Read-Source $registryPath

# Comments are stripped above, so the profile and alias tables are read from the
# raw file. Both live in defaultproperties as one line per entry.
$bridgeRaw = [IO.File]::ReadAllText($bridgePath)
$profileClasses = @([regex]::Matches($bridgeRaw, '(?m)^\s*WeaponProfiles\(\d+\)=\(WeaponClassName=([A-Za-z0-9_]+)') |
    ForEach-Object { $_.Groups[1].Value })
$aliases = @([regex]::Matches($bridgeRaw,
    '(?m)^\s*AuditedSubclasses\(\d+\)=\(SubclassName=([A-Za-z0-9_]+),ProfileClassName=([A-Za-z0-9_]+)\)') |
    ForEach-Object { [pscustomobject]@{ Subclass = $_.Groups[1].Value; Profile = $_.Groups[2].Value } })

$assertions = 0
$skipped = @()
function Check([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:assertions++
}

# ---- The supported-weapon boundary -------------------------------------------

Check 'profile_lookup_is_exact_class_not_isa' {
    $find = Get-Block $bridge '\bsimulated\s+function\s+int\s+FindWeaponProfile\s*\(\s*KFWeapon\s+W\s*\)'
    Assert-True ($find -notmatch '\bIsA\s*\(') 'FindWeaponProfile must not accept a weapon through IsA; a subclass would inherit an unaudited grip.'
    Assert-True ($find -match 'W\.Class\.Name') 'FindWeaponProfile must resolve a profile from the exact class name.'
    Assert-True ($find -match 'AuditedSubclasses') 'FindWeaponProfile must consult the audited subclass table for anything that is not an exact match.'
    $byName = Get-Block $bridge '\bsimulated\s+function\s+int\s+FindProfileByClassName\s*\(\s*name\s+ClassName\s*\)'
    Assert-True ($byName -match 'WeaponProfiles\[I\]\.WeaponClassName\s*==\s*ClassName') 'The name lookup must compare profile class names for equality.'
    Assert-True ($byName -notmatch '\bIsA\s*\(') 'The name lookup must not reintroduce IsA.'
}

Check 'profile_table_is_the_only_isa_free_boundary_user' {
    # Every place that decides "is this weapon one we support" must route through
    # the single boundary, including the armory cycling in SelectNextItem.
    $cycle = Get-Block $bridge '\bsimulated\s+function\s+SelectNextItem\s*\(\s*\)'
    Assert-True ($cycle -notmatch 'IsA\(WeaponProfiles') 'Armory cycling must not match inventory against profile names with IsA.'
    Assert-True ($cycle -match 'FindWeaponProfile\(KFWeapon\(Item\)\)\s*==\s*NextProfile') 'Armory cycling must use the shared exact boundary.'
    $supported = Get-Block $bridge '\bsimulated\s+function\s+bool\s+Supported\s*\(\s*KFWeapon\s+W\s*\)'
    Assert-True ($supported -match 'FindWeaponProfile\(W\)\s*>=\s*0') 'Supported must remain a thin view of the profile boundary.'
}

Check 'profile_table_is_well_formed' {
    Assert-True ($profileClasses.Count -ge 20) "Expected the authored profile table; found $($profileClasses.Count) entries."
    $duplicates = @($profileClasses | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-True ($duplicates.Count -eq 0) "Duplicate profile class names would make the exact lookup order-dependent: $($duplicates -join ', ')"
}

Check 'audited_subclasses_resolve_to_a_real_profile' {
    foreach ($alias in $aliases) {
        Assert-True ($profileClasses -contains $alias.Profile) "Audited subclass $($alias.Subclass) names profile $($alias.Profile), which is not in the profile table."
        Assert-True ($profileClasses -notcontains $alias.Subclass) "$($alias.Subclass) has its own profile; it must not also be listed as an alias."
    }
    $duplicates = @($aliases | Group-Object Subclass | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-True ($duplicates.Count -eq 0) "A subclass may be audited onto one profile only: $($duplicates -join ', ')"
}

Check 'paired_member_classes_keep_their_parent_profile' {
    # The pair conversion path registers project subclasses of stock pistols.
    # Exact-class matching would strand them, so each one must be audited onto
    # the profile of the class it actually extends.
    $members = @(Get-ChildItem -LiteralPath (Join-Path $project 'script/KF2VR/Classes') -Filter 'VRWeap_Paired*.uc')
    Assert-True ($members.Count -gt 0) 'Expected the paired member weapon classes to exist.'
    foreach ($member in $members) {
        $text = [IO.File]::ReadAllText($member.FullName)
        $declaration = [regex]::Match($text, '(?m)^\s*class\s+([A-Za-z0-9_]+)\s+extends\s+([A-Za-z0-9_]+)\s*;')
        Assert-True $declaration.Success "Could not read the class declaration of $($member.Name)."
        $name = $declaration.Groups[1].Value
        $parent = $declaration.Groups[2].Value
        $alias = @($aliases | Where-Object { $_.Subclass -eq $name })
        Assert-True ($alias.Count -eq 1) "$name is a project subclass of a profiled weapon and must be audited onto its parent's profile."
        Assert-True ($alias[0].Profile -eq $parent) "$name extends $parent but is audited onto $($alias[0].Profile)."
        Assert-True ($profileClasses -contains $parent) "$name extends $parent, which no longer has a profile."
        # An audited alias asserts the rig is unchanged. Overriding first person
        # content would invalidate the parent's authored grip and sockets.
        Assert-True ($text -notmatch 'FirstPersonMeshName|FirstPersonAnimSetNames|MySkelMesh\s*=') "$name overrides first person content; re-audit its grip before keeping the alias."
    }
}

# ---- Sold, dropped and destroyed items ---------------------------------------

$update = Get-Block $inventory '\bfunction\s+Update\s*\(\s*float\s+DeltaTime\s*\)'

Check 'revocation_clears_a_captured_transfer' {
    Assert-True ($update -match '(?s)if\s*\(R\s*==\s*None\s*\|\|\s*R\.IsCurrent\(\)\)\s*continue;.{0,400}?if\s*\(TransferItem\s*==\s*R\)\s*CancelTransfer\(\);.{0,200}?Registry\.Revoke\(R\)') 'Losing an item mid-transfer must clear the captured proposal before the runtime is revoked; otherwise both hands stay pending and stop publishing a pose.'
}

Check 'revocation_drops_the_destroyed_presenter_and_attachment' {
    Assert-True ($update -match 'R\.Presenter\.Abandon\(\);\s*R\.Presenter\.Destroy\(\);\s*R\.Presenter\s*=\s*None;') 'A revoked runtime must not keep a reference to a destroyed presenter.'
    Assert-True ($update -match 'R\.EffectsAttachment\.Destroy\(\);\s*R\.EffectsAttachment\s*=\s*None;') 'A revoked runtime must not keep a reference to a destroyed effects attachment.'
    Assert-True ($update -match 'Registry\.Items\.Remove\(I,\s*1\)') 'A revoked runtime must leave the registry.'
}

Check 'stale_selection_and_quick_swap_history_are_cleared' {
    Assert-True ($update -match 'Selected\[I\]\s*!=\s*None\s*&&\s*!Registry\.IsOwned\(Selected\[I\]\)') 'A selection naming an unowned weapon must be cleared and advanced.'
    Assert-True ($update -match 'PreviousItem\[I\]\s*!=\s*None\s*&&\s*!Registry\.IsOwned\(PreviousItem\[I\]\)\s*\)\s*PreviousItem\[I\]\s*=\s*None;') 'Quick swap history naming a sold, dropped or destroyed weapon must be cleared, or that hand refuses every quick swap from then on.'
}

Check 'quick_swap_still_verifies_ownership_at_use' {
    # Clearing history is the recovery; it does not replace the check at use.
    $input = Read-Source (Join-Path $project 'script/KF2VR/Classes/VRDualHandInput.uc')
    $swap = Get-Block $input '\bfunction\s+bool\s+QuickSwapHand\s*\(\s*int\s+Hand\s*\)'
    Assert-True ($swap -match 'Inventory\.PreviousItem\[Hand\]') 'Quick swap must read the exact recorded actor.'
    Assert-True ($swap -match 'Target\s*==\s*None' -and $swap -match 'Inventory\.ReleaseHand\(Hand\)') 'Open hand must be a valid quick-swap target that stows through the normal release path.'
    Assert-True ($swap -match 'CurrentPrimary\.Item\s*==\s*Target') 'A just-redrawn item whose prior target was open must stow rather than refuse its own history.'
    Assert-True ($swap -match '!Inventory\.Registry\.IsOwned\(Target\)' -and $swap -match '!Inventory\.CanDraw\(Target\)') 'Quick swap must still verify ownership and drawability at use.'
}

Check 'a_torn_context_tears_down_instead_of_revoking_everything' {
    $context = Get-Block $inventory '\bfunction\s+bool\s+ContextValid\s*\(\s*\)'
    Assert-True ($context -match 'Registry\.Human\.InvManager\s*!=\s*None') 'Ownership is read from the pawn inventory manager; without it every item would fail the owned test at once and be revoked and destroyed rather than torn down.'
    Assert-True ($update -match '(?s)^\s*.{0,400}?if\s*\(!ContextValid\(\)\)\s*\{\s*Shutdown\(\);\s*return;\s*\}') 'Update must shut down on a torn context before it walks the registry.'
    $owned = Get-Block $registry '\bfunction\s+bool\s+IsOwned\s*\(\s*KFWeapon\s+W\s*\)'
    Assert-True ($owned -match 'Human\.InvManager\s*==\s*None') 'IsOwned must keep rejecting a weapon when there is no inventory manager.'
}

Check 'teardown_releases_the_bridge_hand_references' {
    $shutdown = Get-Block $inventory '\bfunction\s+Shutdown\s*\(\s*\)'
    Assert-True ($shutdown -match 'Bridge\.Hands\[I\]\.Item\s*=\s*None;') 'The bridge outlives this object; teardown must drop its per-hand weapon references on every path, not only the one that rebuilds.'
    Assert-True ($shutdown -match 'Bridge\.Hands\[I\]\.SupportOwner\s*=\s*-1;') 'Teardown must clear stale support ownership.'
    Assert-True ($shutdown -match 'Bridge\.NativeHudSuppressMask\s*=\s*0;') 'Teardown must stop suppressing HUD for a hand that no longer holds anything.'
    Assert-True ($shutdown -match 'Registry\.Shutdown\(\)') 'Teardown must still shut the registry down.'
}

Check 'revocation_is_not_a_revisioned_user_command' {
    $revoke = Get-Block $registry '\bfunction\s+Revoke\s*\(\s*VRWeaponRuntime\s+R\s*\)'
    Assert-True ($revoke -match 'R\.PrimaryHand\s*=\s*-1;' -and $revoke -match 'R\.SupportHand\s*=\s*-1;') 'Revocation must clear both roles of a lost item.'
    Assert-True ($revoke -match 'LeftItem\s*=\s*None' -and $revoke -match 'RightItem\s*=\s*None' -and
        $revoke -match 'LeftSupport\s*=\s*None' -and $revoke -match 'RightSupport\s*=\s*None') 'Revocation must clear every hand slot that named the lost item.'
    Assert-True ($revoke -match 'HandRevision\[0\]' -and $revoke -match 'HandRevision\[1\]') 'Revocation must invalidate the affected hand revisions so delayed commands are rejected.'
    Assert-True ($revoke -notmatch 'ExpectedItemRevision|ExpectedHandRevision') 'Revocation must not require the revisions of an item that has already gone.'
}

# ---- Corroboration against the installed class tree (optional) ---------------

if (-not (Test-Path -LiteralPath $ClassDump)) {
    $skipped += 'boundary_matches_the_installed_class_tree (no extract/kf2_classes.json)'
} else {
    # Windows PowerShell 5.1 rejects this dump through ConvertFrom-Json: stock
    # default property names collide once the parser folds their case. Only the
    # class, its parent and its modifiers are needed, and they are adjacent.
    $dumpText = [IO.File]::ReadAllText($ClassDump)
    $classes = @([regex]::Matches($dumpText,
        '"class":\s*"([A-Za-z0-9_]+)",\s*"parent":\s*(?:"([A-Za-z0-9_]*)"|null),\s*"modifiers":\s*(?:"((?:[^"\\]|\\.)*)"|null)') |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Groups[1].Value
                Parent = $_.Groups[2].Value
                Modifiers = $_.Groups[3].Value
            }
        })
    Assert-True ($classes.Count -gt 1000) "Could not read the installed class tree from $ClassDump; found $($classes.Count) classes."
    $byName = @{}
    foreach ($entry in $classes) { $byName[$entry.Name] = $entry }

    Check 'every_profile_class_is_concrete_so_exact_matching_loses_nothing' {
        foreach ($name in $profileClasses) {
            $entry = $byName[$name]
            Assert-True ($null -ne $entry) "Profile class $name is not in the installed class tree; exact matching would never resolve it."
            Assert-True ($entry.modifiers -notmatch '(?i)\babstract\b') "Profile class $name is abstract; it has no exact instances and the profile would be unreachable."
        }
    }

    Check 'no_stock_subclass_borrows_a_profile_without_an_audit' {
        # These stock variants used to pass IsA into a parent's authored grip.
        # Each ships its own first person rig, so none is audited; this records
        # that and fails if one is added without the mesh check being redone.
        $known = @{
            'KFWeap_Shotgun_HRG_Kaboomstick' = 'KFWeap_Shotgun_DoubleBarrel'
            'KFWeap_HRG_Revolver_Buckshot'   = 'KFWeap_Revolver_SW500'
            'KFWeap_Pistol_Dummy'            = 'KFWeap_Pistol_9mm'
        }
        $audited = @($aliases | ForEach-Object { $_.Subclass })
        foreach ($entry in $classes) {
            if ($profileClasses -notcontains $entry.Parent) { continue }
            if ($audited -contains $entry.Name) { continue }
            Assert-True ($known.ContainsKey($entry.Name)) "$($entry.Name) extends the profiled $($entry.Parent) and is neither audited nor a recorded exclusion; confirm its grip bones, sockets and idle animation, then add it to AuditedSubclasses or to this list."
            Assert-True ($known[$entry.Name] -eq $entry.Parent) "$($entry.Name) no longer extends $($known[$entry.Name])."
        }
        foreach ($name in $known.Keys) {
            Assert-True ($audited -notcontains $name) "$name is recorded as unaudited but appears in AuditedSubclasses; remove it from one list or the other."
        }
    }
}

$message = "PASS $assertions inventory lifecycle source assertions"
if ($skipped.Count -gt 0) { $message += "; SKIPPED $($skipped.Count): $($skipped -join ', ')" }
Write-Output ($message + '; gameplay acceptance remains separate.')
