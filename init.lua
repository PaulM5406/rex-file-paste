-- rex-file-paste: paste the files on the Mac's clipboard into a Rex pane as
-- shell-quoted paths. For a pane on another Rex server, the files are first
-- copied to that machine.
--
--   require("rex-file-paste").setup{ max_size_mb = 25, max_dimension = 2000, key = "cmd+shift+v" }
--
-- Derived from rex-image-paste by pablasso (MIT). See LICENSE.
--
-- Two parts:
--
-- * The action (file_paste) runs in the Mac's Rex server. It reads the
--   clipboard, checks the files, and pastes local paths at once. A Rex
--   configuration action may run for 30 seconds only, so for a remote pane
--   it writes a job file and starts a detached `rex do worker.lua`, then
--   returns.
-- * The worker (a `rex do` script, with no time limit) prepares images,
--   copies each file through a hidden terminal on the remote server that runs
--   `base64 -d`, checks the SHA-256, shows a progress bar when the copy takes
--   more than 2 seconds, and pastes the paths.

local M = {}

M.version = "0.1.0"

local function this_dir()
  local src = debug.getinfo(1, "S").source or ""
  return src:match("^@(.*)/[^/]*$")
end

M.options = {
  -- Key bound by setup(). Set to false to bind it yourself.
  key = "cmd+shift+v",
  -- Largest total size, in MiB, copied to another server in one paste.
  max_size_mb = 25,
  -- Shrink images whose long edge is larger than this many pixels before a
  -- copy. false keeps the size.
  max_dimension = 2000,
  -- Convert images that agents can't read (HEIC, TIFF, BMP) to PNG, and
  -- shrink them (max_dimension), before a copy. false sends images unchanged.
  convert_images = true,
  -- A copy is abandoned after timeout seconds plus the time to send the
  -- data at min_rate_mb MiB/s. Measured: 20 MB in 11 s over Tailscale.
  timeout = 15,
  min_rate_mb = 0.5,
  -- Show a progress bar when the copy has run this many seconds.
  progress_after = 2,
  -- Report background failures with a macOS notification.
  notify = true,
  -- Where the Mac keeps job files, clipboard images, and converted images.
  local_dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/rex-file-paste",
  -- The rex executable that runs the worker. nil finds it.
  rex_path = nil,
  -- The directory that holds worker.lua. nil uses this file's directory.
  module_dir = this_dir(),
  pasteboard = nil, -- tests only: read this named pasteboard instead
}

local SHELL = "com.superlogical.terminal.shell"
local MiB = 1024 * 1024
-- A control request is at most 65536 bytes once encoded (measured: the
-- server refuses larger ones). Keep 1 KiB for the request around the data.
local CHUNK = 64 * 1024 - 1024

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true,
  heic = true, heif = true, tif = true, tiff = true, bmp = true }
-- Agents read PNG, JPEG, GIF, and WebP. Other image formats become PNG.
local KEEP_FORMAT = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

-- Prints JSON: {"kind":"files","paths":[...],"names":[...]}, {"kind":"image","format":
-- "png"|"tiff","path":...} after saving a raw image to argv[0].<format>, or
-- {"kind":"none"}.
local CLIPBOARD_JS = [=[
ObjC.import('AppKit');
function run(argv) {
  const pb = argv[1] ? $.NSPasteboard.pasteboardWithName(argv[1]) : $.NSPasteboard.generalPasteboard;
  // A file copied in Finder is a file URL plus a TIFF of its icon, so check URLs first.
  const opts = $.NSDictionary.dictionaryWithObjectForKey(true, $.NSPasteboardURLReadingFileURLsOnlyKey);
  const urls = pb.readObjectsForClassesOptions($([$.NSURL]), opts);
  if (urls && !urls.isNil() && urls.count > 0) {
    // A file URL's path is often decomposed (NFD). Keep it as it is for the
    // Mac, and give the name in composed form (NFC), as people type it.
    const paths = [], names = [];
    for (let i = 0; i < urls.count; i++) {
      const path = ObjC.unwrap(urls.objectAtIndex(i).path);
      paths.push(path);
      names.push(path.replace(/\/+$/, '').split('/').pop().normalize('NFC'));
    }
    return JSON.stringify({ kind: 'files', paths: paths, names: names });
  }
  for (const [type, format] of [[$.NSPasteboardTypePNG, 'png'], [$.NSPasteboardTypeTIFF, 'tiff']]) {
    const data = pb.dataForType(type);
    if (data.isNil()) continue;
    const path = argv[0] + '.' + format;
    if (!data.writeToFileAtomically(path, true)) throw new Error('cannot write ' + path);
    return JSON.stringify({ kind: 'image', format: format, path: path });
  }
  return JSON.stringify({ kind: 'none' });
}
]=]

