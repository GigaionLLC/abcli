; Copyright 2026 Gigaion, LLC
; SPDX-License-Identifier: AGPL-3.0-or-later
;
; abgui Windows installer (Inno Setup 6).
;
; Built by ../../../scripts/build-gui-flutter.sh windows-installer, and by CI's
; gui-flutter-windows job, with the same command:
;
;   ISCC /DAppVersion=<x.y.z> [/DSourceDir=<abs path to Release>] [/O<outdir>] abgui.iss
;
; -> abgui-setup-x64.exe. It packages the FLUTTER BUILD OUTPUT, not the source tree, so
; `build-gui-flutter.sh windows` must have run first — that is the step that copies the
; embedded abctl.exe next to abgui.exe, and an installer without it produces an app that
; launches and then cannot do anything (AbctlLocator throws AbctlMissingBinary on the
; first command). The #error guards below make that a COMPILE failure instead.
;
; Per-user by default (no UAC): %LOCALAPPDATA%\Programs\abgui. The Microsoft Store's
; validation looks for a MACHINE-WIDE Add/Remove Programs entry, so a Store install passes
; /ALLUSERS and lands in Program Files with a UAC prompt — which is allowed for Store
; installs; only the installer's own UI has to be silent.
;
; abgui's own data (%LOCALAPPDATA%\abgui: keys\, logs\) and the user's GitOps workspace are
; OUTSIDE {app} and are never touched by install or uninstall. See [Code] — that is a
; deliberate divergence from the sibling Airclone installer, not an omission.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

; Default source = `flutter build windows --release` output, resolved from THIS script's
; directory rather than the compiler's working directory: ISCC is invoked from the repo
; root by the build script and from app/ by CI, and a CWD-relative default silently
; resolves to nothing in one of them. Anchoring on SourcePath means an override is
; expected to be absolute, which is also what the guards below assume.
#ifndef SourceDir
  #define SourceDir AddBackslash(SourcePath) + "..\..\build\windows\x64\runner\Release"
#endif

#define AppName "abgui"
#define AppPublisher "Gigaion, LLC"
#define AppExeName "abgui.exe"
#define AppCliName "abctl.exe"
#define AppUrl "https://github.com/GigaionLLC/abcli"

; HARD GATE, at compile time. Both of these have a failure mode that only shows up on a
; user's machine: a missing abgui.exe means SourceDir pointed somewhere stale and the
; installer ships a directory of DLLs with no app, and a missing abctl.exe ships a GUI
; that cannot run a single command. Neither makes ISCC fail on its own — `Source: "...\*"`
; over a wrong-but-existing directory compiles happily — so assert them here.
#if !FileExists(AddBackslash(SourceDir) + AppExeName)
  #error abgui.exe is not in SourceDir. Run "scripts/build-gui-flutter.sh windows" first (or pass /DSourceDir=<abs path to the Release dir>).
#endif
#if !FileExists(AddBackslash(SourceDir) + AppCliName)
  #error abctl.exe is not in SourceDir. The GUI is a facade over the CLI and is useless without it; "scripts/build-gui-flutter.sh windows" is what copies it there.
#endif

