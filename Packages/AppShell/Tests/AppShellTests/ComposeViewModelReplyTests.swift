#if canImport(XCTest)
import XCTest
@testable import AppShell
import Core

@MainActor
final class ComposeViewModelReplyTests: XCTestCase {

    // MARK: - Fixture

    private func makeMessage(
        subject: String = "Привет",
        from: String = "alice@example.com",
        to: [String] = ["bob@example.com"],
        cc: [String] = ["carol@example.com"],
        preview: String? = "Текст письма"
    ) -> Message {
        Message(
            id: .init("msg-1"),
            accountID: .init("acc-1"),
            mailboxID: .init("mbox-1"),
            uid: 1,
            messageID: "<msg1@example.com>",
            threadID: nil,
            subject: subject,
            from: MailAddress(address: from, name: "Alice"),
            to: to.map { MailAddress(address: $0) },
            cc: cc.map { MailAddress(address: $0) },
            date: Date(timeIntervalSince1970: 0), // 1 Jan 1970
            preview: preview,
            size: 100,
            flags: [],
            importance: .unknown
        )
    }

    // MARK: - makeReply

    func testMakeReply_toField() {
        let message = makeMessage(from: "alice@example.com")
        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: "Bob",
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertEqual(vm.to, "alice@example.com")
    }

    func testMakeReply_subjectPrefix() {
        let message = makeMessage(subject: "Привет")
        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.subject.hasPrefix("Re:"), "Тема должна начинаться с 'Re:'")
        XCTAssertTrue(vm.subject.contains("Привет"))
    }

    func testMakeReply_subjectNoDuplicatePrefix() {
        let message = makeMessage(subject: "Re: Привет")
        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertEqual(vm.subject, "Re: Привет", "Не должно быть двойного 'Re:'")
    }

    func testMakeReply_bodyContainsFromAndSubject() {
        let message = makeMessage(subject: "Привет", from: "alice@example.com")
        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.body.contains("alice@example.com"), "Тело должно содержать адрес отправителя")
        XCTAssertTrue(vm.body.contains("Привет"), "Тело должно содержать тему")
    }

    func testMakeReply_bodyContainsPreview() {
        let message = makeMessage(preview: "Текст письма")
        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.body.contains("Текст письма"), "Тело должно содержать preview")
    }

    func testMakeReply_ccIsEmpty() {
        let message = makeMessage()
        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.cc.isEmpty, "Reply не должен заполнять Cc")
    }

    // MARK: - makeReplyAll

    func testMakeReplyAll_toIsOriginalSender() {
        let message = makeMessage(from: "alice@example.com")
        let vm = ComposeViewModel.makeReplyAll(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertEqual(vm.to, "alice@example.com")
    }

    func testMakeReplyAll_ccExcludesAccountEmail() {
        let message = makeMessage(
            from: "alice@example.com",
            to: ["bob@example.com", "dave@example.com"],
            cc: ["carol@example.com"]
        )
        let vm = ComposeViewModel.makeReplyAll(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertFalse(vm.cc.contains("bob@example.com"), "Cc не должен содержать email аккаунта")
        XCTAssertTrue(vm.cc.contains("dave@example.com"))
        XCTAssertTrue(vm.cc.contains("carol@example.com"))
    }

    func testMakeReplyAll_ccExcludesAccountEmail_caseInsensitive() {
        let message = makeMessage(
            from: "alice@example.com",
            to: ["BOB@EXAMPLE.COM"],
            cc: []
        )
        let vm = ComposeViewModel.makeReplyAll(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertFalse(vm.cc.lowercased().contains("bob@example.com"),
                       "Фильтрация должна быть регистронезависимой")
    }

    func testMakeReplyAll_subjectPrefix() {
        let message = makeMessage(subject: "Встреча")
        let vm = ComposeViewModel.makeReplyAll(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.subject.hasPrefix("Re:"))
    }

    // MARK: - makeForward

    func testMakeForward_toIsEmpty() {
        let message = makeMessage()
        let vm = ComposeViewModel.makeForward(
            of: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.to.isEmpty, "Forward: поле To должно быть пустым")
    }

    func testMakeForward_ccIsEmpty() {
        let message = makeMessage()
        let vm = ComposeViewModel.makeForward(
            of: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.cc.isEmpty, "Forward: поле Cc должно быть пустым")
    }

    func testMakeForward_subjectPrefix() {
        let message = makeMessage(subject: "Отчёт")
        let vm = ComposeViewModel.makeForward(
            of: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.subject.hasPrefix("Fwd:"), "Тема должна начинаться с 'Fwd:'")
        XCTAssertTrue(vm.subject.contains("Отчёт"))
    }

    func testMakeForward_subjectNoDuplicatePrefix() {
        let message = makeMessage(subject: "Fwd: Отчёт")
        let vm = ComposeViewModel.makeForward(
            of: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertEqual(vm.subject, "Fwd: Отчёт", "Не должно быть двойного 'Fwd:'")
    }

    func testMakeForward_bodyContainsOriginalInfo() {
        let message = makeMessage(subject: "Отчёт", from: "alice@example.com", preview: "Подробности")
        let vm = ComposeViewModel.makeForward(
            of: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil
        )
        XCTAssertTrue(vm.body.contains("alice@example.com"))
        XCTAssertTrue(vm.body.contains("Отчёт"))
        XCTAssertTrue(vm.body.contains("Подробности"))
    }
}
#endif
