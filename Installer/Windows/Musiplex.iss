; Musiplex for Windows installer: pick Musiplex, Workload, or both.
; Built by GitHub Actions (.github/workflows/release.yml) with Inno Setup:
;   iscc /DAppVersion=2.3 Installer\Windows\Musiplex.iss
; Installs for this user only (no admin prompt). Nothing personal is built in.

#ifndef AppVersion
  #define AppVersion "0.0"
#endif
#define Dist "..\..\dist"

[Setup]
AppId={{6F7A2B9C-41D8-4E3A-9B0C-5D1E8F2A7C63}
AppName=Musiplex
AppVersion={#AppVersion}
AppPublisher=Musiplex
AppPublisherURL=https://github.com/Mozaix/Musiplex
DefaultDirName={localappdata}\Musiplex Apps
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#Dist}
OutputBaseFilename=Musiplex-{#AppVersion}-Windows-Setup
SetupIconFile=musiplex.ico
UninstallDisplayIcon={localappdata}\Musiplex\Musiplex.exe
UninstallDisplayName=Musiplex
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Types]
Name: "full"; Description: "Musiplex and Workload"
Name: "musiplex"; Description: "Musiplex only"
#ifexist "..\..\dist\Workload.exe"
Name: "workload"; Description: "Workload only"
#endif
Name: "custom"; Description: "Choose"; Flags: iscustom

[Components]
Name: "musiplex"; Description: "Musiplex — your music: library, player, notch, mini player and the server for your phones"; Types: full musiplex
#ifexist "..\..\dist\Workload.exe"
Name: "workload"; Description: "Workload — school tasks and deadlines, synced through Musiplex"; Types: full workload
#endif

[Tasks]
Name: "startup"; Description: "Start Musiplex when Windows starts (plays to your phones even before you open it)"; Components: musiplex

[Files]
Source: "{#Dist}\Musiplex.exe"; DestDir: "{localappdata}\Musiplex"; Components: musiplex; Flags: ignoreversion
#ifexist "..\..\dist\Workload.exe"
Source: "{#Dist}\Workload.exe"; DestDir: "{localappdata}\Workload"; Components: workload; Flags: ignoreversion
#endif

[Icons]
Name: "{userprograms}\Musiplex"; Filename: "{localappdata}\Musiplex\Musiplex.exe"; Components: musiplex
#ifexist "..\..\dist\Workload.exe"
Name: "{userprograms}\Workload"; Filename: "{localappdata}\Workload\Workload.exe"; Components: workload
#endif

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Musiplex"; ValueData: """{localappdata}\Musiplex\Musiplex.exe"" --background"; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{localappdata}\Musiplex\Musiplex.exe"; Description: "Open Musiplex"; Components: musiplex; Flags: postinstall nowait skipifsilent
#ifexist "..\..\dist\Workload.exe"
Filename: "{localappdata}\Workload\Workload.exe"; Description: "Open Workload"; Components: workload; Flags: postinstall nowait skipifsilent unchecked
#endif

[UninstallRun]
Filename: "{localappdata}\Musiplex\Musiplex.exe"; Parameters: "--uninstall"; Components: musiplex; RunOnceId: "MusiplexUninstall"; Flags: runhidden waituntilterminated
#ifexist "..\..\dist\Workload.exe"
Filename: "{localappdata}\Workload\Workload.exe"; Parameters: "--uninstall"; Components: workload; RunOnceId: "WorkloadUninstall"; Flags: runhidden waituntilterminated
#endif

[UninstallDelete]
Type: files; Name: "{userprograms}\Musiplex.lnk"
Type: files; Name: "{userprograms}\Workload.lnk"
