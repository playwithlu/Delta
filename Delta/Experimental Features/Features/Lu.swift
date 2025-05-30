//
//  Lu.swift
//  Delta
//
//  Created by Fikri Firat on 15/01/2025.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import SwiftUI
import DeltaFeatures
import AVFoundation

// Voice type for text-to-speech
struct VoiceType: RawRepresentable {
    let rawValue: String
    let displayName: String
    
    init(rawValue: String, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
    }
    
    init(rawValue: String) {
        // Default case
        switch rawValue {
        case "com.apple.voice.premium.en-US.Evan":
            self.init(rawValue: rawValue, displayName: "Evan")
        case "com.apple.voice.premium.en-US.Ava":
            self.init(rawValue: rawValue, displayName: "Ava")
        case "com.apple.voice.compact.en-US.Daniel":
            self.init(rawValue: rawValue, displayName: "Daniel")
        case "com.apple.voice.compact.en-US.Samantha":
            self.init(rawValue: rawValue, displayName: "Samantha")
        default:
            self.init(rawValue: rawValue, displayName: "System Default")
        }
    }
    
    static var availableVoices: [VoiceType] {
        // Gather all English voices on the device
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        // 1. Select en-US neural Siri (TTS bundle) voices
        let ttsBundleVoices = englishVoices.filter { voice in
            voice.language == "en-US" && voice.identifier.contains("ttsbundle")
        }

        // 2. If fewer than 4, append en-US compact voices
        var selected = ttsBundleVoices
        if selected.count < 4 {
            let compactCandidates = englishVoices.filter { voice in
                voice.language == "en-US" &&
                voice.identifier.contains("compact") &&
                !selected.contains(where: { $0.identifier == voice.identifier })
            }
            selected.append(contentsOf: compactCandidates.prefix(4 - selected.count))
        }

        // Limit to top 4 voices
        let topVoices = Array(selected.prefix(4))

        // Map to VoiceType entries (displayName uses the system voice name)
        return topVoices.map { voice in
            VoiceType(rawValue: voice.identifier, displayName: voice.name)
        }
    }

    /// Predefined LMNT API voices
    static var lmntVoices: [VoiceType] {
        return [
            VoiceType(rawValue: "lauren", displayName: "Lauren"),
            VoiceType(rawValue: "magnus", displayName: "Magnus"),
            VoiceType(rawValue: "noah", displayName: "Noah"),
            VoiceType(rawValue: "zoe", displayName: "Zoe"),
            VoiceType(rawValue: "zain", displayName: "Zain"),
            VoiceType(rawValue: "oliver", displayName: "Oliver")
        ]
    }
}


extension VoiceType: CustomStringConvertible, LocalizedOptionValue {
    var description: String {
        return self.displayName
    }
    
    var localizedDescription: Text {
        Text(self.displayName)
    }
    
    static var localizedNilDescription: Text {
        Text("System Default")
    }
}

enum LuEnvironment: String, CaseIterable, LocalizedOptionValue {
    case production
    case staging
    case development
    
    var localizedDescription: Text {
        switch self {
        case .production:
            return Text("Production")
        case .staging:
            return Text("Staging")
        case .development:
            return Text("Development")
        }
    }
}

/// Text-to-speech service options for Lu responses
enum TTSService: String, CaseIterable, LocalizedOptionValue {
    case system
    case lmnt
    case elevenlabs

    var localizedDescription: Text {
        switch self {
        case .system: return Text("System TTS")
        case .lmnt: return Text("LMNT API TTS")
        case .elevenlabs: return Text("ElevenLabs API TTS")
        }
    }
}
private func currentLuTTSService() -> TTSService {
    ExperimentalFeatures.shared.Lu.ttsService
}

// MARK: - Public OptionPickerView Wrapper

/// This view simply wraps the (internal) OptionPickerView so that we expose a public initializer.
public struct PublicOptionPickerView<Value>: View where Value: Equatable & LocalizedOptionValue & Hashable {
    var name: LocalizedStringKey
    var options: [Value?]
    @Binding var selectedValue: Value?

    public init(name: LocalizedStringKey, options: [Value?], selectedValue: Binding<Value?>) {
        self.name = name
        self.options = options
        self._selectedValue = selectedValue
    }

    public var body: some View {
        OptionPickerView(name: name, options: options, selectedValue: $selectedValue)
            .padding()
    }
}

struct PlayWithLuOptions {
    // Hidden option to track if welcome message was shown
    @Option
    var didShowWelcomeMessage: Bool = false
    
    // Hidden option to track the active game being played
    @Option
    var activeGameId: String = ""
    
    // Hidden option to track the active game save state
    @Option
    var activeSaveStateId: String = ""
    
    // Hidden option to track whether the current game supports attachments
    @Option
    var supportsAttachments: Bool = false

    // Hidden option to track whether the current game supports save states
    @Option
    var supportsSavestates: Bool = false
    
    @Option(name: "Share Gameplay Data",
            description: """
            Allow Lu to analyze gameplay data (e.g., save states, active cheats, playtime) for more personalized and accurate responses. Your personal information is never shared.
            """)
    var shareGameplayData: Bool = false
    
    @Option(name: "API Environment",
            description: "Choose which API environment to use for testing Lu.",
            values: LuEnvironment.allCases)
    var apiEnvironment: LuEnvironment = .production
    
    @Option(name: "Voice Interaction",
            description: "Enable long-press on the Lu button to activate speech recognition. You can speak your questions and Lu will read the answers back to you.")
    var enableVoiceInteraction: Bool = true
    
