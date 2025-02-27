local require = require("noice.util.lazy")

local Util = require("noice.util")
local Router = require("noice.message.router")
local Api = require("noice.api")

-- HACK: a bunch of hacks to make Noice behave
local M = {}

---@type fun()[]
M._disable = {}

function M.reset_augroup()
  M.group = vim.api.nvim_create_augroup("noice.hacks", { clear = true })
end

function M.enable()
  M.reset_augroup()
  M.fix_incsearch()
  M.fix_input()
  M.fix_notify()
  M.fix_nohlsearch()
  M.fix_redraw()
  M.fix_cmp()
end

function M.fix_vim_sleuth()
  vim.g.sleuth_noice_heuristics = 0
end

function M.disable()
  M.reset_augroup()
  for _, fn in pairs(M._disable) do
    fn()
  end
  M._disable = {}
end

-- start a timer that checks for vim.v.hlsearch.
-- Clears search count and stops timer when hlsearch==0
function M.fix_nohlsearch()
  M.fix_nohlsearch = Util.interval(30, function()
    if vim.v.hlsearch == 0 then
      require("noice.message.manager").clear({ kind = "search_count" })
    end
  end, {
    enabled = function()
      return vim.v.hlsearch == 1
    end,
  })
  M.fix_nohlsearch()
end

---@see https://github.com/neovim/neovim/issues/17810
function M.fix_incsearch()
  ---@type integer|nil
  local conceallevel

  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = M.group,
    callback = function(event)
      if event.match == "/" or event.match == "?" then
        conceallevel = vim.wo.conceallevel
        vim.wo.conceallevel = 0
      end
    end,
  })

  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = M.group,
    callback = function(event)
      if conceallevel and (event.match == "/" or event.match == "?") then
        vim.wo.conceallevel = conceallevel
        conceallevel = nil
      end
    end,
  })
end

-- we need to intercept redraw so we can safely ignore message triggered by redraw
-- This wraps vim.cmd, nvim_cmd, nvim_command and nvim_exec
---@see https://github.com/neovim/neovim/issues/20416
M.inside_redraw = false
function M.fix_redraw()
  local nvim_cmd = vim.api.nvim_cmd

  local function wrap(fn, ...)
    local inside_redraw = M.inside_redraw

    M.inside_redraw = true

    ---@type boolean, any
    local ok, ret = pcall(fn, ...)

    -- check if the ui needs updating
    Util.try(Router.update)

    if not inside_redraw then
      M.inside_redraw = false
    end

    if ok then
      return ret
    end
    error(ret)
  end

  vim.api.nvim_cmd = function(cmd, ...)
    if type(cmd) == "table" and cmd.cmd and cmd.cmd == "redraw" then
      return wrap(nvim_cmd, cmd, ...)
    else
      return nvim_cmd(cmd, ...)
    end
  end

  local nvim_command = vim.api.nvim_command
  vim.api.nvim_command = function(cmd, ...)
    if cmd == "redraw" then
      return wrap(nvim_command, cmd, ...)
    else
      return nvim_command(cmd, ...)
    end
  end

  local nvim_exec = vim.api.nvim_exec
  vim.api.nvim_exec = function(cmd, ...)
    if type(cmd) == "string" and cmd:find("redraw") then
      -- WARN: this will potentially lose messages before or after the redraw ex command
      -- example: echo "foo" | redraw | echo "bar"
      -- the 'foo' message will be lost
      return wrap(nvim_exec, cmd, ...)
    else
      return nvim_exec(cmd, ...)
    end
  end

  table.insert(M._disable, function()
    vim.api.nvim_cmd = nvim_cmd
    vim.api.nvim_command = nvim_command
    vim.api.nvim_exec = nvim_exec
  end)
end

