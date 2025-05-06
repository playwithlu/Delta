//
//  GameViewController+Lu.swift
//  Delta
//
//  Created by Fikri Firat on 24/04/2025.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import UIKit
import ObjectiveC
import DeltaFeatures
import os.log
import Speech
import AVFoundation

// MARK: - API Models and Utilities
private extension OSLog {
    static let lu = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.rileytestut.Delta", category: "Lu")
}

private func luLog(_ type: OSLogType = .info, _ message: String) {
    os_log("[Lu] %{public}@", log: .lu, type: type, message)
}

private struct GameSupportResponse: Codable {
    let game_id: String
    let supports_attachments: Bool?
    let supports_savestates: Bool?
}

private struct APIContext: Codable {
    struct DeviceContext: Codable {
        let device_id: String
        let device_name: String
        let system_name: String
        let system_version: String
        let model: String
        let bundle_id: String
    }
    
    struct GameContext: Codable {
        let name: String
        let identifier: String
        let type: String
        let save_states_count: Int
        let cheats_count: Int
        let last_played: String?
    }
    
    struct SaveStateMetadata: Codable {
        let name: String
        let creation_date: String
        let modified_date: String
        let type: String
    }
    
    struct Attachment: Codable {
        let type: String
        let content: String
        let filename: String
    }
    
    let device_context: DeviceContext
    let game_context: GameContext
    let attachments: [Attachment]?
}

private extension URLRequest {
    mutating func addContextHeaders(context: APIContext) {
        do {
            let headersOnlyContext = APIContext(
                device_context: context.device_context,
                game_context: context.game_context,
                attachments: nil
            )
            let contextData = try JSONEncoder().encode(headersOnlyContext)
            if let contextString = String(data: contextData, encoding: .utf8) {
                setValue(contextString, forHTTPHeaderField: "x-lu-context")
            }
        } catch {
            luLog(.error, "Failed to encode API context: \(error.localizedDescription)")
        }
    }
}

private extension Date {
    func ISO8601String() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}

private enum APIConstants {
    private static let plist: [String: Any] = {
        guard let plistPath = Bundle.main.path(forResource: "Lu-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            fatalError("[Lu] Failed to load Lu-Info.plist")
        }
        return plist
    }()
    
    // This computed property is fine as is
    static var currentEnvironment: LuEnvironment {
        return ExperimentalFeatures.shared.Lu.wrappedValue.apiEnvironment
    }
    
    // Change from static let with closure to computed property
    static var baseURL: String {
        // Choose the appropriate URL based on current environment
        let urlKey: String
        
        switch currentEnvironment {
        case .production:
            urlKey = "LU_BASE_URL_PROD"
        case .staging:
            urlKey = "LU_BASE_URL_STAGING"
        case .development:
            urlKey = "LU_BASE_URL_DEV"
        }
        
        // Try to get environment-specific URL first
        if let envUrl = plist[urlKey] as? String, !envUrl.isEmpty {
            return envUrl
        }
        
        // Fall back to default URL if specific one isn't found
        guard let url = plist["LU_BASE_URL"] as? String else {
            fatalError("[Lu] Missing LU_BASE_URL in Lu-Info.plist")
        }
        
        return url
    }
    
    // Change from constant to computed property
    static var supportBaseURL: String {
        return "\(baseURL)/check-rom"
    }
    // Change from constant to computed property
    static var askBaseURL: String {
        return "\(baseURL)/ask"
    }
    // Change from constant to computed property
    static var feedbackBaseURL: String {
        return "\(baseURL)/feedbacks"
    }
    // Change from constant to computed property
    static var followUpBaseURL: String {
        return "\(baseURL)/sessions/{session-id}/follow-ups"
    }
    static let supportTimeout: TimeInterval = {
        guard let timeout = plist["SUPPORT_TIMEOUT"] as? TimeInterval else {
            return 10
        }
        return timeout
    }()
    static let askTimeout: TimeInterval = {
        guard let timeout = plist["ASK_TIMEOUT"] as? TimeInterval else {
            return 30
        }
        return timeout
    }()
    static let feedbackTimeout: TimeInterval = {
        guard let timeout = plist["FEEDBACK_TIMEOUT"] as? TimeInterval else {
            return 10
        }
        return timeout
    }()
}

// MARK: - Game Screen Lu Button Implementation

// Keys for GameViewController associated objects
private var gameViewLuButtonKey: UInt8 = 0
private var gameViewLuButtonConstraintsKey: UInt8 = 0
private var gameViewLongPressGestureKey: UInt8 = 0
private var gameViewListeningIndicatorViewKey: UInt8 = 0
private var gameViewListeningLabelKey: UInt8 = 0
private var gameViewProcessingIndicatorViewKey: UInt8 = 0
private var gameViewProcessingLabelKey: UInt8 = 0
private var gameViewResponseNotificationViewKey: UInt8 = 0
private var gameViewHiddenChatVCKey: UInt8 = 0
private var gamesViewLuButtonKey: UInt8 = 0
private var gamesViewLuButtonConstraintsKey: UInt8 = 0
private var gameViewLuButtonStateKey: UInt8 = 0

// Lu button state enum to track current state
enum LuButtonState {
    case idle
    case recording
    case processing
    case playing
    
    // UI properties for each state
    var tintColor: UIColor {
        switch self {
        case .idle:
            return .white
        case .recording:
            return UIColor.systemRed
        case .processing:
            return UIColor(hex: "#6366f1") // Indigo color for processing
        case .playing:
            return UIColor(hex: "#52d964") // Green color for playing
        }
    }
    
    var backgroundColor: UIColor {
        switch self {
        case .idle:
            return UIColor.black.withAlphaComponent(0.5)
        case .recording:
            return UIColor.systemRed.withAlphaComponent(0.3)
        case .processing:
            return UIColor(hex: "#6366f1").withAlphaComponent(0.3) // Indigo color for processing
        case .playing:
            return UIColor(hex: "#52d964").withAlphaComponent(0.3) // Green color for playing
        }
    }
}

// Extension for creating UIColor from hex string
extension UIColor {
    convenience init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        if hexString.hasPrefix("#") {
            hexString.remove(at: hexString.startIndex)
        }
        
        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)
        
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

// Protocol for SpeechManager delegate
// Main delegate protocol for the SpeechManager
protocol SpeechManagerDelegate: AnyObject {
    /// Called when speech recognition has started
    func speechRecognitionDidStart()
    
    /// Called when speech recognition has stopped
    func speechRecognitionDidStop()
    
    /// Called when speech recognition has a partial result
    func speechRecognition(didRecognizePartialResult result: String)
    
    /// Called when speech recognition has a final result
    func speechRecognition(didRecognizeFinalResult result: String)
    
    /// Called when an error occurs during speech recognition
    func speechRecognition(didFailWithError error: Error)
    
    /// Called when authorization status changes
    func speechRecognition(authorizationDidChange status: SFSpeechRecognizerAuthorizationStatus)
}

// Define our own speech recognition manager interface if needed
class SpeechManager: NSObject, SFSpeechRecognizerDelegate {
    static let shared = SpeechManager()
    
    // Use consistent protocol name - this is the single delegate property
    weak var delegate: SpeechManagerDelegate?
    
    // Speech recognition properties
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioEngine: AVAudioEngine = AVAudioEngine()
    private var hasReceivedPartialResults: Bool = false
    public var isListening: Bool = false
    
    // Track the last recognized partial result
    private var lastPartialResult: String = ""
    
    // Initialize with a default locale
    override init() {
        // Initialize speechRecognizer before super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        
        // Call super.init()
        super.init()
        
        // Now set the delegate
        speechRecognizer?.delegate = self
    }
    
