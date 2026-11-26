# Valida um XML contra os schemas oficiais da NF-e (usado pelos testes do motor fiscal).
# Uso: pwsh -File tool/validate-xsd.ps1 -Schema test/fixtures/schemas/PL_010h_v1.03/nfe_v4.00.xsd -Xml nota.xml
# Sai com 0 quando o XML é válido; senão imprime cada erro (linha: mensagem) e sai com 1.
param(
  [Parameter(Mandatory = $true)][string]$Schema,
  [Parameter(Mandatory = $true)][string]$Xml
)
$ErrorActionPreference = 'Stop'
$errors = New-Object System.Collections.Generic.List[string]
$set = New-Object System.Xml.Schema.XmlSchemaSet
$set.XmlResolver = New-Object System.Xml.XmlUrlResolver
$readerSettings = New-Object System.Xml.XmlReaderSettings
$readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Parse
$schemaReader = [System.Xml.XmlReader]::Create((Resolve-Path $Schema).Path, $readerSettings)
[void]$set.Add('http://www.portalfiscal.inf.br/nfe', $schemaReader)
$set.Compile()
$settings = New-Object System.Xml.XmlReaderSettings
$settings.ValidationType = [System.Xml.ValidationType]::Schema
$settings.Schemas = $set
$settings.add_ValidationEventHandler({ param($sender, $e) $errors.Add("$($e.Exception.LineNumber):$($e.Exception.LinePosition): $($e.Message)") })
$reader = [System.Xml.XmlReader]::Create((Resolve-Path $Xml).Path, $settings)
try { while ($reader.Read()) { } } finally { $reader.Close() }
if ($errors.Count -gt 0) {
  $errors | ForEach-Object { Write-Output $_ }
  exit 1
}
Write-Output 'valido'
