-- Auto-summarize a working-copy diff into a commit message and prefill it at
-- the top of a commit-message file when it is opened empty. Supports Jujutsu
-- (`*.jjdescription`) and Git (`.git/COMMIT_EDITMSG`).

local PROMPT = "Write a concise conventional commit message for this diff. Output ONLY the message."

-- Resolve the LLM command (as an argument list) that reads a diff on stdin and
-- prints a commit message. Prefer `jetski`, then `agy`, then `claude`.
-- Returns nil when none are available.
local function llm_cmd()
  if vim.fn.executable "jetski" == 1 then
    return { "jetski", "--model", "Gemini 3.5 Flash", "--print", PROMPT }
  elseif vim.fn.executable "agy" == 1 then
    return { "agy", "--model", "Gemini 3.5 Flash (Low)", "--print", PROMPT }
  elseif vim.fn.executable "claude" == 1 then
    return { "claude", "--model", "haiku", "-p", PROMPT }
  end
  return nil
end

-- Build the `jj diff` command scoped to the change being described. A
-- `*.jjdescription` buffer carries the change's id and file list in its `JJ:`
-- comments; diffing just that change (rather than the whole working copy) keeps
-- the summary focused when the description is for a non-`@` revision or only
-- part of a change. Both `-r <id>` and `-- <files>` are needed: `jj split`
-- opens this editor before persisting the split, so `-r <id>` alone still sees
-- the un-split tree; restricting to the listed files yields the right subset.
local function jj_diff_cmd(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local change_id
  local files = {}
  for _, line in ipairs(lines) do
    -- Only the first Change ID line is honored; a second one would otherwise
    -- add a stray `-r`, turning the revset into an unintended union.
    change_id = change_id or line:match "^JJ: Change ID:%s+(%S+)"
    -- File lines look like `JJ:     M path/to/file`. Renames/copies embed the
    -- change as `{old => new}`, optionally with a shared prefix/suffix
    -- (`{dir => newdir}/file`); rewrite that segment to the destination path.
    local file = line:match "^JJ:%s+[AMDRC]%s+(.+)$"
    if file then
      file = vim.trim((file:gsub("{.-%s*=>%s*(.-)}", "%1")))
      -- Skip empties so we never pass a blank path to `jj diff`.
      if file ~= "" then table.insert(files, file) end
    end
  end
  local cmd = { "jj", "diff" }
  if change_id then vim.list_extend(cmd, { "-r", change_id }) end
  if #files > 0 then
    table.insert(cmd, "--")
    vim.list_extend(cmd, files)
  end
  return cmd
end

-- Build a `BufReadPost`/`BufNewFile` callback that, when the message is still
-- empty, runs the diff and pipes it to the LLM asynchronously, then prepends
-- the result. `diff_cmd` is an argument list (e.g. `{ "git", "diff" }`) or a
-- function `(buf) -> argument list` to compute one from the buffer contents.
-- `comment_prefix` is the line prefix the VCS uses for comments (`JJ:`, `#`).
local function make_prefill(diff_cmd, comment_prefix)
  return function(args)
    local buf = args.buf
    -- The message is empty when, ignoring comment lines, the first 15 lines
    -- contain no text. Comment lines are never touched.
    local function message_empty()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, 15, false)
      for _, line in ipairs(lines) do
        if not vim.startswith(line, comment_prefix) and vim.trim(line) ~= "" then return false end
      end
      return true
    end
    if not message_empty() then return end

    local llm = llm_cmd()
    if not llm then
      vim.notify("Commit message summary skipped: no jetski/agy/claude found", vim.log.levels.WARN)
      return
    end
    -- The LLM call takes a few seconds; let the user know it is in progress.
    vim.notify("Generating commit message…", vim.log.levels.INFO)
    -- Run the diff, then feed its output to the LLM on stdin. Each command runs
    -- directly (no shell), avoiding shell-quoting issues and the lack of `sh`
    -- on Windows.
    local cmd = type(diff_cmd) == "function" and diff_cmd(buf) or diff_cmd
    vim.system(
      cmd,
      { text = true },
      vim.schedule_wrap(function(diff_out)
        if diff_out.code ~= 0 then
          vim.notify("Commit message summary failed: " .. (diff_out.stderr or ""), vim.log.levels.ERROR)
          return
        end
        local diff = diff_out.stdout or ""
        -- Nothing to summarize; don't waste an LLM call on an empty diff.
        if vim.trim(diff) == "" then
          vim.notify("Commit message summary skipped: no diff to summarize", vim.log.levels.WARN)
          return
        end
        vim.system(
          llm,
          { text = true, stdin = diff },
          vim.schedule_wrap(function(out)
            if out.code ~= 0 then
              vim.notify("Commit message summary failed: " .. (out.stderr or ""), vim.log.levels.ERROR)
              return
            end
            local msg = vim.trim(out.stdout or "")
            if msg == "" then return end
            -- Re-check: the user may have started typing during the async call.
            if not vim.api.nvim_buf_is_valid(buf) or not message_empty() then return end
            local lines = vim.split(msg, "\n")
            -- Trailing empty line to separate the message from the VCS comments.
            table.insert(lines, "")
            vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
          end)
        )
      end)
    )
  end
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    autocmds = {
      prefill_commit_msg = {
        {
          event = { "BufReadPost", "BufNewFile" },
          pattern = "*.jjdescription",
          desc = "Prefill jj description with an AI-generated commit message",
          callback = make_prefill(jj_diff_cmd, "JJ:"),
        },
        {
          event = { "BufReadPost", "BufNewFile" },
          pattern = "*.git/*COMMIT_EDITMSG",
          desc = "Prefill git commit message with an AI-generated commit message",
          callback = make_prefill({ "git", "diff", "--staged" }, "#"),
        },
      },
    },
  },
}
