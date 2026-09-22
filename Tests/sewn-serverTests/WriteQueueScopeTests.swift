//
//  WriteQueueScopeTests.swift
//  sewn-serverTests
//
//  The write queue merges consecutive puts into one batch, indexed as the
//  first put's request. On a shared stack that request's caller app picks
//  the Thread, so two puts for different apps must never share a batch —
//  even when owner and group agree.
//

import RaoStack
import XCTest
@testable import sewn_server

final class WriteQueueScopeTests: XCTestCase {

    private func request(owner: String = "owner", group: String? = "g1", app: RaoApp?) -> SewnRequest {
        SewnRequest(ownerId: owner, group: group.map { Sewn.Group.test(id: $0, ownerId: owner) },
                    aggregate: nil, scope: .personal, requestID: nil, callerApp: app)
    }

    func testPutsForTheSameOwnerGroupAndAppCoalesce() {
        XCTAssertTrue(Sewn.canCoalesce(request(app: .ambient), into: request(app: .ambient)))
        XCTAssertTrue(Sewn.canCoalesce(request(app: nil), into: request(app: nil)),
                      "an open or one-app Sewn has no app and coalesces as before")
        XCTAssertTrue(Sewn.canCoalesce(request(group: nil, app: nil), into: request(group: nil, app: nil)))
    }

    func testPutsDifferingOnlyByCallerAppDoNotCoalesce() {
        XCTAssertFalse(Sewn.canCoalesce(request(app: .craft), into: request(app: .ambient)))
        XCTAssertFalse(Sewn.canCoalesce(request(app: nil), into: request(app: .ambient)),
                       "a put that lost its app rides no other app's batch")
        XCTAssertFalse(Sewn.canCoalesce(request(app: .ambient), into: request(app: nil)))
    }

    func testOwnerAndGroupStillGate() {
        XCTAssertFalse(Sewn.canCoalesce(request(owner: "other", app: .ambient), into: request(app: .ambient)))
        XCTAssertFalse(Sewn.canCoalesce(request(group: "g2", app: .ambient), into: request(app: .ambient)))
        XCTAssertFalse(Sewn.canCoalesce(request(group: nil, app: .ambient), into: request(app: .ambient)))
    }
}
