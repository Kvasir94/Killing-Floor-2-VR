// Shown text in the player's language. The source text stays English: menus,
// training and the watch build their English strings as before, and the
// functions that draw text pass them through T(). English draws as written.
//
// The language follows the game's own (Steam's language for KF2, so a Russian
// KF2 shows a Russian VR menu); Language in [KF2VR.VRText] overrides it
// ("RUS" or "INT"). A table is a generated class (VRTextRussian, from
// tools/vr-text-ru.txt by tools/vr_text.py) holding English keys and their
// translations; non-ASCII letters are stored escaped so the package source
// stays ASCII, and are decoded once.
//
// A key is the whole English text, or a template whose * parts stand for
// any text ("PAGE * OF *"); each part is translated in turn. Text no key
// matches is split at ": ", " / " and similar joints, and its pieces are
// translated, so a row built from a label and a value needs no key of its
// own. Untranslated text (map and player names, numbers) draws as it is.
class VRText extends Object config(Game);

var config string Language;
var bool bActive;
var array<string> Keys, Values, Templates, TemplateValues;
var array<string> CacheIn, CacheOut;
var array<string> Joints;
const CACHE_LIMIT = 1024;

// The loaded table is one named object in the transient package. Garbage
// collection may drop it between maps; it is then simply loaded again.
static function string T(string Value)
{
    local VRText Table;
    if (Value == "") return Value;
    Table = VRText(FindObject("Transient.KF2VRTextTable", class'VRText'));
    if (Table == None)
    {
        Table = new(None, "KF2VRTextTable") class'VRText';
        Table.Load();
    }
    // Counts and percentages change every frame and have nothing to translate.
    return (Table.bActive && HasLetter(Value)) ? Table.Lookup(Value) : Value;
}

static function bool HasLetter(string Value)
{
    local int I, Code;
    for (I = 0; I < Len(Value); ++I)
    {
        Code = Asc(Mid(Value, I, 1));
        if ((Code >= 65 && Code <= 90) || (Code >= 97 && Code <= 122)) return true;
    }
    return false;
}

function Load()
{
    local string Code;
    Code = Caps((default.Language != "") ? default.Language : GetLanguage());
    bActive = (Code == "RUS");
    if (bActive) LoadTable(class'VRTextRussian'.default.En, class'VRTextRussian'.default.Ru,
        class'VRTextRussian'.default.Alphabet, class'VRTextRussian'.default.Codes);
}

function LoadTable(array<string> En, array<string> Shown, string Alphabet, array<int> Codes)
{
    local int I;
    for (I = 0; I < En.Length && I < Shown.Length; ++I)
    {
        if (InStr(En[I], "*") >= 0)
        {
            Templates.AddItem(En[I]);
            TemplateValues.AddItem(Decode(Shown[I], Alphabet, Codes));
        }
        else
        {
            Keys.AddItem(En[I]);
            Values.AddItem(Decode(Shown[I], Alphabet, Codes));
        }
    }
}

// "~" and one character of Alphabet stand for the character Codes gives it.
static function string Decode(string Value, string Alphabet, array<int> Codes)
{
    local int I, Index;
    local string Result, Letter;
    if (InStr(Value, "~") < 0) return Value;
    for (I = 0; I < Len(Value); ++I)
    {
        Letter = Mid(Value, I, 1);
        if ((Letter == "~") && (I + 1 < Len(Value)))
        {
            ++I;
            Index = InStr(Alphabet, Mid(Value, I, 1));
            Letter = ((Index >= 0) && (Index < Codes.Length)) ? Chr(Codes[Index]) : Mid(Value, I, 1);
        }
        Result $= Letter;
    }
    return Result;
}

function string Lookup(string Value)
{
    local int I;
    local string Shown;
    I = CacheIn.Find(Value);
    if ((I != INDEX_NONE) && (CacheIn[I] == Value)) return CacheOut[I];
    Shown = Translate(Value, 0);
    if (CacheIn.Length >= CACHE_LIMIT) { CacheIn.Length = 0; CacheOut.Length = 0; }
    CacheIn.AddItem(Value);
    CacheOut.AddItem(Shown);
    return Shown;
}

