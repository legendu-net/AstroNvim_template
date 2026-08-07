-- Replace the bare URL under the cursor with a Markdown link whose text is the
-- page's `<title>`, so `https://example.com` becomes
-- `[Example Domain](https://example.com)`.
--
-- Adapted from https://dbiswas.com/blog/titling-markdown-links-in-neovim/. That
-- reference implementation shells out to two helper scripts (`web-title.sh` and
-- `htmldecode.sh`) that have to be installed on `$PATH`, and fetches
-- synchronously, freezing Neovim until the page responds. This version keeps the
-- title extraction and entity decoding in Lua so only `curl` is needed, and
-- fetches asynchronously, tracking the URL with an extmark so the replacement
-- still lands on the right text if the buffer is edited while the request is in
-- flight.
--
-- Known limitation: the response is assumed to be UTF-8. `curl` does not
-- transcode, so a page served as ISO-8859-1 or Shift-JIS with a non-ASCII title
-- yields mojibake. Titles written with HTML entities are decoded correctly
-- regardless of the page encoding.

-- Seconds to wait for the page before giving up.
local FETCH_TIMEOUT = 10
-- Some sites serve a stub (or a 403) to curl's default user agent, which would
-- yield a useless title, so present a browser-like one instead.
local USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

-- The named HTML entities that realistically show up in a `<title>`. Numeric
-- entities are handled generically, so only the named ones need listing.
local ENTITIES = {
  amp = "&",
  apos = "'",
  bull = "•",
  gt = ">",
  hellip = "…",
  ldquo = "“",
  lsquo = "‘",
  lt = "<",
  mdash = "—",
  ndash = "–",
  quot = '"',
  rdquo = "”",
  rsquo = "’",
}

-- The Latin-1 named entities, which carry the accented letters that show up in
-- real titles. They are contiguous from U+00A0, so listing the names in
-- codepoint order avoids spelling out each number.
do
  local names = [[
    nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg
    macr deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo
    frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil
    Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute
    Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig
    agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml
    igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide
    oslash ugrave uacute ucirc uuml yacute thorn yuml
  ]]
  local code = 0xA0
  for name in names:gmatch "%S+" do
    ENTITIES[name] = vim.fn.nr2char(code, 1)
    code = code + 1
  end
  -- A literal non-breaking space in link text is invisible trouble, and a normal
  -- space reads the same, so override the one this loop just installed.
  ENTITIES.nbsp = " "
end

-- A URL candidate as it appears in a buffer. Whitespace ends it, and so do the
-- characters that delimit surrounding markup (`<>` for an autolink, `[]` for a
-- link, and quotes), without which a run like `[https://a.com](https://b.com)`
-- would be swallowed whole as a single malformed URL. Parentheses are
-- deliberately included, since URLs do legitimately contain them; a trailing one
-- is dealt with below.
local URL_PATTERN = "https?://[^%s<>%[%]\"'`]*"

-- Closing brackets that may legitimately appear inside a URL, mapped to their
-- opener, used to decide whether a trailing one belongs to the URL.
local CLOSERS = { [")"] = "(", ["}"] = "{" }

-- Decode the HTML entities in `text`. Unknown entities are left as-is rather
-- than dropped, so nothing is silently lost from the title.
local function decode_entities(text)
  -- Assigned rather than returned directly, so `gsub`'s substitution count is
  -- dropped without wrapping the whole call in parentheses.
  local decoded = text:gsub("&(#?%w+);", function(entity)
    local hex = entity:match "^#[Xx](%x+)$"
    local code = hex and tonumber(hex, 16) or tonumber(entity:match "^#(%d+)$")
    if code then
      -- Surrogates and out-of-range values are not encodable; leave them alone.
      if code < 1 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then return nil end
      return vim.fn.nr2char(code, 1)
    end
    -- Named references are case-sensitive: `&Eacute;` is É, not é.
    return ENTITIES[entity]
  end)
  return decoded
end

-- Lua patterns have no case-insensitive flag, hence the spelled-out classes.
local TITLE_OPEN = "<[Tt][Ii][Tt][Ll][Ee]"
local TITLE_CLOSE = "</[Tt][Ii][Tt][Ll][Ee]%s*>"

