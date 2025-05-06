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
        // Define known voices
        let knownVoices: [(id: String, displayName: String)] = [
            ("com.apple.voice.premium.en-US.Evan", "Evan"),
            ("com.apple.voice.premium.en-US.Ava", "Ava"),
            ("com.apple.voice.compact.en-US.Daniel", "Daniel"),
            ("com.apple.voice.compact.en-US.Samantha", "Samantha")
        ]
        
        // Get all available voices on the device
        let availableSystemVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") } // Only keep English voices
        
        // Create a map of voice identifiers to AVSpeechSynthesisVoice objects for quick lookup
        let voiceMap = Dictionary(uniqueKeysWithValues: availableSystemVoices.map { ($0.identifier, $0) })
        
        // Create array with proper type
        var voices: [VoiceType] = []
        
        // Add known voices first if they are available on the device
        for knownVoice in knownVoices {
            if voiceMap[knownVoice.id] != nil {
                voices.append(VoiceType(rawValue: knownVoice.id, displayName: knownVoice.displayName))
            }
        }
        
        // Then add any other English voices available on the device
        for voice in availableSystemVoices {
            // Skip if this is one of our known voices we already added
            if knownVoices.contains(where: { $0.id == voice.identifier }) {
                continue
            }
            let displayName = "\(voice.name)"
            
            // For non-known voices, use the actual voice identifier as rawValue
            voices.append(VoiceType(rawValue: voice.identifier, displayName: displayName))
        }
        
        return voices
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
    
    @Option(name: "Remember Conversations",
            description: "Lu can save your previous questions and responses to provide context-aware advice and follow-up suggestions for each game.")
    var rememberConversations: Bool = false
    
    @Option(name: "Voice Interaction",
            description: "Enable long-press on the Lu button to activate speech recognition. You can speak your questions and Lu will read the answers back to you.")
    var enableVoiceInteraction: Bool = true
    
    @Option(name: "Text-to-Speech Voice",
            description: "Select the voice Lu will use when speaking responses to you.",
            values: VoiceType.availableVoices)
    var ttsVoice: VoiceType?
}
