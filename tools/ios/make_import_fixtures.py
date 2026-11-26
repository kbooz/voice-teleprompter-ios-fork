#!/usr/bin/env python3
"""Generates the binary fixtures of the iOS importer tests (SuflyorImportersTests/Fixtures).

The generated files are committed; run this only when a fixture has to change. Output is deterministic (fixed zip
timestamps, reportlab invariant mode), so re-running leaves no diff.

  python3 tools/ios/make_import_fixtures.py

reportlab and pypdf are needed for the PDF fixtures only; without them the PDFs are skipped.
"""
from __future__ import annotations

import io
import sys
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "ios/Packages/SuflyorKit/Tests/SuflyorImportersTests/Fixtures"

RU = "Привет, мир! Это проверка кодировки: ёжик и щука."
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
W_STRICT = "http://purl.oclc.org/ooxml/wordprocessingml/main"
STAMP = (2020, 1, 1, 0, 0, 0)


def write(name: str, data: bytes | str) -> None:
    path = OUT / name
    path.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)


class Unseekable(io.RawIOBase):
    """Forces zipfile to write data descriptors, like Java's ZipOutputStream (what the Android app uses)."""

    def __init__(self) -> None:
        self.buf = io.BytesIO()

    def writable(self) -> bool:
        return True

    def write(self, b: bytes) -> int:  # type: ignore[override]
        return self.buf.write(b)

    def tell(self) -> int:
        return self.buf.tell()


def make_zip(entries: list[tuple[str, bytes | str]], stored_first: str | None = None, streaming: bool = False) -> bytes:
    sink = Unseekable() if streaming else io.BytesIO()
    with zipfile.ZipFile(sink, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, content in entries:
            info = zipfile.ZipInfo(name, STAMP)
            info.compress_type = zipfile.ZIP_STORED if name == stored_first else zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, content.encode("utf-8") if isinstance(content, str) else content, compresslevel=9)
    return (sink.buf if streaming else sink).getvalue()  # type: ignore[union-attr]


def docx(document: str, styles: str | None = None, extra: list[tuple[str, bytes | str]] | None = None) -> bytes:
    entries: list[tuple[str, bytes | str]] = [("word/document.xml", document)]
    if styles:
        entries.append(("word/styles.xml", styles))
    return make_zip(entries + (extra or []))


def text_fixtures() -> None:
    write("ru-utf8.txt", RU.encode("utf-8"))
    write("ru-utf8-bom.txt", b"\xef\xbb\xbf" + RU.encode("utf-8"))
    write("ru-utf16le-bom.txt", b"\xff\xfe" + RU.encode("utf-16-le"))
    write("ru-utf16le.txt", RU.encode("utf-16-le"))
    write("ru-utf16be.txt", RU.encode("utf-16-be"))
    write("ru-cp1251.txt", RU.encode("cp1251"))
    write("ru-koi8r.txt", RU.encode("koi8_r"))
    # Binary junk with a text extension: mostly control characters.
    write("control-chars.bin", bytes([1]) * 100)


def rtf_fixtures() -> None:
    write("cp1251.rtf", (
        "{\\rtf1\\ansi\\ansicpg1251{\\fonttbl{\\f0 Arial;}}\\f0 \\'cf\\'f0\\'e8\\'e2\\'e5\\'f2 "
        "{\\b \\u1084?\\u1080?\\u1088?}!\\par \\'c2\\'f2\\'ee\\'f0\\'ee\\'e9\\par}"
    ).encode("ascii"))
    # WordPad on an English Windows: \ansicpg1252, Cyrillic text in a \fcharset204 font.
    write("font-charset.rtf", (
        "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fnil\\fcharset0 Calibri;}{\\f1\\fnil\\fcharset204 Calibri;}}"
        "\\f1 \\'cf\\'f0\\'e8\\'e2\\'e5\\'f2 \\f0 caf\\'e9\\par}"
    ).encode("ascii"))
    write("absurd-fonts.rtf", (
        "{\\rtf1\\ansi{\\fonttbl{\\f99999999999\\fnil\\fcharset99999999999 Arial;}}\\f0 Hello\\par}"
    ).encode("ascii"))
    # U+1F600 as the surrogate pair D83D DE00, written the RTF way (negative 16-bit numbers).
    write("emoji.rtf", b"{\\rtf1\\ansi Hi \\u-10179?\\u-8704?!\\par}")
    write("not-rtf.rtf", b"{\\rt")


