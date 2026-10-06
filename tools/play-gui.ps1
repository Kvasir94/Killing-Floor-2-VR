<# Graphical selection window for the main launcher.

The console menu in tools/multiplayer/launch_menu.py stays the reference
implementation of what these choices mean; this window presents the same ones
on three pages and returns them to tools/play-main.ps1, which passes them on as
ordinary command line arguments. Nothing is launched from here.

Artwork is the player's own installed Killing Floor 2, read at run time and
never copied into this repository or a release package: the shipped Wallpaper
folder, the official logo from the local Steam library cache, and the HUD's
scanlined plate and blood splash from extract/hud-art when a previous asset
inspection left them there. Every one of those is optional; the window draws
its own equivalents when a file is missing.

Keep this file ASCII: Windows PowerShell reads a script without a byte order
mark as ANSI, which turns anything else into mojibake in the live window.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$ServerRoot,
    [Parameter(Mandatory)][AllowEmptyString()][string]$GameRoot,
    [string]$Release,
    [switch]$Stale,
    [switch]$TestMap,
    [switch]$Solo,
    [hashtable]$InitialSelections = @{}
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-Problem {
    param([string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'KF2-VR launcher',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
}

# The package's own copy is what friends.py will run with. Fall back to the
# checkout only for a package built before this file existed.
$python = Join-Path $Package 'runtime/python.exe'
$state = Join-Path $Package 'tools/multiplayer/launch_state.py'
if (-not (Test-Path -LiteralPath $state -PathType Leaf)) {
    $state = Join-Path $Repo 'tools/multiplayer/launch_state.py'
}
try {
    $json = & $python $state --game-root $GameRoot --server-root $ServerRoot --package-root $Package 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($json -join [Environment]::NewLine) }
    $s = ($json -join "`n") | ConvertFrom-Json
} catch {
    Show-Problem "Could not read the saved launcher selections.`r`n`r`n$_"
    return
}
if (-not $s.game_root) {
    Show-Problem 'Killing Floor 2 was not found. Install it through Steam, start it once so it writes its configuration, then run this launcher again.'
    return
}
# Explicit command-line choices seed the window; untouched fields retain the
# package's resolved profile. The returned choices then replace these inputs.
if ($InitialSelections.Vr) { $s.vr = $true }
if ($InitialSelections.Desktop) { $s.vr = $false }
foreach ($entry in @(@('Map','map'), @('Difficulty','difficulty'), @('GameLength','game_length'), @('VrQuality','vr_quality'))) {
    if ($InitialSelections.ContainsKey($entry[0])) {
        $s.($entry[1]) = if ($entry[0] -eq 'Map') { [string]$InitialSelections[$entry[0]] } else { ([string]$InitialSelections[$entry[0]]).ToLowerInvariant() }
    }
}
foreach ($entry in @(@('InventoryFocus','inventory_focus'), @('MultiplayerGrabs','multiplayer_grabs'), @('DamagePopups','damage_popups'), @('PortalGun','portal_gun'), @('Breacher','breacher'), @('ThreadedRender','threaded_render'))) {
    if ($InitialSelections.ContainsKey($entry[0])) { $s.($entry[1]) = $InitialSelections[$entry[0]] -eq 'On' }
}
if ($InitialSelections.ContainsKey('TestMapPlayers')) { $s.test_map_players = [int]$InitialSelections.TestMapPlayers }
if ($InitialSelections.ContainsKey('Mods')) {
    # Resolve the same catalog/dependencies as the packaged launcher.
    $modJson = & $python -c 'import json,sys; from workshop_loadout import parse_mods; print(json.dumps(parse_mods(sys.argv[1])))' ([string]$InitialSelections.Mods) 2>&1
    if ($LASTEXITCODE -ne 0) { Show-Problem ($modJson -join [Environment]::NewLine); return }
    $s.mods = @((($modJson -join "`n") | ConvertFrom-Json))
    $s.vr_mods = $s.mods
}

# --- Palette and type --------------------------------------------------
# The game's own menu language: a near-black scanlined plate, a hairline of
# blood red around it, and condensed uppercase headings.
function Rgb { param($r, $g, $b) [System.Drawing.Color]::FromArgb([int]$r, [int]$g, [int]$b) }
$ink = Rgb 12 12 14
$plate = Rgb 22 22 26
$plateUp = Rgb 32 32 38
$edge = Rgb 62 62 70
$fg = Rgb 230 230 234
$dim = Rgb 142 142 152
$mute = Rgb 92 92 102
$red = Rgb 176 27 31
$redHot = Rgb 226 58 46
$redDeep = Rgb 66 17 19
$amber = Rgb 216 158 60
$white = [System.Drawing.Color]::White

$families = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
$display = @('Bahnschrift SemiBold Condensed', 'Bahnschrift Condensed', 'Agency FB', 'Segoe UI Semibold') |
    Where-Object { $families -contains $_ } | Select-Object -First 1
if (-not $display) { $display = 'Segoe UI' }
$fontBody = New-Object System.Drawing.Font('Segoe UI', 10)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fontLabel = New-Object System.Drawing.Font($display, 11)
$fontTab = New-Object System.Drawing.Font($display, 12)
$fontCard = New-Object System.Drawing.Font($display, 15)
$fontAction = New-Object System.Drawing.Font($display, 13)
$fontWord = New-Object System.Drawing.Font($display, 36)
$fontTag = New-Object System.Drawing.Font($display, 15)

$titles = @{
    normal = 'Normal'; hard = 'Hard'; suicidal = 'Suicidal'; hellonearth = 'Hell on Earth'
    short = 'Short  -  4 waves, then the boss'; medium = 'Medium  -  7 waves, then the boss'
    long = 'Long  -  10 waves, then the boss'
    quality = 'Quality  -  full detail'; balanced = 'Balanced'; performance = 'Performance  -  highest frame rate'
}
function Get-Label {
    param($Key)
    if ($titles.ContainsKey([string]$Key)) { $titles[[string]$Key] } else { [string]$Key }
}
function New-Control {
    param($Type, $X, $Y, $W, $H, $Text)
    $c = New-Object $Type
    $c.Location = New-Object System.Drawing.Point([int]$X, [int]$Y)
    $c.Size = New-Object System.Drawing.Size([int]$W, [int]$H)
    if ($PSBoundParameters.ContainsKey('Text')) { $c.Text = [string]$Text }
    $c
}
function New-Caption {
    param($Parent, $X, $Y, $W, $H, $Text, $Font, $Color, $Align = 'MiddleLeft')
    $label = New-Control System.Windows.Forms.Label $X $Y $W $H $Text
    $label.Font = $Font
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = $Align
    $Parent.Controls.Add($label)
    $label
}

# --- Installed artwork -------------------------------------------------
function Open-Image {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try { return [System.Drawing.Image]::FromFile($Path) } catch { }
    }
    $null
}
$wallpaper = $null
foreach ($name in @('KF2-Wallpaper1920x1080.jpg', 'KF2-Wallpaper1680x1050.jpg', 'KF2-Wallpaper1600x1200.jpg', 'KF2-Wallpaper1280x720.jpg')) {
    $wallpaper = Open-Image (Join-Path ([string]$s.game_root) (Join-Path 'Wallpaper' $name))
    if ($wallpaper) { break }
}
$logo = $null
try {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
    $cache = Join-Path $steam 'appcache/librarycache/232090'
    $logo = Open-Image (Join-Path $cache 'logo.png')
    if (-not $logo) {
        $any = Get-ChildItem -LiteralPath $cache -Filter '*.png' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($any) { $logo = Open-Image $any.FullName }
    }
} catch { }
$splash = Open-Image (Join-Path $Repo 'extract/hud-art/InGameHUD_SWF_I7E.png')
$scanplate = Open-Image (Join-Path $Repo 'extract/hud-art/UI_Obj_Background_Short.png')
# The HUD's plate is a dark field of fine horizontal lines. Reproduce it once
# as a brush so fields and buttons carry the same texture whether or not the
# installed texture happened to be on disk.
$texture = New-Object System.Drawing.Bitmap 4, 4
for ($ty = 0; $ty -lt 4; $ty++) {
    for ($tx = 0; $tx -lt 4; $tx++) {
        $texture.SetPixel($tx, $ty, $(if ($ty % 2) { [System.Drawing.Color]::FromArgb(26, 255, 255, 255) } else { [System.Drawing.Color]::FromArgb(0, 0, 0, 0) }))
    }
}
$scanBrush = New-Object System.Drawing.TextureBrush $texture
$scanBrush.WrapMode = [System.Drawing.Drawing2D.WrapMode]::Tile

