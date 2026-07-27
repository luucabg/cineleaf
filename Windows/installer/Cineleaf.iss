#ifndef SourceDir
  #error SourceDir must be supplied by the build script.
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by the build script.
#endif
#ifndef ReleaseVersion
  #define ReleaseVersion "0.3.0-beta.1"
#endif
#ifndef DisplayVersion
  #define DisplayVersion "0.3.0 Beta 1"
#endif
#ifndef NumericVersion
  #define NumericVersion "0.3.0.1"
#endif

[Setup]
AppId={{13D98B93-0E26-42F1-A4CA-7DCE509BB689}
AppName=Cineleaf
AppVersion={#NumericVersion}
AppVerName=Cineleaf {#DisplayVersion}
AppPublisher=Cineleaf contributors
AppPublisherURL=https://github.com/luucabg/cineleaf
AppSupportURL=https://github.com/luucabg/cineleaf/issues
DefaultDirName={localappdata}\Programs\Cineleaf
DefaultGroupName=Cineleaf
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Cineleaf-{#ReleaseVersion}-Windows-x64-Setup
SetupIconFile=..\src\Cineleaf.Windows.App\Assets\Cineleaf.ico
UninstallDisplayIcon={app}\Cineleaf.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\LICENSE.txt
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Cineleaf"; Filename: "{app}\Cineleaf.exe"
Name: "{autodesktop}\Cineleaf"; Filename: "{app}\Cineleaf.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Cineleaf.exe"; Description: "{cm:LaunchProgram,Cineleaf}"; Flags: nowait postinstall skipifsilent
