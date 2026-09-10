' tests/test_util.bas -- util layer tests (included by test_core.bas)

' ---------------------------------------------------------------- utf8
t_begin("utf8")
Scope
    Dim s As String = "a" & !"ש" & Chr(&hF0, &h9F, &h98, &h80) & "b"   ' a, U+05E9, U+1F600, b
    Dim p As Long = 0
    check_int(utf8_decode(s, p), 97, "decode ascii")
    check_int(utf8_decode(s, p), &h5E9, "decode 2-byte hebrew")
    check_int(utf8_decode(s, p), &h1F600, "decode 4-byte emoji")
    check_int(utf8_decode(s, p), 98, "decode trailing ascii")
    check_int(p, Len(s), "decode consumed all")
    check_int(utf8_len(s), 4, "utf8_len")
    check_str(utf8_encode(&h5E9), !"ש", "encode 2-byte")
    check_str(utf8_encode(&h20AC), !"€", "encode 3-byte")
    check_str(utf8_encode(&h1F600), Chr(&hF0, &h9F, &h98, &h80), "encode 4-byte")
    check(utf8_valid(s), "valid utf8")
    check(utf8_valid(Chr(&hE9) & "t" & Chr(&hE9)) = 0, "latin1 bytes are invalid utf8")
    check(utf8_valid(Chr(&hC0, &hAF)) = 0, "overlong rejected")
    check(utf8_valid(Chr(&hED, &hA0, &h80)) = 0, "surrogate rejected")
    check(utf8_valid(Chr(&hE2, &h82)) = 0, "truncated sequence rejected")
    Dim q As Long = 0
    check_int(utf8_decode(Chr(&hE2, &h82), q), UTF8_REPLACEMENT, "truncated -> U+FFFD")
    check_int(q, 1, "truncated advances one byte")
    check_int(utf8_prev(s, Len(s) - 1), Len(s) - 5, "utf8_prev over emoji")
    check_int(utf8_next(s, 1), 3, "utf8_next over hebrew")
    check_int(utf8_safe_cut(s, 2), 1, "safe cut does not split hebrew")
    check_int(utf8_safe_cut(s, 5), 3, "safe cut does not split emoji")
    check_int(utf8_safe_cut(s, 7), 7, "safe cut at boundary")
End Scope

t_begin("width")
Scope
    check_int(utf8_cp_width(Asc("a")), 1, "ascii")
    check_int(utf8_cp_width(&h301), 0, "combining acute")
    check_int(utf8_cp_width(&h5B4), 0, "hebrew point hiriq")
    check_int(utf8_cp_width(&h65E5), 2, "CJK wide")
    check_int(utf8_cp_width(&h1F600), 2, "emoji wide")
    check_int(utf8_cp_width(&h5D0), 1, "hebrew letter")
    check_int(utf8_width("abc" & !"日本"), 7, "string width")
    check_str(utf8_truncate_width("ab" & !"日本" & "c", 4), "ab" & !"日", "truncate keeps whole wide char")
    check_str(utf8_truncate_width("ab" & !"日本" & "c", 5), "ab" & !"日", "truncate never splits a wide char")
End Scope

t_begin("charset")
Scope
    check_str(charset_to_utf8(Chr(&hF9, &hEC, &hE5, &hED), CHARSET_CP1255), !"שלום", "cp1255 hebrew")
    check_str(charset_to_utf8(Chr(&hCF, &hF0, &hE8), CHARSET_CP1251), !"При", "cp1251 cyrillic")
    check_str(charset_to_utf8(Chr(&h80), CHARSET_CP1252), !"€", "cp1252 euro")
    check_str(charset_to_utf8(Chr(&hE9), CHARSET_LATIN1), !"é", "latin1")
    check_str(utf8_from_wire("caf" & Chr(&hE9), CHARSET_LATIN1), !"café", "invalid utf8 falls back")
    check_str(utf8_from_wire(!"café", CHARSET_CP1255), !"café", "valid utf8 kept")
    check_str(utf8_to_charset(!"שלום", CHARSET_CP1255), Chr(&hF9, &hEC, &hE5, &hED), "utf8 -> cp1255")
    check_str(utf8_to_charset(!"日", CHARSET_CP1255), "?", "unrepresentable -> ?")
    check_int(charset_from_name("windows-1255"), CHARSET_CP1255, "charset name")
    check_str(utf8_lcase(!"ÉCOLE Привет"), !"école привет", "utf8_lcase")
End Scope

' ---------------------------------------------------------------- strutil
t_begin("strutil")
Scope
    Dim a() As String
    check_int(str_split("a,b,,c", ",", a()), 4, "split count keeps empties")
    check_str(a(2), "", "split empty field")
    check_str(a(3), "c", "split last")
    check_int(str_split("abc", ",", a()), 1, "split no separator")
    check_int(str_words("  one  two three ", a()), 3, "words")
    check_str(a(1), "two", "words(1)")
    check_int(str_words("   ", a()), 0, "words of blanks")
    check_str(str_word("/msg bob hi there", 1), "bob", "str_word")
    check_str(str_rest("/msg bob hi  there", 2), "hi  there", "str_rest keeps inner spacing")
    check_str(str_rest("/msg bob", 2), "", "str_rest past end")
    check_str(str_replace("a-b-c", "-", "+-"), "a+-b+-c", "replace")
    check(str_starts("#chan", "#"), "starts")
    check(str_starts_ci("NickServ", "nick"), "starts_ci")
    check_int(str_to_int("42"), 42, "to_int")
    check_int(str_to_int("4x", -1), -1, "to_int invalid -> default")
    check_int(str_to_int("-7"), -7, "to_int negative")
    check(wild_match("*!*@*.example.com", "bob!~b@host.example.com"), "wild host")
    check(wild_match("b?b*", "BOB!x@y"), "wild ? and case-insensitive")
    check(wild_match("*foo", "barfoo"), "wild suffix")
    check(wild_match("a*b*c", "axxbyyc"), "wild multi star")
    check(wild_match("a*b", "axxc") = 0, "wild mismatch")
    check(wild_match("*", ""), "star matches empty")
    check_str(base64_encode(Chr(0) & "bob" & Chr(0) & "pw"), "AGJvYgBwdw==", "base64 sasl plain")
    check_str(base64_encode("ab"), "YWI=", "base64 pad 1")
    check_str(base64_decode("AGJvYgBwdw=="), Chr(0) & "bob" & Chr(0) & "pw", "base64 decode")
    check_int(CLngInt(time_parse_iso("2026-09-10T12:34:56.500Z") * 10), 17890436965LL, "server-time parse")
    check_int(CLngInt(time_parse_iso("1970-01-01T00:00:00Z")), 0, "epoch")
    check_str(time_duration(252), "4m12s", "duration m/s")
    check_str(time_duration(3 * 86400 + 4 * 3600 + 5), "3d 4h", "duration d/h")
