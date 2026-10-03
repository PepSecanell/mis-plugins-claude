#if DEBUG
import Foundation
import SwiftData

/// Sample team and chats for App Store screenshots. Debug builds only, and only when launched
/// with `-demo YES`; `-demoOpen "<chat title>"` opens that chat. Replaces everything in the store.
enum DemoContent {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }

    @MainActor
    static func load(into context: ModelContext) {
        try? context.delete(model: ChatMessage.self)
        try? context.delete(model: Conversation.self)
        try? context.delete(model: Agent.self)
        try? context.delete(model: MemoryItem.self)

        let chief = SeedData.mainAgent()
        let coach = Agent(name: "Coach", emoji: "🏃", colorHex: "#46A758", team: "Health",
                          tagline: "Short, realistic workouts that fit a busy student schedule.", instructions: "",
                          sortOrder: 1)
        let chef = Agent(name: "Chef", emoji: "🥗", colorHex: "#F76B15", team: "Health",
                         tagline: "Quick, cheap, high-protein meals you can cook in 20 minutes.", instructions: "",
                         sortOrder: 2)
        let tutor = Agent(name: "Tutor", emoji: "📚", colorHex: "#3E63DD", team: "Study",
                          tagline: "Exam plans, spaced review and explaining hard topics simply.", instructions: "",
                          sortOrder: 3)
        let money = Agent(name: "Money", emoji: "💶", colorHex: "#FFC53D", team: "Finance",
                          tagline: "Budgets, saving goals and making sense of your spending.", instructions: "",
                          sortOrder: 4)
        chef.provider = Provider.openai.rawValue
        chef.model = "gpt-5.4-mini"
        for agent in [chief, coach, chef, tutor, money] { context.insert(agent) }

        let start = Date().addingTimeInterval(-3600)
        var clock = start
        func next() -> Date { clock = clock.addingTimeInterval(40); return clock }

        // 1-on-1 with Chief: building the team.
        let chiefChat = Conversation(title: chief.name, isGroup: false, memberIDs: [chief.id])
        chiefChat.pinned = true
        context.insert(chiefChat)
        add(.user, "I want to get fit and eat better, but I'm busy with exams until June. Can you help?",
            to: chiefChat, at: next(), context)
        add(.agent, """
            Definitely. With exams on, the plan has to be small and automatic, not heroic. Here's the team I'd set up:

            - 🏃 **Coach**: 3 short workouts a week, 25 minutes max, no gym needed
            - 🥗 **Chef**: quick high-protein meals and a simple weekly shop
            - 📚 **Tutor**: a revision timetable that leaves room for both

            I'll put Coach and Chef in a **Health Team** chat so they plan together.
            """, agent: chief, to: chiefChat, at: next(), context)
        add(.user, "Perfect, do it", to: chiefChat, at: next(), context)
        add(.notice, "Created 🏃 Coach", to: chiefChat, at: next(), context)
        add(.notice, "Created 🥗 Chef", to: chiefChat, at: next(), context)
        add(.notice, "Created 📚 Tutor", to: chiefChat, at: next(), context)
        add(.notice, "Created group chat Health Team", to: chiefChat, at: next(), context)
        add(.agent, """
            Done! Your team is ready. **Health Team** is pinned at the top of your chats.

            One question so Coach can start: how many days a week can you realistically train?
            """, agent: chief, to: chiefChat, at: next(), context)

        // Group chat with consults.
        let group = Conversation(title: "Health Team", isGroup: true, memberIDs: [chief.id, coach.id, chef.id])
        group.pinned = true
        context.insert(group)
        add(.user, "Plan my week: 3 workouts and easy dinners. I only have 30 minutes a day.",
            to: group, at: next(), context)
        let reply = add(.agent, """
            Here's your week, built with Coach and Chef:

            **Workouts** (25 min, at home)
            - **Mon**: full body: squats, push-ups, rows, plank
            - **Wed**: 20 min brisk walk + 5 min mobility
            - **Sat**: full body again, one more rep each

            **Dinners** (under 20 min)
            - Chickpea and spinach curry with rice
            - Egg fried rice with frozen veg
            - Tuna pasta with tomatoes and olives

            Cook the curry on Sunday and it covers two nights. Want a shopping list?
            """, agent: chief, to: group, at: next(), context)
        let consultCoach = ChatMessage(kind: .consult, text: "Three 25-minute full-body sessions with a walk in the middle. Keep Saturday as the progression day.",
                                       agentID: coach.id, fromAgentID: chief.id,
                                       question: "30 min/day, exam season, no gym. What's a realistic 3-workout week?")
        let consultChef = ChatMessage(kind: .consult, text: "Batch-cook one curry on Sunday; two other dinners from pantry staples, all under 20 minutes.",
                                      agentID: chef.id, fromAgentID: chief.id,
                                      question: "Three easy, cheap, high-protein dinners for a student, 20 min max?")
        for card in [consultCoach, consultChef] {
            card.parentIDRaw = reply.id.uuidString
            card.createdAt = reply.createdAt.addingTimeInterval(-5)
            card.conversation = group
            context.insert(card)
        }

        // Two more chats so the list looks lived in.
        let tutorChat = Conversation(title: tutor.name, isGroup: false, memberIDs: [tutor.id])
        context.insert(tutorChat)
        add(.user, "Make me a revision plan for maths and physics, 6 weeks.", to: tutorChat, at: next(), context)
        add(.agent, "Here's a 6-week plan with spaced review built in. Week 1 starts with the topics you find hardest…",
            agent: tutor, to: tutorChat, at: next(), context)
        let moneyChat = Conversation(title: money.name, isGroup: false, memberIDs: [money.id])
        context.insert(moneyChat)
        add(.user, "How much should I save each month for a €600 laptop by June?", to: moneyChat, at: next(), context)
        add(.agent, "About **€75 a month** over 8 months. Set up an automatic transfer the day after you get paid.",
            agent: money, to: moneyChat, at: next(), context)

        context.insert(MemoryItem(text: "Has exams until June; studies maths and physics.", sourceAgentName: "Chief"))
        context.insert(MemoryItem(text: "Can train about 30 minutes a day, at home.", sourceAgentName: "Coach"))
        try? context.save()
    }

    @discardableResult
    @MainActor
    private static func add(_ kind: MessageKind, _ text: String, agent: Agent? = nil, to chat: Conversation,
                            at date: Date, _ context: ModelContext) -> ChatMessage {
        let message = ChatMessage(kind: kind, text: text, agentID: agent?.id)
        message.createdAt = date
        message.conversation = chat
        context.insert(message)
        chat.updatedAt = date
        return message
    }
}
#endif
