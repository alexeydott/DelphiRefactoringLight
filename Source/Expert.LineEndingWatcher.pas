(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Expert.LineEndingWatcher;

// "Delphi kommt nicht damit klar, wenn nicht das volle Windows Zeilenende
// verwendet wird, insbesondere wenn verschiedene in der Datei vorkommen"
// (user request, 2026-10-15). The project check "Debug consistency" has
// reported such files for a while - but only when someone runs it, and by
// then the unit has usually been edited already. The moment that matters is
// the OPEN: nothing has been typed yet, so the file on disk can simply be
// rewritten and re-read.
//
// So: IOTAIDENotifier -> ofnFileOpened -> warn, and offer to fix. Plus the
// two "do not ask me again" answers the user asked for - always in this
// session, or always (saved in the options).
//
// THE RULES THIS UNIT FOLLOWS, each one written down in CLAUDE.md after it
// was learned the hard way:
//  * A NOTIFIER UPDATES STATE ONLY. ofnFileOpened arrives inside the IDE's
//    own open transaction; a modal dialog there lands in the middle of it
//    (the unit-rename watcher's modal-box trap). The file name is parked
//    and a plain WM_TIMER tick does the talking.
//  * The fix REWRITES BYTES, so it must never reach a binary form file or
//    a shipped RTL/VCL source: LineEndingCheckCandidate (extension),
//    LooksBinaryContent (content) and the BDS root are three separate
//    gates.
//  * A file is reported once per session once the user has ANSWERED - but
//    Cancel is not an answer. It changes nothing and decides nothing, so
//    the next open asks again; "Leave it" is the answer that silences the
//    file (user, 2026-10-15). What each answer means lives in ONE pure
//    place, Expert.DebugConsistency.LineEndingChoiceEffect.
//  * The conversion is a DISK write plus Module.Refresh, which is only
//    honest while the buffer is unmodified. A modified buffer is named
//    instead of being overwritten.

interface

/// <summary>Adds the IOTAIDENotifier and starts the deferred tick.</summary>
procedure InstallLineEndingWatcher;

/// <summary>Removes both. MANDATORY before the BPL unloads.</summary>
procedure UninstallLineEndingWatcher;

/// <summary>One line for the status window: what the check is doing and
///  what it has done in this session.</summary>
function LineEndingWatcherStatus: string;

/// <summary>True while "fix without asking" is on for this session only
///  (the saved setting is TPluginSettings.LineEndingAutoFix).</summary>
function LineEndingFixAlwaysThisSession: Boolean;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  System.StrUtils, Vcl.ExtCtrls, Vcl.Forms, ToolsAPI,
  Expert.DebugConsistency, Expert.DialogHelper, Expert.EditorHelperIntf,
  Expert.PluginSettings, Expert.UnitIndex;

type
  /// <summary>IDE-global file notifier. Does nothing but remember the
  ///  file - see the header: no windows from a notifier.</summary>
  TLineEndingIdeNotifier = class(TNotifierObject, IOTANotifier, IOTAIDENotifier)
  public
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

  TPendingFile = record
    FileName: string;
    Info: TLineEndingInfo;
  end;

  /// <summary>Owns the timer's method pointer - OnTimer needs a method,
  ///  and a plain procedure cannot be one.</summary>
  TTickHandler = class(TObject)
  public
    procedure DoTick(Sender: TObject);
  end;

var
  GNotifier: IOTAIDENotifier;
  GNotifierIndex: Integer = -1;
  GTimer: TTimer;
  GPending: TStringList;             // files the notifier has seen
  GReported: TDictionary<string, Boolean>;
  GBusy: Boolean;                    // our own dialog is up
  GSessionAlways: Boolean;           // "always in this session"
  GChecked: Integer;
  GFixed: Integer;
  GFailed: Integer;
  GTicker: TTickHandler;

{ TLineEndingIdeNotifier }

procedure TLineEndingIdeNotifier.FileNotification(
  NotifyCode: TOTAFileNotification; const FileName: string;
  var Cancel: Boolean);
begin
  if NotifyCode <> ofnFileOpened then Exit;
  if (GPending = nil) or (GTimer = nil) then Exit;
  if not TPluginSettings.LineEndingCheck then Exit;
  if not LineEndingCheckCandidate(FileName) then Exit;
  // STATE ONLY. The tick below reads the file and opens the dialog.
  if GPending.IndexOf(FileName) < 0 then
    GPending.Add(FileName);
  GTimer.Enabled := True;
end;

procedure TLineEndingIdeNotifier.BeforeCompile(const Project: IOTAProject;
  var Cancel: Boolean);
begin
  // not needed
end;

procedure TLineEndingIdeNotifier.AfterCompile(Succeeded: Boolean);
begin
  // not needed
end;

// ---------------------------------------------------------------------------
//  the checks that decide whether a file may be touched at all
// ---------------------------------------------------------------------------

function UnderBdsRoot(const AFileName: string): Boolean;
var
  Root: string;
begin
  Root := FindBdsRoot;
  Result := (Root <> '') and
    AFileName.ToLower.StartsWith(IncludeTrailingPathDelimiter(Root).ToLower);
end;

function IsReadOnlyFile(const AFileName: string): Boolean;
var
  Attr: Integer;
begin
  Attr := FileGetAttr(AFileName);
  Result := (Attr >= 0) and ((Attr and faReadOnly) <> 0);
end;

/// <summary>The file's line-ending verdict, or NeedsFix = False for
///  everything we must not touch.</summary>
function Examine(const AFileName: string; out AInfo: TLineEndingInfo): Boolean;
var
  Bytes: TBytes;
begin
  AInfo := Default(TLineEndingInfo);
  Result := False;
  if not TFile.Exists(AFileName) then Exit;
  // Never offer to rewrite a shipped RTL/VCL source: the user opened it by
  // Ctrl+click, it is not theirs to convert, and it is usually read-only.
  if UnderBdsRoot(AFileName) then Exit;
  if IsReadOnlyFile(AFileName) then Exit;
  try
    Bytes := TFile.ReadAllBytes(AFileName);
  except
    Exit;
  end;
  if LooksBinaryContent(Bytes) then Exit;
  AInfo := ClassifyLineEndings(Bytes);
  Result := AInfo.NeedsFix;
end;

// ---------------------------------------------------------------------------
//  the fix
// ---------------------------------------------------------------------------

function ModuleIsModified(const AFileName: string): Boolean;
var
  Services: IOTAModuleServices;
  Module: IOTAModule;
  I: Integer;
  Editor: IOTAEditor;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTAModuleServices, Services) then Exit;
  try
    Module := Services.FindModule(AFileName);
    if Module = nil then Exit;
    for I := 0 to Module.GetModuleFileCount - 1 do
    begin
      Editor := Module.GetModuleFileEditor(I);
      if (Editor <> nil) and SameText(Editor.FileName, AFileName) and
         Editor.Modified then
        Exit(True);
    end;
  except
    // a module can be mid-construction - then we simply do not fix it
    Result := True;
  end;