    func startListening(completion: ((Bool, Error?) -> Void)? = nil) {
        // Cancel existing task if there is one
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        // Make sure speech recognition is available
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            let error = NSError(domain: "SpeechManagerErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition not available"])
            luLog(.error, "Speech recognition not available on this device")
            self.delegate?.speechRecognition(didFailWithError: error)
            completion?(false, error)
            return
        }
        
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            luLog(.info, "Audio session configured for speech recognition")
        } catch {
            luLog(.error, "Could not configure audio session: \(error.localizedDescription)")
            self.delegate?.speechRecognition(didFailWithError: error)
            completion?(false, error)
            return
        }
        
        // Request authorization for speech recognition
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.startRecognition(completion: completion)
                case .denied, .restricted, .notDetermined:
                    let error = NSError(
                        domain: "SpeechManagerErrorDomain",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Speech recognition not authorized. Status: \(status.rawValue)"]
                    )
                    luLog(.error, "Speech recognition authorization denied: \(status.rawValue)")
                    self.delegate?.speechRecognition(authorizationDidChange: status)
                    self.delegate?.speechRecognition(didFailWithError: error)
                    completion?(false, error)
                @unknown default:
                    let error = NSError(
                        domain: "SpeechManagerErrorDomain",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown authorization status: \(status.rawValue)"]
                    )
                    luLog(.error, "Unknown speech recognition authorization status: \(status.rawValue)")
                    self.delegate?.speechRecognition(didFailWithError: error)
                    completion?(false, error)
                }
            }
        }
    }
    
    func stopListening() {
        // Check if we have partial results but no final result was processed
        let hadPartialResults = self.hasReceivedPartialResults
        let partialResult = self.lastPartialResult
        
        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Reset state
        isListening = false
        
        // IMPORTANT: If we have partial results but the recognition was manually stopped,
        // we should treat the last partial result as a final result
        if hadPartialResults && !partialResult.isEmpty {
            luLog(.info, "📣 Manual stop with partial results, treating as final: \"\(partialResult)\"")
            DispatchQueue.main.async {
                // Notify the delegate of the "final" result
                self.delegate?.speechRecognition(didRecognizeFinalResult: partialResult)
            }
        }
        
        // Reset partial results tracking
        hasReceivedPartialResults = false
        lastPartialResult = ""
        
        // Notify delegate that speech recognition stopped
        DispatchQueue.main.async {
            self.delegate?.speechRecognitionDidStop()
        }
        
        luLog(.info, "Speech recognition stopped")
    }
    
    // Start the actual recognition process
    private func startRecognition(completion: ((Bool, Error?) -> Void)? = nil) {
        guard let speechRecognizer = speechRecognizer else {
            let error = NSError(domain: "SpeechManagerErrorDomain", code: 4, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not initialized"])
            luLog(.error, "Speech recognizer not initialized")
            self.delegate?.speechRecognition(didFailWithError: error)
            completion?(false, error)
            return
        }
        
        // Create a new speech recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            let error = NSError(domain: "SpeechManagerErrorDomain", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create speech recognition request"])
            luLog(.error, "Could not create speech recognition request")
            self.delegate?.speechRecognition(didFailWithError: error)
            completion?(false, error)
            return
        }
        
        // Configure the request
        recognitionRequest.shouldReportPartialResults = true
        
        // Keep audio recording for when recognition is finished
        recognitionRequest.taskHint = .dictation
        
        // Start recognition task
        var isFinal = false
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            var finalResult = false
            
            if let result = result {
                let recognizedText = result.bestTranscription.formattedString
                finalResult = result.isFinal
                
                // If we have a non-empty result, notify the delegate
                if !recognizedText.isEmpty {
                    // If we have a result with transcription, update the flag
                    self.hasReceivedPartialResults = true
                    
                    DispatchQueue.main.async {
                        if finalResult {
                            luLog(.info, "Final speech recognition result: \(recognizedText)")
                            self.delegate?.speechRecognition(didRecognizeFinalResult: recognizedText)
                        } else {
                            luLog(.debug, "Partial speech recognition result: \(recognizedText)")
                            
                            // Store the last partial result for use if stop is called
                            self.lastPartialResult = recognizedText
                            
                            self.delegate?.speechRecognition(didRecognizePartialResult: recognizedText)
                        }
                    }
                }
            }
            
            if error != nil || finalResult {
                // First, log any error details to help with debugging
                if let error = error {
                    let nsError = error as NSError
                    luLog(.error, "Speech recognition error: Domain=\(nsError.domain) Code=\(nsError.code) Description=\(error.localizedDescription)")
                    
                    // Check if this is the specific "No speech detected" error we're looking for
                    let isNoSpeechError = (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101) ||
                                          error.localizedDescription.contains("No speech detected")
                    
                    if isNoSpeechError {
                        luLog(.info, "Detected 'No speech detected' error (kAFAssistantErrorDomain Code=1101)")
                    }
                    
                    // Critical check: Has the user already spoken something?
                    // If we've received partial results, ignore ANY speech recognition error
                    if self.hasReceivedPartialResults || !self.lastPartialResult.isEmpty {
                        luLog(.info, "★ IMPORTANT: Ignoring speech recognition error because we already have partial results")
                        luLog(.info, "★ IMPORTANT: This prevents false 'No speech detected' errors when speech was actually detected")
                        
                        // Don't report the error to the delegate, just continue
                        if finalResult {
                            // Even though we have an error, if we also have a final result, handle that
                            luLog(.info, "We have both a final result and an error - prioritizing the final result")
                        } else {
                            // If no final result but we have partial results, we can ignore the error completely
                            luLog(.info, "Speech will continue despite the error")
                            return // Skip error handling and keep listening
                        }
                    } else if !finalResult {
                        // Check if we actually have speech recognition errors that are NOT "No speech detected"
                        let isNoSpeechError = (nsError.domain == "kAFAssistantErrorDomain" &&
                                              (nsError.code == 1101 || nsError.code == 1110)) ||
                                              error.localizedDescription.contains("No speech detected")
                        
                        // For "No speech detected" errors, don't show alert at all - these are common and annoying
                        if !isNoSpeechError {
                            // Only report other types of errors to the delegate
                            luLog(.info, "Reporting actual error to delegate (not a 'No speech detected' error)")
                            DispatchQueue.main.async {
                                self.delegate?.speechRecognition(didFailWithError: error)
                            }
                            completion?(false, error)
                        } else {
                            // Just log the "No speech detected" error but don't show it to the user
                            luLog(.info, "Suppressing 'No speech detected' error popup to avoid disrupting the user")
                        }
                    }
                }
                
                // Handle final result case specifically
                if finalResult {
                    luLog(.info, "Speech recognition completed with final result")
                }
                
                // Stop recording if we have an error or final result (only reached if we're not returning early)
                luLog(.info, "Stopping audio engine and cleaning up resources")
                self.audioEngine.stop()
                self.audioEngine.inputNode.removeTap(onBus: 0)
                
                self.recognitionRequest?.endAudio()
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.hasReceivedPartialResults = false
                
                // Only set isListening to false if we have a final result or error
                if finalResult || error != nil {
                    self.isListening = false
                }
            }
            
            isFinal = finalResult
        }
        
        // Configure audio engine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap on the audio input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        // Start audio engine
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            delegate?.speechRecognitionDidStart()
            luLog(.info, "Speech recognition started")
            completion?(true, nil)
        } catch {
            luLog(.error, "Could not start audio engine: \(error.localizedDescription)")
            self.delegate?.speechRecognition(didFailWithError: error)
            completion?(false, error)
            self.stopListening()
        }
    }
    
    // SFSpeechRecognizerDelegate method
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available && isListening {
            // If recognizer becomes unavailable while we're listening, stop and report error
            let error = NSError(
                domain: "SpeechManagerErrorDomain",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition became unavailable"]
            )
            luLog(.error, "Speech recognizer availability changed to unavailable while listening")
            delegate?.speechRecognition(didFailWithError: error)
            stopListening()
        } else {
            luLog(.info, "Speech recognizer availability changed: \(available)")
        }
    }
}

extension GameViewController {
    
