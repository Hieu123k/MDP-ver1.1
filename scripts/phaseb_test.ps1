# Phase B smoke test (run on .65 / Docker Desktop). Builds + runs MDP-ver1.1 on :8456 (-p mdptest),
# generates temporary secrets, verifies health/login/seed/TypeB/outbound/pages, leaves stack running.
# Cleanup afterwards with scripts\phaseb_down.ps1
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Rand([int]$n = 32) { -join (1..$n | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
$pgpwd = Rand 24; $jwt = Rand 32; $conn = Rand 32

# Render .env.test from the committed template, injecting fresh temporary secrets
((Get-Content ".env.test.example" -Raw) -replace '__PG_PWD__', $pgpwd -replace '__JWT__', $jwt -replace '__CONN__', $conn) | Set-Content ".env.test" -Encoding ascii

Write-Host "### BUILD + UP (mdptest :8456) ###"
docker compose -f docker-compose.test.yml --env-file .env.test -p mdptest up -d --build

Write-Host "### WAIT backend healthy (up to 6 min) ###"
$ok = $false
for ($i = 0; $i -lt 72; $i++) {
  $h = (docker inspect -f '{{.State.Health.Status}}' mdptest-backend-1 2>$null)
  if ($h -eq 'healthy') { $ok = $true; break }
  Start-Sleep 5
}
Write-Host "backend healthy: $ok"
docker compose -f docker-compose.test.yml -p mdptest ps

$base = "https://localhost:8456"
Write-Host "### VERIFY (curl -k) ###"
$health = (& curl.exe -k -s -o NUL -w "%{http_code}" "$base/api/health")
Write-Host "health   /api/health             -> $health   (expect 200)"

'{"username":"admin","password":"admin123"}' | Set-Content "_login.json" -Encoding ascii
$loginRaw = (& curl.exe -k -s -X POST "$base/api/auth/login" -H "Content-Type: application/json" -d "@_login.json")
$token = $null; try { $token = ($loginRaw | ConvertFrom-Json).access_token } catch {}
if ($token) { Write-Host "login    /api/auth/login          -> 200 (token OK)" } else { Write-Host "login    /api/auth/login          -> FAIL: $loginRaw" }
$auth = "Authorization: Bearer $token"

$seedRaw = (& curl.exe -k -s -X POST "$base/api/admin/demo/seed-procurement-staging" -H "$auth")
try { $s = ($seedRaw | ConvertFrom-Json) } catch { $s = $null }
Write-Host ("seed     procurement-staging      -> " + $(if ($s) { $s.status } else { "FAIL" }))

'{}' | Set-Content "_empty.json" -Encoding ascii
$cmRaw = (& curl.exe -k -s -X POST "$base/api/data-model-templates/jde_supplier/create-model" -H "$auth" -H "Content-Type: application/json" -d "@_empty.json")
try { $cm = ($cmRaw | ConvertFrom-Json) } catch { $cm = $null }
Write-Host ("typeB    create supplier          -> " + $(if ($cm) { "$($cm.status) name=$($cm.data_model.name) status=$($cm.data_model.status)" } else { "FAIL: $cmRaw" }))

$outRaw = (& curl.exe -k -s "$base/api/outbound/supplier?limit=2" -H "$auth")
try { $out = ($outRaw | ConvertFrom-Json) } catch { $out = $null }
Write-Host ("outbound /api/outbound/supplier    -> " + $(if ($out) { "status=$($out.status) count=$($out.count)" } else { "FAIL: $outRaw" }))

foreach ($p in "/", "/login", "/migration-jobs", "/jde-demo") {
  $c = (& curl.exe -k -s -o NUL -w "%{http_code}" "$base$p")
  Write-Host ("page     $p -> $c")
}
Remove-Item "_login.json", "_empty.json" -ErrorAction SilentlyContinue
Write-Host "### DONE. Stack left running on https://localhost:8456 — clean with scripts\phaseb_down.ps1 ###"
