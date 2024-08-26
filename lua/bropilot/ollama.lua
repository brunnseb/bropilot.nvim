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
  local check_job = curl.get(opts.ollama_url .. "/tags", {
    callback = function(data)
      async.util.scheduler(function()
        util.finish_progress(find_progress_handle)
        local body = vim.json.decode(data.body)
        for _, v in ipairs(body.models) do
          if v.name == opts.model then
            cb(true)
            return
          end
        end
        cb(false)
      end)
    end,
  })
  check_job:start()
end

---@param cb function | nil
local function pull_model(cb)
  local opts = options.get()

  local pull_progress_handle =
    util.get_progress_handle("Pulling model " .. opts.model)
  local pull_job = curl.post(opts.ollama_url .. "/pull", {
    body = vim.json.encode({ name = opts.model }),
    on_error = function(err)
      if err.code ~= nil then
        vim.notify(err.message)
      end
    end,
    stream = function(err, data)
      async.util.scheduler(function()
        if err then
          vim.notify(err, vim.log.levels.ERROR)
        end
        local body = vim.json.decode(data)
        if pull_progress_handle ~= nil then
          if body.error then
            vim.notify(body.error, vim.log.levels.ERROR)
            util.finish_progress(pull_progress_handle)
          elseif body.status == "success" then
            util.finish_progress(pull_progress_handle)

            if cb then
              cb()
            end
          else
            local report = { message = "", percentage = 100 }
            if body.status then
              report.message = body.status
            end
            if body.completed ~= nil and body.total ~= nil then
              report.percentage = body.completed / body.total * 100
            end
            pull_progress_handle:report(report)
          end
        else
          if body.error then
            vim.notify(body.error, vim.log.levels.ERROR)
          elseif body.status == "success" then
            vim.notify(
              "Pulled model " .. opts.model .. " successfully!",
              vim.log.levels.INFO
            )

            if cb then
              cb()
            end
          else
            local report = { message = "", percentage = 100 }
            if body.status then
              report.message = body.status
            end
            if body.completed ~= nil and body.total ~= nil then
              report.percentage = body.completed / body.total * 100
            end
            vim.notify(
              "Pulling model: "
                .. report.message
                .. " ("
                .. report.percentage
                .. "%)",
              vim.log.levels.INFO
            )
          end
        end
      end)
    end,
  })
  pull_job:start()
end

local function preload_model()
  local opts = options.get()

  local preload_progress_handle =
    util.get_progress_handle("Preloading " .. opts.model)
  local preload_job = curl.post(opts.ollama_url .. "/generate", {
    body = vim.json.encode({
      model = opts.model,
    }),
    callback = function()
      async.util.scheduler(function()
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
      end)
    end,
  })
  preload_job:start()
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
      if init_callback then
        init_callback()
      else
        preload_model()
      end
    else
      pull_model(function()
        if init_callback then
          init_callback()
        else
          preload_model()
        end
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
  local suggestion_job = curl.post(opts.ollama_url .. "/generate", {
    body = vim.json.encode({
      model = opts.model,
      options = opts.model_params,
      prompt = prompt,
    }),
    on_error = function(err)
      if current_suggestion_pid ~= suggestion_job_pid then
        cancel(suggestion_job_pid)
        return
      end

      if err.message ~= nil then
        vim.notify(err.message, vim.log.levels.ERROR)
      end
    end,
    stream = function(err, data)
      if current_suggestion_pid ~= suggestion_job_pid then
        cancel(suggestion_job_pid)
        return
      end

      async.util.scheduler(function()
        if err then
          vim.notify(err, vim.log.levels.ERROR)
        end

        if data == nil or type(data) ~= "string" then
          return
        end

        local success, body = pcall(vim.json.decode, data)
        if not success then
          util.finish_progress(suggestion_progress_handle)
          current_suggestion_pid = nil
          cb(true)
          return
        end
        if body.done then
          util.finish_progress(suggestion_progress_handle)
          current_suggestion_pid = nil
          cb(true)
          return
        end

        cb(false, body.response)
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
