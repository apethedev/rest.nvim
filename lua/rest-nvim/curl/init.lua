local utils = require("rest-nvim.utils")
local curl = require("plenary.curl")
local log = require("plenary.log").new({ plugin = "rest.nvim" })
local config = require("rest-nvim.config")

local M = {}
-- checks if 'x' can be executed by system()
local function is_executable(x)
  if type(x) == "string" and vim.fn.executable(x) == 1 then
    return true
  elseif vim.tbl_islist(x) and vim.fn.executable(x[1] or "") == 1 then
    return true
  end

  return false
end

local function format_curl_cmd(res)
  local cmd = "curl"

  for _, value in pairs(res) do
    if string.sub(value, 1, 1) == "-" then
      cmd = cmd .. " " .. value
    else
      cmd = cmd .. " '" .. value .. "'"
    end
  end

  -- remote -D option
  cmd = string.gsub(cmd, "-D '%S+' ", "")
  return cmd
end

local function send_curl_start_event(data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "RestStartRequest",
    modeline = false,
    data = data,
  })
end

local function send_curl_stop_event(data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "RestStopRequest",
    modeline = false,
    data = data,
  })
end

local function create_error_handler(opts)
  return function(err)
    send_curl_stop_event(vim.tbl_extend("keep", { err = err }, opts))
    error(err.message)
  end
end

local function parse_headers(headers)
  local parsed = {}
  for _, header in ipairs(headers) do
    if header ~= "" then
      local key, value = header:match("([^:]+):%s*(.*)")
      if key then
        parsed[key] = value or ""
      end
    end
  end
  return parsed
end

-- get_or_create_buf checks if there is already a buffer with the rest run results
-- and if the buffer does not exists, then create a new one
M.get_or_create_buf = function()
  local tmp_name = "rest_nvim_results"

  -- Check if the file is already loaded in the buffer
  local existing_bufnr = vim.fn.bufnr(tmp_name)
  if existing_bufnr ~= -1 then
    -- Set modifiable
    vim.api.nvim_set_option_value("modifiable", true, { buf = existing_bufnr })
    -- Prevent modified flag
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = existing_bufnr })
    -- Delete buffer content
    vim.api.nvim_buf_set_lines(existing_bufnr, 0, -1, false, {})

    -- Make sure the filetype of the buffer is httpResult so it will be highlighted
    -- vim.api.nvim_set_option_value("ft", "httpResult", { buf = existing_bufnr })
    vim.api.nvim_set_option_value("ft", "json", { buf = existing_bufnr })

    return existing_bufnr
  end

  -- Create new buffer
  local new_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(new_bufnr, tmp_name)
  vim.api.nvim_set_option_value("ft", "httpResult", { buf = new_bufnr })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = new_bufnr })

  return new_bufnr
end