def html_fixtures() -> None:
    write("basic.html", (
        "<html><head><title>T</title><style>p{}</style></head><body><h1>Тема</h1>"
        "<p>Раз&nbsp;&laquo;два&raquo; <b>три</b></p><p>Четыре<br>пять</p></body></html>"
    ))
    write("declarations.html", (
        "<!DOCTYPE html><html><head><meta charset=utf-8><title>Мой</title>\n<body>"
        f'<p>Первый <img src="data:image/png;base64,{"A" * 6000}"> абзац.</p>'
        "<![if !supportLists]>1. <![endif]><p>Второй.</p><noscript>без закрытия<p>Третий.</p></body></html>"
    ))
    write("xhtml.html", '<?xml version="1.0" encoding="utf-8"?><html><body><p>Текст</p></body></html>')
    # "<body" mentioned inside a closed head must not end the head early.
    write("body-in-head.html", (
        "<html><head><style>/* <body> reset */ body{margin:0}</style><!-- <body> --><title>Статья</title></head>"
        "<body><p>Текст</p></body></html>"
    ))
    write("script-comment.html", "<script>alert(1)</script><p>Текст</p><!-- c -->")


def docx_fixtures() -> None:
    document = (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:document xmlns:w="{W}"><w:body>'
        '<w:p><w:pPr><w:pStyle w:val="1"/></w:pPr><w:r><w:t>Заголовок</w:t></w:r></w:p>'
        '<w:p><w:r><w:t xml:space="preserve">Обычный </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>жирный</w:t></w:r>'
        '<w:del><w:r><w:delText>удалено</w:delText></w:r></w:del><w:r><w:t xml:space="preserve"> текст</w:t></w:r></w:p>'
        '<w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>Не</w:t></w:r><w:r><w:tab/><w:t>жирный</w:t></w:r></w:p>'
        "</w:body></w:document>"
    )
    styles = (
        f'<?xml version="1.0" encoding="UTF-8"?>\n<w:styles xmlns:w="{W}">'
        '<w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style></w:styles>'
    )
    types = (
        '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/></Types>'
    )
    write("basic.docx", docx(document, styles, [("[Content_Types].xml", types)]))
    # Same text under Word's "Strict Open XML" namespace and a different prefix.
    strict = document.replace(W, W_STRICT).replace("w:", "x:").replace("xmlns:w", "xmlns:x")
    strict_styles = styles.replace(W, W_STRICT).replace("w:", "x:").replace("xmlns:w", "xmlns:x")
    write("strict.docx", docx(strict, strict_styles))

    table = (
        f'<w:document xmlns:w="{W}"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>ячейка</w:t></w:r></w:p></w:tc></w:tr>'
        "</w:tbl></w:body></w:document>"
    )
    write("tables.docx", docx(table))

    body = f'<w:document xmlns:w="{W}"><w:body><w:p><w:r><w:t>&b;</w:t></w:r></w:p></w:body></w:document>'
    dtd = '<!DOCTYPE w:document [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;">]>'
    # The DTD hides behind a long comment, past the first 4 KB.
    late = f'<?xml version="1.0" encoding="UTF-8"?><!--{"x" * 5000}-->{dtd}{body}'
    write("dtd-late.docx", docx(late))

    long_text = f'<w:document xmlns:w="{W}"><w:body><w:p><w:r><w:t>{"слово " * 120_000}</w:t></w:r></w:p></w:body></w:document>'
    write("long.docx", docx(long_text))

    def nested(depth: int) -> str:
        return (
            f'<w:document xmlns:w="{W}"><w:body>' + "<w:p>" * depth + "<w:r><w:t>глубоко</w:t></w:r>"
            + "</w:p>" * depth + "</w:body></w:document>"
        )

    # Deeper than the paragraph cap (32) but within libxml2's nesting limit, and a crafted one far beyond it.
    write("nested.docx", docx(nested(100)))
    write("nested-deep.docx", docx(nested(100_000)))

    # 40 MB of zeros in the document part (a zip bomb: tiny file, over the 32 MB part limit).
    write("zip-bomb.docx", make_zip([("word/document.xml", b"\0" * (40 * 1024 * 1024))]))
    # A zip that is neither DOCX nor ODT.
    write("unknown.zip", make_zip([("mimetype", "x")]))


