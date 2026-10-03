#ifndef PackageVersion
  #error PackageVersion must be provided
#endif
#ifndef PackageArch
  #error PackageArch must be provided
#endif
#ifndef SourceDir
  #error SourceDir must be provided
#endif
#ifndef OutputDir
  #error OutputDir must be provided
#endif
#ifndef IconFile
  #error IconFile must be provided
#endif

[Setup]
AppId=ConsoleViewCompatibility
AppName=Console View
AppVersion={#PackageVersion}
AppPublisher=El Qorchi Ismail
AppPublisherURL=https://github.com/smailkorchi/console-view
AppSupportURL=https://github.com/smailkorchi/console-view/issues
DefaultDirName={localappdata}\Programs\Console View
DefaultGroupName=Console View
PrivilegesRequired=lowest
MinVersion=10.0
#if PackageArch == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesAllowed=x86compatible
#endif
OutputDir={#OutputDir}
OutputBaseFilename=Console-View-{#PackageVersion}-Windows-{#PackageArch}-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\consoleview.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\LICENSE.txt
InfoBeforeFile={#SourceDir}\THIRD-PARTY-NOTICES.txt

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Console View"; Filename: "{app}\consoleview.exe"

[Run]
Filename: "{app}\consoleview.exe"; Description: "Open Console View"; Flags: nowait postinstall skipifsilent
