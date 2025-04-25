//
//  LuChat.swift
//  Delta
//
//  Created by Fikri Firat on 21/04/2025.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import UIKit
import DeltaFeatures
import DeltaCore
import os.log

// MARK: - Logging

private extension OSLog {
    static let lu = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.rileytestut.Delta", category: "Lu")
}

private func luLog(_ type: OSLogType = .info, _ message: String) {
    os_log("[Lu] %{public}@", log: .lu, type: type, message)
}

// MARK: - Data Models

/// Represents a message in a Lu chat conversation
struct LuChatMessage: Codable, Identifiable {
    enum MessageType: String, Codable {
        case userQuestion
        case luResponse
        case systemMessage
    }

    let id: String
    let type: MessageType
    let content: String
    let timestamp: Date
    var attachments: [LuChatAttachment]?

    init(id: String = UUID().uuidString,
         type: MessageType,
         content: String,
         timestamp: Date = Date(),
         attachments: [LuChatAttachment]? = nil) {
        self.id = id
        self.type = type
        self.content = content
        self.timestamp = timestamp
        self.attachments = attachments
    }
}

/// Represents an attachment in a Lu chat message
struct LuChatAttachment: Codable, Identifiable {
    enum AttachmentType: String, Codable {
        case screenshot
        case saveState
    }

    let id: String
    let type: AttachmentType
    let filename: String
    let data: Data?

    init(id: String = UUID().uuidString,
         type: AttachmentType,
         filename: String,
         data: Data?) {
        self.id = id
        self.type = type
        self.filename = filename
        self.data = data
    }
}

/// Represents a conversation with Lu for a specific game
class LuChatConversation: Codable {
    let id: String
    let gameId: String
    let gameName: String
    var messages: [LuChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         gameId: String,
         gameName: String,
         messages: [LuChatMessage] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.gameId = gameId
        self.gameName = gameName
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func addMessage(_ message: LuChatMessage) {
        messages.append(message)
        updatedAt = Date()
    }
}

/// Manager for storing and retrieving Lu chat conversations
class LuChatManager {
    static let shared = LuChatManager()

    private let conversationsKey = "lu_chat_conversations"
    private(set) var activeConversation: LuChatConversation?
    private(set) var conversations: [String: LuChatConversation] = [:]

    private init() {
        loadConversations()
    }

    func getOrCreateConversation(gameId: String, gameName: String) -> LuChatConversation {
        if let conversation = conversations[gameId] {
            activeConversation = conversation
            return conversation
        } else {
            let newConversation = LuChatConversation(gameId: gameId, gameName: gameName)
            conversations[gameId] = newConversation
            activeConversation = newConversation
            saveConversations()
            return newConversation
        }
    }

    func addMessage(_ message: LuChatMessage, toConversation conversationId: String) {
        guard let conversation = conversations[conversationId] else { return }
        conversation.addMessage(message)
        saveConversations()
    }

    func clearConversation(gameId: String) {
        conversations.removeValue(forKey: gameId)
        if activeConversation?.gameId == gameId {
            activeConversation = nil
        }
        saveConversations()
    }

    func clearAllConversations() {
        conversations.removeAll()
        activeConversation = nil
        saveConversations()
    }

    func saveConversations() {
        do {
            let data = try JSONEncoder().encode(conversations)
            UserDefaults.standard.set(data, forKey: conversationsKey)
        } catch {
            luLog(.error, "Failed to save Lu conversations: \(error.localizedDescription)")
        }
    }

    private func loadConversations() {
        guard let data = UserDefaults.standard.data(forKey: conversationsKey) else { return }

        do {
            conversations = try JSONDecoder().decode([String: LuChatConversation].self, from: data)
        } catch {
            luLog(.error, "Failed to load Lu conversations: \(error.localizedDescription)")
        }
    }
}

// MARK: - Protocol for feedback actions
protocol LuResponseFeedbackDelegate: AnyObject {
    func didProvideFeedback(for messageId: String, positive: Bool)
}

// MARK: - View Controller

/// View controller that displays a chat interface with Lu using a bottom sheet presentation
class LuChatViewController: UIViewController {

