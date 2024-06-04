local llm = require("bropilot.llm")
local util = require("bropilot.util")

local M = {}

---@type Options
M.opts = {
  model = "codegemma:2b-code",
  model_params = {
    -- https://github.com/ollama/ollama/blob/main/docs/modelfile.md#valid-parameters-and-values
    mirostat = 0,
    mirostat_eta = 0.1,
    mirostat_tau = 5.0,
    num_ctx = 2048,
    repeat_last_n = 64,
    repeat_penalty = 1.1,
    temperature = 0.8,
    seed = 0,
    stop = {},
    tfs_z = 1,
    num_predict = 128,
    top_k = 40,
    top_p = 0.9,
  },
  prompt = {
    prefix = "<|fim_prefix|>",
    suffix = "<|fim_suffix|>",
    middle = "<|fim_middle|>",
  },
  max_blocks = 1,
  debounce = 1000,
  auto_pull = true,
}

vim.api.nvim_create_autocmd({ "InsertEnter" }, {
  callback = function()
    llm.suggest()
  end,
})

vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
  callback = function()
    local row = util.get_cursor()
    local context_row = llm.get_context_row()

    if row == context_row then
      local current_line = util.get_lines(row - 1, row)[1]
      local context_line = llm.get_context_line()

      local current_suggestion = llm.get_suggestion()
      local suggestion_lines = vim.split(current_suggestion, "\n")

      local current_line_contains_suggestion = string.find(
        vim.pesc(context_line .. suggestion_lines[1]),
        vim.pesc(current_line)
      )

      if current_line_contains_suggestion then
        llm.render_suggestion()
        return
      end
    end

    llm.cancel()
    llm.clear()

    llm.suggest()
  end,
})

vim.api.nvim_create_autocmd({ "InsertLeave" }, {
  callback = function()
    llm.cancel()
    llm.clear()
  end,
})

M.accept_word = llm.accept_word
M.accept_line = llm.accept_line
M.accept_block = llm.accept_block

---@param opts Options
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

  -- setup options (model, prompt, keep_alive, params, etc...)
  llm.init(M.opts, function()
    local mode = vim.api.nvim_get_mode()

    if mode == "i" or mode == "r" then
      llm.suggest()
    end
  end)
end

return M
