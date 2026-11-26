#!/usr/bin/env python3
"""Unit tests for convert_strings.py. Run: python3 tools/ios/test_convert_strings.py"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert_strings as cs  # noqa: E402


def segments(text: str):
    return [(text, False)]


class UnescapeTests(unittest.TestCase):
    def test_escapes(self):
        self.assertEqual(cs.android_unescape(segments(r"Couldn\'t \"quote\" \@home \?")), "Couldn't \"quote\" @home ?")
        self.assertEqual(cs.android_unescape(segments(r"a\nb\\cé")), "a\nb\\cé")

    def test_whitespace_folding_and_quotes(self):
        self.assertEqual(cs.android_unescape(segments("  one \n   two  ")), "one two")
        self.assertEqual(cs.android_unescape(segments('"  keep   this  " x')), "  keep   this   x")

    def test_cdata_is_literal(self):
        self.assertEqual(cs.android_unescape([("a ", False), (r"b\n  <c>", True)]), r"a b\n  <c>")


class FormatTests(unittest.TestCase):
    def conv(self, s):
        return cs.convert_formats(s, "t", cs.Report())

    def test_specifiers(self):
        self.assertEqual(self.conv("%s and %d"), "%@ and %lld")
        self.assertEqual(self.conv("%1$s / %2$d / %3$.1f"), "%1$@ / %2$lld / %3$.1f")
        self.assertEqual(self.conv("%1$d%% done"), "%1$lld%% done")
        self.assertEqual(self.conv("%02d:%02d"), "%02lld:%02lld")

    def test_apple_style_is_kept(self):
        self.assertEqual(self.conv("%lld words, %@"), "%lld words, %@")

    def test_unsupported_flag_warns(self):
        r = cs.Report()
        self.assertEqual(cs.convert_formats("%,d", "t", r), "%lld")
        self.assertTrue(r.warnings)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def write(self, rel: str, text: str) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def res(self, folder: str, body: str, name: str = "strings.xml") -> None:
        self.write(f"app/src/main/res/{folder}/{name}", f'<?xml version="1.0" encoding="utf-8"?><resources>{body}</resources>')

    def build(self):
        catalog, counts, report = cs.build_catalog(self.root)
        return catalog["strings"], counts, report

    def test_languages_plurals_arrays_and_non_translatable(self):
        self.res("values", """
            <string name="hello">Hello, %1$s</string>
            <string name="brand" translatable="false">Suflyor</string>
            <string name="html">Press <b>Start</b> &amp; <xliff:g xmlns:xliff="urn:x" id="a">go</xliff:g></string>
            <string name="cd"><![CDATA[Keep <this> \\n literally]]></string>
            <plurals name="words"><item quantity="one">%d word</item><item quantity="other">%d words</item></plurals>
            <string-array name="tips"><item>First</item><item>Sec\\'ond</item></string-array>
        """)
        self.res("values-ru", """
            <string name="hello">Привет, %1$s</string>
            <plurals name="words"><item quantity="one">%d слово</item><item quantity="few">%d слова</item>
              <item quantity="many">%d слов</item><item quantity="other">%d слова</item></plurals>
        """)
        self.res("values-pt-rBR", '<string name="hello">Olá, %1$s</string>')
        s, counts, report = self.build()
        self.assertEqual(report.errors, [])
        self.assertEqual(s["hello"]["localizations"]["en"]["stringUnit"]["value"], "Hello, %1$@")
        self.assertIn("pt-BR", s["hello"]["localizations"])
        self.assertNotIn("pt", s["hello"]["localizations"])
        self.assertEqual(s["brand"]["shouldTranslate"], False)
        self.assertEqual(list(s["brand"]["localizations"]), ["en"])
        self.assertEqual(s["html"]["localizations"]["en"]["stringUnit"]["value"], "Press Start & go")
        self.assertEqual(s["cd"]["localizations"]["en"]["stringUnit"]["value"], "Keep <this> \\n literally")
        plural = s["words"]["localizations"]["ru"]["variations"]["plural"]
        self.assertEqual(sorted(plural), ["few", "many", "one", "other"])
        self.assertEqual(plural["many"]["stringUnit"]["value"], "%lld слов")
        self.assertEqual(s["tips_1"]["localizations"]["en"]["stringUnit"]["value"], "Sec'ond")
        self.assertEqual(len(report.arrays), 1)
        self.assertEqual(counts["en"], 7)
        self.assertEqual(counts["ru"], 2)
        self.assertEqual(counts["pt-BR"], 1)

    def test_ios_json_merges_and_validates(self):
        self.res("values", '<string name="a">A</string>')
        self.write("ios/Suflyor/Resources/ios-strings/camera.json", json.dumps({
            "ios_camera_record": {"en": "Record %d", "pt-BR": "Gravar"},
            "ios_camera_n": {"en": {"one": "%lld take", "other": "%lld takes"}},
        }))
        s, counts, report = self.build()
        self.assertEqual(report.errors, [])
        self.assertEqual(s["ios_camera_record"]["localizations"]["en"]["stringUnit"]["value"], "Record %lld")
        self.assertIn("variations", s["ios_camera_n"]["localizations"]["en"])
        self.assertEqual(counts["(ios-only keys)"], 2)

    def test_ios_json_errors(self):
        self.res("values", '<string name="a">A</string>')
        self.write("ios/Suflyor/Resources/ios-strings/x.json", json.dumps({
            "a": {"en": "clashes with Android"},
            "ios_x_noen": {"ru": "нет en"},
        }))
        _, _, report = self.build()
        self.assertEqual(len(report.errors), 2)

    def test_deterministic_and_check_mode(self):
        self.res("values", '<string name="b">B</string><string name="a">A</string>')
        self.assertEqual(cs.main(["--root", str(self.root), "--check"]), 1)  # no catalog yet
        self.assertEqual(cs.main(["--root", str(self.root)]), 0)
        first = (self.root / cs.CATALOG_PATH).read_text(encoding="utf-8")
        self.assertEqual(cs.main(["--root", str(self.root)]), 0)
        self.assertEqual(first, (self.root / cs.CATALOG_PATH).read_text(encoding="utf-8"))
        self.assertLess(first.index('"a"'), first.index('"b"'))
        self.assertEqual(cs.main(["--root", str(self.root), "--check"]), 0)
        self.res("values", '<string name="b">B2</string><string name="a">A</string>')
        self.assertEqual(cs.main(["--root", str(self.root), "--check"]), 1)

    def test_missing_english_is_an_error(self):
        self.res("values", '<string name="a">A</string>')
        self.res("values-ru", '<string name="only_ru">Да</string>')
        _, _, report = self.build()
        self.assertTrue(any("only_ru" in e for e in report.errors))


if __name__ == "__main__":
    unittest.main()
