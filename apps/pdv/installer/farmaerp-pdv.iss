; Instalador do FarmaERP PDV para Windows (Inno Setup 6).
; Gerado por tool/build-installer.ps1, que passa a versão e as pastas:
;   ISCC /DAppVersion=1.2.3 /DSourceDir=...\Release /DOutputDir=...\installer farmaerp-pdv.iss
;
; - Instala por usuário (%LOCALAPPDATA%\Programs\FarmaERP PDV), sem pedir administrador: é o que
;   permite a atualização automática silenciosa.
; - Guarda uma cópia de si mesmo em {app}\installer: é com ela que o PDV volta para esta versão se a
;   próxima falhar.
; - Os dados do PDV (banco local, chave do terminal) ficam em %APPDATA% e não são apagados na
;   desinstalação nem na atualização.

#ifndef AppVersion
  #error Informe a versão: /DAppVersion=1.2.3
#endif
#ifndef SourceDir
  #error Informe a pasta do build: /DSourceDir=...
#endif
#ifndef OutputDir
  #define OutputDir "..\build\installer"
#endif

[Setup]
; Identificador fixo: nunca mude, é o que faz a nova versão substituir a anterior.
AppId={{220A7BDC-ACA9-471C-BD9E-2A4D20653878}
AppName=FarmaERP PDV
AppVersion={#AppVersion}
AppVerName=FarmaERP PDV {#AppVersion}
AppPublisher=FarmaERP
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\FarmaERP PDV
DefaultGroupName=FarmaERP PDV
PrivilegesRequired=lowest
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=FarmaERP-PDV-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\farmaerp_pdv.exe
UninstallDisplayName=FarmaERP PDV
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
; Assinatura do instalador (Authenticode): quando houver certificado, configure o SignTool no CI.
; SignTool=farmaerp

[Languages]
Name: "ptbr"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "Criar um atalho na área de trabalho"; GroupDescription: "Atalhos:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Cópia deste instalador, para o PDV voltar a esta versão se a próxima falhar.
Source: "{srcexe}"; DestDir: "{app}\installer"; DestName: "FarmaERP-PDV-Setup.exe"; Flags: external ignoreversion

[Icons]
Name: "{group}\FarmaERP PDV"; Filename: "{app}\farmaerp_pdv.exe"
Name: "{userdesktop}\FarmaERP PDV"; Filename: "{app}\farmaerp_pdv.exe"; Tasks: desktopicon

[Run]
; Também roda na instalação silenciosa da atualização: o PDV reabre sozinho.
Filename: "{app}\farmaerp_pdv.exe"; Description: "Abrir o FarmaERP PDV"; Flags: nowait postinstall

[UninstallDelete]
Type: filesandordirs; Name: "{app}\installer"
