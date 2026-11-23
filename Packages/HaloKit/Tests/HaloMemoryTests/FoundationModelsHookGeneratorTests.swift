#if canImport(FoundationModels)
    import Foundation
    import FoundationModels
    import HaloCore
    import Testing

    @testable import HaloMemory

    @Suite struct FoundationModelsHookGeneratorTests {
        static let modelAvailable = SystemLanguageModel.default.availability == .available

        @Test func availabilityMirrorsTheSystemModel() async {
            #expect(await FoundationModelsHookGenerator().isAvailable == Self.modelAvailable)
        }

        @Test(.enabled(if: !modelAvailable, "only meaningful where the on-device model is unavailable"))
        func unavailableModelReturnsNoHooksWithoutThrowing() async throws {
            let generator = FoundationModelsHookGenerator()
            #expect(await !generator.isAvailable)
            let hooks = try await generator.hooks(
                for: Person(displayName: "Ana", confirmed: true),
                messages: [Fixture.message("I start at Acme on Monday!")], now: Fixture.t0)
            #expect(hooks.isEmpty)
        }

        /// Runs the REAL on-device model; skipped in CI and wherever Apple Intelligence is off.
        @Test(.enabled(if: modelAvailable, "needs the on-device system language model"))
        func realOnDeviceModelProducesPolicyCompliantHooks() async throws {
            let person = Person(displayName: "Ana", confirmed: true)
            let hooks = try await FoundationModelsHookGenerator().hooks(
                for: person,
                messages: [
                    Fixture.message("I start my new job at the Acme bakery on Monday!", minutesAgo: 30),
                    Fixture.message("Congrats!! What will you be baking?", minutesAgo: 20, fromMe: true),
                    Fixture.message(
                        "Sourdough mostly. Also training for the Lisbon half marathon", minutesAgo: 10),
                ],
                now: Fixture.t0)
            #expect(hooks.count <= MemoryHookPolicy.maxHooks)
            for hook in hooks {
                #expect(hook.text.count <= MemoryHookPolicy.maxLength)
                #expect(hook.source == .onDeviceSummary)
                #expect(hook.personID == person.id)
                #expect(hook.expiresAt == MemoryHookPolicy.expiry(from: Fixture.t0))
                #expect(!SensitiveTopicFilter.isSensitive(hook.text))
            }
        }

        @Test func promptIsNilWithoutUsableText() {
            let person = Person(displayName: "Ana")
            #expect(FoundationModelsHookGenerator.prompt(for: person, messages: []) == nil)
            #expect(
                FoundationModelsHookGenerator.prompt(for: person, messages: [Fixture.message(" \n ")]) == nil)
        }

        @Test func promptIsOldestFirstLabelledAndBounded() throws {
            let person = Person(displayName: "Ana")
            var messages = (0..<40).map { Fixture.message("message \($0)", minutesAgo: Double($0)) }
            messages.append(
                Fixture.message(String(repeating: "x", count: 500), minutesAgo: 0.5, fromMe: true))
            let prompt = try #require(FoundationModelsHookGenerator.prompt(for: person, messages: messages))

            #expect(prompt.count < FoundationModelsHookGenerator.maxPromptCharacters + 300)
            #expect(prompt.contains("Ana: message 0"))
            #expect(prompt.contains("Me: " + String(repeating: "x", count: 280)))
            #expect(!prompt.contains(String(repeating: "x", count: 281)))
            #expect(!prompt.contains("message 39"))  // only the newest 20 excerpts
            let older = try #require(prompt.range(of: "message 5"))
            let newer = try #require(prompt.range(of: "message 1\n"))
            #expect(older.lowerBound < newer.lowerBound)
        }
    }
#endif