-- Runs on the remote machine as:
--   sh -c SCRIPT rex-file-paste KEY NAME LENGTH SECONDS SHA256
-- Every value arrives as an argument; nothing is put into the script text.
-- The file goes to /tmp/rex-file-paste-UID/KEY/NAME. If that file, or a file
-- with the same key, already has SHA256, the script reports a hit.
-- Otherwise it puts the terminal in raw mode, reads LENGTH bytes of base64,
-- and reports the checksum of what it decoded.
local REMOTE_SCRIPT = [=[
umask 077
say() { printf '\r\nREXFP-%s\r\n' "$*"; }
fail() { say "ERR $*"; sleep 60; exit 1; }
sum() { { sha256sum 2>/dev/null || shasum -a 256; } < "$1" | cut -c1-64; }
key=$1 name=$2 len=$3 secs=$4 want=$5
case $key in ''|*[!0-9a-f]*) fail "bad key";; esac
case $name in ''|.|..|*/*) fail "bad file name";; esac
case $len$secs in ''|*[!0-9]*) fail "bad length";; esac
uid=$(id -u)
d="/tmp/rex-file-paste-$uid"
[ -L "$d" ] && fail "$d is a symbolic link"
mkdir -p "$d" 2>/dev/null
[ -d "$d" ] && [ -O "$d" ] || fail "cannot use $d"
chmod 700 "$d" || fail "cannot set the mode of $d"
find "$d" -mindepth 2 -type f -mmin +1440 -exec rm -f {} + 2>/dev/null
find "$d" -mindepth 1 -depth -type d -empty -exec rmdir {} + 2>/dev/null
k="$d/$key"
f="$k/$name"
mkdir -p "$k" || fail "cannot create $k"
if [ -f "$f" ] && [ "$(sum "$f")" = "$want" ]; then
  touch "$f"; say "HIT $uid"; sleep 60; exit 0
fi
for g in "$k"/*; do
  [ -f "$g" ] && [ "$g" != "$f" ] || continue
  if [ "$(sum "$g")" = "$want" ] && cp "$g" "$f.part.$$" && mv -f "$f.part.$$" "$f"; then
    touch "$f"; say "HIT $uid"; sleep 60; exit 0
  fi
done
t="$f.part.$$"
trap 'rm -f "$t"' EXIT
stty raw -echo 2>/dev/null || fail "cannot set the terminal mode"
( sleep "$secs"; kill 0 ) 2>/dev/null &
say READY
if head -c "$len" | base64 -d > "$t" && mv -f "$t" "$f"; then
  say "OK $(sum "$f") $uid"
else
  say "ERR could not decode the copy"
fi
sleep 60
]=]

-- Runs in the progress terminal. Each line it reads is "PERCENT TEXT".
local PROGRESS_SCRIPT = [=[
stty -echo 2>/dev/null
printf '\033[?25l'
while IFS= read -r l; do
  p=${l%% *}; t=${l#* }
  printf '\033]7501;state=working:app=rex-file-paste:progress=%s\033\\\r\033[K %s' "$p" "$t"
done
]=]

local function fail(message)
  error("rex-file-paste: " .. message, 0)
end

local function exec(argv, opts)
  local r, err = rex.exec(argv, opts)
  if r == nil then fail(argv[1] .. ": " .. tostring(err)) end
  if not r.ok then
    fail(argv[1] .. ": " .. (r.stderr ~= "" and r.stderr:gsub("%s+$", "") or ("exit " .. r.code)))
  end
  return r.stdout
end

local function must(what, f, ...)
  local result, err = f(...)
  if result == nil then fail(what .. ": " .. tostring(err)) end
  return result
end

local function sleep(seconds)
  if rex.sleep then return rex.sleep(seconds) end
  rex.exec({ "sleep", tostring(seconds) }) -- the configuration file has no rex.sleep
end

-- Seconds with milliseconds. os.time() counts whole seconds only.
local function now()
  local r = rex.exec({ "perl", "-MTime::HiRes=time", "-e", "printf '%.3f', time" })
  return tonumber(r and r.stdout) or os.time()
end

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

local function extension(name)
  return (name:match("%.([^./]+)$") or ""):lower()
end

-- True when s has a C0 or C1 control character, newline and tab included.
local function has_control(s)
  return s:find("%c") ~= nil or s:find("\194[\128-\159]") ~= nil
end

M.has_control = has_control

-- Quotes a path the way a terminal quotes a dropped file: a backslash before
-- every byte a shell could read as syntax. Plain paths stay plain, so agents
-- still recognize them. UTF-8 bytes are left as they are.
function M.shell_quote(path)
  return (path:gsub("[^%w%-%._/+,:@\128-\255]", "\\%0"))
end

local function join_paths(paths)
  local quoted = {}
  for i, p in ipairs(paths) do quoted[i] = M.shell_quote(p) end
  return table.concat(quoted, " ")
end

local function sha256_file(path)
  local out = exec({ "sh", "-c", 'shasum -a 256 < "$1"', "rex-file-paste", path })
  return out:match("^(%x+)") or fail("no checksum for " .. path)
end

local function sha256_text(text)
  return exec({ "shasum", "-a", "256" }, { stdin = text }):match("^(%x+)")
end

local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = io.open(path)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function mb(bytes)
  return string.format("%.1f MiB", bytes / MiB)
end

local function notify(message)
  if not M.options.notify then return end
  rex.exec({ "osascript", "-e", "on run argv", "-e",
    'display notification (item 1 of argv) with title "rex-file-paste"', "-e", "end run", message })
end

-- The action reads the clipboard of the machine its server runs on, so make
-- sure that is the Mac whose key was pressed.
local function check_machine(ctx)
  if M.platform == nil then
    local r = rex.exec({ "uname", "-s" })
    M.platform = r and r.stdout:gsub("%s+$", "") or "unknown"
  end
  if M.platform ~= "Darwin" then
    fail("install this on your Mac's Rex server; this server runs on " .. M.platform)
  end
  if ctx.client_id then
    local info = rex.call("client.inspect", { client_id = ctx.client_id })
    local kind = info and info.client and info.client.principal and info.client.principal.kind
    if kind and kind ~= "peer" then
      fail("the key was pressed on another device, and this server can only read its own clipboard")
    end
  end
end

local function staging_name()
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("incoming-%s-%04x", os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
end

-- Returns the clipboard's content as {kind = "files", paths = {...}} or
-- {kind = "image", format = ..., path = ...}, or nil when it has neither.
local function read_clipboard()
  local argv = { "osascript", "-l", "JavaScript", "-e", CLIPBOARD_JS,
    M.options.local_dir .. "/" .. staging_name() }
  if M.options.pasteboard then argv[#argv + 1] = M.options.pasteboard end
  local out = exec(argv, { timeout = 5 })
  local clip = rex.json.decode(out) or fail("cannot read the clipboard: " .. out)
  if clip.kind == "files" and clip.paths and #clip.paths > 0 then return clip end
  if clip.kind == "image" then return clip end
  return nil
end

-- Checks one copied file and returns its entry, or fails with the reason.
local function check_file(path, name)
  name = name or basename(path)
  if has_control(path) or has_control(name) then
    fail("refused: a file name has a control character or a line break: "
      .. path:gsub("%c", "?"))
  end
  local r = rex.exec({ "stat", "-L", "-f", "%HT\t%z", path })
  if not (r and r.ok) then fail("cannot read " .. path) end
  local kind, size = r.stdout:match("^([^\t]+)\t(%d+)")
  if kind == "Directory" then
    fail("refused: " .. name .. " is a folder; copy the files inside it instead")
  end
  if kind ~= "Regular File" then
    fail("refused: " .. name .. " is not a regular file")
  end
  return { src = path, name = name, size = tonumber(size), image = IMAGE_EXT[extension(name)] or false }
end

-- Returns the files to paste, each {src, name, size, image, raw}.
local function clipboard_entries(clip)
  local entries = {}
  if clip.kind == "files" then
    for i, path in ipairs(clip.paths) do entries[i] = check_file(path, clip.names and clip.names[i]) end
  else
    local r = rex.exec({ "stat", "-f", "%z", clip.path })
    entries[1] = { src = clip.path, name = "clipboard-image." .. clip.format,
      size = tonumber(r and r.stdout) or 0, image = true, raw = true }
  end
  return entries
end

-- Returns how sips should change an image, as a list of arguments, and the
-- name of its output.
local function image_plan(entry)
  local ext = extension(entry.name)
  local argv = {}
  local name = entry.name
  if not KEEP_FORMAT[ext] then
    argv = { "-s", "format", "png" }
    name = (entry.name:gsub("%.[^.]*$", "")) .. ".png"
  end
  local limit = M.options.max_dimension
  if limit and ext ~= "gif" and ext ~= "webp" then
    local info = exec({ "sips", "-g", "pixelWidth", "-g", "pixelHeight", entry.src })
    local w = tonumber(info:match("pixelWidth: (%d+)")) or 0
    local h = tonumber(info:match("pixelHeight: (%d+)")) or 0
    if math.max(w, h) > limit then
      argv[#argv + 1] = "-Z"
      argv[#argv + 1] = tostring(limit)
    end
  end
  return argv, name
end

-- Returns the file to send for entry: {path, name, key, sha, size}. key, the
-- remote directory, is the SHA-256 of the content. A converted image is
-- keyed by its source and the conversion, because sips output isn't
-- byte-for-byte repeatable; the converted file is kept on the Mac to reuse.
function M.prepare(entry)
  local src_sha = sha256_file(entry.src)
  local argv, name = {}, entry.name
  if entry.image and M.options.convert_images then argv, name = image_plan(entry) end
  local key, out
  if #argv == 0 then
    key = src_sha:sub(1, 32)
    if not entry.raw then
      return { path = entry.src, name = name, key = key, sha = src_sha, size = entry.size }
    end
    out = M.options.local_dir .. "/" .. key .. "/" .. name
    exec({ "mkdir", "-p", M.options.local_dir .. "/" .. key })
    if not exists(out) then exec({ "mv", entry.src, out }) end
  else
    key = sha256_text(src_sha .. " " .. table.concat(argv, " ")):sub(1, 32)
    out = M.options.local_dir .. "/" .. key .. "/" .. name
    if not exists(out) then
      exec({ "mkdir", "-p", M.options.local_dir .. "/" .. key })
      local cmd = { "sips" }
      for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
      for _, a in ipairs({ entry.src, "--out", out .. ".part" }) do cmd[#cmd + 1] = a end
      exec(cmd, { timeout = 20 })
      exec({ "mv", out .. ".part", out })
    end
  end
  if entry.raw then os.remove(entry.src) end
  local size = tonumber(exec({ "stat", "-f", "%z", out })) or 0
  return { path = out, name = name, key = key, sha = sha256_file(out), size = size }
end

local function paste_text(api, session_id, block_id, text)
  must("paste", api.call, "block.event", {
    session_id = session_id,
    block_id = block_id,
    event = { type = "paste", payload = { text = text } },
  })
end

local function clean_local()
  local d = M.options.local_dir
  rex.exec({ "find", d, "-mindepth", "1", "-type", "f", "-mmin", "+1440", "-delete" })
  rex.exec({ "find", d, "-maxdepth", "1", "-name", "worker.log", "-size", "+1024k", "-delete" })
  rex.exec({ "find", d, "-mindepth", "1", "-type", "d", "-empty", "-delete" })
end

-- Maps ctx.server, the name the app gives a server, to the label of a host
-- this server knows, which `rex do` accepts.
local function host_label(name)
  local list = rex.call("hosts.list", {})
  for _, h in ipairs(list and list.hosts or {}) do
    if h.label == name or h.id == name then return h.label end
  end
  for _, h in ipairs(list and list.hosts or {}) do
    if h.label and h.label:lower() == tostring(name):lower() then return h.label end
  end
  return name
end

-- The worker runs with the same rex executable as the server: the one on
-- PATH, else the process that started this shell (the server itself runs
-- as `rex server run`), else the place the Mac app installs it.
local function rex_path()
  if M.options.rex_path then return M.options.rex_path end
  local r = rex.exec({ "sh", "-c", [[
command -v rex && exit
p=$(ps -o comm= -p $PPID)
case $p in /*/rex) echo "$p"; exit;; esac
p="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
[ -x "$p" ] && echo "$p"
]] })
  local path = r and r.stdout:match("^(/[^\n]+)")
  if path then return path end
  fail("cannot find the rex executable; set rex_path in setup{}")
