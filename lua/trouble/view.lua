local renderer = require("trouble.renderer")
local config = require("trouble.config")
local folds = require("trouble.folds")
local util = require("trouble.util")

local highlight = vim.api.nvim_buf_add_highlight

---@class View
---@field buf number
---@field win number
---@field items Item[]
---@field folded table<string, boolean>
---@field parent number
---@field float number
local View = {}
View.__index = View

-- keep track of buffers with added highlights
-- highlights are cleared on BufLeave of LspTrouble
local hl_bufs = {}

local function clear_hl(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, config.namespace, 0, -1)
    end
end

---Find a rogue LspTrouble buffer that might have been spawned by i.e. a session.
local function find_rogue_buffer()
    for _, v in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.bufname(v) == "LspTrouble" then return v end
    end
    return nil
end

---Find pre-existing LspTrouble buffer, delete its windows then wipe it.
---@private
local function wipe_rogue_buffer()
    local bn = find_rogue_buffer()
    if bn then
        local win_ids = vim.fn.win_findbuf(bn)
        for _, id in ipairs(win_ids) do
            if vim.fn.win_gettype(id) ~= "autocmd" then
                vim.api.nvim_win_close(id, true)
            end
        end

        vim.api.nvim_buf_set_name(bn, "")
        vim.schedule(function() pcall(vim.api.nvim_buf_delete, bn, {}) end)
    end
end

function View:new(opts)
    opts = opts or {}
    local this = {
        buf = vim.api.nvim_get_current_buf(),
        win = opts.win or vim.api.nvim_get_current_win(),
        parent = opts.parent,
        items = {}
    }
    setmetatable(this, self)
    return this
end

function View:set_option(name, value, win)
    if win then
        return vim.api.nvim_win_set_option(self.win, name, value)
    else
        return vim.api.nvim_buf_set_option(self.buf, name, value)
    end
end

---@param text Text
function View:render(text)
    self:unlock()
    self:set_lines(text.lines)
    self:lock()
    clear_hl(self.buf)
    for _, data in ipairs(text.hl) do
        highlight(self.buf, config.namespace, data.group, data.line, data.from,
                  data.to)
    end
end

function View:clear()
    return vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
end

function View:unlock()
    self:set_option("modifiable", true)
    self:set_option("readonly", false)
end

function View:lock()
    self:set_option("readonly", true)
    self:set_option("modifiable", false)
end

function View:set_lines(lines, first, last, strict)
    first = first or 0
    last = last or -1
    strict = strict or false
    return vim.api.nvim_buf_set_lines(self.buf, first, last, strict, lines)
end

function View:is_valid()
    return vim.api.nvim_buf_is_valid(self.buf) and
               vim.api.nvim_buf_is_loaded(self.buf)
end

function View:update(opts)
    util.debug("update")
    renderer.render(self, opts)
end

