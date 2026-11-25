function Close-DeployLock {
    param([System.Diagnostics.Process]$Process)

    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $Process.StandardInput.WriteLine('ROLLBACK;')
            $Process.StandardInput.WriteLine('\q')
            $Process.StandardInput.Close()
            if (-not $Process.WaitForExit(5000)) {
                Stop-Process -Id $Process.Id -Force
                throw 'Chiusura della connessione PostgreSQL di deploy non riuscita.'
            }
        }
        if ($Process.ExitCode -ne 0) {
            $details = $Process.StandardError.ReadToEnd().Trim()
            throw "Controllo PostgreSQL di deploy fallito: $details"
        }
    }
    finally {
        $Process.Dispose()
    }
}

function Wait-DeployIdle {
    param([int]$PollSeconds = 10)

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command docker -ErrorAction Stop).Source
    $start.Arguments = 'compose exec -T database sh -c "exec psql -X -q -A -t -v ON_ERROR_STOP=1 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""'
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw 'Avvio del controllo PostgreSQL di deploy fallito.'
    }

    try {
        while ($true) {
            $process.StandardInput.WriteLine('BEGIN;')
            $process.StandardInput.WriteLine("SET LOCAL lock_timeout = '10s';")
            $process.StandardInput.WriteLine('LOCK TABLE script_manager.minion_jobs, script_manager.executions IN SHARE ROW EXCLUSIVE MODE;')
            $process.StandardInput.WriteLine("SELECT (SELECT count(*) FROM script_manager.executions WHERE status IN ('running', 'cancel_requested'))::text || '|' || (SELECT count(*) FROM script_manager.minion_jobs WHERE state = 'active')::text;")
            $process.StandardInput.Flush()
            $line = $process.StandardOutput.ReadLine()
            if ($null -eq $line -or $line -notmatch '\A(\d+)\|(\d+)\z') {
                throw "Risposta PostgreSQL di deploy non valida: $line"
            }
            $running = [long]$Matches[1]
            $active = [long]$Matches[2]
            if ($running -eq 0 -and $active -eq 0) {
                Write-Host 'Nessuna procedura o job attivo: avvio del deploy.'
                return $process
            }
            $process.StandardInput.WriteLine('ROLLBACK;')
            $process.StandardInput.Flush()
            Write-Host "Procedure in corso o in annullamento: $running; job attivi: $active. Nuovo controllo tra $PollSeconds secondi."
            Start-Sleep -Seconds $PollSeconds
        }
    }
    catch {
        Close-DeployLock $process
        throw
    }
}
