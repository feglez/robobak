# robobak-health.ps1 - Reads the SMART data of every connected disk for RoboBak.
# RoboBak starts it with admin rights at the end of a run, after asking. It only
# reads: it runs smartctl, or CrystalDiskInfo for the disks smartctl can't read,
# and writes what they report to -ResultPath as JSON. Nothing is written to any
# disk being read.

param(
    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

. (Join-Path $PSScriptRoot 'robobak-lib.ps1')

try {
    $result = Get-HealthReadings
} catch {
    $result = [pscustomobject]@{ Disks = @(); Error = $_.Exception.Message }
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
