-- End-to-end test. Run from a Rex terminal on the Mac:
--
--   rex do test/e2e.lua                        # every case, a pane on this server
--   rex do test/e2e.lua host=LABEL             # every case, a pane on another server
--   rex do test/e2e.lua host=LABEL kind=pdf    # one case
--
-- kind is all (the default) or one of: pdf, docx, name, two, big, over,
-- text, folder, ctrl, tab, image, heic, cleanup (remote only).
-- work=DIR puts the test files there (default: $TMPDIR/rex-file-paste-test).
-- keep=1 keeps them.
--
-- The test uses a private pasteboard, so it never changes your clipboard.
-- Locally it pastes into a hidden terminal. On another server it creates a
-- session of its own with one terminal, so the progress bar has a window to
-- show in. It closes both, and deletes the copied files, at the end.

local root = debug.getinfo(1, "S").source:match("^@?(.*)/test/[^/]+$") or "."
local M = dofile(root .. "/init.lua")

local SHELL = "com.superlogical.terminal.shell"
local host = rex.args.host
local only = rex.args.kind or "all"
local work = rex.args.work or ((os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/rex-file-paste-test")
local keep = rex.args.keep
local failed = false

M.options.pasteboard = "rex-file-paste-test"
M.options.local_dir = work .. "/local"
M.options.module_dir = root
M.options.notify = false

local SEED_JS = [=[
ObjC.import('AppKit');
function run(argv) {
  const [name, kind] = argv;
  const pb = $.NSPasteboard.pasteboardWithName(name);
  pb.clearContents;
  if (kind === 'files') {
    const urls = [];
    for (let i = 2; i < argv.length; i++) urls.push($.NSURL.fileURLWithPath(argv[i]));
    pb.writeObjects($(urls));
  } else if (kind === 'png') pb.setDataForType($.NSData.dataWithContentsOfFile(argv[2]), $.NSPasteboardTypePNG);
  else if (kind === 'text') pb.setStringForType(argv[2], $.NSPasteboardTypeString);
  else throw new Error('kind must be files, png, or text');
  return 'ok';
}
]=]

local function log(...) rex.log(string.format(...)) end

local function check(cond, message)
  if not cond then
    rex.log("error", "  FAIL: " .. message)
    failed = true
  end
  return cond
end

local function sh(script, ...)
  local r = rex.exec({ "sh", "-c", script, "e2e", ... })
  assert(r and r.ok, "command failed: " .. script .. ": " .. (r and r.stderr or "?"))
  return r.stdout
end

local function sha(path)
  return (sh('shasum -a 256 < "$1"', path):match("^(%x+)"))
end

local function printable(s)
  return (s:gsub("[%c]", function(c) return string.format("\\x%02x", c:byte()) end))
end

-- Test files ----------------------------------------------------------------

local src = work .. "/src"
local F = {
  pdf = src .. "/report.pdf",
  docx = src .. "/note.docx",
  name = src .. "/Rapport d'été — n°2 (final).pdf",
  csv = src .. "/data.csv",
  big = src .. "/big-20MB.bin",
  over = src .. "/over-30MiB.bin",
  folder = src .. "/Un dossier",
  ctrl = src .. "/bad\nname.txt",
  tab = src .. "/tab\tname.txt",
  png = src .. "/large.png",
  heic = src .. "/photo.heic",
}

local function pdf_text(line)
  local body = "BT /F1 18 Tf 72 720 Td (" .. line .. ") Tj ET"
  return table.concat({
    "%PDF-1.4",
    "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj",
    "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
    "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj",
    "4 0 obj << /Length " .. #body .. " >> stream", body, "endstream endobj",
    "5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj",
    "trailer << /Root 1 0 R >>", "%%EOF", "",
  }, "\n")
end

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function make_files()
  sh('rm -rf "$1" && mkdir -p "$1"', src)
  write(F.pdf, pdf_text("rex-file-paste test report"))
  write(F.name, pdf_text("Rapport d'ete numero 2"))
  write(F.csv, "name,value\nalpha,1\nbeta,2\n")
  write(src .. "/note.txt", "Une note de test pour rex-file-paste.\n")
  sh('textutil -convert docx "$1" -output "$2"', src .. "/note.txt", F.docx)
  sh('head -c 20000000 /dev/urandom > "$1"', F.big)
  sh('mkfile -n 30m "$1"', F.over)
  sh('mkdir -p "$1" && echo inside > "$1/inside.txt"', F.folder)
  write(F.ctrl, "control\n")
  write(F.tab, "tab\n")
  local icon = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"
  sh('sips -s format png "$1" --out "$2" >/dev/null && sips -z 3000 3000 "$2" >/dev/null', icon, F.png)
  sh('sips -s format heic "$1" --out "$2" >/dev/null', F.png, F.heic)
end

-- The target pane -------------------------------------------------------------

-- A terminal that turns on bracketed paste and echoes what it receives.
local TARGET = { "sh", "-c", [[printf '\033[?2004h'; cat]] }

local api, session_id, target, own_session
if host then
  api = rex.server(host)
  local created = assert(api.call("session.create", {
    label = "rex-file-paste-test",
    initial_windows = { {
      window_label = "target",
      layout = rex.layout.block{ flavor = SHELL, options = { shell = "none", command = TARGET,
        size = { columns = 300, rows = 40 } } },
    } },
  }))
  session_id = created.session_id
  own_session = true
  target = created.initial_windows[1].block_ids[1]
  assert(api.call("session.attach", { session_id = session_id }))
else
  api, session_id = rex, rex.session_id
  target = assert(api.call("session.new_block", {
    session_id = session_id, flavor = SHELL, label = "rex-file-paste-test",
    options = { shell = "none", command = TARGET, size = { columns = 300, rows = 40 } },
  })).block_id
end
rex.sleep(0.5)

local function screen()
  local s = api.call("block.method", {
    session_id = session_id, block_id = target, method = "format", args = { trim = true, unwrap = true },
  })
  return s and s.content or ""
end

local function paste_count()
  local n = 0
  for _ in screen():gmatch("%^%[%[200~") do n = n + 1 end
  return n
end

local function last_paste()
  local text
  for t in screen():gmatch("%^%[%[200~(.-)%^%[%[201~") do text = t end
  return text
end

-- Runs argv in a hidden terminal on the remote server and returns its screen
-- once it prints END.
local function remote_run(argv)
  local b = assert(api.call("session.new_block", {
    session_id = session_id, flavor = SHELL, label = "rex-file-paste-test",
    options = { shell = "none", command = argv, size = { columns = 300, rows = 50 } },
  })).block_id
  local text = ""
  for _ = 1, 200 do
    local s = api.call("block.method", { session_id = session_id, block_id = b, method = "format",
      args = { trim = true, unwrap = true } })
    text = s and s.content or ""
    if text:find("\nEND") or text:find("^END") then break end
    rex.sleep(0.05)
  end
  api.call("block.close", { session_id = session_id, block_id = b })
  return text
end

-- Reads the pasted text the way a shell does and prints a checksum for each
-- path, and the mode of the directory two levels up.
local INTERPRET = [[
eval "set -- $1" || echo EVAL-FAILED
for f do
  if [ -f "$f" ]; then
    s=$({ sha256sum 2>/dev/null || shasum -a 256; } < "$f" | cut -c1-64)
    m=$(stat -c %a "${f%/*/*}" 2>/dev/null || stat -f %Lp "${f%/*/*}")
    printf 'SUM %s %s\n' "$s" "$m"
  else
    echo MISSING
  fi
done
echo END
sleep 20
]]

local function interpret(text)
  local outs = {}
  if host then
    outs.sh = remote_run({ "sh", "-c", INTERPRET, "check", text })
    outs.bash = remote_run({ "bash", "-c", INTERPRET, "check", text })
  else
    local script = INTERPRET:gsub("sleep 20\n", "")
    outs.sh = rex.exec({ "sh", "-c", script, "check", text }).stdout
    outs.zsh = rex.exec({ "zsh", "-c", script, "check", text }).stdout
  end
  return outs
end

local job_seen = {}

local function wait_job(result)
  if result.pasted ~= "pending" then return result end
  local res_path = result.job:gsub("%.json$", "") .. ".result.json"
  for _ = 1, 1200 do
    local f = io.open(res_path)
    if f then
      local text = f:read("*a")
      f:close()
      job_seen[#job_seen + 1] = res_path
      return rex.json.decode(text)
    end
    rex.sleep(0.1)
  end
  return { ok = false, error = "the worker wrote no result in 120 s" }
end

local function seed(kind, ...)
  local r = rex.exec({ "osascript", "-l", "JavaScript", "-e", SEED_JS, M.options.pasteboard, kind, ... })
  assert(r and r.ok, "could not seed the test pasteboard: " .. (r and r.stderr or "?"))
end

local remote_keys = {}

local function remember(paths)
  for _, p in ipairs(paths or {}) do
    local dir = p:match("^(/tmp/rex%-file%-paste%-%d+/%x+)/")
    if dir then remote_keys[dir] = true end
  end
end

-- Pastes and checks that each pasted path, read by a shell, is a file with
-- the expected checksum. expect(paths) returns the expected checksums.
local function expect_paste(label, expect, more)
  local before = paste_count()
  local t0 = os.time()
  local ok, result = pcall(M.paste, { server = host, session_id = session_id, block_id = target })
  if not check(ok, label .. ": " .. tostring(result)) then return nil end
  log("  action returned: %s", rex.json.encode(result))
  result = wait_job(result)
  if result.trace then log("  worker result: %s", rex.json.encode(result)) end
  if not check(result.ok ~= false, label .. ": " .. tostring(result.error)) then return nil end
  check(result.pasted == "paths", label .. ": pasted " .. tostring(result.pasted))
  remember(result.paths)
  for _ = 1, 50 do
    if paste_count() > before then break end
    rex.sleep(0.1)
  end
  local text = last_paste()
  if not check(paste_count() == before + 1 and text, label .. ": the pane received no bracketed paste") then
    return result
  end
  log("  pasted text: %s", printable(text))
  local want = expect(result.paths)
  for shell, out in pairs(interpret(text)) do
    log("  %s reads it as:\n%s", shell, out)
    local sums = {}
    for s, m in out:gmatch("SUM (%x+) (%d+)") do
      sums[#sums + 1] = s
      if host then check(m == "700", label .. ": the remote directory has mode " .. m) end
    end
    check(not out:find("MISSING") and not out:find("EVAL%-FAILED"), label .. ": " .. shell .. " can't find a pasted file")
    check(#sums == #want, string.format("%s: %s found %d files, expected %d", label, shell, #sums, #want))
    for i = 1, #want do
      check(sums[i] == want[i], string.format("%s: %s: file %d has checksum %s, expected %s",
        label, shell, i, tostring(sums[i]), want[i]))
    end
  end
  log("  expected checksums: %s", table.concat(want, " "))
  if more then more(result) end
  -- End the line so the next paste starts on a new one.
  api.call("block.method", { session_id = session_id, block_id = target, method = "write", args = { data = "\r" } })
  log("  elapsed: %ds", os.time() - t0)
  return result
end

local function expect_refusal(label, pattern)
  local before = paste_count()
  local ok, result = pcall(M.paste, { server = host, session_id = session_id, block_id = target })
  log("  action: ok=%s, %s", tostring(ok), ok and rex.json.encode(result) or printable(tostring(result)))
  if ok and result.pasted == "pending" then
    result = wait_job(result)
    log("  worker result: %s", rex.json.encode(result))
    ok = result.ok
    result = result.error
  end
  check(not ok, label .. ": the paste was not refused")
  check(not ok and tostring(result):find(pattern), label .. ": unexpected message: " .. tostring(result))
  rex.sleep(1)
  check(paste_count() == before, label .. ": something was pasted")
end

local function sources(...)
  local list = { ... }
  return function() local s = {} for i, p in ipairs(list) do s[i] = sha(p) end return s end
end

-- Checksums of the files the Mac prepared: the pasted remote path ends in
-- KEY/NAME, and the Mac keeps the converted file at local_dir/KEY/NAME.
local function prepared(fallback)
  return function(paths)
    local s = {}
    for i, p in ipairs(paths) do
      local key, name = p:match("/(%x+)/([^/]+)$")
      local mine = M.options.local_dir .. "/" .. (key or "") .. "/" .. (name or "")
      local f = io.open(mine)
      if f then f:close() s[i] = sha(mine) else s[i] = sha(fallback or p) end
    end
    return s
  end
end

local function max_edge(path)
  local out = sh('sips -g pixelWidth -g pixelHeight "$1"', path)
  return math.max(tonumber(out:match("pixelWidth: (%d+)")) or 0, tonumber(out:match("pixelHeight: (%d+)")) or 0)
end

-- Cases -------------------------------------------------------------------------

local CASES = {}
local ORDER = {}
local function case(name, fn) CASES[name] = fn; ORDER[#ORDER + 1] = name end

case("pdf", function()
  seed("files", F.pdf)
  local first = expect_paste("pdf", sources(F.pdf))
  local again = expect_paste("pdf again", sources(F.pdf))
  if host and again and again.cached then
    check(again.cached[1] == true, "pdf again: the file was copied again")
    check(first and again.paths[1] == first.paths[1], "pdf again: another path")
  end
end)

case("docx", function()
  seed("files", F.docx)
  expect_paste("docx", sources(F.docx), function(r)
    if host then check(r.paths[1]:match("/note%.docx$"), "docx: name not kept: " .. r.paths[1]) end
  end)
end)

case("name", function()
  seed("files", F.name)
  expect_paste("name", sources(F.name), function(r)
    -- Locally the pasted path is the one macOS gives, often decomposed
    -- (NFD); the shell check above shows it names the file. A copy keeps
    -- the name in composed form (NFC), as written here.
    if host then check(r.paths[1]:sub(-#"Rapport d'été — n°2 (final).pdf") == "Rapport d'été — n°2 (final).pdf",
      "name: name not kept: " .. r.paths[1]) end
  end)
end)

case("two", function()
  seed("files", F.pdf, F.csv)
  expect_paste("two", sources(F.pdf, F.csv), function(r)
    check(#r.paths == 2, "two: " .. #r.paths .. " paths")
  end)
end)

case("big", function()
  seed("files", F.big)
  expect_paste("big", sources(F.big), function(r)
    if host then
      log("  20 MB copy: %.2fs in the worker, timeout %.0fs, progress bar %s, last line: %s",
        r.seconds or -1, r.timeout or -1, tostring(r.progress), tostring(r.progress_line))
      log("  program_status of the progress terminal: %s", rex.json.encode(r.program_status or {}))
      check(r.progress == true, "big: no progress bar")
    end
  end)
end)

case("over", function()
  seed("files", F.over)
  if host then
    expect_refusal("over", "more than the limit of 25 MiB")
  else
    -- Design: a local pane gets the original path; nothing is copied, so
    -- the copy limit doesn't apply.
    expect_paste("over (local)", sources(F.over))
  end
end)

case("text", function()
  seed("text", "echo one\necho two")
  local before = paste_count()
  local ok, result = pcall(M.paste, { server = host, session_id = session_id, block_id = target })
  log("  action: ok=%s, %s", tostring(ok), ok and rex.json.encode(result) or tostring(result))
  check(ok and result.pasted == "nothing", "text: " .. tostring(ok and result.pasted or result))
  rex.sleep(1)
  check(paste_count() == before and not screen():find("echo one", 1, true), "text: the pane received the text")
end)

case("folder", function()
  seed("files", F.folder)
  expect_refusal("folder", "is a folder")
end)

case("ctrl", function()
  seed("files", F.ctrl)
  expect_refusal("ctrl", "control character or a line break")
end)

case("tab", function()
  seed("files", F.tab)
  expect_refusal("tab", "control character or a line break")
end)

case("image", function()
  seed("png", F.png)
  expect_paste("image", prepared(), function(r)
    check(r.paths[1]:match("/clipboard%-image%.png$"), "image: unexpected name " .. r.paths[1])
    local key, name = r.paths[1]:match("/(%x+)/([^/]+)$")
    local mine = host and (M.options.local_dir .. "/" .. key .. "/" .. name) or r.paths[1]
    local edge = max_edge(mine)
    log("  long edge after preparation: %d px (source: %d px)", edge, max_edge(F.png))
    check(edge <= 2000, "image: not shrunk")
  end)
end)

case("heic", function()
  seed("files", F.heic)
  if host then
    expect_paste("heic", prepared(), function(r)
      check(r.paths[1]:match("/photo%.png$"), "heic: not converted to PNG: " .. r.paths[1])
    end)
  else
    -- Design: a local pane gets the original path, unconverted.
    expect_paste("heic (local)", sources(F.heic))
  end
end)

case("cleanup", function()
  if not host then log("  remote only, skipped") return end
  local uid = remote_run({ "sh", "-c", 'echo "UID $(id -u)"; echo END; sleep 20' }):match("UID (%d+)")
  local d = "/tmp/rex-file-paste-" .. uid
  local old = d .. "/00000000000000000000000000000000"
  local empty = d .. "/11111111111111111111111111111111"
  log("  %s", remote_run({ "sh", "-c", [[umask 077; mkdir -p "$1" "$2" "$3" && echo old > "$1/old.txt" && touch -d '2 days ago' "$1/old.txt" && ls -la "$1" "$2"; echo END; sleep 20]], "x", old, empty, d }))
  seed("files", F.csv)
  expect_paste("cleanup", sources(F.csv))
  local out = remote_run({ "sh", "-c", [[for p do if [ -e "$p" ]; then echo "STILL $p"; else echo "GONE $p"; fi; done; echo END; sleep 20]], "x", old .. "/old.txt", old, empty })
  log("  %s", out)
  check(not out:find("STILL"), "cleanup: old files or empty directories remain")
end)

-- Run -----------------------------------------------------------------------------

log("rex-file-paste e2e: host=%s kind=%s work=%s", tostring(host or "local"), only, work)
make_files()
for _, name in ipairs(ORDER) do
  if only == "all" or only == name then
    log("CASE %s (%s)", name, host and ("pane on " .. host) or "local pane")
    local before = failed
    failed = false
    local ok, err = pcall(CASES[name])
    if not ok then check(false, name .. ": " .. tostring(err)) end
    log("CASE %s: %s", name, failed and "FAIL" or "PASS")
    failed = failed or before
  end
end

-- Clean up.
if host then
  local dirs = {}
  for d in pairs(remote_keys) do dirs[#dirs + 1] = d end
  if #dirs > 0 then
    log("removing on %s: %s", host, table.concat(dirs, " "))
    log("%s", remote_run({ "sh", "-c", [[rm -rf -- "$@"; d=${1%/*}; rmdir "$d" 2>/dev/null; ls -la "$d" 2>&1 | head -5; echo END; sleep 20]], "x", unpack(dirs) }))
  end
  if own_session then api.call("session.destroy", { session_id = session_id }) end
else
  api.call("block.close", { session_id = session_id, block_id = target })
end
local wlog = io.open(M.options.local_dir .. "/worker.log")
if wlog then
  if failed then log("worker log:\n%s", wlog:read("*a")) end
  wlog:close()
end
if not keep then sh('rm -rf "$1"', work) end
rex.log(failed and "e2e: FAILED" or "e2e: passed")
rex.stop(failed and 1 or 0)
