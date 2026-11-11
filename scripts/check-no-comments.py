#!/usr/bin/env python3
import bisect
import io
import os
import re
import subprocess
import sys
import tokenize

SWIFT_TOOLS_PATH = "QudelixBar/Package.swift"
SWIFT_TOOLS_PREFIX = "// swift-tools-version:"
HEREDOC_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SHELL_WORD_START = " \t\r\n;&|()`"


def line_index(text):
    return [m.start() for m in re.finditer("\n", text)]


def line_of(starts, offset):
    return bisect.bisect_left(starts, offset) + 1


def swift_comments(s):
    n = len(s)
    starts = line_index(s)
    found = []

    def report(a, b):
        found.append((line_of(starts, a), s[a:b].split("\n")[0]))

    def block(i):
        start = i
        i += 2
        depth = 1
        while i < n and depth:
            if s.startswith("/*", i):
                depth += 1
                i += 2
            elif s.startswith("*/", i):
                depth -= 1
                i += 2
            else:
                i += 1
        report(start, i)
        return i

    def regex(i, hashes):
        end = s.find("/" + "#" * hashes, i)
        return n if end < 0 else end + 1 + hashes

    def string(i, hashes):
        multi = s.startswith('"""', i)
        i += 3 if multi else 1
        closer = ('"""' if multi else '"') + "#" * hashes
        while i < n:
            c = s[i]
            if c == "\\" and s.startswith("#" * hashes, i + 1):
                j = i + 1 + hashes
                if j < n and s[j] == "(":
                    i = code(j + 1, True)
                else:
                    i = j + 1
                continue
            if s.startswith(closer, i):
                return i + len(closer)
            if not multi and c == "\n":
                return i
            i += 1
        return i

    def code(i, interp):
        depth = 0
        while i < n:
            c = s[i]
            if c == "/" and i + 1 < n:
                d = s[i + 1]
                if d == "/":
                    j = s.find("\n", i)
                    j = n if j < 0 else j
                    report(i, j)
                    i = j
                    continue
                if d == "*":
                    i = block(i)
                    continue
            if c == '"':
                i = string(i, 0)
                continue
            if c == "#":
                j = i
                while j < n and s[j] == "#":
                    j += 1
                if j < n and s[j] == '"':
                    i = string(j, j - i)
                    continue
                if j < n and s[j] == "/":
                    i = regex(j + 1, j - i)
                    continue
                i = j
                continue
            if interp:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        return i + 1
                    depth -= 1
            i += 1
        return i

    code(0, False)
    return found


def c_comments(s):
    n = len(s)
    starts = line_index(s)
    found = []
    i = 0
    while i < n:
        c = s[i]
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            j = s.find("\n", i)
            j = n if j < 0 else j
            found.append((line_of(starts, i), s[i:j]))
            i = j
        elif c == "/" and i + 1 < n and s[i + 1] == "*":
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
            found.append((line_of(starts, i), s[i:j].split("\n")[0]))
            i = j
        elif c == '"' or c == "'":
            i += 1
            while i < n and s[i] != c and s[i] != "\n":
                i += 2 if s[i] == "\\" else 1
            i += 1
        else:
            i += 1
    return found