[Setup]
; Stable AppId — NEVER change it. Upgrade detection and the uninstall registry key are
; both derived from this GUID, so a new one turns every future release into a SECOND
; installed copy rather than an upgrade. The doubled brace escapes to a literal "{...}".
AppId={{4346463C-B589-4E09-B189-094A56D59702}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
; Per-user by default (no admin). The Store passes /ALLUSERS for a per-machine install so
; its package validation finds the HKLM Add/Remove Programs entry; a per-user install
; writes that entry to HKCU, where validation cannot see it and reports the product as
; not registered.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline dialog
; {autopf} = Program Files under /ALLUSERS, else {localappdata}\Programs — so the default
; double-click install stays UAC-free and the Store install is machine-wide.
DefaultDirName={autopf}\abgui
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir=.
OutputBaseFilename=abgui-setup-x64
SetupIconFile=..\runner\resources\app_icon.ico
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Flutter's Windows embedder needs Windows 10 or newer; an older host fails at load with a
; missing-entry-point error that blames a DLL rather than the OS version.
MinVersion=10.0
; `force`, not `yes`: close a running abgui — and any abctl.exe still holding a file under
; {app} — WITHOUT prompting. A prompt is invisible during a silent (Store) install, and an
; un-closed process leaves undeletable files in {app}, which is the clean-removal failure
; the [Code] section below exists to prevent.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Release tree in one line: abgui.exe, the embedded abctl.exe, flutter_windows.dll,
; every plugin DLL, and data\ (flutter_assets, icudtl.dat). Enumerating them individually
; would break the day a plugin is added — the Flutter bundle's contents are not ours to
; predict — and `data\` MUST land as a sibling of the exe or the engine cannot find
; icudtl.dat and the app exits before showing a window.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; CLEAN REMOVAL. Inno only deletes what it logged at install time, so anything that appears
; in {app} afterwards survives an uninstall — and "files left in C:\Program Files\<app>" is
; a Microsoft Store certification failure (policy 10.2.7), not a cosmetic one. Sweep the
; whole install directory so nothing can survive whatever put it there. The running
; uninstaller's own unins000.* are locked and skipped here; Inno's normal self-delete
; removes them and then the now-empty directory.
; {app} ONLY — user data lives outside it and is deliberately never removed (see [Code]).
Type: filesandordirs; Name: "{app}"

[Code]
// Terminate anything still running FROM the install directory, BEFORE the uninstaller
// starts deleting.
//
// CloseApplications=force is a SETUP-time feature: uninstall performs no Restart Manager
// check at all, so a running abgui.exe — or an abctl.exe mid-sync — makes its own file
// undeletable ("Failed to delete the file; it may be in use (32)" then "Failed to delete
// directory (145)"), and the leftovers are exactly the 10.2.7 failure. [UninstallDelete]
// cannot help: a sweep still cannot delete a LOCKED file. The only fix is to end the
// processes first.
//
// Scoped to {app} BY PATH, never by image name. abctl is a general-purpose CLI that a
// fleet admin may well be running from their own PATH in another window — killing it
// would abort a live `abctl sync --apply` against a production tenant, which is the worst
// thing this installer could possibly do. Only processes whose ExecutablePath is under
// {app} are ours to end.
//
// Best-effort: PowerShell exists on every supported Windows and `-Command` is not subject
// to script ExecutionPolicy. Nothing here may block the uninstall.
procedure TerminateProcessesInAppDir;
var
  Params: String;
  ResultCode: Integer;
begin
  // The `unins*` exclusion is NOT optional. Inno uninstalls in two phases: {app}\unins000.exe
  // launches a copy of itself from %TEMP% and WAITS for it. This code runs in that second
  // phase, so an unfiltered "kill everything under {app}" kills the first-phase process that
  // is waiting on us — the uninstall still completes, but the process tree returns -1 instead
  // of 0, which any exit-code mapping (the Store's included) reads as a failed uninstall.
  Params :=
    '-NoProfile -NonInteractive -Command "' +
    'Get-CimInstance Win32_Process | ' +
    'Where-Object { $_.ExecutablePath -like ''' + ExpandConstant('{app}') + '\*'' ' +
    '-and $_.Name -notlike ''unins*'' } | ' +
    'ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"';
  if Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    // Handles are released asynchronously after a process dies; give the kernel a moment
    // before the first delete attempt or the sweep races it and loses.
    Sleep(750);
end;

function InitializeUninstall(): Boolean;
begin
  TerminateProcessesInAppDir;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // Last line of defence for clean removal: if anything is still in {app} — a file that
    // was locked on the first pass and has since been released, or something dropped there
    // after install — take it out now. The running unins000.* are still locked and are
    // skipped; Inno's own self-delete removes them plus the directory immediately after.
    if DirExists(ExpandConstant('{app}')) then
    begin
      TerminateProcessesInAppDir;
      DelTree(ExpandConstant('{app}\*'), False, True, True);
    end;
    // NO user-data removal, and no prompt offering one. The sibling Airclone installer
    // offers to delete its app-support tree on uninstall; that is WRONG for abgui and the
    // difference is not stylistic:
    //
    //   %LOCALAPPDATA%\abgui\keys  holds the Apple Business API private key, which Apple
    //     lets you download EXACTLY ONCE. Deleting it — even behind a confirmation, even
    //     behind a checkbox somebody clicks through at 5pm — destroys credentials that
    //     cannot be regenerated, only replaced by minting a new API key in Apple Business
    //     Manager and re-authorising it.
    //   %LOCALAPPDATA%\abgui\logs  is the run-log transcript: the record of which tenant
    //     operations ran, when, and with what argv. That is audit evidence for a tool
    //     whose whole risk surface is `sync --apply --prune`.
    //
    // Neither is in {app}, so neither blocks clean removal (policy 10.2.7 is about the
    // PRODUCT's files). Leaving them costs a few MB on a machine the user still owns;
    // removing them costs an unrecoverable key. Uninstalling is not consent to that.
  end;
end;