end

local JOB_OPTIONS = { "max_size_mb", "max_dimension", "convert_images", "timeout", "min_rate_mb",
  "progress_after", "notify", "local_dir" }

-- Starts the worker for a copy to another server and returns the job file.
local function start_job(ctx, entries)
  local opts = {}
  for _, k in ipairs(JOB_OPTIONS) do opts[k] = M.options[k] end
  local jobs = M.options.local_dir .. "/jobs"
  exec({ "mkdir", "-p", jobs })
  local job = jobs .. "/" .. staging_name() .. ".json"
  write_file(job, rex.json.encode({
    host = host_label(ctx.server), session_id = ctx.session_id, block_id = ctx.block_id,
    entries = entries, options = opts,
  }))
  local worker = (M.options.module_dir or ".") .. "/worker.lua"
  if not exists(worker) then fail("cannot find " .. worker .. "; set module_dir in setup{}") end
  if not (rex.exec and rex.exec.start) then fail("this version of Rex can't start a background command") end
  local h, err = rex.exec.start({ "sh", "-c", 'exec "$1" --autostart=false do "$2" job="$3" >>"$4" 2>&1',
    "rex-file-paste", rex_path(), worker, job, M.options.local_dir .. "/worker.log" },
    { detach = true, stdout = false, stderr = false })
  if not h then fail("cannot start the copy: " .. tostring(err)) end
  return job
