# Agents: App Privacy answers (App Store Connect › App Privacy)

Prepared 2026-10-03, matching the 1.0 code.

## Data collection: "No, we do not collect data from this app"

Why this is accurate:
- No analytics, ads, crash reporting or tracking SDKs. The app has no package dependencies at all.
- No server run by the developer. The only network calls are:
  - to the AI provider the user picked (Anthropic, OpenAI, Google, xAI, OpenRouter, Mistral, DeepSeek, Groq), with the user's own key, after an explicit permission prompt;
  - to Apple's CloudKit, into the user's own private iCloud database (sync). Apple's own services aren't "collection" by the developer.
- Apple counts data as "collected" when the developer or its partners can access it. The developer can't access any of it, and the AI provider isn't a partner of the developer: the user has their own account and contract with it. Learn Business gave the same answer for the same setup.

## Tracking: No

## Privacy Policy URL
https://agents.keak.app/privacy.html

## Age rating questionnaire (suggested)
- No violence, sexual content, gambling, contests or user-to-user communication with other people.
- Unrestricted web access: No (there is no browser; agents on Claude models can run web searches and show source links).
- Medical or treatment information: Infrequent/Mild (users can create health agents).
- If asked about AI chatbots / generative AI: Yes.
Expected result: 13+ (accept whatever Apple's questionnaire produces).

## Export compliance
ITSAppUsesNonExemptEncryption = NO is set in the build (HTTPS only), so no questions on upload.