end;

/// <summary>Converts one file and makes the IDE re-read it. AWhy says what
///  stopped it.</summary>
function FixOne(const AFileName: string; out AWhy: string): Boolean;
begin
  AWhy := '';
  Result := False;
  // The conversion writes the FILE; a buffer with unsaved edits would be
  // written over it by the next Ctrl+S (or lost by the refresh), so the
  // answer here is to say so, not to guess.
  if ModuleIsModified(AFileName) then
  begin
    AWhy := 'the editor has unsaved changes - save it first, then reopen it';
    Exit;
  end;
  if not ConvertFileToCrLf(AFileName) then
  begin
    AWhy := 'the file could not be written (read-only, or locked)';
    Exit;
  end;
  // The buffer still holds what the IDE read before the conversion.
  try
    if Editor <> nil then
      Editor.ReloadModifiedFiles([AFileName]);
  except
    // the file on disk is correct either way - that is what matters
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
//  the tick: read, ask, fix
// ---------------------------------------------------------------------------

function FileList(const AFiles: TArray<TPendingFile>; AMax: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFiles) do
  begin
    if I >= AMax then
    begin
      Result := Result + Format('%s... and %d more', [sLineBreak,
        Length(AFiles) - AMax]);
      Break;
    end;
    if Result <> '' then Result := Result + sLineBreak;
    Result := Result + Format('%s - %s',
      [ExtractFileName(AFiles[I].FileName),
       LineEndingProblemText(AFiles[I].Info)]);
  end;