end

-- The action body. ctx needs session_id and block_id, and server for a pane
-- on another Rex server.
function M.paste(ctx)
  if not ctx.session_id or not ctx.block_id then fail("no focused terminal") end
  check_machine(ctx)
  exec({ "mkdir", "-p", M.options.local_dir })
  exec({ "chmod", "700", M.options.local_dir })
  clean_local()
  local clip = read_clipboard()
  if not clip then return { pasted = "nothing" } end
  local entries = clipboard_entries(clip)

  if not ctx.server then
    -- A local pane gets the original paths. Only a raw clipboard image needs
    -- a file, and it gets the same treatment as an image sent away.
    local paths = {}
    for i, e in ipairs(entries) do
      paths[i] = e.raw and M.prepare(e).path or e.src
    end
    paste_text(rex, ctx.session_id, ctx.block_id, join_paths(paths))
    return { pasted = "paths", paths = paths }
  end

  -- Images can shrink before the copy, so the worker checks them again later.
  local total = 0
  for _, e in ipairs(entries) do
    if not (e.image and M.options.convert_images) then total = total + e.size end
  end
  if total > M.options.max_size_mb * MiB then
    for _, e in ipairs(entries) do if e.raw then os.remove(e.src) end end
    fail(string.format("refused: %s to copy, more than the limit of %d MiB", mb(total), M.options.max_size_mb))
  end
  local job = start_job(ctx, entries)
  return { pasted = "pending", job = job, server = ctx.server }