function Get-RoundedPath {
    param($Rect, $Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [int]$Radius * 2
    if ($d -le 0) { $path.AddRectangle($Rect); return $path }
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc(($Rect.Right - $d - 1), $Rect.Y, $d, $d, 270, 90)
    $path.AddArc(($Rect.Right - $d - 1), ($Rect.Bottom - $d - 1), $d, $d, 0, 90)
    $path.AddArc($Rect.X, ($Rect.Bottom - $d - 1), $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}
function Draw-Plate {
    param($Graphics, $Rect, $Radius, $Fill, $Border, [switch]$Scanlines)
    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = Get-RoundedPath $Rect $Radius
    $brush = New-Object System.Drawing.SolidBrush $Fill
    $Graphics.FillPath($brush, $path)
    if ($Scanlines) {
        $clip = $Graphics.Clip
        $Graphics.SetClip($path)
        $Graphics.FillRectangle($scanBrush, $Rect)
        $Graphics.Clip = $clip
    }
    $pen = New-Object System.Drawing.Pen $Border, 1
    $Graphics.DrawPath($pen, $path)
    $brush.Dispose(); $pen.Dispose(); $path.Dispose()
}

# --- Frame -------------------------------------------------------------
$W = 1180
$H = 744
$rail = 420
$bar = 48
$x0 = 460
$cw = $W - $x0 - 40

$form = New-Object System.Windows.Forms.Form
$form.Text = 'KF2-VR'
$form.Font = $fontBody
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size($W, $H)
$form.BackColor = $ink
$form.KeyPreview = $true
$outline = Get-RoundedPath (New-Object System.Drawing.Rectangle 0, 0, $W, $H) 10
$form.Region = New-Object System.Drawing.Region $outline

$titleBar = New-Control System.Windows.Forms.Panel 0 0 $W $bar
$titleBar.BackColor = $plate
# The header carries the HUD's own framed plate when the installed texture is
# on disk, which is where the rest of the window's scanlines come from.
$titleBar.Tag = @{ Plate = $scanplate }
$titleBar.Add_Paint({
    param($sender, $e)
    if ($sender.Tag.Plate) {
        $e.Graphics.DrawImage($sender.Tag.Plate, (New-Object System.Drawing.Rectangle 0, 0, $sender.Width, $sender.Height))
    }
})
$form.Controls.Add($titleBar)
$titleText = New-Caption $titleBar 24 0 500 $bar 'KILLING FLOOR 2   //   VIRTUAL REALITY' $fontTab $dim
$close = New-Control System.Windows.Forms.Panel ($W - $bar - 8) 6 $bar ($bar - 12)
$close.BackColor = [System.Drawing.Color]::Transparent
$close.Add_Paint({
    param($sender, $e)
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen = New-Object System.Drawing.Pen $sender.ForeColor, 1.6
    $mx = [int]($sender.Width / 2); $my = [int]($sender.Height / 2)
    $e.Graphics.DrawLine($pen, ($mx - 6), ($my - 6), ($mx + 6), ($my + 6))
    $e.Graphics.DrawLine($pen, ($mx + 6), ($my - 6), ($mx - 6), ($my + 6))
    $pen.Dispose()
})
$close.ForeColor = $dim
$close.Add_MouseEnter({ param($sender, $e) $sender.BackColor = $red; $sender.ForeColor = $white; $sender.Invalidate() })
$close.Add_MouseLeave({ param($sender, $e) $sender.BackColor = [System.Drawing.Color]::Transparent; $sender.ForeColor = $dim; $sender.Invalidate() })
$close.Add_Click({ $form.Close() })
$titleBar.Controls.Add($close)

# A borderless window still has to be movable.
$script:dragging = $false
$startDrag = {
    $script:dragging = $true
    $script:dragFrom = [System.Windows.Forms.Cursor]::Position
    $script:dragOrigin = $form.Location
}
$moveDrag = {
    if ($script:dragging) {
        $now = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(
            ($script:dragOrigin.X + $now.X - $script:dragFrom.X),
            ($script:dragOrigin.Y + $now.Y - $script:dragFrom.Y))
    }
}
$endDrag = { $script:dragging = $false }
foreach ($handle in @($titleBar, $titleText)) {
    $handle.Add_MouseDown($startDrag); $handle.Add_MouseMove($moveDrag); $handle.Add_MouseUp($endDrag)
}

# --- Art rail ----------------------------------------------------------
$railPanel = New-Control System.Windows.Forms.Panel 0 $bar $rail ($H - $bar)
$railPanel.BackColor = $plate
$railPanel.Tag = @{ Wallpaper = $wallpaper; Splash = $splash; Logo = $logo }
$form.Controls.Add($railPanel)
$railPanel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $whole = New-Object System.Drawing.Rectangle 0, 0, $sender.Width, $sender.Height
    $art = $sender.Tag.Wallpaper
    if ($art) {
        # Fill from the centre-right of the wallpaper, where the game puts its
        # heavy zed, and stop short of the logo burned into its lower edge.
        $srcH = [int]($art.Height * 0.64)
        $srcW = [int]($srcH * $sender.Width / $sender.Height)
        $left = [Math]::Max(0, [Math]::Min($art.Width - $srcW, [int]($art.Width * 0.68) - [int]($srcW / 2)))
        $g.DrawImage($art, $whole, $left, 0, $srcW, $srcH, [System.Drawing.GraphicsUnit]::Pixel)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(168, 8, 8, 10))), $whole)
        $wide = $whole; $wide.Inflate(1, 1)
        $fade = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $wide, [System.Drawing.Color]::FromArgb(0, 12, 12, 14), [System.Drawing.Color]::FromArgb(236, 12, 12, 14), 0.0)
        $g.FillRectangle($fade, $whole)
        $fade.Dispose()
    } else {
        $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $whole, [System.Drawing.Color]::FromArgb(255, 34, 34, 40), [System.Drawing.Color]::FromArgb(255, 12, 12, 14), 60.0)
        $g.FillRectangle($fill, $whole)
        $fill.Dispose()
    }
    $under = New-Object System.Drawing.Rectangle 0, ($sender.Height - 300), $sender.Width, 300
    $tall = $under; $tall.Inflate(1, 1)
    $foot = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $tall, [System.Drawing.Color]::FromArgb(0, 8, 8, 10), [System.Drawing.Color]::FromArgb(226, 8, 8, 10), 90.0)
    $g.FillRectangle($foot, $under)
    $foot.Dispose()
    if ($sender.Tag.Splash) {
        $attributes = New-Object System.Drawing.Imaging.ImageAttributes
        $matrix = New-Object System.Drawing.Imaging.ColorMatrix
        $matrix.Matrix33 = 0.5
        $attributes.SetColorMatrix($matrix)
        $target = New-Object System.Drawing.Rectangle -30, 58, ($sender.Width + 80), 210
        $g.DrawImage($sender.Tag.Splash, $target, 0, 0, $sender.Tag.Splash.Width, $sender.Tag.Splash.Height,
            [System.Drawing.GraphicsUnit]::Pixel, $attributes)
        $attributes.Dispose()
    }
    if ($sender.Tag.Logo) {
        $mark = $sender.Tag.Logo
        $width = $sender.Width - 96
        $height = [int]($width * $mark.Height / $mark.Width)
        $g.DrawImage($mark, 48, (108 - [int]($height / 2)), $width, $height)
    }
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $red), ($sender.Width - 3), 0, 3, $sender.Height)
})
if (-not $logo) {
    [void](New-Caption $railPanel 48 46 320 108 "KILLING`r`nFLOOR 2" $fontWord $white)
}
[void](New-Caption $railPanel 50 210 320 30 'VIRTUAL REALITY' $fontTag $redHot)
[void](New-Caption $railPanel 50 ($H - $bar - 194) 330 20 'THIS SESSION' $fontLabel $redHot)
$summary = New-Caption $railPanel 50 ($H - $bar - 168) 330 96 '' $fontBody $dim 'TopLeft'
$buildText = if ($Release) { [string]$Release } else { 'selected package' }
[void](New-Caption $railPanel 50 ($H - $bar - 64) 330 40 "BUILD`r`n$buildText" $fontSmall $mute 'TopLeft')

