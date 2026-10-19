-- CubeOS package host: keeps packages of another computer (docs/packages/10-second-computer.md). Plain CraftOS, no CubeOS needed:
--   wget run <url>/pkghost.lua        (or copy it by floppy and run it)
-- Packages live in /cubeos-host/. The screen shows the pairing code, this computer's id, free space and the stored packages.
-- It answers over every attached modem (wired and wireless) on channel 4277. Protocol and security: the document above.
-- Tests load it as a module: loadfile("game/pkghost.lua")("module") returns the table H (H.new gives a host whose :handle(msg) answers).
local H = {}
H.CHANNEL = 4277
local PROTO, V = "cpkhost", 1
local CHUNK = 16384
local WINDOW = 120000
local band, bxor, bnot, rsh, rrot = bit32.band, bit32.bxor, bit32.bnot, bit32.rshift, bit32.rrotate
local byte, char, sub, fmt = string.byte, string.char, string.sub, string.format
-- ---------------------------------------------------------------- sha256 and HMAC
local K, H0, primes, n = {}, {}, {}, 2
while #primes < 64 do
  local prime = true
  for _, p in ipairs(primes) do if n % p == 0 then prime = false; break end end
  if prime then primes[#primes + 1] = n end
  n = n + 1
end
for j, p in ipairs(primes) do
  local c = p ^ (1 / 3)
  c = c - (c * c * c - p) / (3 * c * c)
  K[j] = math.floor(c % 1 * 2 ^ 32)
  if j <= 8 then H0[j] = math.floor(math.sqrt(p) % 1 * 2 ^ 32) end
end
local function sha(msg, breathe)
  local len = #msg
  local bits, tail = len * 8, ""
  for _ = 1, 8 do tail = char(bits % 256) .. tail; bits = math.floor(bits / 256) end
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. tail
  local h = { table.unpack(H0) }
  local w = {}
  for blk = 1, #msg, 64 do
    for j = 0, 15 do
      local p = blk + j * 4
      local b1, b2, b3, b4 = byte(msg, p, p + 3)
      w[j] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    for j = 16, 63 do
      local a, b = w[j - 15], w[j - 2]
      w[j] = band(w[j - 16] + bxor(rrot(a, 7), rrot(a, 18), rsh(a, 3)) + w[j - 7] + bxor(rrot(b, 17), rrot(b, 19), rsh(b, 10)), 0xffffffff)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for j = 0, 63 do
      local t1 = hh + bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + K[j + 1] + w[j]
      local t2 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22)) + bxor(band(a, b), band(a, c), band(b, c))
      hh, g, f, e, d, c, b, a = g, f, e, band(d + t1, 0xffffffff), c, b, a, band(t1 + t2, 0xffffffff)
    end
    for j, x in ipairs({ a, b, c, d, e, f, g, hh }) do h[j] = band(h[j] + x, 0xffffffff) end
    if breathe and blk % 16384 == 1 then breathe() end
  end
  local out = {}
  for j = 1, 8 do out[j] = fmt("%08x", h[j]) end
  return table.concat(out) -- hex
