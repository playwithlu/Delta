//
//  LuChatViewController.swift
//  Delta
//
//  Created by Fikri Firat on 21/04/2025.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import UIKit
import DeltaFeatures
import os.log

private extension OSLog {
    static let lu = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.rileytestut.Delta", category: "Lu")
}

private func luLog(_ type: OSLogType = .info, _ message: String) {
    os_log("[Lu] %{public}@", log: .lu, type: type, message)
}

class LuChatViewController: UIViewController {
    
    // MARK: - Properties
    
    private let game: Game
    private var conversation: LuChatConversation
    private var isInitialSetup = true
    private var tempAttachments: [LuChatAttachment] = []
    private var isAskingQuestion = false
    private var isHandlingSendFeedback = false
    
    // UI Components
    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UserMessageCell.self, forCellReuseIdentifier: UserMessageCell.reuseIdentifier)
        tableView.register(LuResponseCell.self, forCellReuseIdentifier: LuResponseCell.reuseIdentifier)
        tableView.register(SystemMessageCell.self, forCellReuseIdentifier: SystemMessageCell.reuseIdentifier)
        tableView.keyboardDismissMode = .onDrag
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 80, right: 0)
        return tableView
    }()
    
    private lazy var questionInputBar: UIView = {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .systemBackground
        
        // Add a subtle top border
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        bar.addSubview(separator)
        
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
        
        return bar
    }()
    
    private lazy var questionTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.isScrollEnabled = true
        textView.layer.cornerRadius = 18
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 1
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 40)
        textView.backgroundColor = .systemBackground
        textView.delegate = self
        return textView
    }()
    
    private lazy var sendButton: UIButton = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        let image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: configuration)
        
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(image, for: .normal)
        button.tintColor = .systemBlue
        button.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
        button.isEnabled = false
        button.alpha = 0.5
        return button
    }()
    
    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
    private var questionBarBottomConstraint: NSLayoutConstraint!
    
    // MARK: - Initialization
    
    init(game: Game) {
        self.game = game
        self.conversation = LuChatManager.shared.getOrCreateConversation(
            gameId: ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId,
            gameName: game.name
        )
        
        super.init(nibName: nil, bundle: nil)
        
        // Configure sheet presentation for iOS 15+
        if #available(iOS 15.0, *) {
            self.sheetPresentationController?.detents = [.medium(), .large()]
            self.sheetPresentationController?.prefersGrabberVisible = true
            self.sheetPresentationController?.preferredCornerRadius = 22
            
            // Start with medium size if no messages yet, otherwise large
            let initialDetent: UISheetPresentationController.Detent = conversation.messages.isEmpty ? .medium() : .large()
            self.sheetPresentationController?.selectedDetentIdentifier = initialDetent.identifier
        }
        
        modalPresentationStyle = .pageSheet
        if self.conversation.messages.isEmpty {
            self.addWelcomeMessageIfNeeded()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle Methods
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupNavigationBar()
        setupKeyboardObservers()
        
        // If we have messages, scroll to the bottom when the view loads
        if !conversation.messages.isEmpty {
            DispatchQueue.main.async {
                self.scrollToBottom(animated: false)
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Only auto-focus on first showing if no messages (just welcome message)
        if isInitialSetup && conversation.messages.count <= 1 {
            questionTextView.becomeFirstResponder()
            isInitialSetup = false
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        questionTextView.resignFirstResponder()
    }
    
    // MARK: - Setup Methods
    
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        // Add table view
        view.addSubview(tableView)
        
        // Add question input bar
        view.addSubview(questionInputBar)
        
        // Add text view and send button to the input bar
        questionInputBar.addSubview(questionTextView)
        questionInputBar.addSubview(sendButton)
        questionInputBar.addSubview(loadingIndicator)
        
        // Setup constraints
        questionBarBottomConstraint = questionInputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: questionInputBar.topAnchor),
            
            questionInputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            questionInputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            questionBarBottomConstraint,
            questionInputBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            
            questionTextView.topAnchor.constraint(equalTo: questionInputBar.topAnchor, constant: 10),
            questionTextView.leadingAnchor.constraint(equalTo: questionInputBar.leadingAnchor, constant: 16),
            questionTextView.trailingAnchor.constraint(equalTo: questionInputBar.trailingAnchor, constant: -16),
            questionTextView.bottomAnchor.constraint(equalTo: questionInputBar.bottomAnchor, constant: -10),
            questionTextView.heightAnchor.constraint(lessThanOrEqualToConstant: 120),
            
            sendButton.trailingAnchor.constraint(equalTo: questionTextView.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: questionTextView.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor)
        ])
    }
    
    private func setupNavigationBar() {
        title = "Ask Lu"
        
        // Add a clear button if the conversation isn't empty
        if !conversation.messages.isEmpty {
            let clearButton = UIBarButtonItem(
                title: "Clear",
                style: .plain,
                target: self,
                action: #selector(handleClearConversation)
            )
            navigationItem.rightBarButtonItem = clearButton
        }
        
        let closeButton = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(handleDismiss)
        )
        navigationItem.leftBarButtonItem = closeButton
    }
    
    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    // MARK: - Actions
    
    @objc private func handleDismiss() {
        dismiss(animated: true)
    }
    
    @objc private func handleClearConversation() {
        let alert = UIAlertController(
            title: "Clear Conversation",
            message: "Are you sure you want to clear this conversation history with Lu?",
            preferredStyle: .alert
        )
        
        let clearAction = UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            
            // Keep the welcome message but clear everything else
            let gameId = self.conversation.gameId
            LuChatManager.shared.clearConversation(gameId: gameId)
            
            // Get a fresh conversation
            self.conversation = LuChatManager.shared.getOrCreateConversation(
                gameId: ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId,
                gameName: self.game.name
            )
            
            // Add welcome message
            self.addWelcomeMessageIfNeeded()
            
            // Update the UI
            self.tableView.reloadData()
            self.setupNavigationBar()
            
            // Expand the sheet to show the input field better
            if #available(iOS 15.0, *) {
                self.sheetPresentationController?.animateChanges {
                    self.sheetPresentationController?.selectedDetentIdentifier = .medium
                }
            }
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(clearAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true)
    }
    
    @objc private func handleSend() {
        guard let question = questionTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty,
              !isAskingQuestion else {
            return
        }
        
        // Disable UI
        isAskingQuestion = true
        sendButton.isEnabled = false
        sendButton.alpha = 0.5
        sendButton.isHidden = true
        loadingIndicator.startAnimating()
        questionTextView.resignFirstResponder()
        
        // Add user message to UI immediately
        let userMessage = LuChatMessage(type: .userQuestion, content: question)
        conversation.addMessage(userMessage)
        LuChatManager.shared.saveConversations()
        
        // Update UI to show the new message
        tableView.reloadData()
        scrollToBottom(animated: true)
        
        // Clear input field
        questionTextView.text = ""
        
        // Request response from Lu
        askLu(question: question)
    }
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        
        let keyboardHeight = keyboardFrame.height
        questionBarBottomConstraint.constant = -keyboardHeight + view.safeAreaInsets.bottom
        
        UIView.animate(withDuration: 0.3) {
            self.view.layoutIfNeeded()
        }
        
        // When keyboard shows, scroll to the bottom of the conversation
        if !conversation.messages.isEmpty {
            scrollToBottom(animated: true)
        }
        
        // Expand to full height when keyboard appears
        if #available(iOS 15.0, *) {
            self.sheetPresentationController?.animateChanges {
                self.sheetPresentationController?.selectedDetentIdentifier = .large
            }
        }
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        questionBarBottomConstraint.constant = 0
        
        UIView.animate(withDuration: 0.3) {
            self.view.layoutIfNeeded()
        }
    }
    
    // MARK: - Helper Methods
    
    private func addWelcomeMessageIfNeeded() {
        // Only add welcome message if the user hasn't seen it before or if conversation is empty
        if !ExperimentalFeatures.shared.Lu.wrappedValue.didShowWelcomeMessage || conversation.messages.isEmpty {
            let welcomeMessage = LuChatMessage(
                type: .systemMessage,
                content: "Welcome to Lu! We and our service providers may record your chat with us. By using this chat, you agree to our Terms of Service and Privacy Policy.\n\nhttps://www.lulabs.ai/legal"
            )
            conversation.addMessage(welcomeMessage)
            LuChatManager.shared.saveConversations()
            
            // Mark welcome message as shown
            ExperimentalFeatures.shared.Lu.wrappedValue.didShowWelcomeMessage = true
        }
    }
    
    private func scrollToBottom(animated: Bool) {
        guard conversation.messages.count > 0 else { return }
        let lastRow = conversation.messages.count - 1
        let indexPath = IndexPath(row: lastRow, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
    }
    
    private func askLu(question: String) {
        // Prepare request
        let urlString = APIConstants.askBaseURL
        guard let url = URL(string: urlString) else {
            showError("Failed to create request")
            resetInputUI()
            return
        }
        
        let activeGameId = ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId
        if activeGameId.isEmpty {
            showError("Failed to prepare your question")
            resetInputUI()
            return
        }
        
        // Check if user has opted in to sharing gameplay data
        let shouldIncludeAttachments = ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData
        
        // Create API context
        guard let gameViewController = self.presentingViewController as? PauseViewController,
              let emulatorCore = gameViewController.emulatorCore else {
            showError("Failed to prepare game context")
            resetInputUI()
            return
        }
        
        let context = createAPIContext(for: game, emulatorCore: emulatorCore, includeAttachments: shouldIncludeAttachments)
        
        let request = LuRequest(
            game_id: activeGameId,
            question: question, 
            sha1: game.identifier.uppercased(),
            remember_conversation: ExperimentalFeatures.shared.Lu.wrappedValue.rememberConversations,
            attachments: context.attachments
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = APIConstants.askTimeout
        
        urlRequest.addContextHeaders(context: context)
        
        do {
            // Encode the request body
            let requestData = try JSONEncoder().encode(request)
            urlRequest.httpBody = requestData
            
            // Log request info
            luLog(.info, "Request payload size: \(requestData.count) bytes")
            
            if let attachments = context.attachments {
                luLog(.info, "Request includes \(attachments.count) attachments")
            } else {
                luLog(.info, "Request does not include any attachments")
            }
            
            luLog(.info, "Request prepared successfully, about to send to \(urlString)")
        } catch {
            luLog(.error, "Failed to encode request: \(error.localizedDescription)")
            showError("Failed to prepare your question")
            resetInputUI()
            return
        }
        
        let task = URLSession.shared.dataTask(with: urlRequest) { [weak self] (data, response, error) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                // Reset UI state
                self.resetInputUI()
                
                if let error = error as? URLError {
                    switch error.code {
                    case .timedOut:
                        self.showError("Lu is taking longer than usual to respond. Please try again.")
                    case .notConnectedToInternet:
                        self.showError("No internet connection. Please check your connection and try again.")
                    default:
                        self.showError("Unable to connect to Lu. Please try again later.")
                    }
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.showError("Received an invalid response. Please try again.")
                    return
                }
                
                guard httpResponse.statusCode == 200,
                      let data = data else {
                    self.showError("Lu encountered an error. Please try again later.")
                    return
                }
                
                do {
                    let luResponse = try JSONDecoder().decode(LuResponse.self, from: data)
                    self.handleLuResponse(response: luResponse, question: question)
                } catch {
                    self.showError("Failed to understand Lu's response. Please try again.")
                }
            }
        }
        task.resume()
    }
    
    private func handleLuResponse(response: LuResponse, question: String) {
        // Create and add Lu response message
        var responseContent = response.answer
        
        if ExperimentalFeatures.shared.Lu.wrappedValue.rememberConversations {
            responseContent += "\n\n(Conversation will be remembered for this game)"
        }
        
        let responseMessage = LuChatMessage(
            id: response.message_id,  // Use server-provided ID for feedback
            type: .luResponse,
            content: responseContent
        )
        
        conversation.addMessage(responseMessage)
        LuChatManager.shared.saveConversations()
        
        // Update UI
        tableView.reloadData()
        scrollToBottom(animated: true)
    }
    
    private func resetInputUI() {
        isAskingQuestion = false
        sendButton.isEnabled = !questionTextView.text.isEmpty
        sendButton.alpha = questionTextView.text.isEmpty ? 0.5 : 1.0
        sendButton.isHidden = false
        loadingIndicator.stopAnimating()
    }
    
    private func showError(_ message: String) {
        // Add error as system message
        let errorMessage = LuChatMessage(
            type: .systemMessage, 
            content: "Error: \(message)"
        )
        conversation.addMessage(errorMessage)
        
        // Update UI
        tableView.reloadData()
        scrollToBottom(animated: true)
    }
    
    private func handleFeedback(for messageId: String, positive: Bool) {
        let feedback = positive ? "POSITIVE" : "NEGATIVE"
        
        if positive {
            // For positive feedback, just send it directly
            sendFeedback(messageId: messageId, feedback: feedback, feedbackMessage: nil)
        } else {
            // For negative feedback, request additional information
            let alert = UIAlertController(
                title: "Additional Feedback",
                message: "How can Lu improve its response to your question?",
                preferredStyle: .alert
            )
            
            alert.addTextField { textField in
                textField.placeholder = "Enter your feedback"
            }
            
            let sendAction = UIAlertAction(title: "Send", style: .default) { [weak self] _ in
                guard let self = self else { return }
                
                let feedbackMessage = alert.textFields?.first?.text
                self.sendFeedback(messageId: messageId, feedback: feedback, feedbackMessage: feedbackMessage)
            }
            
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
            
            alert.addAction(sendAction)
            alert.addAction(cancelAction)
            
            present(alert, animated: true)
        }
    }
    
    private func sendFeedback(messageId: String, feedback: String, feedbackMessage: String?) {
        guard !isHandlingSendFeedback else { return }
        
        // Set flag to prevent multiple sends
        isHandlingSendFeedback = true
        
        // Show loading indicator
        let loadingIndicator = UIActivityIndicatorView(style: .medium)
        loadingIndicator.startAnimating()
        let loadingBarButtonItem = UIBarButtonItem(customView: loadingIndicator)
        navigationItem.rightBarButtonItem = loadingBarButtonItem
        
        let urlString = APIConstants.feedbackBaseURL
        guard let url = URL(string: urlString) else {
            isHandlingSendFeedback = false
            navigationItem.rightBarButtonItem = nil
            setupNavigationBar()
            showError("Failed to send feedback")
            return
        }
        
        let feedbackRequest = FeedbackRequest(message_id: messageId, feedback: feedback, feedback_message: feedbackMessage)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = APIConstants.feedbackTimeout
        
        // Create API context (without attachments)
        guard let gameViewController = self.presentingViewController as? PauseViewController,
              let emulatorCore = gameViewController.emulatorCore else {
            isHandlingSendFeedback = false
            navigationItem.rightBarButtonItem = nil
            setupNavigationBar()
            showError("Failed to prepare game context")
            return
        }
        
        let context = createAPIContext(for: game, emulatorCore: emulatorCore, includeAttachments: false)
        urlRequest.addContextHeaders(context: context)
        
        do {
            urlRequest.httpBody = try JSONEncoder().encode(feedbackRequest)
        } catch {
            isHandlingSendFeedback = false
            navigationItem.rightBarButtonItem = nil
            setupNavigationBar()
            showError("Failed to prepare feedback")
            return
        }
        
        let task = URLSession.shared.dataTask(with: urlRequest) { [weak self] (data, response, error) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                // Reset UI state
                self.isHandlingSendFeedback = false
                self.navigationItem.rightBarButtonItem = nil
                self.setupNavigationBar()
                
                if error != nil {
                    self.showError("Failed to send feedback. Please try again later.")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.showError("Received an invalid response. Please try again.")
                    return
                }
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    // Add confirmation message
                    let confirmMessage = LuChatMessage(
                        type: .systemMessage,
                        content: "Thank you for your feedback! It helps Lu improve."
                    )
                    self.conversation.addMessage(confirmMessage)
                    self.tableView.reloadData()
                    self.scrollToBottom(animated: true)
                } else {
                    self.showError("Something went wrong while sharing your feedback with Lu.")
                }
            }
        }
        task.resume()
    }
    
    // MARK: - API Context Creation
    
    private func createAPIContext(for game: Game, emulatorCore: EmulatorCore, includeAttachments: Bool) -> APIContext {
        let deviceContext = APIContext.DeviceContext(
            device_id: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
            device_name: UIDevice.current.name,
            system_name: UIDevice.current.systemName,
            system_version: UIDevice.current.systemVersion,
            model: UIDevice.current.model,
            bundle_id: Bundle.main.bundleIdentifier ?? "unknown"
        )
        
        // Create save states metadata only if shareGameplayData is enabled
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
            last_played: game.playedDate?.ISO8601String(),
            save_states_metadata: ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData && !saveStatesMetadata.isEmpty ? saveStatesMetadata : nil
        )
        
        // Prepare attachments only if explicitly requested
        var attachments: [APIContext.Attachment]? = nil
        
        if includeAttachments && emulatorCore != nil {
            // Create a collection of attachments
            var contextAttachments: [APIContext.Attachment] = []
            var tempSaveStateURL: URL? = nil
            
            // 1. Capture screenshot if available and supported
            if includeAttachments && ExperimentalFeatures.shared.Lu.wrappedValue.supportsAttachments,
               let snapshot = emulatorCore.videoManager.snapshot(),
               let imageData = snapshot.pngData() {
                
                // Generate timestamp for filename
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
            
            // 2. Capture current game state if supported
            if includeAttachments && ExperimentalFeatures.shared.Lu.wrappedValue.supportsSavestates {
                tempSaveStateURL = FileManager.default.temporaryDirectory.appendingPathComponent("lu_temp_\(UUID().uuidString)")
                let tempSaveState = emulatorCore.saveSaveState(to: tempSaveStateURL!)
                if let saveStateData = try? Data(contentsOf: tempSaveState.fileURL) {
                    let saveStateAttachment = APIContext.Attachment(
                        type: "save_state",
                        content: saveStateData.base64EncodedString(),
                        filename: "state_\(tempSaveStateURL!)"
                    )
                    contextAttachments.append(saveStateAttachment)
                    
                    // Clean up temporary save state file
                    if let url = tempSaveStateURL {
                        do {
                            try FileManager.default.removeItem(at: url)
                        } catch {
                            luLog(.error, "Failed to delete temporary save state file: \(error.localizedDescription)")
                        }
                    }
                }
            }
            
            // Set the attachments if we have any
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

// MARK: - UITableViewDataSource
extension LuChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return conversation.messages.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = conversation.messages[indexPath.row]
        
        switch message.type {
        case .userQuestion:
            let cell = tableView.dequeueReusableCell(withIdentifier: UserMessageCell.reuseIdentifier, for: indexPath) as! UserMessageCell
            cell.configure(with: message)
            return cell
            
        case .luResponse:
            let cell = tableView.dequeueReusableCell(withIdentifier: LuResponseCell.reuseIdentifier, for: indexPath) as! LuResponseCell
            cell.configure(with: message)
            cell.feedbackDelegate = self
            return cell
            
        case .systemMessage:
            let cell = tableView.dequeueReusableCell(withIdentifier: SystemMessageCell.reuseIdentifier, for: indexPath) as! SystemMessageCell
            cell.configure(with: message)
            return cell
        }
    }
}

