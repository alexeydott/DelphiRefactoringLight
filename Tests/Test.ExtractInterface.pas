(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 * Test cases contributed by Ian Branch (code audit, issue #22).
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
/// <summary>
///  Extract interface / Add to existing interface / Add IInterface support:
///  the text routines of Expert.ExtractInterface - the class header
///  matcher, the project interface scanner, what is spliced into an
///  existing interface, finding a declaration again after an edit, and
///  the IInterface directives.
/// </summary>
unit Test.ExtractInterface;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TExtractInterfaceTests = class
  public
    /// <summary>"TMyClass = class": the word "class" inside the NAME made
    ///  the header matcher skip the line, and the class above it was
    ///  parsed instead.</summary>
    [Test] procedure ClassNameContainingClass_IsTheClassParsed;
    /// <summary>The scanner lists interfaces only: not a class with
    ///  TInterfacedObject in its ancestor list, and not a forward
    ///  "IFoo = interface;", which ran to the next type's end.</summary>
    [Test] procedure ScanFile_OnlyRealInterfaceDeclarations;
    /// <summary>With every selected member already in the interface there
    ///  is nothing to splice - a whole "IFoo = interface ... end;" was
    ///  spliced into the existing interface.</summary>
    [Test] procedure Splice_NothingLeft_IsEmpty;
    /// <summary>After the uses clause grew by three lines, the interface is
    ///  found again by name - walking on from the old line ended at the
    ///  previous interface's end.</summary>
    [Test] procedure FindDecl_AfterTheFileGrewAboveIt;
    /// <summary>The class is found again from its old line after an
    ///  interface above it in the same unit was extended.</summary>
    [Test] procedure RelocateClass_AfterTheFileGrewAboveIt;
    /// <summary>What "Add IInterface support to class" declares. The
    ///  user ran it on a class derived from System.Classes' TRecall and
    ///  got TWO compiler errors (2026-10-17): E2169, because the field
    ///  was appended to an existing private section BEHIND its methods,
    ///  and E2137, because the base is not literally TObject/TPersistent
    ///  and the name-based guess therefore wrote "override" on a
    ///  QueryInterface no ancestor declares.</summary>
    [Test] procedure TheIInterfaceBlockCompilesOnAnyBase;

    /// <summary>Issue #44, the reported class verbatim. Two defects in one
    ///  shape: a WRAPPED parameter list was cut at the ';' inside it, so
    ///  "procedure Test3( const AParam1: string;" was the whole method and
    ///  the continuation line became a FIELD member; and a '&'-ESCAPED
    ///  property name was parsed as EMPTY, which generated
    ///  "function Get: String" and "property : String read Get".</summary>
    [Test] procedure WrappedParametersAndEscapedNames_Issue44;

    /// <summary>Issue #46, the reported class verbatim. An ARRAY property
    ///  carries its own ':' inside the index brackets, and the type was
    ///  read from the FIRST colon - so "property Test[ AIndex: Integer]:
    ///  Integer read GetTest" got the type "Integer]:" and lost its index
    ///  list. Found with it: the accessor scan stepped one character short
    ///  of the keyword, so the word after "read" was always "D" and EVERY
    ///  property looked like a FIELD accessor - which is why a property
    ///  reading a real method was rewritten instead of being emitted as it
    ///  stands.</summary>
    [Test] procedure ArrayPropertyKeepsItsIndexList_Issue46;

    /// <summary>Issue #46, the second half: the extracted interface was
    ///  right and the class no longer compiled, because a TObject
    ///  descendant does not implement IInterface. Who provides it is
    ///  decided from evidence - the class's own three methods, then the
    ///  base class - and a base nobody can resolve is reported as
    ///  unknown instead of being guessed at.</summary>
    [Test] procedure WhoProvidesIInterfaceIsDecidedFromEvidence_Issue46;
    /// <summary>And the offer for a TObject-like base: the header is
    ///  rewritten to derive from TInterfacedObject, the interfaces
    ///  behind the base stay, the modifier keeps its place, and the
    ///  shapes that have no base class are refused with a reason.</summary>
    [Test] procedure TheAncestorChangeKeepsEverythingElse_Issue46;
    /// <summary>And the tool declares the ancestor choice: an argument a
    ///  schema does not list is dropped before the handler sees it, and
    ///  nobody is told (1.16.11).</summary>
    [Test] procedure TheExtractToolDeclaresTheAncestorChoice_Issue46;
    /// <summary>User, 2026-10-17: "Wenn die Zielunit schon existiert,
    ///  sollte das Interface dort hinzugefuegt und die benoetigten uses
    ///  ergaenzt werden." Before that the only offer was to OVERWRITE the
    ///  whole file.</summary>
    [Test] procedure AnExistingTargetUnitIsExtended;
    /// <summary>And the other half of the same round: an interface unit
    ///  that names nothing but built-in types gets no uses clause at all,
    ///  instead of the invented System.Classes + System.SysUtils - "mit
    ///  Interfaces will man ja gerade entkoppeln".</summary>
    [Test] procedure TheInterfaceUnitCarriesOnlyWhatItNeeds;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, Expert.ExtractInterface, Mcp.Protocol;

procedure TExtractInterfaceTests.ClassNameContainingClass_IsTheClassParsed;
var
  Info: TExtractInterfaceInfo;
begin
  Assert.IsTrue(TExtractInterfaceEngine.ParseClassAtLine([
    'unit U;',                  // 1
    'interface',                // 2
    'type',                     // 3
    '  TOther = class',         // 4
    '    procedure A;',         // 5
    '  end;',                   // 6
    '  TMyClass = class',       // 7
    '    procedure Run;',       // 8
    '  end;',                   // 9
    'implementation',           // 10
    'end.'], '', 8, Info));
  Assert.AreEqual('TMyClass', Info.ClassName, False);
  Assert.AreEqual(7, Info.ClassDeclLine);
end;

procedure TExtractInterfaceTests.ScanFile_OnlyRealInterfaceDeclarations;
var
  FileName, Found: string;
begin
  FileName := TPath.GetTempFileName;
  TFile.WriteAllText(FileName, string.Join(sLineBreak, [
    'unit U;',                                    // 1
    'interface',                                  // 2
    'type',                                       // 3
    '  TImpl = class(TInterfacedObject, IBar)',   // 4
    '    procedure X;',                           // 5
    '  end;',                                     // 6
    '  IFwd = interface;',                        // 7
    '  IBar = interface',                         // 8
    '    procedure X;',                           // 9
    '  end;',                                     // 10
    '  IFwd = interface',                         // 11
    '    procedure Y;',                           // 12
    '  end;',                                     // 13
    'implementation',                             // 14
    'end.']));
  try
    Found := '';
    for var Loc in TProjectInterfaceScanner.ScanFile(FileName) do
      Found := Found + Format('%s %d-%d|', [Loc.InterfaceName, Loc.DeclLine, Loc.EndLine]);
    Assert.AreEqual('IBar 8-10|IFwd 11-13|', Found, False);
  finally
    TFile.Delete(FileName);
  end;
end;

procedure TExtractInterfaceTests.Splice_NothingLeft_IsEmpty;
var
  Info: TExtractInterfaceInfo;
begin
  Info := Default(TExtractInterfaceInfo);
  Info.InterfaceName := 'IFoo';
  Info.Guid := '{00000000-0000-0000-0000-000000000001}';
  SetLength(Info.Members, 1);
  Info.Members[0].Name := 'Run';
  Info.Members[0].Kind := mkMethod;
  Info.Members[0].Signature := 'procedure Run';
  Info.Members[0].Selected := False;
  Assert.AreEqual('', string.Join('|', TExtractInterfaceEngine.InterfaceSpliceLines(Info)),
    False, 'nothing selected: nothing to splice');
  Info.Members[0].Selected := True;
  Assert.AreEqual('    procedure Run;',
    string.Join('|', TExtractInterfaceEngine.InterfaceSpliceLines(Info)), False);
end;

procedure TExtractInterfaceTests.FindDecl_AfterTheFileGrewAboveIt;
var
  Loc: TInterfaceDeclLocation;
begin
  // IFoo was at line 7 before three uses lines were added above it
  Assert.IsTrue(TProjectInterfaceScanner.FindDecl([
    'unit U;',                  // 1
    'interface',                // 2
    '',                         // 3 (added)
    'uses',                     // 4 (added)
    '  A;',                     // 5 (added)
    'type',                     // 6
    '  IOther = interface',     // 7
    '    procedure P;',         // 8
    '  end;',                   // 9
    '  IFoo = interface',       // 10
    '    procedure Q;',         // 11
    '  end;',                   // 12
    'implementation',           // 13
    'end.'], 'IFoo', 7, Loc));
  Assert.AreEqual(10, Loc.DeclLine);
  Assert.AreEqual(12, Loc.EndLine, 'the end of IFoo, not of IOther');
end;

procedure TExtractInterfaceTests.RelocateClass_AfterTheFileGrewAboveIt;
var
  DeclLine, EndLine: Integer;
begin
  // TFoo was at line 5 before a member was spliced into IFoo above it
  Assert.IsTrue(TExtractInterfaceEngine.RelocateClass([
    'type',                     // 1
    '  IFoo = interface',       // 2
    '    procedure A;',         // 3
    '    procedure B;',         // 4 (spliced in)
    '  end;',                   // 5
    '  TFoo = class',           // 6
    '    procedure A;',         // 7
    '  end;'], 'TFoo', 5, DeclLine, EndLine));
  Assert.AreEqual(6, DeclLine);
  Assert.AreEqual(8, EndLine);
end;

procedure TExtractInterfaceTests.TheIInterfaceBlockCompilesOnAnyBase;
var
  Block: string;
begin
  Block := TExtractInterfaceEngine.BuildIInterfaceDeclBlock(False, False);

  // E2169: the block is spliced at the END of an existing private
  // section, where a field may NOT follow methods - so it opens its own.
  Assert.IsTrue(Block.StartsWith('  private' + sLineBreak),
    'the field opens its own private section: ' + Block);
  Assert.IsTrue(Pos('private', Block) < Pos('FRefCount', Block),
    'and the field stands in it');

  // E2137: no ancestor of a class that reaches this block declares an
  // IInterface method - a base that does makes the verdict "satisfied"
  // (or "partly by hand") and the command refuses before generating.
  Assert.IsFalse(Block.Contains('HResult; override'),
    'QueryInterface is a fresh implementation, not an override: ' + Block);
  Assert.IsFalse(Block.Contains('_AddRef: Integer; override'),
    '_AddRef likewise');
  Assert.IsFalse(Block.Contains('_Release: Integer; override'),
    '_Release likewise');
  for var M in ['QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;',
                '_AddRef: Integer; stdcall;',
                '_Release: Integer; stdcall;'] do
    Assert.IsTrue(Block.Contains(M), 'declared stdcall: ' + M);

  // AfterConstruction / NewInstance ARE overrides - TObject declares
  // both virtual - and they are left out when the class has them.
  Assert.IsTrue(Block.Contains('procedure AfterConstruction; override;'),
    'AfterConstruction overrides TObject''s');
  Assert.IsTrue(Block.Contains('class function NewInstance: TObject; override;'),
    'NewInstance too');

  Block := TExtractInterfaceEngine.BuildIInterfaceDeclBlock(True, True);
  Assert.IsFalse(Block.Contains('AfterConstruction'),
    'a class that declares them keeps its own (E2007): ' + Block);
  Assert.IsFalse(Block.Contains('NewInstance'), 'the same for NewInstance');
  Assert.IsFalse(Block.Contains('public'),
    'and then the block needs no public section at all');
  Assert.IsTrue(Block.Contains('FRefCount'), 'the three methods still come');

  Block := TExtractInterfaceEngine.BuildIInterfaceDeclBlock(True, False);
  Assert.IsTrue(Block.Contains('AfterConstruction'), 'only the missing one');
  Assert.IsFalse(Block.Contains('NewInstance'), 'not the one that is there');
end;

procedure TExtractInterfaceTests.ArrayPropertyKeepsItsIndexList_Issue46;
var
  Info: TExtractInterfaceInfo;
  I: Integer;
begin
  // The reporter's class, verbatim.
  Assert.IsTrue(TExtractInterfaceEngine.ParseClassAtLine([
    'unit U;',                                            // 1
    'interface',                                          // 2
    'type',                                               // 3
    '  TMyClass = class',                                 // 4
    '  private',                                          // 5
    '    function GetTest(AIndex: Integer): Integer;',    // 6
    '  public',                                           // 7
    '    property Test[ AIndex: Integer]: Integer read GetTest;', // 8
    '  end;',                                             // 9
    'implementation',                                     // 10
    'end.'], '', 4, Info));

  Assert.AreEqual(2, Integer(Length(Info.Members)), 'GetTest and Test');

  for I := 0 to High(Info.Members) do
    if SameText(Info.Members[I].Name, 'Test') then
    begin
      // The type stops at the ':' OUTSIDE the index brackets.
      Assert.AreEqual('Integer', Info.Members[I].TypeName, False,
        'the index list holds its own colon');
      // read GetTest names a METHOD of this class, so there is nothing to
      // synthesise - the property goes in as it stands.
      Assert.IsFalse(Info.Members[I].NeedsSynthAccessors,
        'read GetTest is a method accessor, not a field');
      // What the reporter ticked: the property alone.
      Info.Members[I].Selected := True;
    end;

  Info.InterfaceName := 'IMyClass';
  Info.Guid := '{19428B68-DD38-461D-B9C5-198479984325}';

  // The reporter's expected preview, verbatim. The accessor METHOD comes
  // along because an interface property may only name accessors the
  // interface itself declares.
  Assert.AreEqual(
    '  IMyClass = interface' + sLineBreak +
    '    [''{19428B68-DD38-461D-B9C5-198479984325}'']' + sLineBreak +
    '    function GetTest(AIndex: Integer): Integer;' + sLineBreak +
    '    property Test[ AIndex: Integer]: Integer read GetTest;' + sLineBreak +
    '  end;',
    TExtractInterfaceEngine.BuildInterfaceText(Info), False,
    'the array property keeps its index list and brings its getter');

  // An INHERITED accessor is in no member list of this class, so the
  // "is it a field?" test cannot see it - and for an array property the
  // synthesised pair would drop the index parameters. The index list is
  // what decides: a property that has one is never rewritten.
  Assert.IsTrue(TExtractInterfaceEngine.ParseClassAtLine([
    'unit V;',                                                   // 1
    'interface',                                                // 2
    'type',                                                     // 3
    '  TChild = class(TBase)',                                   // 4
    '  public',                                                  // 5
    '    property Items[AIndex: Integer]: string read GetItems;',// 6
    '  end;',                                                   // 7
    'implementation',                                           // 8
    'end.'], '', 4, Info));
  Assert.AreEqual(1, Integer(Length(Info.Members)), 'the property alone');
  Assert.IsFalse(Info.Members[0].NeedsSynthAccessors,
    'an array property is never rewritten, whoever declares its accessor');
  Assert.AreEqual('string', Info.Members[0].TypeName, False, 'type at depth 0');
  Info.Members[0].Selected := True;
  Info.InterfaceName := 'IChild';
  Info.Guid := '{00000000-0000-0000-0000-000000000000}';
  Assert.IsTrue(TExtractInterfaceEngine.BuildInterfaceText(Info).Contains(
    'property Items[AIndex: Integer]: string read GetItems;'),
    'the index list survives: ' + TExtractInterfaceEngine.BuildInterfaceText(Info));
end;

procedure TExtractInterfaceTests.WrappedParametersAndEscapedNames_Issue44;
var
  Info: TExtractInterfaceInfo;
  Names, Sigs: string;
  I: Integer;
begin
  // The reporter's class, verbatim.
  Assert.IsTrue(TExtractInterfaceEngine.ParseClassAtLine([
    'unit U;',                                      // 1
    'interface',                                    // 2
    'type',                                         // 3
    '  TMyObject = class(TObject)',                 // 4
    '  private',                                    // 5
    '    FString: String;',                         // 6
    '  protected',                                  // 7
    '  public',                                     // 8
    '    procedure &Integer;',                      // 9
    '    procedure &Test;',                         // 10
    '    procedure Test2( const AParam: Boolean);', // 11
    '    procedure Test3( const AParam1: string;',  // 12
    '                     const AParam2: Boolean);',// 13
    '    property &String: String read FString;',   // 14
    '  end;',                                       // 15
    'implementation',                               // 16
    'end.'], '', 4, Info));

  for I := 0 to High(Info.Members) do
  begin
    Names := Names + '|' + Info.Members[I].Name;
    Sigs := Sigs + '|' + Info.Members[I].Signature;
    // What the reporter ticked: the public members, not the private field.
    Info.Members[I].Selected := Info.Members[I].Visibility = mvPublic;
  end;

  // ONE entry for Test3, and its continuation line is not a member of its
  // own - it used to arrive as a "field" called "const AParam2".
  Assert.AreEqual('|FString|&Integer|&Test|Test2|Test3|&String', Names, False,
    'six members, and the escaped names are names');
  Assert.IsTrue(Sigs.Contains(
    '|procedure Test3( const AParam1: string; const AParam2: Boolean)'),
    'the wrapped parameter list stays with its header: ' + Sigs);

  Info.InterfaceName := 'IMyObject';
  Info.Guid := '{23E240A6-23A0-4DC8-883E-3BA021063342}';

  // The reporter's expected preview, verbatim.
  Assert.AreEqual(
    '  IMyObject = interface' + sLineBreak +
    '    [''{23E240A6-23A0-4DC8-883E-3BA021063342}'']' + sLineBreak +
    '    procedure &Integer;' + sLineBreak +
    '    procedure &Test;' + sLineBreak +
    '    procedure Test2( const AParam: Boolean);' + sLineBreak +
    '    procedure Test3( const AParam1: string; const AParam2: Boolean);' + sLineBreak +
    '    function GetString: String;' + sLineBreak +
    '    property &String: String read GetString;' + sLineBreak +
    '  end;',
    TExtractInterfaceEngine.BuildInterfaceText(Info), False,
    'the escaped property keeps its & and its getter drops it');
end;

procedure TExtractInterfaceTests.WhoProvidesIInterfaceIsDecidedFromEvidence_Issue46;
var
  V: TIInterfaceVerdict;

  function Parse(const ALines: TArray<string>;
    const AResolver: TIInterfaceBaseResolver = nil): TIInterfaceVerdict;
  var
    Info: TExtractInterfaceInfo;
  begin
    Assert.IsTrue(TExtractInterfaceEngine.ParseClassAtLine(ALines, '', 4, Info),
      'the fixture must declare a class around line 4');
    Result := TExtractInterfaceEngine.IInterfaceNeedOf(ALines, Info.ClassDeclLine,
      Info.ClassEndLine, Info.ClassName, AResolver);
  end;

begin
  // The reported shape: issue #46's class, which is a plain TObject
  // descendant - "TMyClass = class" with no list at all.
  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class',
    '  private', '    function GetTest(AIndex: Integer): Integer;',
    '  public', '    property Test[ AIndex: Integer]: Integer read GetTest;',
    '  end;', 'implementation', 'end.']);
  Assert.AreEqual(Integer(Ord(iinChangeAncestor)), Integer(Ord(V.Need)),
    'a TObject descendant cannot carry an interface - the reported case');
  Assert.AreEqual('TInterfacedObject', V.SuggestedAncestor);
  Assert.AreEqual(3, Integer(Length(V.Missing)), 'all three methods are missing');
  Assert.IsTrue(V.Reason.Contains('TMyClass') and V.Reason.Contains('TObject'),
    'the reason names the class and its base: ' + V.Reason);
  Assert.IsTrue(V.Offer.Contains('TInterfacedObject'), 'and the offer: ' + V.Offer);

  // A base that implements it - measured in the RTL, not assumed.
  // The last three are the VCL / FMX shortcuts: they descend from
  // TComponent, and answering them WITHOUT the index keeps a form out of
  // the warning while the identifier index is still cold - and keeps the
  // dialog from parsing Vcl.Forms on the main thread to find that out.
  for var Base in ['TInterfacedObject', 'TComponent', 'TInterfacedPersistent',
    'TAggregatedObject', 'TSingletonImplementation', 'TForm', 'TControl',
    'TFmxObject'] do
  begin
    V := Parse(['unit U;', 'interface', 'type',
      '  TMyClass = class(' + Base + ')', '    procedure A;', '  end;',
      'implementation', 'end.']);
    Assert.IsTrue(V.Ok, Base + ' implements IInterface, so there is nothing to report');
  end;

  // TPersistent does NOT (it is TComponent that lists IInterface), and
  // its own interfaced descendant is the one to suggest.
  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class(TPersistent)',
    '    procedure A;', '  end;', 'implementation', 'end.']);
  Assert.AreEqual(Integer(Ord(iinChangeAncestor)), Integer(Ord(V.Need)));
  Assert.AreEqual('TInterfacedPersistent', V.SuggestedAncestor);

  // The class itself may implement IInterface by hand - TAggregatedObject
  // does exactly that in the RTL, without listing it.
  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class',
    '  protected',
    '    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;',
    '    function _AddRef: Integer; stdcall;',
    '    function _Release: Integer; stdcall;',
    '  end;', 'implementation', 'end.']);
  Assert.IsTrue(V.Ok, 'a hand-written implementation needs no special base');

  // PART of it by hand is deliberate: swapping the ancestor would collide
  // with what is there, so only completing it is offered.
  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class',
    '  protected',
    '    function _AddRef: Integer; stdcall;',
    '    function _Release: Integer; stdcall;',
    '  end;', 'implementation', 'end.']);
  Assert.AreEqual(Integer(Ord(iinAddSupport)), Integer(Ord(V.Need)),
    'two of three declared: the ancestor must not be swapped');
  Assert.AreEqual(1, Integer(Length(V.Missing)));
  Assert.AreEqual('QueryInterface', V.Missing[0]);

  // A base the index cannot resolve is reported as unknown, never guessed.
  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class(TSomeVendorBase)',
    '    procedure A;', '  end;', 'implementation', 'end.']);
  Assert.AreEqual(Integer(Ord(iinUnknownBase)), Integer(Ord(V.Need)),
    'an unresolvable base is said to be unresolved');

  // With a resolver it is decided: a chain that implements it is fine, a
  // chain that does not gets the add-support offer - changing THAT
  // ancestor would drop the vendor class.
  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class(TSomeVendorBase)',
    '    procedure A;', '  end;', 'implementation', 'end.'],
    function(const ABase: string): TIInterfaceBaseKind
    begin
      Result := ibkImplements;
    end);
  Assert.IsTrue(V.Ok, 'the resolver found IInterface up the chain');

  V := Parse(['unit U;', 'interface', 'type', '  TMyClass = class(TSomeVendorBase)',
    '    procedure A;', '  end;', 'implementation', 'end.'],
    function(const ABase: string): TIInterfaceBaseKind
    begin
      Result := ibkOther;
    end);
  Assert.AreEqual(Integer(Ord(iinAddSupport)), Integer(Ord(V.Need)));
  Assert.IsTrue(V.Offer.Contains('TSomeVendorBase'),
    'the offer says what a changed ancestor would drop: ' + V.Offer);

  // An ancestor list that already names IInterface while nothing
  // implements it does not compile - and the reason says so.
  V := Parse(['unit U;', 'interface', 'type',
    '  TMyClass = class(TObject, IInterface)', '    procedure A;', '  end;',
    'implementation', 'end.']);
  Assert.IsFalse(V.Ok);
  Assert.IsTrue(V.ListsInterface);
  Assert.IsTrue(V.Reason.Contains('does not compile'),
    'listed but not implemented is named as such: ' + V.Reason);
