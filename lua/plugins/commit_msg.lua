-- Auto-summarize a working-copy diff into a commit message and prefill it at
-- the top of a commit-message file when it is opened empty. Supports Jujutsu
-- (`*.jjdescription`) and Git (`.git/COMMIT_EDITMSG`).

-- Default prompt used by most tools.
local PROMPT =
  "Write a concise conventional commit message for this diff. Output ONLY the message, without wrapping it in Markdown code fences or quotation marks."
-- jetski gets a prompt that asks for a summary line plus itemized details.
local JETSKI_PROMPT =
  "Write a commit message for this diff. The first line of the message should be a concise summary of the change. List itemized changes in following lines if necessary. Output ONLY the message, without wrapping it in Markdown code fences or quotation marks."

-- OmniRoute is an OpenAI-compatible LLM gateway; `auto/fast` is one of its
-- routing strategies rather than a concrete model, so the gateway picks the
-- model behind it. The endpoint and key default to a local instance and can be
-- overridden from the environment, so the same configuration also works on a
-- machine that reaches OmniRoute elsewhere.
local OMNIROUTE_BASE_URL = vim.env.OMNIROUTE_BASE_URL or "http://localhost:20128/v1"
local OMNIROUTE_API_KEY = vim.env.OMNIROUTE_API_KEY or "YOUR_OMNIROUTE_API_KEY"
local OMNIROUTE_MODEL = "auto/fast"

-- Cap a value at a length that stays readable once `report` writes it into the
-- buffer as comment lines; an API error body can be arbitrarily long. Cuts on
-- character boundaries (`strcharpart`, not `string.sub`) so a multi-byte UTF-8
-- character in the body is never split in half.
local function truncate(text, limit)
  limit = limit or 300
  local head = vim.fn.strcharpart(text, 0, limit)
  if head == text then return text end
  return head .. "…"
end

-- LLM tool specs, in order of preference. `build(model)` returns the argument
-- list that prints a commit message; `stdin(diff, model)`, when set, maps the
-- diff to what that command reads on stdin (absent: the diff itself); both
-- receive the resolved model (see `resolve_model`), not `tool.model`, so a
-- substitution reaches every part of the request. `parse(stdout)`, when set,
-- extracts the message from its output, returning nil plus a reason on failure
-- (absent: the output is the message); `name`, when set, labels the tool in
-- messages instead of `exe`; `list_models`, when set, is a command that prints
-- the tool's available models (one per line) so a configured-but-deprecated
-- model can be detected and replaced.
local TOOLS = {
  {
    exe = "jetski",
    model = "gemini-3.6-flash",
    list_models = { "jetski", "models" },
    build = function(model) return { "jetski", "--model", model, "--print", JETSKI_PROMPT } end,
  },
  {
    -- OmniRoute speaks the OpenAI chat-completions API over HTTP. curl is
    -- spawned for it rather than using `vim.net.request`, which is GET-only, or
    -- plenary.curl, which is another wrapper around the same binary.
    exe = "curl",
    name = "OmniRoute",
    model = OMNIROUTE_MODEL,
    -- A routing strategy is not a model that can be deprecated, so there is
    -- nothing to validate against.
    list_models = nil,
    build = function()
      return {
        "curl",
        "-sS",
        "--max-time",
        "120",
        "-X",
        "POST",
        OMNIROUTE_BASE_URL .. "/chat/completions",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Authorization: Bearer " .. OMNIROUTE_API_KEY,
        -- Read the request body from stdin, so a large diff never runs into an
        -- argument length limit.
        "--data-binary",
        "@-",
      }
    end,
    stdin = function(diff, model)
      return vim.json.encode {
        model = model,
        -- `stream` has to be sent explicitly: the gateway otherwise replies
        -- with a server-sent event stream, which is not a JSON document.
        stream = false,
        messages = { { role = "user", content = PROMPT .. "\n\n" .. diff } },
      }
    end,
    parse = function(stdout)
      local ok, body = pcall(vim.json.decode, stdout)
      if not ok or type(body) ~= "table" then return nil, "response is not JSON: " .. truncate(stdout) end
      -- A failed request answers with an HTTP error status, which curl does not
      -- turn into a nonzero exit, so the body is the only signal of failure.
      if type(body.error) == "table" then return nil, body.error.message or truncate(stdout) end
      local choice = body.choices and body.choices[1]
      local content = choice and choice.message and choice.message.content
      -- A JSON null decodes to `vim.NIL`, which is truthy, hence the type check.
      if type(content) ~= "string" then return nil, "response has no message content: " .. truncate(stdout) end
      return content
    end,
  },
}

-- Resolve all available tool specs.
local function llm_tools()
  local available = {}
  for _, tool in ipairs(TOOLS) do
    if vim.fn.executable(tool.exe) == 1 then table.insert(available, tool) end
  end
  return available
end

-- Case-insensitive Levenshtein edit distance, used to pick the closest
-- still-available model when the configured one has been deprecated.
local function levenshtein(a, b)
  a, b = a:lower(), b:lower()
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local prev = {}
  for j = 0, lb do
    prev[j] = j
  end
  for i = 1, la do
    local curr = { [0] = i }
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      curr[j] = math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = curr
  end
  return prev[lb]
