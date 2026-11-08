#!/usr/bin/env python3
"""Erzeugt Resources/Localizable.xcstrings: deutsche Schlüssel (vom Compiler extrahiert, *.stringsdata)
+ englische Übersetzung aus tools/translations.json. Bricht ab, wenn eine Übersetzung fehlt.
Aufruf nach einem Build:  python3 tools/gen-strings.py build"""
import json, glob, sys, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
build = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build")
keys = set()
for f in glob.glob(os.path.join(build, "Build/Intermediates.noindex/HomeCast.build/*/HomeCast.build/Objects-normal/*/*.stringsdata")):
    for arr in json.load(open(f)).get("tables", {}).values():
        for e in arr: keys.add(e["key"])
tr = json.load(open(os.path.join(root, "tools/translations.json")))
missing = sorted(k for k in keys if k not in tr)
if missing:
    print("Fehlende Übersetzungen:"); [print("  " + json.dumps(k, ensure_ascii=False)) for k in missing]; sys.exit(1)
strings = {}
for k in sorted(keys):
    # „de“ ausdrücklich eintragen, damit ein de.lproj entsteht (sonst fiele das deutsche iPhone auf Englisch zurück)
    strings[k] = {"localizations": {"de": {"stringUnit": {"state": "translated", "value": k}},
                                    "en": {"stringUnit": {"state": "translated", "value": tr[k]}}}}
out = {"sourceLanguage": "de", "strings": strings, "version": "1.0"}
json.dump(out, open(os.path.join(root, "Resources/Localizable.xcstrings"), "w"), ensure_ascii=False, indent=2, sort_keys=True)
unused = sorted(set(tr) - keys)
print(f"{len(keys)} Schlüssel geschrieben" + (f", {len(unused)} ungenutzte Übersetzungen" if unused else ""))
