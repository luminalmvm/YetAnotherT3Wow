-- T3Bridge Codec: CRC-32, outbound frame building, bit packing into matrix cells, UTF-8 helpers.
-- Pure Lua 5.1, no WoW API, so test/run_tests.py can run it outside the game.
-- Spec: protocol/PROTOCOL.md section 3.
local _, ns = ...
ns = ns or {}

local Codec = {}
ns.Codec = Codec

local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat

Codec.WIDTH = 256          -- cells per row
Codec.ROW_BYTES = 32       -- bytes per data row (256 cells / 8)
Codec.HEADER = 14
Codec.OVERHEAD = 18        -- header + crc32
Codec.VERSION = 1
Codec.MAX_INPUT = 4000     -- user text cap, bytes
Codec.ROWS_SHORT = 8
Codec.ROWS_LONG = 32

function Codec.Capacity(rows) return (rows - 1) * Codec.ROW_BYTES - Codec.OVERHEAD end
Codec.CAP_SHORT = Codec.Capacity(8)    -- 206
Codec.CAP_LONG = Codec.Capacity(32)    -- 974

---------------------------------------------------------------------------------------------
-- 32-bit XOR / shift. Uses WoW's `bit` library when present (normalising signed results),
-- otherwise a pure-arithmetic nibble-table fallback. Tests exercise both.
---------------------------------------------------------------------------------------------
local TWO32 = 4294967296
local XOR4 = {}
for a = 0, 15 do
  for b = 0, 15 do
    local r, p, x, y = 0, 1, a, b
    for _ = 1, 4 do
      if (x % 2) ~= (y % 2) then r = r + p end
      x, y, p = floor(x / 2), floor(y / 2), p * 2
    end
    XOR4[a * 16 + b] = r
  end
end

local function pureXor(a, b)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local na, nb = a % 16, b % 16
    r = r + XOR4[na * 16 + nb] * p
    a, b, p = (a - na) / 16, (b - nb) / 16, p * 16
  end
  return r
end

local bxor, rshift8, lowbyte

local function useBitLib(lib)
  if lib and lib.bxor and lib.rshift and lib.band then
    local lx, lr, la = lib.bxor, lib.rshift, lib.band
    bxor = function(a, b) return lx(a, b) % TWO32 end
    rshift8 = function(a) return lr(a, 8) % TWO32 end
    lowbyte = function(a) return la(a, 255) % TWO32 end
    Codec.bitMode = "bitlib"
  else
    bxor = pureXor
    rshift8 = function(a) return floor(a / 256) end
    lowbyte = function(a) return a % 256 end
    Codec.bitMode = "pure"
  end
end

local CRC_T
local function buildTable()
  CRC_T = {}
  for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
      if c % 2 == 1 then c = bxor(floor(c / 2), 0xEDB88320) else c = floor(c / 2) end
    end
    CRC_T[n] = c
  end
end

--- Select the bit backend. `lib` = a table with bxor/rshift/band, or false/nil for pure Lua.
function Codec.SetBitLib(lib)
  useBitLib(lib)
  buildTable()
end
--- CRC-32/ISO-HDLC (zlib). Returns an unsigned integer.
function Codec.Crc32(s, i, j)
  i = i or 1
  j = j or #s
  local crc = 0xFFFFFFFF
  for k = i, j do
    crc = bxor(rshift8(crc), CRC_T[lowbyte(bxor(crc, byte(s, k)))])
  end
  return bxor(crc, 0xFFFFFFFF)
end

-- Prefer the host `bit` library, but verify it against the check value: some bit libraries
-- mishandle values >= 2^31. Fall back to pure Lua if it disagrees.
local okBit = pcall(Codec.SetBitLib, type(bit) == "table" and bit or nil) -- luacheck: ignore (WoW global)
if not okBit or Codec.Crc32("123456789") ~= 0xCBF43926 then Codec.SetBitLib(nil) end
Codec.selfTestOk = (Codec.Crc32("123456789") == 0xCBF43926)

---------------------------------------------------------------------------------------------
-- Byte helpers
---------------------------------------------------------------------------------------------
local function u16(n) return char(floor(n / 256) % 256, n % 256) end
local function u32(n)
  return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end
Codec.U16, Codec.U32 = u16, u32

