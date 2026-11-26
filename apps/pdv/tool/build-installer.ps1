# Gera o instalador do FarmaERP PDV para Windows.
# Uso (em apps/pdv):
#   powershell -ExecutionPolicy Bypass -File tool/build-installer.ps1 -Version 1.2.3 `
#     -ApiUrl https://farmaerp-hom-api.b6nhiy.easypanel.host -AppEnv homologation
# Resultado: build\installer\FarmaERP-PDV-Setup-1.2.3.exe
# Precisa do Inno Setup 6 (ISCC.exe). No CI do GitHub (windows-latest) ele já vem instalado.
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$ApiUrl,
  [ValidateSet('development', 'homologation', 'production')][string]$AppEnv = 'homologation',
  # Chaves públicas de assinatura, separadas por vírgula. Sem valor, valem as do código.
  [string]$UpdateKeys = ''
)
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}$') { throw "Versão inválida: use 1.2.3 (recebido: $Version)." }
if ($AppEnv -ne 'development' -and $ApiUrl -notmatch '^https://') { throw 'Fora do desenvolvimento, a API precisa ser HTTPS.' }

$root = Split-Path $PSScriptRoot -Parent
$iscc = @(
  (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 não encontrado (ISCC.exe). Instale pelo site oficial: https://jrsoftware.org/isdl.php' }

Push-Location $root
try {
  & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fetch_onnxruntime.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar o ONNX Runtime.' }

  $parts = $Version.Split('.') | ForEach-Object { [int]$_ }
  $buildNumber = $parts[0] * 1000000 + $parts[1] * 1000 + $parts[2]
  $defines = @(
    "--dart-define=APP_VERSION=$Version",
    "--dart-define=API_URL=$ApiUrl",
    "--dart-define=APP_ENV=$AppEnv"
  )
  if ($UpdateKeys) { $defines += "--dart-define=UPDATE_PUBLIC_KEYS=$UpdateKeys" }
  flutter build windows --release --build-name $Version --build-number $buildNumber @defines
  if ($LASTEXITCODE -ne 0) { throw 'Falha no build do Windows.' }

  $source = Join-Path $root 'build\windows\x64\runner\Release'
  $output = Join-Path $root 'build\installer'
  New-Item -ItemType Directory -Force $output | Out-Null
  & $iscc "/DAppVersion=$Version" "/DSourceDir=$source" "/DOutputDir=$output" (Join-Path $root 'installer\farmaerp-pdv.iss')
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao gerar o instalador.' }
  Write-Host "Instalador: $(Join-Path $output "FarmaERP-PDV-Setup-$Version.exe")"
} finally {
  Pop-Location
}