    // MARK: - Properties

    private let game: Game
    private let emulatorCore: EmulatorCore?
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

    init(game: Game, emulatorCore: EmulatorCore?) {
        self.game = game
        self.emulatorCore = emulatorCore
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

        if !conversation.messages.isEmpty {
            DispatchQueue.main.async {
                self.scrollToBottom(animated: false)
            }
        }
        // Log the state of interaction and hidden flags right after UI setup
        luLog(.info, "LuChatViewController.viewDidLoad: view.isUserInteractionEnabled=\(self.view.isUserInteractionEnabled), view.isHidden=\(self.view.isHidden)")
        luLog(.info, "LuChatViewController.viewDidLoad: tableView.isUserInteractionEnabled=\(self.tableView.isUserInteractionEnabled), tableView.isHidden=\(self.tableView.isHidden)")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if isInitialSetup && conversation.messages.count <= 1 {
            questionTextView.becomeFirstResponder()
            isInitialSetup = false
        }
        // Log the interaction state of the main view and subviews
        luLog(.info, "LuChatViewController.viewDidAppear: view.isUserInteractionEnabled=\(self.view.isUserInteractionEnabled), view.isHidden=\(self.view.isHidden), view.alpha=\(self.view.alpha)")
        luLog(.info, "LuChatViewController.viewDidAppear: tableView.isUserInteractionEnabled=\(self.tableView.isUserInteractionEnabled), tableView.isHidden=\(self.tableView.isHidden), tableView.alpha=\(self.tableView.alpha)")
        for (i, subview) in self.view.subviews.enumerated() {
            luLog(.info, "Subview[\(i)]: \(type(of: subview)), frame=\(subview.frame), isUserInteractionEnabled=\(subview.isUserInteractionEnabled), isHidden=\(subview.isHidden), alpha=\(subview.alpha)")
        }
        
        self.view.isUserInteractionEnabled = true
        self.tableView.isUserInteractionEnabled = true
        self.view.isHidden = false
        self.tableView.isHidden = false
        luLog(.info, "Force enabled view and tableView interaction & visibility in viewDidAppear.")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        questionTextView.resignFirstResponder()
    }

    // MARK: - Setup Methods

    private func setupUI() {
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)
        view.addSubview(questionInputBar)
        questionInputBar.addSubview(questionTextView)
        questionInputBar.addSubview(sendButton)
        questionInputBar.addSubview(loadingIndicator)

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

