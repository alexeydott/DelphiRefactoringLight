(*
 * Copyright (c) 2026 Sebastian Jänicke (github.com/jaenicke)
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *)
unit Expert.ExtractInterface;

{
  "Extract interface from class" engine.

  Walks a Pascal class declaration, collects all members (fields,
  methods, properties) with their visibility + signatures, and lets the
  caller compose a target interface from a freely chosen subset of them.

  When fields are picked, the engine generates a paired property +
  getter/setter triple in the original class so the field-based member
  is reachable through an interface (which can only carry method/
  property declarations).

  Two operating modes:
    eimExtractNew     - create a new unit IFoo.pas with a fresh
                        interface declaration; rewrite the class to
                        implement it.
    eimAddToExisting  - splice the chosen members into an existing
                        interface declared somewhere in the project;
                        rewrite the class to implement it (if not
                        already in the ancestor list).

  Limitations of v1:
    - Generic classes / generic interfaces are not specially handled.
    - Indexed properties / default array properties are emitted
      verbatim into the interface; no special validation.
    - Conditional defines inside the class body are preserved
      textually but the parser does not track which branch is active.
    - Overloaded methods are all emitted - no dedup.
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Delphi.FileEncoding;

type
  TInterfaceMode = (eimExtractNew, eimAddToExisting);

  /// <summary>What a class needs before it can implement an interface at
  ///  all. Extracting one rewrites the class header to "TFoo = class(TBase,
  ///  IFoo)", and that only compiles when the class provides IInterface's
  ///  three methods - a TObject descendant does not (issue #46: the
  ///  extracted interface looked right and the class stopped
  ///  compiling).</summary>
  TIInterfaceNeed = (
    /// <summary>The class or one of its ancestors provides IInterface.</summary>
    iinSatisfied,
    /// <summary>A TObject-like base: deriving from TInterfacedObject (or
    ///  TInterfacedPersistent) is the smallest fix.</summary>
    iinChangeAncestor,
    /// <summary>Another base, or a class that already implements PART of
    ///  IInterface by hand: the methods belong in the class itself, which
    ///  is what "Add IInterface support to class" writes.</summary>
    iinAddSupport,
    /// <summary>The base class could not be resolved - said so rather than
    ///  guessed at.</summary>
    iinUnknownBase);

  /// <summary>What is known about a base class whose own text is not at
  ///  hand. ibkOther means RESOLVED and nothing on its chain implements
  ///  IInterface - changing the ancestor would drop that chain, so only
  ///  adding the methods is left.</summary>
  TIInterfaceBaseKind = (ibkUnknown, ibkImplements, ibkTObjectLike, ibkOther);

  /// <summary>Resolves a base class NAME: does it, or one of its own
  ///  ancestors, implement IInterface? Injected, because the answer needs
  ///  the identifier index and the type graph while this unit stays pure.
  ///  nil = only the RTL names this unit knows are decided.</summary>
  TIInterfaceBaseResolver = reference to function(
    const ABaseClass: string): TIInterfaceBaseKind;

  TIInterfaceVerdict = record
    Need: TIInterfaceNeed;
    /// <summary>The first entry of the ancestor list; '' for an implicit
    ///  TObject ("TFoo = class").</summary>
    BaseClass: string;
    /// <summary>For iinChangeAncestor: what to derive from instead.</summary>
    SuggestedAncestor: string;
    /// <summary>Of QueryInterface / _AddRef / _Release: what the class does
    ///  not declare itself.</summary>
    Missing: TArray<string>;
    /// <summary>The ancestor list already names IInterface / IUnknown. With
    ///  a Need other than iinSatisfied that means the class does not
    ///  compile as it stands.</summary>
    ListsInterface: Boolean;
    /// <summary>One sentence: what is the case. Shown as it is.</summary>
    Reason: string;
    /// <summary>One sentence: what can be done about it.</summary>
    Offer: string;
    function Ok: Boolean;
  end;

  TMemberKind = (mkField, mkProperty, mkMethod);

  TMemberVisibility = (mvUnknown, mvStrictPrivate, mvPrivate, mvStrictProtected,
    mvProtected, mvPublic, mvPublished);

  /// <summary>One declaration inside the class body. For fields, Signature
  ///  is e.g. "FFoo: TBar"; for methods, the full procedure/function
  ///  header without the trailing semicolon; for properties the full
  ///  "property X: T read ... write ..." text.</summary>
  TClassMember = record
    Name: string;
    Kind: TMemberKind;
    Visibility: TMemberVisibility;
    IsClassMember: Boolean;
    Signature: string;
    TypeName: string;
    /// <summary>1-based line numbers in the source file.</summary>
    LineStart, LineEnd: Integer;
    /// <summary>True iff this row is checked in the dialog.</summary>
    Selected: Boolean;
    /// <summary>For fields: the synthetic property name we plan to
    ///  expose (FFoo -> Foo). For properties: copy of Name.</summary>
    ExposedName: string;
    /// <summary>For methods we just take the signature verbatim. For
    ///  fields / property-without-accessors, the engine fills these
    ///  during code generation.</summary>
    GetterName, SetterName: string;
    /// <summary>True iff the original property had no explicit Get/Set
    ///  (i.e. it read/wrote a field directly) and we need to invent
    ///  accessors for the interface contract.</summary>
    NeedsSynthAccessors: Boolean;
    /// <summary>For properties: read-only flag (only "read" clause).
    ///  Affects whether we emit a setter.</summary>
    IsReadOnly: Boolean;
  end;

  /// <summary>One method declaration from an interface body. Used by
  ///  the Delegate-Implementation wizard to stub each method in a
  ///  helper class derived from TInterfacedObject.</summary>
  TInterfaceMethodInfo = record
    /// <summary>Full normalised header text (single-line, no trailing
    ///  ';'). Example: "function GetCaption: string" or
    ///  "procedure DoIt(const A: string; B: Integer)".</summary>
    Signature: string;
    /// <summary>Just the method name (e.g. "GetCaption").</summary>
    Name: string;
    /// <summary>True for `function`, False for `procedure`.</summary>
    IsFunction: Boolean;
    /// <summary>Return type for functions; empty for procedures.</summary>
    ReturnType: string;
  end;

  /// <summary>One target interface in an Add-to-existing run. Allows
  ///  the user to select different members for different interfaces
  ///  the class implements, all in a single wizard pass.</summary>
  TInterfaceTarget = record
    InterfaceName: string;
    FileName: string;
    DeclLine, EndLine: Integer;
    /// <summary>Aligned to TExtractInterfaceInfo.Members: True means
    ///  "selected for splice into THIS target interface".</summary>
    MemberSelected: TArray<Boolean>;
  end;

  TExtractInterfaceInfo = record
    Mode: TInterfaceMode;
    SourceFile: string;
    ClassName: string;
    ClassDeclLine: Integer;          // line of "TFoo = class[...]"
    ClassEndLine: Integer;           // line of the matching 'end;'
    AncestorList: string;            // raw "(TBase, IOther)" or ''
    Members: TArray<TClassMember>;
    InterfaceName: string;
    Guid: string;                    // "{XXXXXXXX-...}"
    /// <summary>For eimExtractNew: absolute path of the new unit file.
    ///  Defaults to the source file's directory with name <Interface>.pas
    ///  (T-prefix stripped for the class name, I-prefix prepended).
    ///  For eimAddToExisting: ignored.</summary>
    TargetFile: string;
    /// <summary>For eimAddToExisting: source file containing the
    ///  existing interface, plus 1-based start/end lines of its
    ///  declaration (from "IXxx = interface" up to the matching "end;").
    ///  For eimExtractNew: ignored.</summary>
    ExistingFile: string;
    ExistingDeclLine, ExistingEndLine: Integer;
    /// <summary>For eimAddToExisting: full set of target interfaces
    ///  the user wants to extend. Each entry carries its own per-Member
    ///  selection so different interfaces can receive different members
    ///  in the same wizard run. When this array is non-empty, the
    ///  primary ExistingFile/DeclLine/EndLine fields above are ignored
    ///  by ApplyAddToExisting in favour of the multi-target loop.</summary>
    Targets: TArray<TInterfaceTarget>;
    /// <summary>Unit names to include in the new unit's interface-uses
    ///  clause. The wizard typically fills this with the source unit's
    ///  own interface-uses so any type referenced by the synthesised
    ///  interface members (TButton, TListView, ...) resolves out of the
    ///  box. eimAddToExisting ignores this.</summary>
    NewUnitUses: TArray<string>;
    /// <summary>Filled by the wizard (ParseClassAtLine cannot - the rule
    ///  needs a base-class resolver): what the class needs before it can
    ///  carry an interface at all.</summary>
    IInterface: TIInterfaceVerdict;
    /// <summary>A base class to derive from instead, applied with the
    ///  extraction and BEFORE the interface joins the ancestor list (which
    ///  would otherwise become the first entry this replaces). '' = leave
    ///  the ancestor alone.</summary>
    ChangeBaseTo: string;
    /// <summary>Run "Add IInterface support to class" with the extraction:
    ///  QueryInterface / _AddRef / _Release and the reference counting go
    ///  into the class ITSELF. The other half of the same offer, for a
    ///  class whose ancestor has to stay (user, 2026-10-17: "Wir koennen
    ///  das doch direkt selbst machen").</summary>
    AddIInterface: Boolean;
  end;

  TExtractInterfaceEngine = class
  public
    /// <summary>Parses the class whose declaration line is closest to,
    ///  and at-or-before, ALine in AFileLines. Returns False if no class
    ///  was found around the position.</summary>
    class function ParseClassAtLine(const AFileLines: TArray<string>;
      const AFile: string; ALine: Integer;
      out AInfo: TExtractInterfaceInfo): Boolean;

    /// <summary>Builds the text of the new interface from AInfo. Format
    ///  is fixed: 2-space indent under "type", GUID line, then each
    ///  selected member on its own line. Field members are emitted as a
    ///  property triple (Getter, Setter when not read-only, property).
    ///  Property members with NeedsSynthAccessors get the same triple;
    ///  otherwise the property is emitted verbatim.</summary>
    class function BuildInterfaceText(const AInfo: TExtractInterfaceInfo): string;

    /// <summary>Builds the full text of the new unit file (header,
    ///  uses-clause guess, type section with interface, "end."). Only
    ///  used for eimExtractNew.</summary>
    class function BuildNewUnitText(const AInfo: TExtractInterfaceInfo): string;

    /// <summary>Returns a fresh Pascal GUID literal of the form
    ///  '{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}'.</summary>
    class function NewGuidLiteral: string;

    /// <summary>Suggests an interface name from a class name: TFoo ->
    ///  IFoo, FooBar -> IFooBar, TForm1 -> IForm1.</summary>
    class function SuggestInterfaceName(const AClassName: string): string;

    /// <summary>Suggests a unit / file name for the new unit. Strips a
    ///  leading I (the interface naming convention) only for the .pas
    ///  base name? No - we keep the interface name as the unit base
    ///  name: IFoo -> IFoo.pas in the same dir as ASourceFile.</summary>
    class function SuggestTargetFile(const ASourceFile, AInterfaceName: string): string;

    /// <summary>Parses an interface declaration (from ADeclLine to
    ///  AEndLine in AFile) and returns the names of every method,
    ///  property, and accessor (the identifiers appearing after
    ///  'read' / 'write') it declares. Used for clash detection when
    ///  adding members to an existing interface.</summary>
    class function ParseExistingInterfaceNames(const AFile: string;
      ADeclLine, AEndLine: Integer): TArray<string>;

    /// <summary>Returns the list of identifier names a single class
    ///  member would emit into the interface (method name; or property
    ///  name + Get/Set names; or for a field the synthetic
    ///  Get/Set/property names). Used together with
    ///  ParseExistingInterfaceNames to detect clashes.</summary>
    class function WouldEmitNames(const M: TClassMember): TArray<string>;

    /// <summary>True iff at least one of the identifiers M would emit
    ///  is already in AExistingUpper (which must contain UPPERCASE
    ///  names).</summary>
    class function ClashesWithExisting(const M: TClassMember;
      const AExistingUpper: TArray<string>): Boolean;

    /// <summary>Parses the "(TBase, IFoo, IBar)" tail of a class header
    ///  line. The FIRST entry is taken as the base class (Delphi
    ///  convention; only one class ancestor is allowed), the remaining
    ///  entries are returned as the implemented interfaces. Returns an
    ///  empty array if the class has no '(' / ')' or no entries beyond
    ///  the base.</summary>
    class function ParseClassAncestors(const AHeaderLine: string;
      out ABaseClass: string): TArray<string>;

    /// <summary>True iff the class body between AClassDeclLine and
    ///  AClassEndLine declares a destructor (i.e. a line whose first
    ///  word, after optional 'class' / visibility / modifier prefixes,
    ///  is 'destructor'). Used by the Make-IInterface-compatible
    ///  workflow to decide whether to inject a new destructor or hand
    ///  off the cleanup to the user.</summary>
    class function ClassHasDestructor(const AFileLines: TArray<string>;
      AClassDeclLine, AClassEndLine: Integer): Boolean;

    /// <summary>True iff the class body declares a method (procedure or
    ///  function, optionally prefixed with `class`) named AMethodName.
    ///  The match is whole-identifier: a method named 'NewInstancePlus'
    ///  does NOT count when AMethodName is 'NewInstance'. Used by the
    ///  Add-IInterface-support workflow to decide whether to add fresh
    ///  declarations for NewInstance / AfterConstruction or splice into
    ///  existing bodies instead.</summary>
    class function ClassHasMethodDecl(const AFileLines: TArray<string>;
      AClassDeclLine, AClassEndLine: Integer;
      const AMethodName: string): Boolean;

    /// <summary>Reads the body of an interface declaration in AFile
    ///  (between ADeclLine and AEndLine) and returns every method
    ///  declaration (procedure / function) it contains. Properties are
    ///  skipped because interface properties always delegate to method
    ///  accessors, which are themselves listed as methods, so stubbing
    ///  the methods covers the whole interface contract.</summary>
    class function ParseInterfaceMethodSignatures(const AFile: string;
      ADeclLine, AEndLine: Integer): TArray<TInterfaceMethodInfo>;

    /// <summary>1-based position of the type keyword in ALine when it is
    ///  the first word after the '=' ("TFoo = class", "TFoo = packed
    ///  class", "IFoo = interface"), else 0. A plain Pos() over the line
    ///  also finds the word inside a name such as "TMyClass".</summary>
    class function TypeKeywordPos(const ALine: string;
      const AKeywords: array of string): Integer;

    /// <summary>The member lines to splice into an existing interface:
    ///  BuildInterfaceText without its "IFoo = interface" header, GUID
    ///  line and "end;". Empty when no member is selected.</summary>
    class function InterfaceSpliceLines(const AInfo: TExtractInterfaceInfo): TArray<string>;

    /// <summary>Finds the class AClassName again after an edit moved it:
    ///  the declaration nearest to ANearLine (1-based). Returns its new
    ///  1-based declaration and end lines.</summary>
    class function RelocateClass(const AFileLines: TArray<string>;
      const AClassName: string; ANearLine: Integer;
      out ADeclLine, AEndLine: Integer): Boolean;

    /// <summary>The directive for one IInterface method added to a class
    ///  with base ABaseClass: 'override; ' where the base declares it
    ///  virtual, else ''. Only QueryInterface is virtual in TComponent;
    ///  its _AddRef and _Release are static (E2170 on override).</summary>
    /// <summary>The declarations "Add IInterface support to class"
    ///  inserts into the class body, as ONE block. Two rules the compiler
    ///  enforces, and both cost a live round (user, 2026-10-17, a class
    ///  derived from TRecall):
    ///  * it opens its OWN `private` section. The block is spliced at the
    ///    END of an existing private section, and there a FIELD may not
    ///    follow methods (E2169).
    ///  * NO `override` on QueryInterface / _AddRef / _Release. This block
    ///    is only ever generated when ALL THREE are missing from the whole
    ///    ancestor chain: a base that declares them makes the verdict
    ///    "satisfied" and the command refuse, one that declares some is
    ///    refused as "partly by hand". So there is no inherited virtual
    ///    method to override here - and `override` without one is E2137,
    ///    which is exactly what the name-based guess produced for every
    ///    base that was not literally TObject or TPersistent.
    ///  AHASNEWINSTANCE / AHASAFTERCONSTRUCTION: the class declares it
    ///  already, so it is not declared again (E2007) - the caller splices
    ///  the refcount statement into the existing body.</summary>
    class function BuildIInterfaceDeclBlock(
      AHasNewInstance, AHasAfterConstruction: Boolean): string;

    /// <summary>What this unit knows about an RTL base class, measured in
    ///  the shipped sources rather than assumed. ibkUnknown for everything
    ///  else - that is what the resolver is for.</summary>
    class function KnownIInterfaceBaseKind(
      const ABaseClass: string): TIInterfaceBaseKind;

    /// <summary>Whether the class declared at AClassDeclLine can implement
    ///  an interface, and what to do when it cannot. The class's own three
    ///  methods decide first (a hand-written delegation needs no special
    ///  base at all), then the base class - known names before AResolver,
    ///  because the known answer is exact and free.</summary>
    class function IInterfaceNeedOf(const AFileLines: TArray<string>;
      AClassDeclLine, AClassEndLine: Integer; const AClassName: string;
      const AResolver: TIInterfaceBaseResolver = nil): TIInterfaceVerdict;

    /// <summary>The class header with ANewBase as its base class: an empty
    ///  list is created after the class modifiers ("class abstract(TBase)"
    ///  is where Delphi puts it), an existing one has its FIRST entry
    ///  replaced and keeps every interface behind it. Refuses a forward
    ///  declaration, a "class of", a list that is not closed on this line
    ///  and a header that already names ANewBase - a refusal says why, and
    ///  nothing is rewritten on a guess.</summary>
    class function PlanBaseClassChange(const AHeaderLine, ANewBase: string;
      out ANewLine, AWhy: string): Boolean;
  end;

  /// <summary>Tiny utility: scans an entire Pascal source file and yields
  ///  every interface declaration ("IFoo = interface ['{guid}']") it
  ///  finds, together with the file path and the line numbers. Used by
  ///  the "Add to existing interface" picker.</summary>
  TInterfaceDeclLocation = record
    FileName: string;
    InterfaceName: string;
    DeclLine: Integer;          // line of "IFoo = interface[(...)]"
    EndLine: Integer;           // line of matching 'end;'
  end;

  TProjectInterfaceScanner = class
  public
    class function ScanFile(const AFileName: string): TArray<TInterfaceDeclLocation>;
    /// <summary>ScanFile on lines already in memory.</summary>
    class function ScanLines(const AFileName: string;
      const ALines: TArray<string>): TArray<TInterfaceDeclLocation>;
    /// <summary>Finds the interface AInterfaceName in ALines again after an
    ///  edit moved it: the declaration nearest to ANearLine (1-based).</summary>
    class function FindDecl(const ALines: TArray<string>;
      const AInterfaceName: string; ANearLine: Integer;
      out ALoc: TInterfaceDeclLocation): Boolean;
    class function ScanProject(const AFiles: TArray<string>): TArray<TInterfaceDeclLocation>;
  end;

/// <summary>ATARGETLINES with AINTERFACETEXT added to the END of its
///  interface section's type block - a new "type" section is opened before
///  the first declaration when there is none. The unit keeps everything it
///  already has (user, 2026-10-17: "Wenn die Zielunit schon existiert,
///  sollte das Interface dort hinzugefuegt werden" - the version before
///  asked whether to OVERWRITE the whole file).
///  REFUSED when the unit already declares AINTERFACENAME: splicing a
///  second declaration of the same name is never what was meant, and
///  extending the one that is there is what "Add to existing interface"
///  does. False + AWHY, so the caller can say which it is.</summary>
function PlanInterfaceIntoUnit(const ATargetLines: TArray<string>;
  const AInterfaceName, AInterfaceText: string;
  out ANewLines: TArray<string>; out AWhy: string): Boolean;

/// <summary>The name of a synthesised accessor for the member exposed as
///  AExposedName: APrefix ('Get' / 'Set') plus the name WITHOUT its '&'
///  escape. The property itself KEEPS the escape - the bare word is the
///  reserved one, which is why the author escaped it - but a name DERIVED
///  from it must drop it, because "Get&String" is not an identifier at
///  all. ONE place, because four sites build these names: the interface
///  text, the "would emit" check, and the class's own declarations and
///  bodies in the wizard (issue #44).</summary>
function AccessorName(const APrefix, AExposedName: string): string;

/// <summary>The declared type of a property signature: what stands after
///  the ':' at bracket depth ZERO. An ARRAY property carries its own
///  colon inside the index specification ("property Test[ AIndex:
///  Integer]: Integer read GetTest"), and reading the FIRST colon gave
///  the type "Integer]:" (issue #46). '' when there is no such colon.</summary>
function PropertyTypeName(const ASignature: string): string;

/// <summary>The index specification of a property INCLUDING its brackets
///  ("[ AIndex: Integer]"), or '' for a plain property. Its presence is
///  what makes a property an array property, and such a property can only
///  ever be served by accessor METHODS - never by a field.</summary>
function PropertyIndexSpec(const ASignature: string): string;

/// <summary>The identifiers a property signature names after 'read' and
///  after 'write' ('' when the clause is absent). The words are read with
///  the keyword SKIPPED - stepping one character short of it answered 'D'
///  for every property, which made each of them look like a field
///  accessor (issue #46).</summary>
procedure PropertyAccessors(const ASignature: string; out ARead, AWrite: string);

implementation

uses
  System.StrUtils, System.Character, System.Math, Winapi.ActiveX, Winapi.Windows,
  Expert.PascalScanner, Expert.AutoImport;   // UnitSectionEnd / SplitContentLines

function AccessorName(const APrefix, AExposedName: string): string;
begin
  Result := APrefix + UnescapedIdentifier(AExposedName);
end;

// Does ALINE declare a type of that name - "IFoo = interface", "IFoo =
// class", "IFoo = interface;"? The name must be the whole first token.
function DeclaresTypeNamed(const ALine, AName: string): Boolean;
var
  T: string;
  P: Integer;
begin
  Result := False;
  T := Trim(ALine);
  if not StartsText(AName, T) then Exit;
  P := Length(AName) + 1;
  if (P <= Length(T)) and IsIdentChar(T[P]) then Exit;
  T := Trim(Copy(T, P, MaxInt));
  Result := StartsStr('=', T);
end;

function PlanInterfaceIntoUnit(const ATargetLines: TArray<string>;
  const AInterfaceName, AInterfaceText: string;
  out ANewLines: TArray<string>; out AWhy: string): Boolean;
var
  Masked: TArray<string>;
  IntfLine, ImplLine, I, InsertAt: Integer;
  Upper: string;
  NewBlock: TArray<string>;
begin
  Result := False;
  ANewLines := ATargetLines;
  AWhy := '';
  if (Length(ATargetLines) = 0) or (Trim(AInterfaceText) = '') then
  begin
    AWhy := 'the target unit could not be read';
    Exit;
  end;

  // Comments and strings blanked: a type of that name inside a comment is
  // not a declaration, and neither is one in the implementation section.
  Masked := MaskCommentsAndStrings(ATargetLines);
  IntfLine := -1;
  ImplLine := Length(Masked);
  for I := 0 to High(Masked) do
  begin
    Upper := UpperCase(Trim(Masked[I]));
    if (IntfLine < 0) and (Upper = 'INTERFACE') then IntfLine := I
    else if Upper = 'IMPLEMENTATION' then
    begin
      ImplLine := I;
      Break;
    end;
  end;
  if IntfLine < 0 then
  begin
    AWhy := 'the target unit has no interface section';
    Exit;
  end;

  for I := IntfLine to ImplLine - 1 do
    if DeclaresTypeNamed(Masked[I], AInterfaceName) then
    begin
      AWhy := Format('the target unit already declares %s (line %d) - use ' +
        '"Add to existing interface" to extend that one',
        [AInterfaceName, I + 1]);
      Exit;
    end;

  // The END of the interface section's type block, or - when it has none -
  // before its first declaration.
  InsertAt := UnitSectionEnd(ATargetLines, 'type', IntfLine, ImplLine - 1);
  if InsertAt >= 0 then
  begin
    NewBlock := [''] + SplitContentLines(AInterfaceText);
    Inc(InsertAt);
  end
  else
  begin
    InsertAt := UnitSectionAnchor(ATargetLines, IntfLine + 1, ImplLine - 1);
    NewBlock := [''] + ['type'] + SplitContentLines(AInterfaceText);
  end;
  if InsertAt > ImplLine then InsertAt := ImplLine;

  ANewLines := Copy(ATargetLines, 0, InsertAt) + NewBlock +
    Copy(ATargetLines, InsertAt, Length(ATargetLines) - InsertAt);
  Result := True;
end;

function PropertyTypeName(const ASignature: string): string;
var
  I, Depth: Integer;
begin
  Result := '';
  Depth := 0;
  for I := 1 to Length(ASignature) do
  begin
    case ASignature[I] of
      '[', '(': Inc(Depth);
      ']', ')': if Depth > 0 then Dec(Depth);
      ':':
        if Depth = 0 then
        begin
          var T := Trim(Copy(ASignature, I + 1, MaxInt));
          var K := 1;
          while (K <= Length(T)) and not T[K].IsWhiteSpace and (T[K] <> ';') do
            Inc(K);
          Exit(Copy(T, 1, K - 1));
        end;
    end;
  end;
end;

function PropertyIndexSpec(const ASignature: string): string;
var
  I, Depth, Start: Integer;
begin
  Result := '';
  Depth := 0;
  Start := 0;
  for I := 1 to Length(ASignature) do
  begin
    if ASignature[I] = '[' then
    begin
      if Depth = 0 then Start := I;
      Inc(Depth);
    end
    else if ASignature[I] = ']' then
    begin
      if Depth > 0 then Dec(Depth);
      if (Depth = 0) and (Start > 0) then
        Exit(Copy(ASignature, Start, I - Start + 1));
    end
    // A ':' at depth 0 ends the name part: anything in brackets after it
    // belongs to the TYPE ("property P: array[0..1] of Byte read ..."),
    // not to an index specification.
    else if (ASignature[I] = ':') and (Depth = 0) then
      Exit('');
  end;
end;

procedure PropertyAccessors(const ASignature: string; out ARead, AWrite: string);

  function WordAfter(const AKeyword: string): string;
  var
    Padded: string;
    P, Idx, Start: Integer;
  begin
    Result := '';
    Padded := ' ' + ASignature + ' ';
    P := Pos(' ' + AKeyword + ' ', UpperCase(Padded));
    if P = 0 then Exit;
    // P points at the SPACE before the keyword, so the keyword itself ends
    // at P + Length(AKeyword) - stepping only Length(AKeyword) lands on its
    // last character and answered 'D' for 'READ' (issue #46).
    Idx := P + Length(AKeyword) + 1;
    while (Idx <= Length(Padded)) and (Padded[Idx] = ' ') do Inc(Idx);
    Start := Idx;
    while (Idx <= Length(Padded)) and
          (IsIdentChar(Padded[Idx]) or (Padded[Idx] = '.') or
           (Padded[Idx] = '&')) do
      Inc(Idx);
    Result := Copy(Padded, Start, Idx - Start);
  end;

begin
  ARead := WordAfter('READ');
  AWrite := WordAfter('WRITE');
end;

{ ---------- helpers ---------- }

function FirstWordUpper(const ALine: string; out APosAfter: Integer): string;
var
  I, J: Integer;
begin
  Result := '';
  APosAfter := 0;
  I := 1;
  while (I <= Length(ALine)) and ALine[I].IsWhiteSpace do Inc(I);
  if I > Length(ALine) then Exit;
  if not IsIdentStart(ALine[I]) then Exit;
  J := I;
  while (J <= Length(ALine)) and IsIdentChar(ALine[J]) do Inc(J);
  Result := UpperCase(Copy(ALine, I, J - I));
  APosAfter := J;
end;

function ExtractIdentAfter(const ALine: string; AFromPos: Integer;
  out AEndPos: Integer): string;
var
  I: Integer;
begin
  Result := '';
  AEndPos := AFromPos;
  I := AFromPos;
  while (I <= Length(ALine)) and ALine[I].IsWhiteSpace do Inc(I);
  if I > Length(ALine) then Exit;
  // A '&' ESCAPES a reserved word into an identifier ("property &String"),
  // and it is part of the name: without it the name came out EMPTY and the
  // generated interface read "property : String read Get" (issue #44).
  AEndPos := I;
  if (ALine[AEndPos] = '&') and (AEndPos < Length(ALine)) and
     IsIdentStart(ALine[AEndPos + 1]) then
    Inc(AEndPos)
  else if not IsIdentStart(ALine[AEndPos]) then
    Exit;
  while (AEndPos <= Length(ALine)) and IsIdentChar(ALine[AEndPos]) do Inc(AEndPos);
  Result := Copy(ALine, I, AEndPos - I);
end;

{ ---------- TExtractInterfaceEngine ---------- }

class function TExtractInterfaceEngine.NewGuidLiteral: string;
var
  G: TGUID;
begin
  CoCreateGuid(G);
  Result := GUIDToString(G);
end;

class function TExtractInterfaceEngine.SuggestInterfaceName(const AClassName: string): string;
var
  Bare: string;
begin
  Bare := AClassName;
  if (Length(Bare) > 1) and (Bare[1].ToUpper = 'T') then
    Bare := Copy(Bare, 2, MaxInt);
  Result := 'I' + Bare;
end;

class function TExtractInterfaceEngine.SuggestTargetFile(
  const ASourceFile, AInterfaceName: string): string;
var
  Bare: string;
begin
  // Convention: "IBlub" -> "Interfaces.Blub.pas" in the source file's
  // directory. Strip the leading 'I' if present; otherwise use the name
  // verbatim as the dotted suffix.
  Bare := AInterfaceName;
  if (Length(Bare) > 1) and (Bare[1].ToUpper = 'I') and IsIdentStart(Bare[2]) then
    Bare := Copy(Bare, 2, MaxInt);
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ASourceFile)) +
    'Interfaces.' + Bare + '.pas';
