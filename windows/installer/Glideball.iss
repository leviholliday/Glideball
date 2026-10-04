; Inno Setup script for Glideball for Windows.
; Built by .github/workflows/windows.yml:
;   iscc /DAppVersion=1.0.0 /DSourceExe=..\out\win-x64\Glideball.exe /DArch=x64 Glideball.iss
; Installs per user (no administrator rights), like the app itself runs.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\out\win-x64\Glideball.exe"
#endif
#ifndef Arch
  #define Arch "x64"
#endif

[Setup]
AppId={{6B2E4A51-3C1D-4E8F-9A7B-1C2D3E4F5A60}
AppName=Glideball
AppVersion={#AppVersion}
AppPublisher=Levi Holliday
AppPublisherURL=https://glideball.netlify.app
DefaultDirName={localappdata}\Programs\Glideball
DefaultGroupName=Glideball
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\out
OutputBaseFilename=Glideball-Setup-{#Arch}
SetupIconFile=..\src\Glideball\Assets\Glideball.ico
UninstallDisplayIcon={app}\Glideball.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
#endif

[Tasks]
Name: "startup"; Description: "Start Glideball when I sign in"; GroupDescription: "Options:"

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Glideball"; Filename: "{app}\Glideball.exe"

[Registry]
; Start with Windows (the same value the app's own switch writes).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Glideball"; ValueData: """{app}\Glideball.exe"" --background"; Tasks: startup; Flags: uninsdeletevalue
; Double-click a .glide-settings file to import it.
Root: HKCU; Subkey: "Software\Classes\.glide-settings"; ValueType: string; ValueData: "Glideball.Settings"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Glideball.Settings"; ValueType: string; ValueData: "Glideball Settings"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Glideball.Settings\DefaultIcon"; ValueType: string; ValueData: "{app}\Glideball.exe,0"
Root: HKCU; Subkey: "Software\Classes\Glideball.Settings\shell\open\command"; ValueType: string; ValueData: """{app}\Glideball.exe"" ""%1"""

[Run]
Filename: "{app}\Glideball.exe"; Description: "Open Glideball"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM Glideball.exe /F"; Flags: runhidden; RunOnceId: "StopGlideball"
