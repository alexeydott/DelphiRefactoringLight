(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)

/// <summary>Project check "File encoding": which sources are NOT in the
///  encoding they should be, and the conversion for them.
///
///  The forum idea (2026-10-16) asked for "von wo nach wo" - so the source
///  encodings are a SET the user picks and only files really in one of
///  them are touched. The default pair is the one that fixes a real defect
///  rather than a preference: a unit that is valid UTF-8 but carries no
///  BOM is read by the compiler as ANSI, and every non-ASCII character in
///  it silently becomes two (measured, see TSourceEncoding).
///
///  The CONVERSION is this unit's only writer and the dialog, the menu and
///  the MCP tool all call it - so a file the check would refuse can never
///  be rewritten through another door.</summary>
unit Expert.FileEncodingCheck;

interface

uses
  System.SysUtils, Delphi.FileEncoding;

/// <summary>Rewrites AFileName in ATo, keeping every character. False with
///  AWhy for a buffer with unsaved edits, a file that cannot be written,
///  and - the one that matters - a target encoding that cannot represent
///  the content (ANSI for a file with characters outside the code page):
///  losing characters is never the answer to "convert this".</summary>
function ConvertFileEncodingOf(const AFileName: string;
  ATo: TSourceEncoding; out AWhy: string): Boolean;

/// <summary>Menu entry "Project checks > File encoding...".</summary>
procedure CheckFileEncodings;

/// <summary>The files the check looks at (project sources + their
///  includes) and how it reads one - the MCP tool uses both.</summary>
function GatherEncodingCheckFiles: TArray<string>;
function ReadEncodingBytes(const AFile: string; out ABytes: TBytes): Boolean;

implementation

uses
  System.Classes, System.IOUtils, System.Generics.Collections, System.UITypes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Graphics, Vcl.Clipbrd, System.StrUtils,
  Expert.DebugConsistency, Expert.DialogHelper, Expert.EditorHelperIntf,
  Expert.IdeThemes, Expert.LineEndingWatcher, Expert.ListViewSort,
  Expert.ScopeFiles;

// ---------------------------------------------------------------------------
//  the conversion - the one writer
// ---------------------------------------------------------------------------

function EncodingFor(ATo: TSourceEncoding): TEncoding;
begin
  case ATo of
    secUtf8Bom: Result := TEncoding.UTF8;
    secUtf8NoBom: Result := TDelphiFileEncoding.UTF8NoBOM;
    secAnsi: Result := TEncoding.ANSI;
  else
    Result := nil;
  end;
end;

function ConvertFileEncodingOf(const AFileName: string;
  ATo: TSourceEncoding; out AWhy: string): Boolean;
var
  Target: TEncoding;
  Content: string;
begin
  AWhy := '';
  Result := False;
  Target := EncodingFor(ATo);
  if Target = nil then
  begin
    AWhy := 'nothing can be converted to ' + SourceEncodingText(ATo);
    Exit;
  end;
  // Same rule as the line-ending fix: this rewrites the FILE, and a buffer
  // with unsaved edits would be written over it by the next Ctrl+S.
  if ModuleIsModified(AFileName) then
  begin
    AWhy := 'the editor has unsaved changes - save it first, then try again';
    Exit;
  end;
  try
    Content := TDelphiFileEncoding.ReadAll(AFileName);
  except
    on E: Exception do
    begin
      AWhy := 'the file could not be read: ' + E.Message;
      Exit;
    end;
  end;
  // An ANSI target that cannot hold the text would write '?' for every
  // character it does not know. WriteAll upgrades such a file to UTF-8
  // silently, which is right for a write-back but WRONG for an explicit
  // "convert to ANSI": the honest answer is to refuse this one file.
  if ATo = secAnsi then
    if Target.GetString(Target.GetBytes(Content)) <> Content then
    begin
      AWhy := 'the text has characters the system code page does not know - ' +
        'converting to ANSI would replace them';
      Exit;
    end;
  try
    TDelphiFileEncoding.WriteAll(AFileName, Content, Target);
  except
    on E: Exception do
    begin
      AWhy := 'the file could not be written: ' + E.Message;
      Exit;
    end;
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
//  the files
// ---------------------------------------------------------------------------

