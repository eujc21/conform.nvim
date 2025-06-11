local M = {}

---Find a command in node_modules
---@param cmd string
---@return fun(ctx: conform.Context): string
M.from_node_modules = function(cmd)
  return M.find_executable({ "node_modules/.bin/" .. cmd }, cmd)
end

---Search parent directories for a relative path to a command
---@param paths string[]
---@param default string
---@return fun(self: conform.FormatterConfig, ctx: conform.Context): string
---@example
--- local cmd = require("conform.util").find_executable({ "node_modules/.bin/prettier" }, "prettier")
M.find_executable = function(paths, default)
  return function(self, ctx)
    for _, path in ipairs(paths) do
      local normpath = vim.fs.normalize(path)
      local is_absolute = vim.startswith(normpath, "/")
      if is_absolute and vim.fn.executable(normpath) then
        return normpath
      end

      local idx = normpath:find("/", 1, true)
      local dir, subpath
      if idx then
        dir = normpath:sub(1, idx - 1)
        subpath = normpath:sub(idx)
      else
        -- This is a bare relative-path executable
        dir = normpath
        subpath = ""
      end
      local results = vim.fs.find(dir, { upward = true, path = ctx.dirname, limit = math.huge })
      for _, result in ipairs(results) do
        local fullpath = result .. subpath
        if vim.fn.executable(fullpath) == 1 then
          return fullpath
        end
      end
    end

    return default
  end
end

---@param files string|string[]
---@return fun(self: conform.FormatterConfig, ctx: conform.Context): nil|string
M.root_file = function(files)
  return function(self, ctx)
    return vim.fs.root(ctx.dirname, files)
  end
end

M.does_hunk_overlap = function(hunk_a_start, hunk_a_end, hunk_b_start, hunk_b_end)
    if hunk_a_start > hunk_a_end or hunk_b_start > hunk_b_end then
        return false
    end
    return math.max(hunk_a_start, hunk_b_start) <= math.min(hunk_a_end, hunk_b_end)
end

---@param bufnr integer
---@param range conform.Range
---@return integer start_offset
---@return integer end_offset
M.get_offsets_from_range = function(bufnr, range)
  local row = range.start[1] - 1
  local end_row = range["end"][1] - 1
  local col = range.start[2]
  local end_col = range["end"][2]
  local start_offset = vim.api.nvim_buf_get_offset(bufnr, row) + col
  local end_offset = vim.api.nvim_buf_get_offset(bufnr, end_row) + end_col
  return start_offset, end_offset
end

---@generic T : any
---@param tbl T[]
---@param start_idx? number
---@param end_idx? number
---@return T[]
M.tbl_slice = function(tbl, start_idx, end_idx)
  local ret = {}
  if not start_idx then
    start_idx = 1
  end
  if not end_idx then
    end_idx = #tbl
  end
  for i = start_idx, end_idx do
    table.insert(ret, tbl[i])
  end
  return ret
end

---@generic T : fun()
---@param cb T
---@param wrapper T
---@return T
M.wrap_callback = function(cb, wrapper)
  return function(...)
    wrapper(...)
    cb(...)
  end
end

---Helper function to add to the default args of a formatter.
---@param args string|string[]|fun(self: conform.FormatterConfig, ctx: conform.Context): string|string[]
---@param extra_args string|string[]|fun(self: conform.FormatterConfig, ctx: conform.Context): string|string[]
---@param opts? { append?: boolean }
---@example
--- local util = require("conform.util")
--- local prettier = require("conform.formatters.prettier")
--- require("conform").formatters.prettier = vim.tbl_deep_extend("force", prettier, {
---   args = util.extend_args(prettier.args, { "--tab", "--indent", "2" }),
---   range_args = util.extend_args(prettier.range_args, { "--tab", "--indent", "2" }),
--- })
M.extend_args = function(args, extra_args, opts)
  opts = opts or {}
  return function(self, ctx)
    if type(args) == "function" then
      args = args(self, ctx)
    end
    if type(extra_args) == "function" then
      extra_args = extra_args(self, ctx)
    end
    if type(args) == "string" then
      if type(extra_args) ~= "string" then
        extra_args = table.concat(extra_args, " ")
      end
      if opts.append then
        return args .. " " .. extra_args
      else
        return extra_args .. " " .. args
      end
    else
      if type(extra_args) == "string" then
        error("extra_args must be a table when args is a table")
      end
      local ret = {}
      if opts.append then
        vim.list_extend(ret, args or {})
        vim.list_extend(ret, extra_args or {})
      else
        vim.list_extend(ret, extra_args or {})
        vim.list_extend(ret, args or {})
      end
      return ret
    end
  end
