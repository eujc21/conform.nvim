---This module replaces the default vim.lsp.buf.format() so that we can inject our own logic
local log = require("conform.log")
local vim_lsp_util = require("vim.lsp.util")
local util = require("conform.util")

local M = {}

local function apply_text_edits(text_edits, bufnr, offset_encoding, dry_run, undojoin)
  if
    #text_edits == 1
    and text_edits[1].range.start.line == 0
    and text_edits[1].range.start.character == 0
    and text_edits[1].range["end"].line >= vim.api.nvim_buf_line_count(bufnr)
    and text_edits[1].range["end"].character == 0
  then
    local original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
    local new_lines = vim.split(text_edits[1].newText, "\r?\n", {})
    -- If it had a trailing newline, remove it to make the lines match the expected vim format
    if #new_lines > 1 and new_lines[#new_lines] == "" then
      table.remove(new_lines)
    end
    log.debug("Converting full-file LSP format to piecewise format")
    return require("conform.runner").apply_format(
      bufnr,
      original_lines,
      new_lines,
      nil,
      false,
      dry_run,
      undojoin
    )
  elseif dry_run then
    return #text_edits > 0
  else
    if undojoin then
      pcall(vim.cmd.undojoin)
    end
    vim.lsp.util.apply_text_edits(text_edits, bufnr, offset_encoding)
    return #text_edits > 0
  end
end

---@param options table
---@return table[] clients
function M.get_format_clients(options)
  local method = options.range and "textDocument/rangeFormatting" or "textDocument/formatting"

  local clients
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients({
      id = options.id,
      bufnr = options.bufnr,
      name = options.name,
      method = method,
    })
  else
    ---@diagnostic disable-next-line: deprecated
    clients = vim.lsp.get_active_clients({
      id = options.id,
      bufnr = options.bufnr,
      name = options.name,
    })

    clients = vim.tbl_filter(function(client)
      return client.supports_method(method, { bufnr = options.bufnr })
    end, clients)
  end
  if options.filter then
    clients = vim.tbl_filter(options.filter, clients)
  end
  return clients
end