# --- Toggles -----------------------------------------------------------
# Chips and cards are drawn rather than themed, so the window keeps one look
# instead of mixing the system's controls into the game's.
function Draw-Toggle {
    param($Sender, $Graphics, $Radius, $Font)
    $st = $Sender.Tag
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($Sender.Width - 1), ($Sender.Height - 1)
    $fill = $plate; $border = $edge; $face = $dim
    if (-not $st.Enabled) { $fill = $ink; $border = Rgb 38 38 44; $face = $mute }
    elseif ($st.Checked) { $fill = $redDeep; $border = $red; $face = $white }
    elseif ($st.Hover) { $fill = $plateUp; $border = $dim; $face = $fg }
    else { $fill = $plateUp; $border = $edge; $face = $fg }
    Draw-Plate $Graphics $rect $Radius $fill $border -Scanlines
    $left = 16
    if (-not $st.Center) {
        $box = New-Object System.Drawing.Rectangle 16, ([int]($Sender.Height / 2) - 9), 18, 18
        $mark = if (-not $st.Enabled) { $mute } elseif ($st.Checked) { $redHot } else { $edge }
        Draw-Plate $Graphics $box 3 $(if ($st.Checked -and $st.Enabled) { $red } else { $ink }) $mark
        if ($st.Checked) {
            $pen = New-Object System.Drawing.Pen $(if ($st.Enabled) { $white } else { $mute }), 2
            $Graphics.DrawLine($pen, ($box.X + 4), ($box.Y + 9), ($box.X + 7), ($box.Y + 13))
            $Graphics.DrawLine($pen, ($box.X + 7), ($box.Y + 13), ($box.X + 14), ($box.Y + 5))
            $pen.Dispose()
        }
        $left = 46
    }
    $flags = if ($st.Center) {
        [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    } else {
        [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    }
    $inner = New-Object System.Drawing.Rectangle $left, 0, ($Sender.Width - $left - 16), $Sender.Height
    [System.Windows.Forms.TextRenderer]::DrawText($Graphics, [string]$st.Text, $Font, $inner, $face, $flags)
}
function New-Toggle {
    param($Parent, $X, $Y, $Width, $Height, $Text, $Checked, $Font, [switch]$Center, [switch]$Radio)
    $toggle = New-Control System.Windows.Forms.Panel $X $Y $Width $Height
    $toggle.BackColor = $ink
    $toggle.Tag = @{ Text = $Text; Checked = [bool]$Checked; Enabled = $true; Hover = $false
                     Center = [bool]$Center; Radio = [bool]$Radio; Font = $Font; OnChange = $null }
    $toggle.Add_Paint({ param($sender, $e) Draw-Toggle $sender $e.Graphics 5 $sender.Tag.Font })
    $toggle.Add_MouseEnter({ param($sender, $e) $sender.Tag.Hover = $true; $sender.Invalidate() })
    $toggle.Add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = $false; $sender.Invalidate() })
    $toggle.Add_Click({
        param($sender, $e)
        if (-not $sender.Tag.Enabled) { return }
        if ($sender.Tag.Radio -and $sender.Tag.Checked) { return }
        $sender.Tag.Checked = -not $sender.Tag.Checked
        $sender.Invalidate()
        if ($sender.Tag.OnChange) { & $sender.Tag.OnChange }
    })
    $toggle.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Parent.Controls.Add($toggle)
    $toggle
}
function Set-Toggle {
    param($Toggle, $Checked, $Enabled)
    if ($PSBoundParameters.ContainsKey('Checked')) { $Toggle.Tag.Checked = [bool]$Checked }
    if ($PSBoundParameters.ContainsKey('Enabled')) { $Toggle.Tag.Enabled = [bool]$Enabled }
    $Toggle.Cursor = if ($Toggle.Tag.Enabled) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    $Toggle.Invalidate()
}