function Codec.ToHex(s)
  return (s:gsub(".", function(c) return string.format("%02x", byte(c)) end))
end

function Codec.FromHex(h)
  if type(h) ~= "string" or #h % 2 ~= 0 or h:find("[^0-9a-fA-F]") then return nil end
  return (h:gsub("..", function(x) return char(tonumber(x, 16)) end))
end

--- 4 random bytes as a raw string. `rnd(lo, hi)` defaults to math.random.
function Codec.RandomSid(rnd)
  rnd = rnd or math.random
  local s
  repeat
    s = char(rnd(0, 255), rnd(0, 255), rnd(0, 255), rnd(0, 255))
  until s ~= "\0\0\0\0"
  return s
end

---------------------------------------------------------------------------------------------
-- UTF-8 helpers
---------------------------------------------------------------------------------------------
--- Largest prefix of `s` that is <= maxBytes and does not end inside a multi-byte sequence.
function Codec.Utf8Truncate(s, maxBytes)
  if #s <= maxBytes then return s, false end
  local cut = maxBytes
  -- step back while the byte after the cut is a continuation byte (10xxxxxx)
  while cut > 0 do
    local b = byte(s, cut + 1)
    if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
  end
  return s:sub(1, cut), true
end

--- Number of UTF-8 characters (lenient: counts non-continuation bytes).
function Codec.Utf8Len(s)
  local n = 0
  for k = 1, #s do
    local b = byte(s, k)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------------------------------------
-- Commands (section 3.1)
---------------------------------------------------------------------------------------------
local function cleanField(v)
  v = tostring(v == nil and "" or v)
  return (v:gsub("[\t\r\n]", " "))
end

Codec.COMMANDS = { hello = true, focus = true, send = true, model = true, intr = true, ans = true, hist = true, open = true,
  clip = true, shot = true, unstage = true } -- clip/shot/unstage: PROTOCOL rev 1.3 (D17)