function int ExactKey(string Value)
{
    local int I;
    I = Keys.Find(Value);
    if ((I == INDEX_NONE) || (Keys[I] == Value)) return I;
    // Find may ignore case; "OFF" and "Off" are different keys.
    for (I = 0; I < Keys.Length; ++I)
        if (Keys[I] == Value) return I;
    return INDEX_NONE;
}

function string Translate(string Value, int Depth)
{
    local int I, At, Keep;
    local array<string> Parts;
    if ((Depth > 6) || (Value == "")) return Value;
    I = ExactKey(Value);
    if (I != INDEX_NONE) return Values[I];
    for (I = 0; I < Templates.Length; ++I)
        if (Match(Templates[I], Value, Parts)) return Fill(TemplateValues[I], Parts, Depth);
    for (I = 0; I < Joints.Length; ++I)
    {
        At = InStr(Value, Joints[I]);
        if (At > 0 && At + Len(Joints[I]) < Len(Value))
        {
            // A sentence keeps its own full stop or question mark.
            Keep = (InStr(".?!", Left(Joints[I], 1)) >= 0) ? 1 : 0;
            return Translate(Left(Value, At + Keep), Depth + 1) $ Mid(Joints[I], Keep)
                $ Translate(Mid(Value, At + Len(Joints[I])), Depth + 1);
        }
    }
    return Value;
}

// Parts receives the text each * stood for; none is empty.
function bool Match(string Template, string Value, out array<string> Parts)
{
    local array<string> Pieces;
    local int I, At, Position, Ending;
    Parts.Length = 0;
    // Without culling, a leading or trailing * gives an empty first or last piece.
    ParseStringIntoArray(Template, Pieces, "*", false);
    if ((Pieces.Length < 2) || (Left(Value, Len(Pieces[0])) != Pieces[0])) return false;
    Position = Len(Pieces[0]);
    Ending = Len(Value) - Len(Pieces[Pieces.Length - 1]);
    if ((Ending < Position) || (Mid(Value, Ending) != Pieces[Pieces.Length - 1])) return false;
    for (I = 1; I < Pieces.Length - 1; ++I)
    {
        At = (Pieces[I] == "") ? INDEX_NONE : InStr(Mid(Value, Position + 1, Ending - Position - 1), Pieces[I]);
        if (At == INDEX_NONE) return false;
        At += Position + 1;
        Parts.AddItem(Mid(Value, Position, At - Position));
        Position = At + Len(Pieces[I]);
    }
    if (Ending <= Position) return false;
    Parts.AddItem(Mid(Value, Position, Ending - Position));
    // A * stands for a word or a name, never for joined text: "PRESS *" must not
    // take "PRESS TO BRACE; PRESS AGAIN TO LET GO", which the joints translate.
    for (I = 0; I < Parts.Length; ++I)
        if (InStr(Parts[I], ": ") >= 0 || InStr(Parts[I], "; ") >= 0 || InStr(Parts[I], ". ") >= 0
            || InStr(Parts[I], " / ") >= 0 || InStr(Parts[I], " | ") >= 0) return false;
    return true;
}

function string Fill(string Shown, array<string> Parts, int Depth)
{
    local int I, At;
    local string Result;
    for (I = 0; I < Parts.Length; ++I)
    {
        At = InStr(Shown, "*");
        if (At < 0) break;
        Result $= Left(Shown, At) $ Translate(Parts[I], Depth + 1);
        Shown = Mid(Shown, At + 1);
    }
    return Result $ Shown;
}

defaultproperties
{
    // Tried in this order where no key matches the whole text.
    Joints(0)="  /  "
    Joints(1)=". "
    Joints(2)="? "
    Joints(3)="! "
    Joints(4)=" / "
    Joints(5)=": "
    Joints(6)=" | "
    Joints(7)="; "
    Joints(8)=" + "
    Joints(9)=" - "
}