end;

class function TExtractInterfaceEngine.ParseClassAtLine(
  const AFileLines: TArray<string>; const AFile: string; ALine: Integer;
  out AInfo: TExtractInterfaceInfo): Boolean;
var
  I, P, J: Integer;
  Line, Trimmed, Upper, FirstWord: string;
  DeclLine, EndLine: Integer;
  Depth: Integer;
  CurClassName, AncestorRaw: string;
  Members: TList<TClassMember>;
  CurVis: TMemberVisibility;
  CurIsClass: Boolean;
  procedure ResetModifiers; begin CurIsClass := False; end;

  function MatchClassHeader(const ALine: string;
    out AClassName, AAncestors: string): Boolean;
  var
    EqPos, ClassPos, ParenPos: Integer;
    L, Name, AfterClass: string;
  begin
    Result := False;
    L := StripLineComment(ALine);
    EqPos := Pos('=', L);
    if EqPos = 0 then Exit;
    // "class" must be the first word after '=': found anywhere, it was
    // found in a name like TMyClass, and the line was skipped.
    ClassPos := TExtractInterfaceEngine.TypeKeywordPos(L, ['class']);
    if ClassPos = 0 then Exit;
    // exclude 'class procedure', 'class function', 'class var', etc.
    AfterClass := Trim(Copy(L, ClassPos + 5, MaxInt));
    if (AfterClass <> '') then
    begin
      var AfterUp := UpperCase(AfterClass);
      if StartsText('PROCEDURE', AfterUp) or StartsText('FUNCTION', AfterUp) or
         StartsText('VAR', AfterUp) or StartsText('CONST', AfterUp) or
         StartsText('THREADVAR', AfterUp) or StartsText('OPERATOR', AfterUp) or
         StartsText('PROPERTY', AfterUp) or StartsText('OF ', AfterUp) or
         (AfterUp = 'OF') then Exit;
      // class reference type: "= class of TFoo"
      if StartsText('OF', AfterUp) and ((Length(AfterUp) = 2) or (AfterUp[3] = ' ')) then
        Exit;
    end;
    // forward declaration "TFoo = class;" - skip
    if Pos(';', L) > 0 then
    begin
      // Only if the ';' comes right after CLASS (no body opens this line).
      var TailUp := UpperCase(Trim(Copy(L, ClassPos + 5, MaxInt)));
      if (TailUp = ';') or StartsText(';', TailUp) then Exit;
    end;
    Name := Trim(Copy(L, 1, EqPos - 1));
    // drop generic <T> suffix if present (not v1-specially-handled but
    // accepted as a name).
    var GenPos := Pos('<', Name);
    if GenPos > 0 then Name := Trim(Copy(Name, 1, GenPos - 1));
    AClassName := Name;
    AAncestors := '';
    ParenPos := Pos('(', Copy(L, ClassPos, MaxInt));
    if ParenPos > 0 then
    begin
      var Abs_ := ClassPos + ParenPos - 1;
      var Close_ := Pos(')', Copy(L, Abs_, MaxInt));
      if Close_ > 0 then
        AAncestors := Trim(Copy(L, Abs_, Close_));
    end;
    Result := True;
  end;

