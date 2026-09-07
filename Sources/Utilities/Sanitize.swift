//
//  Sanitize.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/28/25.
//

import Foundation
import Logging

/// Primarily used for embeddings, if the client is processing data from files
/// that can result in mixed strings. Filled with random whitespaces or special
/// symbols. They can utilize on-device solutions to sanitize, or add a flag to the
/// request if they so choose to.
class Sanitize {
    /// Runs sanitization's logic that leads to StandaloneGeneration utility.
    /// - Parameters:
    ///   - texts: An array of strings to sanitize
    ///   - modelProvider: The llm modelProvider
    ///   - logger: The logger
    /// - Returns: Sanitized strings
    static func run(
        _ texts: [String],
        modelProvider: ModelProvider,
        provider: LLMProvider = .serverDefault,
        useLLM: Bool = false,
        logger: Logger
    ) async throws -> [String] {
        var sanitizations: [String] = []
        
        for text in texts {
            if useLLM {
                let prompt: String = promptConcise(text)
                
                let generation = try await StandaloneGeneration
                    .runLLM(
                        prompt,
                        provider: provider,
                        modelProvider: modelProvider,
                        logger: logger
                    )
                
                if let generation, generation.isEmpty == false {
                    sanitizations.append(generation)
                }
            } else {
                let candidates = Sanitize.sanitizePDFContent(text)
                sanitizations.append(contentsOf: candidates)
                // logger.debug("Sanitized: \(sanitizations)")
            }
        }
        
        logger.info("Sanitized with llm: \(useLLM)")
        
        return sanitizations
    }
}

private extension Sanitize {
    static func sanitizePDFContent(_ input: String) -> [String] {
        let texts = input.components(separatedBy: .newlines)
        // Compile regex patterns once for better performance
        let patterns = [
            (pattern: #"Page \d+ of \d+"#, replacement: ""),
            (pattern: #"(?i)\b(?:Confidential|Draft)\b"#, replacement: ""),
            (pattern: #"\n{3,}"#, replacement: "\n\n"),
            (pattern: #" {2,}"#, replacement: " "),
            (pattern: #"\t+"#, replacement: " "),
            (pattern: #"[^\w\s]"#, replacement: ""),
            (pattern: #"^\s+|\s+$"#, replacement: "")
        ]

        var candidates: [String] = []
        
        for text in texts {
            var cleanedText = text
            
            for (pattern, replacement) in patterns {
                do {
                    let regex = try NSRegularExpression(pattern: pattern)
                    cleanedText = regex.stringByReplacingMatches(in: cleanedText,
                                                                 range: NSRange(cleanedText.startIndex..., in: cleanedText),
                                                                 withTemplate: replacement)
                } catch {
                    print("Invalid regex: \(error.localizedDescription)")
                    continue
                }
            }
            
            // Only account for a certain sentence fragment length.
            if text.components(separatedBy: " ").count > 4 {
                candidates.append(text)
            }
        }
        
        return candidates
    }
}

private extension Sanitize {
    static func promptConcise(_ text: String) -> String {
        """
        *Act as an expert text cleaner for extracted PDF content.
        Remove non-content elements like page numbers, headers, footers, watermarks, repeated or boilerplate text, and OCR artifacts. Normalize formatting by standardizing spacing, correcting line breaks, and removing excessive whitespace or non-standard characters. Preserve meaningful content, reconstruct corrupted text if possible, and flag unclear sections in square brackets (e.g., '[unclear: possible OCR error]'). Maintain the original structure. 
        Here is the text to clean:
        \(text).*
        """
    }
    
    static func promptVerbose(_ text: String) -> String {
        """
        *Act as an expert text cleaner for extracted PDF content. Your task is to process the following text and remove or correct all elements that disorient or disrupt readability. Specifically:

        Remove all non-content elements:
        Page numbers, headers, footers, and watermarks.
        Repeated or boilerplate text (e.g., 'Page 1 of 10', 'Confidential', 'Draft').
        Artifacts from OCR or scanning (e.g., random symbols, garbled text, or misread characters).
        
        Normalize formatting:
        Standardize spacing between paragraphs and sentences.
        Correct inconsistent line breaks or hyphenation.
        Remove excessive whitespace, tabs, or non-standard characters.
        
        Preserve and clarify content:
        Retain all meaningful text, tables, lists, and structural elements.
        If a word or phrase is partially corrupted but guessable, reconstruct it logically.
        Flag any sections where the meaning is unclear due to extraction errors.
        
        Output requirements:
        Return only the cleaned, coherent text.
        If you encounter ambiguous fragments, note them in square brackets (e.g., '[unclear: possible OCR error]').
        Maintain the original structure (headings, subheadings, bullet points) as much as possible.
        
        Here is the text to clean:
        \(text).*
        """
    }
}
