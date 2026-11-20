-- The background half of rex-file-paste. The file_paste action starts it as
--   rex do worker.lua job=JOB.json
-- because a configuration action may run for 30 seconds only, and a copy can
-- take longer. A `rex do` script has no such limit. The worker starts itself
-- again as `rex do worker.lua part=SPEC.json` to send a large file in parts.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
local M = dofile(dir .. "/init.lua")

if rex.args.part then
  local ok, err = pcall(M.run_part, rex.args.part)
  if not ok then
    rex.log("error", tostring(err))
    rex.stop(1)
  end
  rex.stop(0)
end

local job = rex.args.job
if not job then
  rex.log("error", "usage: rex do worker.lua job=JOB.json")
  rex.stop(2)
end
local result = M.run_job(job)
rex.log(result.ok and "info" or "error", os.date("%Y-%m-%d %H:%M:%S ") .. rex.json.encode(result))
rex.stop(result.ok and 0 or 1)