def shell_comments(s):
    n = len(s)
    starts = line_index(s)
    found = []
    pending = []

    def consume_heredocs(i):
        for word, strip in pending:
            while i < n:
                j = s.find("\n", i)
                j = n if j < 0 else j
                row = s[i:j]
                i = min(j + 1, n)
                if (row.lstrip("\t") if strip else row) == word:
                    break
        del pending[:]
        return i

    def single(i):
        j = s.find("'", i)
        return n if j < 0 else j + 1

    def ansi(i):
        while i < n and s[i] != "'":
            i += 2 if s[i] == "\\" else 1
        return i + 1

    def double(i):
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
            elif c == '"':
                return i + 1
            elif c == "$" and s.startswith("(", i + 1):
                i = code(i + 2, ")", False)
            elif c == "$" and s.startswith("{", i + 1):
                i = code(i + 2, "}", False)
            elif c == "`":
                i = code(i + 1, "`", False)
            else:
                i += 1
        return i

    def heredoc(i):
        j = i + 2
        strip = j < n and s[j] == "-"
        if strip:
            j += 1
        while j < n and s[j] in " \t":
            j += 1
        if j < n and s[j] in "'\"":
            q = s[j]
            end = s.find(q, j + 1)
            if end < 0:
                return None
            pending.append((s[j + 1:end], strip))
            return end + 1
        m = HEREDOC_WORD.match(s, j)
        if not m:
            return None
        pending.append((m.group(0), strip))
        return m.end()

    def code(i, closer, arith):
        depth = 0
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
            elif c == "'":
                i = single(i + 1)
            elif c == '"':
                i = double(i + 1)
            elif c == "`":
                if closer == "`":
                    return i + 1
                i = code(i + 1, "`", False)
            elif c == "$":
                nxt = s[i + 1] if i + 1 < n else ""
                if nxt == "'":
                    i = ansi(i + 2)
                elif nxt == "(" and s.startswith("(", i + 2):
                    i = code(i + 3, ")", True)
                    if i < n and s[i] == ")":
                        i += 1
                elif nxt == "(":
                    i = code(i + 2, ")", False)
                elif nxt == "{":
                    i = code(i + 2, "}", False)
                else:
                    i += 2
            elif c == "#":
                if i == 0 or s[i - 1] in SHELL_WORD_START:
                    j = s.find("\n", i)
                    j = n if j < 0 else j
                    found.append((line_of(starts, i), s[i:j]))
                    i = j
                else:
                    i += 1
            elif c == "<" and not arith and s.startswith("<<", i) and not s.startswith("<<<", i):
                r = heredoc(i)
                i = i + 2 if r is None else r
            elif c == "\n":
                i += 1
                if pending:
                    i = consume_heredocs(i)
            elif closer == ")" and c == "(":
                depth += 1
                i += 1
            elif c == closer:
                if depth == 0:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return i

    code(0, None, False)
    return found


def yaml_comments(s):
    found = []
    for number, row in enumerate(s.split("\n"), 1):
        quote = None
        i = 0
        while i < len(row):
            c = row[i]
            if quote == "'":
                if c == "'":
                    quote = None
            elif quote == '"':
                if c == "\\":
                    i += 1
                elif c == '"':
                    quote = None
            elif c in "'\"" and (i == 0 or row[i - 1] in " \t[{,"):
                quote = c
            elif c == "#" and (i == 0 or row[i - 1] in " \t"):
                found.append((number, row[i:]))
                break
            i += 1
    return found


def line_prefix_comments(s):
    return [
        (number, row.strip())
        for number, row in enumerate(s.split("\n"), 1)
        if row.lstrip().startswith("#")
    ]


def docker_comments(s):
    rows = s.split("\n")
    found = {}
    i = 0
    while i < len(rows):
        stripped = rows[i].strip()
        if stripped.startswith("#"):
            found[i + 1] = stripped
            i += 1
            continue
        m = re.match(r"\s*RUN\s+(.*)", rows[i], re.I)
        if m:
            start = i
            parts = [m.group(1)]
            while rows[i].rstrip().endswith("\\") and i + 1 < len(rows):
                i += 1
                parts.append(rows[i])
            for number, text in shell_comments("\n".join(parts)):
                found.setdefault(start + number, text)
        i += 1
    return sorted(found.items())


def python_comments(s):
    found = []
    for tok in tokenize.generate_tokens(io.StringIO(s).readline):
        if tok.type == tokenize.COMMENT:
            found.append((tok.start[0], tok.string))
    return found


def xml_comments(s):
    starts = line_index(s)
    found = []
    i = 0
    while True:
        cdata = s.find("<![CDATA[", i)
        comment = s.find("<!--", i)
        if comment < 0:
            break
        if 0 <= cdata < comment:
            end = s.find("]]>", cdata)
            if end < 0:
                break
            i = end + 3
            continue
        end = s.find("-->", comment)
        end = len(s) if end < 0 else end + 3
        found.append((line_of(starts, comment), s[comment:end].split("\n")[0]))
        i = end
    return found


LEXERS = {
    "swift": swift_comments,
    "c": c_comments,
    "shell": shell_comments,
    "yaml": yaml_comments,
    "docker": docker_comments,
    "python": python_comments,
    "linecfg": line_prefix_comments,
    "xml": xml_comments,
}


