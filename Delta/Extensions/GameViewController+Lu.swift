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
    
    static let baseURL: String = {
        guard let url = plist["LU_BASE_URL"] as? String else {
            fatalError("[Lu] Missing LU_BASE_URL in Lu-Info.plist")
        }
        return url
    }()
    
    static let supportBaseURL = "\(baseURL)/check-rom"
    
    static let supportTimeout: TimeInterval = {
        guard let timeout = plist["SUPPORT_TIMEOUT"] as? TimeInterval else {
            return 10
        }
        return timeout
    }()
}

// MARK: - Game Screen Lu Button Implementation

// Keys for GameViewController associated objects
private var gameViewLuButtonKey: UInt8 = 0
private var gameViewLuButtonConstraintsKey: UInt8 = 0

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
    
    @objc private func luButtonTapped() {
        guard let game = self.game as? Game else {
            return
        }

        // Show initial loading indicator
        let loadingAlert = UIAlertController(
            title: nil,
            message: "Checking game...",
            preferredStyle: .alert
        )
        
        let loadingIndicator = UIActivityIndicatorView(frame: CGRect(x: 10, y: 5, width: 50, height: 50))
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.style = .medium
        loadingIndicator.startAnimating()
        
        loadingAlert.view.addSubview(loadingIndicator)
        self.present(loadingAlert, animated: true)
        
        // Check if game is supported before proceeding
        self.checkGameSupport(for: game) { supported in
            DispatchQueue.main.async {
                loadingAlert.dismiss(animated: true) {
                    if supported {
                        // Present the Lu chat UI
                        let chatViewController = LuChatViewController(game: game, emulatorCore: self.emulatorCore)
                        let navigationController = UINavigationController(rootViewController: chatViewController)
                        self.present(navigationController, animated: true)
                    } else {
                        self.showUnsupportedGameMessage()
                    }
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
            message: "Sorry, but Lu doesn't support this game just yet. Don't worry—we're already working on getting it onboarded as soon as possible. Thank you so much for giving Lu a try!",
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
}
// Keys for GamesViewController associated objects
private var gamesViewLuButtonKey: UInt8 = 0
private var gamesViewLuButtonConstraintsKey: UInt8 = 0

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
    
    @objc func luButtonTapped() {
        // Use hardcoded game ID for GamesViewController
        let hardcodedGameId = "0097b2c8-ef65-49e6-9f78-3f896c73db2e"
        
        // Set the active game ID directly
        ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId = hardcodedGameId
        
        // Create a dummy Game object with the hardcoded ID
        let dummyGame = Game(entity: Game.entity(), insertInto: nil)
        dummyGame.name = "Game Selection"
        dummyGame.identifier = hardcodedGameId
        
        // Launch LuChatViewController directly with nil emulatorCore
        let chatViewController = LuChatViewController(game: dummyGame, emulatorCore: nil)
        let navigationController = UINavigationController(rootViewController: chatViewController)
        present(navigationController, animated: true)
    }
}
