#!/usr/bin/env python3
"""Regenerates the torrent fixtures for QuickPeekFormatsTests and prints their info hashes.

The bencode writer here is independent of QuickPeek's Swift parser, so the tests compare the
parser against a second implementation.
"""
import hashlib
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "Tests/QuickPeekFormatsTests/Fixtures"


def bencode(value):
    if isinstance(value, bool):
        raise TypeError("bencode has no booleans")
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return b"%d:" % len(value) + value
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in value.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(type(value))


def write(name, torrent):
    data = bencode(torrent)
    (OUT / name).write_bytes(data)
    info = bencode(torrent["info"])
    print(f"{name}: {len(data)} bytes, info hash {hashlib.sha1(info).hexdigest()}")


OUT.mkdir(parents=True, exist_ok=True)

write("multi.torrent", {
    "announce": "https://tracker.example.org/announce",
    "announce-list": [["https://tracker.example.org/announce"], ["udp://backup.example.net:6969/announce"]],
    "comment": "QuickPeek test torrent",
    "created by": "QuickPeek fixtures",
    "creation date": 1776000000,
    "url-list": ["https://mirror.example.com/files/"],
    "info": {
        "name": "Example Dataset",
        "piece length": 262144,
        "pieces": bytes(range(20)) * 3,
        "files": [
            {"length": 5_000_000_000, "path": ["video", "lecture-01.mkv"]},
            {"length": 1_234, "path": ["README.txt"]},
            {"length": 0, "path": ["video", "subs", "empty.srt"]},
        ],
    },
})

write("single.torrent", {
    "announce": "udp://tracker.example.org:1337/announce",
    "info": {
        "name": "ubuntu-26.04-desktop-amd64.iso",
        "length": 6_123_456_789,
        "piece length": 4_194_304,
        "pieces": b"\xff" * 40,
    },
})

write("private-utf8.torrent", {
    "announce": "https://private.example.org/announce?passkey=secret",
    "info": {
        "name": "Документы — 2026",
        "private": 1,
        "piece length": 16384,
        "pieces": b"\x01" * 20,
        "files": [{"length": 42, "path": ["отчёт.pdf"]}],
    },
})

# --- Office Open XML documents with known properties (for QuickPeekInfo) ---
import zipfile

CORE = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
 xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"
 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<dc:title>{title}</dc:title><dc:creator>Ada Lovelace</dc:creator><cp:lastModifiedBy>Charles Babbage</cp:lastModifiedBy>
<cp:revision>7</cp:revision>
<dcterms:created xsi:type="dcterms:W3CDTF">2026-01-02T15:30:00Z</dcterms:created>
<dcterms:modified xsi:type="dcterms:W3CDTF">2026-02-03T10:00:00Z</dcterms:modified>
</cp:coreProperties>"""


def office(name, title, app_fields, extra):
    app = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
           '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
           + "".join(f"<{k}>{v}</{k}>" for k, v in app_fields.items()) + "</Properties>")
    with zipfile.ZipFile(OUT / name, "w", zipfile.ZIP_DEFLATED) as archive:
        for info_name, content in [("[Content_Types].xml", "<Types/>"), ("docProps/core.xml", CORE.format(title=title)),
                                   ("docProps/app.xml", app)] + extra:
            entry = zipfile.ZipInfo(info_name, date_time=(2026, 1, 2, 15, 30, 0))
            archive.writestr(entry, content)
    print(f"{name}: {(OUT / name).stat().st_size} bytes")


office("report.docx", "Annual Report", {"Application": "Microsoft Office Word", "Pages": 3, "Words": 1200, "Characters": 7000},
       [("word/document.xml", "<w:document/>")])
office("budget.xlsx", "Budget 2026", {"Application": "Microsoft Excel"},
       [("xl/workbook.xml", '<workbook><sheets><sheet name="Income"/><sheet name="Expenses"/><sheet name="Summary"/></sheets></workbook>')])
office("deck.pptx", "Launch Plan", {"Application": "Microsoft Office PowerPoint", "Slides": 12, "Notes": 4},
       [("ppt/presentation.xml", "<p:presentation/>")])