---@see https://github.com/neovim/neovim/issues/20311
M.before_input = false
function M.fix_input()
  local function wrap(fn, skip)
    return function(...)
      if skip and skip(...) then
        return fn(...)
      end

      local Manager = require("noice.message.manager")

      -- do any updates now before blocking
      M.before_input = true
      Router.update()

      M.hide_cursor()
      ---@type boolean, any
      local ok, ret = pcall(fn, ...)
      M.show_cursor()

      -- clear any message right after input
      Manager.clear({ event = "msg_show", kind = { "echo", "echomsg", "" } })

      M.before_input = false
      if ok then
        return ret
      end
      error(ret)
    end
  end

  local function skip(expr)
    return expr ~= nil
  end
  local getchar = vim.fn.getchar
  local getcharstr = vim.fn.getcharstr
  local inputlist = vim.fn.inputlist

  vim.fn.getchar = wrap(vim.fn.getchar, skip)
  vim.fn.getcharstr = wrap(vim.fn.getcharstr, skip)
  vim.fn.inputlist = wrap(vim.fn.inputlist)

  table.insert(M._disable, function()
    vim.fn.getchar = getchar
    vim.fn.getcharstr = getcharstr
    vim.fn.inputlist = inputlist
  end)
end

-- Allow nvim-notify to behave inside instant events
function M.fix_notify()
  vim.schedule(Util.protect(function()
    if pcall(_G.require, "notify") then
      local NotifyService = require("notify.service")
      ---@type NotificationService
      local meta = getmetatable(NotifyService(require("notify")._config()))
      local push = meta.push
      meta.push = function(self, notif)
        ---@type buffer
        local buf = push(self, notif)

        -- run animator and re-render instantly when inside instant events
        if Util.is_blocking() then
          pcall(self._animator.render, self._animator, self._pending, 1 / self._fps)
          self._buffers[notif.id]:render()
        end
        return buf
      end
      table.insert(M._disable, function()
        meta.push = push
      end)
    end
  end))
end

-- Fixes cmp cmdline position
function M.fix_cmp()
  if not Util.module_exists("cmp.utils.api") then
    -- cmp not availablle
    return
  end

  local api = require("cmp.utils.api")

  local get_cursor = api.get_cursor
  api.get_cursor = function()
    if api.is_cmdline_mode() then
      local pos = Api.get_cmdline_position()
      if pos then
        return { pos.bufpos.row, vim.fn.getcmdpos() - 1 }
      end
    end
    return get_cursor()
  end

  local get_screen_cursor = api.get_screen_cursor
  api.get_screen_cursor = function()
    if api.is_cmdline_mode() then
      local pos = Api.get_cmdline_position()
      if pos then
        return { pos.screenpos.row, pos.screenpos.col + vim.fn.getcmdpos() - 1 }
      end
    end
    return get_screen_cursor()
  end

  table.insert(M._disable, function()
    api.get_cursor = get_cursor
    api.get_screen_cursor = get_screen_cursor
  end)
end

function M.cmdline_force_redraw()
  if vim.api.nvim_get_mode().mode ~= "c" then return end

  local cmdline = vim.fn.getcmdline()
  if cmdline:find("s/.") == nil then return end

  local ignored_commands = {
    "e",  "w",  "x",     "r",  "sav", "sp",    "mk",   "vie", "sv",   "vs", "tabe", "tabnew",
    "cf", "cg", "caddf", "lf", "lg",  "laddf", "diff", "ped", "redi", "so", "up",   "vi", "fin"
  }
  for _, value in ipairs(ignored_commands) do
    -- returning here prevents messing with autocompletion for paths
    if cmdline:find("^" .. value) then return end
  end

  -- HACK: this will trigger redraw while typing a substitution command (s/.../.../)
  vim.api.nvim_input("<space><bs>")
end

M._guicursor = nil
function M.hide_cursor()
  if M._guicursor == nil then
    M._guicursor = vim.go.guicursor
  end
  vim.go.guicursor = "a:NoiceHiddenCursor/NoiceHiddenCursor"
  M._disable.guicursor = M.show_cursor
end

function M.show_cursor()
  if M._guicursor then
    vim.go.guicursor = M._guicursor
  end
end

return M