end;

procedure ApplyFix(const AFiles: TArray<TPendingFile>);
var
  F: TPendingFile;
  Why, Problems: string;
begin
  Problems := '';
  for F in AFiles do
    if FixOne(F.FileName, Why) then
      Inc(GFixed)
    else
    begin
      Inc(GFailed);
      if Problems <> '' then Problems := Problems + sLineBreak;
      Problems := Problems + Format('%s: %s',
        [ExtractFileName(F.FileName), Why]);
    end;
  // Silence when it worked - the status window carries the count. A box is
  // only worth the interruption when something did NOT happen.
  if Problems <> '' then
    ShowThemedMessage('Line endings could not be corrected:' + sLineBreak +
      sLineBreak + Problems);
end;

/// <summary>Asks, acts, and answers whether these files are now settled
///  (so they are not reported again in this session).</summary>
function AskAndFix(const AFiles: TArray<TPendingFile>): Boolean;
var
  Options: TArray<TThemedChoice>;
  Index: Integer;
  Prompt: string;
  Effect: TLineEndingEffect;

  function Choice(const ACaption, AHint: string): TThemedChoice;
  begin
    Result.Caption := ACaption;
    Result.Hint := AHint;
    Result.Enabled := True;
    Result.DisabledWhy := '';
  end;

begin
  if Length(AFiles) = 1 then
    Prompt := Format('%s has line endings Delphi does not handle well:',
      [ExtractFileName(AFiles[0].FileName)]) + sLineBreak + sLineBreak +
      FileList(AFiles, 1) + sLineBreak + sLineBreak +
      'Mixed or LF-only line endings put breakpoints on the wrong line and ' +
      'confuse the editor. Correct them to CRLF?'
  else
    Prompt := Format('%d of the files just opened have line endings Delphi ' +
      'does not handle well:', [Length(AFiles)]) + sLineBreak + sLineBreak +
      FileList(AFiles, 8) + sLineBreak + sLineBreak +
      'Correct them to CRLF?';

  Options := [
    Choice('Correct now (CRLF)',
      'Rewrites the line breaks on disk and re-reads the file. The encoding ' +
      'stays as it is.'),
    Choice('Correct now, and always in this session',
      'No more questions until the IDE is closed.'),
    Choice('Correct now, and always (saved)',
      'Turns on "fix line endings without asking" in the options.'),
    Choice('Leave it',
      IfThen(Length(AFiles) = 1,
        'Nothing is changed, and this file is not reported again in this ' +
        'session. (Cancel asks again next time.)',
        'Nothing is changed, and these files are not reported again in this ' +
        'session. (Cancel asks again next time.)'))];
  Index := 0;
  Effect := LineEndingChoiceEffect(LineEndingChoiceOfIndex(Index,
    ChooseThemedOption('Line endings', Prompt, Options, Index)));
  if Effect.AlwaysThisSession then GSessionAlways := True;
  if Effect.AlwaysSaved then
  begin
    TPluginSettings.LineEndingAutoFix := True;
    TPluginSettings.Save;
  end;
  if Effect.Correct then ApplyFix(AFiles);
  Result := Effect.DoNotAskAgain;
end;