end
local function unhex(s) return (s:gsub("%x%x", function(x) return char(tonumber(x, 16)) end)) end
local function digest(msg) return unhex(sha(msg)) end
local function hmac(key, msg)
  if #key > 64 then key = digest(key) end
  key = key .. string.rep("\0", 64 - #key)
  local inner = key:gsub(".", function(ch) return char(bxor(byte(ch), 0x36)) end)
  local outer = key:gsub(".", function(ch) return char(bxor(byte(ch), 0x5c)) end)
  return digest(outer .. digest(inner .. msg))
end
H.sha256_hex = sha
function H.hmac_hex(key, msg) return (hmac(key, msg):gsub(".", function(ch) return fmt("%02x", byte(ch)) end)) end
-- the same canonical text as the client (lib/stew/remote.cub): keys in order, no ambiguity
local function canon(v)
  local t = type(v)
  if t == "string" then return "s" .. #v .. ":" .. v end
  if t == "number" then return "#" .. fmt("%.0f", v) .. ";" end
  if t == "boolean" then return v and "T" or "F" end
  if t == "table" then
    local names = {}
    for k in pairs(v) do names[#names + 1] = k end
    table.sort(names)
    local parts = { "{" }
    for _, k in ipairs(names) do parts[#parts + 1] = canon(k); parts[#parts + 1] = canon(v[k]) end
    parts[#parts + 1] = "}"
    return table.concat(parts)
  end
  return "n"
end
local function sign(key, msg)
  msg.mac = nil
  msg.mac = H.hmac_hex(unhex(key), canon(msg))
  return msg
end
local function same(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local x = 0
  for i = 1, #a do if byte(a, i) ~= byte(b, i) then x = 1 end end
  return x == 0
end
-- ---------------------------------------------------------------- the host
local function valid_name(s)
  return type(s) == "string" and #s >= 1 and #s <= 80 and s:match("^[%w%._@%-]+$") ~= nil and s:sub(1, 1) ~= "." and s:sub(-5) ~= ".part"
    and not s:find("..", 1, true)
end
function H.new(o)
  o = o or {}
  local f = o.fs or fs
  local self = { fs = f, dir = o.dir or "/cubeos-host", clients = {}, pending = {}, tries = 0, log = {}, reserve = o.reserve or 4096 }
  self.now = o.now or function() return os.epoch("utc") end
  self.id = o.id or os.getComputerID()
  self.label = o.label or (os.getComputerLabel and os.getComputerLabel()) or ("computer " .. self.id)
  local counter = 0
  self.random = o.random or function()
    counter = counter + 1
    return sha(tostring(os.epoch("utc")) .. ":" .. tostring(os.clock()) .. ":" .. math.random(1, 2 ^ 30) .. ":" .. counter .. ":" .. tostring({}))
  end
  function self:note(text)
    table.insert(self.log, 1, text)
    self.log[7] = nil
    if self.on_event then self.on_event(text) end
  end
  function self:new_code()
    self.code = fmt("%06d", tonumber(sub(self.random(), 1, 7), 16) % 1000000)
    self.code_at = self.now()
    self.tries = 0
  end
  function self:path(name) return self.dir .. "/" .. name end
  function self:save()
    f.makeDir(self.dir)
    local lines = {}
    for cid, c in pairs(self.clients) do lines[#lines + 1] = cid .. " " .. c.key .. " " .. fmt("%.0f", c.n) end
    local h = f.open(self.dir .. "/.clients", "wb")
    if h then h.write(table.concat(lines, "\n")); h.close() end
  end
  function self:load()
    self.clients = {}
    local h = f.open(self.dir .. "/.clients", "rb")
    if not h then return end
    local text = h.readAll() or ""
    h.close()
    for cid, key, nn in text:gmatch("(%d+) (%x+) (%d+)") do self.clients[tonumber(cid)] = { key = key, n = tonumber(nn) } end
  end
  function self:files()
    local out = {}
    if f.exists(self.dir) then
      for _, name in ipairs(f.list(self.dir)) do
        if valid_name(name) and not f.isDir(self:path(name)) then out[name] = f.getSize(self:path(name)) end
      end
    end
    return out
  end
  function self:free()
    f.makeDir(self.dir)
    local free = f.getFreeSpace(self.dir)
    local cap = f.getCapacity and f.getCapacity(self.dir) or nil
    return free, cap
  end
  function self:answer(m, key, fields, nocache)
    local r = { p = PROTO, v = V, op = "res", cid = m.cid, hid = self.id, re = m.n, ok = fields.ok ~= false }
    for k, v in pairs(fields) do r[k] = v end
    if key then sign(key, r) end
    local c = self.clients[m.cid]
    if c and key and not nocache then c.cached, c.cached_req = r, m.mac end -- a retry of the same request (lost answer) gets the same answer again
    return r
  end
  function self:pair(m)
    if self.now() - self.code_at > 600000 then self:new_code() end
    local p = self.pending[m.cid]
    if not p or p.cn ~= m.cn or p.hn ~= m.hn then return nil end
    self.pending[m.cid] = nil
    local pk = hmac(self.code, "cpkhost-pair" .. m.cn .. m.hn)
    local want = H.hmac_hex(pk, "C" .. m.cn .. m.hn .. m.cid .. self.id)
    if not same(want, m.proof) then
      self.tries = self.tries + 1
      self:note("wrong code from #" .. m.cid .. " (" .. self.tries .. " of 3)")
      if self.tries >= 3 then self:new_code(); self:note("code changed after 3 wrong tries") end
      return { p = PROTO, v = V, op = "denied", cid = m.cid, hid = self.id, re = m.cn, err = "wrong code" }
    end
    local key = H.hmac_hex(pk, "K" .. m.cn .. m.hn)
    self.clients[m.cid] = { key = key, n = 0 }
    self:save()
    self:new_code()
    self:note("paired with #" .. m.cid)
    local free, cap = self:free()
    return { p = PROTO, v = V, op = "pair_ok", cid = m.cid, hid = self.id, re = m.cn, label = self.label, free = free, cap = cap,
      proof = H.hmac_hex(pk, "H" .. m.cn .. m.hn .. m.cid .. self.id) }
  end
  function self:handle(m)
    if type(m) ~= "table" or m.p ~= PROTO or m.v ~= V or type(m.cid) ~= "number" then return nil end
    if m.hid ~= nil and m.hid ~= self.id then return nil end
    if m.op == "hello" then
      if type(m.cn) ~= "string" or #m.cn > 64 then return nil end
      local count = 0
      for _ in pairs(self.pending) do count = count + 1 end
      if count >= 8 then self.pending = {} end
      local hn = self.random()
      self.pending[m.cid] = { cn = m.cn, hn = hn }
      return { p = PROTO, v = V, op = "hello_ok", cid = m.cid, hid = self.id, re = m.cn, hn = hn, label = self.label }
    end
    if m.op == "pair" then
      if type(m.cn) ~= "string" or type(m.hn) ~= "string" or type(m.proof) ~= "string" then return nil end
      return self:pair(m)
    end
    local c = self.clients[m.cid]
    if not c then
      if type(m.n) == "number" then return { p = PROTO, v = V, op = "res", cid = m.cid, hid = self.id, re = m.n, ok = false, err = "not paired" } end
      return nil
    end
    local mac = m.mac
    local copy = {}
    for k, v in pairs(m) do copy[k] = v end
    copy.mac = nil
    if not same(H.hmac_hex(unhex(c.key), canon(copy)), mac) then self:note("bad signature from #" .. m.cid); return nil end
    if m.n == c.n and c.cached and c.cached_req == mac then return c.cached end
    if type(m.n) ~= "number" or m.n <= c.n or math.abs(self.now() - m.n) > WINDOW then
      self:note("replayed or stale request from #" .. m.cid)
      return self:answer(m, c.key, { ok = false, err = "stale request" }, true)
    end
    c.n = m.n
    local op = m.op
    if op == "info" then
      local free, cap = self:free()
      return self:answer(m, c.key, { free = free, cap = cap, label = self.label, files = self:files() })
    elseif op == "read" then
      if not valid_name(m.name) or type(m.offset) ~= "number" or type(m.length) ~= "number" then return self:answer(m, c.key, { ok = false, err = "bad request" }) end
      local len = math.min(math.max(m.length, 0), CHUNK)
      local fh = f.exists(self:path(m.name)) and f.open(self:path(m.name), "rb")
      if not fh then return self:answer(m, c.key, { ok = false, err = "no such package" }) end
      fh.seek("set", m.offset)
      local data = fh.read(len) or ""
      fh.close()
      return self:answer(m, c.key, { data = data, size = f.getSize(self:path(m.name)) })
    elseif op == "put" then
      if not valid_name(m.name) or type(m.offset) ~= "number" or type(m.data) ~= "string" or #m.data > CHUNK then
        return self:answer(m, c.key, { ok = false, err = "bad request" })
      end
      local part = self:path(m.name .. ".part")
      if m.offset == 0 then
        if type(m.total) ~= "number" then return self:answer(m, c.key, { ok = false, err = "bad request" }) end
        if f.exists(part) then f.delete(part) end
        local free = self:free()
        local old = f.exists(self:path(m.name)) and f.getSize(self:path(m.name)) or 0
        if m.total + self.reserve > free + old then return self:answer(m, c.key, { ok = false, err = "not enough space (free " .. free .. ")" }) end
        c.total = m.total
      elseif not f.exists(part) or f.getSize(part) ~= m.offset then
        return self:answer(m, c.key, { ok = false, err = "chunk out of order" })
      end
      local fh = f.open(part, m.offset == 0 and "wb" or "ab")
      if not fh then return self:answer(m, c.key, { ok = false, err = "cannot write" }) end
      fh.write(m.data)
      fh.close()
      if m.last then
        local rh = f.open(part, "rb")
        local all = rh.readAll() or ""
        rh.close()
        if sha(all) ~= m.sha then
          f.delete(part)
          self:note("rejected " .. m.name .. ": checksum")
          return self:answer(m, c.key, { ok = false, err = "checksum mismatch" })
        end
        if f.exists(self:path(m.name)) then f.delete(self:path(m.name)) end
        f.move(part, self:path(m.name))
        self:note("stored " .. m.name .. " (" .. #all .. " B) for #" .. m.cid)
        self:save()
      end
      return self:answer(m, c.key, {})
    elseif op == "delete" then
      if not valid_name(m.name) then return self:answer(m, c.key, { ok = false, err = "bad request" }) end
      if f.exists(self:path(m.name)) then f.delete(self:path(m.name)); self:note("deleted " .. m.name .. " for #" .. m.cid) end
      if f.exists(self:path(m.name .. ".part")) then f.delete(self:path(m.name .. ".part")) end
      self:save()
      return self:answer(m, c.key, {})
    elseif op == "forget" then
      local r = self:answer(m, c.key, {})
      self.clients[m.cid] = nil
      self:save()
      self:note("#" .. m.cid .. " unpaired")
      return r
    end
    return self:answer(m, c.key, { ok = false, err = "unknown request" })
  end
  self:load()
  if f.exists(self.dir) then
    for _, name in ipairs(f.list(self.dir)) do
      if name:sub(-5) == ".part" then f.delete(self:path(name)) end
    end
  end
  self:new_code()
  return self
end
-- ---------------------------------------------------------------- the program
local function modems()
  local out = {}
  if peripheral then
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "modem" then out[#out + 1] = name end
    end
  end
  return out
end
local function size_text(n)
  if not n then return "?" end
  if n < 1024 then return n .. " B" end
  return fmt("%.1f KB", n / 1024)
end
function H.main(...)
  local host = H.new({})
  local colour = term.isColour and term.isColour()
  local function paint(c) if colour then term.setTextColour(c) end end
  local program = shell and shell.getRunningProgram and shell.getRunningProgram() or "pkghost.lua"
  if not fs.exists("/startup.lua") and not fs.exists("/startup") then
    term.clear(); term.setCursorPos(1, 1)
    print("Run the package host after every restart?")
    print("This creates /startup.lua. [y/N]")
    local ans = read()
    if ans and ans:lower():sub(1, 1) == "y" then
      local h = fs.open("/startup.lua", "w")
      h.write('shell.run("' .. program .. '")\n')
      h.close()
    end
  end
  local function open_all()
    for _, name in ipairs(modems()) do peripheral.call(name, "open", H.CHANNEL) end
  end
  local function draw()
    local w = term.getSize()
    term.clear(); term.setCursorPos(1, 1)
    paint(colours.yellow); print("CubeOS package host"); paint(colours.white)
    print("Computer #" .. host.id .. "  " .. host.label)
    print("")
    print("Pairing code:")
    paint(colours.lime); print("   " .. host.code); paint(colours.white)
    print("Type it on the CubeOS computer (stew host pair).")
    local free, cap = host:free()
    print("Free " .. size_text(free) .. (cap and (" of " .. size_text(cap)) or ""))
    local mods = modems()
    print("Modems: " .. (#mods > 0 and table.concat(mods, ", ") or "none! attach one"))
    local ids = {}
    for cid in pairs(host.clients) do ids[#ids + 1] = "#" .. cid end
    print("Paired: " .. (#ids > 0 and table.concat(ids, " ") or "nobody yet"))
    print("Packages:")
    local names = {}
    for name, size in pairs(host:files()) do names[#names + 1] = name .. "  " .. size_text(size) end
    table.sort(names)
    if #names == 0 then print("  none") end
    local _, hgt = term.getSize()
    for i = 1, math.min(#names, math.max(1, hgt - 18)) do print("  " .. names[i]) end
    paint(colours.grey)
    for i = 1, #host.log do print(host.log[i]:sub(1, w)) end
    paint(colours.white)
  end
  open_all()
  draw()
  local timer = os.startTimer(5)
  while true do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then break
    elseif ev[1] == "modem_message" and ev[3] == H.CHANNEL then
      local ok, reply = pcall(host.handle, host, ev[5])
      if ok and reply then
        pcall(peripheral.call, ev[2], "transmit", ev[4], H.CHANNEL, reply)
      elseif not ok then
        host:note("error: " .. tostring(reply))
      end
      draw()
    elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then open_all(); draw()
    elseif ev[1] == "timer" and ev[2] == timer then
      if host.now() - host.code_at > 600000 then host:new_code() end
      draw(); timer = os.startTimer(5)
    elseif ev[1] == "key" and ev[2] == keys.r then host:new_code(); draw()
    elseif ev[1] == "key" and ev[2] == keys.q then break end
  end
  term.clear(); term.setCursorPos(1, 1)
end
local args = { ... }
if args[1] == "module" then return H end
return H.main(...)