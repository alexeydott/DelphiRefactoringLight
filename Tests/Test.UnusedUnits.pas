(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Test.UnusedUnits;

// Issue #47: the project check "Unused project units". These tests are
// about the direction that can do damage - a unit reported as unused that
// something does use. Each case below is one way that could happen, and
// the measurement on the reporter's own kind of project (1822 units, 119
// unreferenced, SIX of them reached from the .dpr body) is what says which
// of them really occur.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TUnusedUnitsTests = class
  public
    /// <summary>The whole rule set in one project: who is reported, who
    ///  is not, and the two categories the issue asks for.</summary>
    [Test] procedure OnlyUnitsNothingNamesAreReported;
    /// <summary>A unit reached ONLY from the main source's body - the
    ///  Application.CreateForm case, which names the form's class and
    ///  never the unit. Six of them in the measured project.</summary>
    [Test] procedure AFormCreatedFromTheMainBodyIsUsed;
    /// <summary>What the check could not look at is named instead of
    ///  being left out, and the ids name the file, not a row.</summary>
    [Test] procedure WhatWasNotCheckedIsSaidOutLoud;
  end;

implementation

uses
  System.SysUtils, Expert.UnusedUnits;

function Facts(const AUnit, AFile: string; AInProject: Boolean;
  const AUses: TArray<string>): TUnitFacts;
begin
  Result := Default(TUnitFacts);
  Result.UnitName := AUnit;
  Result.FileName := AFile;
  Result.InProject := AInProject;
  Result.Readable := True;
  Result.UsesNames := AUses;
end;

function FindIssue(const AIssues: TArray<TUnusedUnitIssue>;
  const AUnit: string; out AIssue: TUnusedUnitIssue): Boolean;
var
  I: TUnusedUnitIssue;
begin
  for I in AIssues do
    if SameText(I.UnitName, AUnit) then
    begin
      AIssue := I;
      Exit(True);
    end;
  AIssue := Default(TUnusedUnitIssue);
  Result := False;
end;

function NamesOf(const AIssues: TArray<TUnusedUnitIssue>): string;
var
  I: TUnusedUnitIssue;
begin
  Result := '';
  for I in AIssues do
    Result := Result + '|' + I.UnitName;
end;

procedure TUnusedUnitsTests.OnlyUnitsNothingNamesAreReported;
var
  Units: TArray<TUnitFacts>;
  Main, Helper: TUnitFacts;
  Issues: TArray<TUnusedUnitIssue>;
  Notes: TArray<string>;
  Issue: TUnusedUnitIssue;
begin
  // The main source lists FIVE units - that clause is the project's
  // membership list, so it may never count as a reference, or nothing
  // could ever be reported.
  Main := Facts('Proj', 'C:\p\Proj.dpr', True,
    ['UsedByMain', 'Dead', 'Registrar', 'Served', 'Helper']);
  Main.IsMainUnit := True;
  Main.MainBody := 'begin InstallHelper; Application.Run; end.';

  // Helper is reached from the main body, and it is what keeps UsedByMain
  // alive. Without that the check would report Helper too - and rightly
  // so: a unit that only has outgoing references is unused.
  Helper := Facts('Helper', 'C:\p\Helper.pas', True, ['UsedByMain']);
  Helper.ExportedIdents := ['InstallHelper'];

  Units := [Main,
    // not named by the main body, but named by Helper below
    Facts('UsedByMain', 'C:\p\UsedByMain.pas', True, []),
    // nobody names it, no side effects -> the finding the issue is about
    Facts('Dead', 'C:\p\Dead.pas', True, []),
    // nobody names it either, but it registers itself -> hint only
    Facts('Registrar', 'C:\p\Registrar.pas', True, []),
    // named by a unit that is NOT in the project (it sits on the search
    // path and was pulled in through a uses clause) - that still makes it
    // used, which is why reference sources are read beyond the project
    Facts('Served', 'C:\p\Served.pas', True, []),
    Helper,
    Facts('PathUnit', 'C:\lib\PathUnit.pas', False, ['Served'])];
  Units[3].HasInitCode := True;         // Registrar

  Issues := CollectUnusedProjectUnits(Units, Notes);

  Assert.AreEqual('|Dead|Registrar', NamesOf(Issues), False,
    'the main unit, a unit named by another unit, and a unit named from ' +
    'the search path are all used');

  Assert.IsTrue(FindIssue(Issues, 'Dead', Issue), 'Dead is reported');
  Assert.AreEqual(Ord(uukSafe), Ord(Issue.Kind), 'no side effects');

  Assert.IsTrue(FindIssue(Issues, 'Registrar', Issue), 'Registrar is reported');
  Assert.AreEqual(Ord(uukInitCode), Ord(Issue.Kind),
    'an initialization section is a hint, never a "safe to remove"');
  Assert.IsTrue(Issue.Reason.Contains('register itself'),
    'and the row says why: ' + Issue.Reason);
end;

procedure TUnusedUnitsTests.AFormCreatedFromTheMainBodyIsUsed;
var
  Units: TArray<TUnitFacts>;
  Main, Form1, Form2: TUnitFacts;
  Issues: TArray<TUnusedUnitIssue>;
  Notes: TArray<string>;
begin
  Main := Facts('Proj', 'C:\p\Proj.dpr', True, ['Unit1', 'Unit2']);
  Main.IsMainUnit := True;
  // The body names the form's CLASS and its variable - never the unit.
  Main.MainBody :=
    'begin' + sLineBreak +
    '  Application.Initialize;' + sLineBreak +
    '  Application.CreateForm(TForm1, Form1);' + sLineBreak +
    '  Application.Run;' + sLineBreak +
    'end.';

  Form1 := Facts('Unit1', 'C:\p\Unit1.pas', True, []);
  Form1.ExportedIdents := ['TForm1', 'Form1'];
  Form2 := Facts('Unit2', 'C:\p\Unit2.pas', True, []);
  Form2.ExportedIdents := ['TForm2', 'Form2'];

  Units := [Main, Form1, Form2];
  Issues := CollectUnusedProjectUnits(Units, Notes);

  Assert.AreEqual('|Unit2', NamesOf(Issues), False,
    'Unit1 is reached through TForm1 in the main body, Unit2 is not');

  // A name that only OCCURS as part of another word is no reference.
  Form2.ExportedIdents := ['TForm'];     // "TForm1" contains it
  Units := [Main, Form1, Form2];
  Issues := CollectUnusedProjectUnits(Units, Notes);
  Assert.AreEqual('|Unit2', NamesOf(Issues), False,
    'TForm is not named by the body just because TForm1 is');
end;

procedure TUnusedUnitsTests.WhatWasNotCheckedIsSaidOutLoud;
var
  Units: TArray<TUnitFacts>;
  Main, Broken, Dead: TUnitFacts;
  Issues: TArray<TUnusedUnitIssue>;
  Notes: TArray<string>;
  Joined: string;
  N: string;
  Issue: TUnusedUnitIssue;
begin
  Main := Facts('Proj', 'C:\p\Proj.dpr', True, ['Broken', 'Dead']);
  Main.IsMainUnit := True;
  Main.MainBody := 'begin end.';

  // A file we could not read may be exactly the one that names Dead, so
  // the answer is incomplete and has to say so.
  Broken := Facts('Broken', 'C:\p\Broken.pas', True, []);
  Broken.Readable := False;
  Dead := Facts('Dead', 'C:\p\Dead.pas', True, []);

  Units := [Main, Broken, Dead];
  Issues := CollectUnusedProjectUnits(Units, Notes);

  for N in Notes do Joined := Joined + N + '|';
  Assert.IsTrue(Joined.Contains('C:\p\Broken.pas'),
    'the unreadable file is named: ' + Joined);
  Assert.IsTrue(Joined.Contains('ONE layer'),
    'and the one-layer limitation is stated: ' + Joined);

  Assert.IsTrue(FindIssue(Issues, 'Broken', Issue), 'Broken is listed');
  Assert.AreEqual(Ord(uukUnreadable), Ord(Issue.Kind),
    'a file nobody could read is not a file without references');

  // The id is the file, so it survives sorting and a re-scan.
  Assert.IsTrue(FindIssue(Issues, 'Dead', Issue), 'Dead is listed');
  Assert.AreEqual(UnusedUnitIssueId('C:\P\DEAD.PAS'), Issue.Id, False,
    'the id names the file, case-insensitively');
  Assert.AreNotEqual(UnusedUnitIssueId('C:\p\Broken.pas'), Issue.Id, False,
    'and two files do not share one');

  // Without the main source nothing can judge the CreateForm case, and the
  // answer says that too.
  Units := [Broken, Dead];
  CollectUnusedProjectUnits(Units, Notes);
  Joined := '';
  for N in Notes do Joined := Joined + N + '|';
  Assert.IsTrue(Joined.Contains('main source was not read'),
    'no main source is a limit worth naming: ' + Joined);
end;

initialization
  TDUnitX.RegisterTestFixture(TUnusedUnitsTests);

end.
