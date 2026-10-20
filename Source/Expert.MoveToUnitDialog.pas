(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Expert.MoveToUnitDialog;

{
  Modal dialog for "Move identifier to another unit" - the ONE place the
  target is settled (user request 2026-10-20: the two menu entries "Move to
  unit..." and "Move to new unit..." became this one dialog).
  - an EXISTING unit: every project .pas except the source, filterable,
    with a preview of the planned edits;
  - a NEW unit: the name, created next to the source unit (a full path is
    accepted), checked while it is typed.
  WHY THE NEW-UNIT PREVIEW IS THE SHORTER ONE: planning a move into a unit
  that does not exist yet means writing the empty unit first, and the
  refusal that matters there - a declaration that needs the source unit
  itself, i.e. a circular unit reference - is decided by DelphiLSP, which
  may cold-start for 10-30 s. Neither belongs on a keystroke. So the
  complete check runs when Move is clicked: a refusal keeps the dialog open
  with its reason instead of arriving as a message box after it closed.
}

interface

uses
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  Expert.MoveToUnit;

type
  TMoveToUnitDialog = class(TForm)
  private
    FLblIdent: TLabel;
    FEdtIdent: TEdit;
    FPnlMode: TPanel;
    FRbExisting: TRadioButton;
    FRbNew: TRadioButton;
    FPnlExisting: TPanel;
    FLblFilter: TLabel;
    FEdtFilter: TEdit;
    FLstUnits: TListBox;
    FPnlNew: TPanel;
    FLblName: TLabel;
    FEdtName: TEdit;
    FLblNewHint: TLabel;
    FMemoPreview: TMemo;
    FBtnOk: TButton;
    FBtnCancel: TButton;
    FSymbol: string;
    FSourceFile: string;
    FChosenTarget: string;
    FAllFiles: TArray<string>;
    FCanMove: Boolean;
    procedure DoModeChange(Sender: TObject);
    procedure DoFilterChange(Sender: TObject);
    procedure DoUnitChange(Sender: TObject);
    procedure DoNameChange(Sender: TObject);
    procedure DoOkClick(Sender: TObject);
    procedure RefreshPreview;
    procedure RefreshList;
    procedure SayCannot(const AReason: string);
  public
    constructor CreateDialog(AOwner: TComponent;
      const ASymbol, ASourceFile: string;
      const AProjectFiles: TArray<string>);
    /// <summary>True while the target is a unit that does not exist yet -
    ///  the caller has to create it (ExecuteToNewUnit), not move into
    ///  it.</summary>
    function TargetIsNewUnit: Boolean;
    /// <summary>The chosen target file: the selected project unit, or the
    ///  file the typed name means. '' when nothing is chosen or the name
    ///  cannot become a unit.</summary>
    function SelectedFile: string;
    /// <summary>The target the Move click really validated. NOT derived
    ///  from the edit box a second time: the new-unit check writes the
    ///  empty unit and deletes it again, and a delete that did not happen
    ///  would read as "already exists" - the click would then do nothing
    ///  and say nothing.</summary>
    function ChosenTarget: string;

    class function Choose(AOwner: TComponent;
      const ASymbol, ASourceFile: string;
      const AProjectFiles: TArray<string>;
      out ATargetFile: string; out ANewUnit: Boolean): Boolean;
  end;

implementation

uses
  System.UITypes, Vcl.Graphics,
  Expert.DialogHelper, Expert.IdeThemes, Expert.LspManager;

{ TMoveToUnitDialog }

constructor TMoveToUnitDialog.CreateDialog(AOwner: TComponent;
  const ASymbol, ASourceFile: string;
  const AProjectFiles: TArray<string>);
var
  F: string;
  Filtered: TArray<string>;
  Count: Integer;
begin
  inherited CreateNew(AOwner);
  Caption := 'Move to unit';
  Position := poMainFormCenter;
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];
  ClientWidth := 720;
  ClientHeight := 480;
  Constraints.MinWidth := 560;
  Constraints.MinHeight := 380;
  KeyPreview := True;

  FSymbol := ASymbol;
  FSourceFile := ASourceFile;

  // Filter the project file list: only .pas files, exclude the source.
  Count := 0;
  SetLength(Filtered, Length(AProjectFiles));
  for F in AProjectFiles do
  begin
    if SameText(F, ASourceFile) then Continue;
    if not SameText(ExtractFileExt(F), '.pas') then Continue;
    Filtered[Count] := F;
    Inc(Count);
  end;
  SetLength(Filtered, Count);
  FAllFiles := Filtered;

  FLblIdent := TLabel.Create(Self);
  FLblIdent.Parent := Self;
  FLblIdent.Left := 12;
  FLblIdent.Top := 8;
  FLblIdent.Caption := 'Identifier to move:';

  FEdtIdent := TEdit.Create(Self);
  FEdtIdent.Parent := Self;
  FEdtIdent.Left := 12;
  FEdtIdent.Top := 26;
  FEdtIdent.Width := ClientWidth - 24;
  FEdtIdent.Anchors := [akLeft, akTop, akRight];
  FEdtIdent.Text := ASymbol;
  FEdtIdent.ReadOnly := True;
  // not the hard-coded light grey it used to be: on the dark theme that
  // was a white box in a dark dialog
  FEdtIdent.Color := GetThemedColor(clBtnFace);

  // The two targets. Radio buttons group by PARENT, so they live on their
  // own panel - on the form they would be one group with anything else.
  FPnlMode := TPanel.Create(Self);
  FPnlMode.Parent := Self;
  FPnlMode.BevelOuter := bvNone;
  FPnlMode.Left := 10;
  FPnlMode.Top := 56;
  FPnlMode.Width := ClientWidth - 20;
  FPnlMode.Height := 26;
  FPnlMode.Anchors := [akLeft, akTop, akRight];

  FRbExisting := TRadioButton.Create(Self);
  FRbExisting.Parent := FPnlMode;
  FRbExisting.Left := 2;
  FRbExisting.Top := 4;
  FRbExisting.Width := 200;
  FRbExisting.Caption := 'Into an e&xisting unit';

  FRbNew := TRadioButton.Create(Self);
  FRbNew.Parent := FPnlMode;
  FRbNew.Left := 210;
  FRbNew.Top := 4;
  FRbNew.Width := 200;
  FRbNew.Caption := 'Into a &new unit';

  FPnlExisting := TPanel.Create(Self);
  FPnlExisting.Parent := Self;
  FPnlExisting.BevelOuter := bvNone;
  FPnlExisting.Left := 12;
  FPnlExisting.Top := 88;
  FPnlExisting.Width := 280;
  FPnlExisting.Height := ClientHeight - 88 - 48;
  FPnlExisting.Anchors := [akLeft, akTop, akBottom];

  FLblFilter := TLabel.Create(Self);
  FLblFilter.Parent := FPnlExisting;
  FLblFilter.Left := 0;
  FLblFilter.Top := 2;
  FLblFilter.Caption := 'Target unit (&filter):';

  FEdtFilter := TEdit.Create(Self);
  FEdtFilter.Parent := FPnlExisting;
  FEdtFilter.Left := 0;
  FEdtFilter.Top := 20;
  FEdtFilter.Width := FPnlExisting.Width;
  FEdtFilter.Anchors := [akLeft, akTop, akRight];
  FLblFilter.FocusControl := FEdtFilter;   // or its Alt+F does nothing

  FLstUnits := TListBox.Create(Self);
  FLstUnits.Parent := FPnlExisting;
  FLstUnits.Left := 0;
  FLstUnits.Top := 50;
  FLstUnits.Width := FPnlExisting.Width;
  FLstUnits.Height := FPnlExisting.Height - 50;
  FLstUnits.Anchors := [akLeft, akTop, akRight, akBottom];

  FPnlNew := TPanel.Create(Self);
  FPnlNew.Parent := Self;
  FPnlNew.BevelOuter := bvNone;
  FPnlNew.Left := FPnlExisting.Left;
  FPnlNew.Top := FPnlExisting.Top;
  FPnlNew.Width := FPnlExisting.Width;
  FPnlNew.Height := FPnlExisting.Height;
  FPnlNew.Anchors := [akLeft, akTop, akBottom];
  FPnlNew.Visible := False;

  FLblName := TLabel.Create(Self);
  FLblName.Parent := FPnlNew;
  FLblName.Left := 0;
  FLblName.Top := 2;
  FLblName.Caption := 'New &unit name:';

  FEdtName := TEdit.Create(Self);
  FEdtName.Parent := FPnlNew;
  FEdtName.Left := 0;
  FEdtName.Top := 20;
  FEdtName.Width := FPnlNew.Width;
  FEdtName.Anchors := [akLeft, akTop, akRight];
  FEdtName.Text := SuggestedNewUnitName(ASymbol);
  FLblName.FocusControl := FEdtName;

  FLblNewHint := TLabel.Create(Self);
  FLblNewHint.Parent := FPnlNew;
  FLblNewHint.Left := 0;
  FLblNewHint.Top := 50;
  FLblNewHint.Width := FPnlNew.Width;
  // AutoSize off with a fixed height: an AutoSize+WordWrap label computes
  // its height against the default width first
  FLblNewHint.AutoSize := False;
  FLblNewHint.WordWrap := True;
  FLblNewHint.Height := 72;
  FLblNewHint.Anchors := [akLeft, akTop, akRight];
  FLblNewHint.Caption := Format('The unit is created next to %s and added to ' +
    'the active project. A dotted name is fine, ".pas" is added by itself, ' +
    'and a full path puts the unit somewhere else.',
    [ExtractFileName(ASourceFile)]);

  FMemoPreview := TMemo.Create(Self);
  FMemoPreview.Parent := Self;
  FMemoPreview.Left := 300;
  FMemoPreview.Top := FPnlExisting.Top;
  FMemoPreview.Width := ClientWidth - 300 - 12;
  FMemoPreview.Height := FPnlExisting.Height;
  FMemoPreview.Anchors := [akLeft, akTop, akRight, akBottom];
  FMemoPreview.ReadOnly := True;
  // WRAPPED (seen in the render): a long path or a sentence used to run
  // off the right edge and could only be read by scrolling sideways
  FMemoPreview.ScrollBars := ssVertical;
  FMemoPreview.Font.Name := 'Consolas';
  FMemoPreview.Font.Size := 9;
  // Font.Name/Size clear ParentFont, and then the themed font COLOUR never
  // arrives - black text on the dark theme
  FMemoPreview.Font.Color := GetThemedColor(clWindowText);
  FMemoPreview.WordWrap := True;

  FBtnCancel := TButton.Create(Self);
  FBtnCancel.Parent := Self;
  FBtnCancel.Caption := 'Cancel';
  FBtnCancel.Width := 90;
  FBtnCancel.Height := 28;
  FBtnCancel.Top := ClientHeight - 38;
  FBtnCancel.Left := ClientWidth - 90 - 12;
  FBtnCancel.Anchors := [akRight, akBottom];
  FBtnCancel.ModalResult := mrCancel;
  FBtnCancel.Cancel := True;

  FBtnOk := TButton.Create(Self);
  FBtnOk.Parent := Self;
  FBtnOk.Caption := 'Move';
  FBtnOk.Width := 90;
  FBtnOk.Height := 28;
  FBtnOk.Top := ClientHeight - 38;
  FBtnOk.Left := FBtnCancel.Left - 96;
  FBtnOk.Anchors := [akRight, akBottom];
  // NO ModalResult: the new-unit target is checked on the click, and a
  // refusal has to keep the dialog open
  FBtnOk.Default := True;
  FBtnOk.Enabled := False;

  RefreshList;

  // With no OTHER unit in the project the existing-unit half cannot work,
  // and opening on it shows an empty list and no reason for it.
  if Length(FAllFiles) = 0 then
  begin
    FRbExisting.Enabled := False;
    FRbNew.Checked := True;
    FPnlExisting.Visible := False;
    FPnlNew.Visible := True;
  end
  else
    FRbExisting.Checked := True;

  // Handlers last: assigning Checked fires OnClick, and a handler that
  // runs while a control it touches does not exist yet is an access
  // violation on the first open.
  FRbExisting.OnClick := DoModeChange;
  FRbNew.OnClick := DoModeChange;
  FEdtFilter.OnChange := DoFilterChange;
  FLstUnits.OnClick := DoUnitChange;
  FEdtName.OnChange := DoNameChange;
  FBtnOk.OnClick := DoOkClick;

  // ...so the state the dialog opens in still has to describe itself
  if FRbNew.Checked then RefreshPreview;

  PrepareDialog(Self, AOwner);
end;

procedure TMoveToUnitDialog.RefreshList;
var
  F, U, Flt: string;
begin
  FLstUnits.Items.BeginUpdate;
  try
    FLstUnits.Items.Clear;
    Flt := AnsiUpperCase(Trim(FEdtFilter.Text));
    for F in FAllFiles do
    begin
      U := ChangeFileExt(ExtractFileName(F), '');
      if (Flt = '') or (Pos(Flt, AnsiUpperCase(U)) > 0) then
        FLstUnits.Items.Add(U);
    end;
  finally
    FLstUnits.Items.EndUpdate;
  end;
  FCanMove := False;
  FBtnOk.Enabled := False;
  FMemoPreview.Clear;
end;

procedure TMoveToUnitDialog.DoModeChange(Sender: TObject);
begin
  FPnlExisting.Visible := not FRbNew.Checked;
  FPnlNew.Visible := FRbNew.Checked;
  if FRbNew.Checked then
  begin
    RefreshPreview;
    if FEdtName.CanFocus then FEdtName.SetFocus;
  end
  else
  begin
    // the selection decides again - and when there is none, nothing is
    // claimed about a target
    FCanMove := False;
    FBtnOk.Enabled := False;
    FMemoPreview.Clear;
    if FLstUnits.ItemIndex >= 0 then RefreshPreview;
  end;
end;

procedure TMoveToUnitDialog.DoFilterChange(Sender: TObject);
begin
  RefreshList;
end;

procedure TMoveToUnitDialog.DoUnitChange(Sender: TObject);
begin
  RefreshPreview;
end;

procedure TMoveToUnitDialog.DoNameChange(Sender: TObject);
begin
  RefreshPreview;
end;

function TMoveToUnitDialog.TargetIsNewUnit: Boolean;
begin
  Result := FRbNew.Checked;
end;

function TMoveToUnitDialog.ChosenTarget: string;
begin
  Result := FChosenTarget;
end;

function TMoveToUnitDialog.SelectedFile: string;
var
  Sel, F, Problem: string;
begin
  Result := '';
  if FRbNew.Checked then
    Exit(PlanNewUnitFile(FEdtName.Text, FSourceFile, Problem));
  if FLstUnits.ItemIndex < 0 then Exit;
  Sel := FLstUnits.Items[FLstUnits.ItemIndex];
  for F in FAllFiles do
    if SameText(ChangeFileExt(ExtractFileName(F), ''), Sel) then
      Exit(F);
end;

procedure TMoveToUnitDialog.SayCannot(const AReason: string);
begin
  FMemoPreview.Lines.Text := Format('Symbol: %s'#13#10'Source: %s'#13#10 +
    #13#10'Cannot move: %s'#13#10,
    [FSymbol, ExtractFileName(FSourceFile), AReason]);
  FCanMove := False;
  FBtnOk.Enabled := False;
end;

procedure TMoveToUnitDialog.RefreshPreview;
var
  Plan: TMovePlan;
  Sel, Problem: string;
  E: TMoveEdit;
  SB: TStringBuilder;
begin
  FCanMove := False;
  FBtnOk.Enabled := False;
  FMemoPreview.Clear;

  if FRbNew.Checked then
  begin
    Sel := PlanNewUnitFile(FEdtName.Text, FSourceFile, Problem);
    if Sel = '' then
    begin
      SayCannot(Problem);
      Exit;
    end;
  end
  else
  begin
    Sel := SelectedFile;
    if Sel = '' then Exit;   // nothing picked: nothing is claimed
  end;

  SB := TStringBuilder.Create;
  try
    SB.Append('Symbol: ').Append(FSymbol).AppendLine;
    SB.Append('Source: ').Append(ExtractFileName(FSourceFile)).AppendLine;
    if FRbNew.Checked then
    begin
      SB.Append('Target: ').Append(ExtractFileName(Sel))
        .Append('  (a NEW unit)').AppendLine;
      SB.Append('Folder: ').Append(ExtractFilePath(Sel)).AppendLine;
      SB.AppendLine;
      SB.Append('What Move does:').AppendLine;
      SB.Append('  - writes the empty unit and adds it to the active project')
        .AppendLine;
      SB.Append('  - moves ').Append(FSymbol)
        .Append(' there, declaration and implementation').AppendLine;
      SB.Append('  - puts the new unit into the uses clause of every unit ' +
        'that needs it').AppendLine;
      SB.AppendLine;
      SB.Append('A declaration that needs ')
        .Append(ChangeFileExt(ExtractFileName(FSourceFile), ''))
        .Append(' itself cannot go into a new unit - that would be a ' +
          'circular unit reference. Deciding that asks DelphiLSP, so it ' +
          'happens when you press Move (the session may have to start up ' +
          'first, and where it cannot be reached the question stays ' +
          'unanswered and the move goes ahead).').AppendLine;
      FCanMove := True;
    end
    else
    begin
      SB.Append('Target: ').Append(ExtractFileName(Sel)).AppendLine;
      SB.AppendLine;
      if TLspMoveToUnit.BuildPlan(FSymbol, FSourceFile, Sel, Plan) then
      begin
        SB.Append('Planned edits:').AppendLine;
        for E in Plan.Edits do
          SB.Append('  - ').Append(ExtractFileName(E.FilePath))
            .Append(': ').Append(E.Description).AppendLine;
        if Length(Plan.Consumers) = 0 then
        begin
          SB.AppendLine;
          SB.Append('No consumer files reference this symbol.').AppendLine;
        end;
        FCanMove := True;
      end
      else
      begin
        SB.Append('Cannot move: ').Append(Plan.ProblemDetail).AppendLine;
      end;
    end;
    FMemoPreview.Lines.Text := SB.ToString;
  finally
    SB.Free;
  end;
  FBtnOk.Enabled := FCanMove;
end;

procedure TMoveToUnitDialog.DoOkClick(Sender: TObject);
var
  Plan: TMovePlan;
  Target, Err: string;
begin
  if not FCanMove then Exit;
  Target := SelectedFile;
  if Target = '' then Exit;

  if not FRbNew.Checked then
  begin
    FChosenTarget := Target;  // the plan was built when the unit was picked
    ModalResult := mrOk;
    Exit;
  end;

  // The complete check for a new unit, including the circular-reference
  // refusal: it asks DelphiLSP, so it runs here and not on a keystroke.
  // APreview writes nothing and deletes the empty unit again.
  // It runs on THIS thread - it is ToolsAPI and DelphiLSP throughout, so
  // it cannot move off the main one - and nothing in that chain pumps a
  // message. Saying what is happening before it starts is what is left.
  FMemoPreview.Lines.Text := Format('Checking %s with DelphiLSP...'#13#10#13#10 +
    'Starting the session can take 10 to 30 seconds. The window does not ' +
    'react while it waits.', [FSymbol]);
  FMemoPreview.Update;
  FBtnOk.Enabled := False;
  FBtnOk.Update;
  Screen.Cursor := crHourGlass;
  try
    if not TLspMoveToUnit.ExecuteToNewUnit(FSymbol, FSourceFile, Target,
         True, Plan, Err) then
    begin
      if Err = '' then Err := 'the move could not be planned';
      SayCannot(Err);   // and that one leaves Move disabled, as it should
      Exit;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  FChosenTarget := Target;
  ModalResult := mrOk;
end;

class function TMoveToUnitDialog.Choose(AOwner: TComponent;
  const ASymbol, ASourceFile: string;
  const AProjectFiles: TArray<string>;
  out ATargetFile: string; out ANewUnit: Boolean): Boolean;
var
  Dlg: TMoveToUnitDialog;
begin
  Result := False;
  ATargetFile := '';
  ANewUnit := False;
  Dlg := TMoveToUnitDialog.CreateDialog(AOwner, ASymbol, ASourceFile, AProjectFiles);
  try
    TLspManager.Instance.ApplyStatusToCaption(Dlg);
    if Dlg.ShowModal = mrOk then
    begin
      ATargetFile := Dlg.ChosenTarget;
      ANewUnit := Dlg.TargetIsNewUnit;
      Result := ATargetFile <> '';
    end;
  finally
    Dlg.Free;
  end;
end;

initialization
  RegisterDialogClass(TMoveToUnitDialog);

end.
