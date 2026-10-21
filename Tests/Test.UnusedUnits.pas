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
    /// <summary>User, 2026-10-17, from his running IDE: "in der aktuell
    ///  offenen IDE wird Unit7 nicht als unbenutzt gefunden, obwohl sie
    ///  nicht einmal existiert". A .dpr entry without an "in '<file>'"
    ///  clause has no file name, so the per-file gathering never made a
    ///  fact for it - and the entry that cannot even compile was the one
    ///  the answer said nothing about.</summary>
    [Test] procedure AUnitListedWithoutAFileIsReported;
    /// <summary>User, 2026-10-17: "Goto bei unused units macht gar
    ///  nichts, obwohl die Unit7 nun gefunden wird." A finding with no
    ///  file had nothing to open, and the button returned without a
    ///  word - but it does have a place: the ENTRY that lists it, which
    ///  is also what has to go.</summary>
    [Test] procedure AFileLessFindingPointsAtTheEntryThatListsIt;
    /// <summary>The expensive facts are asked for CANDIDATES only. The
    ///  production parser needs 15.7 ms per file (measured over a real
    ///  project), so over 1822 units the difference is half a minute
    ///  against two seconds - the laziness IS the feature.</summary>
    [Test] procedure TheExpensiveHalfOnlySeesCandidates;
    /// <summary>Measured live (1.31.3): the answer said "4270 project
    ///  unit(s)" for a project of 1822, because the facts hold the
    ///  reference sources as well - and a denominator the caller cannot
    ///  check is the class of defect the self-checks exist for.</summary>
    [Test] procedure OnlyTheProjectsOwnUnitsAreProjectUnits;
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

/// <summary>The first note containing AText, or '' - the notes are what
///  limits the answer, so a test about them has to name the sentence.</summary>
function NoteAbout(const ANotes: TArray<string>; const AText: string): string;
var
  S: string;
begin
  for S in ANotes do
    if S.Contains(AText) then
      Exit(S);
  Result := '';
end;

function NotesText(const ANotes: TArray<string>): string;
begin
  Result := string.Join(' / ', ANotes);
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

procedure TUnusedUnitsTests.AUnitListedWithoutAFileIsReported;
var
  Units: TArray<TUnitFacts>;
  Main, Used, Dead, Missing, Ghost, Broken: TUnitFacts;
  Issues: TArray<TUnusedUnitIssue>;
  Notes: TArray<string>;
  Issue, Other: TUnusedUnitIssue;
