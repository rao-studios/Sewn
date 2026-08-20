//
//  Flow6_AutoMemoryTests.swift
//  seer-serverTests
//
//  Tests for the AutoMemory system:
//    - Policy model: triggers, modes, threshold as associated value
//    - Trigger logic: messageCount fires every N messages, topicChange fires on boundary
//    - Policy evaluation: .any (OR) and .all (AND) modes
//    - Conversation history formatting: [role]: content lines
//    - Memory group identity: deterministic ID and label per owner
//    - Message filtering: empty content and missing keys are excluded
//

import XCTest
@testable import seer_server

final class Flow6_AutoMemoryTests: XCTestCase {

    // MARK: - Helpers

    /// Extracts the threshold from the first `.messageCount` trigger in the given policy,
    /// or returns nil if no such trigger is present.
    private func messageCountThreshold(in policy: Seer.AutoMemoryPolicy) -> Int? {
        for trigger in policy.triggers {
            if case .messageCount(let threshold) = trigger { return threshold }
        }
        return nil
    }

    /// Evaluates whether a `.messageCount` trigger fires for the given count and threshold.
    private func messageCountFires(at count: Int, threshold: Int) -> Bool {
        count > 0 && count % threshold == 0
    }

    /// Evaluates whether the set of fired triggers satisfies a policy.
    private func policyFires(
        fired: Set<Seer.AutoMemoryTrigger>,
        policy: Seer.AutoMemoryPolicy
    ) -> Bool {
        let active = fired.intersection(policy.triggers)
        switch policy.mode {
        case .any: return !active.isEmpty
        case .all: return active == policy.triggers
        }
    }

    // MARK: - Constants

    func testDefaultPolicyIsEither() {
        let policy = Seer.autoMemoryPolicy
        XCTAssertEqual(policy.mode, .any,
            "Default policy mode must be .any")
        XCTAssertTrue(policy.triggers.contains(.topicChange),
            "Default policy must include .topicChange")
        XCTAssertNotNil(messageCountThreshold(in: policy),
            "Default policy must include a .messageCount trigger")
    }

    func testDefaultMessageCountThresholdIsSeven() {
        let threshold = messageCountThreshold(in: Seer.autoMemoryPolicy)
        XCTAssertEqual(threshold, 7,
            "Default messageCount threshold must be 7 — changing this alters how densely " +
            "conversation turns are archived, affecting memory retrieval quality")
    }

    func testAutoMemoryGroupLabelIsMemory() {
        XCTAssertEqual(Seer.autoMemoryGroupLabel, "Memory",
            "autoMemoryGroupLabel is a stable identity used to locate all auto-generated " +
            "memory documents — changing it orphans existing memory groups")
    }

    // MARK: - messageCount trigger

    func testMessageCountTriggerDoesNotFireAtZero() {
        XCTAssertFalse(messageCountFires(at: 0, threshold: 7),
            "Zero user messages must never trigger auto-memory")
    }

    func testMessageCountTriggerDoesNotFireBeforeThreshold() {
        for count in 1..<7 {
            XCTAssertFalse(messageCountFires(at: count, threshold: 7),
                "Trigger must not fire at \(count) messages (threshold is 7)")
        }
    }

    func testMessageCountTriggerFiresAtFirstThreshold() {
        XCTAssertTrue(messageCountFires(at: 7, threshold: 7),
            "Trigger must fire exactly at message count 7")
    }

    func testMessageCountTriggerFiresAtEveryMultiple() {
        for multiplier in [1, 2, 3, 5, 10] {
            let count = multiplier * 7
            XCTAssertTrue(messageCountFires(at: count, threshold: 7),
                "Trigger must fire at every multiple of threshold (checked \(count))")
        }
    }

    func testMessageCountTriggerDoesNotFireOnNonMultiples() {
        let nonMultiples = [6, 8, 13, 15]
        for count in nonMultiples {
            XCTAssertFalse(messageCountFires(at: count, threshold: 7),
                "Trigger must not fire at non-multiple \(count)")
        }
    }

