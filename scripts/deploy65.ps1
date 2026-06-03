# Persistent MDP deploy on .65 (Docker Desktop). Builds + runs on :8456 (-p mdp65), production env,
# seeds demo, creates Type B supplier, rotates admin off default, verifies. LEAVES STACK RUNNING.
# Coexists with old MDP (80/443), ora2pg, postgres-5434, uns_db (untouched).
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Rand([int]$n = 32) { -join (1..$n | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
$pgpwd = Rand 24; $jwt = Rand 40; $conn = Rand 40
((Get-Content ".env.prod65.example" -Raw) -replace '__PG_PWD__', $pgpwd -replace '__JWT__', $jwt -replace '__CONN__', $conn) | Set-Content ".env.prod65" -Encoding ascii

Write-Host "### BUILD ###"
docker compose -f docker-compose.prod65.yml --env-file .env.prod65 -p mdp65 build
Write-Host "### UP -d (PERSISTENT, -p mdp65, :8456) ###"
docker compose -f docker-compose.prod65.yml --env-file .env.prod65 -p mdp65 up -d

Write-Host "### WAIT backend healthy (alembic upgrade head runs on start) ###"
$ok = $false
for ($i = 0; $i -lt 72; $i++) {
  $h = (docker inspect -f '{{.State.Health.Status}}' mdp65-backend-1 2>$null)
  if ($h -eq 'healthy') { $ok = $true; break }
  Start-Sleep 5
}
Write-Host "backend healthy: $ok"
docker compose -f docker-compose.prod65.yml -p mdp65 ps

$base = "https://localhost:8456"
Write-Host "### VERIFY (curl -k) ###"
Write-Host ("health   /api/health -> " + (& curl.exe -k -s -o NUL -w "%{http_code}" "$base/api/health"))

'{"username":"admin","password":"admin123"}' | Set-Content "_login.json" -Encoding ascii
$token = $null; try { $token = ((& curl.exe -k -s -X POST "$base/api/auth/login" -H "Content-Type: application/json" -d "@_login.json") | ConvertFrom-Json).access_token } catch {}
if ($token) { Write-Host "login    admin/admin123 -> 200 (token OK)" } else { Write-Host "login    -> FAIL (already rotated?)" }
$auth = "Authorization: Bearer $token"

$seed = (& curl.exe -k -s -X POST "$base/api/admin/demo/seed-procurement-staging" -H "$auth")
try { Write-Host ("seed     procurement-staging -> " + (($seed | ConvertFrom-Json).status)) } catch { Write-Host "seed     -> $seed" }

'{}' | Set-Content "_empty.json" -Encoding ascii
$cm = (& curl.exe -k -s -X POST "$base/api/data-model-templates/jde_supplier/create-model" -H "$auth" -H "Content-Type: application/json" -d "@_empty.json")
try { $c = ($cm | ConvertFrom-Json); Write-Host ("typeB    create supplier -> " + $c.status + " name=" + $c.data_model.name + " status=" + $c.data_model.status) } catch { Write-Host "typeB    -> $cm" }

$out = (& curl.exe -k -s "$base/api/outbound/supplier?limit=2" -H "$auth")
try { $o = ($out | ConvertFrom-Json); Write-Host ("outbound /api/outbound/supplier -> status=" + $o.status + " count=" + $o.count) } catch { Write-Host "outbound -> $out" }

foreach ($p in "/", "/login", "/migration-jobs", "/jde-demo") {
  Write-Host ("page     $p -> " + (& curl.exe -k -s -o NUL -w "%{http_code}" "$base$p"))
}

# Rotate admin off default; save new password to a local (gitignored) file, NOT to console
$newpw = "Mdp65-" + (Rand 10)
$adminId = $null
try { $adminId = (((& curl.exe -k -s "$base/api/users" -H "$auth") | ConvertFrom-Json) | Where-Object { $_.username -eq 'admin' }).id } catch {}
if ($adminId) {
  ('{"password":"' + $newpw + '"}') | Set-Content "_pw.json" -Encoding ascii
  $rc = (& curl.exe -k -s -o NUL -w "%{http_code}" -X PUT "$base/api/users/$adminId" -H "$auth" -H "Content-Type: application/json" -d "@_pw.json")
  ('{"username":"admin","password":"' + $newpw + '"}') | Set-Content "_newlogin.json" -Encoding ascii
  $nc = (& curl.exe -k -s -o NUL -w "%{http_code}" -X POST "$base/api/auth/login" -H "Content-Type: application/json" -d "@_newlogin.json")
  $oc = (& curl.exe -k -s -o NUL -w "%{http_code}" -X POST "$base/api/auth/login" -H "Content-Type: application/json" -d "@_login.json")
  ("MDP .65:8456 admin login`r`nusername: admin`r`npassword: " + $newpw) | Set-Content "mdp65_admin.txt" -Encoding ascii
  Write-Host ("admin    rotate -> PUT $rc | new login $nc (expect 200) | old admin123 $oc (expect 401) -> password saved to mdp65_admin.txt")
  Remove-Item "_pw.json", "_newlogin.json" -ErrorAction SilentlyContinue
}
else { Write-Host "admin    rotate -> SKIP (no admin id)" }
Remove-Item "_login.json", "_empty.json" -ErrorAction SilentlyContinue
Write-Host "### DONE: MDP PERSISTENT on https://localhost:8456 (project mdp65, restart unless-stopped). Admin password in mdp65_admin.txt ###"