begin
  // The reported project, verbatim: Unit7 is listed with no file clause
  // and no such file exists anywhere.
  Main := Facts('Project7', 'C:\p\Project7.dpr', True,
    ['Vcl.Forms', 'Unit5', 'Unit6', 'Unit7', 'Ghost', 'Broken']);
  Main.IsMainUnit := True;
  Main.MainBody := 'begin Application.CreateForm(TForm5, Form5); end.';

  Used := Facts('Unit5', 'C:\p\Unit5.pas', True, ['Vcl.Forms']);
  Used.ExportedIdents := ['TForm5'];        // the body names it
  Dead := Facts('Unit6', 'C:\p\Unit6.pas', True, []);

  Missing := Facts('Unit7', '', True, []);
  Missing.Readable := False;
  Ghost := Facts('Ghost', '', True, []);
  Ghost.Readable := False;
  // The control: a file that IS named but cannot be read is a different
  // answer - there the check could not look, here there is nothing.
  Broken := Facts('Broken', 'C:\p\Broken.pas', True, []);
  Broken.Readable := False;

  Units := [Main, Used, Dead, Missing, Ghost, Broken];
  Issues := CollectUnusedProjectUnits(Units, Notes);

  Assert.IsTrue(FindIssue(Issues, 'Unit7', Issue),
    'the unit the project lists without a file is reported: ' +
    NamesOf(Issues));
  Assert.AreEqual(Ord(uukNoSource), Ord(Issue.Kind),
    'and it is a finding, not a "could not look": ' +
    UnusedUnitKindText(Issue.Kind));
  Assert.IsTrue(Issue.Reason.Contains('no uses clause names it'),
    'the reason says the half that IS decided: ' + Issue.Reason);
  Assert.IsTrue(Issue.Reason.Contains('no source'),
    'and the half that is not: ' + Issue.Reason);

  // Both halves of the id rule: '' would be ONE id for every such entry.
  Assert.IsTrue(FindIssue(Issues, 'Ghost', Other), 'Ghost is listed too');
  Assert.AreNotEqual(Issue.Id, Other.Id, False,
    'two units without a file must not share one id');
  Assert.AreNotEqual('', Issue.Id, False, 'and an id is not empty');

  Assert.IsTrue(FindIssue(Issues, 'Broken', Other), 'Broken is listed');
  Assert.AreEqual(Ord(uukUnreadable), Ord(Other.Kind),
    'a file that could not be READ keeps its own kind');

  // ...and nothing else moved: Unit5 is reached from the body, Unit6 is
  // the ordinary finding.
  Assert.IsFalse(FindIssue(Issues, 'Unit5', Other),
    'the form the main body creates is used: ' + NamesOf(Issues));
  Assert.IsTrue(FindIssue(Issues, 'Unit6', Other), 'Unit6 is unused');
  Assert.AreEqual(Ord(uukSafe), Ord(Other.Kind), 'and safe to remove');

  // Measured live on his Project7 (2.0.3): the notes called Unit7 a unit
  // that "could not be read" while its own row says the project lists a
  // unit that is not there - one answer contradicting itself. The two
  // cases get their own sentence.
  Assert.IsTrue(NoteAbout(Notes, 'no source this check could find') <> '',
    'a unit with no file is named as a FINDING, not as "could not be ' +
    'read": ' + NotesText(Notes));
  Assert.IsFalse(NoteAbout(Notes, 'no source this check could find')
    .Contains('could not be read'),
    'and that sentence does not say it was unreadable: ' +
    NoteAbout(Notes, 'no source this check could find'));
  Assert.IsTrue(NoteAbout(Notes, 'could not be read').Contains('nothing ' +
    'about them was decided'),
    'while the file that really could not be read keeps that sentence: ' +
    NotesText(Notes));
end;

procedure TUnusedUnitsTests.AFileLessFindingPointsAtTheEntryThatListsIt;
const
  // his Project7.dpr, verbatim
  Dpr =
    'program Project7;'#13#10 +
    ''#13#10 +
    'uses'#13#10 +
    '  Vcl.Forms,'#13#10 +
    '  Unit5 in ''Unit5.pas'' {Form5},'#13#10 +
    '  Unit6 in ''Unit6.pas'','#13#10 +
    '  Unit7,'#13#10 +
    '  Interfaces.MyClass in ''Interfaces.MyClass.pas'';'#13#10 +
    ''#13#10 +
    'begin'#13#10 +
    'end.'#13#10;
var
  L, C: Integer;
begin
  Assert.IsTrue(UsesEntryPosition(Dpr, 'Unit7', L, C),
    'the entry that lists it is found');
  Assert.AreEqual(6, L, 'the line of "Unit7," - 0-based, as GotoLocation takes it');
  Assert.AreEqual(2, C, 'and the column of the NAME, never the line start');

  // An entry WITH an "in" clause is the same question.
  Assert.IsTrue(UsesEntryPosition(Dpr, 'Unit5', L, C), 'Unit5');
  Assert.AreEqual(4, L, 'line of Unit5');
  Assert.AreEqual(2, C, 'column of Unit5');

  // A dotted unit name is one name, not a qualifier and a member - the
  // highlight has to cover all of it.
  Assert.IsTrue(UsesEntryPosition(Dpr, 'Interfaces.MyClass', L, C),
    'a dotted name');
  Assert.AreEqual(7, L, 'line of Interfaces.MyClass');
  Assert.AreEqual(2, C, 'column of Interfaces.MyClass');

  // Pascal does not care about case, and neither does the project list.
  Assert.IsTrue(UsesEntryPosition(Dpr, 'uNiT6', L, C), 'case does not matter');
  Assert.AreEqual(5, L, 'line of Unit6');

  // The list may have changed since the check ran - then the button says
  // so instead of jumping somewhere.
  Assert.IsFalse(UsesEntryPosition(Dpr, 'Unit9', L, C),
    'a name the clause does not carry');
  Assert.IsFalse(UsesEntryPosition('', 'Unit7', L, C), 'and no text at all');
end;

