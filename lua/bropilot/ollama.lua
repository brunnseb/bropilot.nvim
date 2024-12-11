local async = require("plenary.async")
local curl = require("plenary.curl")

local util = require("bropilot.util")
local options = require("bropilot.options")

---@type boolean
local ready = false
---@type boolean
local initializing = false

local current_suggestion_pid = nil
local suggestion_handles = {}

local function is_ready()
  return not initializing and ready
end

---@type function | nil
local init_callback = nil
---@param cb function | nil
local function init(cb)
  init_callback = cb
  if ready or initializing then
    return
  end
  initializing = true

  if init_callback then
    init_callback()
  end
end

---@param pid number | nil
local function cancel(pid)
  if not is_ready() then
    init()
  end

  if pid == nil then
    pid = current_suggestion_pid
  end

  if pid and suggestion_handles[pid] then
    local job = suggestion_handles[pid].job
    local progress = suggestion_handles[pid].progress

    job:shutdown()
    util.finish_progress(progress)

    current_suggestion_pid = nil
  end
end

local function generate(prompt, cb)
  local opts = options.get()

  local suggestion_progress_handle = util.get_progress_handle("Suggesting...")
  local suggestion_job_pid = nil
  local body = vim.json.encode(
    vim.tbl_deep_extend("force", { prompt = prompt }, opts.model_params)
  )
  vim.notify(vim.inspect(body), nil, { title = "🪚 body", ft = "lua" })
  local suggestion_job = curl.post(opts.ollama_url .. "/completions", {
    headers = {
      ["x-api-key"] = "e79fc6f6e89fe2072e20be5a91d57b67",
      ["Content-Type"] = "application/json",
    },
    body = body,
    on_error = function(err)
      if current_suggestion_pid ~= suggestion_job_pid then
        cancel(suggestion_job_pid)
        return
      end

      if err.message ~= nil then
        vim.notify(err.message, vim.log.levels.ERROR)
      end
    end,
    callback = function(data, err)
      if current_suggestion_pid ~= suggestion_job_pid then
        cancel(suggestion_job_pid)
        return
      end
      async.util.scheduler(function()
        if err then
          vim.notify(err, vim.log.levels.ERROR)
        end

        if data == nil then
          return
        end

        local success, res = pcall(vim.json.decode, data.body)
        if not success then
          util.finish_progress(suggestion_progress_handle)
          current_suggestion_pid = nil
          return
        end
        if res.choices[1].finish_reason == "stop" then
          util.finish_progress(suggestion_progress_handle)
          current_suggestion_pid = nil
          cb(res.choices[1].text)
          return
        end
      end)
    end,
  })
  suggestion_job_pid = suggestion_job.pid
  suggestion_handles[suggestion_job_pid] = {
    job = suggestion_job,
    progress = suggestion_progress_handle,
  }
  current_suggestion_pid = suggestion_job_pid
end

return {
  cancel = cancel,
  generate = generate,
  init = init,
  is_ready = is_ready,
}