# --- Select fields -----------------------------------------------------
# A drawn field with its own popup list. A themed ComboBox would bring the
# system's white drop-down button back into an otherwise black window.
function New-Select {
    param($Parent, $X, $Y, $Width, $Items, $Index)
    $field = New-Control System.Windows.Forms.Panel $X $Y $Width 40
    $field.BackColor = $ink
    $field.Tag = @{ Items = @($Items); Index = [int]$Index; Enabled = $true; Hover = $false; Open = $false; OnChange = $null }
    $field.Cursor = [System.Windows.Forms.Cursors]::Hand
    $field.Add_Paint({
        param($sender, $e)
        $st = $sender.Tag
        $g = $e.Graphics
        $rect = New-Object System.Drawing.Rectangle 0, 0, ($sender.Width - 1), ($sender.Height - 1)
        $fill = if ($st.Enabled) { $plateUp } else { $ink }
        $border = if (-not $st.Enabled) { Rgb 38 38 44 } elseif ($st.Open -or $st.Hover) { $red } else { $edge }
        Draw-Plate $g $rect 5 $fill $border -Scanlines
        $face = if ($st.Enabled) { $fg } else { $mute }
        $value = if ($st.Index -ge 0 -and $st.Index -lt $st.Items.Count) { [string]$st.Items[$st.Index] } else { '' }
        $inner = New-Object System.Drawing.Rectangle 16, 0, ($sender.Width - 56), $sender.Height
        [System.Windows.Forms.TextRenderer]::DrawText($g, $value, $sender.Font, $inner, $face,
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter `
                -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object System.Drawing.Pen $(if ($st.Enabled) { $redHot } else { $mute }), 2
        $cx = $sender.Width - 24; $cy = [int]($sender.Height / 2) - 2
        $g.DrawLine($pen, ($cx - 5), $cy, $cx, ($cy + 5))
        $g.DrawLine($pen, $cx, ($cy + 5), ($cx + 5), $cy)
        $pen.Dispose()
    })
    $field.Add_MouseEnter({ param($sender, $e) $sender.Tag.Hover = $true; $sender.Invalidate() })
    $field.Add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = $false; $sender.Invalidate() })
    $field.Add_Click({ param($sender, $e) Show-SelectList $sender })
    $field.Font = $fontBody
    $Parent.Controls.Add($field)
    $field
}
function Show-SelectList {
    param($Field)
    $st = $Field.Tag
    if (-not $st.Enabled -or $st.Open -or -not $st.Items.Count) { return }
    $rowH = 32
    $pad = 6
    $shown = [Math]::Min($st.Items.Count, 11)
    $height = $shown * $rowH + $pad * 2
    $popup = New-Object System.Windows.Forms.Form
    $popup.FormBorderStyle = 'None'
    $popup.ShowInTaskbar = $false
    $popup.StartPosition = 'Manual'
    $popup.BackColor = $red
    $popup.ClientSize = New-Object System.Drawing.Size($Field.Width, $height)
    $origin = $Field.PointToScreen((New-Object System.Drawing.Point 0, $Field.Height))
    $screen = [System.Windows.Forms.Screen]::FromControl($Field).WorkingArea
    $topY = $origin.Y + 4
    if (($topY + $height) -gt $screen.Bottom) { $topY = $origin.Y - $Field.Height - $height - 4 }
    $popup.Location = New-Object System.Drawing.Point $origin.X, $topY
    $list = New-Control System.Windows.Forms.Panel 1 1 ($Field.Width - 2) ($height - 2)
    $list.BackColor = $plate
    $first = [Math]::Max(0, [Math]::Min($st.Items.Count - $shown, $st.Index - [int]($shown / 2)))
    # Event handlers run after this function has returned, so everything they
    # need lives on the control instead of in a local.
    $list.Tag = @{ Items = $st.Items; First = $first; Shown = $shown; RowH = $rowH; Pad = $pad
                   Index = $st.Index; Hover = -1; Field = $Field; Popup = $popup
                   RowAt = {
                       param($Sender, $Y)
                       $ls = $Sender.Tag
                       $row = [Math]::Floor(($Y - $ls.Pad) / $ls.RowH)
                       if ($row -lt 0 -or $row -ge $ls.Shown) { return -1 }
                       $item = $ls.First + $row
                       if ($item -ge $ls.Items.Count) { -1 } else { $item }
                   } }
    $list.Add_Paint({
        param($sender, $e)
        $ls = $sender.Tag
        $g = $e.Graphics
        $g.FillRectangle((New-Object System.Drawing.SolidBrush $plate), 0, 0, $sender.Width, $sender.Height)
        $g.FillRectangle($scanBrush, 0, 0, $sender.Width, $sender.Height)
        for ($i = 0; $i -lt $ls.Shown; $i++) {
            $item = $ls.First + $i
            if ($item -ge $ls.Items.Count) { break }
            $top = $ls.Pad + $i * $ls.RowH
            $row = New-Object System.Drawing.Rectangle 4, $top, ($sender.Width - 8), $ls.RowH
            if ($item -eq $ls.Hover) {
                $g.FillRectangle((New-Object System.Drawing.SolidBrush $redDeep), $row)
            }
            if ($item -eq $ls.Index) {
                $g.FillRectangle((New-Object System.Drawing.SolidBrush $redHot), 4, $top, 3, $ls.RowH)
            }
            $face = if ($item -eq $ls.Index -or $item -eq $ls.Hover) { $white } else { $dim }
            $inner = New-Object System.Drawing.Rectangle 16, $top, ($sender.Width - 28), $ls.RowH
            [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$ls.Items[$item], $sender.Font, $inner, $face,
                ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter `
                    -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
        }
        if ($ls.Items.Count -gt $ls.Shown) {
            $track = $sender.Height - $ls.Pad * 2
            $thumb = [Math]::Max(24, [int]($track * $ls.Shown / $ls.Items.Count))
            $span = $ls.Items.Count - $ls.Shown
            $top = $ls.Pad + [int](($track - $thumb) * $ls.First / $span)
            $g.FillRectangle((New-Object System.Drawing.SolidBrush $edge), ($sender.Width - 5), $top, 3, $thumb)
        }
    })
    $list.Add_MouseMove({
        param($sender, $e)
        $hit = & $sender.Tag.RowAt $sender $e.Y
        if ($hit -ne $sender.Tag.Hover) { $sender.Tag.Hover = $hit; $sender.Invalidate() }
    })
    $list.Add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = -1; $sender.Invalidate() })
    $list.Add_MouseWheel({
        param($sender, $e)
        $ls = $sender.Tag
        $step = 3 * [Math]::Sign($e.Delta)
        $ls.First = [Math]::Max(0, [Math]::Min($ls.Items.Count - $ls.Shown, $ls.First - $step))
        $sender.Invalidate()
    })
    $list.Add_Click({
        param($sender, $e)
        $hit = & $sender.Tag.RowAt $sender $sender.PointToClient([System.Windows.Forms.Cursor]::Position).Y
        if ($hit -ge 0) {
            $chosen = $sender.Tag.Field
            $chosen.Tag.Index = $hit
            $chosen.Invalidate()
            $sender.Tag.Popup.Close()
            if ($chosen.Tag.OnChange) { & $chosen.Tag.OnChange }
        }
    })
    $list.Font = $fontBody
    $popup.Controls.Add($list)
    $popup.Tag = @{ Field = $Field }
    $popup.Add_Deactivate({ param($sender, $e) $sender.Close() })
    $popup.Add_FormClosed({
        param($sender, $e)
        $sender.Tag.Field.Tag.Open = $false
        $sender.Tag.Field.Invalidate()
    })
    $st.Open = $true
    $Field.Invalidate()
    $popup.Show($form)
    $list.Focus()
}
function Get-SelectValue { param($Field) [string]$Field.Tag.Items[$Field.Tag.Index] }