def kind_of(path, head):
    base = os.path.basename(path)
    ext = os.path.splitext(base)[1].lower()
    if base == "Dockerfile" or base.startswith("Dockerfile."):
        return "docker"
    if base == ".gitignore" or ext in (".rules", ".desktop"):
        return "linecfg"
    if ext == ".swift":
        return "swift"
    if ext in (".c", ".h", ".modulemap"):
        return "c"
    if ext == ".py":
        return "python"
    if ext == ".sh":
        return "shell"
    if ext in (".yml", ".yaml"):
        return "yaml"
    if ext in (".xml", ".svg"):
        return "xml"
    if not ext and head.startswith("#!"):
        first = head.split("\n", 1)[0]
        if re.search(r"\b(ba)?sh\b", first):
            return "shell"
    return None


def analyze(kind, text, path=""):
    found = LEXERS[kind](text)
    kept = []
    for number, comment in found:
        if number == 1 and kind in ("shell", "python") and comment.startswith("#!"):
            continue
        if (
            number == 1
            and kind == "swift"
            and path == SWIFT_TOOLS_PATH
            and comment.startswith(SWIFT_TOOLS_PREFIX)
        ):
            continue
        kept.append((number, comment))
    return kept


SELF_TESTS = [
    ("swift", "let a = 1\n// x\nlet b = 2\n", [2]),
    ("swift", "let a = 1 // x\n", [1]),
    ("swift", "/// doc\nfunc f() {}\n", [1]),
    ("swift", "let a = 1\n/* x\ny */\nlet b = 2\n", [2]),
    ("swift", "/* a /* nested */ still */ let a = 1\n// real\n", [1, 2]),
    ("swift", "/* a /* nested */ still */\nlet a = 1 // real\n", [1, 2]),
    ("swift", 'let u = "https://example.com"\n', []),
    ("swift", 'let m = "*/*"\n', []),
    ("swift", 'let s = "a // b"\n', []),
    ("swift", 'let s = "a /* b */ c"\n', []),
    ("swift", 'let s = "q\\"//"\n', []),
    ("swift", 'let s = "\\("x//y")"\n', []),
    ("swift", 'let s = "\\(f(")//", 2)) // c"\nlet t = 1 // c\n', [2]),
    ("swift", 'let s = "\\(a ?? "\\(b)//")"\nlet t = 1 // c\n', [2]),
    ("swift", 'let r = #"\\d+//"#\n', []),
    ("swift", 'let r = ##"a "# // b"##\n', []),
    ("swift", 'let r = #"a \\#(x) //"#\n', []),
    ("swift", 'let r = #"""\n// text\n"""#\n', []),
    ("swift", 'let t = """\n// text\n/* no */\n"""\n// yes\n', [5]),
    ("swift", "let re = #/a+\\d//#\nlet x = 1 // c\n", [2]),
    ("swift", "#if os(Linux)\nlet a = 1\n#endif\nif #available(macOS 13, *) {}\n", []),
    ("swift", "let k = #selector(f)\n", []),
    ("c", "int a;\n// x\n", [2]),
    ("c", "int a; // x\n", [1]),
    ("c", "int a;\n/* x\ny */\n", [2]),
    ("c", 'char *u = "http://x/*y*/";\n#include <a.h>\n#define A 1\n', []),
    ("c", "char c = '\"'; // x\n", [1]),
    ("c", "char c = '\\'';\nchar d = '/'; /* z */\n", [2]),
    ("python", "x = 1\n# c\n", [2]),
    ("python", "x = 1  # c\n", [1]),
    ("python", '#!/usr/bin/env python3\nx = "# not"\n', []),
    ("python", 'x = """\n# not\n"""\n', []),
    ("shell", "#!/bin/sh\necho hi\n# c\n", [3]),
    ("shell", "echo hi # c\n", [1]),
    ("shell", "echo a;# c\n", [1]),
    ("shell", "echo $#\necho ${#var}\necho ${v#pat}\necho ${v##pat}\necho $((16#ff))\n", []),
    ("shell", "echo a#b\necho 'x # y'\necho \"x # y\"\necho \\# x\n", []),
    ("shell", "echo $'a # b\\'' # c\n", [1]),
    ("shell", 'echo "$(echo "#" ) # in"\n', []),
    ("shell", 'echo "$(echo hi # c\n)"\n', [1]),
    ("shell", "x=`echo hi # c\n`\n", [1]),
    ("shell", "cat <<EOF\n# data\nEOF\necho # c\n", [4]),
    ("shell", "cat <<'EOF'\n# data\nEOF\n", []),
    ("shell", 'cat <<"EOF" | tee x\n# data\nEOF\n# c\n', [4]),
    ("shell", "cat <<-EOF\n\t# data\n\tEOF\n# c\n", [4]),
    ("shell", "cat <<A <<B\n# a\nA\n# b\nB\n# c\n", [6]),
    ("shell", "echo $(( 1 << 2 ))\n# c\n", [2]),
    ("yaml", "a: 1\n# c\n", [2]),
    ("yaml", "a: 1 # c\n", [1]),
    ("yaml", "run: |\n  echo hi # c\n", [2]),
    ("yaml", "a: \"x # y\"\nb: 'x # y'\nc: a#b\n", []),
    ("yaml", "a: it's # c\n", [1]),
    ("docker", "FROM x\n# c\n", [2]),
    ("docker", "FROM x\n  # c\n", [2]),
    ("docker", "RUN a \\\n && b # c\n", [2]),
    ("docker", "RUN echo '# x' \\\n && echo \"#\"\n", []),
    ("docker", "RUN a # c\nRUN b\n", [1]),
    ("linecfg", "a\n# c\n  # d\nb#c\n", [2, 3]),
    ("xml", "<a/>\n<!-- x -->\n", [2]),
    ("xml", "<a>\n<!-- x\ny -->\n</a>\n", [2]),
    ("xml", "<a><![CDATA[ <!-- not --> ]]></a>\n", []),
    ("xml", '<a href="x"/>\n', []),
]