end

-- A progress bar in a floating layer at the bottom of the pane's window, on
-- the remote server. Its program reports the percentage with OSC 7501 too.
local function progress_bar(api, session_id, block_id)
  local bar = {}
  local layer, term
  local function open()
    local info = api.call("session.describe_block", { session_id = session_id, block_id = block_id })
    local window_id = info and info.block and info.block.window_id
    if not window_id then return end
    local r = api.call("session.new_layer", {
      session_id = session_id, window_id = window_id, focus = false,
      bounds = { 0.5, 0.86, 0.48, 0.12 },
      layout = { block = { flavor = SHELL, label = "rex-file-paste",
        options = { shell = "none", command = { "sh", "-c", PROGRESS_SCRIPT } } } },
    })
    if r then layer, term = r.layer_id, r.block_ids[1] end
  end
  function bar.update(fraction, text)
    if not layer then open() end
    bar.opened = bar.opened or layer ~= nil
    if not term then return end
    local pct = math.floor(fraction * 100)
    local width = 20
    local full = math.floor(fraction * width)
    local line = string.format("%d [%s%s] %d%% %s", pct, string.rep("#", full), string.rep("-", width - full), pct, text)
    api.call("block.method", { session_id = session_id, block_id = term, method = "write", args = { data = line .. "\n" } })
    bar.last = line
  end
  function bar.screen()
    if not term then return nil end
    local s = api.call("block.method", { session_id = session_id, block_id = term, method = "program_status", args = {} })
    return s
  end
  function bar.close()
    if layer then api.call("session.close_layer", { session_id = session_id, layer_id = layer }) end
    layer, term = nil, nil
  end
  return bar