# --- Pages -------------------------------------------------------------
$pageTop = $bar + 112
$pageHeight = $H - $pageTop - 148
$pages = [ordered]@{}
foreach ($name in @('SESSION', 'HEADSET', 'MODS', 'TEST CONTROL')) {
    $page = New-Control System.Windows.Forms.Panel $x0 $pageTop $cw $pageHeight
    $page.BackColor = $ink
    $page.Visible = $false
    $form.Controls.Add($page)
    $pages[$name] = $page
}
$tabs = @{}
$tabX = $x0
foreach ($name in @($pages.Keys)) {
    $tab = New-Control System.Windows.Forms.Panel $tabX ($bar + 40) 150 44
    $tab.BackColor = $ink
    $tab.Cursor = [System.Windows.Forms.Cursors]::Hand
    $tab.Tag = @{ Name = $name; Active = $false; Hover = $false }
    $tab.Add_Paint({
        param($sender, $e)
        $st = $sender.Tag
        $g = $e.Graphics
        $face = if ($st.Active) { $white } elseif ($st.Hover) { $fg } else { $mute }
        [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$st.Name, $fontTab,
            (New-Object System.Drawing.Rectangle 0, 0, $sender.Width, ($sender.Height - 6)), $face,
            ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
        $g.FillRectangle((New-Object System.Drawing.SolidBrush $(if ($st.Active) { $redHot } else { $plateUp })),
            0, ($sender.Height - 3), $sender.Width, 3)
    })
    $tab.Add_MouseEnter({ param($sender, $e) $sender.Tag.Hover = $true; $sender.Invalidate() })
    $tab.Add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = $false; $sender.Invalidate() })
    $tab.Add_Click({ param($sender, $e) Select-Page $sender.Tag.Name })
    $form.Controls.Add($tab)
    $tabs[$name] = $tab
    $tabX += 154
}
function Select-Page {
    param($Name)
    foreach ($key in @($pages.Keys)) {
        $pages[$key].Visible = ($key -eq $Name)
        $tabs[$key].Tag.Active = ($key -eq $Name)
        $tabs[$key].Invalidate()
    }
}
function New-Field {
    param($Page, $Label, $Y, $Items, $Index)
    [void](New-Caption $Page 0 $Y 150 40 ([string]$Label).ToUpperInvariant() $fontLabel $dim)
    New-Select $Page 160 $Y ($cw - 160) $Items $Index
}
function New-Rule {
    param($Page, $Y, $Text)
    if ($Text) { [void](New-Caption $Page 0 ($Y - 26) 400 22 ([string]$Text).ToUpperInvariant() $fontLabel $redHot) }
    $rule = New-Control System.Windows.Forms.Panel 0 $Y $cw 1
    $rule.BackColor = $plateUp
    $Page.Controls.Add($rule)
}

