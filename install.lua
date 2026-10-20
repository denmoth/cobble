-- CubeOS installer bootstrap (docs/packages/08-setup-and-store.md), plain Lua for a bare CraftOS computer:
--   wget run https://raw.githubusercontent.com/denmoth/cobble/main/install.lua
--   install.lua [catalog url] [--from <folder with index.json5 and .cpk>] [--root <dir>] [--keep] [--events <file>] [--text]
-- Downloads cubeos.setup and its dependencies, checks sha256, unpacks them with its own inflate into a temp folder and runs
-- the installer screens (lib/setup), which install the system through stew.
local BASE = "https://raw.githubusercontent.com/denmoth/cobble/main/"
local BRANCH
local START = "cubeos.setup"
local MIN_CC = 1.100

local args, from, root, keep, events, text = { ... }, nil, "/", false, nil, false
local i = 1
while args[i] do
  local a = args[i]
  if a == "--from" then from = args[i + 1]; i = i + 1
  elseif a == "--root" then root = args[i + 1]; i = i + 1
  elseif a == "--events" then events = args[i + 1]; i = i + 1
  elseif a == "--keep" then keep = true
  elseif a == "--text" then text = true
  elseif a:match("^https?://") then BASE = a:sub(-1) == "/" and a or a .. "/"
  else error("unknown argument " .. a, 0) end
  i = i + 1
end
if from and from:sub(1, 1) ~= "/" and shell then from = shell.resolve(from) end
local TMP = fs.combine(root, ".cubeos-setup")
local color = term.isColour and term.isColour()
local band, bor, bxor, bnot, rsh, lsh, rrot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rshift, bit32.lshift, bit32.rrotate
local byte, char, sub = string.byte, string.char, string.sub

local function paint(c) if color then term.setTextColour(c) end end
local function say(text, c) paint(c or colours.white); print(text); paint(colours.white) end
local function breathe() os.queueEvent("cubeos_setup"); os.pullEvent("cubeos_setup") end

-- ---------------------------------------------------------------- sha256 (FIPS 180-4)
-- constants: fractions of square and cube roots of the first primes (one Newton step makes the cube roots exact enough)
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

