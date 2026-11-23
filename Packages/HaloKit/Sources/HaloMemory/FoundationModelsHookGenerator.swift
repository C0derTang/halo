#if canImport(FoundationModels)
    import Foundation
    import FoundationModels
    import HaloCore

    /// Generates `.onDeviceSummary` memory hooks with Apple's ON-DEVICE system language model
    /// (`SystemLanguageModel`). Invariant 6: no network, no Private Cloud Compute, no other model,
    /// and neither the message text nor the generated hooks are ever logged.
    ///
    /// Uses only iOS 26 / macOS 26 SDK API (`SystemLanguageModel.availability`,
    /// `LanguageModelSession(model:instructions:)`, `respond(to:generating:includeSchemaInPrompt:options:)`,
    /// `@Generable` / `@Guide(.maximumCount)`), so it builds on Xcode 26 and 27.
    public struct FoundationModelsHookGenerator: MemoryHookGenerating {
        /// Prompt budget: the on-device model has a small context window, so only the newest
        /// excerpts are sent, each clipped, up to a total character budget.
        public static let maxPromptMessages = 20
        public static let maxMessageCharacters = 280
        public static let maxPromptCharacters = 3_000

        static let instructions = """
            You write short memory hooks: facts worth remembering about one person, taken only \
            from their recent messages with the user. Return between 0 and 3 hooks. Each hook is \
            at most 40 characters, factual, neutral and about that person (for example "Started \
            a new job at Acme" or "Training for a marathon"). Never mention health, illness, \
            religion, sexuality, dating, money or finances. Do not invent anything. If nothing \
            fits, return an empty list.
            """

        private let model: SystemLanguageModel

        /// `model` must be an on-device `SystemLanguageModel`; the default is `.default`.
        public init(model: SystemLanguageModel = .default) {
            self.model = model
        }

        public var isAvailable: Bool {
            get async { model.availability == .available }
        }

        /// Returns `[]` (never throws) when the model is unavailable or there is nothing to summarize.
        public func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date)
            async throws -> [MemoryHook]
        {
            guard model.availability == .available else { return [] }
            let prompt = Self.prompt(for: person, messages: messages)
            guard let prompt else { return [] }
            try Task.checkCancellation()

            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            var options = GenerationOptions()
            options.temperature = 0.2
            let response = try await session.respond(
                to: prompt, generating: GeneratedHooks.self, includeSchemaInPrompt: true,
                options: options)
            try Task.checkCancellation()
            return MemoryHookPolicy.makeHooks(for: person.id, texts: response.content.hooks, now: now)
        }

        /// Builds the prompt from the newest excerpts, or nil when there is no usable text.
        static func prompt(for person: Person, messages: [InteractionDigest.DigestMessage]) -> String? {
            let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let them = name.isEmpty ? "Them" : name
            var lines: [String] = []
            var budget = maxPromptCharacters
            for message in messages.sorted(by: { $0.date > $1.date }).prefix(maxPromptMessages) {
                let text = message.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let line = "\(message.fromMe ? "Me" : them): \(String(text.prefix(maxMessageCharacters)))"
                guard line.count <= budget else { break }
                budget -= line.count
                lines.append(line)
            }
            guard !lines.isEmpty else { return nil }
            // Oldest first reads naturally as a conversation.
            return """
                Recent messages between me and \(them), oldest first:
                \(lines.reversed().joined(separator: "\n"))

                Write up to 3 memory hooks about \(them).
                """
        }
    }

    @Generable
    struct GeneratedHooks {
        @Guide(
            description:
                "Up to 3 short factual things worth remembering about the person, each at most 40 characters",
            .maximumCount(3))
        var hooks: [String]
    }
#endif