# Session -----------------------------------------------------------------
$session = $pages['SESSION']
$cardW = [int](($cw - 20) / 2)
# Two different kinds of match, chosen explicitly: hosting goes through the
# dedicated server and replication; solo is standalone with no network at all.
$savedSolo = $false
try { $savedSolo = (Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'KF2VR/Profile/session-type.txt') -ErrorAction Stop | Select-Object -First 1) -eq 'solo' } catch {}
$startSolo = [bool]$Solo -or (($savedSolo -or -not $s.server_installed) -and -not $TestMap)
$hostCard = New-Toggle $session 0 0 $cardW 64 'HOST ON THIS PC' (-not $startSolo) $fontCard -Center -Radio
$soloCard = New-Toggle $session ($cardW + 20) 0 $cardW 64 'TRUE SOLO' $startSolo $fontCard -Center -Radio
$sessionNote = New-Caption $session 0 70 $cw 36 '' $fontSmall $amber 'TopLeft'
$vrCard = New-Toggle $session 0 112 $cardW 56 'VR HEADSET' ([bool]$s.vr) $fontCard -Center -Radio
$flatCard = New-Toggle $session ($cardW + 20) 112 $cardW 56 'DESKTOP' (-not [bool]$s.vr) $fontCard -Center -Radio
# Older intact packages may predate solo_maps; read only installed client maps
# in that case. Both modes still launch that same selected package.
$stockMaps = @($s.solo_maps)
if (-not $s.PSObject.Properties['solo_maps']) {
    $stockMaps = @(Get-ChildItem -LiteralPath (Join-Path $GameRoot 'KFGame/BrewedPC/Maps') -Recurse -Filter 'KF-*.kfm' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -ne $s.test_map_name } | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
}
$initialMaps = @(if ($startSolo) { $stockMaps } else { $s.maps })
$startMap = if ($TestMap) { [string]$s.test_map_name } else { [string]$s.map }
if ($InitialSelections.ContainsKey('Map') -and $initialMaps -notcontains $startMap) { $initialMaps += $startMap }
$mapNames = @($initialMaps | ForEach-Object { if ($_ -eq $s.test_map_name) { "$_    Remilly test map" } else { [string]$_ } })
$startIndex = [Math]::Max(0, [Array]::IndexOf([string[]]$initialMaps, $startMap))
$mapField = New-Field $session 'Map' 196 $mapNames $startIndex
$mapField.Tag.MapValues = @($initialMaps)
$mapField.Tag.ForSolo = $startSolo
$difficultyField = New-Field $session 'Difficulty' 252 @($s.difficulties | ForEach-Object { Get-Label $_ }) ([Math]::Max(0, [Array]::IndexOf([string[]]$s.difficulties, [string]$s.difficulty)))
$lengthField = New-Field $session 'Match length' 308 @($s.game_lengths | ForEach-Object { Get-Label $_ }) ([Math]::Max(0, [Array]::IndexOf([string[]]$s.game_lengths, [string]$s.game_length)))
$sessionFoot = New-Caption $session 0 364 $cw 40 '' $fontSmall $mute 'TopLeft'

# Headset ------------------------------------------------------------------
$headset = $pages['HEADSET']
$qualityField = New-Field $headset 'Graphics' 0 @($s.vr_qualities | ForEach-Object { Get-Label $_ }) ([Math]::Max(0, [Array]::IndexOf([string[]]$s.vr_qualities, [string]$s.vr_quality)))
$scales = @(100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50)
$scaleIndex = 0
if ($InitialSelections.ContainsKey('EyeRenderPercent')) {
    $scales = @($scales + [int]$InitialSelections.EyeRenderPercent | Sort-Object -Descending -Unique)
    $scaleIndex = 1 + [array]::IndexOf([int[]]$scales, [int]$InitialSelections.EyeRenderPercent)
}
$scaleField = New-Field $headset 'Render scale' 60 (@('Use saved preference') + @($scales | ForEach-Object { "$_%" })) $scaleIndex
[void](New-Caption $headset 0 118 $cw 30 'Provisional starts: Quest Performance / 75%; Index Balanced / 100%; high-resolution Performance / 65%.' $fontSmall $mute 'TopLeft')
New-Rule $headset 150 'Experimental'
$threadedToggle = New-Toggle $headset 0 176 $cw 46 'Threaded rendering (experimental)' ([bool]$s.threaded_render) $fontBody
[void](New-Caption $headset 0 224 $cw 22 'OFF: portal see-through views. ON: flat portal fill; may improve frame rate.' $fontSmall $mute 'TopLeft')
$focusToggle = New-Toggle $headset 0 250 $cw 46 'Slow time while a VR inventory selector is held' ([bool]$s.inventory_focus) $fontBody
[void](New-Caption $headset 0 298 $cw 22 'Host-controlled and shared by everyone in the session. It yields to Zed Time.' $fontSmall $mute 'TopLeft')
$grabToggle = New-Toggle $headset 0 324 $cw 46 'Multiplayer Zed grabbing (host sets it for all players)' ([bool]$s.multiplayer_grabs) $fontBody
[void](New-Caption $headset 0 372 $cw 22 'Experimental server physics; the host sets it for every VR player. Solo has its own grabbing setting.' $fontSmall $mute 'TopLeft')
$headsetNote = New-Caption $headset 0 398 $cw 36 '' $fontSmall $amber 'TopLeft'