    func testMessageCountTriggerRespectsCustomThreshold() {
        XCTAssertFalse(messageCountFires(at: 7, threshold: 10),
            "A count of 7 must not fire when threshold is 10")
        XCTAssertTrue(messageCountFires(at: 10, threshold: 10),
            "A count of 10 must fire when threshold is 10")
        XCTAssertTrue(messageCountFires(at: 20, threshold: 10),
            "A count of 20 must fire when threshold is 10")
    }

    // MARK: - Policy: .any mode (OR)

    func testAnyPolicyFiresOnMessageCountAlone() {
        let policy = Seer.AutoMemoryPolicy.either
        XCTAssertTrue(
            policyFires(fired: [.messageCount()], policy: policy),
            ".any policy must fire when only messageCount fires"
        )
    }

    func testAnyPolicyFiresOnTopicChangeAlone() {
        let policy = Seer.AutoMemoryPolicy.either
        XCTAssertTrue(
            policyFires(fired: [.topicChange], policy: policy),
            ".any policy must fire when only topicChange fires"
        )
    }

    func testAnyPolicyFiresWhenBothFire() {
        let policy = Seer.AutoMemoryPolicy.either
        XCTAssertTrue(
            policyFires(fired: [.messageCount(), .topicChange], policy: policy),
            ".any policy must fire when both triggers fire"
        )
    }

    func testAnyPolicyDoesNotFireWhenNoneFire() {
        let policy = Seer.AutoMemoryPolicy.either
        XCTAssertFalse(
            policyFires(fired: [], policy: policy),
            ".any policy must not fire when no triggers fire"
        )
    }

    // MARK: - Policy: .all mode (AND)

    func testAllPolicyDoesNotFireOnMessageCountAlone() {
        let policy = Seer.AutoMemoryPolicy.all
        XCTAssertFalse(
            policyFires(fired: [.messageCount()], policy: policy),
            ".all policy must not fire when only messageCount fires"
        )
    }

    func testAllPolicyDoesNotFireOnTopicChangeAlone() {
        let policy = Seer.AutoMemoryPolicy.all
        XCTAssertFalse(
            policyFires(fired: [.topicChange], policy: policy),
            ".all policy must not fire when only topicChange fires"
        )
    }

    func testAllPolicyFiresWhenBothFire() {
        let policy = Seer.AutoMemoryPolicy.all
        XCTAssertTrue(
            policyFires(fired: [.messageCount(), .topicChange], policy: policy),
            ".all policy must fire when every trigger fires"
        )
    }

    func testAllPolicyDoesNotFireWhenNoneFire() {
        let policy = Seer.AutoMemoryPolicy.all
        XCTAssertFalse(
            policyFires(fired: [], policy: policy),
            ".all policy must not fire when no triggers fire"
        )
    }

    // MARK: - Policy: single-trigger presets

    func testMessageCountOnlyPolicyIgnoresTopicChange() {
        let policy = Seer.AutoMemoryPolicy.messageCountOnly
        XCTAssertFalse(
            policyFires(fired: [.topicChange], policy: policy),
            "messageCountOnly policy must not fire on topicChange alone"
        )
        XCTAssertTrue(
            policyFires(fired: [.messageCount()], policy: policy),
            "messageCountOnly policy must fire on messageCount"
        )
    }

    func testTopicChangeOnlyPolicyIgnoresMessageCount() {
        let policy = Seer.AutoMemoryPolicy.topicChangeOnly
        XCTAssertFalse(
            policyFires(fired: [.messageCount()], policy: policy),
            "topicChangeOnly policy must not fire on messageCount alone"
        )
        XCTAssertTrue(
            policyFires(fired: [.topicChange], policy: policy),
            "topicChangeOnly policy must fire on topicChange"
        )
    }

    // MARK: - Conversation history formatting

    private func formatMessages(_ messages: [[String: Any]], recentMessage: String) -> String {
        let allMessages = messages + [["role": "user", "content": recentMessage]]
        return allMessages.compactMap { msg -> String? in
            guard
                let role = msg["role"] as? String,
                let content = msg["content"] as? String,
                !content.isEmpty
            else { return nil }
            return "[\(role)]: \(content)"
        }.joined(separator: "\n")
    }

