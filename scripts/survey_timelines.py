"""Surveys the game's scenes (timelines) for the tracks that change what an actor wears or carries.

Input: timeline files extracted from the game's packages and converted to .lsx with LSLib
(vanilla/TimelinesLsx, not in the repository). Output: a summary on the console and
build/timelines-survey.json.

A timeline is a list of EffectComponent nodes; each has a Type, usually an Actor, and Keys.
A key of a "show" track carries its value only when it is not the default. The default is
"shown": the files only ever spell out ShowWeapon="False" and ShowVisual="False".
"""
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "vanilla" / "TimelinesLsx"
OUT = ROOT / "build" / "timelines-survey.json"

# Later packages override earlier ones.
PACKAGES = ["Gustav", "GustavX", "Patch8_HotFix9", "Patch8_HotFix10"]

NODE = re.compile(r'<node id="([^"]+)"')
ATTR = re.compile(r'<attribute id="([^"]+)" type="[^"]+" value="([^"]*)"')
WATCHED = {"TLShowWeapon": "ShowWeapon", "TLShowVisual": "ShowVisual", "TLShowArmor": "Value"}


def scan(path):
    """Yields (type, keys) per component; keys is a list of {attribute: value}."""
    comp_type, keys, key, depth_comp = None, [], None, None
    depth = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("<node"):
                m = NODE.search(stripped)
                name = m.group(1) if m else ""
                if name == "EffectComponent":
                    if comp_type is not None:
                        yield comp_type, keys
                    comp_type, keys, key, depth_comp = "?", [], None, depth
                elif name == "Key" and comp_type is not None:
                    key = {}
                    keys.append(key)
                if not stripped.endswith("/>"):
                    depth += 1
            elif stripped.startswith("</node"):
                depth -= 1
                if depth_comp is not None and depth <= depth_comp:
                    yield comp_type, keys
                    comp_type, keys, key, depth_comp = None, [], None, None
            elif stripped.startswith("<attribute") and comp_type is not None:
                m = ATTR.search(stripped)
                if not m:
                    continue
                if m.group(1) == "Type" and comp_type == "?":
                    comp_type = m.group(2)
                elif key is not None:
                    key[m.group(1)] = m.group(2)
    if comp_type is not None:
        yield comp_type, keys


def main():
    files = {}
    for package in PACKAGES:
        for path in (SOURCE / package).rglob("*.lsx"):
            if "Timeline" in path.parts and "Generated" in path.parts:
                files[path.name] = path
    print(f"{len(files)} timelines", file=sys.stderr)

    types = collections.Counter()          # track type -> number of scenes using it
    samples = collections.defaultdict(list)
    watched = {t: {"scenes": 0, "hides": 0, "hides_then_shows": 0, "only_shows": 0, "examples": []} for t in WATCHED}
    key_attrs = collections.defaultdict(collections.Counter)

    for n, (name, path) in enumerate(sorted(files.items())):
        seen = set()
        state = {t: {"hide": False, "show": False} for t in WATCHED}
        for comp_type, keys in scan(path):
            seen.add(comp_type)
            if comp_type in WATCHED:
                attr = WATCHED[comp_type]
                for key in keys:
                    for a in key:
                        key_attrs[comp_type][a] += 1
                    shown = key.get(attr, "True") == "True"
                    state[comp_type]["show" if shown else "hide"] = True
        for t in seen:
            types[t] += 1
            if len(samples[t]) < 6:
                samples[t].append(name)
        for t, s in state.items():
            if t not in seen:
                continue
            w = watched[t]
            w["scenes"] += 1
            if s["hide"]:
                w["hides"] += 1
                if s["show"]:
                    w["hides_then_shows"] += 1
                w["examples"].append(name)
            elif s["show"]:
                w["only_shows"] += 1
        if n % 2000 == 0:
            print(f"  {n}", file=sys.stderr)

    result = {
        "timelines": len(files),
        "track_types": dict(types.most_common()),
        "samples": samples,
        "watched": watched,
        "key_attributes": {t: dict(c) for t, c in key_attrs.items()},
    }
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(result, indent=1), encoding="utf-8")

    print(f"timelines: {len(files)}")
    for t, w in watched.items():
        print(f"{t}: in {w['scenes']} scenes; hides in {w['hides']} (of them shows again in {w['hides_then_shows']}); only shows in {w['only_shows']}")
        print("   key attributes:", dict(key_attrs[t]))
        prefixes = collections.Counter(re.split(r"[_.]", n)[0] for n in w["examples"])
        print("   by name prefix:", dict(prefixes.most_common(25)))
    print("track types by number of scenes:")
    for t, c in types.most_common():
        print(f"  {c:6d}  {t}")


if __name__ == "__main__":
    main()