def run_self_test():
    failures = 0
    for index, (kind, source, expected) in enumerate(SELF_TESTS):
        got = [number for number, _ in analyze(kind, source)]
        if got != expected:
            failures += 1
            print(f"self-test {index} ({kind}): expected {expected}, got {got}")
    package_swift = "// swift-tools-version:5.9\nlet a = 1\n"
    if analyze("swift", package_swift, SWIFT_TOOLS_PATH):
        failures += 1
        print("self-test: swift-tools-version line should be allowed")
    if not analyze("swift", package_swift, "Other.swift"):
        failures += 1
        print("self-test: swift-tools-version line must be flagged elsewhere")
    if not analyze("swift", "// x\n// swift-tools-version:5.9\n", SWIFT_TOOLS_PATH):
        failures += 1
        print("self-test: swift-tools-version exception must be line 1 only")
    if not analyze("swift", "// other\n", SWIFT_TOOLS_PATH):
        failures += 1
        print("self-test: only the swift-tools-version prefix is allowed")
    if analyze("shell", "#!/bin/bash\n"):
        failures += 1
        print("self-test: shebang should be allowed")
    if not analyze("shell", "echo\n#!/bin/bash\n"):
        failures += 1
        print("self-test: shebang must be line 1 only")
    if failures:
        print(f"{failures} self-test failures")
        return 1
    print(f"self-test passed ({len(SELF_TESTS)} cases)")
    return 0


def tracked_files():
    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    listing = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        capture_output=True,
        cwd=root,
    ).stdout.decode("utf-8", "replace")
    return root, [p for p in listing.split("\0") if p]


def run_check():
    root, paths = tracked_files()
    checked = 0
    total = 0
    for path in paths:
        full = os.path.join(root, path)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        with open(full, "rb") as handle:
            raw = handle.read()
        base_has_ext = bool(os.path.splitext(os.path.basename(path))[1])
        head = "" if base_has_ext else raw[:200].decode("utf-8", "replace")
        kind = kind_of(path, head)
        if kind is None:
            continue
        checked += 1
        text = raw.decode("utf-8", "replace")
        try:
            found = analyze(kind, text, path)
        except (tokenize.TokenError, SyntaxError) as error:
            print(f"{path}:1: cannot parse: {error}")
            total += 1
            continue
        for number, comment in found:
            print(f"{path}:{number}: {comment.strip()[:80]}")
            total += 1
    if total:
        print(f"{total} comments found in {checked} checked files")
        return 1
    print(f"no comments in {checked} files")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return run_self_test()
    return run_check()


if __name__ == "__main__":
    sys.exit(main())
