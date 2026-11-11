-- Minimal test harness for Lua 5.1 (no dependencies). Used by run_tests.py.
local T = { tests = {}, root = T3TEST_ROOT or "." }

function T.test(name, fn) T.tests[#T.tests + 1] = { name = name, fn = fn } end

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function T.eq(got, want, msg)
  if got ~= want then
    error((msg and (msg .. ": ") or "") .. "expected " .. fmt(want) .. ", got " .. fmt(got), 2)
  end
end

function T.ok(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

function T.path(rel) return T.root .. "/" .. rel end

--- Load addon modules into a fresh namespace, like WoW does with `local name, ns = ...`.
function T.loadAddon(files)
  local ns = {}
  for _, f in ipairs(files) do
    local chunk, err = loadfile(T.path("addon/T3Bridge/" .. f))
    assert(chunk, err)
    chunk("T3Bridge", ns)
  end
  return ns
end

--- Run a snapshot file in an empty sandbox environment. Returns T3B_IN, T3B_IN_END (or nil, err).
function T.loadSnapshot(path, env)
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  env = env or {}
  setfenv(chunk, env)
  local ok, e = pcall(chunk)
  if not ok then return nil, e end
  return env.T3B_IN, env.T3B_IN_END
end

function T.readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

function T.run()
  local pass, fail, lines = 0, 0, {}
  for _, t in ipairs(T.tests) do
    local ok, err = pcall(t.fn)
    if ok then
      pass = pass + 1
      lines[#lines + 1] = "  ok   " .. t.name
    else
      fail = fail + 1
      lines[#lines + 1] = "  FAIL " .. t.name .. "\n       " .. tostring(err)
    end
  end
  return pass, fail, table.concat(lines, "\n")
end

-- Tiny ordered JSON encoder for vectors: objects are { {key, value}, ... } with `__obj=true`.
function T.json(v, ind)
  ind = ind or ""
  local tv = type(v)
  if tv == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
      return m[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif tv == "number" or tv == "boolean" then
    return tostring(v)
  elseif tv == "table" and v.__obj then
    local parts = {}
    for _, kv in ipairs(v) do parts[#parts + 1] = ind .. "  " .. T.json(kv[1]) .. ": " .. T.json(kv[2], ind .. "  ") end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
  elseif tv == "table" then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = ind .. "  " .. T.json(x, ind .. "  ") end
    if #parts == 0 then return "[]" end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
  end
  return "null"
end

return T