        if !conversation.messages.isEmpty {
            let clearButton = UIBarButtonItem(
                title: "Clear",
                style: .plain,
                target: self,
                action: #selector(handleClearConversation)
            )
            navigationItem.rightBarButtonItem = clearButton
        } else {
            navigationItem.rightBarButtonItem = nil
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
            let gameId = self.conversation.gameId
            LuChatManager.shared.clearConversation(gameId: gameId)
            self.conversation = LuChatManager.shared.getOrCreateConversation(
                gameId: ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId,
                gameName: self.game.name
            )
            self.addWelcomeMessageIfNeeded()
            self.tableView.reloadData()
            self.setupNavigationBar()
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

        isAskingQuestion = true
        sendButton.isEnabled = false
        sendButton.alpha = 0.5
        sendButton.isHidden = true
        loadingIndicator.startAnimating()
        questionTextView.resignFirstResponder()

        let userMessage = LuChatMessage(type: .userQuestion, content: question)
        conversation.addMessage(userMessage)
        LuChatManager.shared.saveConversations()

        tableView.reloadData()
        scrollToBottom(animated: true)

        questionTextView.text = ""

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

        if !conversation.messages.isEmpty {
            scrollToBottom(animated: true)
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
        if !ExperimentalFeatures.shared.Lu.wrappedValue.didShowWelcomeMessage || conversation.messages.isEmpty {
            let welcomeMessage = LuChatMessage(
                type: .systemMessage,
                content: "Welcome to Lu! We and our service providers may record your chat with us. By using this chat, you agree to our Terms of Service and Privacy Policy.\n\nhttps://www.lulabs.ai/legal"
            )
            conversation.addMessage(welcomeMessage)
            LuChatManager.shared.saveConversations()

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
        let urlString = APIConstants.askBaseURL
        luLog(.info, "Attempting to create URL from string: '\(urlString)'")

        guard let url = URL(string: urlString) else {
            luLog(.error, "Failed to create URL from string: '\(urlString)'. The string might contain invalid characters or have an improper format.")
            showError("Failed to create request URL")
            resetInputUI()
            return
        }

        luLog(.info, "Successfully created URL: \(url.absoluteString)")

        let activeGameId = ExperimentalFeatures.shared.Lu.wrappedValue.activeGameId
        if activeGameId.isEmpty {
            showError("Failed to prepare your question")
            resetInputUI()
            return
        }

        let shouldIncludeAttachments = ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData

        let context = createAPIContext(for: game, emulatorCore: self.emulatorCore, includeAttachments: shouldIncludeAttachments)

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

        luLog(.info, "Request headers:")
        urlRequest.allHTTPHeaderFields?.forEach { key, value in
            if key.lowercased().contains("auth") || key.lowercased().contains("token") || key == "x-lu-context" {
                luLog(.info, "  \(key): [REDACTED]")
            } else {
                luLog(.info, "  \(key): \(value)")
            }
        }

        do {
            let requestData = try JSONEncoder().encode(request)
            urlRequest.httpBody = requestData

            luLog(.info, "Request payload size: \(requestData.count) bytes")

            if let jsonPreview = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] {
                var safeJsonPreview = [String: Any]()
                for (key, value) in jsonPreview {
                    if key == "question" {
                        safeJsonPreview[key] = value
                    } else if key == "game_id" {
                        safeJsonPreview[key] = value
                    } else if key == "sha1" {
                        safeJsonPreview[key] = value
                    } else if key == "remember_conversation" {
                        safeJsonPreview[key] = value
                    } else if key == "attachments" {
                        if let attachments = value as? [[String: Any]] {
                            safeJsonPreview[key] = "[\(attachments.count) attachments]"
                        } else {
                            safeJsonPreview[key] = "null"
                        }
                    }
                }
                luLog(.info, "Request payload preview: \(safeJsonPreview)")
            }

            if let attachments = context.attachments {
                luLog(.info, "Request includes \(attachments.count) attachments")
                for (index, attachment) in attachments.enumerated() {
                    luLog(.info, "  Attachment \(index+1): type=\(attachment.type), filename=\(attachment.filename), content size=\(attachment.content.count/4*3) bytes (estimated from base64)")
                }
            } else {
                luLog(.info, "Request does not include any attachments")
            }

            luLog(.info, "Request prepared successfully, about to send to '\(urlString)'")
        } catch {
            luLog(.error, "Failed to encode request: \(error.localizedDescription)")
            showError("Failed to prepare your question")
            resetInputUI()
            return
        }

        let task = URLSession.shared.dataTask(with: urlRequest) { [weak self] (data, response, error) in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.resetInputUI()

                if let error = error {
                    luLog(.error, "Network error when calling Lu API: \(error.localizedDescription)")
                    if let urlError = error as? URLError {
                        luLog(.error, "URL Error details - Code: \(urlError.code.rawValue), Description: \(urlError.localizedDescription)")
                        luLog(.error, "Failed URL: \(urlError.failureURLString ?? "unknown")")

                        if let failureURL = urlError.failingURL {
                            luLog(.error, "Failing URL components: scheme=\(failureURL.scheme ?? "nil"), host=\(failureURL.host ?? "nil"), path=\(failureURL.path), query=\(failureURL.query ?? "nil")")
                        }

                        switch urlError.code {
                        case .timedOut:
                            self.showError("Lu is taking longer than usual to respond. Please try again.")
                        case .notConnectedToInternet:
                            self.showError("No internet connection. Please check your connection and try again.")
                        case .badURL:
                            self.showError("Invalid URL format. Please contact support with this error.")
                            luLog(.error, "Bad URL error - This could indicate an issue with the URL format or invalid characters.")
                        case .cannotFindHost, .cannotConnectToHost:
                            self.showError("Cannot connect to Lu server. Please check your connection and try again.")
                        default:
                            self.showError("Unable to connect to Lu. Please try again later.")
                        }
                    } else {
                        self.showError("An error occurred while connecting to Lu: \(error.localizedDescription)")
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    luLog(.error, "Invalid response type received - not an HTTP response")
                    self.showError("Received an invalid response. Please try again.")
                    return
                }

                luLog(.info, "Received HTTP response - Status code: \(httpResponse.statusCode)")
                luLog(.info, "Response headers:")
                httpResponse.allHeaderFields.forEach { key, value in
                    luLog(.info, "  \(key): \(value)")
                }

                guard httpResponse.statusCode == 200,
                      let data = data else {
                    luLog(.error, "Server returned non-200 status code: \(httpResponse.statusCode)")
                    if let data = data,
                       let errorResponse = String(data: data, encoding: .utf8) {
                        luLog(.error, "Error response body: \(errorResponse)")
                    }
                    let errorMessage: String
                    switch httpResponse.statusCode {
                    case 400:
                        errorMessage = "The server couldn't understand the request."
                    case 401, 403:
                        errorMessage = "Authentication issue. Please try again later."
                    case 404:
                        errorMessage = "The requested resource wasn't found."
                    case 429:
                        errorMessage = "Too many requests. Please try again later."
                    case 500, 502, 503, 504:
                        errorMessage = "Lu service is currently unavailable. Please try again later."
                    default:
                        errorMessage = "Lu encountered an error (HTTP \(httpResponse.statusCode)). Please try again later."
                    }
                    self.showError(errorMessage)
                    return
                }

                if !data.isEmpty {
                    luLog(.info, "Received response data: \(data.count) bytes")
                } else {
                    luLog(.error, "Received empty response data")
                }

                do {
                    let luResponse = try JSONDecoder().decode(LuResponse.self, from: data)
                    luLog(.info, "Successfully decoded Lu response with message_id: \(luResponse.message_id)")
                    self.handleLuResponse(response: luResponse, question: question)
                } catch {
                    luLog(.error, "Failed to decode Lu response: \(error.localizedDescription)")
                    if let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) {
                        luLog(.error, "Response preview: \(responsePreview)...")
                    }
                    self.showError("Failed to understand Lu's response. Please try again.")
                }
            }
        }
        task.resume()
    }

