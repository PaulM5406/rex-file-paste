-- The background half of rex-file-paste. The file_paste action starts it as
--   rex do worker.lua job=JOB.json
-- because a configuration action may run for 30 seconds only, and a copy can
-- take longer. A `rex do` script has no such limit.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
local M = dofile(dir .. "/init.lua")
local job = rex.args.job
if not job then
  rex.log("error", "usage: rex do worker.lua job=JOB.json")
  rex.stop(2)
end
local result = M.run_job(job)
rex.log(result.ok and "info" or "error", os.date("%Y-%m-%d %H:%M:%S ") .. rex.json.encode(result))
rex.stop(result.ok and 0 or 1)