procedure TUnusedUnitsTests.OnlyTheProjectsOwnUnitsAreProjectUnits;
var
  Units: TArray<TUnitFacts>;

  procedure Add(const AName: string; AInProject: Boolean);
  var
    F: TUnitFacts;
  begin
    F := Default(TUnitFacts);
    F.UnitName := AName;
    F.FileName := AName + '.pas';
    F.InProject := AInProject;
    F.Readable := True;
    Units := Units + [F];
  end;

begin
  Assert.AreEqual(0, ProjectUnitCount(nil), 'nothing is nothing');

  Add('Main', True);
  Add('Own1', True);
  Add('Own2', True);
  // what ProjectScopeFiles adds on top: units on the search path, read
  // only so their uses clauses count.
  Add('Vendor.Grid', False);
  Add('Vendor.Edit', False);
  Add('Vendor.Base', False);
  Add('Vendor.Util', False);

  Assert.AreEqual(3, ProjectUnitCount(Units),
    'the project lists three - the four reference sources are not its units');
  Assert.AreEqual(4, Integer(Length(Units)) - ProjectUnitCount(Units),
    'and the rest is what the answer reports as reference sources');
end;

procedure TUnusedUnitsTests.TheExpensiveHalfOnlySeesCandidates;
var
  Units: TArray<TUnitFacts>;
  Main: TUnitFacts;
  Issues: TArray<TUnusedUnitIssue>;
  Notes: TArray<string>;
  Asked: string;
  Issue: TUnusedUnitIssue;
begin
  Main := Facts('Proj', 'C:\p\Proj.dpr', True, ['Live', 'Dead', 'Ghost']);
  Main.IsMainUnit := True;
  Main.MainBody := 'begin UseLive; Application.Run; end.';

  Units := [Main,
    Facts('Live', 'C:\p\Live.pas', True, []),      // reached from the body
    Facts('Dead', 'C:\p\Dead.pas', True, []),      // a candidate
    Facts('Ghost', 'C:\p\Ghost.pas', True, []),    // a candidate
    Facts('User', 'C:\p\User.pas', True, ['Live'])];
  // User is named from the body too, or it would be a candidate itself.
  Units[4].ExportedIdents := ['UseLive'];

  Asked := '';
  Issues := CollectUnusedProjectUnits(Units, Notes,
    function (const AFile: string; out AHasInit: Boolean;
      out AIdents: TArray<string>): Boolean
    begin
      Asked := Asked + '|' + AFile;
      AHasInit := AFile.Contains('Ghost');
      // With a callback it is the source of truth, so what a unit exports
      // comes from here too.
      if AFile.Contains('User') then
        AIdents := ['UseLive']
      else
        AIdents := nil;
      Result := True;
    end);

  // The saving is the USES CLAUSE pass: Live is named by User and the main
  // unit is never a candidate, so neither costs a parse. User IS asked -
  // no uses clause names it, and the body test can only run once its
  // exported identifiers are known, which is the expensive thing itself.
  Assert.AreEqual('|C:\p\Dead.pas|C:\p\Ghost.pas|C:\p\User.pas', Asked, False,
    'three of five units are parsed - the referenced ones are not');
  // And the body rule still decides afterwards: User is not reported.
  Assert.AreEqual('|Dead|Ghost', NamesOf(Issues), False,
    'User is reached from the main body through UseLive');

  // And the callback's answer is what classifies them.
  Assert.IsTrue(FindIssue(Issues, 'Ghost', Issue), 'Ghost is reported');
  Assert.AreEqual(Ord(uukInitCode), Ord(Issue.Kind),
    'the initialization flag comes from the callback');
  Assert.IsTrue(FindIssue(Issues, 'Dead', Issue), 'Dead is reported');
  Assert.AreEqual(Ord(uukSafe), Ord(Issue.Kind), 'and so does its absence');

  // A candidate the callback cannot read is listed, never dropped.
  Issues := CollectUnusedProjectUnits(Units, Notes,
    function (const AFile: string; out AHasInit: Boolean;
      out AIdents: TArray<string>): Boolean
    begin
      AHasInit := False;
      AIdents := nil;
      Result := False;
    end);
  Assert.IsTrue(FindIssue(Issues, 'Dead', Issue), 'still listed');
  Assert.AreEqual(Ord(uukUnreadable), Ord(Issue.Kind),
    'a file the parser could not read is not a file without side effects');
end;

initialization
  TDUnitX.RegisterTestFixture(TUnusedUnitsTests);

end.
