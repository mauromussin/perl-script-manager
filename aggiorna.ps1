[CmdletBinding()]
param(
    [string]$ArtifactZip
)

$ErrorActionPreference = 'Stop'
$extraction = $null
$previousImage = $env:APP_IMAGE
. (Join-Path $PSScriptRoot 'docker\deploy-lock.ps1')

function Invoke-Docker {
    & docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "Comando docker fallito (codice $LASTEXITCODE): docker $($args -join ' ')"
    }
}

try {
    if ((Get-Location).Path -ne $PSScriptRoot) {
        throw 'Eseguire questo script dalla root di perl-script-manager.'
    }
    if (-not (Test-Path -LiteralPath '.\compose.yaml' -PathType Leaf)) {
        throw 'compose.yaml non trovato.'
    }
    if (-not $ArtifactZip) {
        $downloads = Join-Path $env:USERPROFILE 'Downloads'
        $latest = Get-ChildItem -LiteralPath $downloads -Filter 'perl-script-manager*.zip' -File |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) {
            throw "Nessun artifact perl-script-manager*.zip trovato in $downloads."
        }
        $ArtifactZip = $latest.FullName
    }
    $zip = Get-Item -LiteralPath $ArtifactZip
    if ($zip.PSIsContainer -or $zip.Extension -ne '.zip') {
        throw 'Specificare un file ZIP di artifact.'
    }
    Write-Host "Artifact selezionato: $($zip.FullName)"
    Get-Command docker -ErrorAction Stop | Out-Null
    $env:APP_IMAGE = 'perl-script-manager:production'
    Invoke-Docker info --format '{{.ServerVersion}}'
    Invoke-Docker compose config --quiet

    $extraction = Join-Path ([System.IO.Path]::GetTempPath()) ('script-manager-' + [guid]::NewGuid())
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $extraction
    $tar = Join-Path $extraction 'perl-script-manager.tar'
    $checksum = "$tar.sha256"
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf) -or
        -not (Test-Path -LiteralPath $checksum -PathType Leaf)) {
        throw 'Artifact incompleto: mancano il TAR o il relativo checksum SHA256.'
    }
    $expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $tar -Algorithm SHA256).Hash
    if ($expected -notmatch '\A[0-9a-fA-F]{64}\z' -or $actual -ne $expected) {
        throw 'Checksum immagine non valido: importazione annullata.'
    }
    Invoke-Docker load --input $tar
    $deployLock = Wait-DeployIdle
    try {
        if ($deployLock.HasExited) {
            throw 'Connessione PostgreSQL di deploy interrotta prima dello stop.'
        }
        Invoke-Docker compose stop app worker
        if ($deployLock.HasExited) {
            throw 'Connessione PostgreSQL di deploy interrotta durante lo stop: verificare le esecuzioni.'
        }
    }
    finally {
        Close-DeployLock $deployLock
    }
    Invoke-Docker compose up -d --no-deps --no-build --pull never --wait --wait-timeout 60 app worker
    Invoke-Docker compose ps app worker
    Write-Host 'Aggiornamento completato.'
}
finally {
    $env:APP_IMAGE = $previousImage
    if ($extraction -and (Test-Path -LiteralPath $extraction)) {
        Remove-Item -LiteralPath $extraction -Recurse -Force
    }
}