local function sha256_hex(msg)
  local n = #msg
  local bits, tail = n * 8, ""
  for _ = 1, 8 do tail = char(bits % 256) .. tail; bits = math.floor(bits / 256) end
  msg = msg .. "\128" .. string.rep("\0", (55 - n) % 64) .. tail
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
      local s0 = bxor(rrot(a, 7), rrot(a, 18), rsh(a, 3))
      local s1 = bxor(rrot(b, 17), rrot(b, 19), rsh(b, 10))
      w[j] = band(w[j - 16] + s0 + w[j - 7] + s1, 0xffffffff)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for j = 0, 63 do
      local t1 = hh + bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + K[j + 1] + w[j]
      local t2 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22)) + bxor(band(a, b), band(a, c), band(b, c))
      hh, g, f, e, d, c, b, a = g, f, e, band(d + t1, 0xffffffff), c, b, a, band(t1 + t2, 0xffffffff)
    end
    for j, x in ipairs({ a, b, c, d, e, f, g, hh }) do h[j] = band(h[j] + x, 0xffffffff) end
    if blk % 16384 == 1 then breathe() end
  end
  return string.format(string.rep("%08x", 8), h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
end

-- ---------------------------------------------------------------- inflate (RFC 1951, after zlib's puff.c)
-- length and distance bases and extra bits
local LB, LE, DB, DE = { 3 }, {}, { 1 }, {}
for j = 1, 30 do
  LE[j], DE[j] = math.max(0, math.floor((j - 5) / 4)), math.max(0, math.floor((j - 3) / 2))
  LB[j + 1], DB[j + 1] = LB[j] + 2 ^ LE[j], DB[j] + 2 ^ DE[j]
end
LB[29], LE[29] = 258, 0
local ORD = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function huff(lens, n)
  local cnt, sym, offs = {}, {}, { [1] = 0 }
  for l = 0, 15 do cnt[l] = 0 end
  for s = 0, n - 1 do local l = lens[s] or 0; cnt[l] = cnt[l] + 1 end
  for l = 1, 14 do offs[l + 1] = offs[l] + cnt[l] end
  for s = 0, n - 1 do
    local l = lens[s] or 0
    if l > 0 then sym[offs[l]] = s; offs[l] = offs[l] + 1 end
  end
  return { cnt = cnt, sym = sym }
end

local function inflate(s)
  local pos, bb, bc, out, on = 1, 0, 0, {}, 0
  local function bits(n)
    while bc < n do
      local b = byte(s, pos) or error("inflate: data ends early", 0)
      bb, pos, bc = bb + lsh(b, bc), pos + 1, bc + 8
    end
    local v = band(bb, lsh(1, n) - 1)
    bb, bc = rsh(bb, n), bc - n
    return v
  end
  local function decode(h)
    local code, first, index = 0, 0, 0
    for len = 1, 15 do
      code = bor(code, bits(1))
      local c = h.cnt[len]
      if code - c < first then return h.sym[index + code - first] end
      index, first, code = index + c, (first + c) * 2, code * 2
    end
    error("inflate: bad code", 0)
  end
  repeat
    local last, typ = bits(1), bits(2)
    if typ == 0 then
      bb, bc = 0, 0
      local len = byte(s, pos) + byte(s, pos + 1) * 256
      pos = pos + 4
      for j = 0, len - 1 do out[on + j + 1] = byte(s, pos + j) end
      on, pos = on + len, pos + len
    elseif typ == 3 then
      error("inflate: bad block type", 0)
    else
      local lit, dist
      if typ == 1 then
        local l, d = {}, {}
        for j = 0, 287 do l[j] = j < 144 and 8 or j < 256 and 9 or j < 280 and 7 or 8 end
        for j = 0, 29 do d[j] = 5 end
        lit, dist = huff(l, 288), huff(d, 30)
      else
        local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
        local l = {}
        for j = 1, ncode do l[ORD[j]] = bits(3) end
        local h, lens, j = huff(l, 19), {}, 0
        while j < nlen + ndist do
          local sym = decode(h)
          if sym < 16 then lens[j], j = sym, j + 1
          else
            local v, rep = 0, 0
            if sym == 16 then v, rep = lens[j - 1], 3 + bits(2)
            elseif sym == 17 then rep = 3 + bits(3)
            else rep = 11 + bits(7) end
            for _ = 1, rep do lens[j], j = v, j + 1 end
          end
        end
        local dl = {}
        for k = 0, ndist - 1 do dl[k] = lens[nlen + k] end
        lit, dist = huff(lens, nlen), huff(dl, ndist)
      end
      while true do
        local sym = decode(lit)
        if sym < 256 then on = on + 1; out[on] = sym
        elseif sym == 256 then break
        else
          sym = sym - 256
          local len = LB[sym] + bits(LE[sym])
          local ds = decode(dist) + 1
          local d = DB[ds] + bits(DE[ds])
          for _ = 1, len do on = on + 1; out[on] = out[on - d] end
        end
      end
    end
  until last == 1
  local parts = {}
  for j = 1, on, 4096 do parts[#parts + 1] = char(table.unpack(out, j, math.min(on, j + 4095))) end
  return table.concat(parts)
end

-- ---------------------------------------------------------------- JSON5 (what index.json5 and manifests use)
local function json5(s)
  local p = 1
  local function ws()
    while true do
      p = s:find("[^ \t\r\n]", p) or #s + 1
      local two = sub(s, p, p + 1)
      if two == "//" then p = (s:find("\n", p, true) or #s) + 1
      elseif two == "/*" then p = (s:find("*/", p, true) or #s) + 2
      else return end
    end
  end
  local ESC = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["0"] = "\0" }
  local function str()
    local q, out = sub(s, p, p), {}
    p = p + 1
    while true do
      local e = s:find("[\\" .. q .. "]", p) or error("json5: unterminated string", 0)
      out[#out + 1] = sub(s, p, e - 1)
      if sub(s, e, e) == q then p = e + 1; return table.concat(out) end
      local c = sub(s, e + 1, e + 1)
      p = e + 2
      if c == "u" then
        local cp = tonumber(sub(s, p, p + 3), 16)
        out[#out + 1] = cp < 128 and char(cp) or (utf8 and utf8.char(cp) or "?")
        p = p + 4
      elseif c == "x" then out[#out + 1] = char(tonumber(sub(s, p, p + 1), 16)); p = p + 2
      elseif c ~= "\n" then out[#out + 1] = ESC[c] or c end
    end
  end
  local val
  local function list(close, keyed)
    local t = {}
    p = p + 1
    while true do
      ws()
      if sub(s, p, p) == close then p = p + 1; return t end
      if keyed then
        local k, c = nil, sub(s, p, p)
        if c == '"' or c == "'" then k = str()
        else
          local a, b = s:find("^[%w_$]+", p)
          if not a then error("json5: bad key at " .. p, 0) end
          k, p = sub(s, a, b), b + 1
        end
        ws()
        p = p + 1
        t[k] = val()
      else
        t[#t + 1] = val()
      end
      ws()
      if sub(s, p, p) == "," then p = p + 1 end
    end
  end
  function val()
    ws()
    local c = sub(s, p, p)
    if c == "{" then return list("}", true) end
    if c == "[" then return list("]", false) end
    if c == '"' or c == "'" then return str() end
    local a, b = s:find("^[^,%]}%s]+", p)
    if not a then error("json5: bad value at " .. p, 0) end
    local w = sub(s, a, b)
    p = b + 1
    if w == "true" then return true elseif w == "false" then return false elseif w == "null" then return nil end
    return tonumber(w) or error("json5: bad value " .. w, 0)
  end
  return val()
end

-- ---------------------------------------------------------------- files, downloads, .cpk
local function read(path)
  local f = fs.open(path, "rb")
  if not f then return nil end
  local d = f.readAll()
  f.close()
  return d
end

local function write(path, data)
  fs.makeDir(fs.getDir(path))
  local f = fs.open(path, "wb") or error("cannot write " .. path, 0)
  f.write(data)
  f.close()
end

local function get(rel)
  if rel:match("^https?://") or not from then
    local url = rel:match("^https?://") and rel or BASE .. rel
    local h, err = http.get(url, nil, true)
    if not h then error("cannot download " .. url .. ": " .. tostring(err), 0) end
    local d = h.readAll()
    h.close()
    return d
  end
  return read(fs.combine(from, rel)) or error("no file " .. fs.combine(from, rel), 0)
end

-- raw.githubusercontent.com serves a branch from a cache for minutes after a push: take the files of the newest commit
local function pin(base)
  local o, r, b = base:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/$")
  if not o or #b == 40 then return base end
  local h = http.get("https://api.github.com/repos/" .. o .. "/" .. r .. "/commits/" .. b)
  if not h then return base end
  local sha = h.readAll():match('"sha"%s*:%s*"(%x+)"')
  h.close()
  return sha and #sha == 40 and ("https://raw.githubusercontent.com/" .. o .. "/" .. r .. "/" .. sha .. "/") or base
end

-- the screen as CraftOS left it: text mode, its own colours
local function reset_screen()
  if term.setGraphicsMode then pcall(term.setGraphicsMode, false) end
  if term.nativePaletteColour then
    for i = 0, 15 do pcall(term.setPaletteColour, 2 ^ i, term.nativePaletteColour(2 ^ i)) end
  end
  if color then term.setBackgroundColour(colours.black) end
  term.setTextColour(colours.white)
end

local function u(s, at, n)
  local v, m = 0, 1
  for j = 0, n - 1 do v, m = v + byte(s, at + j) * m, m * 256 end
  return v
end

-- unpack every file except line maps into memory (the installer writes nothing to the disk before it installs);
-- returns the manifest text and {path = contents}
local function unpack_cpk(data)
  if sub(data, 1, 4) ~= "CPK\1" then error("not a .cpk package", 0) end
  local ml = u(data, 5, 4)
  local p = 9 + ml
  local nb, blocks, raw = u(data, p, 2), {}, {}
  p = p + 2
  for j = 1, nb do blocks[j] = { u(data, p, 4), u(data, p + 4, 4), byte(data, p + 12) }; p = p + 17 end
  local nf, files = u(data, p, 2), {}
  p = p + 2
  for _ = 1, nf do
    local pl = u(data, p, 2)
    local path, q = sub(data, p + 2, p + 1 + pl), p + 2 + pl
    local bi, off, size, flags = u(data, q, 2), u(data, q + 2, 4), u(data, q + 6, 4), byte(data, q + 10)
    p = q + 11
    if path:find("%.%.") or path:sub(1, 1) == "/" then error("unsafe path in package: " .. path, 0) end
    if flags ~= 2 then
      if not raw[bi] then
        local b = blocks[bi]
        local st = sub(data, b[1] + 1, b[1] + b[2])
        raw[bi] = b[3] == 2 and inflate(st) or b[3] == 0 and st or error("unknown compression method " .. b[3], 0)
        breathe()
      end
      files[path] = sub(raw[bi], off + 1, off + size)
    end
  end
  return sub(data, 9, 8 + ml), files
end

-- a loader like sys/boot/pkgload.lua over the packages in memory: Cubic chunks get (rt, import), Lua modules get import in
-- their environment
local function loader(idx)
  local rt, cache = assert(load(idx.rt, "=cubic/rt.lua", "t", _G))(), {}
  local function import(spec)
    local m = idx.modules[spec] or error("module '" .. spec .. "' is not installed (no package provides it)", 0)
    local key = m[1] .. ":" .. m[2]
    if cache[key] == nil then
      local src = idx.packages[m[1]].files[m[2]] or error("module file missing: " .. key, 0)
      local env = _G
      if not src:find("^local __rt, __import = %.%.%.") then env = setmetatable({ import = import }, { __index = _G }) end
      cache[key] = assert(load(src, "=" .. m[2]:gsub("^lib/", ""), "t", env))(rt, import) or {}
    end
    return cache[key]
  end
  return import
end

-- newest version: compare the numbers of x.y.z
local function latest(versions)
  local best, bk
  for v in pairs(versions) do
    local k = v:gsub("%d+", function(d) return ("%08d"):format(tonumber(d)) end)
    if not bk or k > bk then best, bk = v, k end
  end
  return best
end

-- ---------------------------------------------------------------- main
local function main()
  if color then term.setBackgroundColour(colours.black) end
  term.clear()
  term.setCursorPos(1, 1)
  paint(colours.lightBlue)
  term.write("\131\131 "); paint(colours.white); print("CubeOS installer")
  say(from and ("Source: " .. from) or ("Source: " .. BASE), colours.grey)
  local cc = tonumber((_HOST or ""):match("ComputerCraft (%d+%.%d+)") or "")
  if cc and cc < MIN_CC then error("CubeOS needs CC: Tweaked " .. MIN_CC .. " or newer (this is " .. _HOST .. ")", 0) end
  if not from and not http then error("HTTP is off: enable http in the ComputerCraft server config, or use --from <folder>", 0) end
  if not from then BRANCH = BASE; BASE = pin(BASE) end
  local free = fs.getFreeSpace(root)

  local index = json5(get("index.json5")).packages or error("index.json5 has no packages", 0)
  local want, order, seen = { START }, {}, {}
  while #want > 0 do
    local id = table.remove(want, 1)
    if not seen[id] then
      seen[id] = true
      local p = index[id] or error("the catalog has no package " .. id, 0)
      local v = latest(p.versions)
      local rec = p.versions[v]
      order[#order + 1] = { id = id, rec = rec }
      for dep in pairs(rec.depends or {}) do want[#want + 1] = dep end
    end
  end
  -- an old installer of the first version left its packages on the disk
  if fs.exists(TMP) then fs.delete(TMP) end
  local idx = { packages = {}, modules = {} }
  local _, y = term.getCursorPos()
  for n, e in ipairs(order) do
    term.setCursorPos(1, y)
    term.clearLine()
    paint(colours.grey); term.write(string.format("[%d/%d] ", n, #order)); paint(colours.white); term.write(e.id)
    local data = get(e.rec.url)
    if #data ~= e.rec.size or sub(data, -2) ~= "\0\0" or sha256_hex(sub(data, 1, -35)) ~= e.rec.sha256 then
      error(e.id .. ": damaged download (size or sha256)", 0)
    end
    local mtext, files = unpack_cpk(data)
    local man = json5(mtext)
    idx.packages[e.id] = { files = files }
    -- modules: lib/a/b.lua is a.b (lib/a/init.lua is a), plus the manifest's own
    for path in pairs(files) do
      local r = path:match("^lib/(.+)%.lua$")
      if r then idx.modules[(r:gsub("/init$", ""):gsub("/", "."))] = { e.id, path } end
    end
    for name, path in pairs(man.modules or {}) do idx.modules[name] = { e.id, path } end
    if files["src/cubic/rt.lua"] then idx.rt = files["src/cubic/rt.lua"] end
  end
  print()
  if not idx.rt then error("the installer packages lack the Cubic runtime (cubeos.cubic-rt)", 0) end

  local import = loader(idx)
  return import("setup").main({
    fs = fs, term = term, root = root, import = import, colour = color,
    -- fonts and pictures of the installer's own packages (in memory)
    asset = function(rel)
      for _, p in pairs(idx.packages) do
        local d = p.files["assets/" .. rel]
        if d then return d end
      end
    end,
    source = from and { name = "local", kind = "path", url = from } or { name = "cobble", kind = "http", url = (BRANCH or BASE) .. "index.json5" },
    events = events and dofile(events) or nil, gui = not text,
    cleanup = function() end,
    reboot = os.reboot,
  })
end

local ok, err = pcall(main)
if not keep and fs.exists(TMP) then fs.delete(TMP) end
if not ok then
  reset_screen()
  print()
  say("CubeOS setup stopped: " .. tostring(err), colours.red)
end
