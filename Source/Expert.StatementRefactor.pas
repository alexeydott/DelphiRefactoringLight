(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Expert.StatementRefactor;

// Two statement-level refactorings suggested in issue #11 (Ian Branch):
//
// EXTRACT VARIABLE - the selected expression becomes an inline variable
//   ("var LName := <expr>;") declared right before the STATEMENT that
//   contains it, and the selection is replaced by the name. Never at the
//   routine's begin: hoisting further would change how often and whether
//   the expression is evaluated. Refused where even the statement start is
//   too far: after a short-circuit operator ("if Assigned(X) and (X.Foo >
//   0)" - hoisting X.Foo would dereference nil), inside a branch or loop
//   body on the same line (then/else/do), in a loop condition, as the sole
//   statement of a branch (inserting before it would change the branch),
//   and inside a with (the names might bind to the with target).
//
// WRAP IN TRY..FINALLY - the selected statements go into a try block; the
//   cleanup is inferred from the statement right before them:
//   "X := TFoo.Create..." -> X.Free, "X.BeginUpdate" -> X.EndUpdate,
//   "X.Enter/Acquire/Lock" -> Leave/Release/Unlock, "TMonitor.Enter(X)" ->
//   TMonitor.Exit(X); otherwise a TODO comment. Only wrapper lines are
//   added, so a wrong guess is a compile error, never silent damage.
//
// The planners are pure (tested); the two entry points read the selection
// through the editor helper and write through ApplyLinesMinimal (undoable
// in the IDE).

interface

uses
  System.SysUtils;

type
  TExtractVarPlan = record
    StatementLine: Integer;   // 0-based line the declaration goes before
    DeclText: string;         // "  var LCount := Foo.Bar.Count;"
    NewLines: TArray<string>; // the whole unit after the edit
  end;

/// <summary>A readable name for a variable holding AExpr: the last
///  identifier before a call / index ("Foo.Bar.Count" -> "LCount",
///  "GetName(X)" -> "LName", "Items[I].Caption" -> "LCaption"), "LValue"
///  when there is none.</summary>
function SuggestVariableName(const AExpr: string): string;

/// <summary>Plans "extract variable" for the single-line selection
///  [AStartCol0, AEndCol0) on ALine0 (0-based, end exclusive). False with
///  AWhy when the extraction would not be safe (see the unit header).</summary>
function PlanExtractVariable(const ALines: TArray<string>; ALine0, AStartCol0,
  AEndCol0: Integer; const AName: string; out APlan: TExtractVarPlan;
  out AWhy: string): Boolean;

/// <summary>The cleanup statement for a try..finally around statements
///  that follow APrevStatement ('' when nothing can be inferred).</summary>
function InferCleanup(const APrevStatement: string): string;

/// <summary>ALines with the statements on lines AFirst0..ALast0 wrapped in
///  try..finally (cleanup = ACleanup, or a TODO comment when empty). False
///  with AWhy when the lines are not a sequence of complete statements
///  (unbalanced begin/end, try/end, case/end, parentheses).</summary>
function PlanWrapTryFinally(const ALines: TArray<string>; AFirst0, ALast0: Integer;
  const ACleanup: string; out ANewLines: TArray<string>; out AWhy: string): Boolean;

type
  /// <summary>What the selection is, as far as a declaration cares. A
  ///  literal EXPRESSION ("2 * 1024") counts as its literals' kind; mixing
  ///  strings and numbers, or naming any identifier, is dvOther - a const
  ///  may only hold a constant expression, and an identifier that is in
  ///  scope at the use site need not be in scope where the declaration
  ///  goes.</summary>
  TDeclareValueKind = (dvNone, dvNumber, dvString, dvOther);

  /// <summary>Where the declaration goes. dplClass needs an enclosing type,
  ///  dplLocal an enclosing routine.</summary>
  TDeclarePlace = (dplLocal, dplClass, dplInterface, dplImplementation);

  /// <summary>Which section. dsResourceString exists at UNIT level only and
  ///  takes a string literal - that is Delphi's rule, not ours.</summary>
  TDeclareSection = (dsConst, dsResourceString);

  TDeclarePlan = record
    InsertLine0: Integer;      // 0-based line the declaration is inserted at
    DeclText: string;          // what is inserted, line breaks included
    NewLines: TArray<string>;  // the whole unit after the edit
    Replaced: Integer;         // occurrences that became the name
    Note: string;              // '' or what the user should know
  end;

/// <summary>What ASelection could be declared as. Numbers, strings, char
///  literals and expressions built from them only - see
///  TDeclareValueKind.</summary>
function ClassifyDeclareValue(const ASelection: string): TDeclareValueKind;

/// <summary>A name to offer for a constant holding ASelection. A string
///  gives its own words ('Datei nicht gefunden' -> 'SDateiNichtGefunden'),
///  a number takes the identifier it is assigned to or compared with
///  (AContextBefore, the code left of the selection: 'Timeout := ' ->
///  'CTimeout'), else 'CValue'.</summary>
function SuggestConstantName(const ASelection, AContextBefore: string;
  AKind: TDeclareValueKind): string;

type
  /// <summary>What to declare, and where. The VALUE is its own field and
  ///  not the selected text: the selection only offers it, and the user may
  ///  change it (request 2026-10-16) - or select nothing at all and define
  ///  the constant from scratch, which is what HasSelection = False
  ///  means.</summary>
  TDeclareRequest = record
    /// <summary>0-based caret line. Without a selection this is still what
    ///  says which routine or class dplLocal / dplClass mean.</summary>
    Line0: Integer;
    /// <summary>The selection on Line0, end exclusive. Ignored, and
    ///  nothing is replaced, when HasSelection is False.</summary>
    HasSelection: Boolean;
    StartCol0: Integer;
    EndCol0: Integer;
    Name: string;
    /// <summary>What is declared. A literal or a constant expression of
    ///  literals - see TDeclareValueKind.</summary>
    Value: string;
    /// <summary>'' = untyped, which is what a const usually wants.</summary>
    TypeName: string;
    Place: TDeclarePlace;
    Section: TDeclareSection;
    /// <summary>Also replace every OTHER occurrence of the selected literal
    ///  - in the enclosing routine for dplLocal, in the whole unit
    ///  otherwise. Only in code and only whole literals, so 100 never
    ///  matches inside 1000. Without a selection there is nothing to
    ///  replace and this is ignored.</summary>
    ReplaceAll: Boolean;
  end;

/// <summary>Declares AReq.Value as a constant, and where AReq has a
///  selection puts the name in its place. False with AWhy for everything
///  that would not compile or would change the meaning - and every refusal
///  says which.</summary>
function PlanDeclare(const ALines: TArray<string>;
  const AReq: TDeclareRequest; out APlan: TDeclarePlan;
  out AWhy: string): Boolean;

/// <summary>A request for the selection [AStartCol0, AEndCol0) on ALine0,
///  with the value and the name offered from it - what the editor hands the
///  dialog. AStartCol0 &gt;= AEndCol0 means "nothing selected".</summary>
function DeclareRequestFor(const ALines: TArray<string>;
  ALine0, AStartCol0, AEndCol0: Integer): TDeclareRequest;

/// <summary>Editor entry points (IDE and standalone).</summary>
procedure ExtractVariableAtSelection;
procedure WrapSelectionInTryFinally;

implementation

uses
  System.Classes, System.StrUtils, System.Math, Vcl.Dialogs,
  Expert.EditorHelperIntf, Expert.UnitIndex, Expert.UsesEditor,
  Expert.AutoImport, Expert.WithScanner, Expert.DialogHelper, Expert.PascalScanner,
  Expert.IdentifierCheck, Expert.MethodEdit, Expert.SelectionValidator;

// Assigns the reason and answers False, so every refusal below is one
// line and none of them can forget to say why.
function SetWhy(out AWhy: string; const AMsg: string): Boolean;
begin
  AWhy := AMsg;
  Result := False;
end;

function LeadingBlanks(const S: string): string;
var
  K: Integer;
begin
  K := 1;
  while (K <= Length(S)) and CharInSet(S[K], [' ', #9]) do Inc(K);
  Result := Copy(S, 1, K - 1);
end;

function HasWordCI(const S, AWord: string): Boolean;
var
  U, W: string;
  P, E: Integer;
begin
  U := UpperCase(S);
  W := UpperCase(AWord);
  P := Pos(W, U);
  while P > 0 do
  begin
    E := P + Length(W);
    if ((P = 1) or not IsIdentChar(U[P - 1])) and ((E > Length(U)) or not IsIdentChar(U[E])) then
      Exit(True);
    P := Pos(W, U, P + 1);
  end;
  Result := False;
end;

function SuggestVariableName(const AExpr: string): string;
var
  S, Id: string;
  I, Depth: Integer;
begin
  S := Trim(AExpr);
  // drop trailing (...) / [...] groups: "GetName(X)" -> "GetName"
  while (S <> '') and CharInSet(S[Length(S)], [')', ']']) do
  begin
    Depth := 0;
    I := Length(S);
    while I >= 1 do
    begin
      if CharInSet(S[I], [')', ']']) then Inc(Depth)
      else if CharInSet(S[I], ['(', '[']) then
      begin
        Dec(Depth);
        if Depth = 0 then Break;
      end;
      Dec(I);
    end;
    if I < 1 then Break;
    S := TrimRight(Copy(S, 1, I - 1));
  end;
  // last identifier
  I := Length(S);
  while (I >= 1) and IsIdentChar(S[I]) do Dec(I);
  Id := Copy(S, I + 1, MaxInt);
  if (Id = '') or CharInSet(Id[1], ['0'..'9']) then Exit('LValue');
  if (Length(Id) > 3) and StartsText('Get', Id) and CharInSet(Id[4], ['A'..'Z']) then
    Id := Copy(Id, 4, MaxInt);
  if (Length(Id) > 1) and CharInSet(Id[1], ['F', 'A']) and CharInSet(Id[2], ['A'..'Z']) then
    Id := Copy(Id, 2, MaxInt);   // FCount / ACount -> Count
  Result := 'L' + UpCase(Id[1]) + Copy(Id, 2, MaxInt);
end;

// Last code token of a masked line ('' for a blank one).
function LastCodeWord(const AMasked: string; out ALastChar: Char): string;
var
  S: string;
  I: Integer;
begin
  S := TrimRight(AMasked);
  ALastChar := #0;
  Result := '';
  if S = '' then Exit;
  ALastChar := S[Length(S)];
  I := Length(S);
  while (I >= 1) and IsIdentChar(S[I]) do Dec(I);
  Result := UpperCase(Copy(S, I + 1, MaxInt));
end;

// 0-based line where the statement containing ALine0 starts: the line after
// the nearest code line that ends a statement or opens a statement list.
function StatementStartLine(const AMasked: TArray<string>; ALine0: Integer): Integer;
var
  W: string;
  C: Char;
begin
  Result := ALine0;
  for var L := ALine0 - 1 downto 0 do
  begin
    W := LastCodeWord(AMasked[L], C);
    if C = #0 then Continue;   // blank / comment-only line
    if (C = ';') or (W = 'BEGIN') or (W = 'THEN') or (W = 'DO') or (W = 'ELSE')
      or (W = 'TRY') or (W = 'FINALLY') or (W = 'EXCEPT') or (W = 'REPEAT')
      or (W = 'OF') or ((C = ':') and not AMasked[L].TrimRight.EndsWith(':=')) then
      Exit(L + 1);
    Result := L;   // continuation of the statement
  end;
end;

function PlanExtractVariable(const ALines: TArray<string>; ALine0, AStartCol0,
  AEndCol0: Integer; const AName: string; out APlan: TExtractVarPlan;
  out AWhy: string): Boolean;
var
  M: TArray<string>;
  Sel, Before, FirstWord: string;
  Depth, StmtLine, I: Integer;
begin
  Result := False;
  APlan := Default(TExtractVarPlan);
  AWhy := '';
  if (ALine0 < 0) or (ALine0 > High(ALines)) or (AStartCol0 < 0)
    or (AEndCol0 <= AStartCol0) or (AEndCol0 > Length(ALines[ALine0])) then
  begin
    AWhy := 'select an expression on ONE line';
    Exit;
  end;
  if not IsValidIdent(AName) then
  begin
    AWhy := '"' + AName + '" is not a valid identifier';
    Exit;
  end;
  Sel := Copy(ALines[ALine0], AStartCol0 + 1, AEndCol0 - AStartCol0);
  if Trim(Sel) = '' then begin AWhy := 'the selection is empty'; Exit; end;
  Sel := Trim(Sel);
  M := MaskCommentsAndStrings(ALines);
  // the selection must be CODE at both ends (not inside a comment/string)
  // and balanced: brackets, and no statement separator inside
  var SelM := Copy(M[ALine0], AStartCol0 + 1, AEndCol0 - AStartCol0);
  // skip leading blanks of the selection; its first real character must be
  // code - or the opening quote of a string literal
  var FirstIdx := AStartCol0 + 1;
  while (FirstIdx <= AEndCol0) and CharInSet(ALines[ALine0][FirstIdx], [' ', #9]) do
    Inc(FirstIdx);
  if (M[ALine0][FirstIdx] <> ALines[ALine0][FirstIdx])
    and (ALines[ALine0][FirstIdx] <> '''') and (ALines[ALine0][FirstIdx] <> '#') then
  begin
    AWhy := 'the selection starts inside a comment or string';
    Exit;
  end;
  Depth := 0;
  for I := 1 to Length(SelM) do
    case SelM[I] of
      '(', '[': Inc(Depth);
      ')', ']':
        begin
          Dec(Depth);
          if Depth < 0 then Break;
        end;
      ';': begin AWhy := 'the selection contains a statement end ";"'; Exit; end;
    end;
  if Depth <> 0 then
  begin
    AWhy := 'the selection is not a complete expression (unbalanced brackets)';
    Exit;
  end;
  if Sel.Contains(':=') then
  begin
    AWhy := 'the selection contains an assignment - select an expression';
    Exit;
  end;

  StmtLine := StatementStartLine(M, ALine0);
  if IsSoleBranchStatement(ALines, StmtLine) then
  begin
    AWhy := 'the statement is the only one of a then/else/do branch - put it ' +
      'into begin..end first (a declaration before it would leave the branch)';
    Exit;
  end;
  // everything of the statement in front of the selection
  Before := '';
  for I := StmtLine to ALine0 - 1 do Before := Before + ' ' + M[I];
  Before := Before + ' ' + Copy(M[ALine0], 1, AStartCol0);
  FirstWord := '';
  var T := TrimLeft(Before);
  I := 1;
  while (I <= Length(T)) and IsIdentChar(T[I]) do Inc(I);
  FirstWord := UpperCase(Copy(T, 1, I - 1));
  // "1: Foo(X)" - a case branch or label: no declaration can go before it
  var ColonP := Pos(':', T);
  if (ColonP > 0) and ((ColonP = Length(T)) or (T[ColonP + 1] <> '=')) then
  begin
    AWhy := 'the statement is a case branch or carries a label - put it into ' +
      'begin..end first';
    Exit;
  end;
  if (FirstWord = 'WHILE') or (FirstWord = 'UNTIL') then
  begin
    AWhy := 'the expression is part of a loop condition - it is evaluated on ' +
      'every iteration';
    Exit;
  end;
  for var W in ['AND', 'OR', 'THEN', 'ELSE', 'DO', 'OF', 'EXCEPT', 'FINALLY'] do
    if HasWordCI(Before, W) then
    begin
      if (W = 'AND') or (W = 'OR') then
        AWhy := 'the expression follows a short-circuit "' + LowerCase(W) + '" - ' +
          'hoisting it would evaluate it unconditionally'
      else
        AWhy := 'the expression sits in a branch or loop body on the same line ' +
          '("' + LowerCase(W) + '") - put that part on its own line first';
      Exit;
    end;
  // inside a with? its names may bind to the with target
  var Src := string.Join(sLineBreak, ALines);
  for var Occ in TWithScanner.ScanSource(Src) do
    if (ALine0 + 1 >= Occ.BodyRange.StartPos.Line) and (ALine0 + 1 <= Occ.BodyRange.EndPos.Line) then
    begin
      AWhy := 'the selection is inside a "with" - remove the with first';
      Exit;
    end;
  // the name must be free in the routine
  var RF, RL: Integer;
  if FindEnclosingRoutineRange(Src, ALine0, RF, RL) then
  begin
    for var L in CodeWordLines(Copy(ALines, RF, RL - RF + 1), AName) do
    begin
      AWhy := Format('"%s" is already used in this routine (line %d)', [AName, RF + L + 1]);
      Exit;
    end;
  end
  else
  begin
    AWhy := 'the selection is not inside a routine';
    Exit;
  end;

  APlan.StatementLine := StmtLine;
  APlan.DeclText := LeadingBlanks(ALines[StmtLine]) + 'var ' + AName + ' := ' + Sel + ';';
  SetLength(APlan.NewLines, Length(ALines) + 1);
  for I := 0 to StmtLine - 1 do APlan.NewLines[I] := ALines[I];
  APlan.NewLines[StmtLine] := APlan.DeclText;
  for I := StmtLine to High(ALines) do APlan.NewLines[I + 1] := ALines[I];
  APlan.NewLines[ALine0 + 1] := Copy(ALines[ALine0], 1, AStartCol0) + AName +
    Copy(ALines[ALine0], AEndCol0 + 1, MaxInt);
  Result := True;
end;

function InferCleanup(const APrevStatement: string): string;
var
  S, U, Target: string;
  P: Integer;
begin
  Result := '';
  S := Trim(APrevStatement);
  while S.EndsWith(';') do S := TrimRight(Copy(S, 1, Length(S) - 1));
  if S = '' then Exit;
  U := UpperCase(S);
  // X := TFoo.Create(...) / X := TFoo.CreateFmt(...)
  P := Pos(':=', S);
  if P > 1 then
  begin
    Target := Trim(Copy(S, 1, P - 1));
    if StartsText('VAR ', UpperCase(Target)) then Target := Trim(Copy(Target, 5, MaxInt));
    var Colon := Pos(':', Target);
    if Colon > 0 then Target := Trim(Copy(Target, 1, Colon - 1));
    var Rhs := UpperCase(Trim(Copy(S, P + 2, MaxInt)));
    if IsValidIdent(Target, True) and (Pos('.CREATE', Rhs) > 0) then
      Exit(Target + '.Free');
    Exit;
  end;
  // TMonitor.Enter(X)
  if StartsText('TMONITOR.ENTER(', U) then
    Exit('TMonitor.Exit(' + Copy(S, Length('TMonitor.Enter(') + 1, MaxInt));
  // X.BeginUpdate / X.Enter / X.Acquire / X.Lock / X.BeginWrite / X.BeginRead
  P := LastDelimiter('.', S);
  if P > 1 then
  begin
    Target := Copy(S, 1, P - 1);
    var Meth := UpperCase(Copy(S, P + 1, MaxInt));
    if not IsValidIdent(Target, True) then Exit;
    if Meth = 'BEGINUPDATE' then Exit(Target + '.EndUpdate');
    if Meth = 'ENTER' then Exit(Target + '.Leave');
    if Meth = 'ACQUIRE' then Exit(Target + '.Release');
    if Meth = 'LOCK' then Exit(Target + '.Unlock');
    if Meth = 'BEGINWRITE' then Exit(Target + '.EndWrite');
    if Meth = 'BEGINREAD' then Exit(Target + '.EndRead');
  end;
end;

function PlanWrapTryFinally(const ALines: TArray<string>; AFirst0, ALast0: Integer;
  const ACleanup: string; out ANewLines: TArray<string>; out AWhy: string): Boolean;
var
  M: TArray<string>;
  Blocks, Parens, I: Integer;
  Indent, Cleanup: string;
  Res: TArray<string>;
begin
  Result := False;
  ANewLines := nil;
  AWhy := '';
  if (AFirst0 < 0) or (ALast0 > High(ALines)) or (ALast0 < AFirst0) then
  begin
    AWhy := 'select the statements to wrap';
    Exit;
  end;
  M := MaskCommentsAndStrings(ALines);
  // complete statements: block openers and ends balance, parentheses too,
  // and the last line ends a statement
  Blocks := 0;
  Parens := 0;
  for I := AFirst0 to ALast0 do
  begin
    var U := UpperCase(M[I]);
    var K := 1;
    while K <= Length(U) do
    begin
      if CharInSet(U[K], ['A'..'Z', '_']) and ((K = 1) or not IsIdentChar(U[K - 1])) then
      begin
        var S := K;
        while (K <= Length(U)) and IsIdentChar(U[K]) do Inc(K);
        var W := Copy(U, S, K - S);
        if (W = 'BEGIN') or (W = 'TRY') or (W = 'CASE') or (W = 'ASM') then Inc(Blocks)
        else if W = 'END' then Dec(Blocks);
        if Blocks < 0 then Break;
        Continue;
      end;
      if U[K] = '(' then Inc(Parens) else if U[K] = ')' then Dec(Parens);
      Inc(K);
    end;
    if Blocks < 0 then Break;
  end;
  if (Blocks <> 0) or (Parens <> 0) then
  begin
    AWhy := 'the selected lines are not complete statements (unbalanced ' +
      'begin/try/case..end or brackets)';
    Exit;
  end;
  var LastChar: Char;
  var LastW := LastCodeWord(M[ALast0], LastChar);
  if not ((LastChar = ';') or (LastW = 'END')) then
  begin
    AWhy := 'the selection does not end with a complete statement';
    Exit;
  end;
  // "if X then" / "  A;" / "B;": wrapping A and B would take B into the
  // branch as well
  if IsSoleBranchStatement(ALines, StatementStartLine(M, AFirst0)) then
  begin
    AWhy := 'the statement is the only one of a then/else/do branch - put it ' +
      'into begin..end first (the try would take the following statements ' +
      'into the branch)';
    Exit;
  end;
  Indent := LeadingBlanks(ALines[AFirst0]);
  Cleanup := ACleanup;
  if Cleanup = '' then Cleanup := '// TODO: release what the block acquired'
  else if not Cleanup.EndsWith(';') then Cleanup := Cleanup + ';';
  Res := Copy(ALines, 0, AFirst0);
  Res := Res + [Indent + 'try'];
  for I := AFirst0 to ALast0 do
    if Trim(ALines[I]) = '' then Res := Res + [ALines[I]]
    else Res := Res + ['  ' + ALines[I]];
  Res := Res + [Indent + 'finally', Indent + '  ' + Cleanup, Indent + 'end;'];
  Res := Res + Copy(ALines, ALast0 + 1, MaxInt);
  ANewLines := Res;
  Result := True;
end;

// ---------------------------------------------------------------------------
//  Editor entry points
// ---------------------------------------------------------------------------

function ReadLinesOf(const AFile: string; out AContent: string;
  out ALines: TArray<string>): Boolean;
var
  SL: TStringList;
begin
  Result := (Editor <> nil) and Editor.ReadEditorContent(AFile, AContent);
  if not Result then Exit;
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    ALines := SL.ToStringArray;
  finally
    SL.Free;
  end;
end;

function WriteLines(const AFile, AOriginal: string; const ALines: TArray<string>): Boolean;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    for var L in ALines do SL.Add(L);
    Result := ApplyLinesMinimal(AFile, SL, AOriginal);
  finally
    SL.Free;
  end;
end;

// ---------------------------------------------------------------------------
//  Declare a selection as a constant (forum idea 2026-10-15: "Extract
//  Constant" for a number, "Extract Resource string" for a string). The
//  user's own answer is the design and the reason there is ONE function:
//  "eine einzelne Funktion deklarieren, die eine Selektion automatisch als
//  Wert uebernimmt. Dann sagt man den Typ und den Ort."
// ---------------------------------------------------------------------------

function ClassifyDeclareValue(const ASelection: string): TDeclareValueKind;
var
  Sc: TPascalScanner;
  Tok: TPasToken;
  Numbers, Strings: Integer;
begin
  Result := dvNone;
  if Trim(ASelection) = '' then Exit;
  // A multi-line literal cannot be judged (and cannot be selected on one
  // line in the first place).
  if ASelection.Contains('''''''') then Exit(dvOther);
  Numbers := 0;
  Strings := 0;
  Sc := TPascalScanner.Create(ASelection);
  try
    while Sc.Next(Tok) do
      case Tok.Kind of
        ptNumber: Inc(Numbers);
        ptString: Inc(Strings);
        ptSymbol:
          // Only what can stand BETWEEN literals of a constant expression.
          // Anything else (',', ':=', '[') means the selection is not one
          // value.
          if (Tok.Text <> '+') and (Tok.Text <> '-') and (Tok.Text <> '*')
            and (Tok.Text <> '/') and (Tok.Text <> '(') and (Tok.Text <> ')')
          then
            Exit(dvOther);
      else
        // an identifier, and with it a name that need not be in scope where
        // the declaration goes
        Exit(dvOther);
      end;
  finally
    Sc.Free;
  end;
  if (Numbers > 0) and (Strings = 0) then Result := dvNumber
  else if (Strings > 0) and (Numbers = 0) then Result := dvString
  else if (Numbers > 0) or (Strings > 0) then Result := dvOther;
end;

// 'Datei nicht gefunden' -> 'DateiNichtGefunden', capped - a name, not a
// sentence.
function WordsToPascalCase(const AText: string; AMaxChars: Integer): string;
var
  C: Char;
  AtStart: Boolean;
begin
  Result := '';
  AtStart := True;
  for C in AText do
  begin
    if IsIdentChar(C) and not CharInSet(C, ['0'..'9']) or
      (not AtStart and CharInSet(C, ['0'..'9'])) then
    begin
      if AtStart then Result := Result + UpCase(C) else Result := Result + C;
      AtStart := False;
    end
    else
      AtStart := True;   // a separator: the next letter starts a word
    if Length(Result) >= AMaxChars then Break;
  end;
end;

function SuggestConstantName(const ASelection, AContextBefore: string;
  AKind: TDeclareValueKind): string;
var
  Core, Ident: string;
begin
  if AKind = dvString then
  begin
    // The literal says what it means, so use its own words.
    Core := ASelection;
    Core := StringReplace(Core, '''', ' ', [rfReplaceAll]);
    Result := 'S' + WordsToPascalCase(Core, 28);
    if Result = 'S' then Result := 'SText';
    Exit;
  end;
  // A number says nothing, so the name has to come from the code around it -
  // and WHICH identifier is the meaning is decided by the separator right
  // before the number, not by proximity:
  //   Timeout := 5000     ':='  -> the assignment target
  //   if I > 5000         '>'   -> what it is compared with
  //   SetTimeout(5000)    '('   -> the routine it is passed to
  //   X := Y + 5000       '+'   -> nothing; Y is an operand, not a meaning
  Ident := '';
  var Ctx := TrimRight(AContextBefore);
  var Sep := '';
  for var Cand in ['(', ':=', '<>', '<=', '>=', '>', '<', '='] do
    if Ctx.EndsWith(Cand) then
    begin
      Sep := Cand;
      Break;
    end;
  if Sep <> '' then
  begin
    Ctx := TrimRight(Copy(Ctx, 1, Length(Ctx) - Length(Sep)));
    var IdentCol: Integer;
    Ident := IdentifierBefore(Ctx, Length(Ctx) + 1, IdentCol);
  end;
  if (Ident <> '') and TIdentifierChecker.IsPascalKeyword(Ident) then Ident := '';
  // "SetTimeout(" / "GetTimeout(" both mean Timeout.
  if (Length(Ident) > 4) and (SameText(Copy(Ident, 1, 3), 'Set')
    or SameText(Copy(Ident, 1, 3), 'Get')) then
    Ident := Copy(Ident, 4, MaxInt);
  if Ident = '' then Exit('CValue');
  Result := 'C' + UpCase(Ident[1]) + Copy(Ident, 2, MaxInt);
end;

// The token the selection is, or Kind = ptEnd when the selection is not
// exactly one token of CODE. Scanning the whole content rather than the one
// line is deliberate: a line inside a { } comment opened further up yields
// no tokens at all, which is the answer we want there.
function TokenOfSelection(const AContent: string; ALine0, AStartCol0,
  AEndCol0: Integer; out APrevKind: TPasTokenKind;
  out APrevText: string): TPasToken;
var
  Sc: TPascalScanner;
  Tok: TPasToken;
begin
  Result := Default(TPasToken);
  Result.Kind := ptEnd;
  APrevKind := ptEnd;
  APrevText := '';
  Sc := TPascalScanner.Create(AContent);
  try
    var PrevK := ptEnd;
    var PrevT := '';
    while Sc.Next(Tok) do
    begin
      if (Tok.Line = ALine0) and (Tok.Col = AStartCol0)
        and (Tok.Col + Length(Tok.Text) = AEndCol0) then
      begin
        APrevKind := PrevK;
        APrevText := PrevT;
        Exit(Tok);
      end;
      if (Tok.Line > ALine0) then Break;
      PrevK := Tok.Kind;
      PrevT := Tok.Text;
    end;
  finally
    Sc.Free;
  end;
end;

// Every occurrence of exactly this literal in [AFrom, ATo], as (line, col)
// pairs. Only complete tokens, so 100 never matches inside 1000, and only
// code, because a comment produces no token.
function LiteralOccurrences(const AContent: string; const AText: string;
  AFrom, ATo: Integer): TArray<TPasToken>;
var
  Sc: TPascalScanner;
  Tok: TPasToken;
begin
  Result := nil;
  Sc := TPascalScanner.Create(AContent);
  try
    while Sc.Next(Tok) do
      if (Tok.Line >= AFrom) and (Tok.Line <= ATo) and (Tok.Text = AText)
        and (Tok.Kind in [ptNumber, ptString]) then
        Result := Result + [Tok];
  finally
    Sc.Free;
  end;
end;

// The last line of the top-level section AKeyword inside [AFrom, ATo], or
// -1. A section ends at the next top-level keyword.
function UnitSectionEnd(const ALines: TArray<string>; const AKeyword: string;
  AFrom, ATo: Integer): Integer;
const
  Enders: array[0..12] of string = ('TYPE', 'CONST', 'VAR', 'RESOURCESTRING',
    'THREADVAR', 'PROCEDURE', 'FUNCTION', 'CLASS', 'IMPLEMENTATION',
    'INTERFACE', 'INITIALIZATION', 'FINALIZATION', 'END.');
var
  I, J, Last: Integer;
  T, U: string;

  function TopLevel(ALine: Integer): Boolean;
  begin
    Result := Length(ALines[ALine]) - Length(TrimLeft(ALines[ALine])) <= 2;
  end;

  function StartsAnother(const AUpper: string): Boolean;
  var
    E: string;
  begin
    for E in Enders do
      if (AUpper = E) or AUpper.StartsWith(E + ' ') then Exit(True);
    Result := False;
  end;

begin
  Result := -1;
  for I := Max(0, AFrom) to Min(High(ALines), ATo) do
  begin
    T := Trim(StripLineComment(ALines[I]));
    U := UpperCase(T);
    if not TopLevel(I) then Continue;
    if (U = UpperCase(AKeyword)) or U.StartsWith(UpperCase(AKeyword) + ' ') then
    begin
      // walk to the end of THIS section
      Last := I;
      for J := I + 1 to Min(High(ALines), ATo) do
      begin
        T := Trim(StripLineComment(ALines[J]));
        U := UpperCase(T);
        if (T <> '') and TopLevel(J) and StartsAnother(U) then Break;
        if T <> '' then Last := J;
      end;
      Result := Last;
    end;
  end;
end;

// Where a NEW top-level section goes in [AFrom, ATo]: before the first
// type / var / routine, which is also where a constant must stand when a
// type below it uses it.
function UnitSectionAnchor(const ALines: TArray<string>; AFrom,
  ATo: Integer): Integer;
var
  I, Stop: Integer;
  T, U: string;
begin
  Stop := Min(High(ALines), ATo);
  Result := Min(High(ALines) + 1, Max(0, AFrom));
  I := Max(0, AFrom);
  while I <= Stop do
  begin
    T := Trim(StripLineComment(ALines[I]));
    U := UpperCase(T);
    if T = '' then
    begin
      Inc(I);
      Continue;
    end;
    // skip the section's own uses clause - it may wrap over lines
    if U.StartsWith('USES') then
    begin
      while (I <= Stop) and (Pos(';', StripLineComment(ALines[I])) = 0) do Inc(I);
      Inc(I);
      Result := I;
      Continue;
    end;
    if (U = 'TYPE') or U.StartsWith('TYPE ') or (U = 'VAR') or U.StartsWith('VAR ')
      or (U = 'CONST') or U.StartsWith('CONST ') or (U = 'RESOURCESTRING')
      or U.StartsWith('PROCEDURE ') or U.StartsWith('FUNCTION ')
      or U.StartsWith('CLASS ') or (U = 'IMPLEMENTATION') or (U = 'END.') then
      Exit(I);
    Inc(I);
  end;
end;

function DeclareRequestFor(const ALines: TArray<string>;
  ALine0, AStartCol0, AEndCol0: Integer): TDeclareRequest;
var
  Sel: string;
begin
  Result := Default(TDeclareRequest);
  Result.Line0 := ALine0;
  Result.Place := dplLocal;
  Result.Section := dsConst;
  Result.HasSelection := (ALine0 >= 0) and (ALine0 <= High(ALines))
    and (AEndCol0 > AStartCol0) and (AStartCol0 >= 0);
  if not Result.HasSelection then
  begin
    // From scratch: the user names the value too. A place that needs no
    // enclosing routine is the safer default then.
    Result.Name := 'CValue';
    Exit;
  end;
  Result.StartCol0 := AStartCol0;
  Result.EndCol0 := AEndCol0;
  Sel := Copy(ALines[ALine0], AStartCol0 + 1, AEndCol0 - AStartCol0);
  Result.Value := Sel;
  Result.Name := SuggestConstantName(Sel, Copy(ALines[ALine0], 1, AStartCol0),
    ClassifyDeclareValue(Sel));
end;

function PlanDeclare(const ALines: TArray<string>;
  const AReq: TDeclareRequest; out APlan: TDeclarePlan;
  out AWhy: string): Boolean;
var
  Content, Value, Sel, Decl, Keyword, Problem: string;
  Kind: TDeclareValueKind;
  Tok: TPasToken;
  PrevKind: TPasTokenKind;
  PrevText: string;
  Lines: TArray<string>;
  Hits: TArray<TPasToken>;
  First, Last, InsLine, I: Integer;
  ALine0, AStartCol0, AEndCol0: Integer;
  AName, AType: string;
  APlace: TDeclarePlace;
  ASection: TDeclareSection;
  AReplaceAll: Boolean;
begin
  ALine0 := AReq.Line0;
  AStartCol0 := AReq.StartCol0;
  AEndCol0 := AReq.EndCol0;
  AName := AReq.Name;
  AType := AReq.TypeName;
  APlace := AReq.Place;
  ASection := AReq.Section;
  AReplaceAll := AReq.ReplaceAll and AReq.HasSelection;
  // No "Result := False" here: every refusal below goes through SetWhy,
  // which answers False - so a path that forgets the reason cannot compile
  // as a silent failure either.
  APlan := Default(TDeclarePlan);
  APlan.InsertLine0 := -1;
  AWhy := '';
  if (ALine0 < 0) or (ALine0 > High(ALines)) then Exit(SetWhy(AWhy, 'the line is not in this file'));

  Content := string.Join(#10, ALines);
  Value := Trim(AReq.Value);
  if Value = '' then Exit(SetWhy(AWhy, 'enter a value'));

  // --- the VALUE is what gets declared, so it is what must be a literal ----
  Kind := ClassifyDeclareValue(Value);
  if not (Kind in [dvNumber, dvString]) then
    Exit(SetWhy(AWhy, 'the value must be a literal - a number, a string, or ' +
      'an expression of those; a name in it need not be in scope where the ' +
      'declaration goes'));

  // --- a SELECTION, when there is one, must be one literal of code ---------
  Tok := Default(TPasToken);
  Tok.Kind := ptEnd;
  if AReq.HasSelection then
  begin
    if (AStartCol0 < 0) or (AEndCol0 <= AStartCol0) then
      Exit(SetWhy(AWhy, 'the selection is empty'));
    Sel := Copy(ALines[ALine0], AStartCol0 + 1, AEndCol0 - AStartCol0);
    Tok := TokenOfSelection(Content, ALine0, AStartCol0, AEndCol0, PrevKind, PrevText);
    if Tok.Kind = ptEnd then
    begin
      // A selected unary minus together with its number is two tokens, and
      // whether the minus belongs to the value depends on what stands before
      // it - that is a question the user should answer, not us.
      if (Length(Sel) > 1) and (Sel[1] = '-') then
        Exit(SetWhy(AWhy, 'the minus may belong to the expression - select the number itself'));
      Exit(SetWhy(AWhy, 'select exactly one number or string literal (and not inside a comment)'));
    end;
    if not (Tok.Kind in [ptNumber, ptString]) then
      Exit(SetWhy(AWhy, 'only a number or a string literal can be replaced by a constant'));
  end;

  // --- the name ------------------------------------------------------------
  Problem := DeclarationNameProblem(AName, 'constant');
  if Problem <> '' then Exit(SetWhy(AWhy, Problem));

  // --- what Delphi allows where --------------------------------------------
  if ASection = dsResourceString then
  begin
    if Kind <> dvString then
      Exit(SetWhy(AWhy, 'a resourcestring holds a string - the value must be a string literal'));
    if not (APlace in [dplInterface, dplImplementation]) then
      Exit(SetWhy(AWhy, 'a resourcestring can only be declared at unit level'));
    if Trim(AType) <> '' then
      Exit(SetWhy(AWhy, 'a resourcestring has no type of its own'));
    Keyword := 'resourcestring';
  end
  else
    Keyword := 'const';

  if Trim(AType) <> '' then
    Decl := AName + ': ' + Trim(AType) + ' = ' + Value
  else
    Decl := AName + ' = ' + Value;

  // --- is the name free where it would be declared? ------------------------
  if APlace = dplLocal then
  begin
    if not FindEnclosingRoutineRange(Content, ALine0, First, Last) then
      Exit(SetWhy(AWhy, 'the selection is not inside a routine'));
    // Conservative on purpose: any whole-word occurrence inside the routine
    // refuses, which at worst costs the user a different name - a duplicate
    // identifier would cost a unit that does not compile.
    if Length(CodeWordLines(Copy(ALines, First, Last - First + 1), AName)) > 0 then
      Exit(SetWhy(AWhy, Format('"%s" already occurs in this routine', [AName])));
  end
  else if Length(CodeWordLines(ALines, AName)) > 0 then
    Exit(SetWhy(AWhy, Format('"%s" already occurs in this unit', [AName])));

  // --- replace, then insert ------------------------------------------------
  Lines := Copy(ALines);
  Hits := nil;
  if AReplaceAll then
  begin
    // Keyed on the SELECTED literal, not on the (possibly edited) value -
    // the other occurrences are the ones that look like what was selected.
    if APlace = dplLocal then
      Hits := LiteralOccurrences(Content, Sel, First, Last)
    else
      Hits := LiteralOccurrences(Content, Sel, 0, High(ALines));
  end
  else if AReq.HasSelection then
    Hits := [Tok];
  // right to left per line, so the columns stay valid
  for I := High(Hits) downto 0 do
  begin
    var H := Hits[I];
    if (H.Line < 0) or (H.Line > High(Lines)) then Continue;
    Lines[H.Line] := Copy(Lines[H.Line], 1, H.Col) + AName +
      Copy(Lines[H.Line], H.Col + Length(H.Text) + 1, MaxInt);
    Inc(APlan.Replaced);
  end;
  if APlan.Replaced > 1 then
    APlan.Note := Format('%d occurrences of %s replaced', [APlan.Replaced, Sel])
  else if not AReq.HasSelection then
    APlan.Note := 'declared only - nothing in the code was changed';

  case APlace of
    dplLocal:
      if not PlanLocalDecl(Lines, ALine0, Keyword, Decl, InsLine, APlan.DeclText) then
        Exit(SetWhy(AWhy, 'no place for a local const (a nested routine before the body?)'));
    dplClass:
      begin
        if not FindEnclosingRoutineRange(Content, ALine0, First, Last) then
          Exit(SetWhy(AWhy, 'the selection is not inside a method'));
        var Owner := OwnerTypeOfImplHeader(Lines[First]);
        if Owner = '' then
          Exit(SetWhy(AWhy, 'the enclosing routine is no method of a class'));
        var CFirst, CLast: Integer;
        if not ClassBodyRange(Lines, Owner, CFirst, CLast) then
          Exit(SetWhy(AWhy, Format('the declaration of %s was not found in this unit', [Owner])));
        var FirstDecl: Integer;
        if not PlanMemberInsertion(Lines, CFirst, 'private',
          [Keyword + ' ' + Decl + ';'], InsLine, APlan.DeclText, FirstDecl) then
          Exit(SetWhy(AWhy, Format('no place for a const inside %s', [Owner])));
      end;
  else
    begin
      var ImplLine := ImplementationLineOf(Lines);
      if APlace = dplInterface then
      begin
        First := 0;
        Last := ImplLine - 1;
      end
      else
      begin
        if ImplLine > High(Lines) then
          Exit(SetWhy(AWhy, 'this unit has no implementation section'));
        First := ImplLine + 1;
        Last := High(Lines);
      end;
      var SecEnd := UnitSectionEnd(Lines, Keyword, First, Last);
      if SecEnd >= 0 then
      begin
        // append to the section that is already there
        InsLine := SecEnd + 1;
        APlan.DeclText := '  ' + Decl + ';' + sLineBreak;
      end
      else
      begin
        InsLine := UnitSectionAnchor(Lines, First, Last);
        APlan.DeclText := Keyword + sLineBreak + '  ' + Decl + ';' + sLineBreak +
          sLineBreak;
      end;
    end;
  end;

  APlan.InsertLine0 := InsLine;
  APlan.NewLines := Copy(Lines, 0, InsLine) +
    SplitEditorLines(APlan.DeclText.TrimRight([#13, #10])) +
    Copy(Lines, InsLine, Length(Lines) - InsLine);
  Result := True;
end;

procedure ExtractVariableAtSelection;
var
  F, Text, Content, Name, Why: string;
  SL, SC, EL, EC: Integer;
  Lines: TArray<string>;
  Plan: TExtractVarPlan;
begin
  if (Editor = nil) or not Editor.GetSelection(F, SL, SC, EL, EC, Text) or (Trim(Text) = '') then
  begin
    ShowThemedMessage('Extract variable: select the expression first.');
    Exit;
  end;
  if (EL <> SL) or Text.Contains(#10) then
  begin
    ShowThemedMessage('Extract variable: select an expression on ONE line.');
    Exit;
  end;
  if not ReadLinesOf(F, Content, Lines) or (SL < 1) or (SL > Length(Lines)) then
  begin
    ShowThemedMessage('Extract variable: the file is not open in the editor.');
    Exit;
  end;
  // The selection's columns are editor columns; trust the selected TEXT and
  // find it on the line at (or right next to) the reported start.
  var Col0 := SC - 1;
  var LineText := Lines[SL - 1];
  if Copy(LineText, Col0 + 1, Length(Text)) <> Text then
  begin
    var P := Pos(Text, LineText, Max(1, Col0 - 1));
    if P = 0 then P := Pos(Text, LineText);
    if P = 0 then
    begin
      ShowThemedMessage('Extract variable: the selection could not be located on the line.');
      Exit;
    end;
    Col0 := P - 1;
  end;
  Name := SuggestVariableName(Text);
  if not AskThemedText('Extract variable', 'Name of the new variable (inline "var"):',
    Name,
    function(S: string): string
    begin
      if IsValidIdent(Trim(S)) then Result := '' else Result := 'not a valid identifier';
    end) then Exit;
  Name := Trim(Name);
  if not PlanExtractVariable(Lines, SL - 1, Col0, Col0 + Length(Text), Name, Plan, Why) then
  begin
    ShowThemedMessage('Extract variable not possible: ' + Why + '.');
    Exit;
  end;
  if not WriteLines(F, Content, Plan.NewLines) then
    ShowThemedMessage('Extract variable: writing the change failed.');
end;

procedure WrapSelectionInTryFinally;
var
  F, Text, Content, Why, Cleanup: string;
  SL, SC, EL, EC: Integer;
  Lines, NewLines: TArray<string>;
begin
  if (Editor = nil) or not Editor.GetSelection(F, SL, SC, EL, EC, Text) or (Trim(Text) = '') then
  begin
    ShowThemedMessage('Wrap in try..finally: select the statements first.');
    Exit;
  end;
  if EC = 1 then Dec(EL);   // a selection ending at a line start excludes that line
  if not ReadLinesOf(F, Content, Lines) or (SL < 1) or (EL > Length(Lines)) then
  begin
    ShowThemedMessage('Wrap in try..finally: the file is not open in the editor.');
    Exit;
  end;
  // the statement before the selection names what to release
  Cleanup := '';
  for var L := SL - 2 downto 0 do
    if Trim(Lines[L]) <> '' then
    begin
      Cleanup := InferCleanup(Lines[L]);
      Break;
    end;
  if not PlanWrapTryFinally(Lines, SL - 1, EL - 1, Cleanup, NewLines, Why) then
  begin
    ShowThemedMessage('Wrap in try..finally not possible: ' + Why + '.');
    Exit;
  end;
  if not WriteLines(F, Content, NewLines) then
    ShowThemedMessage('Wrap in try..finally: writing the change failed.');
end;

end.