// MARK: - UITableViewDelegate
extension LuChatViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
}

// MARK: - UITextViewDelegate
extension LuChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        // Enable/disable send button based on text content
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sendButton.isEnabled = !text.isEmpty
        sendButton.alpha = text.isEmpty ? 0.5 : 1.0
    }
}

// MARK: - LuResponseFeedbackDelegate
extension LuChatViewController: LuResponseFeedbackDelegate {
    func didProvideFeedback(for messageId: String, positive: Bool) {
        handleFeedback(for: messageId, positive: positive)
    }
}

// MARK: - Message Cell Classes

// Protocol for feedback actions
protocol LuResponseFeedbackDelegate: AnyObject {
    func didProvideFeedback(for messageId: String, positive: Bool)
}

// Base message cell class
class BaseChatCell: UITableViewCell {
    let messageView = UIView()
    let messageLabel = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        
        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageView.layer.cornerRadius = 12
        messageView.clipsToBounds = true
        contentView.addSubview(messageView)
        
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.font = UIFont.systemFont(ofSize: 16)
        messageView.addSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: messageView.trailingAnchor, constant: -12),
            messageLabel.bottomAnchor.constraint(equalTo: messageView.bottomAnchor, constant: -10)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// User message cell
class UserMessageCell: BaseChatCell {
    static let reuseIdentifier = "UserMessageCell"
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        messageView.backgroundColor = .systemBlue
        messageLabel.textColor = .white
        
        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            messageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            messageView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
            messageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            messageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.75)
        ])
    }
    
    func configure(with message: LuChatMessage) {
        messageLabel.text = message.content
    }
}

