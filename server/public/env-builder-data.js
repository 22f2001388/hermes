// Static catalog/schema data for env-builder. MUST load BEFORE env-builder.js — classic browser scripts share one global lexical scope.
// Model Catalogs
const MODEL_CATALOGS = {
  "LLM_MODEL": {
    "Anthropic": [
      "anthropic/claude-opus-4-7",
      "anthropic/claude-opus-4-6",
      "anthropic/claude-sonnet-4-6",
      "anthropic/claude-sonnet-4-5",
      "anthropic/claude-haiku-4-5",
      "anthropic/claude-haiku-3-5"
    ],
    "Gemini": [
      "gemini/gemini-3.5-flash",
      "gemini/gemini-3.1-flash-lite",
      "gemini/gemini-3-flash-preview",
      "gemini/gemini-2.5-flash",
      "gemini/gemini-2.5-flash-lite",
      "gemini/gemma-4-31b-it",
      "gemini/gemma-4-26b-a4b-it"
    ],
    "OpenAI": [
      "openai/gpt-4.1",
      "openai/gpt-4.1-mini",
      "openai/gpt-4o",
      "openai/gpt-4o-mini",
      "openai/o3",
      "openai/o4-mini",
      "openai/o3-mini"
    ],
    "OpenRouter": [
      "openrouter/anthropic/claude-opus-4-7",
      "openrouter/anthropic/claude-sonnet-4-6",
      "openrouter/anthropic/claude-haiku-4-5",
      "openrouter/openai/gpt-4o",
      "openrouter/openai/o3",
      "openrouter/google/gemini-2.5-flash",
      "openrouter/google/gemini-2.5-pro",
      "openrouter/meta-llama/llama-4-maverick",
      "openrouter/deepseek/deepseek-r1",
      "openrouter/deepseek/deepseek-chat-v3-5",
      "openrouter/mistralai/mistral-large"
    ],
    "DeepSeek": [
      "deepseek/deepseek-chat",
      "deepseek/deepseek-reasoner"
    ],
    "xAI": [
      "xai/grok-3",
      "xai/grok-3-mini",
      "xai/grok-2"
    ],
    "HuggingFace": [
      "huggingface/meta-llama/Llama-3.3-70B-Instruct",
      "huggingface/meta-llama/Llama-3.1-70B-Instruct",
      "huggingface/Qwen/Qwen2.5-72B-Instruct",
      "huggingface/mistralai/Mistral-7B-Instruct-v0.3",
      "huggingface/google/gemma-2-27b-it"
    ],
    "Moonshot / Kimi": [
      "moonshot/moonshot-v1-128k",
      "kimi-coding/kimi-k2-0711-preview",
      "kimi-coding-cn/kimi-k2-0711-preview"
    ],
    "Alibaba": [
      "alibaba/qwen-max",
      "alibaba/qwen-plus",
      "alibaba/qwen-turbo"
    ],
    "Minimax": [
      "minimax/minimax-01",
      "minimax-cn/minimax-01"
    ],
    "NVIDIA": [
      "nvidia/meta/llama-3.1-70b-instruct",
      "nvidia/meta/llama-3.3-70b-instruct"
    ],
    "GLM / ZAI": [
      "zai/glm-4-plus",
      "glm/chatglm-turbo"
    ],
    "Vercel AI Gateway": [
      "vercel-ai-gateway/anthropic/claude-sonnet-4-6",
      "vercel-ai-gateway/openai/gpt-4o"
    ],
    "Custom / OpenAI-compatible": [
      "custom"
    ]
  }
};

const ICONS = {
  "All":       "🌐",
  "Core":      "⚡",
  "Backup":    "💾",
  "Telegram":  "📱",
  "WebUI":     "🖥️",
  "Providers": "🔑",
  "Cloudflare":"☁️",
  "Advanced":  "⚙️",
  "Custom Env":"🔧"
};

