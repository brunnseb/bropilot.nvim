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

---@param cb function
local function find_model(cb)
  local opts = options.get()

  local find_progress_handle =
    util.get_progress_handle("Finding model " .. opts.model)
  local check_job = curl.get(opts.ollama_url .. "/models", {
    headers = {
      ["x-api-key"] = "e79fc6f6e89fe2072e20be5a91d57b67",
    },
    callback = function(data)
      async.util.scheduler(function()
        util.finish_progress(find_progress_handle)
        local body = vim.json.decode(data.body)
        for _, v in ipairs(body.data) do
          if v.id == opts.model then
            cb(true)
            return
          end
        end
        cb(false)
      end)
    end,
  })
  --   check_job:start()
end
--
-- ---@param cb function | nil
-- local function pull_model(cb)
--   local opts = options.get()
--
--   local pull_progress_handle =
--     util.get_progress_handle("Pulling model " .. opts.model)
--   local pull_job = curl.post(opts.ollama_url .. "/pull", {
--     body = vim.json.encode({ name = opts.model }),
--     on_error = function(err)
--       if err.code ~= nil then
--         vim.notify(err.message)
--       end
--     end,
--     stream = function(err, data)
--       async.util.scheduler(function()
--         if err then
--           vim.notify(err, vim.log.levels.ERROR)
--         end
--         local body = vim.json.decode(data)
--         if pull_progress_handle ~= nil then
--           if body.error then
--             vim.notify(body.error, vim.log.levels.ERROR)
--             util.finish_progress(pull_progress_handle)
--           elseif body.status == "success" then
--             util.finish_progress(pull_progress_handle)
--
--             if cb then
--               cb()
--             end
--           else
--             local report = { message = "", percentage = 100 }
--             if body.status then
--               report.message = body.status
--             end
--             if body.completed ~= nil and body.total ~= nil then
--               report.percentage = body.completed / body.total * 100
--             end
--             pull_progress_handle:report(report)
--           end
--         else
--           if body.error then
--             vim.notify(body.error, vim.log.levels.ERROR)
--           elseif body.status == "success" then
--             vim.notify(
--               "Pulled model " .. opts.model .. " successfully!",
--               vim.log.levels.INFO
--             )
--
--             if cb then
--               cb()
--             end
--           else
--             local report = { message = "", percentage = 100 }
--             if body.status then
--               report.message = body.status
--             end
--             if body.completed ~= nil and body.total ~= nil then
--               report.percentage = body.completed / body.total * 100
--             end
--             vim.notify(
--               "Pulling model: "
--                 .. report.message
--                 .. " ("
--                 .. report.percentage
--                 .. "%)",
--               vim.log.levels.INFO
--             )
--           end
--         end
--       end)
--     end,
--   })
--   -- pull_job:start()
-- end
--
---@param cb function
local function preload_model(cb)
  local opts = options.get()

  local body = vim.json.encode({
    ["model_name"] = opts.model,
    -- max_seq_len = 4096,
    -- cache_size = 4096,
    -- tensor_parallel = true,
    -- gpu_split_auto = true,
    -- autosplit_reserve = {
    --   0,
    -- },
    -- gpu_split = {
    --   24,
    --   20,
    -- },
    -- rope_scale = 1,
    -- rope_alpha = 1,
    -- cache_mode = "",
    -- chunk_size = 0,
    -- prompt_template = "",
    -- vision = true,
    -- num_experts_per_token = 0,
    -- draft_model = {
    --   draft_model_name = "",
    --   draft_rope_scale = 0,
    --   draft_rope_alpha = 1,
    --   draft_cache_mode = "",
    -- },
    -- skip_queue = false,
  })

  local preload_progress_handle =
    util.get_progress_handle("Preloading " .. opts.model)
  local preload_job = curl.post(opts.ollama_url .. "/model/load", {
    headers = {
      ["x-admin-key"] = "e79fc6f6e89fe2072e20be5a91d57b67",
      ["Content-Type"] = "application/json",
    },
    body = body,
    callback = function(data, err)
      async.util.scheduler(function()
        -- local body = vim.json.decode(data.body)

        if preload_progress_handle ~= nil then
          preload_progress_handle:finish()
          preload_progress_handle = nil
        else
          vim.notify(
            "Preloaded model " .. opts.model .. " successfully!",
            vim.log.levels.INFO
          )
        end
        ready = true
        initializing = false
        cb()
      end)
    end,
  })
  --   -- preload_job:start()
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
  find_model(function(found)
    if found then
      preload_model(function()
        if init_callback then
          init_callback()
        end
      end)
    else
      pull_model(function()
        preload_model(function()
          if init_callback then
            init_callback()
          end
        end)
      end)
    end
  end)
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
  local body = vim.json.encode({
    -- model = opts.model,
    -- options = opts.model_params,
    prompt = prompt,
  })
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
        -- vim.notify(
        --   "res: " .. vim.inspect(res.choices[1]),
        --   nil,
        --   { title = "🪚 res", ft = "lua" }
        -- )
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

        -- cb(false, res.response)
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