End Scope

' ---------------------------------------------------------------- bidi
Function bidi_visual(ByRef s As String) As String
    ' returns the visual string (mirrored where RTL)
    Dim cps() As ULong
    Dim n As Long = 0
    Dim p As Long = 0
    ReDim cps(0 To Len(s))
    While p < Len(s)
        cps(n) = utf8_decode(s, p)
        n += 1
    Wend
    Dim ord() As Long
    Dim lv() As UByte
    bidi_reorder(cps(), n, ord(), lv())
    Dim r As String
    Dim i As Long
    For i = 0 To n - 1
        Dim c As ULong = cps(ord(i))
        If lv(ord(i)) And 1 Then c = bidi_mirror(c)
        r &= utf8_encode(c)
    Next i
    Return r
End Function

t_begin("bidi")
Scope
    check_str(bidi_visual("hello world"), "hello world", "pure LTR untouched")
    check_str(bidi_visual(!"שלום"), !"םולש", "hebrew word reversed")
    check_str(bidi_visual(!"<bob> שלום עולם"), !"<bob> םלוע םולש", "RTL run after LTR prefix")
    check_str(bidi_visual(!"שלום 123 עולם"), !"םלוע 123 םולש", "number keeps LTR order inside RTL")
    check_str(bidi_visual(!"hi שלום (עולם) bye"), !"hi (םלוע) םולש bye", "brackets mirrored in RTL run")
    check_str(bidi_visual(!"abc 12 def"), "abc 12 def", "numbers in LTR text")
    check_str(bidi_visual(!"שלום, world"), !"םולש, world", "comma between R and L stays LTR")
End Scope

' ---------------------------------------------------------------- ini
t_begin("ini")
Scope
    Dim f As ini_file
    ini_set(f, "global", "nick", "bob")
    ini_set(f, "network Libera", "server", "a")
    ini_add(f, "network Libera", "server", "b")
    ini_set(f, "global", "realname", !"בוב")
    ini_set(f, "global", "nick", "alice")
    check_str(ini_get(f, "GLOBAL", "Nick"), "alice", "case-insensitive get + replace")
    Dim arr() As String
    check_int(ini_get_all(f, "network libera", "server", arr()), 2, "repeated key count")
    check_str(arr(1), "b", "repeated key order")
    Dim tmpdir As String = Environ("TMPDIR")
    If Len(tmpdir) = 0 Then tmpdir = "/tmp"
    Dim fn As String = tmpdir & "/vtirc_ng_test.ini"
    check(ini_save(f, fn), "save")
    Dim g As ini_file
    check(ini_load(g, fn), "load")
    check_str(ini_get(g, "global", "realname"), !"בוב", "utf-8 value round-trip")
    check_int(ini_get_all(g, "network Libera", "server", arr()), 2, "repeated keys round-trip")
    Dim secs() As String
    check_int(ini_sections(g, secs()), 2, "sections")
    check_str(secs(0), "global", "section order")
    ini_del_section(g, "global")
    check_str(ini_get(g, "global", "nick", "none"), "none", "delete section")
    Kill fn
End Scope

t_begin("paths")
Scope
    check_str(path_sanitize("#linux/../x"), "#linux_.._x", "sanitize separators")
    check_str(path_sanitize(".."), "__", "sanitize dots")
    check_str(path_sanitize("con"), "_con", "sanitize reserved names")
    check_str(path_sanitize(!"#עברית"), !"#עברית", "sanitize keeps unicode")
End Scope

t_begin("arabic")
Scope
    Dim cps(0 To 3) As ULong = { &h633, &h644, &h627, &h645 }     ' salam
    Dim keep() As Byte
    arabic_shape(cps(), 4, keep())
    check_int(cps(0), &hFEB3, "seen initial")
    check_int(cps(1), &hFEFC, "lam-alef final ligature")
    check(keep(2) = 0, "alef absorbed into the ligature")
    check_int(cps(3), &hFEE1, "meem isolated after alef")
    Dim c2(0 To 2) As ULong = { &h628, &h640, &h628 }             ' beh tatweel beh
    arabic_shape(c2(), 3, keep())
    check_int(c2(0), &hFE91, "beh initial before tatweel")
    check_int(c2(2), &hFE90, "beh final after tatweel")
    Dim c3(0 To 1) As ULong = { &h62F, &h628 }                     ' dal does not join forward
    arabic_shape(c3(), 2, keep())
    check_int(c3(0), &hFEA9, "dal isolated")
    check_int(c3(1), &hFE8F, "beh isolated after dal")
End Scope
