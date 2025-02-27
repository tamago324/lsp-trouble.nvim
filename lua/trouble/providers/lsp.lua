local lsp = require("vim.lsp")
local util = require("trouble.util")

---@class Lsp
local M = {}

---@param options Options
---@return Item[]
function M.diagnostics(win, buf, cb, options)
    if options.mode == "lsp_document_diagnostics" then buf = nil end
    local buffer_diags = buf and {[buf] = vim.lsp.diagnostic.get(buf, nil)} or
                             vim.lsp.diagnostic.get_all()

    cb(util.locations_to_items(buffer_diags, 1))
end

---@return Item[]
function M.references(win, buf, cb, options)
    local method = "textDocument/references"
    local params = util.make_position_params(win, buf)
    params.context = {includeDeclaration = true}
    lsp.buf_request(buf, method, params,
                    function(err, method, result, client_id, bufnr, config)
        if err then
            util.error("an error happened getting references: " .. err)
            return cb({})
        end
        local ret = util.locations_to_items({result}, 0)
        cb(ret)
    end)
end

function M.get_signs()
    local signs = {}
    for _, v in pairs(util.severity) do
        -- pcall to catch entirely unbound or cleared out sign hl group
        local status, sign = pcall(function()
            return vim.trim(vim.fn.sign_getdefined("LspDiagnosticsSign" .. v)[1]
                                .text)
        end)
        if not status then sign = v:sub(1, 1) end
        signs[string.lower(v)] = sign
    end
    return signs
end

return M
