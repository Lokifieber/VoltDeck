[Setup]
AppId={{4F46BE2F-DB48-45C0-8FE9-D84188346610}
AppName=VoltDeck
AppVersion={#ReleaseVersion}
AppVerName=VoltDeck {#ReleaseVersion} (Early Access)
AppPublisher=Lokicraft
DefaultDirName={localappdata}\Programs\VoltDeck
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
MinVersion=10.0
SetupIconFile=..\assets\VoltDeck.ico
UninstallDisplayIcon={app}\VoltDeck.exe
VersionInfoCompany=Lokicraft
VersionInfoDescription=VoltDeck Early Access Setup
VersionInfoVersion={#NumericVersion}
VersionInfoProductName=VoltDeck
WizardStyle=modern dynamic
OutputBaseFilename=VoltDeck-{#ReleaseVersion}-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "..\target\release\VoltDeck.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\VoltDeck"; Filename: "{app}\VoltDeck.exe"; AppUserModelID: "LokiFieber.VoltDeck"
Name: "{autodesktop}\VoltDeck"; Filename: "{app}\VoltDeck.exe"; Tasks: desktopicon; AppUserModelID: "LokiFieber.VoltDeck"

[Run]
Filename: "{app}\VoltDeck.exe"; Description: "{cm:LaunchProgram,VoltDeck}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Verb: String;
  Command: String;
begin
  if CurUninstallStep = usUninstall then begin
    Verb := 'Software\Classes\DesktopBackground\Shell\DriverToolBoost';
    if RegQueryStringValue(HKCU, Verb + '\command', '', Command) and
       (CompareText(Command, '"' + ExpandConstant('{app}\VoltDeck.exe') + '" --boost') = 0) then
      RegDeleteKeyIncludingSubkeys(HKCU, Verb);
  end;
end;
