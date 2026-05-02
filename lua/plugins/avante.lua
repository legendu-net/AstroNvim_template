return {
  "yetone/avante.nvim",
  build = "make BUILD_FROM_SOURCE=true",
  opts = {
    provider = "gemini",
    providers = {
      gemini = {
        model = "gemini-3.1-flash-lite-preview",
        extra_request_body = {
          temperature = 0,
        },
      },
    },
  },
}
