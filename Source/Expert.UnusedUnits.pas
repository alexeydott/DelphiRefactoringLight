(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Expert.UnusedUnits;

// The pure half of the project check "Unused project units" (issue #47 by
// nLeonardt95): a unit the project FILE lists although nothing in the
// project names it any more. In a long-lived project those keep being
// compiled and keep cluttering the project tree.
//
// MEASURED on a real project before this was designed (1822 units in the
// .dpr): 119 units are named in no other unit's uses clause - and SIX of
// them are reached from the .dpr's own body (Application.CreateForm and
// friends), so the body test is not a refinement, it is what keeps the
// answer from being wrong. Of the rest, 39 carry an initialization or
// finalization section and 74 do not.
//
// POLARITY, and every rule below follows from it: a wrong "unused" makes
// somebody remove a unit the project needs. So anything this check cannot
// prove counts as USED, and whatever it could not look at is NAMED instead
// of being silently left out of the answer.

interface

uses
  System.SysUtils;

type
  /// <summary>Why a unit the project lists is reported.</summary>
  TUnusedUnitKind = (
    /// <summary>Nothing names it and it has no load-time side effects -
    ///  the project entry can go.</summary>
    uukSafe,
    /// <summary>Nothing names it, but it has an initialization or
    ///  finalization section. Such a unit is often in the project for
    ///  exactly that reason - a class factory registering itself, an IoC
    ///  container, an RTTI or logger registration - so this is a HINT to
    ///  check, never a "safe to remove".</summary>
    uukInitCode,
    /// <summary>Its text could not be read, so nothing about it was
    ///  decided. Listed so the answer does not look complete.</summary>
    uukUnreadable);

  /// <summary>What the caller found out about one file. The project's own
  ///  units and the units merely reachable from them share this record;
  ///  only InProject units can ever be reported, the others are read for
  ///  their uses clause alone - a unit on the search path can name a
  ///  project unit, and then that unit is used.</summary>
  TUnitFacts = record
    /// <summary>The unit's own name (not the file name).</summary>
    UnitName: string;
    /// <summary>Full path, '' when the project names a file that is not
    ///  on disk.</summary>
    FileName: string;
    /// <summary>True for a unit the PROJECT FILE lists. Only these are
    ///  candidates.</summary>
    InProject: Boolean;
    /// <summary>True for the project's own main source (.dpr / .dpk).
    ///  Never a candidate, and its uses clause is the project's MEMBERSHIP
    ///  LIST, not a reference - counting it would make every unit used.</summary>
    IsMainUnit: Boolean;
    /// <summary>False when the text could not be read.</summary>
    Readable: Boolean;
    /// <summary>An initialization or finalization section exists.</summary>
    HasInitCode: Boolean;
    /// <summary>The identifiers the unit's interface declares. Only used
    ///  to ask whether the main body reaches into this unit.</summary>
    ExportedIdents: TArray<string>;
    /// <summary>Every name in every uses clause of this unit, interface
    ///  and implementation, in EVERY conditional branch - the scan is
    ///  deliberately configuration-blind, because "no occurrence in any
    ///  branch" is the only statement that holds for every build.</summary>
    UsesNames: TArray<string>;
    /// <summary>For the main unit only: its body, i.e. everything after
    ///  its uses clause, with comments and strings masked.</summary>
    MainBody: string;
  end;

  /// <summary>Fills the EXPENSIVE facts of one unit: its initialization
  ///  section and the identifiers its interface declares. It is called
  ///  only for units that no uses clause names, and that is why it
  ///  exists: MEASURED with the production parser over a real project,
  ///  one unit costs 15.7 ms, so asking for all 1822 of them would take
  ///  half a minute while the ~119 candidates take two seconds. False =
  ///  the unit could not be read after all.</summary>
  TUnusedUnitDetails = reference to function(const AFile: string;
    out AHasInitCode: Boolean;
    out AExportedIdents: TArray<string>): Boolean;

  /// <summary>One reported unit.</summary>
  TUnusedUnitIssue = record
    UnitName: string;
    FileName: string;
    Kind: TUnusedUnitKind;
    /// <summary>One sentence: what was found and what it means.</summary>
    Reason: string;
    /// <summary>Stable id of the PLACE (the file), so an answer can name
    ///  a row whatever the sort order is.</summary>
    Id: string;
  end;

/// <summary>FNV-1a over the lower-cased file name. Same shape as the other
///  project checks' ids - it names the PLACE, never a list position.</summary>
function UnusedUnitIssueId(const AFileName: string): string;

/// <summary>Plain text for a kind, for a list column and a report.</summary>
function UnusedUnitKindText(AKind: TUnusedUnitKind): string;

/// <summary>The project units that nothing in AUnits names any more.
///
///  A unit counts as USED when any OTHER unit's uses clause names it, or
///  when the main source's body names one of the identifiers it declares
///  (which is how a form reached only through Application.CreateForm is
///  used). The main source's own uses clause never counts - that is the
///  project's unit list.
///
///  ANotes receives what limits the answer: files that could not be read,
///  and whether the main body was available at all. A caller must show
///  them - without them a short list looks like a complete one.
///
///  ADetails (may be nil, and then the facts are taken as they arrive)
///  supplies the initialization flag and the exported identifiers, and it
///  is asked ONLY about units no uses clause names.</summary>
function CollectUnusedProjectUnits(const AUnits: TArray<TUnitFacts>;
  out ANotes: TArray<string>;
  const ADetails: TUnusedUnitDetails = nil): TArray<TUnusedUnitIssue>;

implementation

uses
  System.Classes,                    // TStringList, for the notes
  System.Generics.Collections,
  Expert.AutoImport;                 // HasWholeWordCI - one place for it

function UnusedUnitIssueId(const AFileName: string): string;
var
  H: Cardinal;
  B: Byte;
  Key: string;
begin
  Key := LowerCase(AFileName);
  H := 2166136261;
  for B in TEncoding.UTF8.GetBytes(Key) do
  begin
    H := H xor B;
    H := H * 16777619;
  end;
  Result := IntToHex(H, 8);
end;

function UnusedUnitKindText(AKind: TUnusedUnitKind): string;
begin
  case AKind of
    uukSafe: Result := 'unused';
    uukInitCode: Result := 'unused, has initialization';
    uukUnreadable: Result := 'not checked';
  else
    Result := '';
  end;
end;

function CollectUnusedProjectUnits(const AUnits: TArray<TUnitFacts>;
  out ANotes: TArray<string>;
  const ADetails: TUnusedUnitDetails): TArray<TUnusedUnitIssue>;
var
  Referenced: TDictionary<string, Boolean>;
  Notes, Unreadable: TStringList;
  Issues: TList<TUnusedUnitIssue>;
  MainBody, MainName: string;
  HaveMain: Boolean;
  F: TUnitFacts;
  N: string;
  I: Integer;
begin
  ANotes := nil;
  Result := nil;

  Referenced := TDictionary<string, Boolean>.Create;
  Notes := TStringList.Create;
  Unreadable := TStringList.Create;
  Issues := TList<TUnusedUnitIssue>.Create;
  try
    MainBody := '';
    MainName := '';
    HaveMain := False;

    // Pass 1: who is named by whom. The main source is skipped on purpose -
    // its uses clause lists every unit of the project.
    for F in AUnits do
    begin
      if F.IsMainUnit then
      begin
        HaveMain := True;
        MainName := F.UnitName;
        MainBody := F.MainBody;
        Continue;
      end;
      if not F.Readable then
      begin
        // Its uses clause is unknown, so it cannot clear anyone. That makes
        // the whole answer incomplete, which has to be said rather than
        // hidden (a file we did not read is not a file without references).
        if F.FileName <> '' then
          Unreadable.Add(F.FileName)
        else
          Unreadable.Add(F.UnitName);
        Continue;
      end;
      for N in F.UsesNames do
        if N <> '' then
          Referenced.AddOrSetValue(LowerCase(N), True);
    end;

    // Pass 2: the candidates, in the order the project lists them.
    for I := 0 to High(AUnits) do
    begin
      F := AUnits[I];
      if not F.InProject then Continue;
      if F.IsMainUnit then Continue;
      if Referenced.ContainsKey(LowerCase(F.UnitName)) then Continue;

      var Issue := Default(TUnusedUnitIssue);
      Issue.UnitName := F.UnitName;
      Issue.FileName := F.FileName;
      Issue.Id := UnusedUnitIssueId(F.FileName);

      if not F.Readable then
      begin
        Issue.Kind := uukUnreadable;
        Issue.Reason := 'the file could not be read, so nothing about it ' +
          'was decided';
        Issues.Add(Issue);
        Continue;
      end;

      // Only HERE is the expensive half worth asking for - this unit is a
      // candidate, and over a real project that is 119 of 1822 files.
      if Assigned(ADetails) then
      begin
        var HasInit: Boolean;
        var Idents: TArray<string>;
        if ADetails(F.FileName, HasInit, Idents) then
        begin
          F.HasInitCode := HasInit;
          F.ExportedIdents := Idents;
        end
        else
        begin
          Issue.Kind := uukUnreadable;
          Issue.Reason := 'the file could not be read, so nothing about ' +
            'it was decided';
          Issues.Add(Issue);
          Continue;
        end;
      end;

      // Does the main source's body reach into this unit? That is how a
      // form created with Application.CreateForm is used: the body names
      // its TForm1 / Form1, never the unit.
      var Reached := '';
      if MainBody <> '' then
        for N in F.ExportedIdents do
          if (N <> '') and HasWholeWordCI(MainBody, N) then
          begin
            Reached := N;
            Break;
          end;
      if Reached <> '' then Continue;

      if F.HasInitCode then
      begin
        Issue.Kind := uukInitCode;
        Issue.Reason := 'no uses clause names it, but it has an ' +
          'initialization or finalization section - it may be in the ' +
          'project to register itself. Check before removing it.';
      end
      else
      begin
        Issue.Kind := uukSafe;
        Issue.Reason := 'no uses clause names it and it has no ' +
          'initialization or finalization section';
      end;
      Issues.Add(Issue);
    end;

    if not HaveMain then
      Notes.Add('The project''s main source was not read, so a unit used ' +
        'only from its body (Application.CreateForm and friends) cannot ' +
        'be recognised as used.')
    else if MainBody = '' then
      Notes.Add('The body of ' + MainName + ' is empty or was not ' +
        'available, so a unit used only from there cannot be recognised ' +
        'as used.');

    if Unreadable.Count > 0 then
    begin
      Notes.Add(Format('%d file(s) could not be read; a uses clause of ' +
        'theirs may name a unit listed below:', [Unreadable.Count]));
      for I := 0 to Unreadable.Count - 1 do
        Notes.Add('    ' + Unreadable[I]);
    end;

    Notes.Add('Only ONE layer is reported: two unused units that use each ' +
      'other keep each other alive. Run the check again after removing ' +
      'something.');

    Result := Issues.ToArray;
    ANotes := Notes.ToStringArray;
  finally
    Issues.Free;
    Unreadable.Free;
    Notes.Free;
    Referenced.Free;
  end;
end;

end.