    private func handleLuResponse(response: LuResponse, question: String) {
        var responseContent = response.answer

        if ExperimentalFeatures.shared.Lu.wrappedValue.rememberConversations {
            responseContent += "\n\n(Conversation will be remembered for this game)"
        }

        let responseMessage = LuChatMessage(
            id: response.message_id,
            type: .luResponse,
            content: responseContent
        )

        conversation.addMessage(responseMessage)
        LuChatManager.shared.saveConversations()

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
        let errorMessage = LuChatMessage(
            type: .systemMessage,
            content: "Error: \(message)"
        )
        conversation.addMessage(errorMessage)
        tableView.reloadData()
        scrollToBottom(animated: true)
    }

    private func handleFeedback(for messageId: String, positive: Bool) {
        luLog(.info, "⚙️ handleFeedback called for message ID: \(messageId), positive: \(positive)")

        let feedback = positive ? "POSITIVE" : "NEGATIVE"

        if positive {
            sendFeedback(messageId: messageId, feedback: feedback, feedbackMessage: nil)
        } else {
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

        isHandlingSendFeedback = true

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

        let context = createAPIContext(for: game, emulatorCore: self.emulatorCore, includeAttachments: false)
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

    private func createAPIContext(for game: Game, emulatorCore: EmulatorCore?, includeAttachments: Bool) -> APIContext {
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
            //save_states_metadata: ExperimentalFeatures.shared.Lu.wrappedValue.shareGameplayData && !saveStatesMetadata.isEmpty ? saveStatesMetadata : nil
        )

        var attachments: [APIContext.Attachment]? = nil

        if includeAttachments && emulatorCore != nil {
            var contextAttachments: [APIContext.Attachment] = []
            var tempSaveStateURL: URL? = nil

            if includeAttachments && ExperimentalFeatures.shared.Lu.wrappedValue.supportsAttachments,
               let snapshot = emulatorCore?.videoManager.snapshot(),
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

            if includeAttachments && ExperimentalFeatures.shared.Lu.wrappedValue.supportsSavestates {
                tempSaveStateURL = FileManager.default.temporaryDirectory.appendingPathComponent("lu_temp_\(UUID().uuidString)")
                tempSaveStateURL = FileManager.default.temporaryDirectory.appendingPathComponent("lu_temp_\(UUID().uuidString)")
                let tempSaveState = emulatorCore?.saveSaveState(to: tempSaveStateURL!)
                if let saveStateData = try? Data(contentsOf: tempSaveState?.fileURL ?? URL(fileURLWithPath: "")) {
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

// MARK: - UITableViewDataSource
extension LuChatViewController: UITableViewDataSource {
    @objc func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return conversation.messages.count
    }

    @objc func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = conversation.messages[indexPath.row]

        switch message.type {
        case .userQuestion:
            let cell = tableView.dequeueReusableCell(withIdentifier: UserMessageCell.reuseIdentifier, for: indexPath) as! UserMessageCell
            cell.configure(with: message)
            return cell

        case .luResponse:
            let cell = tableView.dequeueReusableCell(withIdentifier: LuResponseCell.reuseIdentifier, for: indexPath) as! LuResponseCell
            cell.feedbackDelegate = self
            print("cellForRowAt: Set feedbackDelegate for messageId: \(message.id), cell: \(cell)")
            luLog(.info, "cellForRowAt: Set feedbackDelegate for messageId: \(message.id), cell: \(cell)")
            cell.configure(with: message)
            #if DEBUG
            if message.id.starts(with: "8") {
                luLog(.info, "Lu response cell configured for message ID: \(message.id)")
            }
            #endif
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
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sendButton.isEnabled = !text.isEmpty
        sendButton.alpha = text.isEmpty ? 0.5 : 1.0
    }
}

// MARK: - LuResponseFeedbackDelegate
extension LuChatViewController: LuResponseFeedbackDelegate {
    func didProvideFeedback(for messageId: String, positive: Bool) {
        luLog(.info, "🔔 LuChatViewController received feedback for message ID: \(messageId), positive: \(positive)")
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.handleFeedback(for: messageId, positive: positive)
            }
            return
        }
        handleFeedback(for: messageId, positive: positive)
    }
}

// MARK: - Message Cell Classes

class BaseChatCell: UITableViewCell {
    let messageView = UIView()
    let messageTextView = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = true

        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageView.layer.cornerRadius = 12
        messageView.clipsToBounds = true
        messageView.isUserInteractionEnabled = true
        contentView.addSubview(messageView)

        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.font = UIFont.systemFont(ofSize: 16)
        messageTextView.isEditable = false
        messageTextView.isSelectable = true
        messageTextView.isScrollEnabled = false
        messageTextView.backgroundColor = .clear
        messageTextView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        messageTextView.dataDetectorTypes = [.link]
        messageTextView.isUserInteractionEnabled = true
        messageView.addSubview(messageTextView)

        NSLayoutConstraint.activate([
            messageTextView.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 10),
            messageTextView.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 12),
            messageTextView.trailingAnchor.constraint(equalTo: messageView.trailingAnchor, constant: -12),
            messageTextView.bottomAnchor.constraint(equalTo: messageView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
class UserMessageCell: BaseChatCell {
    static let reuseIdentifier = "UserMessageCell"
    
    private let timestampLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        messageView.backgroundColor = .systemBlue
        messageTextView.textColor = .white
        
        // Configure timestamp label
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = UIFont.systemFont(ofSize: 11)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.textAlignment = .right
        contentView.addSubview(timestampLabel)

        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            messageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            messageView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
            messageView.bottomAnchor.constraint(equalTo: timestampLabel.topAnchor, constant: -2),
            messageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.75),
            
            timestampLabel.trailingAnchor.constraint(equalTo: messageView.trailingAnchor),
            timestampLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
            timestampLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with message: LuChatMessage) {
        messageTextView.text = message.content
        
        // Format and set timestamp
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        timestampLabel.text = formatter.string(from: message.timestamp)
    }
    }

class LuResponseCell: UITableViewCell {
    static let reuseIdentifier = "LuResponseCell"

    let messageView = UIView()
    let messageTextView = UITextView()
    let feedbackContainer = UIView()
    let thumbsUpButton = UIButton(type: .system)
    let thumbsDownButton = UIButton(type: .system)
    let feedbackLabel = UILabel()
    let timestampLabel = UILabel()

    private var messageId: String = ""
    weak var feedbackDelegate: LuResponseFeedbackDelegate?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Bubble
        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageView.layer.cornerRadius = 12
        messageView.clipsToBounds = true
        messageView.backgroundColor = .systemBackground
        messageView.layer.borderWidth = 1
        messageView.layer.borderColor = UIColor.systemGray5.cgColor
        messageView.layer.shadowColor = UIColor.black.cgColor
        messageView.layer.shadowOpacity = 0.1
        messageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        messageView.layer.shadowRadius = 2
        contentView.addSubview(messageView)

        // Selectable text
        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.font = UIFont.systemFont(ofSize: 16)
        messageTextView.isEditable = false
        messageTextView.isSelectable = true
        messageTextView.isScrollEnabled = false
        messageTextView.backgroundColor = .clear
        messageTextView.textColor = .label
        messageTextView.dataDetectorTypes = [.link]
        messageTextView.textContainerInset = .zero
        messageTextView.textContainer.lineFragmentPadding = 0
        messageView.addSubview(messageTextView)
        
        // Timestamp
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = UIFont.systemFont(ofSize: 11)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.textAlignment = .left
        contentView.addSubview(timestampLabel)

        // Feedback row (NOT inside messageView!)
        feedbackContainer.translatesAutoresizingMaskIntoConstraints = false
        feedbackContainer.backgroundColor = .clear
        contentView.addSubview(feedbackContainer)

        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.text = "Helpful?"
        feedbackLabel.font = UIFont.systemFont(ofSize: 12)
        feedbackLabel.textColor = .secondaryLabel
        feedbackLabel.isUserInteractionEnabled = false
        feedbackContainer.addSubview(feedbackLabel)

        thumbsUpButton.translatesAutoresizingMaskIntoConstraints = false
        let upConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        thumbsUpButton.setImage(UIImage(systemName: "hand.thumbsup", withConfiguration: upConfig), for: .normal)
        thumbsUpButton.tintColor = .systemBlue
        thumbsUpButton.backgroundColor = UIColor.systemGray6
        thumbsUpButton.layer.cornerRadius = 15
        thumbsUpButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        thumbsUpButton.isUserInteractionEnabled = true
        thumbsUpButton.addTarget(self, action: #selector(handleThumbsUp), for: .touchUpInside)
        feedbackContainer.addSubview(thumbsUpButton)

        thumbsDownButton.translatesAutoresizingMaskIntoConstraints = false
        let downConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        thumbsDownButton.setImage(UIImage(systemName: "hand.thumbsdown", withConfiguration: downConfig), for: .normal)
        thumbsDownButton.tintColor = .systemGray
        thumbsDownButton.backgroundColor = UIColor.systemGray6
        thumbsDownButton.layer.cornerRadius = 15
        thumbsDownButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        thumbsDownButton.isUserInteractionEnabled = true
        thumbsDownButton.addTarget(self, action: #selector(handleThumbsDown), for: .touchUpInside)
        feedbackContainer.addSubview(thumbsDownButton)

        // Constraints
        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            messageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            messageView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60),
            messageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.75),

            messageTextView.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 10),
            messageTextView.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 12),
            messageTextView.trailingAnchor.constraint(equalTo: messageView.trailingAnchor, constant: -12),
            messageTextView.bottomAnchor.constraint(equalTo: messageView.bottomAnchor, constant: -10),

            feedbackContainer.topAnchor.constraint(equalTo: messageView.bottomAnchor, constant: 4),
            feedbackContainer.leadingAnchor.constraint(equalTo: messageView.leadingAnchor),
            feedbackContainer.trailingAnchor.constraint(equalTo: messageView.trailingAnchor), // <-- THIS IS CRITICAL
            feedbackContainer.heightAnchor.constraint(equalToConstant: 32),
            feedbackContainer.bottomAnchor.constraint(equalTo: timestampLabel.topAnchor, constant: -2),

            feedbackLabel.leadingAnchor.constraint(equalTo: feedbackContainer.leadingAnchor, constant: 4),
            feedbackLabel.centerYAnchor.constraint(equalTo: feedbackContainer.centerYAnchor),

            thumbsUpButton.centerYAnchor.constraint(equalTo: feedbackContainer.centerYAnchor),
            thumbsUpButton.leadingAnchor.constraint(equalTo: feedbackLabel.trailingAnchor, constant: 8),
            thumbsUpButton.widthAnchor.constraint(equalToConstant: 30),
            thumbsUpButton.heightAnchor.constraint(equalToConstant: 30),

            thumbsDownButton.centerYAnchor.constraint(equalTo: feedbackContainer.centerYAnchor),
            thumbsDownButton.leadingAnchor.constraint(equalTo: thumbsUpButton.trailingAnchor, constant: 8),
            thumbsDownButton.widthAnchor.constraint(equalToConstant: 30),
            thumbsDownButton.heightAnchor.constraint(equalToConstant: 30),
            
            timestampLabel.leadingAnchor.constraint(equalTo: messageView.leadingAnchor),
            timestampLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            timestampLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2)
        ])
        // Ensure no overlap: Highest z-order for feedbackContainer
        contentView.bringSubviewToFront(feedbackContainer)
    }

    @objc private func handleThumbsUp() {
        guard !messageId.isEmpty else { return }
        UIView.animate(withDuration: 0.2) {
            self.thumbsUpButton.setImage(UIImage(systemName: "hand.thumbsup.fill"), for: .normal)
            self.thumbsDownButton.setImage(UIImage(systemName: "hand.thumbsdown"), for: .normal)
            self.thumbsUpButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.2)
            self.thumbsUpButton.tintColor = .systemBlue
            self.thumbsDownButton.tintColor = .systemGray
            self.feedbackLabel.text = "Thanks!"
        }
        self.thumbsUpButton.isEnabled = false
        self.thumbsDownButton.isEnabled = false
        feedbackDelegate?.didProvideFeedback(for: self.messageId, positive: true)
    }

    @objc private func handleThumbsDown() {
        guard !messageId.isEmpty else { return }
        UIView.animate(withDuration: 0.2) {
            self.thumbsUpButton.setImage(UIImage(systemName: "hand.thumbsup"), for: .normal)
            self.thumbsDownButton.setImage(UIImage(systemName: "hand.thumbsdown.fill"), for: .normal)
            self.thumbsDownButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.2)
            self.thumbsUpButton.tintColor = .systemGray
            self.thumbsDownButton.tintColor = .systemRed
            self.feedbackLabel.text = "Thanks!"
        }
        self.thumbsUpButton.isEnabled = false
        self.thumbsDownButton.isEnabled = false
        feedbackDelegate?.didProvideFeedback(for: self.messageId, positive: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(with message: LuChatMessage) {
        messageTextView.text = message.content
        messageId = message.id
        
        // Reset feedback buttons to initial state
        thumbsUpButton.isEnabled = true
        thumbsDownButton.isEnabled = true
        thumbsUpButton.alpha = 1.0
        thumbsDownButton.alpha = 1.0
        thumbsUpButton.backgroundColor = UIColor.systemGray6
        thumbsDownButton.backgroundColor = UIColor.systemGray6
        thumbsUpButton.setImage(UIImage(systemName: "hand.thumbsup"), for: .normal)
        thumbsDownButton.setImage(UIImage(systemName: "hand.thumbsdown"), for: .normal)
        thumbsUpButton.tintColor = .systemBlue
        thumbsDownButton.tintColor = .systemGray
        feedbackLabel.text = "Helpful?"
        
        // Format and set timestamp
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        timestampLabel.text = formatter.string(from: message.timestamp)
    }
}

