local Job = require("plenary.job")
local git_worktree = require("git-worktree")

local M = {}
local force_next_deletion = false
local list_delimiter = "\t"

local function parse_worktree_line(line)
    local cleaned = vim.fn.trim(line):gsub("%s+", " ")
    if cleaned == "" then
        return nil
    end

    local fields = vim.split(cleaned, " ")
    if #fields < 2 then
        return nil
    end

    local entry = {
        path = fields[1],
        sha = fields[2],
        branch = fields[3] or "",
    }

    if entry.sha == "(bare)" then
        return nil
    end

    return entry
end

local function build_worktree_lines()
    git_worktree.setup_git_info()
    local root = git_worktree.get_root()
    if not root then
        return {}
    end

    local output, code = Job:new({
        command = "git",
        args = { "worktree", "list" },
        cwd = root,
    }):sync()

    if code ~= 0 then
        return {}
    end

    local lines = {}
    for _, line in ipairs(output) do
        local entry = parse_worktree_line(line)
        if entry then
            table.insert(lines, table.concat({
                entry.branch,
                entry.path,
                entry.sha,
            }, list_delimiter))
        end
    end

    return lines
end

local function parse_selected_line(selected)
    if not selected or not selected[1] then
        return nil
    end

    local fields = vim.split(selected[1], list_delimiter, { plain = true })
    if #fields < 2 then
        local cleaned = vim.fn.trim(selected[1]):gsub("%s+", " ")
        fields = vim.split(cleaned, " ")
    end

    if #fields < 2 then
        return nil
    end

    return {
        branch = fields[1],
        path = fields[2],
        sha = fields[3],
    }
end

local function toggle_forced_deletion()
    force_next_deletion = not force_next_deletion
    if force_next_deletion then
        print("The next deletion will be forced")
    else
        print("The next deletion will not be forced")
    end
    vim.fn.execute("redraw")
end

local function delete_success_handler()
    force_next_deletion = false
end

local function delete_failure_handler()
    print("Deletion failed, use <C-f> to force the next deletion")
end

local function confirm_deletion(forcing)
    local confirm = git_worktree._config.confirm_fzf_deletions
    if confirm == nil then
        confirm = git_worktree._config.confirm_telescope_deletions
    end

    if not confirm then
        return true
    end

    local prompt = "Delete worktree? [y/n]: "
    if forcing then
        prompt = "Force deletion of worktree? [y/n]: "
    end

    local confirmed = vim.fn.input(prompt)
    if string.sub(string.lower(confirmed), 1, 1) == "y" then
        return true
    end

    print("Didn't delete worktree")
    return false
end

local function switch_worktree(selected)
    local entry = parse_selected_line(selected)
    if not entry or not entry.path then
        return
    end

    git_worktree.switch_worktree(entry.path)
end

local function delete_worktree(selected)
    if not confirm_deletion(force_next_deletion) then
        return
    end

    local entry = parse_selected_line(selected)
    if not entry or not entry.path then
        return
    end

    git_worktree.delete_worktree(entry.path, force_next_deletion, {
        on_failure = delete_failure_handler,
        on_success = delete_success_handler,
    })
end

local function parse_branch_name(line)
    if not line then
        return nil
    end

    if line:match("%(no branch, bisect") then
        line = line:gsub("%(no.-%)", " ")
    end

    return line:match("^[%*+]*[%s]*[(]?([^%s)]+)")
end

local function prompt_for_path(default_path)
    local default_input = "../"
    if default_path and default_path ~= "" then
        default_input = default_input .. default_path
    end

    local path = vim.fn.input("Path to subtree > ", default_input)
    if path == "" then
        path = default_input
    end
    return path
end

M.git_worktree = function(opts)
    local lines = build_worktree_lines()
    if #lines == 0 then
        print("No worktrees found")
        return
    end

    local fzf_lua = require("fzf-lua")
    opts = vim.tbl_deep_extend("force", {}, opts or {})

    local actions = {
        ["default"] = switch_worktree,
        ["ctrl-d"] = delete_worktree,
        ["ctrl-f"] = { toggle_forced_deletion, fzf_lua.actions.resume },
    }

    opts.actions = vim.tbl_extend("force", actions, opts.actions or {})
    opts.fzf_opts = vim.tbl_extend("force", {
        ["--delimiter"] = list_delimiter,
        ["--with-nth"] = "1,2,3",
    }, opts.fzf_opts or {})
    opts.prompt = opts.prompt or "Git Worktrees> "

    return fzf_lua.fzf_exec(lines, opts)
end

M.create_git_worktree = function(opts)
    local fzf_lua = require("fzf-lua")
    opts = vim.tbl_deep_extend("force", {}, opts or {})

    local function create_from_selection(selected, action_opts)
        local branch = selected and parse_branch_name(selected[1]) or nil
        if not branch and action_opts and action_opts.__resume_key then
            local ok, config = pcall(require, "fzf-lua.config")
            if ok then
                branch = config.resume_get("query", action_opts)
            end
        end

        if not branch or branch == "" then
            return
        end

        local path = prompt_for_path(branch)
        if not path or path == "" then
            return
        end

        git_worktree.create_worktree(path, branch)
    end

    local actions = {
        ["default"] = create_from_selection,
    }

    opts.actions = vim.tbl_extend("force", actions, opts.actions or {})
    opts.fzf_opts = vim.tbl_extend("force", {
        ["--print-query"] = "",
    }, opts.fzf_opts or {})

    return fzf_lua.git_branches(opts)
end

M.setup = function()
    local ok, fzf_lua = pcall(require, "fzf-lua")
    if not ok then
        return
    end

    fzf_lua.register_extension("git_worktree", M.git_worktree, {}, true)
    fzf_lua.register_extension("create_git_worktree", M.create_git_worktree, {}, true)
end

return M
