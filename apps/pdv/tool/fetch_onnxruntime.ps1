# Baixa o ONNX Runtime (motor que roda os modelos do rosto) do pacote oficial da Microsoft no NuGet,
# confere o SHA-512 publicado e extrai só o que o PDV no Windows usa: a DLL, o .lib e os cabeçalhos.
# Fica em apps/pdv/third_party/onnxruntime (fora do Git). O build do Windows usa essa cópia.
# Uso: powershell -ExecutionPolicy Bypass -File tool/fetch_onnxruntime.ps1
$ErrorActionPreference = 'Stop'

$version = '1.32.0'
# SHA-512 publicado pelo NuGet para esta versão (catálogo do nuget.org).
$expectedHash = 'fj2P9s5o2s5MvwwdDiCF4frwXUJed1gLh1wb0igCUnonbrvfoHMmAFtaj9atgYbBflcQtE3FQ6zGv/s75FQEsQ=='
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$version/microsoft.ml.onnxruntime.$version.nupkg"

$root = Join-Path (Split-Path $PSScriptRoot -Parent) 'third_party\onnxruntime'
$marker = Join-Path $root "VERSION"
if ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $version)) {
  Write-Host "ONNX Runtime $version já está em $root."
  exit 0
}

$package = Join-Path ([System.IO.Path]::GetTempPath()) "onnxruntime.$version.nupkg"
try {
  Write-Host "Baixando o ONNX Runtime $version do NuGet..."
  Invoke-WebRequest -Uri $url -OutFile $package -UseBasicParsing

  $sha = [System.Security.Cryptography.SHA512]::Create()
  $stream = [System.IO.File]::OpenRead($package)
  try { $hash = [Convert]::ToBase64String($sha.ComputeHash($stream)) } finally { $stream.Dispose() }
  if ($hash -ne $expectedHash) { throw "O pacote baixado não confere com o SHA-512 publicado pelo NuGet." }

  if (Test-Path $root) { Remove-Item -Recurse -Force $root }
  New-Item -ItemType Directory -Force (Join-Path $root 'include') | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $root 'lib') | Out-Null

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($package)
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName
      $target = $null
      if ($name -like 'build/native/include/*' -and $entry.Name) { $target = Join-Path $root "include\$($entry.Name)" }
      elseif ($name -eq 'runtimes/win-x64/native/onnxruntime.dll') { $target = Join-Path $root 'lib\onnxruntime.dll' }
      elseif ($name -eq 'runtimes/win-x64/native/onnxruntime.lib') { $target = Join-Path $root 'lib\onnxruntime.lib' }
      elseif ($name -eq 'LICENSE' -or $name -eq 'LICENSE.txt' -or $name -eq 'ThirdPartyNotices.txt') { $target = Join-Path $root $entry.Name }
      if ($target) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true) }
    }
  } finally { $zip.Dispose() }

  if (-not (Test-Path (Join-Path $root 'lib\onnxruntime.dll'))) { throw 'A DLL do ONNX Runtime não veio no pacote.' }
  Set-Content -Path $marker -Value $version -Encoding ascii
  Write-Host "ONNX Runtime $version pronto em $root."
} finally {
  if (Test-Path $package) { Remove-Item -Force $package }
}