-- Pull the page title out of `html`, or nil when there is none. `.` matches
-- newlines, so a title split across lines is captured whole and then collapsed
-- onto one line. Both `<title>` and `<title lang="en">` have to match while
-- `<titlebar>` must not, so the tag name is required to be followed by `>` or
-- whitespace; Lua patterns have no alternation, hence the two attempts.
local function extract_title(html)
  local title = html:match(TITLE_OPEN .. ">(.-)" .. TITLE_CLOSE)
    or html:match(TITLE_OPEN .. "%s[^>]*>(.-)" .. TITLE_CLOSE)
  if not title then return nil end
  title = vim.trim((decode_entities(title):gsub("%s+", " ")))
  return title ~= "" and title or nil
end

-- Sentence punctuation and Markdown markers that trail a URL in prose without
-- being part of it, so that `**https://a.com**` and `https://a.com.` both yield
-- a clean URL. Quotes and backticks are absent because `URL_PATTERN` already
-- stops before them. `_` is absent too: it is common enough inside real URLs
-- that stripping a trailing one would do more harm than handling `_url_`.
local TRAILING = "[%.,;:!%?%*]"

-- Strip the punctuation that trails a URL in prose but is not part of it. A
-- closing bracket is only dropped when it is unbalanced, so URLs that genuinely
-- contain one (Wikipedia's `..._(disambiguation)`, for instance) survive.
local function trim_trailing_punctuation(url)
  while #url > 0 do
    local last = url:sub(-1)
    local opener = CLOSERS[last]
    if opener then
      local _, opens = url:gsub("%" .. opener, "")
      local _, closes = url:gsub("%" .. last, "")
      if closes <= opens then break end
    elseif not last:match(TRAILING) then
      break
    end
    url = url:sub(1, -2)
  end
  return url
end

-- Find the URL the cursor is on, returning it together with the 0-indexed start
-- and exclusive end byte columns of the text to replace, or nil when there is
-- none. `col` is the cursor's 0-indexed byte column. The span is the URL itself
-- except for an autolink, where it widens to take in the angle brackets.
--
-- The line is scanned directly rather than going through `<cWORD>`: a WORD is
-- only whitespace-delimited, so it can span several URLs, and a URL recovered
-- from one still has to be located back in the line. Scanning here yields the
-- span as a by-product, so the URL and its position cannot disagree.
--
-- Every candidate is considered and the one nearest the cursor wins, because the
-- cursor commonly rests just outside the URL — on the period of
-- `https://a.com.` — which is inside no candidate at all; taking the first match
-- would then rewrite an unrelated URL earlier on the line.
local function url_at_cursor(line, col)
  local best
  local init = 1
  while true do
    local start, stop = line:find(URL_PATTERN, init)
    if not start then break end
    -- Resume past the untrimmed match, so the punctuation trimmed off below is
    -- never rescanned as the start of another candidate.
    init = stop + 1
    local url = trim_trailing_punctuation(line:sub(start, stop))
    -- Require at least one character of authority, so a bare scheme is skipped.
    if url:match "^https?://%S" then
      stop = start + #url - 1
      -- Zero while the cursor is within the candidate, else the gap to it.
      local distance = math.max(start - 1 - col, col - (stop - 1), 0)
      if not best or distance < best.distance then
        -- An autolink's angle brackets are part of the link syntax being
        -- replaced, so the span covers them even though they are not part of
        -- the URL; leaving them behind would yield `<[Title](url)>`.
        local first, last = start, stop
        if line:sub(first - 1, first - 1) == "<" and line:sub(last + 1, last + 1) == ">" then
          first, last = first - 1, last + 1
        end
        best = { url = url, start_col = first - 1, end_col = last, distance = distance }
      end
      if distance == 0 then break end
    end
  end
  if best then return best.url, best.start_col, best.end_col end
end

-- Render `title` and `url` as a Markdown inline link. A fetched title is plain
-- text, so every character that would otherwise be read as markup is escaped:
-- brackets would end the link text early, and `*`, `_` and `` ` `` would render
-- part of the title as emphasis or code rather than as itself. `<` is escaped
-- too, so a title such as `A <script> tag` cannot inject raw HTML.
local function format_link(title, url)
  local text = title:gsub("([\\%[%]%*_`<])", "\\%1")
  -- Parentheses delimit the destination, so any inside the URL are escaped.
  -- Backslash escapes are used in preference to the `<...>` destination form,
  -- which provides no way to escape a `>` occurring within the URL.
  local destination = url:gsub("([\\%(%)])", "\\%1")
  return ("[%s](%s)"):format(text, destination)
end

local ns = vim.api.nvim_create_namespace "markdown_link_title"