procedure TTickHandler.DoTick(Sender: TObject);
var
  Files: TArray<TPendingFile>;
  Entry: TPendingFile;
  Info: TLineEndingInfo;
  Fn: string;
  I: Integer;
begin
  // Our own dialog is modal, and this timer fires from ITS message loop
  // too - the pending list must survive that untouched.
  if GBusy then Exit;
  // Somebody else's modal dialog (the IDE's own "file changed on disk", a
  // project load): asking on top of it is exactly the trap the header
  // names. The files stay pending.
  if Application.ModalLevel > 0 then Exit;
  if (GPending = nil) or (GPending.Count = 0) then
  begin
    GTimer.Enabled := False;
    Exit;
  end;

  GTimer.Enabled := False;
  Files := nil;
  for I := 0 to GPending.Count - 1 do
  begin
    Fn := GPending[I];
    if GReported.ContainsKey(Fn.ToLower) then Continue;
    Inc(GChecked);
    if not Examine(Fn, Info) then Continue;
    Entry.FileName := Fn;
    Entry.Info := Info;
    Files := Files + [Entry];
  end;
  GPending.Clear;
  if Length(Files) = 0 then Exit;

  GBusy := True;
  try
    if GSessionAlways or TPluginSettings.LineEndingAutoFix then
      // Nothing to remember: a corrected file is CRLF and will not come
      // back, and one that could NOT be corrected deserves the question
      // again when it is reopened - which is what its message asks for.
      ApplyFix(Files)
    else if AskAndFix(Files) then
      for Entry in Files do
        GReported.AddOrSetValue(Entry.FileName.ToLower, True);
  finally
    GBusy := False;
  end;
end;

// ---------------------------------------------------------------------------
//  install / status
// ---------------------------------------------------------------------------

function LineEndingFixAlwaysThisSession: Boolean;
begin
  Result := GSessionAlways;
end;

function LineEndingWatcherStatus: string;
begin
  if not TPluginSettings.LineEndingCheck then
    Exit('off - a file with LF-only or mixed line endings is not reported');
  Result := Format('on - %d file(s) checked', [GChecked]);
  if GFixed > 0 then
    Result := Result + Format(', %d corrected', [GFixed]);
  if GFailed > 0 then
    Result := Result + Format(', %d NOT corrected', [GFailed]);
  if TPluginSettings.LineEndingAutoFix then
    Result := Result + ' (fixing without asking: always)'
  else if GSessionAlways then
    Result := Result + ' (fixing without asking: this session)';
end;

procedure InstallLineEndingWatcher;
var
  Services: IOTAServices;
begin
  if GPending <> nil then Exit;
  GPending := TStringList.Create;
  GReported := TDictionary<string, Boolean>.Create;
  GTicker := TTickHandler.Create;
  GTimer := TTimer.Create(nil);
  GTimer.Enabled := False;
  GTimer.Interval := 500;
  GTimer.OnTimer := GTicker.DoTick;
  if Supports(BorlandIDEServices, IOTAServices, Services) then
  begin
    GNotifier := TLineEndingIdeNotifier.Create;
    GNotifierIndex := Services.AddNotifier(GNotifier);
  end;
end;

procedure UninstallLineEndingWatcher;
var
  Services: IOTAServices;
begin
  if (GNotifierIndex >= 0) and
     Supports(BorlandIDEServices, IOTAServices, Services) then
  begin
    try
      Services.RemoveNotifier(GNotifierIndex);
    except
      // the IDE may be shutting down
    end;
  end;
  GNotifierIndex := -1;
  GNotifier := nil;
  if GTimer <> nil then
  begin
    GTimer.Enabled := False;
    GTimer.OnTimer := nil;
  end;
  FreeAndNil(GTimer);
  FreeAndNil(GTicker);
  FreeAndNil(GReported);
  FreeAndNil(GPending);
end;

initialization

finalization
  UninstallLineEndingWatcher;

end.
