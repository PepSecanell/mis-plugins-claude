# App Review notes (paste into App Store Connect › App Review Information › Notes)

Sign-in required: NO (the app has no accounts).

---

Agents is a free chat app for your own team of AI agents. It has no accounts, no in-app purchases and no server of ours: it calls AI providers directly with an API key the user supplies from their own provider account (bring-your-own-key). The user pays their provider directly. We do not sell anything, and the app does not link to any purchase.

HOW TO TEST
1. Open the app and tap the gear (Settings) › Anthropic (Claude).
2. Paste this test key: [PASTE A TEST ANTHROPIC KEY HERE, with a low spend limit set at console.anthropic.com]
3. Tap Save key. The app shows a permission prompt before any data is sent to the provider (guideline 5.1.2(i)). Tap Allow. The app checks the key and loads its models.
4. Go back and open the "Chief" chat. Send: "Build me a small team of agents to help me get fit."
   Chief asks a few questions, then creates agents (they appear as "Created …" lines in the chat and in the Agents row) and can create a group chat for them.
5. Long-press any message to Copy, Reply, Share, Select Text or Retry.

The same build runs on Mac (universal purchase).

PRIVACY AND THIRD-PARTY AI (5.1.1 / 5.1.2(i))
- Before any data is sent to an AI provider, the app shows a prompt naming the provider and listing what is sent (messages, agent instructions, saved "About me" facts). Nothing is sent until the user taps Allow.
- Data goes directly from the device to the provider the user chose. We never receive it. The privacy policy (https://agents.keak.app/privacy.html) names every provider.
- Agents, chats and memory sync only through the user's private iCloud database (CloudKit).

CONTENT
Agents are general-purpose assistants created by the user. The default main agent's instructions tell it to recommend a professional for medical, legal or financial decisions.

Contact: Pep Secanell, keoly.app@gmail.com
