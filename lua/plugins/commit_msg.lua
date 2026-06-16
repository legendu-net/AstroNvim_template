-- Auto-summarize a working-copy diff into a commit message and prefill it at
-- the top of a commit-message file when it is opened empty. Supports Jujutsu
-- (`*.jjdescription`) and Git (`.git/COMMIT_EDITMSG`).

local PROMPT = "Write a concise conventional commit message for this diff. " .. "Output ONLY the message."

-- Resolve the LLM command (as an argument list) that reads a diff on stdin and
-- prints a commit message. Prefer `jetski`, then `agy`, then `claude`.
-- Returns nil when none are available.
local function llm_cmd()
  if vim.fn.executable "jetski" == 1 then
    return { "jetski", "--model", "Gemini 3.5 Flash (Low)", "--print", PROMPT }
  elseif vim.fn.executable "agy" == 1 then
    return { "agy", "--model", "Gemini 3.5 Flash (Low)", "--print", PROMPT }
  elseif vim.fn.executable "claude" == 1 then
    return { "claude", "--model", "haiku", "-p", PROMPT }
  end
  return nil
end

-- Build a `BufReadPost`/`BufNewFile` callback that, when the message is still
-- empty, runs the diff and pipes it to the LLM asynchronously, then prepends
-- the result. `diff_cmd` is an argument list (e.g. `{ "git", "diff" }`).
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
    vim.system(
      diff_cmd,
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
          callback = make_prefill({ "jj", "diff" }, "JJ:"),
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