--- Build a command payload. Every field except the free-text last field of send/ans is cleaned of
--- tabs/newlines. Returns payload string or nil, err.
function Codec.BuildCommand(kind, ...)
  if not Codec.COMMANDS[kind] then return nil, "unknown command" end
  local args = { ... }
  local n = select("#", ...)
  local parts = { kind }
  local freeLast = (kind == "send" or kind == "ans")
  for k = 1, n do
    local v = args[k]
    if freeLast and k == n then
      parts[#parts + 1] = tostring(v == nil and "" or v)
    else
      parts[#parts + 1] = cleanField(v)
    end
  end
  return concat(parts, "\t")
end

--- Split a payload into fields, honouring the free-text rule (max 4 fields for send/ans).
function Codec.ParseCommand(payload)
  local first = payload:find("\t", 1, true)
  local kind = first and payload:sub(1, first - 1) or payload
  local limit = (kind == "send" or kind == "ans") and 4 or math.huge
  local out, pos = {}, 1
  while true do
    if #out == limit - 1 then out[#out + 1] = payload:sub(pos); break end
    local t = payload:find("\t", pos, true)
    if not t then out[#out + 1] = payload:sub(pos); break end
    out[#out + 1] = payload:sub(pos, t - 1)
    pos = t + 1
  end
  return out
end

---------------------------------------------------------------------------------------------
-- Frames (section 3.2)
---------------------------------------------------------------------------------------------
--- @param sid string 4 raw bytes
--- @param seq integer 1..65535
--- @param part integer 1..parts
--- @param parts integer 1..255
--- @param payload string this frame's slice
--- @param flags integer|nil
function Codec.BuildFrame(sid, seq, part, parts, payload, flags)
  assert(type(sid) == "string" and #sid == 4, "sid must be 4 bytes")
  assert(seq >= 1 and seq <= 65535, "seq out of range")
  assert(part >= 1 and part <= parts and parts <= 255, "bad part")
  assert(#payload <= 65535, "payload too long")
  local head = "T3" .. char(Codec.VERSION, flags or 0) .. sid .. u16(seq) .. char(part, parts) .. u16(#payload)
  local body = head .. payload
  return body .. u32(Codec.Crc32(body))
end

--- Choose rows and split a message. Returns rows, { chunk1, chunk2, ... }.
function Codec.SplitMessage(msg)
  if #msg <= Codec.CAP_SHORT then return Codec.ROWS_SHORT, { msg } end
  local chunks, cap = {}, Codec.CAP_LONG
  for k = 1, #msg, cap do chunks[#chunks + 1] = msg:sub(k, k + cap - 1) end
  return Codec.ROWS_LONG, chunks
end

--- All frames for one message. Returns { frame1, ... }, rows.
function Codec.FramesForMessage(sid, seq, msg, flags)
  local rows, chunks = Codec.SplitMessage(msg)
  assert(#chunks <= 255, "message too long")
  local frames = {}
  for k, c in ipairs(chunks) do frames[k] = Codec.BuildFrame(sid, seq, k, #chunks, c, flags) end
  return frames, rows
end

--- Parse + verify a frame byte string (decoder side; used by tests and /t3 spike s2 self-check).
function Codec.ParseFrame(b)
  if #b < Codec.OVERHEAD then return nil, "short" end
  if b:sub(1, 2) ~= "T3" then return nil, "magic" end
  local ver, flags = byte(b, 3), byte(b, 4)
  if ver ~= Codec.VERSION then return nil, "version" end
  local sid = b:sub(5, 8)
  local seq = byte(b, 9) * 256 + byte(b, 10)
  local part, parts = byte(b, 11), byte(b, 12)
  local len = byte(b, 13) * 256 + byte(b, 14)
  if #b < Codec.OVERHEAD + len then return nil, "len" end
  local crcGot = ((byte(b, 15 + len) * 256 + byte(b, 16 + len)) * 256 + byte(b, 17 + len)) * 256 + byte(b, 18 + len)
  if Codec.Crc32(b, 1, 14 + len) ~= crcGot then return nil, "crc" end
  return { flags = flags, sid = sid, seq = seq, part = part, parts = parts, payload = b:sub(15, 14 + len) }
end

---------------------------------------------------------------------------------------------
-- Matrix cells (section 3.3)
---------------------------------------------------------------------------------------------
--- Bit of frame byte k (0-based) at bit position j (0 = MSB).
local function bitAt(frame, k, j)
  local b = byte(frame, k + 1)
  if not b then return 0 end
  return floor(b / 2 ^ (7 - j)) % 2
end

--- Cell value at (row, x), 0-based. Row 0 is the sync row.
function Codec.Cell(frame, row, x)
  if row == 0 then return (x % 2 == 0) and 1 or 0 end
  local k = (row - 1) * Codec.ROW_BYTES + floor(x / 8)
  return bitAt(frame, k, x % 8)
end

--- Rows of "0"/"1" strings, 256 chars each (for vectors and tests).
function Codec.CellStrings(frame, rows)
  assert(#frame <= (rows - 1) * Codec.ROW_BYTES, "frame does not fit")
  local out = {}
  for r = 0, rows - 1 do
    local t = {}
    for x = 0, Codec.WIDTH - 1 do t[x + 1] = Codec.Cell(frame, r, x) end
    out[r + 1] = concat(t)
  end
  return out
end

--- White runs, for rendering with as few textures as possible.
--- Returns array of { row, x0, len } (0-based row/x).
function Codec.WhiteRuns(frame, rows)
  assert(#frame <= (rows - 1) * Codec.ROW_BYTES, "frame does not fit")
  local runs = {}
  for r = 0, rows - 1 do
    local start
    for x = 0, Codec.WIDTH do
      local v = (x < Codec.WIDTH) and Codec.Cell(frame, r, x) or 0
      if v == 1 and not start then
        start = x
      elseif v == 0 and start then
        runs[#runs + 1] = { r, start, x - start }
        start = nil
      end
    end
  end
  return runs
end

--- Inverse of CellStrings: recover frame bytes from data rows (decoder reference; tests).
function Codec.CellsToBytes(cellRows)
  local out = {}
  for r = 2, #cellRows do
    local row = cellRows[r]
    for k = 0, Codec.ROW_BYTES - 1 do
      local v = 0
      for j = 1, 8 do v = v * 2 + (row:sub(k * 8 + j, k * 8 + j) == "1" and 1 or 0) end
      out[#out + 1] = char(v)
    end
  end
  return concat(out)
end

return Codec