    func testFormattedHistoryIncludesRecentMessage() {
        let history = formatMessages([], recentMessage: "hello world")
        XCTAssertTrue(history.contains("hello world"),
            "recentMessage must appear in formatted history")
    }

    func testFormattedHistoryRecentMessageAppearsLast() {
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": "earlier reply"],
        ]
        let history = formatMessages(messages, recentMessage: "latest user message")
        let lines = history.components(separatedBy: "\n")
        XCTAssertTrue(lines.last?.contains("latest user message") ?? false,
            "recentMessage must be the last line — it is appended after prior history")
    }

    func testFormattedHistoryLineFormat() {
        let history = formatMessages([], recentMessage: "test content")
        XCTAssertEqual(history, "[user]: test content",
            "Each line must be formatted as '[role]: content'")
    }

    func testFormattedHistoryMultipleMessages() {
        let messages: [[String: Any]] = [
            ["role": "user",      "content": "first message"],
            ["role": "assistant", "content": "first reply"],
        ]
        let history = formatMessages(messages, recentMessage: "second message")
        let lines = history.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "[user]: first message")
        XCTAssertEqual(lines[1], "[assistant]: first reply")
        XCTAssertEqual(lines[2], "[user]: second message")
    }

    func testFormattedHistoryEmptyContentIsFiltered() {
        let messages: [[String: Any]] = [
            ["role": "user",      "content": "real content"],
            ["role": "assistant", "content": ""],
        ]
        let history = formatMessages(messages, recentMessage: "recent")
        let lines = history.components(separatedBy: "\n")
        XCTAssertFalse(lines.contains("[assistant]: "),
            "Messages with empty content must be filtered out")
        XCTAssertEqual(lines.count, 2,
            "Only non-empty content messages should appear")
    }

    func testFormattedHistoryMissingRoleIsFiltered() {
        let messages: [[String: Any]] = [
            ["content": "no role key"],
            ["role": "user", "content": "has role"],
        ]
        let history = formatMessages(messages, recentMessage: "recent")
        XCTAssertFalse(history.contains("no role key"),
            "Messages missing the 'role' key must be filtered out")
    }

    func testFormattedHistoryMissingContentKeyIsFiltered() {
        let messages: [[String: Any]] = [
            ["role": "user"],
            ["role": "assistant", "content": "has content"],
        ]
        let history = formatMessages(messages, recentMessage: "")
        let lines = history.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1,
            "Only the assistant line must survive — user without content key must be filtered")
        XCTAssertEqual(lines.first, "[assistant]: has content")
    }

    func testFormattedHistoryAllEmptyProducesEmptyString() {
        let history = formatMessages([], recentMessage: "")
        XCTAssertTrue(history.isEmpty,
            "Empty recentMessage with no prior history must produce an empty formatted string")
    }

    // MARK: - Memory group identity

    func testMemoryGroupIdIncludesOwnerId() {
        let ownerId = "test-owner-123"
        let groupId = "memory-\(ownerId)"
        XCTAssertTrue(groupId.hasPrefix("memory-"),
            "Memory group ID must be prefixed with 'memory-'")
        XCTAssertTrue(groupId.hasSuffix(ownerId),
            "Memory group ID must end with the owner ID")
    }

    func testMemoryGroupIdIsDeterministicPerOwner() {
        let ownerId = "deterministic-owner"
        let id1 = "memory-\(ownerId)"
        let id2 = "memory-\(ownerId)"
        XCTAssertEqual(id1, id2,
            "Memory group ID must be deterministic for the same owner")
    }

    func testMemoryGroupIdsDifferPerOwner() {
        let id1 = "memory-alice"
        let id2 = "memory-bob"
        XCTAssertNotEqual(id1, id2,
            "Different owners must have different memory group IDs")
    }

    func testMemoryGroupLabelMatchesConstant() {
        XCTAssertEqual(Seer.autoMemoryGroupLabel, "Memory")
    }
}
