# Phase B cleanup — tear down the test stack and remove temp env (run on .65).
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
docker compose -f docker-compose.test.yml -p mdptest down -v
Remove-Item ".env.test" -ErrorAction SilentlyContinue
Write-Host "### mdptest cleaned: down -v + .env.test removed ###"
