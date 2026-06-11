return {
  "yetone/avante.nvim",
  opts = {
    -- add any opts here
    -- this file can contain specific instructions for your project
    instructions_file = "AGENTS.md",
    -- for example
    provider = "gemini",
    providers = {
      gemini = {
        -- model = "gemini-3.1-flash-lite-preview",
        model = "gemini-3.1-pro-preview",
        -- api_key_name = { "gopass", "show", "-o", "gemini/token" },
        -- api_key_name = "cmd:gopass show -o gemini/token",
        extra_request_body = {
          temperature = 0,
        },
      },
      claude = {
        endpoint = "https://api.anthropic.com",
        model = "claude-opus-4-8",
        timeout = 30000, -- Timeout in milliseconds
        extra_request_body = {
          temperature = 0.75,
          max_tokens = 20480,
        },
      },
      moonshot = {
        endpoint = "https://api.moonshot.ai/v1",
        model = "kimi-k2-0711-preview",
        timeout = 30000, -- Timeout in milliseconds
        extra_request_body = {
          temperature = 0.75,
          max_tokens = 32768,
        },
      },
    },
  },
}
