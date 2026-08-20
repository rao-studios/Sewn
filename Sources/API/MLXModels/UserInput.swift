//
//  UserInput.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/7/26.
//  MLX Project.

import Foundation

public typealias Message = [String: Any]

/// Container for raw user input.
///
/// A ``UserInputProcessor`` can convert this to ``LMInput``.
/// See also ``ModelContext``.
public struct UserInput: Sendable {

    /// Representation of a prompt or series of messages (conversation).
    ///
    /// This may be a single string with a user prompt or a series of back
    /// and forth responses representing a conversation.
    public enum Prompt: Sendable, CustomStringConvertible {
        /// a single string
        case text(String)

        /// model specific array of dictionaries
        case messages([Message])

        /// model agnostic structured chat (series of messages)
        case chat([Chat.Message])

        public var description: String {
            switch self {
            case .text(let text):
                return text
            case .messages(let messages):
                return messages.map { $0.description }.joined(separator: "\n")
            case .chat(let messages):
                return messages.map(\.content).joined(separator: "\n")
            }
        }
    }

    /// Representation of a video resource.
    public enum Video: Sendable {
        case url(URL)
    }

    /// Representation of an image resource.
    public enum Image: Sendable {
        case url(URL)
    }

    /// Representation of processing to apply to media.
    public struct Processing: Sendable {
        public var resize: CGSize?

        public init(resize: CGSize? = nil) {
            self.resize = resize
        }
    }

    /// The prompt to evaluate.
    public var prompt: Prompt {
        didSet {
            switch prompt {
            case .text, .messages:
                // no action
                break
            case .chat(let messages):
                // rebuild images & videos
                self.images = messages.reduce(into: []) { result, message in
                    result.append(contentsOf: message.images)
                }
                self.videos = messages.reduce(into: []) { result, message in
                    result.append(contentsOf: message.videos)
                }
            }
        }
    }

    /// The images associated with the `UserInput`.
    ///
    /// If the ``prompt-swift.property`` is a ``Prompt-swift.enum/chat(_:)`` this will
    /// collect the images from the chat messages, otherwise these are the stored images with the ``UserInput``.
    public var images = [Image]()

    /// The images associated with the `UserInput`.
    ///
    /// If the ``prompt-swift.property`` is a ``Prompt-swift.enum/chat(_:)`` this will
    /// collect the videos from the chat messages, otherwise these are the stored videos with the ``UserInput``.
    public var videos = [Video]()

    /// Additional values provided for the chat template rendering context
    public var additionalContext: [String: Any]?
    public var processing: Processing = .init()

    /// Initialize the `UserInput` with a single text prompt.
    ///
    /// - Parameters:
    ///   - prompt: text prompt
    ///   - images: optional images
    ///   - videos: optional videos
    ///   - tools: optional tool specifications
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        prompt: String, images: [Image] = [Image](), videos: [Video] = [Video](),
        additionalContext: [String: Any]? = nil
    ) {
        self.prompt = .chat([
            .user(prompt, images: images, videos: videos)
        ])
        self.additionalContext = additionalContext
    }

    /// Initialize the `UserInput` with model specific mesage structures.
    ///
    /// For example, the Qwen2VL model wants input in this format:
    ///
    /// ```
    /// [
    ///     [
    ///         "role": "user",
    ///         "content": [
    ///             [
    ///                 "type": "text",
    ///                 "text": "What is this?"
    ///             ],
    ///             [
    ///                 "type": "image",
    ///             ],
    ///         ]
    ///     ]
    /// ]
    /// ```
    ///
    /// Typically the ``init(chat:tools:additionalContext:)`` should be used instead
    /// along with a model specific ``MessageGenerator`` (supplied by the ``UserInputProcessor``).
    ///
    /// - Parameters:
    ///   - messages: array of dictionaries representing the prompt in a model specific format
    ///   - images: optional images
    ///   - videos: optional videos
    ///   - tools: optional tool specifications
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        messages: [Message], images: [Image] = [Image](), videos: [Video] = [Video](),
        additionalContext: [String: Any]? = nil
    ) {
        self.prompt = .messages(messages)
        self.images = images
        self.videos = videos
        self.additionalContext = additionalContext
    }

    /// Initialize the `UserInput` with a model agnostic structured context.
    ///
    /// For example:
    ///
    /// ```
    /// let chat: [Chat.Message] = [
    ///     .system("You are a helpful photographic assistant."),
    ///     .user("Please describe the photo.", images: [image1]),
    /// ]
    /// let userInput = UserInput(chat: chat)
    /// ```
    ///
    /// A model specific ``MessageGenerator`` (supplied by the ``UserInputProcessor``)
    /// is used to convert this into a model specific format.
    ///
    /// - Parameters:
    ///   - chat: structured content
    ///   - tools: optional tool specifications
    ///   - processing: optional processing to be applied to media
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        chat: [Chat.Message],
        processing: Processing = .init(),
        additionalContext: [String: Any]? = nil
    ) {
        self.prompt = .chat(chat)

        // note: prompt.didSet is not triggered in init
        self.images = chat.reduce(into: []) { result, message in
            result.append(contentsOf: message.images)
        }
        self.videos = chat.reduce(into: []) { result, message in
            result.append(contentsOf: message.videos)
        }

        self.processing = processing
        self.additionalContext = additionalContext
    }

    /// Initialize the `UserInput` with a preconfigured ``Prompt-swift.enum``.
    ///
    /// ``init(chat:tools:additionalContext:)`` is the preferred mechanism.
    ///
    /// - Parameters:
    ///   - prompt: the prompt
    ///   - images: optional images
    ///   - videos: optional videos
    ///   - tools: optional tool specifications
    ///   - processing: optional processing to be applied to media
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        prompt: Prompt,
        images: [Image] = [Image](),
        videos: [Video] = [Video](),
        processing: Processing = .init(),
        additionalContext: [String: Any]? = nil
    ) {
        self.prompt = prompt
        switch prompt {
        case .text, .messages:
            self.images = images
            self.videos = videos
        case .chat:
            break
        }
        self.processing = processing
        self.additionalContext = additionalContext
    }
}

private enum UserInputError: Error {
    case notImplemented
    case unableToLoad(URL)
    case arrayError(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return String("This functionality is not implemented.")
        case .unableToLoad(let url):
            return String("Unable to load image from URL: \(url.path).")
        case .arrayError(let message):
            return String("Error processing image array: \(message).")
        }
    }
}