// Lu response cell
class LuResponseCell: BaseChatCell {
    static let reuseIdentifier = "LuResponseCell"
    
    private let feedbackContainer = UIView()
    private let thumbsUpButton = UIButton(type: .system)
    private let thumbsDownButton = UIButton(type: .system)
    
    private var messageId: String = ""
    weak var feedbackDelegate: LuResponseFeedbackDelegate?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        messageView.backgroundColor = .secondarySystemBackground
        messageLabel.textColor = .label
        
        // Configure feedback buttons
        feedbackContainer.translatesAutoresizingMaskIntoConstraints = false
        feedbackContainer.backgroundColor = .clear
        messageView.addSubview(feedbackContainer)
        
        thumbsUpButton.translatesAutoresizingMaskIntoConstraints = false
        thumbsUpButton.setImage(UIImage(systemName: "hand.thumbsup"), for: .normal)
        thumbsUpButton.addTarget(self, action: #selector(handleThumbsUp), for: .touchUpInside)
        feedbackContainer.addSubview(thumbsUpButton)
        
        thumbsDownButton.translatesAutoresizingMaskIntoConstraints = false
        thumbsDownButton.setImage(UIImage(systemName: "hand.thumbsdown"), for: .normal)
        thumbsDownButton.addTarget(self, action: #selector(handleThumbsDown), for: .touchUpInside)
        feedbackContainer.addSubview(thumbsDownButton)
        
        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            messageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            messageView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60),
            messageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            messageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.75),
            
            feedbackContainer.topAnchor.constraint(equalTo: messageLabel.bottomAnchor),
            feedbackContainer.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 12),
            feedbackContainer.trailingAnchor.constraint(equalTo: messageView.trailingAnc