end;

procedure TExtractInterfaceTests.TheAncestorChangeKeepsEverythingElse_Issue46;
var
  NewLine, Why: string;
begin
  // No list at all - the reported class.
  Assert.IsTrue(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class', 'TInterfacedObject', NewLine, Why), Why);
  Assert.AreEqual('  TMyClass = class(TInterfacedObject)', NewLine);

  // An existing base is replaced and the interfaces behind it stay.
  Assert.IsTrue(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class(TObject, IFoo, IBar)', 'TInterfacedObject',
    NewLine, Why), Why);
  Assert.AreEqual('  TMyClass = class(TInterfacedObject, IFoo, IBar)', NewLine);

  // Delphi puts the parentheses AFTER the class modifier - measured in
  // the RTL sources, where "= class abstract(" is how it is written.
  Assert.IsTrue(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class abstract', 'TInterfacedObject', NewLine, Why), Why);
  Assert.AreEqual('  TMyClass = class abstract(TInterfacedObject)', NewLine);
  Assert.IsTrue(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class sealed(TObject)', 'TInterfacedObject', NewLine, Why), Why);
  Assert.AreEqual('  TMyClass = class sealed(TInterfacedObject)', NewLine);

  // A trailing comment belongs to the author, so it survives.
  Assert.IsTrue(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class(TObject) // the model', 'TInterfacedObject',
    NewLine, Why), Why);
  Assert.AreEqual('  TMyClass = class(TInterfacedObject) // the model', NewLine);

  // And the shapes that have no base class, each with its reason.
  Assert.IsFalse(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class;', 'TInterfacedObject', NewLine, Why),
    'a forward declaration has nothing to derive from');
  Assert.IsTrue(Why.Contains('forward'), Why);
  Assert.IsFalse(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClassRef = class of TMyClass', 'TInterfacedObject', NewLine, Why),
    'a class reference is no class declaration');
  Assert.IsFalse(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class(TBase,', 'TInterfacedObject', NewLine, Why),
    'a wrapped ancestor list is not rewritten from one line');
  Assert.IsTrue(Why.Contains('not closed'), Why);
  Assert.IsFalse(TExtractInterfaceEngine.PlanBaseClassChange(
    '  TMyClass = class(TInterfacedObject, IFoo)', 'TInterfacedObject',
    NewLine, Why), 'nothing to change');
  Assert.IsTrue(Why.Contains('already'), Why);
end;

procedure TExtractInterfaceTests.AnExistingTargetUnitIsExtended;
var
  Target: TArray<string>;
  NewLines: TArray<string>;
  Why, Text: string;
begin
  Text := '  IOther = interface' + sLineBreak +
          '    procedure Go;' + sLineBreak +
          '  end;';

  // A unit that already HOLDS an interface: the new one goes at the end
  // of its type block and everything that was there stays.
  Target := ['unit Interfaces.App;', '', 'interface', '', 'uses',
    '  System.Classes;', '', 'type', '  IFirst = interface',
    '    procedure Run;', '  end;', '', 'implementation', '', 'end.'];
  Assert.IsTrue(PlanInterfaceIntoUnit(Target, 'IOther', Text, NewLines, Why),
    Why);
  var Joined := string.Join(sLineBreak, NewLines);
  Assert.IsTrue(Joined.Contains('IFirst = interface'),
    'what the unit had stays - it is extended, not replaced');
  Assert.IsTrue(Joined.Contains('IOther = interface'), 'and the new one is in');
  Assert.IsTrue(Pos('IFirst', Joined) < Pos('IOther', Joined),
    'the new interface goes at the END of the type block');
  Assert.IsTrue(Pos('IOther', Joined) < Pos('implementation', Joined),
    'and still in the INTERFACE section');

  // A unit without a type section gets one, after its uses clause.
  Target := ['unit Interfaces.Bare;', '', 'interface', '', 'uses',
    '  System.Classes,', '  System.SysUtils;', '', 'implementation', '',
    'end.'];
  Assert.IsTrue(PlanInterfaceIntoUnit(Target, 'IOther', Text, NewLines, Why),
    Why);
  Joined := string.Join(sLineBreak, NewLines);
  Assert.IsTrue(Joined.Contains('type'), 'a type section is opened');
  Assert.IsTrue(Pos('System.SysUtils;', Joined) < Pos('type', Joined),
    'after the uses clause, which may wrap over lines');
  Assert.IsTrue(Pos('type', Joined) < Pos('implementation', Joined),
    'and before the implementation');

  // The name is already there: splicing a second declaration of it is
  // never what was meant.
  Target := ['unit Interfaces.App;', '', 'interface', '', 'type',
    '  IOther = interface', '    procedure Go;', '  end;', '',
    'implementation', '', 'end.'];
  Assert.IsFalse(PlanInterfaceIntoUnit(Target, 'IOther', Text, NewLines, Why),
    'a second IOther is refused');
  Assert.IsTrue(Why.Contains('already declares IOther'), Why);
  Assert.IsTrue(Why.Contains('Add to existing interface'),
    'and the refusal names the command that DOES extend it: ' + Why);

  // A name inside a COMMENT is no declaration.
  Target := ['unit Interfaces.App;', '', 'interface', '', 'type',
    '  // IOther = interface - the old one', '  IFirst = interface',
    '    procedure Run;', '  end;', '', 'implementation', '', 'end.'];
  Assert.IsTrue(PlanInterfaceIntoUnit(Target, 'IOther', Text, NewLines, Why),
    'a commented-out declaration does not block it: ' + Why);

  // And a declaration in the IMPLEMENTATION section is another type.
  Target := ['unit Interfaces.App;', '', 'interface', '', 'type',
    '  IFirst = interface', '    procedure Run;', '  end;', '',
    'implementation', '', 'type', '  IOther = interface', '  end;', '',
    'end.'];
  Assert.IsTrue(PlanInterfaceIntoUnit(Target, 'IOther', Text, NewLines, Why),
    'only the interface section decides: ' + Why);
end;

procedure TExtractInterfaceTests.TheInterfaceUnitCarriesOnlyWhatItNeeds;
var
  Info: TExtractInterfaceInfo;
begin
  Assert.IsTrue(TExtractInterfaceEngine.ParseClassAtLine(
    ['unit U;', 'interface', 'type', '  TMyClass = class', '  public',
     '    procedure Run(const AName: string);', '  end;', 'implementation',
     'end.'], '', 4, Info), 'the fixture parses');
  Info.InterfaceName := 'IMyClass';
  Info.Guid := '{11111111-2222-3333-4444-555555555555}';
  Info.TargetFile := 'C:\temp\IMyClass.pas';
  for var I := 0 to High(Info.Members) do
    Info.Members[I].Selected := Info.Members[I].Name = 'Run';

  Info.NewUnitUses := nil;
  var Text := TExtractInterfaceEngine.BuildNewUnitText(Info);
  Assert.IsFalse(Text.Contains('uses'),
    'nothing but built-in types: no uses clause at all, and above all no ' +
    'invented System.Classes / System.SysUtils');
  Assert.IsTrue(Text.Contains('IMyClass = interface'), 'the interface is in');

  // With units they are written, one clause.
  Info.NewUnitUses := ['System.Classes', 'Vcl.Controls'];
  Text := TExtractInterfaceEngine.BuildNewUnitText(Info);
  Assert.IsTrue(Text.Contains('uses'), 'and with units it has a clause');
  Assert.IsTrue(Text.Contains('System.Classes, Vcl.Controls;'),
    'with exactly those: ' + Text);
end;

procedure TExtractInterfaceTests.TheExtractToolDeclaresTheAncestorChoice_Issue46;
var
  Args: TArray<string>;

  function Declares(const AName: string): Boolean;
  begin
    Result := False;
    for var A in Args do
      if SameText(A, AName) then Exit(True);
  end;

begin
  Args := KnownToolArguments('extract_interface');
  Assert.IsTrue(Length(Args) > 0, 'the tool is in the shipped definitions');
  // Exactly what ToolExtractInterface reads.
  for var Needed in ['file', 'line', 'interface_name', 'target_file',
    'members', 'add_to_existing', 'change_base_to', 'add_iinterface',
    'apply'] do
    Assert.IsTrue(Declares(Needed), Needed + ' is declared');
end;

initialization
  TDUnitX.RegisterTestFixture(TExtractInterfaceTests);

end.
