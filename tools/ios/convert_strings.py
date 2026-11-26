#!/usr/bin/env python3
"""Builds the iOS String Catalog from the Android string resources and the iOS-only JSON files.

Inputs
  app/src/main/res/values/strings*.xml          English (the catalog's source language)
  app/src/main/res/values-<lang>[-r<REGION>]/   ru, tr, pt-rBR (any other language directory is converted too)
  ios/Suflyor/Resources/ios-strings/*.json      {"ios_<wp>_<name>": {"en": "...", "pt-BR": "..."}} from the iOS work packages
Output
  ios/Suflyor/Resources/Localizable.xcstrings   deterministic (sorted keys, stable formatting)

  convert_strings.py           write the catalog
  convert_strings.py --check   exit 1 when the committed catalog is not what the inputs produce (for CI)

Android -> Apple conversions: resource escapes (\\' \\" \\n \\@ \\? \\uXXXX), quoting and whitespace folding, XML
entities, CDATA (kept literally), inline markup (tags dropped, text kept), format specifiers (%s -> %@, %d -> %lld),
<plurals> -> plural variations, <string-array> -> key_0, key_1, ..., translatable="false" -> shouldTranslate false,
pt-rBR -> pt-BR.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
RES_DIR = Path("app/src/main/res")
IOS_STRINGS_DIR = Path("ios/Suflyor/Resources/ios-strings")
CATALOG_PATH = Path("ios/Suflyor/Resources/Localizable.xcstrings")

SOURCE_LANGUAGE = "en"
PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")

VALUES_DIR = re.compile(r"^values(?:-([a-z]{2,3})(?:-r([A-Z]{2}))?)?$")

# %[index$][flags][width][.precision][length]conversion; "%%" and "%n" are matched by the conversion alternatives.
FORMAT = re.compile(r"%(?:(\d+)\$)?([-#+ 0,(]*)(\d+)?(?:\.(\d+))?(ll|l|h|hh|q|z|j|t)?([a-zA-Z@%])")

CDATA = re.compile(r"<!\[CDATA\[(.*?)\]\]>", re.DOTALL)
CDATA_MARK = re.compile("(\\d+)")


class Report:
    def __init__(self) -> None:
        self.arrays: list[str] = []
        self.untranslatable: list[str] = []
        self.markup: list[str] = []
        self.warnings: list[str] = []
        self.errors: list[str] = []

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def error(self, message: str) -> None:
        self.errors.append(message)


# ---------------------------------------------------------------------------------------------------------------
# Android text -> plain text

def android_unescape(segments: list[tuple[str, bool]]) -> str:
    """aapt-style processing of one string: segments are (text, literal) pairs; CDATA ones are literal."""
    out: list[str] = []
    in_quotes = False
    pending_space = False
    for text, literal in segments:
        if literal:
            if pending_space and out:
                out.append(" ")
            pending_space = False
            out.append(text)
            continue
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\\" and i + 1 < len(text):
                nxt = text[i + 1]
                i += 2
                if pending_space and out:
                    out.append(" ")
                pending_space = False
                if nxt == "n":
                    out.append("\n")
                elif nxt == "t":
                    out.append("\t")
                elif nxt == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", text[i:i + 4]):
                    out.append(chr(int(text[i:i + 4], 16)))
                    i += 4
                else:  # \' \" \@ \? \\ and any other escaped character stand for themselves
                    out.append(nxt)
                continue
            i += 1
            if ch == '"':
                in_quotes = not in_quotes
                continue
            if ch.isspace() and not in_quotes:
                pending_space = True
                continue
            if pending_space and out:
                out.append(" ")
            pending_space = False
            out.append(ch)
    return "".join(out)


def element_text(elem: ET.Element, report: Report, where: str) -> str:
    """Flattens inline markup (<b>, <i>, <xliff:g>...) to its text and unescapes like the resource compiler."""
    if len(elem):
        report.markup.append(where)
    parts = "".join(elem.itertext())
    segments: list[tuple[str, bool]] = []
    pos = 0
    for m in CDATA_MARK.finditer(parts):
        segments.append((parts[pos:m.start()], False))
        segments.append((CDATA_STORE[int(m.group(1))], True))
        pos = m.end()
    segments.append((parts[pos:], False))
    return android_unescape(segments)


CDATA_STORE: list[str] = []


def parse_xml(path: Path) -> ET.Element:
    raw = path.read_text(encoding="utf-8")

    def stash(m: re.Match[str]) -> str:
        CDATA_STORE.append(m.group(1))
        return f"{len(CDATA_STORE) - 1}"

    return ET.fromstring(CDATA.sub(stash, raw))


# ---------------------------------------------------------------------------------------------------------------
# Format specifiers

def convert_formats(text: str, where: str, report: Report) -> str:
    """Android/Java specifiers -> Apple ones. Specifiers that already carry a length modifier (%lld) are kept."""

    def sub(m: re.Match[str]) -> str:
        index, flags, width, precision, length, conv = m.groups()
        if conv == "%":
            return m.group(0)
        if length:  # already Apple style (iOS-only strings)
            return m.group(0)
        if conv == "n":
            return "\n"
        if "," in flags or "(" in flags:
            report.warn(f"{where}: flag in {m.group(0)!r} is not supported by Apple formats and was dropped")
            flags = flags.replace(",", "").replace("(", "")
        if conv in "sS":
            apple = "@"
        elif conv in "di":
            apple = "lld"
        elif conv in "xX":
            apple = "ll" + conv
        elif conv == "c":
            apple = "C"
        elif conv in "fFeEgGaA@":
            apple = conv
        elif conv in "oOuU":
            apple = "ll" + conv
        else:
            report.warn(f"{where}: unknown specifier {m.group(0)!r} kept as it is")
            return m.group(0)
        prefix = f"{index}$" if index else ""
        prec = f".{precision}" if precision is not None else ""
        return f"%{prefix}{flags}{width or ''}{prec}{apple}"

    return FORMAT.sub(sub, text)


# ---------------------------------------------------------------------------------------------------------------
# Catalog model: {key: {"translatable": bool, "langs": {lang: str | {category: str}}}}

Entry = dict[str, Any]


def lang_of_dir(name: str) -> str | None:
    m = VALUES_DIR.match(name)
    if not m:
        return None
    lang, region = m.group(1), m.group(2)
    if lang is None:
        return SOURCE_LANGUAGE
    return f"{lang}-{region}" if region else lang


def add_value(entries: dict[str, Entry], key: str, lang: str, value: Any, translatable: bool, where: str,
              report: Report) -> None:
    entry = entries.setdefault(key, {"translatable": True, "langs": {}})
    if lang in entry["langs"]:
        report.error(f"{where}: duplicate key {key!r} for language {lang}")
        return
    entry["langs"][lang] = value
    if not translatable:
        entry["translatable"] = False


def read_android(root: Path, report: Report) -> dict[str, Entry]:
    entries: dict[str, Entry] = {}
    res = root / RES_DIR
    for d in sorted(p for p in res.iterdir() if p.is_dir() and p.name.startswith("values")):
        lang = lang_of_dir(d.name)
        if lang is None:
            report.warn(f"{d.name}: not a language directory, skipped")
            continue
        for path in sorted(d.glob("strings*.xml")):
            where_file = f"{d.name}/{path.name}"
            for elem in parse_xml(path):
                name = elem.get("name")
                translatable = elem.get("translatable") != "false"
                where = f"{where_file}:{name}"
                if not name:
                    continue
                if elem.tag == "string":
                    text = convert_formats(element_text(elem, report, where), where, report)
                    add_value(entries, name, lang, text, translatable, where, report)
                elif elem.tag == "plurals":
                    forms: dict[str, str] = {}
                    for item in elem.findall("item"):
                        q = item.get("quantity", "other")
                        if q not in PLURAL_CATEGORIES:
                            report.error(f"{where}: unknown plural quantity {q!r}")
                            continue
                        forms[q] = convert_formats(element_text(item, report, where), where, report)
                    if "other" not in forms:
                        report.error(f"{where}: <plurals> without an 'other' item")
                        continue
                    add_value(entries, name, lang, forms, translatable, where, report)
                elif elem.tag == "string-array":
                    for n, item in enumerate(elem.findall("item")):
                        text = convert_formats(element_text(item, report, where), where, report)
                        add_value(entries, f"{name}_{n}", lang, text, translatable, where, report)
                    report.arrays.append(f"{lang}:{name} ({len(elem.findall('item'))} items) -> {name}_0..")
                else:
                    report.warn(f"{where}: <{elem.tag}> is not a string resource, skipped")
    return entries


def read_ios_strings(root: Path, entries: dict[str, Entry], report: Report) -> int:
    folder = root / IOS_STRINGS_DIR
    count = 0
    if not folder.is_dir():
        return count
    for path in sorted(folder.glob("*.json")):
        where_file = f"ios-strings/{path.name}"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as e:
            report.error(f"{where_file}: invalid JSON ({e})")
            continue
        if not isinstance(data, dict):
            report.error(f"{where_file}: top level must be an object")
            continue
        for key, langs in data.items():
            where = f"{where_file}:{key}"
            if not key.startswith("ios_"):
                report.warn(f"{where}: iOS-only keys should start with 'ios_'")
            if key in entries:
                report.error(f"{where}: key already defined by the Android resources or another JSON file")
                continue
            if not isinstance(langs, dict) or SOURCE_LANGUAGE not in langs:
                report.error(f"{where}: needs an object with at least an 'en' value")
                continue
            for lang, value in langs.items():
                if isinstance(value, dict):
                    if "other" not in value or any(c not in PLURAL_CATEGORIES for c in value):
                        report.error(f"{where}: plural object for {lang} needs valid categories and 'other'")
                        continue
                    value = {c: convert_formats(v, where, report) for c, v in value.items()}
                elif isinstance(value, str):
                    value = convert_formats(value, where, report)
                else:
                    report.error(f"{where}: value for {lang} must be a string or a plural object")
                    continue
                add_value(entries, key, lang, value, True, where, report)
            count += 1
    return count


def unit(value: str) -> dict[str, Any]:
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value: str | dict[str, str]) -> dict[str, Any]:
    if isinstance(value, str):
        return unit(value)
    return {"variations": {"plural": {c: unit(value[c]) for c in PLURAL_CATEGORIES if c in value}}}


def build_catalog(root: Path) -> tuple[dict[str, Any], dict[str, int], Report]:
    report = Report()
    del CDATA_STORE[:]
    entries = read_android(root, report)
    ios_keys = read_ios_strings(root, entries, report)
    strings: dict[str, Any] = {}
    langs: set[str] = set()
    for key, entry in entries.items():
        if SOURCE_LANGUAGE not in entry["langs"]:
            report.error(f"{key}: missing the English (source) value")
            continue
        item: dict[str, Any] = {"extractionState": "manual"}
        if not entry["translatable"]:
            item["shouldTranslate"] = False
            report.untranslatable.append(key)
            entry["langs"] = {SOURCE_LANGUAGE: entry["langs"][SOURCE_LANGUAGE]}
        item["localizations"] = {lang: localization(v) for lang, v in entry["langs"].items()}
        langs.update(entry["langs"])
        strings[key] = item
    catalog = {"sourceLanguage": SOURCE_LANGUAGE, "strings": strings, "version": "1.0"}
    counts = {lang: sum(1 for s in strings.values() if lang in s["localizations"]) for lang in sorted(langs)}
    counts["(keys)"] = len(strings)
    counts["(ios-only keys)"] = ios_keys
    return catalog, counts, report


def render(catalog: dict[str, Any]) -> str:
    # Xcode writes `"key" : value`; the same spacing keeps diffs small when Xcode re-saves the file.
    return json.dumps(catalog, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : ")) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="fail if the committed catalog is stale")
    ap.add_argument("--root", type=Path, default=ROOT, help="repository root (tests use a temporary one)")
    args = ap.parse_args(argv)

    catalog, counts, report = build_catalog(args.root)
    for w in report.warnings:
        print(f"warning: {w}", file=sys.stderr)
    for e in report.errors:
        print(f"error: {e}", file=sys.stderr)
    if report.errors:
        return 1

    text = render(catalog)
    target = args.root / CATALOG_PATH
    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else None
        if current != text:
            print(f"{CATALOG_PATH} is stale; run: python3 tools/ios/convert_strings.py", file=sys.stderr)
            return 1
        print(f"ok: {CATALOG_PATH} is up to date")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print(f"wrote {CATALOG_PATH}")
    for lang, n in counts.items():
        print(f"  {lang}: {n}")
    if report.untranslatable:
        print(f"  translatable=false: {len(report.untranslatable)} keys (English only, shouldTranslate=false)")
    for a in report.arrays:
        print(f"  string-array: {a}")
    if report.markup:
        print(f"  inline markup flattened to text in {len(report.markup)} strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