class SystemMessageCell: BaseChatCell {
    static let reuseIdentifier = "SystemMessageCell"
    
    private let timestampLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        messageView.backgroundColor = .tertiarySystemFill
        messageTextView.textColor = .secondaryLabel
        messageTextView.font = UIFont.systemFont(ofSize: 14)
        
        // Configure timestamp label
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = UIFont.systemFont(ofSize: 11)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.textAlignment = .center
        contentView.addSubview(timestampLabel)

        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            messageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            messageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),
            messageView.bottomAnchor.constraint(equalTo: timestampLabel.topAnchor, constant: -2),
            
            timestampLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            timestampLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with message: LuChatMessage) {
        messageTextView.text = message.content
        
        // Format and set timestamp
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        timestampLabel.text = formatter.string(from: message.timestamp)
    }
}

// MARK: - API Models

private struct LuRequest: Codable {
    let game_id: String
    let question: String
    let sha1: String
    let remember_conversation: Bool
    let attachments: [APIContext.Attachment]?
}

private struct LuResponse: Codable {
    let answer: String
    let message_id: String
}

private struct FeedbackRequest: Codable {
    let message_id: String
    let feedback: String
    let feedback_message: String?
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

    static let askBaseURL = "\(baseURL)/ask"
    static let supportBaseURL = "\(baseURL)/check-rom"
    static let feedbackBaseURL = "\(baseURL)/feedbacks"

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

// MARK: - Extensions for API Support

private extension URLRequest {
    mutating func addContextHeaders(context: APIContext) {
        do {
            let headersOnlyContext = APIContext(
                device_context: context.device_context,
                game_context: context.game_context,
                attachments: nil
            )
            let contextData = try JSONEncoder().encode(headersOnlyContext)
            guard let contextString = String(data: contextData, encoding: .utf8) else {
                luLog(.error, "Failed to encode context data to string")
                return
            }
            luLog(.info, "Adding x-lu-context header (size: \(contextString.count) characters) - attachments excluded")
            if contextString.count > 8000 {
                luLog(.info, "x-lu-context header is still large (\(contextString.count) chars) even without attachments.")
            }
            setValue(contextString, forHTTPHeaderField: "x-lu-context")
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
