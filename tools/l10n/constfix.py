import re
def mask(src):
    """Same-length copy with string/comment contents blanked (so we can scan code)."""
    out = list(src); i = 0; n = len(src)
    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n': out[k] = ' '
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i); j = n if j < 0 else j; blank(i, j); i = j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); j = n if j < 0 else j + 2; blank(i, j); i = j; continue
        if src[i] in '\'"':
            q = src[i]; tri = src.startswith(q * 3, i); d = q * 3 if tri else q
            j = i + len(d)
            while j < n and not src.startswith(d, j):
                j += 2 if src[j] == '\\' else 1
            j += len(d)
            # keep tr( visible: strings never contain code we care about
            blank(i + 1, j - 1); i = j; continue
        i += 1
    return ''.join(out)

def match_close(m, i, o, c):
    d = 0
    while i < len(m):
        if m[i] == o: d += 1
        elif m[i] == c:
            d -= 1
            if d == 0: return i
        i += 1
    return -1

def fix(src):
    m = mask(src)
    edits = []
    for k in re.finditer(r'(?<![\w.])const\b', m):
        a = k.start(); j = k.end()
        line_start = m.rfind('\n', 0, a) + 1
        before = m[line_start:a]
        after = m[j:]
        # constructor declarations: const Name({…}) / const Name(this.x)
        if re.match(r'\s+_?[A-Z]\w*(\.\w+)?\(\s*(\{|this\.|super\.|required)', after) and before.strip() == '':
            continue
        # declarations: [static] const [Type] name = …;
        dm = re.match(r'\s+(?:[A-Za-z_][\w<>, ?]*\s+)?[a-z_]\w*\s*=', after)
        if dm and (before.strip() in ('', 'static')):
            end = j + dm.end()
            semi = end; depth = 0
            while semi < len(m):
                ch = m[semi]
                if ch in '([{': depth += 1
                elif ch in ')]}': depth -= 1
                elif ch == ';' and depth == 0: break
                semi += 1
            if 'tr(' in m[end:semi]: edits.append((a, j, 'final'))
            continue
        # expression const
        p = j
        while p < len(m) and m[p] in ' \t\n': p += 1
        if p < len(m) and m[p] == '<':
            p = match_close(m, p, '<', '>') + 1
            while m[p] in ' \t\n': p += 1
        if p < len(m) and m[p] in '[{':
            e = match_close(m, p, m[p], ']' if m[p] == '[' else '}')
        else:
            q = re.match(r'[A-Za-z_][\w.]*(\s*<[^()]*?>)?\s*', m[p:])
            if not q: continue
            p2 = p + q.end()
            if p2 >= len(m) or m[p2] != '(': continue
            e = match_close(m, p2, '(', ')')
        if e > 0 and 'tr(' in m[j:e + 1]:
            end = j
            while end < len(m) and m[end] in ' \t': end += 1
            edits.append((a, end, ''))
    for a, b, r in sorted(edits, reverse=True):
        src = src[:a] + r + src[b:]
    return src, len(edits)
