# Starts the normal MoonStone stack while enabling the fixed-story Mock only for
# GalGameService. Auth/User/File/Knowledge services continue to use real data.
param([switch]$Verify)

# Prevent a process-wide Mock flag from changing the other services.
Remove-Item Env:MOONSTONE_MODE -ErrorAction SilentlyContinue

& (Join-Path $PSScriptRoot 'start.ps1') -GalGameMock -Verify:$Verify