-- Drop the extmark, tolerating a buffer wiped while the fetch was in flight;
-- `nvim_buf_del_extmark` throws on an invalid buffer rather than no-opping.
local function clear_mark(buf, mark)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_del_extmark(buf, ns, mark) end
end

-- Replace the extmark's range with `link`, provided it still holds exactly
-- `original`, the text the range covered when the fetch started. Anything else
-- means the user edited over it while the request was in flight, so their text
-- is left alone.
local function replace_url(buf, mark, original, link)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })
  vim.api.nvim_buf_del_extmark(buf, ns, mark)
  if not pos[1] then return end
  local row, col, details = pos[1], pos[2], pos[3]
  local ok, current = pcall(vim.api.nvim_buf_get_text, buf, row, col, details.end_row, details.end_col, {})
  if not ok or #current ~= 1 or current[1] ~= original then
    return vim.notify("Skipped titling the URL: the text changed while it was being fetched", vim.log.levels.WARN)
  end
  -- Re-checked here as well as up front, since the buffer may have been made
  -- read-only (or reloaded) during the fetch.
  if not vim.bo[buf].modifiable then
    return vim.notify("Skipped titling the URL: the buffer is no longer modifiable", vim.log.levels.WARN)
  end
  vim.api.nvim_buf_set_text(buf, row, col, details.end_row, details.end_col, { link })
end

-- Title the URL under the cursor in `buf`.
local function add_title_to_url(buf)
  if vim.fn.executable "curl" ~= 1 then
    return vim.notify("Titling a URL requires `curl`, which is not executable", vim.log.levels.ERROR)
  end
  if not vim.bo[buf].modifiable then
    return vim.notify("Cannot title the URL: the buffer is not modifiable", vim.log.levels.ERROR)
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local url, start_col, end_col = url_at_cursor(line, col)
  if not url then return vim.notify("The cursor is not on an http(s) URL", vim.log.levels.WARN) end
  -- A URL right after `](` is already a link destination, and one right before
  -- it is that link's text; titling either would nest a link inside a link.
  if line:sub(1, start_col):sub(-2) == "](" or line:sub(end_col + 1, end_col + 2) == "](" then
    return vim.notify("The URL is already part of a Markdown link", vim.log.levels.WARN)
  end

  -- The exact text being replaced, which for an autolink includes the angle
  -- brackets around the URL. Kept so the async landing can confirm the range
  -- still holds it.
  local original = line:sub(start_col + 1, end_col)
  -- The default gravity is what is wanted at both ends: text typed at either
  -- boundary stays outside the tracked range, so continuing to type the sentence
  -- while the page loads still leaves the range holding exactly this text.
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, row - 1, start_col, { end_col = end_col })

  vim.notify("Fetching the title of " .. url .. "…", vim.log.levels.INFO)
  -- `-L` follows redirects and `-f` suppresses the body of an error page, whose
  -- `<title>` would otherwise be used as the link text.
  local cmd = { "curl", "-sSLf", "--max-time", tostring(FETCH_TIMEOUT), "-A", USER_AGENT, url }
  vim.system(
    cmd,
    { text = true, timeout = (FETCH_TIMEOUT + 5) * 1000 },
    vim.schedule_wrap(function(out)
      if out.code ~= 0 then
        clear_mark(buf, mark)
        local reason = vim.trim(out.stderr or "")
        if reason == "" then reason = "curl exited with code " .. out.code end
        return vim.notify("Failed to fetch " .. url .. ": " .. reason, vim.log.levels.ERROR)
      end
      local title = extract_title(out.stdout or "")
      if not title then
        clear_mark(buf, mark)
        return vim.notify("No <title> found at " .. url, vim.log.levels.WARN)
      end
      replace_url(buf, mark, original, format_link(title, url))
    end)
  )
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    autocmds = {
      markdown_link_title = {
        {
          event = "FileType",
          -- `FileType` matches the filetype as a whole rather than per
          -- dot-separated component, so the compound filetypes need spelling
          -- out for `markdown.myst` (set for the `blog` project in
          -- `astrocore.lua`) to be covered too.
          pattern = { "markdown", "markdown.*" },
          desc = "Map <LocalLeader>at to title the URL under the cursor",
          callback = function(args)
            vim.keymap.set(
              "n",
              "<LocalLeader>at",
              function() add_title_to_url(args.buf) end,
              { buffer = args.buf, desc = "Add title to URL" }
            )
          end,
        },
      },
    },
  },
}