end

---@param formatter conform.FormatterConfig
---@param extra_args string|string[]|fun(self: conform.FormatterConfig, ctx: conform.Context): string|string[]
---@param opts? { append?: boolean }
---@example
--- local util = require("conform.util")
--- local prettier = require("conform.formatters.prettier")
--- util.add_formatter_args(prettier, { "--tab", "--indent", "2" })
M.add_formatter_args = function(formatter, extra_args, opts)
  formatter.args = M.extend_args(formatter.args, extra_args, opts)
  if formatter.range_args then
    formatter.range_args = M.extend_args(formatter.range_args, extra_args, opts)
  end
end

---@param config conform.FormatterConfig
---@param override conform.FormatterConfigOverride
---@return conform.FormatterConfig
M.merge_formatter_configs = function(config, override)
  local ret = vim.tbl_deep_extend("force", config, override)
  if override.prepend_args then
    M.add_formatter_args(ret, override.prepend_args, { append = false })
  elseif override.append_args then
    M.add_formatter_args(ret, override.append_args, { append = true })
  end
  return ret
end

---@param bufnr integer
---@return integer
M.buf_get_changedtick = function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return -2
  end
  local changedtick = vim.b[bufnr].changedtick
  -- changedtick gets set to -1 when vim is exiting. We have an autocmd that should store it in
  -- last_changedtick before it is set to -1.
  if changedtick == -1 then
    return vim.b[bufnr].last_changedtick or -1
  else
    return changedtick
  end
end

---Parse the rust edition from the Cargo.toml file
---@param dir string
---@return string?
M.parse_rust_edition = function(dir)
  local manifest = vim.fs.find("Cargo.toml", { upward = true, path = dir })[1]
  if manifest then
    for line in io.lines(manifest) do
      if line:match("^edition *=") then
        local edition = line:match("%d+")
        if edition then
          return edition
        end
      end
    end
  end
end

---@param cmd string
---@return string[]
M.shell_build_argv = function(cmd)
  local argv = {}

  -- If the shell starts with a quote, it contains spaces (from :help 'shell').
  -- The shell may also have additional arguments in it, separated by spaces.
  if vim.startswith(vim.o.shell, '"') then
    local quoted = vim.o.shell:match('^"([^"]+)"')
    table.insert(argv, quoted)
    vim.list_extend(argv, vim.split(vim.o.shell:sub(quoted:len() + 3), "%s+", { trimempty = true }))
  else
    vim.list_extend(argv, vim.split(vim.o.shell, "%s+"))
  end

  vim.list_extend(argv, vim.split(vim.o.shellcmdflag, "%s+", { trimempty = true }))

  if vim.o.shellxquote ~= "" then
    -- When shellxquote is "(", we should escape the shellxescape characters with '^'
    -- See :help 'shellxescape'
    if vim.o.shellxquote == "(" and vim.o.shellxescape ~= "" then
      cmd = cmd:gsub(".", function(char)
        if string.find(vim.o.shellxescape, char, 1, true) then
          return "^" .. char
        else
          return char
        end
      end)
    end

    if vim.o.shellxquote == "(" then
      cmd = "(" .. cmd .. ")"
    elseif vim.o.shellxquote == '"(' then
      cmd = '"(' .. cmd .. ')"'
    else
      cmd = vim.o.shellxquote .. cmd .. vim.o.shellxquote
    end
  end

  table.insert(argv, cmd)
  return argv
end

