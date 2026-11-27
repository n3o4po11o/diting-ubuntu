#!/usr/bin/env python3
"""Write po/cellular-settings.pot from the sources.

    python3 po/update-pot.py            # from the package directory

Every string the user sees is written `t!("...")`, or `t!("... {}", x)`
with the first argument the message id. This reads those literals (not
those of comments) into the template. The translations are then brought up
to date with msgmerge:

    msgmerge -U po/zh_CN.po po/cellular-settings.pot

The template has no date, so that regenerating it changes nothing when no
string changed.
"""

import pathlib
import sys

PACKAGE = "cellular-settings"
VERSION = "0.1"


def unescape(body):
    """The value of a Rust string literal's body, between the quotes."""
    out = []
    i = 0
    while i < len(body):
        char = body[i]
        if char != "\\":
            out.append(char)
            i += 1
            continue
        nxt = body[i + 1] if i + 1 < len(body) else ""
        if nxt == "\n":
            # a line continued: the newline and the whitespace after it go
            i += 1
            while i < len(body) and body[i] in " \t\r\n":
                i += 1
            continue
        simple = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "\0": "\0"}
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
        elif nxt == "u" and body[i + 2 : i + 3] == "{":
            end = body.index("}", i)
            out.append(chr(int(body[i + 3 : end], 16)))
            i = end + 1
        else:
            raise SystemExit(f"unknown escape \\{nxt}")
    return "".join(out)


def message_ids(text):
    """(line, msgid) of every `t!("...")`, in the order of the text."""
    found = []
    i = 0
    line = 1
    while i < len(text):
        char = text[i]
        if char == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif char == '"':
            # a string literal that is not a message: nothing to read in it
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        else:
            literal = text.startswith("t!(", i) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_"))
            if literal:
                j = i + 3
                while j < len(text) and text[j] in " \t\r\n":
                    j += 1
                if text[j] == '"':
                    start = j + 1
                    end = start
                    while text[end] != '"':
                        end += 2 if text[end] == "\\" else 1
                    found.append((line, unescape(text[start:end])))
                    i = end + 1
                    continue
            i += 1
    return found


def quoted(text):
    """A msgid as a .po string, continued on its newlines."""
    text = text.replace("\\", "\\\\").replace('"', '\\"')
    if "\n" not in text:
        return f'"{text}"'
    lines = text.split("\n")
    return "\n".join(f'"{part}\\n"' for part in lines[:-1]) + f'\n"{lines[-1]}"'


def main():
    here = pathlib.Path(__file__).resolve().parent
    package = here.parent
    entries = {}
    for source in sorted((package / "src").rglob("*.rs")):
        for line, msgid in message_ids(source.read_text(encoding="utf-8")):
            entries.setdefault(msgid, []).append(f"{source.relative_to(package)}:{line}")
    out = [
        "# Cellular Settings.",
        "# This file is distributed under the same license as the cellular-settings package.",
        "#",
        "#, fuzzy",
        "msgid \"\"",
        "msgstr \"\"",
        f'"Project-Id-Version: {PACKAGE} {VERSION}\\n"',
        '"Report-Msgid-Bugs-To: \\n"',
        '"POT-Creation-Date: \\n"',
        '"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\\n"',
        '"Last-Translator: Automatically generated\\n"',
        '"Language-Team: none\\n"',
        '"Language: \\n"',
        '"MIME-Version: 1.0\\n"',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        '"Content-Transfer-Encoding: 8bit\\n"',
        "",
    ]
    for msgid, where in entries.items():
        out += [f"#: {" ".join(where)}", f"msgid {quoted(msgid)}", "msgstr \"\"", ""]
    (here / f"{PACKAGE}.pot").write_text("\n".join(out), encoding="utf-8")
    print(f"{len(entries)} messages in {here / (PACKAGE + '.pot')}")


if __name__ == "__main__":
    sys.exit(main())
