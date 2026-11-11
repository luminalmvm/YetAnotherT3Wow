local T = ...

local ns = T.loadAddon({ "Codec.lua" })
local C = ns.Codec

-- A bit library that behaves like LuaJIT BitOp (signed 32-bit results) to prove normalisation.
local function signed(x) x = x % 4294967296; if x >= 2147483648 then x = x - 4294967296 end; return x end
local fakeBit = {
  bxor = function(a, b)
    a, b = a % 4294967296, b % 4294967296
    local r, p = 0, 1
    for _ = 1, 32 do
      if (a % 2) ~= (b % 2) then r = r + p end
      a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return signed(r)
  end,
  rshift = function(a, n) return signed(math.floor((a % 4294967296) / 2 ^ n)) end,
  band = function(a, b)
    a, b = a % 4294967296, b % 4294967296
    local r, p = 0, 1
    for _ = 1, 32 do
      if (a % 2) == 1 and (b % 2) == 1 then r = r + p end
      a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return signed(r)
  end,
}

local CRC_VECTORS = {
  { "", 0x00000000 },
  { "a", 0xE8B7BE43 },
  { "abc", 0x352441C2 },
  { "123456789", 0xCBF43926 },
  { "The quick brown fox jumps over the lazy dog", 0x414FA339 },
  { string.rep("\255", 32), 0xFF6CAB0B },
}

for _, mode in ipairs({ "pure", "bitlib-signed" }) do
  T.test("crc32 vectors (" .. mode .. ")", function()
    C.SetBitLib(mode == "pure" and nil or fakeBit)
    for _, v in ipairs(CRC_VECTORS) do
      T.eq(C.Crc32(v[1]), v[2], "crc32(" .. string.format("%q", v[1]):sub(1, 20) .. ")")
    end
  end)
end

T.test("crc32 self-test picked a working backend at load", function()
  T.ok(ns.Codec.selfTestOk, "selfTestOk")
end)

T.test("capacities", function()
  C.SetBitLib(nil)
  T.eq(C.CAP_SHORT, 206)
  T.eq(C.CAP_LONG, 974)
end)

T.test("frame layout + parse round trip", function()
  local sid = C.FromHex("9f3a01c2")
  local f = C.BuildFrame(sid, 513, 1, 1, "focus\ta1b2c3d4", 0)
  T.eq(#f, 18 + 14)
  T.eq(f:sub(1, 2), "T3")
  T.eq(f:byte(3), 1)
  T.eq(f:byte(4), 0)
  T.eq(f:sub(5, 8), sid)
  T.eq(f:byte(9) * 256 + f:byte(10), 513)
  T.eq(f:byte(11), 1); T.eq(f:byte(12), 1)
  T.eq(f:byte(13) * 256 + f:byte(14), 14)
  local p = assert(C.ParseFrame(f))
  T.eq(p.payload, "focus\ta1b2c3d4"); T.eq(p.seq, 513); T.eq(p.sid, sid)
  -- corrupt one payload byte -> crc failure
  local bad = f:sub(1, 15) .. "X" .. f:sub(17)
  local q, why = C.ParseFrame(bad)
  T.eq(q, nil); T.eq(why, "crc")
end)

T.test("split: 206 -> 8 rows, 207 -> 32 rows, 4070 -> 5 parts", function()
  local r, ch = C.SplitMessage(string.rep("x", 206))
  T.eq(r, 8); T.eq(#ch, 1)
  r, ch = C.SplitMessage(string.rep("x", 207))
  T.eq(r, 32); T.eq(#ch, 1)
  r, ch = C.SplitMessage(string.rep("x", 4070))
  T.eq(r, 32); T.eq(#ch, 5); T.eq(#ch[1], 974); T.eq(#ch[5], 4070 - 4 * 974)
end)

T.test("cells: sync row, MSB-first packing, cells->bytes round trip", function()
  local sid = C.FromHex("01020304")
  local frames, rows = C.FramesForMessage(sid, 7, "hello", 0)
  local cells = C.CellStrings(frames[1], rows)
  T.eq(#cells, 8)
  T.eq(cells[1], string.rep("10", 128))
  -- first data byte is 'T' = 0x54 = 01010100
  T.eq(cells[2]:sub(1, 8), "01010100")
  T.eq(cells[2]:sub(9, 16), "00110011") -- '3'
  local back = C.CellsToBytes(cells)
  T.eq(back:sub(1, #frames[1]), frames[1])
  T.ok(back:sub(#frames[1] + 1):find("^%z*$"), "padding is zero")
  local p = assert(C.ParseFrame(back))
  T.eq(p.payload, "hello")
end)

T.test("white runs reproduce the cell matrix", function()
  local frames, rows = C.FramesForMessage(C.FromHex("deadbeef"), 65535, string.rep("\255\0", 300), 1)
  for _, fr in ipairs(frames) do
    local cells = C.CellStrings(fr, rows)
    local grid = {}
    for r = 1, rows do grid[r] = {} for x = 1, 256 do grid[r][x] = "0" end end
    for _, run in ipairs(C.WhiteRuns(fr, rows)) do
      for x = run[2], run[2] + run[3] - 1 do grid[run[1] + 1][x + 1] = "1" end
    end
    for r = 1, rows do T.eq(table.concat(grid[r]), cells[r], "row " .. r) end
  end
end)

T.test("multi-part message reassembles", function()
  local msg = C.BuildCommand("send", "a1b2c3d4", "9f3a01c2-3", string.rep("\195\169", 2000)) -- 4000 bytes of é
  local frames, rows = C.FramesForMessage(C.FromHex("9f3a01c2"), 3, msg, 0)
  T.eq(rows, 32)
  local acc = {}
  for k, fr in ipairs(frames) do
    local p = assert(C.ParseFrame(C.CellsToBytes(C.CellStrings(fr, rows))))
    T.eq(p.part, k); T.eq(p.parts, #frames)
    acc[#acc + 1] = p.payload
  end
  T.eq(table.concat(acc), msg)
end)

T.test("commands: clean fields, free-text last field, parse", function()
  local p = C.BuildCommand("send", "a1\tb", "id-1", "line1\nline2\twith tab")
  T.eq(p, "send\ta1 b\tid-1\tline1\nline2\twith tab")
  local f = C.ParseCommand(p)
  T.eq(#f, 4); T.eq(f[4], "line1\nline2\twith tab")
  local f2 = C.ParseCommand(C.BuildCommand("ans", "t1", "r1", "allow"))
  T.eq(f2[1], "ans"); T.eq(f2[4], "allow")
  T.eq(C.BuildCommand("hello"), "hello")
  T.eq(C.BuildCommand("nope"), nil)
end)

T.test("utf8 truncate never splits a character", function()
  local s = "ab\226\130\172cd" -- ab€cd
  T.eq((C.Utf8Truncate(s, 2)), "ab")
  T.eq((C.Utf8Truncate(s, 3)), "ab")
  T.eq((C.Utf8Truncate(s, 4)), "ab")
  T.eq((C.Utf8Truncate(s, 5)), "ab\226\130\172")
  T.eq(C.Utf8Len(s), 5)
end)

T.test("hex helpers and random sid", function()
  T.eq(C.ToHex("\0\255\16"), "00ff10")
  T.eq(C.FromHex("00ff10"), "\0\255\16")
  T.eq(C.FromHex("zz"), nil)
  local n = 0
  local sid = C.RandomSid(function() n = n + 1; return n < 5 and 0 or 7 end)
  T.eq(#sid, 4); T.ok(sid ~= "\0\0\0\0")
end)
