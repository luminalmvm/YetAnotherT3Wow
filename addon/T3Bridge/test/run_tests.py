#!/usr/bin/env python3
"""Run the T3Bridge Lua tests under a real Lua 5.1 interpreter (lupa.lua51).

    pip install lupa            # once (or put lupa on PYTHONPATH)
    python addon/T3Bridge/test/run_tests.py                 # run all tests
    python addon/T3Bridge/test/run_tests.py --write-vectors # also regenerate protocol/vectors/*.json
    python addon/T3Bridge/test/run_tests.py --unknown       # also list API methods the WoW mock did not model

WoW runs Lua 5.1, so the tests use lupa's lua51 module (not 5.4); 5.2+ syntax fails here as it would in game.
Suites:
  1. compile: every .lua file in the addon parses as Lua 5.1
  2. unit:    test_codec.lua, test_state.lua (pure modules, fixture, torn/stale snapshots, outbox)
  3. smoke:   test_smoke.lua loads the whole addon (TOC order) against wow_mock.lua, twice:
              "modern" (all templates) and "legacy" (no modern templates, no C_XMLUtil, no
              GetPhysicalScreenSize, no BackdropTemplate)
"""
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, ".."))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))

try:
    import lupa.lua51 as lupa51
except ImportError:
    sys.stderr.write("lupa is required: pip install lupa\n")
    sys.exit(2)


def lp(p):
    return p.replace("\\", "/").encode()


def new_runtime():
    lua = lupa51.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    lua.globals().T3TEST_ROOT = lp(ROOT)
    harness = lua.eval("function(p) return assert(loadfile(p))() end")(lp(os.path.join(HERE, "harness.lua")))
    run_file = lua.eval("function(p, T) return assert(loadfile(p))(T) end")
    return lua, harness, run_file


def report(title, harness):
    passed, failed, text = harness.run()
    print(f"\n== {title}")
    print(text.decode("utf-8", "replace"))
    return passed, failed


def main():
    total_pass = total_fail = 0

    # 1. compile check
    lua, _, _ = new_runtime()
    print("Lua runtime:", lua.eval("_VERSION").decode())
    compile_ok = lua.eval("function(p) local f, e = loadfile(p); return f ~= nil, e end")
    bad = 0
    files = []
    for dirpath, _, names in os.walk(ADDON):
        for n in names:
            if n.endswith(".lua"):
                files.append(os.path.join(dirpath, n))
    for f in sorted(files):
        ok, err = compile_ok(lp(f))
        if not ok:
            bad += 1
            print("  COMPILE FAIL", os.path.relpath(f, ROOT), err.decode("utf-8", "replace"))
    print(f"\n== compile: {len(files) - bad}/{len(files)} Lua files parse as Lua 5.1")
    total_pass += len(files) - bad
    total_fail += bad

    # 2. unit
    lua, harness, run_file = new_runtime()
    for name in ("test_codec.lua", "test_state.lua"):
        run_file(lp(os.path.join(HERE, name)), harness)
    p, f = report("unit", harness)
    total_pass += p
    total_fail += f

    if "--write-vectors" in sys.argv:
        vec = run_file(lp(os.path.join(HERE, "vectors_spec.lua")), harness)
        outdir = os.path.join(ROOT, "protocol", "vectors")
        os.makedirs(outdir, exist_ok=True)
        for k in range(1, len(vec) + 1):
            item = vec[k]
            with open(os.path.join(outdir, item[b"name"].decode() + ".json"), "wb") as fh:
                fh.write(item[b"json"])
        print(f"wrote {len(vec)} vectors to {outdir}")

    # 3. smoke, fresh Lua state per config
    tmp = tempfile.mkdtemp(prefix="t3bridge-smoke-")
    try:
        for config in ("modern", "legacy"):
            lua, harness, run_file = new_runtime()
            g = lua.globals()
            g.SMOKE_CONFIG = config.encode()
            g.T3TEST_TMP = lp(tmp)
            run_file(lp(os.path.join(HERE, "test_smoke.lua")), harness)
            p, f = report(f"smoke ({config})", harness)
            total_pass += p
            total_fail += f
            if "--unknown" in sys.argv and g.SMOKE_UNKNOWN:
                print("  unmodelled methods:", g.SMOKE_UNKNOWN.decode())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\nTOTAL: {total_pass} passed, {total_fail} failed")
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
