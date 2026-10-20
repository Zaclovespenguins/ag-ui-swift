// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

final class ResumeValidatorTests: XCTestCase {

    private let past = "2000-01-01T00:00:00Z"
    private let future = "2999-01-01T00:00:00Z"

    func testAcceptsEntriesThatAnswerEveryPendingInterrupt() throws {
        let pending = [Interrupt(id: "a", reason: .toolCall), Interrupt(id: "b", reason: .confirmation)]
        XCTAssertNoThrow(try ResumeValidator.validate(
            entries: [.resolved(interruptId: "b"), .cancelled(interruptId: "a")], pending: pending
        ))
    }

    func testThrowsWhenAnInterruptIsUnanswered() {
        let pending = [Interrupt(id: "a", reason: .toolCall), Interrupt(id: "b", reason: .toolCall)]
        XCTAssertThrowsError(try ResumeValidator.validate(
            entries: [.cancelled(interruptId: "a")], pending: pending
        )) {
            XCTAssertEqual($0 as? InterruptError, .unansweredInterrupts(ids: ["b"]))
        }
    }

    func testThrowsOnUnknownIdsOnceAndInOrder() {
        let pending = [Interrupt(id: "a", reason: .toolCall)]
        XCTAssertThrowsError(try ResumeValidator.validate(
            entries: [.cancelled(interruptId: "a"), .cancelled(interruptId: "z"),
                      .cancelled(interruptId: "y"), .cancelled(interruptId: "z")],
            pending: pending
        )) {
            XCTAssertEqual($0 as? InterruptError, .unknownInterrupts(ids: ["z", "y"]))
        }
    }

    func testNoPendingInterruptsRejectsAnyEntry() {
        XCTAssertThrowsError(try ResumeValidator.validate(
            entries: [.cancelled(interruptId: "a")], pending: []
        )) {
            XCTAssertEqual($0 as? InterruptError, .unknownInterrupts(ids: ["a"]))
        }
    }

    func testExpiredInterruptOnlyAcceptsCancelled() {
        let pending = [Interrupt(id: "a", reason: .toolCall, expiresAt: past)]
        XCTAssertThrowsError(try ResumeValidator.validate(
            entries: [.resolved(interruptId: "a")], pending: pending
        )) {
            XCTAssertEqual($0 as? InterruptError, .expired(id: "a"))
        }
        XCTAssertNoThrow(try ResumeValidator.validate(
            entries: [.cancelled(interruptId: "a")], pending: pending
        ))
    }

    func testExpiryIsJudgedAgainstInjectedNow() throws {
        let pending = [Interrupt(id: "a", reason: .toolCall, expiresAt: "2030-01-01T00:00:00Z")]
        let before = try XCTUnwrap(InterruptExpiry.parse("2029-12-31T23:59:59Z"))
        let after = try XCTUnwrap(InterruptExpiry.parse("2030-01-01T00:00:00Z"))
        XCTAssertNoThrow(try ResumeValidator.validate(
            entries: [.resolved(interruptId: "a")], pending: pending, now: before
        ))
        XCTAssertThrowsError(try ResumeValidator.validate(
            entries: [.resolved(interruptId: "a")], pending: pending, now: after
        ))
    }

    func testExpiryParsesFractionalSecondsAndIgnoresFutureAbsentAndUnparseable() {
        XCTAssertTrue(InterruptExpiry.isExpired(Interrupt(id: "a", reason: .toolCall, expiresAt: "2000-01-01T00:00:00.123Z")))
        XCTAssertFalse(InterruptExpiry.isExpired(Interrupt(id: "b", reason: .toolCall, expiresAt: future)))
        XCTAssertFalse(InterruptExpiry.isExpired(Interrupt(id: "c", reason: .toolCall)))
        XCTAssertFalse(InterruptExpiry.isExpired(Interrupt(id: "d", reason: .toolCall, expiresAt: "soon")))
    }

    func testInterruptErrorDescriptions() {
        XCTAssertEqual(
            InterruptError.unansweredInterrupts(ids: ["a", "b"]).errorDescription,
            "Thread has 2 pending interrupt(s) not addressed by resume: a, b"
        )
        XCTAssertNotNil(InterruptError.unknownInterrupts(ids: ["x"]).errorDescription)
        XCTAssertNotNil(InterruptError.expired(id: "x").errorDescription)
    }
}
