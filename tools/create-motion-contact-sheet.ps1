<# Contact sheet from saved real engine screenshots; raw captures stay intact. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SessionRoot)
$ErrorActionPreference='Stop'
$motionSession=[IO.Path]::GetFullPath($SessionRoot).TrimEnd('\','/')
$motionTimeline=Get-Content -LiteralPath (Join-Path $motionSession 'motion-timeline.json') -Raw | ConvertFrom-Json
$motionFrames=@($motionTimeline.captures | Where-Object { $_.status -eq 'copied' })
if ($motionFrames.Count -lt 1 -or $motionFrames.Count -gt 100) { throw 'Expected 1..100 saved engine frames.' }
Add-Type -AssemblyName System.Drawing
$motionRows=[int][Math]::Ceiling($motionFrames.Count/2.0)
$motionSheet=[Drawing.Bitmap]::new(1280,400*$motionRows)
$motionGraphics=[Drawing.Graphics]::FromImage($motionSheet)
$motionFont=[Drawing.Font]::new('Arial',11)
$motionBrush=[Drawing.SolidBrush]::new([Drawing.Color]::White)
try {
    $motionGraphics.Clear([Drawing.Color]::FromArgb(20,24,30))
    for ($motionIndex=0;$motionIndex -lt $motionFrames.Count;$motionIndex++) {
        $motionFrame=$motionFrames[$motionIndex]
        $motionPath=[IO.Path]::GetFullPath($motionFrame.files[0].copied_path)
        if (-not $motionPath.StartsWith($motionSession+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Frame must remain inside the session bundle.' }
        $motionImage=[Drawing.Image]::FromFile($motionPath)
        try {
            $motionX=($motionIndex%2)*640
            $motionY=[int][Math]::Floor($motionIndex/2)*400
            $motionGraphics.DrawImage($motionImage,$motionX,$motionY,640,360)
            $motionLabel='Replay '+$motionFrame.replay_id+' / '+([double]$motionFrame.replay_seconds).ToString('F3')+'s / sample '+$motionFrame.input_sample_index+' / seq '+$motionFrame.network_sequence
            $motionGraphics.DrawString($motionLabel,$motionFont,$motionBrush,$motionX+6,$motionY+363)
            $motionGraphics.DrawString('Actual engine screenshot / camera '+$motionFrame.camera_mode,$motionFont,$motionBrush,$motionX+6,$motionY+380)
        } finally { $motionImage.Dispose() }
    }
    $motionOutput=Join-Path $motionSession 'contact-sheet.png'
    $motionSheet.Save($motionOutput,[Drawing.Imaging.ImageFormat]::Png)
    Write-Output $motionOutput
} finally {
    $motionGraphics.Dispose();$motionSheet.Dispose();$motionFont.Dispose();$motionBrush.Dispose()
}
