# Cross-check: the addon's Codec.lua (Lua 5.1 via lupa) vs companion/test/vectors/*.json.
# Usage: pip install lupa ; python scripts/dev/crosscheck-lua-vectors.py [repo root]
# Runs addon/T3Bridge/Codec.lua (Lua 5.1 via lupa) against companion/test/vectors/*.json (read-only).
import json, os, sys, glob
import lupa.lua51 as L
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
lua = L.LuaRuntime(encoding=None, unpack_returned_tuples=True)
codec = lua.eval("function(p) local f = assert(loadfile(p)); return f('T3Bridge', {}) end")((ROOT + "/addon/T3Bridge/Codec.lua").encode())
fails = 0; n = 0
for path in sorted(glob.glob(ROOT + "/companion/test/vectors/*.json")):
    v = json.load(open(path, encoding="utf8"))
    sid = bytes.fromhex(v["sidHex"]); msg = bytes.fromhex(v["messageHex"])
    frames, rows = codec.FramesForMessage(sid, v["seq"], msg, v["flags"])
    got = [frames[k + 1] for k in range(len(frames))]
    want = [bytes.fromhex(f["hex"]) for f in v["frames"]]
    ok = got == want and rows == v["frames"][0]["rows"]
    for k, f in enumerate(v["frames"]):
        cs = codec.CellStrings(got[k] if k < len(got) else b"", rows)
        cells = [cs[i + 1].decode() for i in range(len(cs))]
        ok = ok and cells == f["cells"]
    n += 1
    if not ok: fails += 1
    print(("PASS" if ok else "FAIL"), os.path.basename(path), "parts", len(got), "rows", rows, "bitMode", codec.bitMode.decode() if codec.bitMode else "?")
print(f"{n - fails}/{n} vectors identical between the addon Lua Codec and the companion encoder")
sys.exit(1 if fails else 0)