--- Filters LSP TextEdit objects based on overlap with user-defined hunks.
--- @param lsp_edits table[] Array of LSP TextEdit objects. Ranges are 0-indexed.
---    Each TextEdit: { range = { start = { line = L, character = C }, end = { line = L, character = C } }, newText = "..." }
--- @param user_hunks table[] Array of user hunk objects. Line numbers are 1-indexed, inclusive.
---    Each hunk: { start_line = SL, end_line = EL }
--- @return table[] Filtered array of LSP TextEdit objects.
M.filter_lsp_text_edits_by_hunks = function(lsp_edits, user_hunks)
  if not lsp_edits or vim.tbl_isempty(lsp_edits) then
    return {}
  end
  if not user_hunks or vim.tbl_isempty(user_hunks) then
    -- If there are no user changes, no LSP edits should be applied if filtering is active.
    return {}
  end

  local filtered_edits = {}
  local log = require("conform.log") -- For debugging, if needed

  log.trace("Filtering LSP edits. Total LSP edits: %d, Total user hunks: %d", #lsp_edits, #user_hunks)
  -- log.trace("LSP Edits: %s", lsp_edits) -- Careful: can be very verbose
  -- log.trace("User Hunks (1-indexed): %s", user_hunks)

  for _, lsp_edit in ipairs(lsp_edits) do
    -- LSP ranges are 0-indexed. Convert to 1-indexed for comparison with user_hunks.
    -- Add 1 to line numbers.
    local lsp_edit_start_line_1idx = lsp_edit.range.start.line + 1
    local lsp_edit_end_line_1idx = lsp_edit.range["end"].line + 1

    -- Ensure end is not less than start for the LSP edit itself (e.g. single line insert)
    if lsp_edit_end_line_1idx < lsp_edit_start_line_1idx then
        lsp_edit_end_line_1idx = lsp_edit_start_line_1idx
    end

    log.trace("Processing LSP edit (1-indexed range): lines %d-%d", lsp_edit_start_line_1idx, lsp_edit_end_line_1idx)

    local overlaps = false
    for _, user_hunk in ipairs(user_hunks) do
      log.trace("  Comparing with user hunk: lines %d-%d", user_hunk.start_line, user_hunk.end_line)
      if M.does_hunk_overlap(lsp_edit_start_line_1idx, lsp_edit_end_line_1idx, user_hunk.start_line, user_hunk.end_line) then
        overlaps = true
        log.trace("    Overlap found with user hunk: lines %d-%d. Including this LSP edit.", user_hunk.start_line, user_hunk.end_line)
        break
      end
    end

    if overlaps then
      table.insert(filtered_edits, lsp_edit)
    else
      log.trace("    No overlap found for LSP edit (1-indexed range %d-%d) with any user hunk. Discarding.", lsp_edit_start_line_1idx, lsp_edit_end_line_1idx)
    end
  end

  log.trace("Finished filtering LSP edits. Original count: %d, Filtered count: %d", #lsp_edits, #filtered_edits)
  return filtered_edits
end

--- Identifies lines changed by the user compared to the last saved version of the file.
--- @param bufnr integer The buffer number.
--- @param current_buffer_lines table Array of strings representing lines in the buffer.
--- @return table Array of hunk objects {start_line=S, end_line=E} (1-indexed, inclusive),
---               or an empty table if no changes or not applicable.
M.get_user_changed_hunks = function(bufnr, current_buffer_lines)
  local log = require("conform.log")
  local user_changed_hunks = {}
  local file_path = vim.api.nvim_buf_get_name(bufnr)

  if file_path == "" or vim.bo[bufnr].buftype ~= "" then
    log.debug("get_user_changed_hunks: Cannot get hunks for unnamed or special buffer: %s", bufnr)
    return {}
  end

  if vim.fn.filereadable(file_path) == 1 then
    local saved_lines_content = vim.fn.readfile(file_path)
    if type(saved_lines_content) ~= "table" then saved_lines_content = {} end

    local saved_lines_for_diff = vim.deepcopy(saved_lines_content)
    table.insert(saved_lines_for_diff, "")
    local saved_text_for_diff = table.concat(saved_lines_for_diff, "\n")
    table.remove(saved_lines_for_diff)

    local buffer_lines_for_diff = vim.deepcopy(current_buffer_lines)
    table.insert(buffer_lines_for_diff, "")
    local buffer_text_for_diff = table.concat(buffer_lines_for_diff, "\n")
    table.remove(buffer_lines_for_diff)

    local user_diff_indices = vim.diff(saved_text_for_diff, buffer_text_for_diff, { result_type = "indices", algorithm = "histogram" })
    log.trace("get_user_changed_hunks: User diff indices (saved vs current buffer): %s", user_diff_indices)

    for _, diff_entry in ipairs(user_diff_indices) do
      local _, _, change_start_in_buffer, change_count_in_buffer = unpack(diff_entry)
      if change_count_in_buffer > 0 then
        table.insert(user_changed_hunks, {
          start_line = change_start_in_buffer, -- 1-indexed
          end_line = change_start_in_buffer + change_count_in_buffer - 1, -- 1-indexed, inclusive
        })
      end
    end
    log.trace("get_user_changed_hunks: User changed hunks (1-indexed): %s", user_changed_hunks)
  else
    log.debug("get_user_changed_hunks: File not found on disk: %s. No hunks.", file_path)
    return {}
  end
  return user_changed_hunks
end

return M