end

-- Given the configured model and the list of available ones, return the model
-- to use and whether a substitution was made. When the configured model is
-- available (or the list is unknown) it is used unchanged; otherwise the
-- closest name by edit distance is chosen.
local function resolve_model(want, available)
  if not available or #available == 0 then return want, false end
  -- Match case-insensitively but return the tool's own spelling, so a listing
  -- that only differs in case is used as-is rather than flagged as a swap.
  local lower = want:lower()
  for _, m in ipairs(available) do
    if m:lower() == lower then return m, false end
  end
  local best, best_dist
  for _, m in ipairs(available) do
    local dist = levenshtein(want, m)
    if not best_dist or dist < best_dist then
      best, best_dist = m, dist
    end
  end
  return best, true
end

-- Fetch `tool`'s available models asynchronously and invoke `cb(models_or_nil)`.
-- Any failure (no list command, nonzero exit, empty output) yields nil, so the
-- caller falls back to using the configured model as-is.
local function list_models(tool, cb)
  if not tool.list_models then return cb(nil) end
  vim.system(
    tool.list_models,
    { text = true },
    vim.schedule_wrap(function(out)
      if out.code ~= 0 then return cb(nil) end
      local models = {}
      for line in (out.stdout or ""):gmatch "[^\n]+" do
        local m = line:match "^%s*(%S+)"
        if m and m ~= "" then table.insert(models, m) end
      end
      cb(#models > 0 and models or nil)
    end)
  )
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

-- Strip a single Markdown code fence wrapping the whole message. Some LLM tools
-- return the commit message inside a ```…``` block; when the first line is an
-- opening fence and its matching closing fence is the last line, drop both so
-- the fence never lands in the commit message. To stay close to CommonMark and
-- avoid mangling real content:
--   * The opener must be a bare fence — a run of >=3 backticks plus an optional
--     language tag, nothing else. A line with text after the backticks (e.g.
--     "```feat: add x") is the message itself, not a wrapper.
--   * The close must be the *first* line, after the opener, that is a run of at
--     least as many backticks and nothing else. If it appears before the last
--     line, the message holds other content or additional code blocks rather
--     than one wrapping fence, so it is returned unchanged.
-- Also returns the message unchanged when it is not wrapped in a fence.
local function strip_code_fence(msg)
  local lines = vim.split(msg, "\n")
  if #lines < 2 then return msg end
  local fence = lines[1]:match "^%s*(```+)%s*[%w_+%-]*%s*$"
  if not fence then return msg end
  local closing = "^%s*" .. fence .. "`*%s*$"
  for i = 2, #lines do
    if lines[i]:match(closing) then
      if i == #lines then return vim.trim(table.concat(lines, "\n", 2, #lines - 1)) end
      return msg
    end
  end
  return msg
end

-- Strip a single pair of matching quotation marks wrapping the message. Some
-- LLM tools return the commit message as a quoted string (e.g. `"feat: add x"`
-- or `"Add workflow"`); when the whole message, or just its first line, is
-- wrapped in a balanced pair of quotes, drop that pair so the quotes never land
-- in the commit subject. Straight quotes (`"`, `'`, `` ` ``) and typographic
-- “smart” quotes are handled. Only a genuinely enclosing pair is removed — one
-- whose delimiters do not reappear inside — so an apostrophe within the text
-- (e.g. `fix: don't crash`) and two separate quoted spans (e.g. `"foo" and
-- "bar"`) are left untouched.
local function strip_surrounding_quotes(msg)
  -- Opening/closing pairs: straight quotes (open == close) and multibyte
  -- typographic quotes (open ~= close), written as UTF-8 byte escapes since
  -- Neovim's LuaJIT does not accept the `\u{XXXX}` form.
  local quote_pairs = {
    { '"', '"' },
    { "'", "'" },
    { "`", "`" },
    { "\xe2\x80\x9c", "\xe2\x80\x9d" }, -- “ ”
    { "\xe2\x80\x98", "\xe2\x80\x99" }, -- ‘ ’
  }
  -- Strip a wrap around `text`, returning it unquoted or nil when not wrapped.
  local function unwrap(text)
    for _, pair in ipairs(quote_pairs) do
      local open, close = pair[1], pair[2]
      if #text >= #open + #close and text:sub(1, #open) == open and text:sub(-#close) == close then
        local inner = text:sub(#open + 1, -#close - 1)
        if not inner:find(open, 1, true) and not inner:find(close, 1, true) then return inner end
      end
    end
    return nil
  end
  -- Whole-message wrap (typically a single-line, quoted subject).
  local whole = unwrap(vim.trim(msg))
  if whole then return vim.trim(whole) end
  -- First-line-only wrap: the subject is quoted but the body is not.
  local lines = vim.split(msg, "\n")
  local subject = unwrap(lines[1])
  if subject then
    lines[1] = vim.trim(subject)
    return table.concat(lines, "\n")
  end
  return msg
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
    -- Notify the user and also drop the message into the buffer as VCS
    -- comment(s), so the record survives after the notification fades. Split on
    -- newlines because buffer lines must not contain them (stderr may be
    -- multi-line); the comment prefix keeps it out of the final message.
    local function report(msg, level)
      vim.notify(msg, level)
      -- Only record the note while the buffer is still the empty auto-fill
      -- state, so a late failure never shifts text the user has begun typing.
      if not vim.api.nvim_buf_is_valid(buf) or not message_empty() then return end
      local comment = {}
      for _, line in ipairs(vim.split(msg, "\n", { trimempty = true })) do
        table.insert(comment, comment_prefix .. " " .. line)
      end
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, comment)
    end
    if not message_empty() then return end

    local tools = llm_tools()
    if #tools == 0 then
      report("Skipped commit message generation: no jetski/curl found", vim.log.levels.WARN)
      return
    end

    local cmd = type(diff_cmd) == "function" and diff_cmd(buf) or diff_cmd

    report("Generating diff using: " .. table.concat(cmd, " "), vim.log.levels.INFO)

    -- Run the diff, then feed its output to the LLMs on stdin. Each command
    -- runs directly (no shell), avoiding shell-quoting issues and the lack of
    -- `sh` on Windows.
    vim.system(
      cmd,
      { text = true },
      vim.schedule_wrap(function(diff_out)
        -- The diff can take a moment; skip the expensive LLM calls if the user
        -- has begun typing in the meantime.
        if not vim.api.nvim_buf_is_valid(buf) or not message_empty() then return end
        if diff_out.code ~= 0 then
          report("Failed to read diff (changes): " .. (diff_out.stderr or ""), vim.log.levels.ERROR)
          return
        end
        local diff = diff_out.stdout or ""
        -- Nothing to summarize; don't waste an LLM call on an empty diff.
        if vim.trim(diff) == "" then
          report("Skipped commit message generation: no diff to summarize", vim.log.levels.WARN)
          return
        end

        report("Diff generated by: " .. table.concat(cmd, " "), vim.log.levels.INFO)

        local function try_tool(index)
          if not vim.api.nvim_buf_is_valid(buf) or not message_empty() then return end
          local tool = tools[index]
          if not tool then
            report("Failed to generate commit message: all LLM tools failed.", vim.log.levels.ERROR)
            return
          end

          -- Look up the tool's available models first, so a configured model that has
          -- since been deprecated can be swapped for the closest one still offered.
          list_models(tool, function(available)
            -- The user may have started typing during the async model lookup; bail out
            -- so we neither notify nor kick off the LLM work over their text.
            if not vim.api.nvim_buf_is_valid(buf) or not message_empty() then return end
            local model, substituted = resolve_model(tool.model, available)
            local llm = tool.build(model)
            local label = tool.name or tool.exe

            report("Generating commit message using " .. label .. " (" .. model .. ")…", vim.log.levels.INFO)

            vim.system(
              llm,
              { text = true, stdin = tool.stdin and tool.stdin(diff, model) or diff },
              vim.schedule_wrap(function(out)
                if out.code ~= 0 then
                  report(
                    "Failed to generate commit message using " .. label .. " (" .. model .. "): " .. (out.stderr or ""),
                    vim.log.levels.ERROR
                  )
                  try_tool(index + 1)
                  return
                end
                -- Tools that answer with more than the message itself (an API
                -- response) extract it here, and report why when they cannot.
                local msg, err = vim.trim(out.stdout or ""), nil
                if tool.parse then
                  msg, err = tool.parse(msg)
                end
                if not msg then
                  report(
                    "Failed to generate commit message using " .. label .. " (" .. model .. "): " .. (err or ""),
                    vim.log.levels.ERROR
                  )
                  try_tool(index + 1)
                  return
                end
                msg = strip_surrounding_quotes(strip_code_fence(vim.trim(msg)))
                if msg == "" then
                  report("Generated empty message using " .. label .. " (" .. model .. ")", vim.log.levels.WARN)
                  try_tool(index + 1)
                  return
                end
                -- Re-check: the user may have started typing during the async call.
                if not vim.api.nvim_buf_is_valid(buf) or not message_empty() then return end
                local lines = vim.split(msg, "\n")
                -- Trailing empty line to separate the message from the VCS comments.
                table.insert(lines, "")
                -- Flag the substitution when the configured model was unavailable,
                -- so the author knows the message came from a different model.
                if substituted then
                  table.insert(
                    lines,
                    comment_prefix
                      .. " Note: configured model '"
                      .. tool.model
                      .. "' is unavailable; used the closest available model instead."
                  )
                end
                -- Record which tool and model produced this draft so the author
                -- knows its provenance and how much to scrutinize it. Grouped with
                -- the VCS comments, so it is stripped from the final message.
                table.insert(lines, comment_prefix .. " Commit message generated by " .. label .. " (" .. model .. ")")
                vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
              end)
            )
          end)
        end

        try_tool(1)
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
