(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Expert.LineEndingDialog;

// Project check "Line endings" (user request, 2026-10-15: the same thing as
// a project check, next to the DFM event check). The warning at file open
// catches a file when somebody opens it; this one answers the question for
// the WHOLE project at once - after a checkout, before a debugging session,
// or when breakpoints start landing on the wrong line.
//
// It shares everything with the warning: the classification and the three
// gates are pure (Expert.DebugConsistency), and the correction itself is
// the one FixLineEndingsOf of Expert.LineEndingWatcher - so the check can
// never rewrite a file the warning would refuse, or the other way round.

interface

uses
  System.SysUtils;      // TBytes, named by ReadLineEndingBytes below

/// <summary>Scans the project and opens the result window.</summary>
procedure CheckLineEndings;

/// <summary>The files the check looks at: the project's own sources plus
///  every file they {$I}nclude, never below the RAD Studio installation.
///  Exported because the MCP tool answers about exactly the same set.</summary>
function GatherLineEndingCheckFiles: TArray<string>;

/// <summary>Reads a file as the check sees it - the EDITOR BUFFER when the
///  file is open (that is what the user is looking at, and what a save
///  would write), the disk otherwise.</summary>
function ReadLineEndingBytes(const AFile: string; out ABytes: TBytes): Boolean;

implementation

uses
  System.Classes, System.IOUtils, System.Generics.Collections,
  System.UITypes, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.Graphics, Vcl.ExtCtrls, Vcl.ClipBrd,
  Expert.DebugConsistency, Expert.DialogHelper, Expert.EditorHelperIntf,
  Expert.IdeThemes, Expert.ListViewSort, Expert.LineEndingWatcher,
  Expert.ScopeFiles, Expert.UnitIndex;

function ReadLineEndingBytes(const AFile: string; out ABytes: TBytes): Boolean;
var
  Content: string;
begin
  ABytes := nil;
  // An open buffer is the truth: the file on disk may still be LF-only
  // while the editor already holds something else, and vice versa. The
  // bytes we classify must be the bytes a save would produce - the editor
  // hands us text, so it is encoded the way the file is read back.
  if Editor.ReadEditorContent(AFile, Content) then
  begin
    ABytes := TEncoding.UTF8.GetBytes(Content);
    Exit(True);
  end;
  if not TFile.Exists(AFile) then Exit(False);
  try
    ABytes := TFile.ReadAllBytes(AFile);
    Result := True;
  except
    Result := False;
  end;
end;

function GatherLineEndingCheckFiles: TArray<string>;
var
  Extra: TScopeExtra;
  Root: string;
  F: string;
begin
  Result := nil;
  if Editor = nil then Exit;
  // Project sources AND the files they {$I}nclude - ProjectScopeFiles adds
  // those itself (Extra.IncludeFiles only COUNTS them), and an .inc with
  // LF endings is exactly as bad as a .pas with them.
  var Files := ProjectScopeFiles('', False, False, Extra);
  Root := IncludeTrailingPathDelimiter(FindBdsRoot).ToLower;
  for F in Files do
    if (Root = '') or not F.ToLower.StartsWith(Root) then
      Result := Result + [F];
end;

type
  TLineEndingCheckDialog = class(TForm)
  private
    FListView: TListView;
    FLblSummary: TLabel;
    FBtnFix: TButton;
    FBtnGoto: TButton;
    FBtnCopy: TButton;
    FBtnClose: TButton;
    FIssues: TArray<TLineEndingIssue>;
    FScanned: Integer;
    FFixing: Boolean;
    procedure FillList;
    procedure UpdateSummary;
    function SelectedIssue(out AIssue: TLineEndingIssue): Boolean;
    procedure DoDblClick(Sender: TObject);
    procedure DoGotoClick(Sender: TObject);
    procedure DoFixClick(Sender: TObject);
    procedure DoCopyClick(Sender: TObject);
    procedure DoCloseClick(Sender: TObject);
    procedure DoCustomDrawSubItem(Sender: TCustomListView; Item: TListItem;
      SubItem: Integer; State: TCustomDrawState; var DefaultDraw: Boolean);
    procedure DoFormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateDialog(AOwner: TComponent;
      const AIssues: TArray<TLineEndingIssue>; AScanned: Integer);
  end;

constructor TLineEndingCheckDialog.CreateDialog(AOwner: TComponent;
  const AIssues: TArray<TLineEndingIssue>; AScanned: Integer);
var
  Col: TListColumn;
begin
  inherited CreateNew(AOwner);
  Caption := 'Line endings';
  Width := 900;
  Height := 520;
  Position := poScreenCenter;
  BorderStyle := bsSizeable;
  OnClose := DoFormClose;

  FIssues := AIssues;
  FScanned := AScanned;

  FLblSummary := TLabel.Create(Self);
  FLblSummary.Parent := Self;
  FLblSummary.Align := alTop;
  FLblSummary.AlignWithMargins := True;
  FLblSummary.Margins.SetBounds(8, 8, 8, 4);
  FLblSummary.WordWrap := True;

  FListView := TListView.Create(Self);
  FListView.Parent := Self;
  FListView.Align := alClient;
  FListView.AlignWithMargins := True;
  FListView.Margins.SetBounds(8, 4, 8, 4);
  FListView.ViewStyle := vsReport;
  FListView.ReadOnly := True;
  FListView.RowSelect := True;
  FListView.Checkboxes := True;
  FListView.OnDblClick := DoDblClick;
  FListView.OnCustomDrawSubItem := DoCustomDrawSubItem;

  // The widths add up to less than the client area (rendered: at 240/250/
  // 70/70/70/300 the Folder column was cut off at the right edge).
  Col := FListView.Columns.Add; Col.Caption := 'File';    Col.Width := 220;
  Col := FListView.Columns.Add; Col.Caption := 'Problem'; Col.Width := 240;
  Col := FListView.Columns.Add; Col.Caption := 'CRLF';    Col.Width := 60;
  Col := FListView.Columns.Add; Col.Caption := 'LF';      Col.Width := 55;
  Col := FListView.Columns.Add; Col.Caption := 'CR';      Col.Width := 55;
  Col := FListView.Columns.Add; Col.Caption := 'Folder';  Col.Width := 240;

  var Panel := TPanel.Create(Self);
  Panel.Parent := Self;
  Panel.Align := alBottom;
  Panel.Height := 40;
  Panel.BevelOuter := bvNone;

  // Writes files, so never the Default button (audit #41, M40e).
  FBtnFix := TButton.Create(Self);
  FBtnFix.Parent := Panel;
  FBtnFix.Caption := 'Correct c&hecked (CRLF)';
  FBtnFix.Width := 170;
  FBtnFix.Align := alLeft;
  FBtnFix.AlignWithMargins := True;
  FBtnFix.OnClick := DoFixClick;

  FBtnCopy := TButton.Create(Self);
  FBtnCopy.Parent := Panel;
  FBtnCopy.Caption := 'Copy &report';
  FBtnCopy.Width := 110;
  FBtnCopy.Align := alLeft;
  FBtnCopy.AlignWithMargins := True;
  FBtnCopy.OnClick := DoCopyClick;

  FBtnClose := TButton.Create(Self);
  FBtnClose.Parent := Panel;
  FBtnClose.Caption := '&Close';
  FBtnClose.Align := alRight;
  FBtnClose.AlignWithMargins := True;
  FBtnClose.Cancel := True;
  FBtnClose.OnClick := DoCloseClick;

  FBtnGoto := TButton.Create(Self);
  FBtnGoto.Parent := Panel;
  FBtnGoto.Caption := '&Go to';
  FBtnGoto.Align := alRight;
  FBtnGoto.AlignWithMargins := True;
  FBtnGoto.OnClick := DoGotoClick;

  FillList;
  UpdateSummary;
  EnableListViewSorting(FListView);
  EnableThemes(Self);
  PrepareDialog(Self, AOwner);
end;

procedure TLineEndingCheckDialog.FillList;
var
  I: Integer;
  Item: TListItem;
begin
  FListView.Items.BeginUpdate;
  try
    FListView.Items.Clear;
    for I := 0 to High(FIssues) do
    begin
      Item := FListView.Items.Add;
      // A sortable row maps to its array entry through Data, never through
      // Item.Index - that rule is why sorting does not scramble the fix.
      Item.Data := Pointer(NativeInt(I));
      Item.Caption := ExtractFileName(FIssues[I].FileName);
      Item.SubItems.Add(LineEndingProblemText(FIssues[I].Info));
      Item.SubItems.Add(IntToStr(FIssues[I].Info.CrLf));
      Item.SubItems.Add(IntToStr(FIssues[I].Info.LfOnly));
      Item.SubItems.Add(IntToStr(FIssues[I].Info.CrOnly));
      Item.SubItems.Add(ExtractFilePath(FIssues[I].FileName));
      // Pre-ticked: unlike the DFM check, where a generated handler can
      // SHADOW an inherited one, correcting a line break has no second
      // reading - and fixing the project is what this check is for. The
      // button still asks before it writes.
      Item.Checked := True;
    end;
  finally
    FListView.Items.EndUpdate;
  end;
end;

procedure TLineEndingCheckDialog.UpdateSummary;
var
  Mixed, LfOnly, CrOnly: Integer;
  Issue: TLineEndingIssue;
begin
  Mixed := 0; LfOnly := 0; CrOnly := 0;
  for Issue in FIssues do
    case Issue.Info.Kind of
      lekMixed: Inc(Mixed);
      lekLf: Inc(LfOnly);
      lekCr: Inc(CrOnly);
    end;
  if Length(FIssues) = 0 then
    FLblSummary.Caption := Format(
      '%d file(s) checked, all of them CRLF - nothing to correct.', [FScanned])
  else
    FLblSummary.Caption := Format('%d of %d file(s) are not CRLF: %d MIXED, ' +
      '%d LF only, %d CR only. Mixed endings are the worst case - the ' +
      'debugger puts breakpoints on the wrong line. The correction keeps ' +
      'the encoding and changes nothing but the line breaks.',
      [Length(FIssues), FScanned, Mixed, LfOnly, CrOnly]);
end;

procedure TLineEndingCheckDialog.DoCustomDrawSubItem(Sender: TCustomListView;
  Item: TListItem; SubItem: Integer; State: TCustomDrawState;
  var DefaultDraw: Boolean);
var
  Idx: Integer;
begin
  // THE DARK-MODE RULE: touching the canvas makes the native control take
  // the row background from Brush.Color, and the unthemed default is WHITE.
  Sender.Canvas.Brush.Color := GetThemedColor(clWindow);
  if cdsSelected in State then Exit;
  Idx := NativeInt(Item.Data);
  if (SubItem = 1) and (Idx >= 0) and (Idx <= High(FIssues)) and
     (FIssues[Idx].Info.Kind = lekMixed) then
    Sender.Canvas.Font.Style := Sender.Canvas.Font.Style + [fsBold];
end;

function TLineEndingCheckDialog.SelectedIssue(
  out AIssue: TLineEndingIssue): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  AIssue := Default(TLineEndingIssue);
  if FListView.Selected = nil then Exit;
  Idx := NativeInt(FListView.Selected.Data);
  if (Idx < 0) or (Idx > High(FIssues)) then Exit;
  AIssue := FIssues[Idx];
  Result := True;
end;

procedure TLineEndingCheckDialog.DoDblClick(Sender: TObject);
begin
  DoGotoClick(Sender);
end;

procedure TLineEndingCheckDialog.DoGotoClick(Sender: TObject);
var
  Issue: TLineEndingIssue;
begin
  if not SelectedIssue(Issue) then Exit;
  // The whole FILE is the finding, so there is no position to highlight -
  // a highlight counted from column 0 would mark the indentation (user,
  // 2026-10-05).
  Editor.GotoLocation(Issue.FileName, 0, 0, 0);
end;

procedure TLineEndingCheckDialog.DoFixClick(Sender: TObject);
var
  Wanted: TArray<Integer>;
  I, Done, Failed: Integer;
  Why, Problems: string;
  Prog: TCheckProgressWindow;
  Bytes: TBytes;
  Info: TLineEndingInfo;
begin
  // The run pumps messages (the progress window), so the ROWS may change
  // under it - take a snapshot of what was ticked, and refuse re-entry
  // (audit #37, M22).
  if FFixing then Exit;
  Wanted := nil;
  for I := 0 to FListView.Items.Count - 1 do
    if FListView.Items[I].Checked then
      Wanted := Wanted + [NativeInt(FListView.Items[I].Data)];
  if Length(Wanted) = 0 then
  begin
    ShowThemedMessage('No file is ticked.');
    Exit;
  end;
  if not AskThemedConfirm(Format('Rewrite the line breaks of %d file(s) as ' +
    'CRLF?' + sLineBreak + sLineBreak + 'The encoding is kept and nothing but ' +
    'the line breaks changes. A file that is open with unsaved changes is ' +
    'skipped and named.', [Length(Wanted)]), 'Correct') then Exit;

  FFixing := True;
  Done := 0; Failed := 0; Problems := '';
  Prog := CreateCheckProgress('Line endings', Self, 'Correcting...');
  try
    FListView.Enabled := False;
    FBtnFix.Enabled := False;
    for I := 0 to High(Wanted) do
    begin
      if (Wanted[I] < 0) or (Wanted[I] > High(FIssues)) then Continue;
      Prog.Step(I + 1, Length(Wanted),
        ExtractFileName(FIssues[Wanted[I]].FileName));
      if FixLineEndingsOf(FIssues[Wanted[I]].FileName, Why) then
        Inc(Done)
      else
      begin
        Inc(Failed);
        if Problems <> '' then Problems := Problems + sLineBreak;
        Problems := Problems + Format('%s: %s',
          [ExtractFileName(FIssues[Wanted[I]].FileName), Why]);
      end;
    end;
  finally
    Prog.Free;
    FListView.Enabled := True;
    FBtnFix.Enabled := True;
    FFixing := False;
  end;

  // Re-read what was touched: a row must never keep claiming a problem
  // that is gone, and one that could not be corrected stays.
  var Remaining: TArray<TLineEndingIssue> := nil;
  for I := 0 to High(FIssues) do
  begin
    if ReadLineEndingBytes(FIssues[I].FileName, Bytes) then
    begin
      Info := ClassifyLineEndings(Bytes);
      if not Info.NeedsFix then Continue;
      FIssues[I].Info := Info;
    end;
    Remaining := Remaining + [FIssues[I]];
  end;
  FIssues := Remaining;
  FillList;
  UpdateSummary;

  if Problems <> '' then
    ShowThemedMessage(Format('%d file(s) corrected, %d not:', [Done, Failed]) +
      sLineBreak + sLineBreak + Problems);
end;

procedure TLineEndingCheckDialog.DoCopyClick(Sender: TObject);
var
  SL: TStringList;
  Issue: TLineEndingIssue;
begin
  SL := TStringList.Create;
  try
    SL.Add(FLblSummary.Caption);
    SL.Add('');
    for Issue in FIssues do
      SL.Add(Format('%s - %s',
        [Issue.FileName, LineEndingProblemText(Issue.Info)]));
    Clipboard.AsText := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TLineEndingCheckDialog.DoCloseClick(Sender: TObject);
begin
  Close;
end;

procedure TLineEndingCheckDialog.DoFormClose(Sender: TObject;
  var Action: TCloseAction);
begin
  Action := caFree;      // non-modal: the window owns its own lifetime
end;

procedure CheckLineEndings;
var
  Files: TArray<string>;
  Issues: TArray<TLineEndingIssue>;
  Prog: TCheckProgressWindow;
  Dlg: TLineEndingCheckDialog;
begin
  Files := GatherLineEndingCheckFiles;
  if Length(Files) = 0 then
  begin
    ShowThemedMessage('No project loaded / no source files found.');
    Exit;
  end;
  Prog := CreateCheckProgress('Line endings', nil);
  try
    Screen.Cursor := crHourGlass;
    try
      // Not a file of the RAD Studio installation - see the encoding
      // check, where a live run found one in the list (1.31.3).
      Issues := CollectLineEndingIssues(Files, ReadLineEndingBytes,
        procedure(ACurrent, ATotal: Integer; const AFile: string)
        begin
          if (ACurrent mod 25 = 0) or (ACurrent = ATotal) then
            Prog.Step(ACurrent, ATotal, ExtractFileName(AFile));
        end, FindBdsRoot);
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    Prog.Free;
  end;

  // The window opens even with nothing to report - "all of them CRLF" is
  // the answer the user ran the check for.
  Dlg := TLineEndingCheckDialog.CreateDialog(Application.MainForm, Issues,
    Length(Files));
  Dlg.Show;
end;

end.
