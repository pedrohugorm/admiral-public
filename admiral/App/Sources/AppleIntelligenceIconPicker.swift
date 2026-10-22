import AdmiralCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Picks a tab's icon with the on-device Apple Intelligence model. The answer is constrained
/// to the symbols in `meanings` that are also in Admiral's list, so it is always one of them.
/// Without the model (Apple Intelligence off, or macOS before 26) there is no pick, and the tab
/// keeps its default icon.
struct AppleIntelligenceIconPicker: IconPicker {
    func pickSymbol(for prompt: String, from symbols: [String]) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return await Self.pick(prompt, from: symbols) }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func pick(_ prompt: String, from symbols: [String]) async -> String? {
        let candidates = meanings.map(\.symbol).filter(symbols.contains)
        guard SystemLanguageModel.default.availability == .available,
              let schema = try? GenerationSchema(
                  root: DynamicGenerationSchema(name: "Icon", description: "An SF Symbol name", anyOf: candidates),
                  dependencies: []
              ) else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        // Greedy, so a prompt gets the same icon every time. Sampled, 11 of 276 real first
        // prompts changed icon from one run to the next. `sampling:` because the release build's
        // Xcode 26 SDK has no `samplingMode:`; the newer SDK only deprecates it.
        guard let response = try? await session.respond(
                  to: prompt, schema: schema, options: GenerationOptions(sampling: .greedy)),
              let symbol = try? response.content.value(String.self) else { return nil }
        // The model answers " hammer" as often as "hammer".
        return symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    /// What each symbol stands for, as kinds of request. The model reads the prompt's main verb,
    /// so the meanings are verbs and question words; listed as topics ("servers, databases"),
    /// it fell back to the catch-all for two prompts in five and matched a hand-labelled set
    /// of 212 real first prompts a quarter of the time. This list matches 69% of them.
    /// Anchor, sailboat, star and cube stay in the editor only: none of them fit a prompt.
    static let meanings: [(symbol: String, meaning: String)] = [
        ("magnifyingglass", "investigate, find, check, confirm, read and report, look up data, count, audit"),
        ("bubble.left.and.bubble.right", "a question to answer or explain; why, how, what, is, does, can, explain"),
        ("ladybug", "something is broken, failing, stuck, wrong, not working, or crashing"),
        ("hammer", "build, implement, add, or change a feature"),
        ("compass.drawing", "make a plan, design, architecture, or write docs"),
        ("flag", "Jira tickets (like ACME-123 or PROJ-45), execute a ticket, releases notes"),
        ("shippingbox", "get latest, pull, push, rebuild for release, install"),
        ("cloud", "deploy, Kubernetes, clusters, production rollout"),
        ("server.rack", "databases, SQL queries, backend services"),
        ("terminal", "shell commands and scripts"),
        ("brain", "AI models, prompts, agents, memory"),
        ("antenna.radiowaves.left.and.right", "APIs, MCP, integrations, networking"),
        ("square.grid.2x2", "UI, layout, screens, dashboards"),
        ("bell", "notifications, alerts, monitoring"),
        ("bolt", "performance, speed, CPU"),
        ("gearshape", "settings and configuration"),
        ("wrench.and.screwdriver", "cleanup, removal, upgrades, maintenance"),
        ("flask", "experiments, prototypes, trying a new tool or model"),
        ("lifepreserver", "an incident or a failed production workflow"),
        // The default icon, so a prompt with nothing to go on looks like no pick.
        ("sparkles", #"the message has no clear task, such as "continue", "are we done?", or "try again""#),
    ]

    static let instructions = """
        You choose the icon for a coding session's tab from the user's first message. \
        Decide what the user is asking for, from the main verb, then pick the symbol for that kind of work:
        \(meanings.map { "\($0.symbol): \($0.meaning)" }.joined(separator: "\n"))

        Examples:
        "Why is the build slow?" -> bubble.left.and.bubble.right
        "investigate why case 123 failed" -> magnifyingglass
        "get latest and rebuild for release" -> shippingbox
        "Read PROJ-12 and create a plan" -> compass.drawing
        "the sidebar is showing white, fix it" -> ladybug
        "continue" -> sparkles
        """
}
