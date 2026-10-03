# Agents

A native iPhone + Mac app for your own team of AI agents, modelled on xAI's **Grok Bot**. It runs on Claude.

- **Agents (bots):** each has a name, emoji avatar, color, label (Health, YouTube…), specialty and its own instructions. Create as many as you want. **Write with AI** drafts the instructions from one sentence.
- **Main agent:** your chief of staff (by default **Don't Die**). It leads group chats and coordinates the specialists.
- **1-on-1 chats:** tap any agent to talk to it directly.
- **Group chats (2–6 agents):** the main agent answers and can **hand off** to whoever fits best. `@Name` asks a specific agent and `@everyone` asks all of them. Hand-offs appear in the chat, like in Grok Bot.
- **Agents talk to each other:** any agent can privately **consult** teammates, several at once in parallel. You see this as a collapsible *"Consulted 3 agents"* panel above the answer, like Grok's multi-agent panel, with each agent's question and reply.
- **Shared memory ("About me"):** agents save facts about you (goals, weight, routine, channel niche…) and every agent can read them. You can view and edit them in Settings.
- **Web search per agent:** on for YouTube Scout, off by default for the others.
- **iCloud sync:** agents, chats and memory sync between iPhone and Mac. Your API key syncs through iCloud Keychain.

## Starter team

| Agent | Label | What it does |
|---|---|---|
| 🧬 Don't Die (main) | Health | Longevity chief of staff built on the Don't Die / Blueprint philosophy. Coordinates the others. |
| 🍉 Nutrition | Health | Raw vegan fruitarian meals, calories and micronutrients (B12, D, omega-3, iodine…). |
| 🏋️ Workouts | Health | Strength, zone 2, VO2 max, mobility and recovery plans. |
| 🗓️ Daily Coach | Health | "What should I do today?": concrete schedules, routines and accountability. |
| 🎬 YouTube Scout | YouTube | Researches video ideas with web search: trends, outliers, titles, hooks. |

A **Health Team** group chat with the four health agents is pinned on first launch.

## Install on your iPhone and Mac

You need a Mac with **Xcode 16 or newer** and your Apple Developer account.

1. Open `apps/Agents/Agents.xcodeproj` in Xcode.
2. Select the **Agents** target → **Signing & Capabilities** → choose your **Team**.
   - If `com.keoly.agents` is taken, change the bundle id (for example `com.yourname.agents`). Then change the iCloud container in the **iCloud** section to match, for example `iCloud.com.yourname.agents`. You must also update the two `.entitlements` files.
   - In the **iCloud** section, make sure the container `iCloud.com.keoly.agents` is ticked. Press **+** to create it if Xcode asks.
3. **iPhone:** plug it in (or use Wi-Fi pairing), pick it as the run destination, and press **Run** (⌘R). The first time, go to Settings → Privacy & Security → turn on Developer Mode, and trust your developer certificate.
4. **Mac:** pick **My Mac** as the destination and press **Run**. To keep it installed, use Product → Archive → Distribute App → Custom → Copy App, then drag it into Applications.
5. **To keep it for good (recommended):** Product → Archive → Distribute App → **TestFlight & App Store**. The build then shows up in the TestFlight app on your iPhone and Mac, and it won't expire after 7 days like a direct install from a free account.
6. Open the app → ⚙️ Settings → paste your **Anthropic API key** (from console.anthropic.com → API Keys).

> iCloud sync only works in signed builds with the iCloud capability. If it isn't set up, the app still works but keeps data on each device separately.

## Costs

You pay Anthropic directly for what you use. Each agent picks its own model:

- **Opus 5.5** (default): smartest. $4 input / $20 output per million tokens.
- **Sonnet 5.5**: faster, half the price.
- **Haiku 4.5**: cheapest.

A typical chat message costs about 1–5 cents. A message where the main agent consults three specialists costs roughly four times that. Web search adds about $0.01 per search. Lowering an agent's **thinking effort** makes it faster and cheaper.

## How it works (for developers)

- `Services/ClaudeClient.swift` is a raw-HTTP Messages API client with SSE streaming. There is no official Swift SDK.
- `Services/AgentEngine.swift` runs the agent loop:
  - Tools: `ask_agent` (private consult; parallel calls run concurrently, up to two levels deep), `hand_off` (group chats), `remember` / `forget` (shared memory), and the server-side `web_search` tool.
  - Adaptive thinking (summarized, shown as "Reasoning") and `output_config.effort` per agent.
  - Automatic prompt caching.
  - `fallbacks: "default"`: if a safety classifier declines a request, the API retries it on a fallback model.
  - Within a tool loop, content blocks are echoed back unchanged. Across turns, only the final text is replayed, so the history stays append-only.
- `Services/SeedData.swift` holds the starter agents and their prompts. Edit it to change the defaults.
- `Models/*.swift` are SwiftData models that follow CloudKit's rules: every property has a default, and relationships are optional.
- Regenerate the Xcode project after adding files: `gem install xcodeproj && ruby generate_project.rb`. You can also add the files in Xcode directly.

## Ideas for next versions

- **Routines:** scheduled check-ins, like Grok Bot routines ("Daily Coach, every morning at 7"). This needs a small server or background task.
- Apple Health data (sleep, HRV, steps) for Don't Die.
- Voice mode, and photo input (meal photos for Nutrition).
- Home-screen widget with today's plan.