function View:setup(opts)
    util.debug("setup")
    opts = opts or {}
    vim.cmd("setlocal nonu")
    vim.cmd("setlocal nornu")
    if not pcall(vim.api.nvim_buf_set_name, self.buf, 'LspTrouble') then
        wipe_rogue_buffer()
        vim.api.nvim_buf_set_name(self.buf, 'LspTrouble')
    end
    self:set_option("bufhidden", "wipe")
    self:set_option("filetype", "LspTrouble")
    self:set_option("buftype", "nofile")
    self:set_option("swapfile", false)
    self:set_option("buflisted", false)
    self:set_option("winfixwidth", true, true)
    self:set_option("spell", false, true)
    self:set_option("list", false, true)
    self:set_option("winfixheight", true, true)
    self:set_option("signcolumn", "no", true)
    self:set_option("foldmethod", "manual", true)
    self:set_option("foldcolumn", "0", true)
    self:set_option("foldlevel", 3, true)
    self:set_option("foldenable", false, true)
    self:set_option("winhighlight", "Normal:LspTroubleNormal", true)

    for action, keys in pairs(config.options.action_keys) do
        if type(keys) == "string" then keys = {keys} end
        for _, key in pairs(keys) do
            vim.api.nvim_buf_set_keymap(self.buf, "n", key,
                                        [[<cmd>lua require("trouble").action("]] ..
                                            action .. [[")<cr>]],
                                        {silent = true, noremap = true})
        end
    end

    vim.api.nvim_win_set_height(self.win, config.options.height)

    vim.api.nvim_exec([[
      augroup LspTroubleHighlights
        autocmd! * <buffer>
        autocmd BufEnter <buffer> lua require("trouble").action("on_enter")
        autocmd CursorMoved <buffer> lua require("trouble").action("auto_preview")
        autocmd BufLeave <buffer> lua require("trouble").action("on_leave")
      augroup END
    ]], false)

    if not opts.parent then self:on_enter() end
    self:lock()
    self:update(opts)
end

function View:on_enter()
    util.debug("on_enter")

    self.parent = self.parent or vim.fn.win_getid(vim.fn.winnr('#'))

    if (not self:is_valid_parent(self.parent)) or self.parent == self.win then
        for _, win in pairs(vim.api.nvim_list_wins()) do
            if self:is_valid_parent(win) and win ~= self.win then
                self.parent = win
                break
            end
        end
    end

    self.parent_state = {
        buf = vim.api.nvim_win_get_buf(self.parent),
        cursor = vim.api.nvim_win_get_cursor(self.parent)
    }
end

function View:on_leave()
    util.debug("on_leave")
    self:close_preview()
end

function View:close_preview()

    -- Clear preview highlights
    for buf, _ in pairs(hl_bufs) do clear_hl(buf) end
    hl_bufs = {}

    -- Reset parent state
    local valid_win = vim.api.nvim_win_is_valid(self.parent)
    local valid_buf = vim.api.nvim_buf_is_valid(self.parent_state.buf)

    if self.parent_state and valid_buf and valid_win then
        vim.api.nvim_win_set_buf(self.parent, self.parent_state.buf)
        vim.api.nvim_win_set_cursor(self.parent, self.parent_state.cursor)
    end

    self.parent_state = nil
end

function View:is_float(win)
    local opts = vim.api.nvim_win_get_config(win)
    return opts and opts.relative and opts.relative ~= ""
end

function View:is_valid_parent(win)
    -- dont do anything for floating windows
    if View:is_float(win) then return false end
    local buf = vim.api.nvim_win_get_buf(win)
    -- Skip special buffers
    if vim.api.nvim_buf_get_option(buf, "buftype") ~= "" then return false end

    return true
end

function View:on_win_enter()
    util.debug("on_win_enter")

    local current_win = vim.api.nvim_get_current_win()

    if not self:is_valid_parent(current_win) then return end

    local current_buf = vim.api.nvim_get_current_buf()

    -- update parent when needed
    if current_win ~= self.parent and current_win ~= self.win then
        self.parent = current_win
        -- update diagnostics to match the window we are viewing
        if self:is_valid() then
            vim.defer_fn(function()
                util.debug("update_on_win_enter")
                self:update()
            end, 100)
        end
    end

    -- check if another buffer took over our window
    local parent = self.parent
    if current_win == self.win and current_buf ~= self.buf then
        -- open the buffer in the parent
        vim.api.nvim_win_set_buf(parent, current_buf)
        -- HACK: somw window local settings need to be reset
        vim.api.nvim_win_set_option(parent, "winhl", "")
        -- close the current trouble window
        vim.api.nvim_win_close(self.win, false)
        -- open a new trouble window
        require("trouble").open()
        -- switch back to the opened window / buffer
        View.switch_to(parent, current_buf)
        -- util.warn("win_enter pro")
    end
end

function View:focus()
    View.switch_to(self.win, self.buf)
    local line = self:get_line()
    if line == 1 then
        self:next_item()
        self:next_item()
    end
end

function View.switch_to(win, buf)
    if win then
        vim.api.nvim_set_current_win(win)
        if buf then vim.api.nvim_win_set_buf(win, buf) end
    end
end

function View:switch_to_parent()
    -- vim.cmd("wincmd p")
    View.switch_to(self.parent)
end

function View:close() vim.api.nvim_buf_delete(self.buf, {}) end

function View.create(opts)
    opts = opts or {}
    if opts.win then
        View.switch_to(opts.win)
        vim.cmd("enew")
    else
        vim.cmd("below new")
        vim.cmd("wincmd J")
    end
    local buffer = View:new(opts)
    buffer:setup(opts)

    if opts and opts.auto then buffer:switch_to_parent() end
    return buffer
end

function View:get_cursor() return vim.api.nvim_win_get_cursor(self.win) end
function View:get_line() return self:get_cursor()[1] end
function View:get_col() return self:get_cursor()[2] end

function View:current_item()
    local line = self:get_line()
    local item = self.items[line]
    return item
end

function View:next_item()
    local line = self:get_line()
    for i = line + 1, vim.api.nvim_buf_line_count(self.buf), 1 do
        if self.items[i] then
            vim.api.nvim_win_set_cursor(self.win, {i, self:get_col()})
            return
        end
    end
end

function View:previous_item()
    local line = self:get_line()
    for i = line - 1, 0, -1 do
        if self.items[i] then
            vim.api.nvim_win_set_cursor(self.win, {i, self:get_col()})
            return
        end
    end
end

function View:hover(opts)
    opts = opts or {}
    local item = opts.item or self:current_item()
    if not (item and item.full_text) then return end

    local lines = {}
    for line in item.full_text:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end

    vim.lsp.util.open_floating_preview(lines, "plaintext", {border = "single"})
end

function View:jump(opts)
    opts = opts or {}
    local item = opts.item or self:current_item()
    if not item then return end

    if item.is_file == true then
        folds.toggle(item.filename)
        self:update()
    else
        View.switch_to(opts.win or self.parent)
        if vim.api.nvim_buf_get_option(item.bufnr, "buflisted") == false then
            vim.cmd("edit #" .. item.bufnr)
        else
            vim.cmd("buffer " .. item.bufnr)
        end
        vim.api.nvim_win_set_cursor(self.parent,
                                    {item.start.line + 1, item.start.character})
    end
end

function View:toggle_fold()
    folds.toggle(self:current_item().filename)
    self:update()
end

function View:preview()
    util.debug("preview")

    local item = self:current_item()
    if not item then return end

    if item.is_file ~= true then

        vim.api.nvim_win_set_buf(self.parent, item.bufnr)
        vim.api.nvim_win_set_cursor(self.parent,
                                    {item.start.line + 1, item.start.character})

        vim.api.nvim_buf_call(item.bufnr, function()
            -- Center preview line on screen and open enough folds to show it
            vim.cmd("norm! zz zv")
            if vim.api.nvim_buf_get_option(item.bufnr, "filetype") == "" then
                vim.cmd("do BufRead")
            end
        end)

        clear_hl(item.bufnr)
        hl_bufs[item.bufnr] = true
        for row = item.start.line, item.finish.line, 1 do
            local col_start = 0
            local col_end = -1
            if row == item.start.line then
                col_start = item.start.character
            end
            if row == item.finish.line then
                col_end = item.finish.character
            end
            highlight(item.bufnr, config.namespace, "LspTroublePreview", row,
                      col_start, col_end)
        end
    end
end

return View
