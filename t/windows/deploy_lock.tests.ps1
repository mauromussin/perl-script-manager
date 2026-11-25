$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'docker\deploy-lock.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('sm-deploy-test-' + [guid]::NewGuid().ToString('N'))
$oldFile = $env:COMPOSE_FILE
$oldProject = $env:COMPOSE_PROJECT_NAME
$lock = $null
$job = $null
$created = $false

try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $env:COMPOSE_FILE = Join-Path $work 'compose.yaml'
    $env:COMPOSE_PROJECT_NAME = 'smdeploytest' + [guid]::NewGuid().ToString('N')
    @'
services:
  database:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_USER: deploytest
      POSTGRES_PASSWORD: isolated-test-only
      POSTGRES_DB: deploytest
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U deploytest -d deploytest"]
      interval: 1s
      timeout: 2s
      retries: 60
'@ | Set-Content -LiteralPath $env:COMPOSE_FILE -Encoding UTF8
    $created = $true
    & docker compose up -d --wait --wait-timeout 90 database
    if ($LASTEXITCODE -ne 0) { throw 'Avvio PostgreSQL di test fallito.' }
    $setup = "CREATE SCHEMA script_manager; CREATE TABLE script_manager.executions (status text); CREATE TABLE script_manager.minion_jobs (state text); INSERT INTO script_manager.executions VALUES ('running'), ('cancel_requested'); INSERT INTO script_manager.minion_jobs VALUES ('active'), ('inactive');"
    & docker compose exec -T database psql -X -U deploytest -d deploytest -v ON_ERROR_STOP=1 -c $setup
    if ($LASTEXITCODE -ne 0) { throw 'Preparazione delle tabelle di test fallita.' }

    $job = Start-Job -ArgumentList $env:COMPOSE_FILE, $env:COMPOSE_PROJECT_NAME -ScriptBlock {
        param($file, $project)
        $env:COMPOSE_FILE = $file
        $env:COMPOSE_PROJECT_NAME = $project
        & docker compose exec -T database psql -X -U deploytest -d deploytest -v ON_ERROR_STOP=1 -c "SELECT pg_sleep(3); DELETE FROM script_manager.executions; DELETE FROM script_manager.minion_jobs WHERE state = 'active';"
        if ($LASTEXITCODE -ne 0) { throw 'Completamento simulato fallito.' }
    }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lock = Wait-DeployIdle -PollSeconds 1
    $timer.Stop()
    if ($timer.Elapsed.TotalSeconds -lt 2) { throw 'Il deploy non ha atteso le esecuzioni attive.' }
    Wait-Job $job | Out-Null
    Receive-Job $job
    if ($job.State -ne 'Completed') { throw 'Il completamento simulato non e riuscito.' }

    foreach ($sql in @(
        "INSERT INTO script_manager.executions VALUES ('running')",
        "INSERT INTO script_manager.minion_jobs VALUES ('active')",
        "LOCK TABLE script_manager.minion_jobs, script_manager.executions IN SHARE ROW EXCLUSIVE MODE"
    )) {
        $ErrorActionPreference = 'Continue'
        $output = & docker compose exec -T database psql -X -U deploytest -d deploytest -v ON_ERROR_STOP=1 -c "SET lock_timeout = '500ms'; $sql" 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0 -or ($output | Out-String) -notmatch 'lock timeout') {
            throw "Il lock non ha impedito la scrittura come previsto: $sql"
        }
    }
    Close-DeployLock $lock
    $lock = $null
    & docker compose exec -T database psql -X -U deploytest -d deploytest -v ON_ERROR_STOP=1 -c "INSERT INTO script_manager.executions VALUES ('queued');"
    if ($LASTEXITCODE -ne 0) { throw 'Lock non rilasciato dopo lo stop.' }
    $queued = & docker compose exec -T database psql -X -A -t -U deploytest -d deploytest -c "SELECT count(*) FROM script_manager.minion_jobs WHERE state = 'inactive';"
    if ($LASTEXITCODE -ne 0 -or $queued.Trim() -ne '1') { throw 'Job accodato non conservato.' }
    $timer.Restart()
    $lock = Wait-DeployIdle -PollSeconds 1
    $timer.Stop()
    if ($timer.Elapsed.TotalSeconds -ge 10) { throw 'Un job accodato senza esecuzioni attive ha bloccato il deploy.' }
    Close-DeployLock $lock
    $lock = $null
    & docker compose stop database
    if ($LASTEXITCODE -ne 0) { throw 'Arresto PostgreSQL di test fallito.' }
    $failed = $false
    try { $lock = Wait-DeployIdle -PollSeconds 1 }
    catch { $failed = $true }
    if (-not $failed) { throw 'Database indisponibile non ha bloccato il deploy.' }
    Write-Host 'Test deploy lock superati.'
}
finally {
    if ($lock) { Close-DeployLock $lock }
    if ($job) { Remove-Job -Job $job -Force }
    if ($created) {
        & docker compose down --remove-orphans
        if ($LASTEXITCODE -ne 0) { Write-Error 'Pulizia del progetto Compose di test fallita.' }
    }
    $env:COMPOSE_FILE = $oldFile
    $env:COMPOSE_PROJECT_NAME = $oldProject
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