    @Option(name: "Text-to-Speech Voice",
            description: "Select the voice Lu will use when speaking responses to you.",
            detailView: { binding in
                let service = currentLuTTSService()
                if service == .elevenlabs {
                    ElevenLabsVoicePickerView(selectedValue: binding)
                } else {
                    let voices: [VoiceType?] = {
                        switch service {
                        case .system:
                            return VoiceType.availableVoices.map(Optional.init) + [nil]
                        case .lmnt:
                            return VoiceType.lmntVoices.map(Optional.init) + [nil]
                        case .elevenlabs:
                            return []
                        }
                    }()
                    PublicOptionPickerView(
                        name: "Text-to-Speech Voice",
                        options: voices,
                        selectedValue: binding
                    )
                    .onChange(of: service) { newService in
                        switch newService {
                        case .system:
                            binding.wrappedValue = nil
                        case .lmnt:
                            binding.wrappedValue = VoiceType.lmntVoices.first(where: { $0.rawValue == "zoe" })
                        case .elevenlabs:
                            binding.wrappedValue = nil
                        }
                    }
                    .onAppear {
                        switch service {
                        case .system:
                            binding.wrappedValue = nil
                        case .lmnt:
                            if binding.wrappedValue == nil || !voices.contains(binding.wrappedValue) {
                                binding.wrappedValue = VoiceType.lmntVoices.first(where: { $0.rawValue == "zoe" })
                            }
                        case .elevenlabs:
                            binding.wrappedValue = nil
                        }
                    }
                }
            })
    var ttsVoice: VoiceType?

    @Option(name: "TTS Service",
            description: "Select the text-to-speech service to use for speaking responses.",
            values: TTSService.allCases)
    var ttsService: TTSService = .system
}

// MARK: - ElevenLabs Voice Picker

private struct ElevenVoice: Decodable {
    let voice_id: String
    let name: String
}

private struct ElevenVoicesResponse: Decodable {
    let voices: [ElevenVoice]
}

@MainActor
private class ElevenLabsVoiceLoader: ObservableObject {
    @Published var voices: [VoiceType?] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var hasLoaded = false

    /// Shared singleton loader prevents repeated fetches.
    static let shared = ElevenLabsVoiceLoader()

    private init() {
        print("[ElevenLabsVoiceLoader] init; hasLoaded=\(hasLoaded)")
        load()
    }

    func load() {
        print("[ElevenLabsVoiceLoader] load() called; hasLoaded=\(hasLoaded)")
        guard !hasLoaded else {
            print("[ElevenLabsVoiceLoader] load() skipped; already hasLoaded")
            return
        }
        hasLoaded = true
        isLoading = true
        print("[ElevenLabsVoiceLoader] Starting fetch of ElevenLabs voices")
        Task { @MainActor in
            print("[ElevenLabsVoiceLoader] Task started on main actor")
            do {
                guard let apiKey = loadElevenLabsAPIKey() else {
                    throw NSError(domain: "ElevenLabsVoiceLoader",
                                  code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing ELEVENLABS_API_KEY"])
                }
                print("[ElevenLabsVoiceLoader] API key loaded (length=\(apiKey.count))")
                var request = URLRequest(
                    url: URL(string: "https://api.elevenlabs.io/v2/voices?category=premade&language=en&search=Conversational")!
                )
                request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[ElevenLabsVoiceLoader] HTTP status: \(status)")
                guard status == 200 else {
                    throw NSError(domain: "ElevenLabsVoiceLoader", code: status)
                }

                let apiResponse = try JSONDecoder().decode(ElevenVoicesResponse.self, from: data)
                let fetched = apiResponse.voices.map {
                    VoiceType(rawValue: $0.voice_id, displayName: $0.name)
                }
                print("[ElevenLabsVoiceLoader] Decoded voices: \(fetched.map { $0.rawValue })")
                voices = fetched.map(Optional.init) + [nil]
            } catch {
                errorMessage = error.localizedDescription
                print("[ElevenLabsVoiceLoader] ERROR: \(error)")
            }
            isLoading = false
            print("[ElevenLabsVoiceLoader] Task completed; isLoading=\(isLoading)")
        }
    }

    private func loadElevenLabsAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Lu-Info", withExtension: "plist") else {
            print("[ElevenLabsVoiceLoader] Lu-Info.plist not found")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            print("[ElevenLabsVoiceLoader] Failed to read Lu-Info.plist data")
            return nil
        }
        guard let dict = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            print("[ElevenLabsVoiceLoader] Failed to parse Lu-Info.plist")
            return nil
        }
        guard let key = dict["ELEVENLABS_API_KEY"] as? String else {
            print("[ElevenLabsVoiceLoader] ELEVENLABS_API_KEY missing or invalid")
            return nil
        }
        return key
    }
}

private struct ElevenLabsVoicePickerView: View {
    @Binding var selectedValue: VoiceType?
    @ObservedObject private var loader = ElevenLabsVoiceLoader.shared

    var body: some View {
        Group {
            if let error = loader.errorMessage {
                Text("Error loading voices: \(error)")
                    .foregroundColor(.red)
            } else if loader.isLoading {
                ProgressView("Loading voices…")
            } else {
                PublicOptionPickerView(
                    name: "Text-to-Speech Voice",
                    options: loader.voices,
                    selectedValue: $selectedValue
                )
                .onChange(of: loader.voices) { newVoices in
                    print("[ElevenLabsVoicePickerView] voices changed: \(newVoices.compactMap { $0?.rawValue })")
                    if selectedValue == nil || !newVoices.contains(selectedValue) {
                        selectedValue = newVoices.compactMap { $0 }.first
                        print("[ElevenLabsVoicePickerView] default selection now \(String(describing: selectedValue?.rawValue))")
                    }
                }
            }
        }
        .padding()
    }
}

