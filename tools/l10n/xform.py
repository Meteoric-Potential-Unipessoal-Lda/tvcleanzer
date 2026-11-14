# Wrap user-visible Cyrillic string literals in tr('…', [args]) across Dart files.
import re, sys, json, glob, os

CYR = re.compile(r'[\u0400-\u04FF]')

class Lit:  # one string literal: parts = list of ('t', text) | ('e', exprsource)
    def __init__(s, start, end, parts, raw): s.start, s.end, s.parts, s.raw = start, end, parts, raw

def unesc(ch):
    return {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', "'": "'", '"': '"', '$': '$'}.get(ch, ch)

def skip_ws_comments(src, i):
    n = len(src)
    while i < n:
        if src[i] in ' \t\r\n': i += 1
        elif src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j + 1
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2
        else: break
    return i

def parse_string(src, i):
    """src[i] is the opening quote (or r prefix). Returns Lit."""
    start = i
    raw = False
    if src[i] == 'r': raw = True; i += 1
    q = src[i]
    triple = src.startswith(q * 3, i)
    delim = q * 3 if triple else q
    i += len(delim)
    parts = []; buf = []
    n = len(src)
    while i < n:
        if src.startswith(delim, i):
            i += len(delim); break
        c = src[i]
        if c == '\\' and not raw:
            buf.append(unesc(src[i + 1])); i += 2; continue
        if c == '$' and not raw:
            if src[i + 1] == '{':
                j = i + 2; depth = 1
                while depth:
                    k = src[j]
                    if k in '\'"' or (k == 'r' and src[j + 1] in '\'"'):
                        sub = parse_string(src, j); j = sub.end; continue
                    if k == '{': depth += 1
                    elif k == '}': depth -= 1
                    j += 1
                if buf: parts.append(('t', ''.join(buf))); buf = []
                parts.append(('e', src[i + 2:j - 1])); i = j; continue
            m = re.match(r'[A-Za-z_][A-Za-z0-9_]*', src[i + 1:])
            if m:
                if buf: parts.append(('t', ''.join(buf))); buf = []
                parts.append(('e', m.group(0))); i += 1 + len(m.group(0)); continue
        buf.append(c); i += 1
    if buf: parts.append(('t', ''.join(buf)))
    return Lit(start, i, parts, raw)

def find_groups(src):
    """Top-level (not inside other strings) groups of adjacent string literals."""
    i = 0; n = len(src); groups = []
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j + 1; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; continue
        c = src[i]
        isstr = c in '\'"' or (c == 'r' and i + 1 < n and src[i + 1] in '\'"' and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == '_')))
        if isstr:
            lits = [parse_string(src, i)]
            j = skip_ws_comments(src, lits[-1].end)
            while j < n and (src[j] in '\'"' or (src[j] == 'r' and j + 1 < n and src[j + 1] in '\'"')):
                lits.append(parse_string(src, j)); j = skip_ws_comments(src, lits[-1].end)
            groups.append(lits); i = lits[-1].end; continue
        i += 1
    return groups

def dart_lit(text):
    t = text.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$').replace('\n', '\\n').replace('\t', '\\t')
    return "'" + t + "'"

ALL = {}

def convert_expr(expr, fname):
    # an interpolated expression may itself contain Cyrillic literals
    return transform(expr, fname, top=False)

def transform(src, fname, top=True):
    out = []; last = 0
    for g in find_groups(src):
        text = ''.join(p[1] for l in g for p in l.parts if p[0] == 't')
        has_inner = any(p[0] == 'e' and CYR.search(p[1]) for l in g for p in l.parts)
        if not CYR.search(text) and not has_inner:
            continue
        if not CYR.search(text):
            # only nested literals are Cyrillic: rebuild the group with converted expressions
            pieces = []
            for l in g:
                s = src[l.start:l.end]
                pieces.append(s)
            rebuilt = ' '.join(pieces)
            for l in g:
                for p in l.parts:
                    if p[0] == 'e' and CYR.search(p[1]):
                        rebuilt = rebuilt.replace(p[1], convert_expr(p[1], fname), 1)
            out.append(src[last:g[0].start]); out.append(rebuilt); last = g[-1].end
            continue
        tmpl = []; args = []
        for l in g:
            for k, v in l.parts:
                if k == 't': tmpl.append(v.replace('{', '{{').replace('}', '}}') if False else v)
                else:
                    tmpl.append('{%d}' % len(args)); args.append(convert_expr(v, fname))
        key = ''.join(tmpl)
        ALL.setdefault(key, set()).add(fname)
        call = 'tr(' + dart_lit(key) + (', [' + ', '.join(args) + ']' if args else '') + ')'
        out.append(src[last:g[0].start]); out.append(call); last = g[-1].end
    out.append(src[last:])
    return ''.join(out)

DECL = re.compile(r'^\s*const\s+_?[A-Z]\w*(\.\w+)?\(.*(this\.|super\.).*\)\s*(:.*)?;\s*$')
def drop_const(src):
    lines = src.split('\n'); res = []
    for ln in lines:
        if DECL.match(ln) or re.match(r'^\s*(static\s+)?const\s+[a-z_]\w*\s*=', ln) or re.match(r'^\s*const\s+[A-Z_][A-Za-z0-9_<>, ]*\s+[a-z_]\w*\s*=', ln):
            res.append(ln); continue
        # expression-position const before a constructor / collection literal
        ln = re.sub(r'(?<![\w.])const\s+(?=[A-Z_][\w.]*\s*[<(]|\[|\{|<)', '', ln)
        res.append(ln)
    return '\n'.join(res)

if __name__ == '__main__':
    root = sys.argv[1]
    skip = {'lib/services/app_log.dart', 'lib/services/demo_tv.dart', 'lib/l10n/strings.dart', 'lib/l10n/l10n.dart'}
    changed = []
    for f in sorted(glob.glob(root + '/lib/**/*.dart', recursive=True)):
        rel = os.path.relpath(f, root)
        if rel in skip or rel.startswith('lib/l10n/'): continue
        s = open(f, encoding='utf-8').read()
        t = transform(s, rel)
        if t != s:
            t = drop_const(t)
            if "import '" not in t or 'l10n/l10n.dart' not in t:
                depth = rel.count('/') - 1
                imp = "import '" + ('../' * depth) + "l10n/l10n.dart';\n"
                # after the last import line
                m = list(re.finditer(r'^import .*;\s*$', t, re.M))
                pos = m[-1].end() + 1 if m else 0
                t = t[:pos] + imp + t[pos:]
            open(f, 'w', encoding='utf-8').write(t); changed.append(rel)
    json.dump({k: sorted(v) for k, v in ALL.items()}, open(sys.argv[2], 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(len(changed), 'files;', len(ALL), 'strings')
