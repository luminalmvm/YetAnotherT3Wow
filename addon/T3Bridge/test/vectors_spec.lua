-- Outbound test vectors (PROTOCOL.md section 3). run_tests.py --write-vectors turns these into
-- protocol/vectors/*.json using the Lua encoder; scripts/dev/gen-vectors.js --check recomputes
-- them independently. /t3 spike s2 shows the same frames in game (see Spike.lua: S2_CASES).
local T = ...
local ns = T.loadAddon({ "Codec.lua" })
local C = ns.Codec
C.SetBitLib(nil)

local SID = "9f3a01c2"
local cases = {
  { name = "hello_c1", seq = 1, cell = 1, flags = 0, msg = C.BuildCommand("hello", "1", "0.1.0", "1", "8") },
  { name = "focus_c2", seq = 2, cell = 2, flags = 0, msg = C.BuildCommand("focus", "a1b2c3d4") },
  { name = "focus_retransmit_c2", seq = 2, cell = 2, flags = 1, msg = C.BuildCommand("focus", "a1b2c3d4") },
  { name = "send_utf8_c2", seq = 3, cell = 2, flags = 0, msg = C.BuildCommand("send", "a1b2c3d4", SID .. "-3", "Hej! caf\195\169 \226\128\148 \240\159\153\130 done?") },
  { name = "ans_option_c1", seq = 4, cell = 1, flags = 0, msg = C.BuildCommand("ans", "a1b2c3d4", "req-77", "allow") },
  { name = "ans_freetext_c4", seq = 5, cell = 4, flags = 0, msg = C.BuildCommand("ans", "c3d4e5f6", "req-80", "Use the staging\tbucket,\nnot prod.") },
  { name = "model_c2", seq = 6, cell = 2, flags = 0, msg = C.BuildCommand("model", "a1b2c3d4", "claude-sonnet-5-5") },
  { name = "model_effort_c2", seq = 11, cell = 2, flags = 0, msg = C.BuildCommand("model", "a1b2c3d4", "claude-opus-5-5", "xhigh") },
  { name = "intr_c4", seq = 7, cell = 4, flags = 0, msg = C.BuildCommand("intr", "b2c3d4e5") },
  { name = "hist_c2", seq = 8, cell = 2, flags = 0, msg = C.BuildCommand("hist", "a1b2c3d4", "93") },
  { name = "boundary_206_c2", seq = 9, cell = 2, flags = 0, msg = C.BuildCommand("send", "a1b2c3d4", SID .. "-9", string.rep("a", 206 - #("send\ta1b2c3d4\t" .. SID .. "-9\t"))) },
  { name = "boundary_207_c2", seq = 10, cell = 2, flags = 0, msg = C.BuildCommand("send", "a1b2c3d4", SID .. "-10", string.rep("b", 207 - #("send\ta1b2c3d4\t" .. SID .. "-10\t"))) },
  { name = "send_4000_c2", seq = 65535, cell = 2, flags = 0, msg = C.BuildCommand("send", "a1b2c3d4", SID .. "-65535", (function()
      local t, i = {}, 0
      while #table.concat(t) < 4000 do i = i + 1; t[#t + 1] = string.format("%04d \195\169\226\130\172 ", i) end
      return (C.Utf8Truncate(table.concat(t), 4000))
    end)()) },
}

local out = {}
for _, c in ipairs(cases) do
  local frames, rows = C.FramesForMessage(C.FromHex(SID), c.seq, c.msg, c.flags)
  local parts = {}
  for k, fr in ipairs(frames) do
    local p = assert(C.ParseFrame(fr))
    parts[k] = { __obj = true,
      { "part", k }, { "parts", #frames }, { "len", #p.payload },
      { "payload_hex", C.ToHex(p.payload) },
      { "frame_hex", C.ToHex(fr) },
      { "crc32_hex", C.ToHex(fr:sub(-4)) },
      { "cells", C.CellStrings(fr, rows) },
    }
  end
  out[#out + 1] = { name = c.name, json = T.json({ __obj = true,
    { "name", c.name },
    { "protocol", "T3Bridge outbound v1 (protocol/PROTOCOL.md section 3)" },
    { "sid_hex", SID }, { "seq", c.seq }, { "flags", c.flags },
    { "cell", c.cell }, { "rows", rows }, { "width_cells", 256 },
    { "message_utf8", c.msg }, { "message_hex", C.ToHex(c.msg) }, { "message_len", #c.msg },
    { "parts", parts },
  }) .. "\n" }
end
return out