end

-- Copies one prepared file to the server behind api. Returns the remote path
-- and whether the server already had it.
local function upload(api, session_id, file, state)
  local len = 4 * math.ceil(file.size / 3)
  local secs = math.ceil(state.deadline - now()) + 30
  local block_id = must("start the copy terminal", api.call, "session.new_block", {
    session_id = session_id,
    flavor = SHELL,
    label = "rex-file-paste",
    options = {
      shell = "none",
      command = { "sh", "-c", REMOTE_SCRIPT, "rex-file-paste", file.key, file.name,
        tostring(len), tostring(math.max(secs, 60)), file.sha },
      size = { columns = 200, rows = 10 },
    },
  }).block_id

  local function call(method, args)
    return api.call("block.method", { session_id = session_id, block_id = block_id, method = method, args = args or {} })
  end
  local function screen()
    local s = call("format", { trim = true, unwrap = true })
    local text = s and s.content or ""
    local why = text:match("REXFP%-ERR ([^\r\n]+)")
    if why then fail(file.name .. ": " .. why) end
    return text
  end
  local function remote_path(uid)
    return "/tmp/rex-file-paste-" .. uid .. "/" .. file.key .. "/" .. file.name
  end

  local ok, path, cached = pcall(function()
    while true do
      local text = screen()
      local uid = text:match("REXFP%-HIT (%d+)")
      if uid then return remote_path(uid), true end
      if text:find("REXFP%-READY") then break end
      state.check("starting the copy")
      sleep(0.02)
    end
    state.mark("remote ready for " .. file.name)
    -- macOS base64 writes one line. Drop its line end without scanning the
    -- whole text; scan only if it ever wraps lines.
    local encoded = exec({ "base64", "-i", file.path })
    local last = #encoded
    while last > 0 and encoded:byte(last) <= 32 do last = last - 1 end
    encoded = encoded:sub(1, last)
    if #encoded ~= len then encoded = encoded:gsub("%s", "") end
    state.mark("encoded " .. file.name)
    if #encoded ~= len then fail("unexpected base64 length for " .. file.name) end
    local n = 0
    for i = 1, #encoded, CHUNK do
      must("copy", call, "write", { data = encoded:sub(i, i + CHUNK - 1) })
      n = n + 1
      state.sent = state.sent + math.min(CHUNK, #encoded - i + 1)
      if n % 16 == 0 then state.tick() end
      state.check(string.format("copying %s (%s of %s sent)", file.name, mb(state.sent * 3 / 4), mb(state.total * 3 / 4)))
    end
    state.tick()
    state.mark(string.format("sent %d requests for %s", n, file.name))
    while true do
      local got, uid = screen():match("REXFP%-OK (%x+) (%d+)")
      if got then
        if got ~= file.sha then fail("checksum mismatch for " .. file.name) end
        return remote_path(uid), false
      end
      state.check("waiting for the remote file")
      sleep(0.05)
    end
  end)
  api.call("block.close", { session_id = session_id, block_id = block_id })
  if not ok then error(path, 0) end
  return path, cached
end

-- The worker body: runs a job file written by M.paste. Writes the result
-- next to it, as JOB.result.json, and returns it.
function M.run_job(job_path)
  local job = rex.json.decode(read_file(job_path) or "") or fail("cannot read " .. job_path)
  for k, v in pairs(job.options or {}) do M.options[k] = v end
  local started = now()
  local trace = {}
  local function mark(label) trace[#trace + 1] = { label = label, seconds = now() - started } end
  local bar
  local ok, result = pcall(function()
    local api = rex.server(job.host)
    api.call("session.attach", { session_id = job.session_id })
    bar = progress_bar(api, job.session_id, job.block_id)
    local files, total, bytes = {}, 0, 0
    for i, e in ipairs(job.entries) do
      files[i] = M.prepare(e)
      bytes = bytes + files[i].size
      total = total + 4 * math.ceil(files[i].size / 3)
    end
    mark("prepared")
    if bytes > M.options.max_size_mb * MiB then
      fail(string.format("refused: %s to copy, more than the limit of %d MiB", mb(bytes), M.options.max_size_mb))
    end
    local seconds = M.options.timeout + bytes / (M.options.min_rate_mb * MiB)
    local stop = os.time() + math.ceil(seconds)
    local state = { sent = 0, total = total, deadline = started + seconds }
    local last_tick = 0
    state.mark = mark
    -- os.time() costs nothing; now() starts a process, so it is kept for ticks.
    function state.check(doing)
      if os.time() >= stop then
        fail(string.format("gave up %s after %ds", doing, math.floor(seconds)))
      end
    end
    -- Each update is one more request, so update about once a second.
    local started_s = os.time()
    function state.tick()
      local t = os.time()
      if t - started_s < M.options.progress_after or t - last_tick < 1 or total == 0 then return end
      last_tick = t
      bar.update(state.sent / total, string.format("%s / %s", mb(state.sent * 3 / 4), mb(total * 3 / 4)))
    end
    local paths, cached = {}, {}
    for i, f in ipairs(files) do
      paths[i], cached[i] = upload(api, job.session_id, f, state)
      mark("copied " .. f.name .. (cached[i] and " (already there)" or ""))
    end
    if bar.opened then
      bar.update(1, "done")
      state.program_status = bar.screen()
    end
    paste_text(api, job.session_id, job.block_id, join_paths(paths))
    mark("pasted")
    return { ok = true, pasted = "paths", paths = paths, cached = cached, bytes = bytes,
      timeout = seconds, progress = bar.opened or false, progress_line = bar.last,
      program_status = state.program_status }
  end)
  if bar then bar.close() end
  if not ok then
    result = { ok = false, error = tostring(result) }
    notify(result.error)
  end
  result.trace = trace
  result.seconds = now() - started
  result.host = job.host
  write_file(job_path:gsub("%.json$", "") .. ".result.json", rex.json.encode(result))
  os.remove(job_path)
  return result
end

function M.setup(opts)
  local known = { pasteboard = true, rex_path = true }
  for k in pairs(M.options) do known[k] = true end
  for k, v in pairs(opts or {}) do
    if known[k] then
      M.options[k] = v
    else
      rex.log("warn", "rex-file-paste: ignoring unknown option " .. tostring(k))
    end
  end
  rex.action{
    name = "file_paste",
    title = "Paste Files as Paths",
    description = "Paste the clipboard's files or image as shell-quoted paths. In a pane on another server, the files are copied there first.",
    category = "Clipboard",
    keywords = "clipboard file image screenshot pdf document upload path agent",
    run = function(ctx) return M.paste(ctx) end,
  }
  if M.options.key then rex.bind(M.options.key, "file_paste") end
  return M
end

return M