def odt_fixtures() -> None:
    content = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>'
        "<text:h>Тема</text:h><text:p>Раз<text:s/>два<text:note><text:note-body><text:p>сноска</text:p>"
        "</text:note-body></text:note></text:p></office:text></office:body></office:document-content>"
    )
    write("basic.odt", make_zip(
        [("mimetype", "application/vnd.oasis.opendocument.text"), ("content.xml", content)], stored_first="mimetype"
    ))


def office_binary_fixtures() -> None:
    ole2 = bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    write("legacy.doc", ole2 + bytes(504))
    write("encrypted.docx", ole2 + bytes(100) + "EncryptedPackage".encode("utf-16-le") + bytes(300))


def archive_fixtures() -> None:
    # What the Android app writes: Markdown per script, plus the languages file; Java writes data descriptors.
    write("android-backup.zip", make_zip([
        ("Дрон для путешествий.md",
         "# Вступление\n\nСегодня **разберём**, как выбрать дрон.\n\n[пауза] И не переплатить."),
        ("Second.md", "Plain English text."),
        ("suflyor-languages.txt", "en\tSecond.md\n"),
    ], streaming=True))
    write("archive-foreign.zip", make_zip([("photo.jpg", bytes(10))]))
    write("archive-office.zip", make_zip([("word/document.xml", "<w/>"), ("notes.md", "x")]))
    write("archive-odf.zip", make_zip([("mimetype", "application/vnd.oasis.opendocument.text")]))
    write("archive-files.zip", make_zip([
        ("folder/one.md", "first"),
        ("__MACOSX/folder/._one.md", bytes(4)),
        ("picture.png", bytes(100)),
        ("two.txt", "second"),
    ]))
    # 2 MB of spaces compresses to a few KB and is longer than any script the app takes.
    write("archive-too-long.zip", make_zip([("big.md", b" " * (2 * 1024 * 1024)), ("ok.md", "fine")]))
    # 40 MB of zeros in a file that is not a script.
    write("archive-bomb.zip", make_zip([("a.md", "x"), ("junk.bin", bytes(40 * 1024 * 1024))]))


def pdf_fixtures() -> None:
    try:
        from reportlab.lib.pagesizes import A4
        from reportlab.pdfgen import canvas
    except ImportError:
        print("reportlab missing: PDF fixtures skipped", file=sys.stderr)
        return

    def make(draw) -> bytes:
        buf = io.BytesIO()
        c = canvas.Canvas(buf, pagesize=A4, invariant=1)
        draw(c)
        c.showPage()
        c.save()
        return buf.getvalue()

    def text_page(c) -> None:
        y = 780
        for line in [
            "Hello Suflyor. This line is long enough to be wrapped by a typesetter and it goes on and on-",
            "ward into the next line, which also runs almost to the end of the line width here.",
            "Short end.",
            "7",
            "A second paragraph starts here and also fills the whole width of the line, as text does.",
        ]:
            c.setFont("Helvetica", 9)
            c.drawString(40, y, line)
            y -= 14

    def scan_page(c) -> None:
        c.rect(50, 50, 400, 600, fill=1)

    text_pdf = make(text_page)
    write("text.pdf", text_pdf)
    write("scan.pdf", make(scan_page))
    try:
        from pypdf import PdfReader, PdfWriter

        writer = PdfWriter()
        for page in PdfReader(io.BytesIO(text_pdf)).pages:
            writer.add_page(page)
        writer.encrypt("secret", algorithm="RC4-128")
        out = io.BytesIO()
        writer.write(out)
        write("password.pdf", out.getvalue())
    except Exception as e:  # noqa: BLE001 - optional fixture
        print(f"password.pdf skipped: {e}", file=sys.stderr)
    write("not-a-pdf.pdf", b"%PDF-1.4\nthis is not really a pdf\n")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    text_fixtures()
    rtf_fixtures()
    html_fixtures()
    docx_fixtures()
    odt_fixtures()
    office_binary_fixtures()
    archive_fixtures()
    pdf_fixtures()
    for p in sorted(OUT.iterdir()):
        print(f"{p.stat().st_size:>9}  {p.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
