#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
"""Adds translator comments to an Xcode string catalog without touching anything else.

    scripts/xcstrings-comments.py <comments> <catalog.xcstrings>
    scripts/xcstrings-comments.py --check <catalog.xcstrings>

<comments> is a JSON file {"key": "comment", …} or another version of the catalog (for example the same file from
another branch: `git show <branch>:<path> > /tmp/other.xcstrings`); its comments are copied to the keys of the catalog
that have none. Keys, values, order and Xcode's formatting stay exactly as they are: only `"comment"` lines are
inserted, so the diff is easy to review and to merge. --check writes nothing and lists the keys
without a comment (exit code 1 when there are any).
"""
import json
import re
import sys

KEY_LINE = re.compile(r'^    ("(?:[^"\\]|\\.)*") : \{$')
# An empty entry written on one line (`"key" : {},`), as tools other than Xcode and merges leave it.
EMPTY_KEY_LINE = re.compile(r'^    ("(?:[^"\\]|\\.)*") : \{\}(,?)$')


def load_comments(path):
    with open(path, encoding="utf-8") as file:
        data = json.load(file)
    if isinstance(data.get("strings"), dict):
        return {key: entry["comment"] for key, entry in data["strings"].items() if entry.get("comment")}
    return data


def quoted(text):
    """A JSON string the way Xcode writes it."""
    return json.dumps(text, ensure_ascii=False)


def main():
    arguments = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    if check and len(arguments) == 1:
        arguments.insert(0, None)
    if len(arguments) != 2:
        sys.exit(__doc__)
    comments = load_comments(arguments[0]) if arguments[0] else {}
    with open(arguments[1], encoding="utf-8") as file:
        text = file.read()
    strings = json.loads(text)["strings"]
    lines = text.split("\n")
    output = []
    added = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        empty = EMPTY_KEY_LINE.match(line)
        if empty:
            key = json.loads(empty.group(1))
            if key in strings and not strings[key].get("comment") and comments.get(key):
                # Written the way Xcode writes an entry that only has a comment.
                output.append("    " + empty.group(1) + " : {")
                output.append('      "comment" : ' + quoted(comments[key]))
                output.append("    }" + empty.group(2))
                added += 1
                index += 1
                continue
        output.append(line)
        match = KEY_LINE.match(line)
        if match:
            key = json.loads(match.group(1))
            entry = strings.get(key)
            if entry is not None and not entry.get("comment") and comments.get(key):
                comment = '      "comment" : ' + quoted(comments[key])
                if lines[index + 1] == "" and lines[index + 2].startswith("    }"):
                    # An empty entry: Xcode writes it as a blank line between the braces.
                    output.append(comment)
                    index += 1
                else:
                    output.append(comment + ",")
                added += 1
        index += 1
    result = "\n".join(output)
    after = json.loads(result)
    before = json.loads(text)
    for key, entry in after["strings"].items():
        entry_before = dict(before["strings"][key])
        entry_after = dict(entry)
        entry_after.pop("comment", None) if not entry_before.get("comment") else None
        if entry_after != entry_before:
            sys.exit(f"refusing to write: entry {key!r} would change beyond its comment")
    missing = [key for key, entry in after["strings"].items() if not entry.get("comment")]
    if not check:
        with open(arguments[1], "w", encoding="utf-8") as file:
            file.write(result)
    print(f"{arguments[1]}: {added} comments {'would be ' if check else ''}added, {len(missing)} keys without a comment")
    for key in missing:
        print(f"  no comment: {key!r}")
    if check and missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