function GatherEncodingCheckFiles: TArray<string>;
var
  Extra: TScopeExtra;
begin
  if Editor = nil then Exit(nil);
  // Project sources AND the files they {$I}nclude - never below the BDS
  // root, which ProjectScopeFiles already guarantees.
  Result := ProjectScopeFiles(Editor.GetActiveFileName, True, False, Extra);
end;

function ReadEncodingBytes(const AFile: string; out ABytes: TBytes): Boolean;
var
  Content: string;
begin
  ABytes := nil;
  Result := False;
  // The BUFFER first: the bytes we classify must be the bytes a save would
  // produce. An open buffer has no encoding of its own, so it is measured
  // through what the IDE would write - which is the file's own encoding,
  // i.e. exactly what is on disk. So: disk, unless the file is gone.
  try
    if TFile.Exists(AFile) then
    begin
      ABytes := TFile.ReadAllBytes(AFile);
      Exit(True);
    end;
    if (Editor <> nil) and Editor.ReadEditorContent(AFile, Content) then
    begin
      ABytes := TEncoding.UTF8.GetBytes(Content);
      Exit(True);
    end;
  except
    Result := False;
  end;
end;

// ---------------------------------------------------------------------------
//  the dialog
// ---------------------------------------------------------------------------

type
  TEncodingCheckDialog = class(TThemedToolForm)
  private
    FList: TThemedListView;
    FInfo: TLabel;
    FBtnFix: TButton;
    FIssues: TArray<TEncodingIssue>;
    FTarget: TSourceEncoding;
    FBusy: Boolean;
    procedure FillRows;
    procedure DoFixClick(Sender: TObject);
    procedure DoGotoClick(Sender: TObject);
    procedure DoCopyClick(Sender: TObject);
    /// <summary>Close, not ModalResult: this window is shown with Show,
    ///  and nothing outside ShowModal's loop ever reads ModalResult
    ///  (issue #47).</summary>
    procedure DoCloseClick(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateWith(const AIssues: TArray<TEncodingIssue>;
      ATarget: TSourceEncoding; AChecked: Integer);
  end;

constructor TEncodingCheckDialog.CreateWith(
  const AIssues: TArray<TEncodingIssue>; ATarget: TSourceEncoding;
  AChecked: Integer);
var
  Col: TListColumn;
  Panel: TPanel;

  function Btn(const ACaption: string; AWidth: Integer; AAlign: TAlign;
    AOnClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Panel;
    Result.Caption := ACaption;
    Result.Width := AWidth;
    Result.Align := AAlign;
    Result.AlignWithMargins := True;
    Result.OnClick := AOnClick;
  end;

begin
  inherited CreateNew(nil);
  OnClose := DoFormClose;
  FIssues := AIssues;
  FTarget := ATarget;
  Caption := 'File encoding';
  Width := 900;
  Height := 520;
  Position := poScreenCenter;

  FInfo := TLabel.Create(Self);
  FInfo.Parent := Self;
  FInfo.Align := alTop;
  FInfo.AlignWithMargins := True;
  FInfo.Margins.SetBounds(8, 8, 8, 4);
  FInfo.AutoSize := False;
  FInfo.WordWrap := True;
  FInfo.Height := 48;
  FInfo.Caption := Format('%d of %d file(s) are not %s. The conversion keeps ' +
    'every character and changes nothing else; form files and anything ' +
    'binary are never touched.',
    [Length(AIssues), AChecked, SourceEncodingText(ATarget)]);

  FList := TThemedListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.AlignWithMargins := True;
  FList.Margins.SetBounds(8, 4, 8, 4);
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.Checkboxes := True;

  // Measured in the headless render: 220/180/260/220 runs past the right
  // edge of a 900 px window and cuts the one column that carries the
  // reason.
  Col := FList.Columns.Add; Col.Caption := 'File';     Col.Width := 190;
  Col := FList.Columns.Add; Col.Caption := 'Found';    Col.Width := 150;
  Col := FList.Columns.Add; Col.Caption := 'Why it matters'; Col.Width := 330;
  Col := FList.Columns.Add; Col.Caption := 'Folder';   Col.Width := 200;

  Panel := TPanel.Create(Self);
  Panel.Parent := Self;
  Panel.Align := alBottom;
  Panel.Height := 40;
  Panel.BevelOuter := bvNone;
  FBtnFix := Btn('Convert c&hecked', 150, alLeft, DoFixClick);
  Btn('Copy &report', 110, alLeft, DoCopyClick);
  Btn('&Close', 75, alRight, DoCloseClick).Cancel := True;
  Btn('&Go to', 75, alRight, DoGotoClick);

  FillRows;
  EnableListViewSorting(FList);
  EnableThemes(Self);
  PrepareDialog(Self, nil);
end;

procedure TEncodingCheckDialog.FillRows;
var
  I: Integer;
  Item: TListItem;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to High(FIssues) do
    begin
      Item := FList.Items.Add;
      Item.Data := Pointer(NativeInt(I));
      Item.Caption := ExtractFileName(FIssues[I].FileName);
      Item.SubItems.Add(SourceEncodingText(FIssues[I].Found));
      Item.SubItems.Add(SourceEncodingNote(FIssues[I].Found));
      Item.SubItems.Add(ExtractFilePath(FIssues[I].FileName));
      // Pre-ticked: unlike a generated DFM handler, a conversion that keeps
      // every character has no second reading.
      Item.Checked := True;
    end;
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TEncodingCheckDialog.DoFixClick(Sender: TObject);
var
  Picked: TArray<Integer>;
  Item: TListItem;
  I, Done, Failed: Integer;
  Why, Report: string;
  Prog: TCheckProgressWindow;
begin
  if FBusy then Exit;   // the progress window pumps messages
  Picked := nil;
  for Item in FList.Items do
    if Item.Checked then
      Picked := Picked + [Integer(NativeInt(Item.Data))];
  if Length(Picked) = 0 then
  begin
    ShowThemedMessage('Nothing is ticked.');
    Exit;
  end;
  if not AskThemedConfirm(Format('Convert %d file(s) to %s?' + sLineBreak +
    sLineBreak + 'Every character is kept; only the encoding changes.',
    [Length(Picked), SourceEncodingText(FTarget)]), 'Convert') then Exit;

  FBusy := True;
  FList.Enabled := False;
  FBtnFix.Enabled := False;
  Done := 0;
  Failed := 0;
  Report := '';
  Prog := CreateCheckProgress('Converting...', Self);
  try
    for I := 0 to High(Picked) do
    begin
      Prog.Step(I + 1, Length(Picked),
        ExtractFileName(FIssues[Picked[I]].FileName));
      if ConvertFileEncodingOf(FIssues[Picked[I]].FileName, FTarget, Why) then
        Inc(Done)
      else
      begin
        Inc(Failed);
        Report := Report + ExtractFileName(FIssues[Picked[I]].FileName) +
          ': ' + Why + sLineBreak;
      end;
    end;
  finally
    Prog.Free;
    FBusy := False;
    FList.Enabled := True;
    FBtnFix.Enabled := True;
  end;

  // Re-read every row: a row must never keep claiming a problem that is
  // gone, and one that could not be converted keeps its reason.
  for I := High(FIssues) downto 0 do
  begin
    var Bytes: TBytes;
    if ReadEncodingBytes(FIssues[I].FileName, Bytes) then
      FIssues[I].Found := ClassifySourceEncoding(Bytes);
    if FIssues[I].Found = FTarget then
      Delete(FIssues, I, 1);
  end;
  FillRows;
  FInfo.Caption := Format('%d converted, %d left.%s', [Done, Length(FIssues),
    IfThen(Failed > 0, Format(' %d could NOT be converted.', [Failed]), '')]);
  if Report <> '' then
    ShowThemedMessage('Not converted:' + sLineBreak + sLineBreak + Report);
end;

procedure TEncodingCheckDialog.DoCloseClick(Sender: TObject);
begin
  Close;
end;

procedure TEncodingCheckDialog.DoFormClose(Sender: TObject; var Action: TCloseAction);
begin
  // A result window of its own - every run opens a new one, so the closed
  // one has to go rather than wait for the package to unload.
  Action := caFree;
end;

procedure TEncodingCheckDialog.DoGotoClick(Sender: TObject);
begin
  if (FList.Selected = nil) or (Editor = nil) then Exit;
  Editor.GotoLocation(FIssues[Integer(NativeInt(FList.Selected.Data))].FileName,
    0, 0, 0);
end;

procedure TEncodingCheckDialog.DoCopyClick(Sender: TObject);
var
  SL: TStringList;
  Issue: TEncodingIssue;
begin
  SL := TStringList.Create;
  try
    SL.Add(FInfo.Caption);
    SL.Add('');
    for Issue in FIssues do
      SL.Add(Format('%s'#9'%s'#9'%s', [Issue.FileName,
        SourceEncodingText(Issue.Found), SourceEncodingNote(Issue.Found)]));
    Clipboard.AsText := SL.Text;
  finally
    SL.Free;
  end;
end;

// ---------------------------------------------------------------------------
//  the menu entry
// ---------------------------------------------------------------------------

procedure CheckFileEncodings;
var
  Files: TArray<string>;
  Issues: TArray<TEncodingIssue>;
  Dlg: TEncodingCheckDialog;
  Prog: TCheckProgressWindow;
  From: TSourceEncodings;
  Target: TSourceEncoding;
  Choices: TArray<TThemedChoice>;
  Pick: Integer;
begin
  Files := GatherEncodingCheckFiles;
  if Length(Files) = 0 then
  begin
    ShowThemedMessage('No project source files found.');
    Exit;
  end;

  // "von wo nach wo" (the forum idea): the pairs that are worth offering.
  // The first one is the DEFECT - a BOM-less UTF-8 unit is read as ANSI
  // and loses its text - the second the hygiene case, the third both.
  SetLength(Choices, 4);
  Choices[0].Caption := 'UTF-8 without BOM  ->  UTF-8 with BOM';
  Choices[0].Hint := 'the compiler reads those as ANSI today - this is the ' +
    'one that fixes broken text';
  Choices[1].Caption := 'ANSI  ->  UTF-8 with BOM';
  Choices[1].Hint := 'readable either way; UTF-8 does not depend on the ' +
    'machine''s code page';
  Choices[2].Caption := 'both of the above  ->  UTF-8 with BOM';
  Choices[2].Hint := 'everything that is not already UTF-8 with a BOM, ' +
    'except pure ASCII';
  Choices[3].Caption := 'ASCII as well  ->  UTF-8 with BOM';
  Choices[3].Hint := 'adds a BOM to files whose bytes would not change - ' +
    'consistency only';
  for Pick := 0 to High(Choices) do Choices[Pick].Enabled := True;
  Pick := 0;
  if not ChooseThemedOption('File encoding',
    'Which files should be converted, and to what?', Choices, Pick) then Exit;
  Target := secUtf8Bom;
  case Pick of
    0: From := [secUtf8NoBom];
    1: From := [secAnsi];
    2: From := [secAnsi, secUtf8NoBom];
  else
    From := [secAnsi, secUtf8NoBom, secAscii];
  end;

  Prog := CreateCheckProgress('File encoding...', nil);
  try
    Issues := CollectEncodingIssues(Files, From, Target, ReadEncodingBytes,
      procedure(ACurrent, ATotal: Integer; const AFile: string)
      begin
        Prog.Step(ACurrent, ATotal, ExtractFileName(AFile));
      end);
  finally
    Prog.Free;
  end;

  if Length(Issues) = 0 then
  begin
    ShowThemedMessage(Format('All %d file(s) checked - nothing to convert.',
      [Length(Files)]));
    Exit;
  end;
  Dlg := TEncodingCheckDialog.CreateWith(Issues, Target, Length(Files));
  Dlg.Show;   // modeless: the user goes to the files from here
end;

end.