begin
  Result := False;
  AInfo := Default(TExtractInterfaceInfo);
  if Length(AFileLines) = 0 then Exit;

  // Walk upward from ALine to find a class header. If we don't find
  // one upward within 2000 lines, walk downward as fallback (cursor may
  // be before the class).
  DeclLine := -1;
  for I := Min(ALine, Length(AFileLines)) - 1 downto Max(0, ALine - 2000) do
  begin
    if MatchClassHeader(AFileLines[I], CurClassName, AncestorRaw) then
    begin
      DeclLine := I + 1;
      Break;
    end;
  end;
  if DeclLine < 1 then
  begin
    for I := Max(0, ALine - 1) to Min(Length(AFileLines) - 1, ALine + 2000) do
    begin
      if MatchClassHeader(AFileLines[I], CurClassName, AncestorRaw) then
      begin
        DeclLine := I + 1;
        Break;
      end;
    end;
  end;
  if DeclLine < 1 then Exit;

  // Find end of class declaration. EVERY comment form is masked and every
  // nested BODY counts (audit #39, M38a): only 'record' used to open one
  // and only '//' was stripped, so "type TInner = class end;" inside the
  // class, or a "{ the old end }" comment, ended it there - and every
  // member below was never offered for the interface.
  EndLine := -1;
  Depth := 1;
  var MaskedBody := MaskCommentsAndStrings(AFileLines);
  for I := DeclLine to Length(AFileLines) - 1 do
  begin
    if I <= High(MaskedBody) then Line := MaskedBody[I]
    else Line := StripLineComment(AFileLines[I]);
    Upper := UpperCase(Line);
    var Pos_ := 1;
    var PrevW := '';
    while Pos_ <= Length(Upper) do
    begin
      if IsIdentStart(Upper[Pos_]) then
      begin
        var Q := Pos_;
        while (Q <= Length(Upper)) and IsIdentChar(Upper[Q]) do Inc(Q);
        var W := Copy(Upper, Pos_, Q - Pos_);
        // What follows the keyword decides: "class procedure" / "class
        // function" / "class var" are MODIFIERS, and "TFoo = class;" is a
        // forward - neither opens a body.
        var Tail := Trim(Copy(Upper, Q, MaxInt));
        if (W = 'RECORD') or (W = 'OBJECT')
          or (((W = 'CLASS') or (W = 'INTERFACE') or (W = 'DISPINTERFACE'))
              and (PrevW = '=')
              and not Tail.StartsWith(';')
              and not Tail.StartsWith('OF ')) then
          Inc(Depth)
        else if (W = 'END') then
        begin
          Dec(Depth);
          if Depth = 0 then begin EndLine := I + 1; Break; end;
        end;
        PrevW := W;
        Pos_ := Q;
      end
      else
      begin
        if not CharInSet(Upper[Pos_], [' ', #9]) then PrevW := Upper[Pos_];
        Inc(Pos_);
      end;
    end;
    if EndLine > 0 then Break;
  end;
  if EndLine < 1 then Exit;

  AInfo.SourceFile := AFile;
  AInfo.ClassName := CurClassName;
  AInfo.ClassDeclLine := DeclLine;
  AInfo.ClassEndLine := EndLine;
  AInfo.AncestorList := AncestorRaw;

  // Parse members between DeclLine+1 and EndLine-1.
  Members := TList<TClassMember>.Create;
  // Members declared before any visibility keyword default to published
  // for $M+ classes (TPersistent / TComponent / TForm descendants - the
  // common case in VCL/FMX projects) and to public for plain TObject
  // descendants. We default to mvPublished here because the published
  // case is by far the dominant one in practice; in the rare pure-
  // TObject case the user can re-tick manually.
  CurVis := mvPublished;
  ResetModifiers;
  try
    I := DeclLine;
    while I < EndLine - 1 do
    begin
      Line := StripLineComment(AFileLines[I]);
      Trimmed := Trim(Line);
      if Trimmed = '' then begin Inc(I); Continue; end;

      FirstWord := FirstWordUpper(Line, P);

      // Visibility section?
      if (FirstWord = 'PRIVATE') then begin CurVis := mvPrivate; ResetModifiers; Inc(I); Continue end
      else if (FirstWord = 'PROTECTED') then begin CurVis := mvProtected; ResetModifiers; Inc(I); Continue end
      else if (FirstWord = 'PUBLIC') then begin CurVis := mvPublic; ResetModifiers; Inc(I); Continue end
      else if (FirstWord = 'PUBLISHED') then begin CurVis := mvPublished; ResetModifiers; Inc(I); Continue end
      else if (FirstWord = 'STRICT') then
      begin
        var Rest := UpperCase(Trim(Copy(Line, P, MaxInt)));
        if StartsText('PRIVATE', Rest) then CurVis := mvStrictPrivate
        else if StartsText('PROTECTED', Rest) then CurVis := mvStrictProtected;
        ResetModifiers; Inc(I); Continue;
      end;

      // CLASS modifier (class procedure / class var / class property)?
      if (FirstWord = 'CLASS') then
      begin
        var Rest := UpperCase(Trim(Copy(Line, P, MaxInt)));
        if StartsText('VAR', Rest) or StartsText('CONST', Rest) or
           StartsText('THREADVAR', Rest) then
        begin
          // "class var" introduces a new sub-section; treat like
          // visibility-stays-the-same but mark class-member. Just continue.
          CurIsClass := True; Inc(I); Continue;
        end;
        // class procedure / class function / class property: mark and
        // re-parse the rest of the line as the actual member.
        CurIsClass := True;
        Line := Trim(Copy(Line, P, MaxInt));
        Trimmed := Line;
        FirstWord := FirstWordUpper(Line, P);
      end;

      // Method?
      if (FirstWord = 'PROCEDURE') or (FirstWord = 'FUNCTION') or
         (FirstWord = 'CONSTRUCTOR') or (FirstWord = 'DESTRUCTOR') or
         (FirstWord = 'OPERATOR') then
      begin
        // Collect the full signature: may span several lines. The ';' that
        // ends it is the first one OUTSIDE ( ) and [ ] - a WRAPPED
        // parameter list carries its own, and taking that one truncated
        // the header and made the continuation line a "field" (issue #44).
        var SigStart := I;
        var Acc := Line;
        var HDepth := 0;
        var HDone := LineEndsDeclaration(StripLineComment(Line), HDepth);
        while not HDone do
        begin
          Inc(I);
          if I >= EndLine - 1 then Break;
          var NextLine := Trim(StripLineComment(AFileLines[I]));
          Acc := Acc + ' ' + NextLine;
          HDone := LineEndsDeclaration(NextLine, HDepth);
        end;
        // Stop accumulating after first ';' that closes the header.
        var SigEnd := I + 1;
        // After ';', directives (overload; virtual; abstract; ...) may
        // follow on the same or next lines. Keep grabbing until we
        // hit a line whose trimmed first word isn't a known directive
        // and isn't blank.
        Inc(I);
        while I < EndLine - 1 do
        begin
          var DLine := Trim(StripLineComment(AFileLines[I]));
          if DLine = '' then begin Inc(I); Continue; end;
          var DUpper := UpperCase(DLine);
          // strip trailing ';'
          while (DUpper <> '') and (DUpper[Length(DUpper)] = ';') do
            DUpper := Copy(DUpper, 1, Length(DUpper) - 1);
          if (DUpper = 'OVERLOAD') or (DUpper = 'OVERRIDE') or
             (DUpper = 'VIRTUAL') or (DUpper = 'ABSTRACT') or
             (DUpper = 'REINTRODUCE') or (DUpper = 'STATIC') or
             (DUpper = 'INLINE') or (DUpper = 'CDECL') or
             (DUpper = 'STDCALL') or (DUpper = 'SAFECALL') or
             (DUpper = 'PASCAL') or (DUpper = 'REGISTER') or
             (DUpper = 'FINAL') or (DUpper = 'MESSAGE') or
             StartsText('MESSAGE ', DUpper) or
             StartsText('DEPRECATED', DUpper) or
             (DUpper = 'EXPERIMENTAL') or (DUpper = 'PLATFORM') or
             (DUpper = 'LIBRARY') then
          begin
            Acc := Acc + ' ' + DLine;
            SigEnd := I + 1;
            Inc(I); Continue;
          end;
          Break;
        end;

        // Extract method name = first ident after PROCEDURE/FUNCTION/...
        var After := Length(FirstWord) + 1; // FirstWord found at start of (trimmed) Acc
        var TrimmedAcc := Trim(Acc);
        var AfterKw := Pos(' ', TrimmedAcc);
        // Through the shared reader, so an escaped name ("procedure
        // &Integer") is the name and not an empty string (issue #44).
        var NameEnd := 0;
        var MName := ExtractIdentAfter(TrimmedAcc, AfterKw, NameEnd);
        if After = 0 then ; // silence hint

        var M: TClassMember;
        M := Default(TClassMember);
        M.Name := MName;
        M.Kind := mkMethod;
        M.Visibility := CurVis;
        M.IsClassMember := CurIsClass;
        M.Signature := Trim(Acc);
        // Strip a trailing ';' from signature for emission control.
        while (M.Signature <> '') and (M.Signature[Length(M.Signature)] = ';') do
          M.Signature := Trim(Copy(M.Signature, 1, Length(M.Signature) - 1));
        M.LineStart := SigStart + 1;
        M.LineEnd := SigEnd;
        M.ExposedName := MName;
        Members.Add(M);
        ResetModifiers;
        Continue;
      end;

      // Property?
      if FirstWord = 'PROPERTY' then
      begin
        var SigStart := I;
        var Acc := Line;
        // Same rule as for a method: an index specification
        // "property Items[const A: Integer; const B: Integer]: T" has its
        // own ';' inside the brackets (issue #44).
        var PDepth := 0;
        var PDone := LineEndsDeclaration(StripLineComment(Line), PDepth);
        while not PDone do
        begin
          Inc(I);
          if I >= EndLine - 1 then Break;
          var NextLine := Trim(StripLineComment(AFileLines[I]));
          Acc := Acc + ' ' + NextLine;
          PDone := LineEndsDeclaration(NextLine, PDepth);
        end;
        var SigEnd := I + 1;
        Inc(I);
        var TrimAcc := Trim(Acc);
        // name after "property "
        var Pn := ExtractIdentAfter(TrimAcc, Length('property') + 1, J);
        // The type stands after the ':' at bracket depth 0 - an array
        // property carries its own colon inside the index specification
        // (issue #46).
        var TName := PropertyTypeName(TrimAcc);
        var AccRead, AccWrite: string;
        PropertyAccessors(TrimAcc, AccRead, AccWrite);
        var HasRead := AccRead <> '';
        var HasWrite := AccWrite <> '';

        var M: TClassMember;
        M := Default(TClassMember);
        M.Name := Pn;
        M.Kind := mkProperty;
        M.Visibility := CurVis;
        M.IsClassMember := CurIsClass;
        M.Signature := Trim(Acc);
        while (M.Signature <> '') and (M.Signature[Length(M.Signature)] = ';') do
          M.Signature := Trim(Copy(M.Signature, 1, Length(M.Signature) - 1));
        M.TypeName := TName;
        M.LineStart := SigStart + 1;
        M.LineEnd := SigEnd;
        M.ExposedName := Pn;
        M.IsReadOnly := HasRead and not HasWrite;
        M.GetterName := AccRead;
        M.SetterName := AccWrite;
        // Whether these accessors are METHODS of this class or plain
        // FIELDS can only be decided once every member is known - an
        // accessor may be declared below the property. See the pass after
        // the loop.
        M.NeedsSynthAccessors := False;
        Members.Add(M);
        ResetModifiers;
        Continue;
      end;

      // Otherwise: assume a field declaration "Name[, Name2]: Type;".
      var Sem := Pos(';', Trimmed);
      var FieldDecl := Trimmed;
      if Sem > 0 then FieldDecl := Copy(Trimmed, 1, Sem - 1);
      var CP := Pos(':', FieldDecl);
      if CP > 0 then
      begin
        var NamesPart := Trim(Copy(FieldDecl, 1, CP - 1));
        var TypePart := Trim(Copy(FieldDecl, CP + 1, MaxInt));
        for var NItem in NamesPart.Split([',']) do
        begin
          var FN := Trim(NItem);
          if FN = '' then Continue;
          // A field name is ONE identifier, optionally '&'-escaped. The
          // blank test is what keeps a continuation line like
          // "const AParam2: Boolean)" from becoming a member (issue #44) -
          // it cannot happen any more now that a wrapped parameter list
          // stays with its header, but a parse that invents members is
          // worth a guard of its own.
          var FBare := UnescapedIdentifier(FN);
          if (FBare = '') or not IsIdentStart(FBare[1]) then Continue;
          if Pos(' ', FN) > 0 then Continue;
          var M: TClassMember;
          M := Default(TClassMember);
          M.Name := FN;
          M.Kind := mkField;
          M.Visibility := CurVis;
          M.IsClassMember := CurIsClass;
          M.Signature := FN + ': ' + TypePart;
          M.TypeName := TypePart;
          M.LineStart := I + 1;
          M.LineEnd := I + 1;
          // ExposedName: F-prefix stripped if present. An escaped name
          // keeps its '&' - it is the reserved word that needs it.
          if (Length(FBare) >= 2) and (FBare[1].ToUpper = 'F') and
             IsIdentStart(FBare[2]) then
            M.ExposedName := Copy(FBare, 2, MaxInt)
          else
            M.ExposedName := FN;
          Members.Add(M);
        end;
      end;
      ResetModifiers;
      Inc(I);
    end;

    // An accessor is a METHOD of this class or it is not - and that
    // decides everything downstream: a method accessor means the property
    // goes into the interface AS IT STANDS (with its index list) and the
    // accessor's own signature comes along, while a field accessor means
    // the engine has to invent the pair. The old test was "the word does
    // not start with Get/Set", which is a guess, and it ran on a word that
    // was always 'D' (issue #46). The class's own member list is exact,
    // and it is complete only here - an accessor may stand BELOW its
    // property.
    for var PI := 0 to Members.Count - 1 do
    begin
      if Members[PI].Kind <> mkProperty then Continue;
      var PM := Members[PI];
      // An ARRAY property can never be served by a field, so it is always
      // emitted verbatim - inventing accessors there would drop the index
      // list, which is exactly the reported damage.
      if PropertyIndexSpec(PM.Signature) <> '' then
        PM.NeedsSynthAccessors := False
      else
      begin
        var NeedSynth := False;
        for var AccName in [PM.GetterName, PM.SetterName] do
        begin
          if AccName = '' then Continue;
          var IsOwnMethod := False;
          for var MI := 0 to Members.Count - 1 do
            if (Members[MI].Kind = mkMethod) and
               SameText(Members[MI].Name, AccName) then
            begin
              IsOwnMethod := True;
              Break;
            end;
          if not IsOwnMethod then NeedSynth := True;
        end;
        PM.NeedsSynthAccessors := NeedSynth;
      end;
      Members[PI] := PM;
    end;

    AInfo.Members := Members.ToArray;
  finally
    Members.Free;
  end;

  AInfo.InterfaceName := SuggestInterfaceName(AInfo.ClassName);
  AInfo.Guid := NewGuidLiteral;
  AInfo.TargetFile := SuggestTargetFile(AFile, AInfo.InterfaceName);
  Result := True;
end;

class function TExtractInterfaceEngine.BuildInterfaceText(
  const AInfo: TExtractInterfaceInfo): string;
var
  SB: TStringBuilder;
  Emitted: TStringList;
  M: TClassMember;
  Pn, Getter, Setter, TN, Indent: string;
begin
  Indent := '    ';
  SB := TStringBuilder.Create;
  Emitted := TStringList.Create;
  try
    SB.Append('  ').Append(AInfo.InterfaceName).Append(' = interface').AppendLine;
    SB.Append(Indent).Append('[''').Append(AInfo.Guid).Append(''']').AppendLine;
    for M in AInfo.Members do
    begin
      if not M.Selected then Continue;
      // A CLASS member cannot be an interface method (audit #39, M38c):
      // "class function Make: TFoo" was emitted as "function Make: TFoo",
      // and the class then does not implement the interface (E2291). Such
      // a member is skipped - an interface describes what an INSTANCE can
      // do.
      if M.IsClassMember then Continue;
      case M.Kind of
        mkMethod:
        begin
          SB.Append(Indent).Append(M.Signature).Append(';').AppendLine;
          Emitted.Add(M.Signature);
        end;

        mkField:
        begin
          Pn := M.ExposedName;
          Getter := AccessorName('Get', Pn);
          Setter := AccessorName('Set', Pn);
          TN := M.TypeName;
          SB.Append(Indent).Append('function ').Append(Getter)
            .Append(': ').Append(TN).Append(';').AppendLine;
          SB.Append(Indent).Append('procedure ').Append(Setter)
            .Append('(const AValue: ').Append(TN).Append(');').AppendLine;
          SB.Append(Indent).Append('property ').Append(Pn)
            .Append(': ').Append(TN)
            .Append(' read ').Append(Getter)
            .Append(' write ').Append(Setter).Append(';').AppendLine;
        end;

        mkProperty:
        begin
          if not M.NeedsSynthAccessors then
          begin
            // An interface property may only name accessors the INTERFACE
            // itself declares, so the methods it reads and writes come
            // along - with their own signatures, which is what carries an
            // array property's index parameters (issue #46). A method the
            // user ticked as well is not emitted twice.
            for var AccName in [M.GetterName, M.SetterName] do
            begin
              if AccName = '' then Continue;
              for var A in AInfo.Members do
                if (A.Kind = mkMethod) and not A.IsClassMember and
                   SameText(A.Name, AccName) and
                   (Emitted.IndexOf(A.Signature) < 0) then
                begin
                  SB.Append(Indent).Append(A.Signature).Append(';').AppendLine;
                  Emitted.Add(A.Signature);
                end;
            end;
            SB.Append(Indent).Append(M.Signature).Append(';').AppendLine;
          end
          else
          begin
            Pn := M.ExposedName;
            Getter := AccessorName('Get', Pn);
            TN := M.TypeName;
            SB.Append(Indent).Append('function ').Append(Getter)
              .Append(': ').Append(TN).Append(';').AppendLine;
            if not M.IsReadOnly then
            begin
              Setter := AccessorName('Set', Pn);
              SB.Append(Indent).Append('procedure ').Append(Setter)
                .Append('(const AValue: ').Append(TN).Append(');').AppendLine;
              SB.Append(Indent).Append('property ').Append(Pn)
                .Append(': ').Append(TN)
                .Append(' read ').Append(Getter)
                .Append(' write ').Append(Setter).Append(';').AppendLine;
            end
            else
              SB.Append(Indent).Append('property ').Append(Pn)
                .Append(': ').Append(TN)
                .Append(' read ').Append(Getter).Append(';').AppendLine;
          end;
        end;
      end;
    end;
    SB.Append('  end;');
    Result := SB.ToString;
  finally
    Emitted.Free;
    SB.Free;
  end;
end;

class function TExtractInterfaceEngine.BuildNewUnitText(
  const AInfo: TExtractInterfaceInfo): string;
var
  UName: string;
  SB: TStringBuilder;
  I: Integer;
begin
  UName := ChangeFileExt(ExtractFileName(AInfo.TargetFile), '');
  SB := TStringBuilder.Create;
  try
    SB.Append('unit ').Append(UName).Append(';').AppendLine.AppendLine;
    SB.Append('interface').AppendLine.AppendLine;
    // An interface that names nothing but built-in types needs NO uses
    // clause, and inventing one is the opposite of what an interface unit
    // is for (user, 2026-10-17). The old else-branch guessed
    // System.Classes + System.SysUtils.
    if Length(AInfo.NewUnitUses) > 0 then
    begin
      SB.Append('uses').AppendLine;
      // Emit comma-separated on one or more wrapped lines (Delphi
      // convention) instead of one-unit-per-line. Wrap when the
      // current line would exceed ~75 chars including the trailing
      // separator.
      var Line: string := '  ';
      for I := 0 to High(AInfo.NewUnitUses) do
      begin
        var Sep: string;
        if I = High(AInfo.NewUnitUses) then Sep := ';' else Sep := ', ';
        var Add: string := AInfo.NewUnitUses[I] + Sep;
        // If Line already has content beyond the initial indent and
        // adding Add would overflow, flush Line and start a new one.
        if (Length(Line) > 2) and (Length(Line) + Length(Add) > 75) then
        begin
          SB.Append(TrimRight(Line)).AppendLine;
          Line := '  ';
        end;
        Line := Line + Add;
      end;
      if Length(Line) > 2 then
        SB.Append(TrimRight(Line)).AppendLine;
      SB.AppendLine;
    end;
    SB.Append('type').AppendLine;
    SB.Append(BuildInterfaceText(AInfo)).AppendLine.AppendLine;
    SB.Append('implementation').AppendLine.AppendLine;
    SB.Append('end.').AppendLine;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TExtractInterfaceEngine.ParseExistingInterfaceNames(
  const AFile: string; ADeclLine, AEndLine: Integer): TArray<string>;
var
  Lines: TArray<string>;
  L: TList<string>;
  I: Integer;
  Line, Trimmed, Upper: string;
  procedure AddIdentAfter(const AKeyword: string; const ATrimmedLine: string);
  var
    UpLine: string;
    Idx, Start: Integer;
  begin
    UpLine := UpperCase(ATrimmedLine);
    if not StartsText(AKeyword + ' ', UpLine) then Exit;
    Idx := Length(AKeyword) + 1;
    while (Idx <= Length(ATrimmedLine)) and (ATrimmedLine[Idx] = ' ') do Inc(Idx);
    Start := Idx;
    while (Idx <= Length(ATrimmedLine)) and
          (ATrimmedLine[Idx].IsLetterOrDigit or (ATrimmedLine[Idx] = '_')) do
      Inc(Idx);
    if Idx > Start then L.Add(Copy(ATrimmedLine, Start, Idx - Start));
  end;
  procedure CollectAfterKeyword(const AKW, AUpAcc, AOrigAcc: string);
  var
    KP, Start: Integer;
    Padded: string;
  begin
    Padded := ' ' + AUpAcc + ' ';
    KP := Pos(' ' + AKW + ' ', Padded);
    if KP = 0 then Exit;
    KP := KP + Length(AKW); // index in Padded after the keyword
    while (KP <= Length(Padded)) and (Padded[KP] = ' ') do Inc(KP);
    Start := KP;
    while (KP <= Length(Padded)) and
          (Padded[KP].IsLetterOrDigit or (Padded[KP] = '_')) do
      Inc(KP);
    if KP > Start then
      L.Add(Copy(AOrigAcc, Start - 1, KP - Start));
  end;
begin
  Result := nil;
  Lines := TDelphiFileEncoding.ReadLines(AFile);
  L := TList<string>.Create;
  try
    for I := ADeclLine to AEndLine - 1 do
    begin
      if (I < 1) or (I > Length(Lines)) then Continue;
      Line := StripLineComment(Lines[I - 1]);
      Trimmed := Trim(Line);
      if Trimmed = '' then Continue;
      Upper := UpperCase(Trimmed);

      if StartsText('PROCEDURE ', Upper) or StartsText('FUNCTION ', Upper) then
      begin
        AddIdentAfter('PROCEDURE', Trimmed);
        AddIdentAfter('FUNCTION', Trimmed);
      end
      else if StartsText('PROPERTY ', Upper) then
      begin
        AddIdentAfter('PROPERTY', Trimmed);
        CollectAfterKeyword('READ', Upper, Trimmed);
        CollectAfterKeyword('WRITE', Upper, Trimmed);
      end;

    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

class function TExtractInterfaceEngine.WouldEmitNames(
  const M: TClassMember): TArray<string>;
var
  L: TList<string>;
begin
  L := TList<string>.Create;
  try
    case M.Kind of
      mkMethod: L.Add(M.Name);
      mkField:
      begin
        L.Add(M.ExposedName);          // interface property name
        L.Add(AccessorName('Get', M.ExposedName));
        L.Add(AccessorName('Set', M.ExposedName));
      end;
      mkProperty:
      begin
        L.Add(M.ExposedName);
        if M.NeedsSynthAccessors then
        begin
          L.Add(AccessorName('Get', M.ExposedName));
          if not M.IsReadOnly then L.Add(AccessorName('Set', M.ExposedName));
        end
        else
        begin
          // The accessor METHODS travel with the property, so their names
          // are part of what this member puts into the interface.
          if M.GetterName <> '' then L.Add(M.GetterName);
          if M.SetterName <> '' then L.Add(M.SetterName);
        end;
      end;
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

class function TExtractInterfaceEngine.ClashesWithExisting(
  const M: TClassMember; const AExistingUpper: TArray<string>): Boolean;
var
  Mine: TArray<string>;
  N, E: string;
begin
  Result := False;
  Mine := WouldEmitNames(M);
  for N in Mine do
    for E in AExistingUpper do
      if SameText(N, E) then Exit(True);
end;

class function TExtractInterfaceEngine.ParseClassAncestors(
  const AHeaderLine: string; out ABaseClass: string): TArray<string>;
var
  L, Inner, Item, Name: string;
  P, Q, GenPos, I: Integer;
  Items: TArray<string>;
  List: TList<string>;
begin
  Result := nil;
  ABaseClass := '';
  L := StripLineComment(AHeaderLine);
  P := Pos('(', L);
  if P = 0 then Exit;
  Q := Pos(')', L);
  if Q <= P then Exit;
  Inner := Trim(Copy(L, P + 1, Q - P - 1));
  if Inner = '' then Exit;
  Items := Inner.Split([',']);
  List := TList<string>.Create;
  try
    for I := 0 to High(Items) do
    begin
      Item := Trim(Items[I]);
      if Item = '' then Continue;
      Name := Item;
      // strip generic argument list
      GenPos := Pos('<', Name);
      if GenPos > 0 then Name := Trim(Copy(Name, 1, GenPos - 1));
      if I = 0 then
        ABaseClass := Name
      else
        List.Add(Name);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

class function TExtractInterfaceEngine.ClassHasDestructor(
  const AFileLines: TArray<string>;
  AClassDeclLine, AClassEndLine: Integer): Boolean;
var
  I: Integer;
  Upper: string;
begin
  Result := False;
  for I := AClassDeclLine to AClassEndLine - 2 do
  begin
    if (I < 0) or (I >= Length(AFileLines)) then Continue;
    Upper := UpperCase(Trim(StripLineComment(AFileLines[I])));
    if StartsText('DESTRUCTOR ', Upper) or
       StartsText('CLASS DESTRUCTOR ', Upper) then
      Exit(True);
  end;
end;

class function TExtractInterfaceEngine.ClassHasMethodDecl(
  const AFileLines: TArray<string>;
  AClassDeclLine, AClassEndLine: Integer;
  const AMethodName: string): Boolean;
var
  I, P: Integer;
  Upper, NameUpper, Trimmed: string;
  procedure TestPrefix(const APrefix: string);
  var After: Char;
  begin
    if not StartsText(APrefix, Upper) then Exit;
    P := Length(APrefix);
    if P >= Length(Upper) then begin Result := True; Exit; end;
    After := Upper[P + 1];
    // whole-identifier: char right after the name must not be
    // ident-cont (so 'NewInstancePlus' doesn't match 'NewInstance').
    if not (After.IsLetterOrDigit or (After = '_')) then
      Result := True;
  end;
begin
  Result := False;
  NameUpper := UpperCase(AMethodName);
  for I := AClassDeclLine to AClassEndLine - 2 do
  begin
    if (I < 0) or (I >= Length(AFileLines)) then Continue;
    Trimmed := Trim(StripLineComment(AFileLines[I]));
    if Trimmed = '' then Continue;
    Upper := UpperCase(Trimmed);
    // Strip a leading 'class' modifier.
    if StartsText('CLASS ', Upper) then
      Upper := Trim(Copy(Upper, 7, MaxInt));
    TestPrefix('PROCEDURE ' + NameUpper);
    if Result then Exit;
    TestPrefix('FUNCTION ' + NameUpper);
    if Result then Exit;
  end;
end;

class function TExtractInterfaceEngine.ParseInterfaceMethodSignatures(
  const AFile: string; ADeclLine, AEndLine: Integer): TArray<TInterfaceMethodInfo>;
var
  Lines: TArray<string>;
  L: TList<TInterfaceMethodInfo>;
  I, K, Depth, LastColon: Integer;
  Line, Trimmed, Upper, Acc, Tail, NamePart: string;
  Info: TInterfaceMethodInfo;
begin
  Result := nil;
  Lines := TDelphiFileEncoding.ReadLines(AFile);
  L := TList<TInterfaceMethodInfo>.Create;
  try
    I := ADeclLine; // skip the "IFoo = interface" header itself
    while (I < AEndLine - 1) and (I < Length(Lines)) do
    begin
      Line := StripLineComment(Lines[I]);
      Trimmed := Trim(Line);
      Upper := UpperCase(Trimmed);
      if not (StartsText('PROCEDURE ', Upper) or StartsText('FUNCTION ', Upper)) then
      begin
        Inc(I);
        Continue;
      end;
      // Collect the signature across lines until we see a ';' that
      // closes the header. (Interface methods rarely have directives
      // but we strip the trailing ';' regardless.)
      Acc := Trimmed;
      while Pos(';', StripLineComment(Acc)) = 0 do
      begin
        Inc(I);
        if (I >= AEndLine - 1) or (I >= Length(Lines)) then Break;
        Acc := Acc + ' ' + Trim(StripLineComment(Lines[I]));
      end;
      while (Acc <> '') and (Acc[Length(Acc)] = ';') do
        Acc := Trim(Copy(Acc, 1, Length(Acc) - 1));

      Info := Default(TInterfaceMethodInfo);
      Info.Signature := Acc;
      Info.IsFunction := StartsText('FUNCTION ', UpperCase(Acc));
      // Method name = first identifier after the keyword.
      K := Pos(' ', Acc);
      if K > 0 then
      begin
        Tail := Trim(Copy(Acc, K, MaxInt));
        var EndIdx: Integer := 1;
        while (EndIdx <= Length(Tail)) and
              (Tail[EndIdx].IsLetterOrDigit or (Tail[EndIdx] = '_')) do
          Inc(EndIdx);
        Info.Name := Copy(Tail, 1, EndIdx - 1);
      end;
      if Info.IsFunction then
      begin
        // Return type = text after the LAST top-level ':' in the signature.
        Depth := 0;
        LastColon := 0;
        for K := 1 to Length(Acc) do
        begin
          case Acc[K] of
            '(': Inc(Depth);
            ')': Dec(Depth);
            ':': if Depth = 0 then LastColon := K;
          end;
        end;
        if LastColon > 0 then
        begin
          NamePart := Trim(Copy(Acc, LastColon + 1, MaxInt));
          Info.ReturnType := NamePart;
        end;
      end;
      L.Add(Info);
      Inc(I);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

class function TExtractInterfaceEngine.TypeKeywordPos(const ALine: string;
  const AKeywords: array of string): Integer;
var
  P, Q: Integer;
  W: string;
begin
  Result := 0;
  P := Pos('=', ALine);
  if P = 0 then Exit;
  Inc(P);
  repeat
    while (P <= Length(ALine)) and ALine[P].IsWhiteSpace do Inc(P);
    Q := P;
    while (Q <= Length(ALine)) and IsIdentChar(ALine[Q]) do Inc(Q);
    W := Copy(ALine, P, Q - P);
    if not SameText(W, 'packed') then Break;
    P := Q;
  until False;
  if W = '' then Exit;
  for var K in AKeywords do
    if SameText(W, K) then Exit(P);
end;

class function TExtractInterfaceEngine.InterfaceSpliceLines(
  const AInfo: TExtractInterfaceInfo): TArray<string>;
var
  Body: TStringList;
  I: Integer;
begin
  Result := nil;
  Body := TStringList.Create;
  try
    Body.Text := BuildInterfaceText(AInfo);
    // header, GUID ... "end;" - the frame always goes, also when nothing
    // is left between it
    for I := 2 to Body.Count - 2 do
      if Trim(Body[I]) <> '' then
        Result := Result + [Body[I]];
  finally
    Body.Free;
  end;
end;

class function TExtractInterfaceEngine.RelocateClass(
  const AFileLines: TArray<string>; const AClassName: string; ANearLine: Integer;
  out ADeclLine, AEndLine: Integer): Boolean;
var
  I, Best, EqPos: Integer;
  L, Name: string;
  Info: TExtractInterfaceInfo;
begin
  Result := False;
  ADeclLine := 0;
  AEndLine := 0;
  Best := -1;
  for I := 0 to High(AFileLines) do
  begin
    L := StripLineComment(AFileLines[I]);
    if TypeKeywordPos(L, ['class']) = 0 then Continue;
    EqPos := Pos('=', L);
    Name := Trim(Copy(L, 1, EqPos - 1));
    if Pos('<', Name) > 0 then Name := Trim(Copy(Name, 1, Pos('<', Name) - 1));
    if not SameText(Name, AClassName) then Continue;
    if (Best < 0) or (Abs(I + 1 - ANearLine) < Abs(Best + 1 - ANearLine)) then
      Best := I;
  end;
  if Best < 0 then Exit;
  // the parse walks up from the given line, so it starts on the header
  if not ParseClassAtLine(AFileLines, '', Best + 1, Info) then Exit;
  if not SameText(Info.ClassName, AClassName) then Exit;
  ADeclLine := Info.ClassDeclLine;
  AEndLine := Info.ClassEndLine;
  Result := True;
end;

{ TIInterfaceVerdict }

function TIInterfaceVerdict.Ok: Boolean;
begin
  Result := Need = iinSatisfied;
end;

class function TExtractInterfaceEngine.KnownIInterfaceBaseKind(
  const ABaseClass: string): TIInterfaceBaseKind;
const
  // MEASURED in the shipped RTL sources, not assumed: System.pas declares
  // TInterfacedObject, TContainedObject, TClassHelperBase and
  // TNoRefCountObject with IInterface in their ancestor list,
  // System.Classes TInterfacedPersistent and TComponent; TAggregatedObject
  // is "class(TObject)" and declares the three methods itself (so the
  // ancestor list alone would have answered wrongly there), and
  // TSingletonImplementation gets them from TNoRefCountObject.
  Implementers: array[0..9] of string = ('TInterfacedObject',
    'TAggregatedObject', 'TContainedObject', 'TClassHelperBase',
    'TNoRefCountObject', 'TSingletonImplementation', 'TInterfacedPersistent',
    'TComponent', 'TInterfaceList', 'TStreamAdapter');
  // SHORTCUTS, not independent facts: every one of these descends from
  // TComponent (measured - Vcl.Controls "TControl = class(TComponent)",
  // FMX.Types "TFmxObject = class(TComponent)"), so the chain walk would
  // reach the same answer. It would do so by parsing Vcl.Forms and
  // Vcl.Controls on the main thread, and it would answer "could not be
  // determined" while the identifier index is still cold - which is
  // exactly the moment someone opens a form and runs this.
  Roots: array[0..10] of string = ('TControl', 'TWinControl',
    'TCustomControl', 'TGraphicControl', 'TScrollingWinControl',
    'TCustomForm', 'TForm', 'TFrame', 'TCustomFrame', 'TDataModule',
    'TFmxObject');
begin
  // An implicit base IS TObject ("TFoo = class").
  if Trim(ABaseClass) = '' then Exit(ibkTObjectLike);
  if SameText(ABaseClass, 'TObject') or SameText(ABaseClass, 'TPersistent') then
    Exit(ibkTObjectLike);
  for var N in Implementers do
    if SameText(ABaseClass, N) then Exit(ibkImplements);
  for var N in Roots do
    if SameText(ABaseClass, N) then Exit(ibkImplements);
  Result := ibkUnknown;
end;

class function TExtractInterfaceEngine.IInterfaceNeedOf(
  const AFileLines: TArray<string>;
  AClassDeclLine, AClassEndLine: Integer; const AClassName: string;
  const AResolver: TIInterfaceBaseResolver): TIInterfaceVerdict;
const
  Methods: array[0..2] of string = ('QueryInterface', '_AddRef', '_Release');
var
  Have: TArray<string>;
  Kind: TIInterfaceBaseKind;
  BaseName: string;
begin
  Result := Default(TIInterfaceVerdict);
  Result.Need := iinSatisfied;
  if (AClassDeclLine < 1) or (AClassDeclLine > Length(AFileLines)) then
  begin
    Result.Need := iinUnknownBase;
    Result.Reason := 'the class declaration is outside the file';
    Exit;
  end;

  for var A in ParseClassAncestors(AFileLines[AClassDeclLine - 1],
    Result.BaseClass) do
    if SameText(A, 'IInterface') or SameText(A, 'IUnknown') then
      Result.ListsInterface := True;
  if Result.BaseClass = '' then BaseName := 'TObject' else BaseName := Result.BaseClass;

  for var M in Methods do
    if ClassHasMethodDecl(AFileLines, AClassDeclLine, AClassEndLine, M) then
      Have := Have + [M]
    else
      Result.Missing := Result.Missing + [M];

  if Length(Result.Missing) = 0 then
  begin
    Result.Reason := Format(
      '%s declares QueryInterface, _AddRef and _Release itself', [AClassName]);
    Exit;
  end;

  // Known names first: the answer is exact and costs nothing, and it keeps
  // a resolver from having to be right about the RTL.
  Kind := KnownIInterfaceBaseKind(Result.BaseClass);
  if (Kind = ibkUnknown) and Assigned(AResolver) then
    Kind := AResolver(Result.BaseClass);

  if Kind = ibkImplements then
  begin
    Result.Reason := Format('%s descends from %s, which implements IInterface',
      [AClassName, BaseName]);
    Exit;
  end;

  // PART of IInterface by hand is a deliberate implementation (a
  // delegation, a no-refcount object): swapping its ancestor would collide
  // with what is already there, so the only honest offer is to complete it.
  if Length(Have) > 0 then
  begin
    Result.Need := iinAddSupport;
    Result.Reason := Format('%s declares %s, but not %s',
      [AClassName, string.Join(', ', Have), string.Join(', ', Result.Missing)]);
    Result.Offer := 'complete the missing method(s) by hand - "Add IInterface ' +
      'support to class" would redeclare what is already there';
  end
  else
    case Kind of
      ibkTObjectLike:
        begin
          Result.Need := iinChangeAncestor;
          if SameText(Result.BaseClass, 'TPersistent') then
            Result.SuggestedAncestor := 'TInterfacedPersistent'
          else
            Result.SuggestedAncestor := 'TInterfacedObject';
          Result.Reason := Format('%s descends from %s, which does not ' +
            'implement IInterface - QueryInterface, _AddRef and _Release are ' +
            'missing', [AClassName, BaseName]);
          Result.Offer := Format('derive it from %s, or add IInterface ' +
            'support to the class itself', [Result.SuggestedAncestor]);
        end;
      ibkOther:
        begin
          Result.Need := iinAddSupport;
          Result.Reason := Format('%s descends from %s, and nothing on that ' +
            'chain implements IInterface', [AClassName, BaseName]);
          Result.Offer := Format('add IInterface support to the class - ' +
            'deriving from TInterfacedObject instead would drop %s', [BaseName]);
        end;
    else
      Result.Need := iinUnknownBase;
      Result.Reason := Format('%s descends from %s, and whether that ' +
        'implements IInterface could not be determined here',
        [AClassName, BaseName]);
      Result.Offer := 'if the compiler reports the three IInterface methods ' +
        'as missing, add IInterface support to the class';
    end;

  if not Result.Ok then
    if Result.ListsInterface then
      Result.Reason := Result.Reason +
        ' (its ancestor list already names IInterface, so it does not compile ' +
        'as it stands)';
end;

class function TExtractInterfaceEngine.PlanBaseClassChange(
  const AHeaderLine, ANewBase: string; out ANewLine, AWhy: string): Boolean;
var
  Code, Rest: string;
  KP, P, Q, Start, Stop: Integer;
begin
  Result := False;
  ANewLine := '';
  AWhy := '';
  if Trim(ANewBase) = '' then
  begin
    AWhy := 'no base class given';
    Exit;
  end;
  Code := StripLineComment(AHeaderLine);
  KP := TypeKeywordPos(Code, ['class']);
  if KP = 0 then
  begin
    AWhy := 'the line does not declare a class';
    Exit;
  end;
  Rest := Trim(Copy(Code, KP + Length('class'), MaxInt));
  // "TFoo = class;" is a forward declaration and "TFoo = class of TBar" a
  // metaclass - neither has a base class to change. An EMPTY rest is
  // neither: that is a class whose body follows on the next lines, which
  // is the shape issue #46 reported.
  if StartsStr(';', Rest) then
  begin
    AWhy := 'a forward declaration has no ancestor list';
    Exit;
  end;
  if StartsText('of ', Rest) then
  begin
    AWhy := 'a class reference type has no ancestor list';
    Exit;
  end;

  P := 0;
  for var I := KP + Length('class') to Length(Code) do
    if Code[I] = '(' then
    begin
      P := I;
      Break;
    end
    else if Code[I] = ')' then
      Break;

  if P = 0 then
  begin
    // No list yet: Delphi writes the parentheses AFTER the class
    // modifiers - "TFoo = class abstract(TBase)".
    Stop := KP + Length('class');
    while True do
    begin
      var I := Stop;
      while (I <= Length(Code)) and CharInSet(Code[I], [' ', #9]) do Inc(I);
      var W := '';
      while (I <= Length(Code)) and IsIdentChar(Code[I]) do
      begin
        W := W + Code[I];
        Inc(I);
      end;
      if SameText(W, 'abstract') or SameText(W, 'sealed') then
        Stop := I
      else
        Break;
    end;
    ANewLine := Copy(AHeaderLine, 1, Stop - 1) + '(' + ANewBase + ')' +
      Copy(AHeaderLine, Stop, MaxInt);
    Exit(True);
  end;

  Q := 0;
  for var I := P + 1 to Length(Code) do
    if Code[I] = ')' then
    begin
      Q := I;
      Break;
    end;
  if Q = 0 then
  begin
    AWhy := 'the ancestor list is not closed on the class header line';
    Exit;
  end;

  // The first entry is the base class (Delphi allows only one), so its
  // span is what gets replaced - every interface behind it stays.
  Start := P + 1;
  while (Start < Q) and CharInSet(Code[Start], [' ', #9]) do Inc(Start);
  Stop := Start;
  while (Stop < Q) and (Code[Stop] <> ',') do Inc(Stop);
  var Current := Trim(Copy(Code, Start, Stop - Start));
  if Current = '' then
  begin
    // "TFoo = class()" - nothing to replace, so put the base in.
    ANewLine := Copy(AHeaderLine, 1, P) + ANewBase +
      Copy(AHeaderLine, P + 1, MaxInt);
    Exit(True);
  end;
  if SameText(Current, ANewBase) then
  begin
    AWhy := Format('it already derives from %s', [ANewBase]);
    Exit;
  end;
  ANewLine := Copy(AHeaderLine, 1, Start - 1) + ANewBase +
    Copy(AHeaderLine, Start + Length(Current), MaxInt);
  Result := True;
end;

class function TExtractInterfaceEngine.BuildIInterfaceDeclBlock(
  AHasNewInstance, AHasAfterConstruction: Boolean): string;
begin
  Result :=
    '  private' + sLineBreak +
    '    FRefCount: Integer;' + sLineBreak +
    '  protected' + sLineBreak +
    '    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;' + sLineBreak +
    '    function _AddRef: Integer; stdcall;' + sLineBreak +
    '    function _Release: Integer; stdcall;';
  if AHasNewInstance and AHasAfterConstruction then Exit;
  Result := Result + sLineBreak + '  public';
  if not AHasAfterConstruction then
    Result := Result + sLineBreak +
      '    procedure AfterConstruction; override;';
  if not AHasNewInstance then
    Result := Result + sLineBreak +
      '    class function NewInstance: TObject; override;';
end;

{ ---------- TProjectInterfaceScanner ---------- }

class function TProjectInterfaceScanner.ScanFile(
  const AFileName: string): TArray<TInterfaceDeclLocation>;
var
  Lines: TArray<string>;
begin
  Result := nil;
  if not TFile.Exists(AFileName) then Exit;
  try
    Lines := TDelphiFileEncoding.ReadLines(AFileName);
  except
    Exit;
  end;
  Result := ScanLines(AFileName, Lines);
end;

class function TProjectInterfaceScanner.FindDecl(const ALines: TArray<string>;
  const AInterfaceName: string; ANearLine: Integer;
  out ALoc: TInterfaceDeclLocation): Boolean;
var
  Loc: TInterfaceDeclLocation;
begin
  Result := False;
  ALoc := Default(TInterfaceDeclLocation);
  for Loc in ScanLines('', ALines) do
    if SameText(Loc.InterfaceName, AInterfaceName) and
       (not Result or (Abs(Loc.DeclLine - ANearLine) < Abs(ALoc.DeclLine - ANearLine))) then
    begin
      ALoc := Loc;
      Result := True;
    end;
end;

class function TProjectInterfaceScanner.ScanLines(const AFileName: string;
  const ALines: TArray<string>): TArray<TInterfaceDeclLocation>;
var
  I, J: Integer;
  L, Trimmed: string;
  EqPos, IfacePos, Depth: Integer;
  List: TList<TInterfaceDeclLocation>;
begin
  List := TList<TInterfaceDeclLocation>.Create;
  try
    I := 0;
    while I < Length(ALines) do
    begin
      L := StripLineComment(ALines[I]);
      Trimmed := Trim(L);
      EqPos := Pos('=', Trimmed);
      if EqPos > 0 then
      begin
        // "interface" / "dispinterface" as the first word after '=' - a
        // Pos() over the line also took "class(TInterfacedObject, IFoo)".
        // A forward "IFoo = interface;" has no body: its end would be the
        // next type's.
        IfacePos := TExtractInterfaceEngine.TypeKeywordPos(Trimmed,
          ['interface', 'dispinterface']);
        if IfacePos > 0 then
        begin
          var KwLen := Length('interface');
          if StartsText('dispinterface', Copy(Trimmed, IfacePos, MaxInt)) then
            KwLen := Length('dispinterface');
          if StartsText(';', TrimLeft(Copy(Trimmed, IfacePos + KwLen, MaxInt))) then
            IfacePos := 0;
        end;
        if IfacePos > 0 then
        begin
          // exclude the unit's "interface" section keyword
          var Name_ := Trim(Copy(Trimmed, 1, EqPos - 1));
          // exclude generic-suffix
          var GenPos := Pos('<', Name_);
          if GenPos > 0 then Name_ := Trim(Copy(Name_, 1, GenPos - 1));
          if (Name_ <> '') and IsIdentStart(Name_[1]) then
          begin
            // Find the matching 'end;' tracking record/class nesting.
            Depth := 1;
            var EndLineFound := -1;
            J := I;
            while J < Length(ALines) do
            begin
              var LineU := UpperCase(StripLineComment(ALines[J]));
              var Pos_ := 1;
              while Pos_ <= Length(LineU) do
              begin
                if IsIdentStart(LineU[Pos_]) then
                begin
                  var Q := Pos_;
                  while (Q <= Length(LineU)) and IsIdentChar(LineU[Q]) do Inc(Q);
                  var W := Copy(LineU, Pos_, Q - Pos_);
                  if (W = 'RECORD') and (J > I) then Inc(Depth)
                  else if (W = 'END') then
                  begin
                    Dec(Depth);
                    if Depth = 0 then begin EndLineFound := J + 1; Break; end;
                  end;
                  Pos_ := Q;
                end
                else
                  Inc(Pos_);
              end;
              if EndLineFound > 0 then Break;
              Inc(J);
            end;
            if EndLineFound > 0 then
            begin
              var Loc: TInterfaceDeclLocation;
              Loc.FileName := AFileName;
              Loc.InterfaceName := Name_;
              Loc.DeclLine := I + 1;
              Loc.EndLine := EndLineFound;
              List.Add(Loc);
              I := EndLineFound;
              Continue;
            end;
          end;
        end;
      end;
      Inc(I);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

class function TProjectInterfaceScanner.ScanProject(
  const AFiles: TArray<string>): TArray<TInterfaceDeclLocation>;
var
  All: TList<TInterfaceDeclLocation>;
  F: string;
begin
  All := TList<TInterfaceDeclLocation>.Create;
  try
    for F in AFiles do
      All.AddRange(ScanFile(F));
    Result := All.ToArray;
  finally
    All.Free;
  end;
end;

end.
