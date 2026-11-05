#!/usr/bin/env python3
"""Fill the AI gap in shadowrocket.conf so it matches mihomo's GEOSITE,category-ai-!cn.

Shadowrocket has no GEOSITE, and blackmatrix7 only offers lists for a few AI services.
This script downloads category-ai-!cn from MetaCubeX meta-rules-dat (the same data mihomo
and sing-box use), drops the domains already covered by the blackmatrix7 lists referenced
in the AI section, and rewrites the block between the BEGIN/END markers in shadowrocket.conf.

Usage: python3 client/gen-shadowrocket-ai.py
"""
import pathlib
import re
import urllib.request

CONF = pathlib.Path(__file__).with_name("shadowrocket.conf")
META = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ai-!cn.list"
BEGIN = "# BEGIN category-ai-!cn（由 client/gen-shadowrocket-ai.py 生成，不要手改）"
END = "# END category-ai-!cn"
POLICY = "🤖 AI服务"


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8")


def main():
    conf = CONF.read_text(encoding="utf-8")
    head, rest = conf.split(BEGIN + "\n", 1)
    _, tail = rest.split(END + "\n", 1)

    # Rules already in the AI section (outside the generated block): remote lists + inline domains
    ai_part = head.split("# AI（", 1)[1]
    suffix, full, keyword = set(), set(), []
    sources = re.findall(r"^RULE-SET,(\S+?),🤖 AI服务", ai_part, re.M)
    lines = [l for u in sources for l in fetch(u).splitlines()]
    lines += [l.rsplit(",", 1)[0] for l in ai_part.splitlines() if l.endswith("," + POLICY)]
    for line in lines:
        parts = line.strip().split(",")
        if len(parts) < 2:
            continue
        kind, value = parts[0], parts[1].lower()
        if kind == "DOMAIN-SUFFIX":
            suffix.add(value)
        elif kind == "DOMAIN":
            full.add(value)
        elif kind == "DOMAIN-KEYWORD":
            keyword.append(value)

    def covered(domain, exact):
        labels = domain.split(".")
        if any(".".join(labels[i:]) in suffix for i in range(len(labels))):
            return True
        if exact and domain in full:
            return True
        return any(k in domain for k in keyword)

    rules = set()
    for line in fetch(META).splitlines():
        line = line.strip().lower()
        if not line or line.startswith("#"):
            continue
        exact = not line.startswith("+.")
        domain = line if exact else line[2:]
        if not covered(domain, exact):
            rules.add(("DOMAIN" if exact else "DOMAIN-SUFFIX", domain))

    block = "".join(f"{k},{d},{POLICY}\n" for k, d in sorted(rules))
    CONF.write_text(head + BEGIN + "\n" + block + END + "\n" + tail, encoding="utf-8")
    print(f"{len(rules)} rules written to {CONF}")


if __name__ == "__main__":
    main()