// tag: "critical" | "credential" | "feature" | "optional" | "advanced" | "build"
const FIELDS = [
  // Core
  {
    "g": "Core", "icon": "⚡",
    "k": "GATEWAY_TOKEN",
    "lbl": "Gateway token — protects the Hermes web UI",
    "type": "password", "secret": 1, "common": 1, "tag": "critical"
  },
  {
    "g": "Core", "icon": "⚡",
    "k": "LLM_MODEL",
    "lbl": "Default model (provider/model-name format)",
    "type": "model", "options_key": "LLM_MODEL",
    "ph": "gemini/gemini-2.5-flash", "common": 1, "tag": "critical"
  },
  {
    "g": "Core", "icon": "⚡",
    "k": "LLM_API_KEY",
    "lbl": "API key for the chosen provider",
    "type": "password", "secret": 1, "common": 1, "tag": "credential"
  },

  // WebUI
  {
    "g": "WebUI", "icon": "🖥️",
    "k": "PRIMARY_UI",
    "lbl": "Landing page — webui (default) or the Hermes dashboard",
    "type": "select",
    "options": ["webui", "dashboard"],
    "ph": "webui", "common": 1, "tag": "feature"
  },
  {
    "g": "WebUI", "icon": "🖥️",
    "k": "HERMES_WEBUI_PASSWORD",
    "lbl": "WebUI login password (defaults to GATEWAY_TOKEN)",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "WebUI", "icon": "🖥️",
    "k": "HERMES_WEBUI_PORT",
    "lbl": "Internal WebUI port (proxied behind the public router)",
    "type": "number", "ph": "8787", "tag": "advanced"
  },
  {
    "g": "WebUI", "icon": "🖥️",
    "k": "HERMES_WEBUI_STATE_DIR",
    "lbl": "WebUI state directory",
    "type": "text", "ph": "/opt/data/webui", "tag": "advanced"
  },
  {
    "g": "WebUI", "icon": "🖥️",
    "k": "HERMES_WEBUI_DEFAULT_WORKSPACE",
    "lbl": "WebUI default workspace directory",
    "type": "text", "ph": "/opt/data/workspace", "tag": "advanced"
  },

  // Backup
  {
    "g": "Backup", "icon": "💾",
    "k": "HF_TOKEN",
    "lbl": "HuggingFace token — enables state backup to a private dataset",
    "type": "password", "secret": 1, "common": 1, "tag": "credential"
  },
  {
    "g": "Backup", "icon": "💾",
    "k": "BACKUP_DATASET_NAME",
    "lbl": "Name of the HF dataset used for backups",
    "type": "text", "ph": "hermes-backup", "common": 1, "tag": "optional"
  },
  {
    "g": "Backup", "icon": "💾",
    "k": "SYNC_INTERVAL",
    "lbl": "Backup sync ceiling — max seconds between change-driven syncs",
    "type": "number", "ph": "60", "tag": "optional"
  },

  // Telegram
  {
    "g": "Telegram", "icon": "📱",
    "k": "TELEGRAM_BOT_TOKEN",
    "lbl": "Telegram bot token from @BotFather",
    "type": "password", "secret": 1, "common": 1, "tag": "credential"
  },
  {
    "g": "Telegram", "icon": "📱",
    "k": "TELEGRAM_ALLOWED_USERS",
    "lbl": "Allowed Telegram user IDs (comma-separated)",
    "type": "text", "ph": "123456789,987654321", "common": 1, "tag": "feature"
  },
  {
    "g": "Telegram", "icon": "📱",
    "k": "TELEGRAM_MODE",
    "lbl": "Telegram update mode",
    "type": "select",
    "options": ["webhook", "polling"],
    "ph": "webhook", "tag": "optional"
  },
  {
    "g": "Telegram", "icon": "📱",
    "k": "TELEGRAM_WEBHOOK_URL",
    "lbl": "Override webhook URL (auto-detected from SPACE_HOST if blank)",
    "type": "text", "ph": "https://your-space.hf.space/telegram", "tag": "optional"
  },
  {
    "g": "Telegram", "icon": "📱",
    "k": "TELEGRAM_BASE_URL",
    "lbl": "Custom Telegram API base URL (for proxies)",
    "type": "text", "ph": "https://proxy.example.com/bot", "tag": "optional"
  },

  // Providers
  {
    "g": "Providers", "icon": "🔑",
    "k": "ANTHROPIC_API_KEY",
    "lbl": "Anthropic API key",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "ANTHROPIC_API_KEYS",
    "lbl": "Anthropic API key pool (comma-separated; rotated round-robin)",
    "type": "textarea", "ph": "key1, key2, key3", "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "OPENAI_API_KEY",
    "lbl": "OpenAI API key",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "OPENAI_API_KEYS",
    "lbl": "OpenAI API key pool (comma-separated; rotated round-robin)",
    "type": "textarea", "ph": "key1, key2, key3", "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "GOOGLE_API_KEY",
    "lbl": "Google / Gemini API key",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "GEMINI_API_KEY",
    "lbl": "Gemini API key (alias for GOOGLE_API_KEY)",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "GEMINI_API_KEYS",
    "lbl": "Gemini API key pool (comma-separated; rotated round-robin)",
    "type": "textarea", "ph": "key1, key2, key3", "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "OPENROUTER_API_KEY",
    "lbl": "OpenRouter API key",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "OPENROUTER_API_KEYS",
    "lbl": "OpenRouter API key pool (comma-separated; rotated round-robin)",
    "type": "textarea", "ph": "key1, key2, key3", "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "DEEPSEEK_API_KEY",
    "lbl": "DeepSeek API key",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "DEEPSEEK_API_KEYS",
    "lbl": "DeepSeek API key pool (comma-separated; rotated round-robin)",
    "type": "textarea", "ph": "key1, key2, key3", "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "XAI_API_KEY",
    "lbl": "xAI (Grok) API key",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "XAI_API_KEYS",
    "lbl": "xAI (Grok) API key pool (comma-separated; rotated round-robin)",
    "type": "textarea", "ph": "key1, key2, key3", "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "HERMES_INFERENCE_PROVIDER",
    "lbl": "Force Hermes inference provider (overrides auto-detect)",
    "type": "select",
    "options": ["auto", "anthropic", "openai", "gemini", "openrouter", "huggingface", "custom", "deepseek", "xai"],
    "ph": "auto", "tag": "advanced"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "CUSTOM_BASE_URL",
    "lbl": "Custom OpenAI-compatible base URL",
    "type": "text", "ph": "https://your-api.example.com/v1", "tag": "feature"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "CUSTOM_API_KEY",
    "lbl": "API key for the custom provider",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "CUSTOM_PROVIDER",
    "lbl": "Provider name for custom endpoints",
    "type": "text", "ph": "custom", "tag": "advanced"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "CUSTOM_MODEL_CONTEXT_LENGTH",
    "lbl": "Context length for custom model",
    "type": "number", "ph": "131072", "tag": "advanced"
  },
  {
    "g": "Providers", "icon": "🔑",
    "k": "CUSTOM_MODEL_MAX_TOKENS",
    "lbl": "Max output tokens for custom model",
    "type": "number", "ph": "8192", "tag": "advanced"
  },

  // Cloudflare
  {
    "g": "Cloudflare", "icon": "☁️",
    "k": "CLOUDFLARE_WORKERS_TOKEN",
    "lbl": "Cloudflare Workers API token (for Telegram proxy setup)",
    "type": "password", "secret": 1, "tag": "credential"
  },
  {
    "g": "Cloudflare", "icon": "☁️",
    "k": "CLOUDFLARE_PROXY_URL",
    "lbl": "Cloudflare proxy URL for Telegram (if already deployed)",
    "type": "text", "ph": "https://your-worker.your-subdomain.workers.dev", "tag": "feature"
  },
  {
    "g": "Cloudflare", "icon": "☁️",
    "k": "CLOUDFLARE_PROXY_DEBUG",
    "lbl": "Enable Cloudflare proxy debug logging",
    "type": "toggle", "ph": "false", "tag": "advanced"
  },

  // Advanced
  {
    "g": "Advanced", "icon": "⚙️",
    "k": "WEBHOOK_URL",
    "lbl": "URL to POST a JSON notification on gateway (re)start",
    "type": "text", "ph": "https://...", "tag": "optional"
  },
  {
    "g": "Advanced", "icon": "⚙️",
    "k": "GATEWAY_READY_TIMEOUT",
    "lbl": "Seconds to wait for gateway API port before failing",
    "type": "number", "ph": "120", "tag": "advanced"
  },
  {
    "g": "Advanced", "icon": "⚙️",
    "k": "API_SERVER_PORT",
    "lbl": "Hermes gateway internal API port",
    "type": "number", "ph": "8642", "tag": "advanced"
  },
  {
    "g": "Advanced", "icon": "⚙️",
    "k": "DASHBOARD_PORT",
    "lbl": "Hermes dashboard internal port",
    "type": "number", "ph": "9119", "tag": "advanced"
  },
  {
    "g": "Advanced", "icon": "⚙️",
    "k": "HERMES_BACKGROUND_NOTIFICATIONS",
    "lbl": "Background process notification level",
    "type": "select",
    "options": ["result", "progress", "none"],
    "ph": "result", "tag": "optional"
  },
  {
    "g": "Advanced", "icon": "⚙️",
    "k": "TELEGRAM_WEBHOOK_SECRET",
    "lbl": "Secret token for Telegram webhook validation (auto-generated if blank)",
    "type": "password", "secret": 1, "tag": "credential"
  }
];