# Mods ---------------------------------------------------------------------
$mods = $pages['MODS']
# A saved Desktop session resolves to no mods, because friends.py only applies
# the remembered loadout to VR. The window always passes its mods explicitly,
# so start from the remembered VR selection rather than from that empty list.
$startMods = if (@($s.mods).Count) { [string[]]$s.mods } else { [string[]]$s.vr_mods }
$modToggles = @{}
$patchToggle = $null
$index = 0
foreach ($mod in $s.mod_catalog) {
    $toggle = New-Toggle $mods (($index % 2) * ($cardW + 20)) ([Math]::Floor($index / 2) * 58) $cardW 46 `
        ([string]$mod.label) ([string[]]$startMods -contains [string]$mod.key) $fontBody
    $modToggles[[string]$mod.key] = $toggle
    if ($mod.key -eq 'ukfp') { $patchToggle = $toggle }
    $index++
}
$modsBottom = [Math]::Ceiling($index / 2) * 58 + 44
New-Rule $mods $modsBottom 'Patch options'
$popupToggle = New-Toggle $mods 0 ($modsBottom + 26) $cardW 46 'Damage popups' ([bool]$s.damage_popups) $fontBody
$scalingToggle = New-Toggle $mods ($cardW + 20) ($modsBottom + 26) $cardW 46 'Remilly: 6-player waves' ([int]$s.test_map_players -eq 6) $fontBody
$portalToggle = New-Toggle $mods 0 ($modsBottom + 84) $cw 46 'Portal gun for sale at the trader (Solo only, experimental; portals are local)' ([bool]$s.portal_gun) $fontBody
$breacherToggle = New-Toggle $mods 0 ($modsBottom + 136) $cw 46 'Breacher (experimental; matching local package required for every player)' ([bool]$s.breacher) $fontBody
$modsNote = New-Caption $mods 0 ($modsBottom + 190) $cw 40 '' $fontSmall $mute 'TopLeft'

# Explicit test control is never read from or saved to the launcher profile.
$testPage = $pages['TEST CONTROL']
$localTestToggle = New-Toggle $testPage 0 0 $cw 46 'Local agent test control (this launch only, Solo VR)' ([bool]$InitialSelections.LocalTestControl) $fontBody
[void](New-Caption $testPage 0 58 $cw 80 'UNRANKED TEST SESSION. Gives verified VR weapons and spawns test zeds. Carry capacity is bypassed for grants. Disabling leaves granted inventory and spawned zeds; restart for normal play.' $fontBody $amber 'TopLeft')
[void](New-Caption $testPage 0 150 $cw 44 'Default OFF and never remembered. Hosted LAN and joined-server control are not implemented in this version.' $fontSmall $dim 'TopLeft')

# --- Stale build and actions -------------------------------------------
$staleToggle = $null
if ($Stale) {
    [void](New-Caption $form $x0 ($H - 196) $cw 20 'This build is older than the current source. Its files are intact; recent changes are not in it.' $fontSmall $amber)
    $staleToggle = New-Toggle $form $x0 ($H - 172) $cw 42 'Play this older build anyway' ([bool]$InitialSelections.AllowStale) $fontBody
}
function Draw-Action {
    param($Sender, $Graphics)
    $st = $Sender.Tag
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($Sender.Width - 1), ($Sender.Height - 1)
    $fill = $plateUp; $border = $edge; $face = $fg
    if (-not $st.Enabled) { $fill = $plate; $border = Rgb 38 38 44; $face = $mute }
    elseif ($st.Primary) { $fill = $(if ($st.Hover) { $redHot } else { $red }); $border = $redHot; $face = $white }
    elseif ($st.Hover) { $border = $dim }
    Draw-Plate $Graphics $rect 5 $fill $border -Scanlines
    [System.Windows.Forms.TextRenderer]::DrawText($Graphics, [string]$st.Text, $fontAction,
        (New-Object System.Drawing.Rectangle 0, 0, $Sender.Width, $Sender.Height), $face,
        ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
}
function New-Action {
    param($Text, $X, $Width, [switch]$Primary)
    $button = New-Control System.Windows.Forms.Panel $X ($H - 108) $Width 54
    $button.BackColor = $ink
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Tag = @{ Text = ([string]$Text).ToUpperInvariant(); Primary = [bool]$Primary; Enabled = $true; Hover = $false; OnClick = $null }
    $button.Add_Paint({ param($sender, $e) Draw-Action $sender $e.Graphics })
    $button.Add_MouseEnter({ param($sender, $e) $sender.Tag.Hover = $true; $sender.Invalidate() })
    $button.Add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = $false; $sender.Invalidate() })
    $button.Add_Click({ param($sender, $e) if ($sender.Tag.Enabled -and $sender.Tag.OnClick) { & $sender.Tag.OnClick } })
    $form.Controls.Add($button)
    $button
}
$quitButton = New-Action 'Quit' $x0 150
$prepareButton = New-Action 'Prepare only' ($x0 + 162) 190
$playButton = New-Action 'Play' ($x0 + $cw - 230) 230 -Primary

# --- Rules -------------------------------------------------------------
# One place keeps the window's state honest, so the combinations friends.py
# rejects can never be assembled here in the first place.
$refresh = {
    $vr = $vrCard.Tag.Checked
    $solo = $soloCard.Tag.Checked
    if ($mapField.Tag.ForSolo -ne $solo) {
        $previousMap = [string]$mapField.Tag.MapValues[$mapField.Tag.Index]
        $available = @(if ($solo) { $stockMaps } else { $s.maps })
        $mapField.Tag.MapValues = @($available)
        $mapField.Tag.Items = @($available | ForEach-Object { if ($_ -eq $s.test_map_name) { "$_    Remilly test map" } else { [string]$_ } })
        $mapField.Tag.Index = [Math]::Max(0, [Array]::IndexOf([string[]]$available, $previousMap))
        $mapField.Tag.ForSolo = $solo
        $mapField.Invalidate()
    }
    $mapName = [string]$mapField.Tag.MapValues[$mapField.Tag.Index]
    $isTestMap = $mapName -eq [string]$s.test_map_name
    $soloMapOk = -not $isTestMap -and $stockMaps -contains $mapName
    $hostMapOk = $s.maps -contains $mapName
    $sessionNote.Text = if ($solo) {
        'Standalone single player from the selected build. No dedicated server, no network, no replication.'
    } else { 'Starts a dedicated server on this PC and joins it - the multiplayer path, with replication.' }
    $sessionFoot.Text = if (-not $solo -and -not $s.server_installed) { 'Hosting needs the dedicated server. Install it with tools\install-multiplayer-server.ps1, or choose True Solo.' }
        elseif ($solo -and -not $soloMapOk) { 'Solo needs a stock map installed in Killing Floor 2.' }
        elseif (-not $solo -and -not $hostMapOk) { 'This map is unavailable for hosting. Choose an installed or supported Workshop map.' }
        elseif ($solo) { 'Mods and the inventory slowdown apply to hosted sessions only.' }
        else { 'Friends join with the address and password the launcher prints.' }
    $sessionFoot.ForeColor = if (($solo -and -not $soloMapOk) -or (-not $solo -and (-not $s.server_installed -or -not $hostMapOk))) { $amber } else { $mute }
    Set-Toggle $qualityField -Enabled $vr
    Set-Toggle $scaleField -Enabled $vr
    Set-Toggle $threadedToggle -Enabled $vr
    Set-Toggle $focusToggle -Enabled (-not $solo)
    Set-Toggle $grabToggle -Enabled (-not $solo)
    $headsetNote.Text = if ($vr) { '' } else { 'This is a desktop session, so these settings are not used.' }
    $patch = $patchToggle.Tag.Checked
    Set-Toggle $patchToggle -Enabled (-not $solo)
    Set-Toggle $portalToggle -Enabled $solo
    Set-Toggle $localTestToggle -Enabled ($solo -and $vr) -Checked $(if ($solo -and $vr) { $localTestToggle.Tag.Checked } else { $false })
    foreach ($key in @($modToggles.Keys)) {
        if ($key -ne 'ukfp') {
            Set-Toggle $modToggles[$key] -Enabled ($patch -and -not $solo) -Checked $(if ($patch) { $modToggles[$key].Tag.Checked } else { $false })
        }
    }
    Set-Toggle $popupToggle -Enabled (-not $solo -and ($patch -or $vr))
    Set-Toggle $scalingToggle -Enabled (-not $solo -and $patch -and $isTestMap)
    $modsNote.Text = if (-not $patch -and -not $vr) {
        'Damage popups and Remilly scaling need the Unofficial Patch.'
    } elseif (-not $isTestMap) { 'Remilly scaling applies to the test map only.' } else { '' }
    $go = (-not $staleToggle -or $staleToggle.Tag.Checked) -and
        $(if ($solo) { $soloMapOk } else { [bool]$s.server_installed -and $hostMapOk })
    foreach ($button in @($playButton, $prepareButton)) { $button.Tag.Enabled = $go; $button.Invalidate() }
    if ($solo) { $modsNote.Text = 'True solo runs without mods; these apply when you host.' }
    $chosen = @($s.mod_catalog | Where-Object { $modToggles[[string]$_.key].Tag.Checked })
    $summary.Text = ($(if ($solo) { 'TRUE SOLO - NO SERVER' } else { 'HOSTED ON THIS PC' }) + "`r`n" + $(if ($vr) { 'VR HEADSET' } else { 'DESKTOP' }) + '   /   ' + $mapName + "`r`n" +
        (Get-SelectValue $difficultyField) + '   /   ' + ((Get-SelectValue $lengthField) -split '\s+-\s+')[0] + "`r`n" +
        $(if (-not $solo -and $chosen.Count) { "$($chosen.Count) mods enabled" } else { 'No mods' }))
}
$vrCard.Tag.OnChange = {
    $flatCard.Tag.Checked = $false
    $flatCard.Invalidate()
    # Switching to VR restores the remembered VR loadout when nothing is on,
    # the way the console menu re-resolves the profile.
    if (-not @($modToggles.Values | Where-Object { $_.Tag.Checked }).Count) {
        foreach ($key in [string[]]$s.vr_mods) {
            if ($modToggles.ContainsKey($key)) { $modToggles[$key].Tag.Checked = $true; $modToggles[$key].Invalidate() }
        }
    }
    & $refresh
}
$flatCard.Tag.OnChange = { $vrCard.Tag.Checked = $false; $vrCard.Invalidate(); & $refresh }
$hostCard.Tag.OnChange = { $soloCard.Tag.Checked = $false; $soloCard.Invalidate(); & $refresh }
$soloCard.Tag.OnChange = { $hostCard.Tag.Checked = $false; $hostCard.Invalidate(); & $refresh }
foreach ($field in @($mapField, $difficultyField, $lengthField, $qualityField, $scaleField)) { $field.Tag.OnChange = $refresh }
foreach ($toggle in @($modToggles.Values) + @($popupToggle, $scalingToggle, $focusToggle, $grabToggle, $portalToggle, $threadedToggle, $localTestToggle)) { $toggle.Tag.OnChange = $refresh }
if ($staleToggle) { $staleToggle.Tag.OnChange = $refresh }

$script:choice = $null
$playButton.Tag.OnClick = { $script:choice = 'play'; $form.Close() }
$prepareButton.Tag.OnClick = { $script:choice = 'prepare'; $form.Close() }
$quitButton.Tag.OnClick = { $form.Close() }
$form.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

Select-Page 'SESSION'
& $refresh
[void]$form.ShowDialog()
foreach ($image in @($wallpaper, $logo, $splash, $scanplate)) { if ($image) { $image.Dispose() } }
$scanBrush.Dispose(); $texture.Dispose()
if (-not $script:choice) { return }

$map = [string]$mapField.Tag.MapValues[$mapField.Tag.Index]
$chosenMods = @($s.mod_catalog | Where-Object { $modToggles[[string]$_.key].Tag.Checked } | ForEach-Object { [string]$_.key })
$result = @{
    Map            = $map
    TestMap        = ($map -eq [string]$s.test_map_name)
    Difficulty     = @('Normal', 'Hard', 'Suicidal', 'HellOnEarth')[$difficultyField.Tag.Index]
    GameLength     = @('Short', 'Medium', 'Long')[$lengthField.Tag.Index]
    Mods           = $(if ($chosenMods.Count) { $chosenMods -join ',' } else { 'none' })
    DamagePopups   = $(if ($popupToggle.Tag.Checked) { 'On' } else { 'Off' })
    InventoryFocus = $(if ($focusToggle.Tag.Checked) { 'On' } else { 'Off' })
    MultiplayerGrabs = $(if ($grabToggle.Tag.Checked) { 'On' } else { 'Off' })
    PortalGun      = $(if ($portalToggle.Tag.Checked) { 'On' } else { 'Off' })
    Breacher       = $(if ($breacherToggle.Tag.Checked) { 'On' } else { 'Off' })
    TestMapPlayers = $(if ($scalingToggle.Tag.Checked) { 6 } else { 0 })
    PrepareOnly    = ($script:choice -eq 'prepare')
    AllowStale     = [bool]($staleToggle -and $staleToggle.Tag.Checked)
    Vr             = $vrCard.Tag.Checked
    Desktop        = (-not $vrCard.Tag.Checked)
    Solo           = $soloCard.Tag.Checked
    LocalTestControl = ($localTestToggle.Tag.Checked -and $soloCard.Tag.Checked -and $vrCard.Tag.Checked)
}
if ($result.Solo) {
    foreach ($name in @('Mods', 'DamagePopups', 'InventoryFocus', 'MultiplayerGrabs', 'TestMapPlayers')) { $result.Remove($name) }
}
else { $result.Remove('PortalGun') }
if ($vrCard.Tag.Checked) {
    $result.VrQuality = [string]$s.vr_qualities[$qualityField.Tag.Index]
    $result.ThreadedRender = $(if ($threadedToggle.Tag.Checked) { 'On' } else { 'Off' })
    if ($scaleField.Tag.Index -gt 0) { $result.EyeRenderPercent = $scales[$scaleField.Tag.Index - 1] }
}
$result
