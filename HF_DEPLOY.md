# HF Deploy: N Hermes Agents on Hugging Face Spaces

One baked image → N independent HF Space agents. Each agent differs by Telegram bot, allowed chat, and persona — configured via Space secrets injected at boot.

## Architecture

| Layer | Detail |
|---|---|
| Base image | Single Docker build from this repo. All agents share the same image. |
| Per-agent diff | `AGENT_NAME` selects a `.soul` persona. Space env vars inject token, chats, keys at boot via `hermes config set`. |
| Storage | HF persistent storage (`/data`). Each agent scopes under `/data/<AGENT_NAME>/`. |
| Respawn | `entrypoint.sh` auto-restarts the gateway on crash. |

## Environment Variables (Space Secrets)

| Variable | Required | Description |
|---|---|---|
| `AGENT_NAME` | Yes | Matches a `.hermes/souls/<AGENT_NAME>.soul` file. Must be stable per Space (never change after first deploy — changes agent identity). |
| `TELEGRAM_BOT_TOKEN` | Yes | Unique Telegram bot token (one per agent, from BotFather). |
| `TELEGRAM_ALLOWED_CHATS` | Yes | Comma-separated chat IDs the bot responds to. |
| `GEMINI_API_KEY` | Yes | Primary Gemini API key. |
| `GEMINI_API_KEY_1` | No | Secondary key (round-robin). |
| `GEMINI_API_KEY_2` | No | Tertiary key. |
| `GEMINI_API_KEY_3` | No | Quaternary key. |
| `GEMINI_API_KEY_4` | No | Quinary key. |
| `AGENT_PERSONALITY` | No | Override `display.personality` (default: `kawaii`). |
| `HF_TOKEN` | No | Hugging Face token (for model access). |

## Deploy Agent N

1. **Create the soul:** Add `.hermes/souls/<AGENT_NAME>.soul` in this repo with the agent's persona/identity prompt.

2. **Build & push to HF:**
   ```bash
   git add -A
   git commit -m "feat: add <AGENT_NAME> soul"
   git push
   ```

3. **Create a new HF Space** from this repo (`sdk: docker`).

4. **Set Space secrets** — every variable from the table above.

5. **Enable persistent storage** in Space settings (`/data`).

6. **Deploy.** The Space builds the image and boots the agent.

## Important Notes

- **Stable AGENT_NAME:** Never change `AGENT_NAME` for an existing Space. It scopes persistent storage at `/data/<AGENT_NAME>/`. Changing it orphans all state (sessions, memories, logs).
- **Token rotation:** If a token is compromised, rotate it via BotFather and update the Space secret. Rebuild+redeploy the Space to apply.
- **Propagation:** Config changes (souls, base config) require a rebuild+redeploy. Image-level changes are shared by all agents.
- **Respawn on crash:** The entrypoint loops forever, restarting the gateway on any non-zero exit.