local function create_callback(curl_cmd, opts)
  local method = opts.method
  local url = opts.url
  local script_str = opts.script_str

  return function(res)
    send_curl_stop_event(vim.tbl_extend("keep", { res = res }, opts))

    if res.exit ~= 0 then
      log.error("[rest.nvim] " .. utils.curl_error(res.exit))
      return
    end
    local res_bufnr = M.get_or_create_buf()

    local headers = utils.filter(res.headers, function(value)
      return value ~= ""
    end, false)

    headers = utils.map(headers, function(value)
      local _, _, http, status = string.find(value, "^(HTTP.*)%s+(%d+)%s*$")

      if http and status then
        return http .. " " .. utils.http_status(tonumber(status))
      end

      return value
    end)

    headers = utils.split_list(headers, function(value)
      return string.find(value, "^HTTP.*$")
    end)

    res.headers = parse_headers(res.headers)

    local content_type = res.headers[utils.key(res.headers, "content-type")]
    if content_type then
      content_type = content_type:match("application/([-a-z]+)") or content_type:match("text/(%l+)")
    end

    if script_str ~= nil then
      local context = {
        result = res,
        pretty_print = vim.pretty_print,
        json_decode = vim.fn.json_decode,
        set_env = utils.set_env,
        set = utils.set_context,
      }
      local env = { context = context }
      setmetatable(env, { __index = _G })
      local f = load(script_str, nil, "bt", env)
      if f ~= nil then
        f()
      end
    end

    if config.get("result").show_url then
      --- Add metadata into the created buffer (status code, date, etc)
      -- Request statement (METHOD URL)
      utils.write_block(res_bufnr, { method:upper() .. " " .. url }, false)
    end

    -- This can be quite verbose so let user control it
    if config.get("result").show_curl_command then
      utils.write_block(res_bufnr, { "Command: " .. curl_cmd }, true)
    end

    if config.get("result").show_http_info then
      -- HTTP version, status code and its meaning, e.g. HTTP/1.1 200 OK
      utils.write_block(res_bufnr, { "HTTP/1.1 " .. utils.http_status(res.status) }, false)
    end

    if config.get("result").show_headers then
      -- Headers, e.g. Content-Type: application/json
      for _, header_block in ipairs(headers) do
        utils.write_block(res_bufnr, header_block, true)
      end
    end

    if config.get("result").show_statistics then
      -- Statistics, e.g. Total Time: 123.4 ms
      local statistics

      res.body, statistics = utils.parse_statistics(res.body)

      utils.write_block(res_bufnr, statistics, true)
    end

    --- Add the curl command results into the created buffer
    local formatter = config.get("result").formatters[content_type]
    -- format response body
    if type(formatter) == "function" then
      local ok, out = pcall(formatter, res.body)
      -- check if formatter ran successfully
      if ok and out then
        res.body = out
      else
        vim.api.nvim_echo({
          {
            string.format("Error calling formatter on response body:\n%s", out),
            "Error",
          },
        }, false, {})
      end
    elseif is_executable(formatter) then
      local stdout = vim.fn.system(formatter, res.body):gsub("\n$", "")
      -- check if formatter ran successfully
      if vim.v.shell_error == 0 then
        res.body = stdout
      else
        vim.api.nvim_echo({
          {
            string.format("Error running formatter %s on response body:\n%s", vim.inspect(formatter), stdout),
            "Error",
          },
        }, false, {})
      end
    end

    -- append response container
    -- local buf_content = "#+RESPONSE\n"
    local buf_content = ""
    if utils.is_binary_content_type(content_type) then
      buf_content = buf_content .. "Binary answer"
    else
      buf_content = buf_content .. res.body
    end
    -- buf_content = buf_content .. "\n#+END"

    local lines = utils.split(buf_content, "\n")

    utils.write_block(res_bufnr, lines)

    -- Only open a new split if the buffer is not loaded into the current window
    if vim.fn.bufwinnr(res_bufnr) == -1 then
      local cmd_split = [[vert sb]]
      if config.get("result_split_horizontal") then
        cmd_split = [[sb]]
      end
      if config.get("result_split_in_place") then
        cmd_split = [[bel ]] .. cmd_split
      end
      if config.get("stay_in_current_window_after_split") then
        vim.cmd(cmd_split .. res_bufnr .. " | wincmd p")
      else
        vim.cmd(cmd_split .. res_bufnr)
      end
      -- Set unmodifiable state
      vim.api.nvim_set_option_value("modifiable", false, { buf = res_bufnr })
    end

    -- Send cursor in response buffer to start
    utils.move_cursor(res_bufnr, 1)

    -- add syntax highlights for response
    local syntax_file = vim.fn.expand(string.format("$VIMRUNTIME/syntax/%s.vim", content_type))

    if vim.fn.filereadable(syntax_file) == 1 then
      vim.cmd(string.gsub(
        [[
        if exists("b:current_syntax")
          unlet b:current_syntax
        endif
        syn include @%s syntax/%s.vim
        syn region %sBody matchgroup=Comment start=+\v^#\+RESPONSE$+ end=+\v^#\+END$+ contains=@%s

        let b:current_syntax = "httpResult"
      ]],
        "%%s",
        content_type
      ))
    end
  end
end

-- curl_cmd runs curl with the passed options, gets or creates a new buffer
-- and then the results are printed to the recently obtained/created buffer
-- @param opts (table) curl arguments:
--           - yank_dry_run (boolean): displays the command
--           - arguments are forwarded to plenary
M.curl_cmd = function(opts)
  --- Execute request pre-script if any.
  if config.get("request").pre_script then
    config.get("request").pre_script(opts, utils.get_variables())
  end

  -- plenary's curl module is strange in the sense that with "dry_run" it returns the command
  -- otherwise it starts the request :/
  local dry_run_opts = vim.tbl_extend("force", opts, { dry_run = true })
  local res = curl[opts.method](dry_run_opts)
  local curl_cmd = format_curl_cmd(res)

  send_curl_start_event(opts)

  if opts.dry_run then
    if config.get("yank_dry_run") then
      vim.cmd("let @+=" .. string.format("%q", curl_cmd))
    end

    vim.api.nvim_echo({ { "[rest.nvim] Request preview:\n", "Comment" }, { curl_cmd } }, false, {})

    send_curl_stop_event(opts)
    return
  else
    opts.callback = vim.schedule_wrap(create_callback(curl_cmd, opts))
    opts.on_error = vim.schedule_wrap(create_error_handler(opts))
    curl[opts.method](opts)
  end
end

return M