    // Computed properties using associated objects
    private var luButton: UIButton? {
        get {
            return objc_getAssociatedObject(self, &gameViewLuButtonKey) as? UIButton
        }
        set {
            objc_setAssociatedObject(self, &gameViewLuButtonKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var luButtonConstraints: [NSLayoutConstraint] {
        get {
            return objc_getAssociatedObject(self, &gameViewLuButtonConstraintsKey) as? [NSLayoutConstraint] ?? []
        }
        set {
            objc_setAssociatedObject(self, &gameViewLuButtonConstraintsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    // Current Lu button state
    private var luButtonState: LuButtonState {
        get {
            return objc_getAssociatedObject(self, &gameViewLuButtonStateKey) as? LuButtonState ?? .idle
        }
        set {
            objc_setAssociatedObject(self, &gameViewLuButtonStateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            updateLuButtonAppearance()
        }
    }
    
    // Update button appearance based on current state
    private func updateLuButtonAppearance() {
        guard let button = self.luButton else { return }
        
        // Update colors based on state
        UIView.animate(withDuration: 0.3) {
            button.tintColor = self.luButtonState.tintColor
            button.backgroundColor = self.luButtonState.backgroundColor
        }
        
        // Remove existing animations
        button.layer.removeAllAnimations()
        
        // Apply appropriate animation based on state
        switch luButtonState {
        case .idle:
            // No animation for idle state
            break
            
        case .recording:
            // Pulse animation for recording
            let pulseAnimation = CABasicAnimation(keyPath: "transform.scale")
            pulseAnimation.duration = 1.0
            pulseAnimation.fromValue = 1.0
            pulseAnimation.toValue = 1.2
            pulseAnimation.autoreverses = true
            pulseAnimation.repeatCount = .infinity
            button.layer.add(pulseAnimation, forKey: "pulse")
            
        case .processing:
            // Rotation animation for processing
            let rotationAnimation = CABasicAnimation(keyPath: "transform.rotation")
            rotationAnimation.fromValue = 0
            rotationAnimation.toValue = CGFloat.pi * 2
            rotationAnimation.duration = 2.0
            rotationAnimation.repeatCount = .infinity
            button.layer.add(rotationAnimation, forKey: "rotation")
            
        case .playing:
            // Subtle pulse animation for playing
            let pulseAnimation = CABasicAnimation(keyPath: "transform.scale")
            pulseAnimation.duration = 1.5
            pulseAnimation.fromValue = 1.0
            pulseAnimation.toValue = 1.1
            pulseAnimation.autoreverses = true
            pulseAnimation.repeatCount = .infinity
            button.layer.add(pulseAnimation, forKey: "pulse")
        }
    }
    
    private var longPressGesture: UILongPressGestureRecognizer? {
        get {
            return objc_getAssociatedObject(self, &gameViewLongPressGestureKey) as? UILongPressGestureRecognizer
        }
        set {
            objc_setAssociatedObject(self, &gameViewLongPressGestureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var listeningIndicatorView: UIView? {
        get {
            return objc_getAssociatedObject(self, &gameViewListeningIndicatorViewKey) as? UIView
        }
        set {
            objc_setAssociatedObject(self, &gameViewListeningIndicatorViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var listeningLabel: UILabel? {
        get {
            return objc_getAssociatedObject(self, &gameViewListeningLabelKey) as? UILabel
        }
        set {
            objc_setAssociatedObject(self, &gameViewListeningLabelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var hiddenChatVC: LuChatViewController? {
        get {
            return objc_getAssociatedObject(self, &gameViewHiddenChatVCKey) as? LuChatViewController
        }
        set {
            objc_setAssociatedObject(self, &gameViewHiddenChatVCKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    /// Adds the Lu button to the game view
    func addLuButton() {
        // Create button
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        button.setImage(#imageLiteral(resourceName: "Lu"), for: .normal)
        
        // Style button
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.tintColor = .white
        button.layer.cornerRadius = 30 // Increased from 20 to 30 for larger button
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12) // Increased padding
        
        // Add action
        button.addTarget(self, action: #selector(luButtonTapped), for: .touchUpInside)
        
        // Add long press gesture for voice interactions if enabled
        if ExperimentalFeatures.shared.Lu.wrappedValue.enableVoiceInteraction {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLuButtonLongPress(_:)))
            longPress.minimumPressDuration = 0.5 // Half second press to activate
            button.addGestureRecognizer(longPress)
            self.longPressGesture = longPress
        }
        
        // Store the reference
        self.luButton = button
        
        // Add to view
        view.addSubview(button)
        
        // Position in top right with Auto Layout constraints
        let buttonSize: CGFloat = 60 // Increased from 40 to 60
        
        let constraints = [
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize)
        ]
        
        NSLayoutConstraint.activate(constraints)
        self.luButtonConstraints = constraints
        
        // Add pan gesture recognizer for dragging
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLuButtonPan(_:)))
        button.addGestureRecognizer(panGesture)
        
        // Add orientation change observer
        registerForOrientationChanges()
    }
    
    func registerForOrientationChanges() {
        // First remove any existing observer to avoid duplicates
        unregisterFromOrientationChanges()
        
        // Add orientation change observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    func unregisterFromOrientationChanges() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    @objc func orientationDidChange() {
        // Give the view time to update its layout for the new orientation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let button = self.luButton else { return }
            
            // Only adjust if the button is using frame-based layout (has been dragged)
            if button.translatesAutoresizingMaskIntoConstraints {
                self.keepButtonWithinSafeBounds(button)
            }
        }
    }
    
    private func keepButtonWithinSafeBounds(_ button: UIButton) {
        // Get button dimensions
        let halfButtonWidth = button.bounds.width / 2
        let halfButtonHeight = button.bounds.height / 2
        let safeAreaInsets = view.safeAreaInsets
        
        // Get current position
        var newCenter = button.center
        
        // Constrain x position
        newCenter.x = max(halfButtonWidth + safeAreaInsets.left, newCenter.x)
        newCenter.x = min(view.bounds.width - halfButtonWidth - safeAreaInsets.right, newCenter.x)
        
        // Constrain y position
        newCenter.y = max(halfButtonHeight + safeAreaInsets.top, newCenter.y)
        newCenter.y = min(view.bounds.height - halfButtonHeight - safeAreaInsets.bottom, newCenter.y)
        
        // Update button position with animation
        UIView.animate(withDuration: 0.3) {
            button.center = newCenter
        }
    }
    
    @objc func handleLuButtonPan(_ gesture: UIPanGestureRecognizer) {
        guard let button = gesture.view else { return }
        
        // When dragging starts, switch to frame-based layout
        if gesture.state == .began {
            // Deactivate constraints and switch to frame-based layout
            NSLayoutConstraint.deactivate(self.luButtonConstraints)
            button.translatesAutoresizingMaskIntoConstraints = true
            
            // Make sure the button is still in the same position
            let frame = button.frame
            button.frame = frame
        }
        
        let translation = gesture.translation(in: view)
        
        // Calculate new position
        var newCenter = CGPoint(
            x: button.center.x + translation.x,
            y: button.center.y + translation.y
        )
        
        // Ensure button stays within screen bounds
        let halfButtonWidth = button.bounds.width / 2
        let halfButtonHeight = button.bounds.height / 2
        let safeAreaInsets = view.safeAreaInsets
        
        // Constrain x position
        newCenter.x = max(halfButtonWidth + safeAreaInsets.left, newCenter.x)
        newCenter.x = min(view.bounds.width - halfButtonWidth - safeAreaInsets.right, newCenter.x)
        
        // Constrain y position
        newCenter.y = max(halfButtonHeight + safeAreaInsets.top, newCenter.y)
        newCenter.y = min(view.bounds.height - halfButtonHeight - safeAreaInsets.bottom, newCenter.y)
        
        // Update button position
        button.center = newCenter
        
        // Reset translation to avoid accumulation
        gesture.setTranslation(.zero, in: view)
    }
    
    // Called by the GameViewController's viewWillDisappear
    func viewWillDisappearHandler(animated: Bool) {
        // Clean up when view disappears
        unregisterFromOrientationChanges()
        
        // Stop speech recognition if active
        if SpeechManager.shared.isListening {
            SpeechManager.shared.stopListening()
            hideListeningIndicator()
        }
    }
    
    // Called by the GameViewController's viewDidAppear
    func viewDidAppearHandler(animated: Bool) {
        // Re-register when view appears
        registerForOrientationChanges()
    }
    
    // MARK: - Lu Button Interactions
    @objc private func luButtonTapped() {
        guard let game = self.game as? Game else {
            return
        }
        
        // Check if TTS is playing and stop it if needed
        if luButtonState == .playing {
            luLog(.info, "Lu button tapped while TTS is playing - stopping playback")
            stopTTSPlayback()
            return
        }
        
        // Debug: Check if a conversation exists for this game and log its contents
        let luChatManager = LuChatManager.shared
        let existingConversation = luChatManager.getOrCreateConversation(gameId: game.identifier, gameName: game.name)
        luLog(.info, "💬 DEBUG: Tapped Lu button - Found conversation ID: \(existingConversation.id) with \(existingConversation.messages.count) messages")
        
        // Show loading indicator - update the button to processing state instead
        self.luButtonState = .processing
        
        // Check if game is supported before proceeding
        self.checkGameSupport(for: game) { supported in
            DispatchQueue.main.async {
                // Reset button state
                self.luButtonState = .idle
                
                if supported {
                    // Important: Ensure conversations are saved and reloaded before showing UI
                    luChatManager.saveConversations()
                    
                    // Get conversation to log its current state
                    let conversation = luChatManager.getOrCreateConversation(gameId: game.identifier, gameName: game.name)
                    luLog(.info, "💬 DEBUG: Opening LuChatViewController with conversation ID: \(conversation.id)")
                    luLog(.info, "💬 DEBUG: Conversation has \(conversation.messages.count) messages before presenting")
                    
                    // Create and present the chat view controller
                    let chatViewController = LuChatViewController(game: game, emulatorCore: self.emulatorCore)
                    
                    // Set a flag to force refresh if needed
                    if let customVC = chatViewController as? LuChatViewController {
                        // You may need to add a property like 'forceRefresh' to LuChatViewController
                        // customVC.forceRefresh = true
                    }
                    
                    let navigationController = UINavigationController(rootViewController: chatViewController)
                    self.present(navigationController, animated: true)
                } else {
                    self.showUnsupportedGameMessage()
                }
            }
        }
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Lu can't help you right now",
            message: message,
            preferredStyle: .alert
        )
        
        let okAction = UIAlertAction(title: "OK", style: .default)
        alert.addAction(okAction)
        
        self.present(alert, animated: true)
    }
    
    private func showUnsupportedGameMessage() {
        let alert = UIAlertController(
            title: "Lu Can't Help You Yet",
            message: "Sorry, but Lu doesn't support this game just yet. Don't worry--we're already working on getting it onboarded as soon as possible. Thank you so much for giving Lu a try!",
            preferredStyle: .alert
        )
        
        let okAction = UIAlertAction(title: "OK", style: .default)
        alert.addAction(okAction)
        
        self.present(alert, animated: true)
    }
    
    private func checkGameSupport(for game: Game, completion: @escaping (Bool) -> Void) {
        let sha1 = game.identifier.uppercased()
        
        // Log the check-rom request
        luLog(.info, "Checking game availability on Lu")
        
        let urlString = "\(APIConstants.supportBaseURL)?sha1=\(sha1)"
        guard let url = URL(string: urlString) else {
            luLog(.error, "Invalid URL for check-rom endpoint")
            showError("Sorry, but Lu can't help you with this game right now.")
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = APIConstants.supportTimeout
        
        // Create API context without gameplay attachments
        let context = createAPIContext(for: game, includeAttachments: false)
        request.addContextHeaders(context: context)
        luLog(.info, "Making request to URL: \(urlString)")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] (data, response, error) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let error = error as? URLError {
                    let errorMessage: String
                    switch error.code {
                    case .timedOut:
                        errorMessage = "Connection timed out. Please check your internet connection and try again."
                    case .notConnectedToInternet:
                        errorMessage = "No internet connection. Please check your connection and try again."
                    default:
                        errorMessage = "Unable to connect to Lu. Please try again later."
                    }
                    
                    luLog(.error, "check-rom error: \(errorMessage) - \(error.localizedDescription)")
                    self.showError("Sorry, but Lu can't help you with this game right now.")
                    completion(false)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.showError("Received an invalid response. Please try again.")
                    luLog(.error, "check-rom error: invalid response \(response)")
                    completion(false)
                    return
                }
                
                switch httpResponse.statusCode {
                case 200:
                    if let data = data {
                        do {
                            let supportResponse = try JSONDecoder().decode(GameSupportResponse.self, from: data)

                            ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId = supportResponse.game_id
                            // Store the supports_attachments and supports_savestates flags
                            let supportsAttachments = supportResponse.supports_attachments ?? false
                            let supportsSavestates = supportResponse.supports_savestates ?? false
                            ExperimentalFeatures.shared.Lu.wrappedValue.supportsAttachments = supportsAttachments
                            ExperimentalFeatures.shared.Lu.wrappedValue.supportsSavestates = supportsSavestates
                            
                            luLog(.info, "Response [check-rom]: game_id=\(supportResponse.game_id), supports_attachments=\(supportsAttachments), supports_savestates=\(supportsSavestates), status=\(httpResponse.statusCode)")
                            completion(true)
                        } catch {
                            luLog(.error, "check-rom decode error: \(error.localizedDescription)")
                            self.showError("Failed to process game support information")
                            completion(false)
                        }
                    }
                case 404:
                    luLog(.info, "Response [check-rom]: Game not available yet, status=\(httpResponse.statusCode)")
                    self.showUnsupportedGameMessage()
                    completion(false)
                case 500...599:
                    luLog(.error, "check-rom server error: Status \(httpResponse.statusCode)")
                    self.showError("Lu is temporarily unavailable. Please try again later.")
                    completion(false)
                    
                default:
                    luLog(.error, "check-rom unexpected error, status: \(httpResponse.statusCode)")
                    self.showError("Something unexpected happened. Please try again.")
                    completion(false)
                }
            }
        }
        
        task.resume()
    }
    
    private func createAPIContext(for game: Game, includeAttachments: Bool) -> APIContext {
        let deviceContext = APIContext.DeviceContext(
            device_id: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
            device_name: UIDevice.current.name,
            system_name: UIDevice.current.systemName,
            system_version: UIDevice.current.systemVersion,
            model: UIDevice.current.model,
            bundle_id: Bundle.main.bundleIdentifier ?? "unknown"
        )
        
        var saveStatesMetadata: [String: APIContext.SaveStateMetadata] = [:]
        
        if ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData {
            let saveStates = SaveState.instancesWithPredicate(
                NSPredicate(format: "%K == %@", #keyPath(SaveState.game), game),
                inManagedObjectContext: DatabaseManager.shared.viewContext,
                type: SaveState.self
            )
            
            for saveState in saveStates {
                saveStatesMetadata[saveState.identifier] = APIContext.SaveStateMetadata(
                    name: saveState.name ?? "Untitled",
                    creation_date: saveState.creationDate.ISO8601String(),
                    modified_date: saveState.modifiedDate.ISO8601String(),
                    type: {
                        switch saveState.type {
                        case .auto: return "auto"
                        case .quick: return "quick"
                        case .general: return "general"
                        case .locked: return "locked"
                        }
                    }()
                )
            }
        }
        
        
        let gameContext = APIContext.GameContext(
            name: game.name,
            identifier: game.identifier,
            type: game.type.rawValue,
            save_states_count: game.saveStates.count,
            cheats_count: game.cheats.count,
            last_played: game.playedDate?.ISO8601String()
            // Removed save_states_metadata parameter
        )
        var attachments: [APIContext.Attachment]? = nil
        
        if includeAttachments && ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData {
            var contextAttachments: [APIContext.Attachment] = []
            var tempSaveStateURL: URL? = nil
            
            if ExperimentalFeatures.shared.Lu.wrappedValue.supportsAttachments,
               let emulatorCore = self.emulatorCore,
               let snapshot = emulatorCore.videoManager.snapshot(),
               let imageData = snapshot.pngData() {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = dateFormatter.string(from: Date())
                
                let screenshotAttachment = APIContext.Attachment(
                    type: "screenshot",
                    content: imageData.base64EncodedString(),
                    filename: "screen_\(timestamp).png"
                )
                
                contextAttachments.append(screenshotAttachment)
                luLog(.info, "Added screenshot to API context")
            }
            
            if ExperimentalFeatures.shared.Lu.wrappedValue.supportsSavestates,
               let emulatorCore = self.emulatorCore {
                tempSaveStateURL = FileManager.default.temporaryDirectory.appendingPathComponent("lu_temp_\(UUID().uuidString)")
                let tempSaveState = emulatorCore.saveSaveState(to: tempSaveStateURL!)
                
                if let saveStateData = try? Data(contentsOf: tempSaveState.fileURL) {
                    let saveStateAttachment = APIContext.Attachment(
                        type: "save_state",
                        content: saveStateData.base64EncodedString(),
                        filename: "state_\(tempSaveStateURL!.lastPathComponent)"
                    )
                    contextAttachments.append(saveStateAttachment)
                    
                    if let url = tempSaveStateURL {
                        do {
                            try FileManager.default.removeItem(at: url)
                        } catch {
                            luLog(.error, "Failed to delete temporary save state file: \(error.localizedDescription)")
                        }
                    }
                }
            }
            
            if !contextAttachments.isEmpty {
                attachments = contextAttachments
            }
        }
        
        return APIContext(
            device_context: deviceContext,
            game_context: gameContext,
            attachments: attachments
        )
    }
    
    // Method swizzling to hook into the view controller lifecycle methods
    static func swizzleViewControllerMethods() {
        // This should be called once when the app starts, such as in GameViewController's initialize() method
        
        if self == GameViewController.self {
            let originalViewDidAppear = class_getInstanceMethod(self, #selector(UIViewController.viewDidAppear(_:)))
            let swizzledViewDidAppear = class_getInstanceMethod(self, #selector(GameViewController.swizzled_viewDidAppear(_:)))
            
            let originalViewWillDisappear = class_getInstanceMethod(self, #selector(UIViewController.viewWillDisappear(_:)))
            let swizzledViewWillDisappear = class_getInstanceMethod(self, #selector(GameViewController.swizzled_viewWillDisappear(_:)))
            
            if let originalMethod = originalViewDidAppear, let swizzledMethod = swizzledViewDidAppear {
                method_exchangeImplementations(originalMethod, swizzledMethod)
            }
            
            if let originalMethod = originalViewWillDisappear, let swizzledMethod = swizzledViewWillDisappear {
                method_exchangeImplementations(originalMethod, swizzledMethod)
            }
        }
    }
    
    // Set up speech recognition
    func setupSpeechRecognition() {
        SpeechManager.shared.delegate = self
    }
    
    // Swizzled view controller methods
    @objc func swizzled_viewDidAppear(_ animated: Bool) {
        // Call the original implementation
        self.swizzled_viewDidAppear(animated)
        
        // Call our custom handler
        self.viewDidAppearHandler(animated: animated)
    }
    
    @objc func swizzled_viewWillDisappear(_ animated: Bool) {
        // Call the original implementation
        self.swizzled_viewWillDisappear(animated)
        
        // Call our custom handler
        self.viewWillDisappearHandler(animated: animated)
    }
}

// MARK: - Speech Recognition

// Implement the protocol we've defined
extension GameViewController: SpeechManagerDelegate {
    
    // MARK: - SpeechRecognitionManagerDelegate Methods
    
    func speechRecognitionDidStart() {
        // Update listening label to show it's actively listening
        DispatchQueue.main.async {
            self.listeningLabel?.text = "Listening..."
        }
    }
    
    func speechRecognitionDidStop() {
        // No additional action needed, visual cleanup is handled in endSpeechRecognition()
    }
    
    func speechRecognition(didRecognizePartialResult result: String) {
        // Update listening label with partial transcription
        if !result.isEmpty {
            DispatchQueue.main.async {
                self.listeningLabel?.text = result
            }
        }
    }
    
    func speechRecognition(didRecognizeFinalResult result: String) {
        // Handle final speech recognition result
        DispatchQueue.main.async {
            // Make sure we have a valid question
            guard !result.isEmpty, let game = self.game as? Game else {
                luLog(.error, "⚠️ Speech recognition result invalid or game not available")
                return
            }

            // Log the recognized speech
            luLog(.info, "🎙️ Speech recognized: \"\(result)\"")

            // Update the Lu button to show processing state
            self.luButtonState = .processing

            // Check if game is supported before proceeding
            self.checkGameSupport(for: game) { supported in
                if supported {
                    // Get or create the conversation for this game
                    let luChatManager = LuChatManager.shared
                    let conversation = luChatManager.getOrCreateConversation(gameId: game.identifier, gameName: game.name)
                    
                    // Log the conversation ID and initial message count
                    let initialMessageCount = conversation.messages.count
                    luLog(.info, "💬 Using conversation ID: \(conversation.id) with \(initialMessageCount) existing messages")
                    
                    // IMPORTANT: Make sure we're adding the user message to the conversation
                    // This was missing in the original code - we must ensure the message is added
                    let userMessage = LuChatMessage(type: .userQuestion, content: result)
                    conversation.addMessage(userMessage)
                    
                    // Save the conversation immediately after adding the user message
                    luChatManager.saveConversations()
                    luLog(.info, "💬 Added user message to conversation, now has \(conversation.messages.count) messages")
                    
                    // Ensure the hiddenChatVC is reset between uses to avoid state conflicts
                    if self.hiddenChatVC != nil {
                        self.hiddenChatVC = nil
                    }
                    
                    // Send the question to Lu API using a dedicated method
                    self.askLuUsingChatController(question: result, for: game) { success, responseText in
                        DispatchQueue.main.async {
                            if success, let responseText = responseText {
                                // Log the successful response
                                luLog(.info, "✅ Received Lu response: \"\(responseText.prefix(50))...\"")
                                
                                // Change button state to playing and speak the response
                                self.luButtonState = .playing
                                self.speakResponseUsingLuChat(text: responseText, game: game)
                            } else {
                                // Reset button state and show error message if request failed
                                self.luButtonState = .idle
                                self.showError("Sorry, Lu couldn't understand your question.")
                            }
                        }
                    }
                } else {
                    // Reset button state if game isn't supported
                    self.luButtonState = .idle
                    self.showUnsupportedGameMessage()
                }
            }
        }
    }
    
    func speechRecognition(didFailWithError error: Error) {
        DispatchQueue.main.async {
            // Reset button state on error
            self.luButtonState = .idle
            self.showSpeechRecognitionError(error)
        }
    }
    
    func speechRecognition(authorizationDidChange status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            // Authorization granted, no action needed
            break
        case .denied, .restricted:
            // Show error for permission denied
            DispatchQueue.main.async {
                let error = NSError(
                    domain: "SpeechRecognitionErrorDomain",
                    code: 100,
                    userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied. Please enable it in Settings."]
                )
                self.showSpeechRecognitionError(error)
            }
        case .notDetermined:
            // Waiting for user to grant permission, no action needed
            break
        @unknown default:
            break
        }
    }
}

// MARK: - Lu Voice Interaction Implementation

extension GameViewController {
    
    @objc private func handleLuButtonLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard ExperimentalFeatures.shared.Lu.wrappedValue.enableVoiceInteraction,
              let game = self.game as? Game else {
            return
        }
        
        // If TTS is playing, stop it regardless of gesture
        if luButtonState == .playing && gesture.state == .began {
            stopTTSPlayback()
            return
        }
        
        // Handle different gesture states
        switch gesture.state {
        case .began:
            // Start speech recognition
            luLog(.info, "Long press began - starting speech recognition")
            beginSpeechRecognition()
            
        case .ended, .cancelled, .failed:
            // End speech recognition
            luLog(.info, "Long press ended - stopping speech recognition")
            endSpeechRecognition()
            
        default:
            // Ignore other states
            break
        }
    }
    
    private func beginSpeechRecognition() {
        // Set SpeechRecognitionManager delegate to self
        SpeechManager.shared.delegate = self
        
        // Update Lu button state to recording
        luButtonState = .recording
        
        // Show the listening indicator
        showListeningIndicator()
        
        // Provide haptic feedback to indicate listening has started
        let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
        
        // Start speech recognition
        SpeechManager.shared.startListening { success, error in
            if !success {
                DispatchQueue.main.async {
                    self.hideListeningIndicator()
                    
                    // Show error message
                    if let error = error {
                        self.showSpeechRecognitionError(error)
                    } else {
                        self.showSpeechRecognitionError(nil)
                    }
                }
            }
        }
    }
    
    private func endSpeechRecognition() {
        // Update the listening label to show "Processing..." before stopping
        // This gives user feedback that we're doing something with their speech
        DispatchQueue.main.async {
            self.listeningLabel?.text = "Processing..."
        }
        
        // Update Lu button state to processing
        luButtonState = .processing
        
        // Stop speech recognition - this will now process partial results as final
        SpeechManager.shared.stopListening()
        
        // Increase the delay before hiding the listening indicator
        // This gives more time for processing the partial result as final
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.hideListeningIndicator()
        }
        
        // Provide haptic feedback to indicate listening has ended
        let feedbackGenerator = UINotificationFeedbackGenerator()
        feedbackGenerator.notificationOccurred(.success)
    }
    
    private func showListeningIndicator() {
        guard let button = self.luButton else { return }
        
        // Create the listening indicator view if it doesn't exist
        if listeningIndicatorView == nil {
            let indicatorView = UIView()
            indicatorView.translatesAutoresizingMaskIntoConstraints = false
            indicatorView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.3)
            indicatorView.layer.cornerRadius = 40
            indicatorView.alpha = 0
            
            // Add microphone icon
            let microphoneIcon = UIImageView(image: UIImage(systemName: "mic.fill"))
            microphoneIcon.translatesAutoresizingMaskIntoConstraints = false
            microphoneIcon.tintColor = .white
            microphoneIcon.contentMode = .scaleAspectFit
            
            // Add to view hierarchy
            indicatorView.addSubview(microphoneIcon)
            view.addSubview(indicatorView)
            
            // Set up constraints
            NSLayoutConstraint.activate([
                indicatorView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                indicatorView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                indicatorView.widthAnchor.constraint(equalToConstant: 80),
                indicatorView.heightAnchor.constraint(equalToConstant: 80),
                
                microphoneIcon.centerXAnchor.constraint(equalTo: indicatorView.centerXAnchor),
                microphoneIcon.centerYAnchor.constraint(equalTo: indicatorView.centerYAnchor),
                microphoneIcon.widthAnchor.constraint(equalToConstant: 30),
                microphoneIcon.heightAnchor.constraint(equalToConstant: 30)
            ])
            
            self.listeningIndicatorView = indicatorView
        }
        
        // Create the listening label if it doesn't exist
        if listeningLabel == nil {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = "Listening..."
            label.textColor = .white
            label.font = UIFont.boldSystemFont(ofSize: 16)
            label.textAlignment = .center
            label.backgroundColor = .clear
            label.numberOfLines = 0 // Allow multiple lines
            
            // Add padding using a container view
            let containerView = UIView()
            containerView.translatesAutoresizingMaskIntoConstraints = false
            containerView.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            containerView.layer.cornerRadius = 10
            containerView.clipsToBounds = true
            
            // Add label to container
            view.addSubview(containerView)
            containerView.addSubview(label)
            
            // Set up container and label constraints
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
                label.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
                
                // Fixed width constraint - adjust the value as needed
                containerView.widthAnchor.constraint(equalToConstant: 260),
                
                containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
            ])
            
            self.listeningLabel = label
        }
        
        // Show with animation
        UIView.animate(withDuration: 0.3) {
            self.listeningIndicatorView?.alpha = 1.0
            self.listeningLabel?.superview?.alpha = 1.0
            
            // Start pulsing animation
            self.startPulseAnimation()
        }
        
        // Temporarily hide the Lu button
        button.alpha = 0.3
    }
    
    private func hideListeningIndicator() {
        // Store references to the views before animation
        let indicatorView = self.listeningIndicatorView
        let labelContainer = self.listeningLabel?.superview
        
        UIView.animate(withDuration: 0.3, animations: {
            indicatorView?.alpha = 0
            labelContainer?.alpha = 0 // Animate the container
            self.luButton?.alpha = 1.0
        }) { _ in
            // After animation completes, remove the views from the hierarchy
            indicatorView?.removeFromSuperview()
            labelContainer?.removeFromSuperview()
            self.listeningIndicatorView = nil
            self.listeningLabel = nil
            self.stopPulseAnimation()
        }
    }
    
    private func startPulseAnimation() {
        guard let indicatorView = self.listeningIndicatorView else { return }
        
        // Stop any existing animations
        indicatorView.layer.removeAllAnimations()
        
        // Create pulse animation
        let pulseAnimation = CABasicAnimation(keyPath: "transform.scale")
        pulseAnimation.duration = 1.0
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 1.2
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        
        indicatorView.layer.add(pulseAnimation, forKey: "pulse")
    }
    
    private func stopPulseAnimation() {
        listeningIndicatorView?.layer.removeAllAnimations()
    }
    
    private func showSpeechRecognitionError(_ error: Error?) {
        // Check if we're already presenting an alert to avoid "already presenting" error
        if self.presentedViewController != nil {
            return
        }
        
        let message: String
        
        if let error = error as NSError? {
            // Handle specific error domains by comparing strings
            if error.domain == "kAFAssistantErrorDomain" ||
               error.domain == "com.apple.speech.recognition.error" {
                message = "Speech recognition access denied. Please enable it in Settings."
            } else if error.domain == "com.apple.coreaudio.avfaudio.error" {
                message = "Cannot access microphone. Please check permissions in Settings."
            } else {
                message = "Speech recognition failed: \(error.localizedDescription)"
            }
        } else {
            message = "Unable to start speech recognition. Please try again."
        }
        
        // Show alert with error message
        let alert = UIAlertController(
            title: "Speech Recognition Error",
            message: message,
            preferredStyle: .alert
        )
        
        // Add action to open settings if permissions are the issue
        if message.contains("enable it in Settings") || message.contains("check permissions in Settings") {
            let settingsAction = UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            alert.addAction(settingsAction)
        }
        
        let okAction = UIAlertAction(title: "OK", style: .default)
        alert.addAction(okAction)
        
        self.present(alert, animated: true)
    }
    
    // MARK: - Background API and TTS methods
    
    // Processing indicator properties (using associated objects)
    private var processingIndicatorView: UIView? {
        get {
            return objc_getAssociatedObject(self, &gameViewProcessingIndicatorViewKey) as? UIView
        }
        set {
            objc_setAssociatedObject(self, &gameViewProcessingIndicatorViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var processingLabel: UILabel? {
        get {
            return objc_getAssociatedObject(self, &gameViewProcessingLabelKey) as? UILabel
        }
        set {
            objc_setAssociatedObject(self, &gameViewProcessingLabelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var responseNotificationView: UIView? {
        get {
            return objc_getAssociatedObject(self, &gameViewResponseNotificationViewKey) as? UIView
        }
        set {
            objc_setAssociatedObject(self, &gameViewResponseNotificationViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private func showProcessingIndicator(message: String) {
        // This method is no longer needed as we're using the Lu button state
        // to indicate processing. Left in for compatibility.
        luButtonState = .processing
    }
    
    private func hideProcessingIndicator() {
        // This method is no longer needed as we're using the Lu button state
        // to indicate processing. Left in for compatibility.
        // Only reset to idle if we're not playing audio
        if luButtonState == .processing {
            luButtonState = .idle
        }
    }
    
    private func showResponseNotification(message: String) {
        // This method is no longer needed as we're not showing notification text
        // and instead just changing the button state
    }
    
    private func hideResponseNotification() {
        // This method is no longer needed
    }
    
    // Uses LuChatViewController's TTS functionality to speak the response
    private func speakResponseUsingLuChat(text: String, game: Game) {
        // Update Lu button state to playing
        luButtonState = .playing
        
        luLog(.info, "🗣️ Starting TTS for response: \"\(text.prefix(30))...\"")
        
        // Reset any previous TTS
        if let existingVC = self.hiddenChatVC {
            luLog(.info, "Cleaning up previous hidden chat VC")
            existingVC.viewWillDisappear(false) // Ensure proper cleanup
            self.hiddenChatVC = nil
        }
        
        // Set up audio session first
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            luLog(.info, "🔊 Audio session configured for TTS")
        } catch {
            luLog(.error, "❌ Failed to configure audio session: \(error.localizedDescription)")
        }
        
        // Create a hidden instance of LuChatViewController
        let chatVC = LuChatViewController(game: game, emulatorCore: self.emulatorCore)
        
        // Add completion handler with stronger reference to self to ensure it's not deallocated
        chatVC.onSpeechFinished = { [self] in
            DispatchQueue.main.async {
                // Reset Lu button state to idle when speech is finished
                self.luButtonState = .idle
                luLog(.info, "🔔 Speech finished naturally - resetting Lu button state to idle")
            }
        }
        
        // Create a dummy LuResponseCell to use with the speech function
        // This is necessary because the speak method requires a cell parameter
        let dummyCell = LuResponseCell(style: .default, reuseIdentifier: "DummyCell")
        
        // Actually initiate the speech synthesis with the message text
        chatVC.speak(messageText: text, for: dummyCell)
        
        // Store reference to ensure it's not deallocated too early
        self.hiddenChatVC = chatVC
    }
    
    // Stop TTS playback when button is tapped during playing state
    private func stopTTSPlayback() {
        if let chatVC = self.hiddenChatVC {
            // Stop any ongoing speech
            chatVC.stopSpeaking()
            luLog(.info, "Stopped TTS playback")
            
            // Manually call the completion handler to ensure state is reset
            chatVC.onSpeechFinished?()
            luLog(.info, "🔍 DEBUG: Manually called onSpeechFinished in stopTTSPlayback")
        } else {
            luLog(.info, "⚠️ No hidden chat VC found when trying to stop TTS")
        }
        
        // Reset button state to idle (this is now redundant but kept for safety)
        luButtonState = .idle
        luLog(.info, "🔍 DEBUG: Reset luButtonState to idle directly in stopTTSPlayback")
    }
    
    // Method to ask Lu using a hidden chat controller
    private func askLuUsingChatController(question: String, for game: Game, completion: @escaping (Bool, String?) -> Void) {
        // Create API call without requiring a full chat view controller
        let luChatManager = LuChatManager.shared
        let conversation = luChatManager.getOrCreateConversation(gameId: game.identifier, gameName: game.name)
        
        // Log conversation details for debugging
        luLog(.info, "💬 DEBUG: askLuUsingChatController - Using conversation ID: \(conversation.id)")
        luLog(.info, "💬 DEBUG: Game identifier: \(game.identifier), conversation gameId: \(conversation.gameId)")
        
        // Get API URL and setup parameters
        let activeGameId = ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId
        let urlString = "\(APIConstants.askBaseURL)"
        guard let url = URL(string: urlString) else {
            completion(false, nil)
            return
        }
        
        let shouldIncludeAttachments = ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData
        let context = self.createAPIContext(for: game, includeAttachments: shouldIncludeAttachments)
        
        // Create the request structure
        struct LuRequest: Codable {
            let game_id: String
            let question: String
            let sha1: String
            let remember_conversation: Bool
            let attachments: [APIContext.Attachment]?
        }
        
        let request = LuRequest(
            game_id: activeGameId,
            question: question,
            sha1: game.identifier.uppercased(),
            remember_conversation: true,  // Important: Make sure this is true!
            attachments: context.attachments
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 30.0
        
        urlRequest.addContextHeaders(context: context)
        
        do {
            let requestData = try JSONEncoder().encode(request)
            urlRequest.httpBody = requestData
            
            // Log the request details
            luLog(.info, "🌐 Sending Lu API request for question: \"\(question.prefix(30))...\"")
            
            let task = URLSession.shared.dataTask(with: urlRequest) { (data, response, error) in
                // Handle response on main thread
                DispatchQueue.main.async {
                    if let error = error {
                        luLog(.error, "❌ Network error when calling Lu API: \(error.localizedDescription)")
                        completion(false, nil)
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        luLog(.error, "❌ Response is not HTTPURLResponse")
                        completion(false, nil)
                        return
                    }
                    
                    guard httpResponse.statusCode == 200, let data = data else {
                        luLog(.error, "❌ Server returned non-200 status code (\(httpResponse.statusCode)) or no data")
                        completion(false, nil)
                        return
                    }
                    
                    do {
                        // Define response structure
                        struct LuResponse: Codable {
                            let answer: String
                            let message_id: String
                            let session_id: String?
                        }
                        
                        let luResponse = try JSONDecoder().decode(LuResponse.self, from: data)
                        luLog(.info, "✅ Successfully decoded Lu response with message_id: \(luResponse.message_id)")
                        
                        // Important: Create Lu response message with the correct ID from the API
                        let responseMessage = LuChatMessage(
                            id: luResponse.message_id,
                            type: .luResponse,
                            content: luResponse.answer
                        )
                        
                        // Add to conversation and save immediately
                        conversation.addMessage(responseMessage)
                        luChatManager.saveConversations()
                        
                        // Verify the conversation has been updated
                        let refreshedConversation = luChatManager.getOrCreateConversation(gameId: game.identifier, gameName: game.name)
                        luLog(.info, "💬 Conversation now has \(refreshedConversation.messages.count) messages after adding Lu response")
                        
                        // NEW: Manually update with follow-up questions right here
                        // This ensures follow-up questions are added immediately after the response
                        // instead of relying on a separate API call
                        if let lastIndex = refreshedConversation.messages.lastIndex(where: { $0.type == .luResponse }) {
                            var updatedMessage = refreshedConversation.messages[lastIndex]
                            
                            // Use dummy questions directly
                            let dummyQuestions = [
                                "How do I beat this level?",
                                "What are the best power-ups?",
                                "Any hidden secrets or cheats?"
                            ]
                            
                            luLog(.info, "📋 Manually adding \(dummyQuestions.count) follow-up questions to message ID: \(updatedMessage.id)")
                            updatedMessage.followUpQuestions = dummyQuestions
                            refreshedConversation.messages[lastIndex] = updatedMessage
                            
                            // Save changes
                            luChatManager.saveConversations()
                            luLog(.info, "💾 Saved conversation with follow-up questions")
                        } else {
                            luLog(.error, "⚠️ Could not find last response message to add follow-up questions")
                        }
                        
                        // Return the answer through completion handler
                        completion(true, luResponse.answer)
                    } catch {
                        luLog(.error, "Failed to decode Lu response: \(error.localizedDescription)")
                        completion(false, nil)
                    }
                }
            }
            task.resume()
        } catch {
            luLog(.error, "Failed to encode request: \(error.localizedDescription)")
            completion(false, nil)
        }
    }
}

// Add support for GamesViewController
extension GamesViewController {
    // Computed properties using associated objects
    private var luButton: UIButton? {
        get {
            return objc_getAssociatedObject(self, &gamesViewLuButtonKey) as? UIButton
        }
        set {
            objc_setAssociatedObject(self, &gamesViewLuButtonKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    private var luButtonConstraints: [NSLayoutConstraint] {
        get {
            return objc_getAssociatedObject(self, &gamesViewLuButtonConstraintsKey) as? [NSLayoutConstraint] ?? []
        }
        set {
            objc_setAssociatedObject(self, &gamesViewLuButtonConstraintsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    @objc func addLuButton() {
        
        // Create button (same implementation as in GameViewController)
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        button.setImage(#imageLiteral(resourceName: "Lu"), for: .normal)
        
        // Style button
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.tintColor = .white
        button.layer.cornerRadius = 30 // Increased from 20 to 30 for larger button
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12) // Increased padding
        
        // Add action
        button.addTarget(self, action: #selector(luButtonTapped), for: .touchUpInside)
        
        // Store the reference
        self.luButton = button
        
        // Add to view
        view.addSubview(button)
        
        // Position in bottom right with Auto Layout constraints
        let buttonSize: CGFloat = 60 // Increased from 40 to 60
        
        let constraints = [
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize)
        ]
        
        NSLayoutConstraint.activate(constraints)
        self.luButtonConstraints = constraints
        
        // Add pan gesture recognizer for dragging
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLuButtonPan(_:)))
        button.addGestureRecognizer(panGesture)
        
        // Add orientation change observer
        registerForOrientationChanges()
    }
    
    func registerForOrientationChanges() {
        // First remove any existing observer to avoid duplicates
        unregisterFromOrientationChanges()
        
        // Add orientation change observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    func unregisterFromOrientationChanges() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    @objc func orientationDidChange() {
        // Give the view time to update its layout for the new orientation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let button = self.luButton else { return }
            
            // Only adjust if the button is using frame-based layout (has been dragged)
            if button.translatesAutoresizingMaskIntoConstraints {
                self.keepButtonWithinSafeBounds(button)
            }
        }
    }
    
    private func keepButtonWithinSafeBounds(_ button: UIButton) {
        // Get button dimensions
        let halfButtonWidth = button.bounds.width / 2
        let halfButtonHeight = button.bounds.height / 2
        let safeAreaInsets = view.safeAreaInsets
        
        // Get current position
        var newCenter = button.center
        
        // Constrain x position
        newCenter.x = max(halfButtonWidth + safeAreaInsets.left, newCenter.x)
        newCenter.x = min(view.bounds.width - halfButtonWidth - safeAreaInsets.right, newCenter.x)
        
        // Constrain y position
        newCenter.y = max(halfButtonHeight + safeAreaInsets.top, newCenter.y)
        newCenter.y = min(view.bounds.height - halfButtonHeight - safeAreaInsets.bottom, newCenter.y)
        
        // Update button position with animation
        UIView.animate(withDuration: 0.3) {
            button.center = newCenter
        }
    }
    
    @objc func handleLuButtonPan(_ gesture: UIPanGestureRecognizer) {
        guard let button = gesture.view else { return }
        
        // When dragging starts, switch to frame-based layout
        if gesture.state == .began {
            // Deactivate constraints and switch to frame-based layout
            NSLayoutConstraint.deactivate(self.luButtonConstraints)
            button.translatesAutoresizingMaskIntoConstraints = true
            
            // Make sure the button is still in the same position
            let frame = button.frame
            button.frame = frame
        }
        
        let translation = gesture.translation(in: view)
        
        // Calculate new position
        var newCenter = CGPoint(
            x: button.center.x + translation.x,
            y: button.center.y + translation.y
        )
        
        // Ensure button stays within screen bounds
        let halfButtonWidth = button.bounds.width / 2
        let halfButtonHeight = button.bounds.height / 2
        let safeAreaInsets = view.safeAreaInsets
        
        // Constrain x position
        newCenter.x = max(halfButtonWidth + safeAreaInsets.left, newCenter.x)
        newCenter.x = min(view.bounds.width - halfButtonWidth - safeAreaInsets.right, newCenter.x)
        
        // Constrain y position
        newCenter.y = max(halfButtonHeight + safeAreaInsets.top, newCenter.y)
        newCenter.y = min(view.bounds.height - halfButtonHeight - safeAreaInsets.bottom, newCenter.y)
        
        // Update button position
        button.center = newCenter
        
        // Reset translation to avoid accumulation
        gesture.setTranslation(.zero, in: view)
    }
    
    // Called by the GamesViewController's viewWillDisappear
    func viewWillDisappearHandler(animated: Bool) {
        // Clean up when view disappears
        unregisterFromOrientationChanges()
    }
    
    // Called by the GamesViewController's viewDidAppear
    func viewDidAppearHandler(animated: Bool) {
        // Re-register when view appears
        registerForOrientationChanges()
    }
    
    @objc func luButtonTapped() {
        let hardcodedGameId = "0097b2c8-ef65-49e6-9f78-3f896c73db2e"
        let hardcodedGameIdStaging = ""
        
        // Set the active game ID directly
        ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId = hardcodedGameId
        
        // Create a dummy Game object with the hardcoded ID
        let dummyGame = Game(entity: Game.entity(), insertInto: nil)
        dummyGame.name = "Game Selection"
        dummyGame.identifier = hardcodedGameId
        
        // Get all available games to provide metadata for save states
        let allGames = Game.instancesWithPredicate(
            NSPredicate(value: true),  // Predicate that matches all games
            inManagedObjectContext: DatabaseManager.shared.viewContext,
            type: Game.self
        )
        var gamesWithSaveStates = [Game]()
        
        // Filter to only games with save states
        for game in allGames {
            if game.saveStates.count > 0 {
                gamesWithSaveStates.append(game)
            }
        }
        
        // Launch LuChatViewController directly with nil emulatorCore
        // Include a comment in the question about querying save states
        let chatViewController = LuChatViewController(game: dummyGame, emulatorCore: nil, isFromGamesViewController: true)

        // Log the information instead
        luLog(.info, "Found \(gamesWithSaveStates.count) games with save states")
        let navigationController = UINavigationController(rootViewController: chatViewController)
        present(navigationController, animated: true)
    }
    
    // Swizzled view controller methods - defined BEFORE they are referenced in swizzleViewControllerMethods
    @objc func swizzled_viewDidAppear(_ animated: Bool) {
        // Call the original implementation
        self.swizzled_viewDidAppear(animated)
        
        // Call our custom handler
        self.viewDidAppearHandler(animated: animated)
    }
    
    @objc func swizzled_viewWillDisappear(_ animated: Bool) {
        // Call the original implementation
        self.swizzled_viewWillDisappear(animated)
        
        // Call our custom handler
        self.viewWillDisappearHandler(animated: animated)
    }
    
    // Method swizzling to hook into the view controller lifecycle methods
    static func swizzleViewControllerMethods() {
        // This should be called once when the app starts, such as in GamesViewController's initialize() method
        
        if self == GamesViewController.self {
            let originalViewDidAppear = class_getInstanceMethod(self, #selector(UIViewController.viewDidAppear(_:)))
            let swizzledViewDidAppear = class_getInstanceMethod(self, #selector(GamesViewController.swizzled_viewDidAppear(_:)))
            
            let originalViewWillDisappear = class_getInstanceMethod(self, #selector(UIViewController.viewWillDisappear(_:)))
            let swizzledViewWillDisappear = class_getInstanceMethod(self, #selector(GamesViewController.swizzled_viewWillDisappear(_:)))
            
            if let originalMethod = originalViewDidAppear, let swizzledMethod = swizzledViewDidAppear {
                method_exchangeImplementations(originalMethod, swizzledMethod)
            }
            
            if let originalMethod = originalViewWillDisappear, let swizzledMethod = swizzledViewWillDisappear {
                method_exchangeImplementations(originalMethod, swizzledMethod)
            }
        }
    }
}