---@param options conform.FormatOpts
---@param callback fun(err?: string, did_edit?: boolean)
function M.format(options, callback)
  options = options or {}
  local bufnr = options.bufnr
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
    options.bufnr = bufnr
  end
  local range = options.range
  local method = range and "textDocument/rangeFormatting" or "textDocument/formatting"

  local clients = M.get_format_clients(options)

  if #clients == 0 then
    return callback("[LSP] Format request failed, no matching language servers.")
  end

  local function set_range(client, params)
    if range then
      local range_params =
        util.make_given_range_params(range.start, range["end"], bufnr, client.offset_encoding)
      params.range = range_params.range
    end
    return params
  end

  if options.async then
    local changedtick = vim.b[bufnr].changedtick
    local do_format
    local did_edit = false
    do_format = function(idx, client)
      if not client then
        return callback(nil, did_edit)
      end
      --- @diagnostic disable-next-line: param-type-mismatch
      local params = set_range(client, util.make_formatting_params(options.formatting_options))
      local auto_id = vim.api.nvim_create_autocmd("LspDetach", {
        buffer = bufnr,
        callback = function(args)
          if args.data.client_id == client.id then
            log.warn("LSP %s detached during format request", client.name)
            callback("LSP detached")
          end
        end,
      })
      local request = vim.fn.has("nvim-0.11") == 1
          and function(c, ...)
            return c:request(...)
          end
        or function(c, ...)
          return c.request(...)
        end
      request(client, method, params, function(err, result, ctx, _)
        vim.api.nvim_del_autocmd(auto_id)
        if not result then
          return callback(err or "No result returned from LSP formatter")
        elseif not vim.api.nvim_buf_is_valid(ctx.bufnr) then -- Use ctx.bufnr here
          return callback("buffer was deleted")
        elseif changedtick ~= util.buf_get_changedtick(ctx.bufnr) then -- Use util from conform.util
          return callback(
            string.format(
              "Async LSP formatter discarding changes for %s: concurrent modification",
              vim.api.nvim_buf_get_name(ctx.bufnr)
            )
          )
        else
          local final_edits = result
          if options.format_only_local_changes == true and options.range == nil then
            log.debug("LSP Async: format_only_local_changes is active.")
            local original_buffer_lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)
            local user_hunks = util.get_user_changed_hunks(ctx.bufnr, original_buffer_lines)

            local file_path_check = vim.api.nvim_buf_get_name(ctx.bufnr)
            if file_path_check == "" or vim.bo[ctx.bufnr].buftype ~= "" or vim.fn.filereadable(file_path_check) == 0 then
              log.debug("LSP Async: format_only_local_changes effectively disabled for new/special/unreadable file. Applying all LSP edits.")
              -- final_edits remains 'result' (all edits)
            elseif vim.tbl_isempty(user_hunks) then
              log.debug("LSP Async: format_only_local_changes active, but no user changes found. Applying no LSP edits.")
              final_edits = {}
            else
              log.debug("LSP Async: Filtering %d LSP edits by %d user hunks.", #result, #user_hunks)
              final_edits = util.filter_lsp_text_edits_by_hunks(result, user_hunks)
            end
          end
          -- Then call apply_text_edits with final_edits:
          local this_did_edit = apply_text_edits(final_edits, ctx.bufnr, client.offset_encoding, options.dry_run, options.undojoin)
          changedtick = vim.b[ctx.bufnr].changedtick -- Use ctx.bufnr

          if options.dry_run and this_did_edit then
            callback(nil, true)
          else
            did_edit = did_edit or this_did_edit
            do_format(next(clients, idx))
          end
        end
      end, bufnr)
    end
    do_format(next(clients))
  else
    local timeout_ms = options.timeout_ms or 1000
    local did_edit = false
    local request_sync = vim.fn.has("nvim-0.11") == 1
        and function(c, ...)
          return c:request_sync(...)
        end
      or function(c, ...)
        return c.request_sync(...)
      end
    for _, client in pairs(clients) do
      --- @diagnostic disable-next-line: param-type-mismatch
      local params = set_range(client, vim_lsp_util.make_formatting_params(options.formatting_options)) -- Use vim_lsp_util
      local result, err = request_sync(client, method, params, timeout_ms, bufnr)
      if result and result.result then
        local actual_lsp_edits = result.result
        local final_edits = actual_lsp_edits
        if options.format_only_local_changes == true and options.range == nil then
          log.debug("LSP Sync: format_only_local_changes is active.")
          local original_buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local user_hunks = util.get_user_changed_hunks(bufnr, original_buffer_lines)

          local file_path_check = vim.api.nvim_buf_get_name(bufnr)
          if file_path_check == "" or vim.bo[bufnr].buftype ~= "" or vim.fn.filereadable(file_path_check) == 0 then
            log.debug("LSP Sync: format_only_local_changes effectively disabled for new/special/unreadable file. Applying all LSP edits.")
            -- final_edits remains 'actual_lsp_edits'
          elseif vim.tbl_isempty(user_hunks) then
            log.debug("LSP Sync: format_only_local_changes active, but no user changes found. Applying no LSP edits.")
            final_edits = {}
          else
            log.debug("LSP Sync: Filtering %d LSP edits by %d user hunks.", #actual_lsp_edits, #user_hunks)
            final_edits = util.filter_lsp_text_edits_by_hunks(actual_lsp_edits, user_hunks)
          end
        end
        -- Then call apply_text_edits with final_edits:
        local this_did_edit = apply_text_edits(final_edits, bufnr, client.offset_encoding, options.dry_run, options.undojoin)
        did_edit = did_edit or this_did_edit

        if options.dry_run and did_edit then
          callback(nil, true)
          return true -- Return true was missing, but it's in the original code
        end
      elseif err then
        if not options.quiet then
          vim.notify(string.format("[LSP][%s] %s", client.name, err), vim.log.levels.WARN)
        end
        return callback(string.format("[LSP][%s] %s", client.name, err))
      end
    end
    callback(nil, did_edit)
  end
end

return M
