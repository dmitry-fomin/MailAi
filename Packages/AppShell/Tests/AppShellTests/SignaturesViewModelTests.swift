#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
import Storage
@testable import AppShell

// MARK: - Helpers

private func makeTestStore() throws -> GRDBMetadataStore {
    let url = URL(fileURLWithPath: "/tmp/mailai-sigvm-\(UUID().uuidString).sqlite")
    return try GRDBMetadataStore(url: url)
}

// MARK: - Tests

@MainActor
final class SignaturesViewModelTests: XCTestCase {

    private var store: GRDBMetadataStore!
    private var repo: SignaturesRepository!
    private var viewModel: SignaturesViewModel!

    override func setUp() async throws {
        store = try makeTestStore()
        repo = SignaturesRepository(pool: store.pool)
        viewModel = SignaturesViewModel(repository: repo)
    }

    override func tearDown() async throws {
        viewModel = nil
        repo = nil
        store = nil
    }

    // MARK: - load

    func testLoadInitiallyEmpty() async {
        await viewModel.load()
        XCTAssertTrue(viewModel.signatures.isEmpty)
        XCTAssertNil(viewModel.selectedID)
    }

    func testLoadFetchesExistingRecords() async throws {
        try await repo.upsert(Signature(id: .init("lf-1"), name: "Работа", body: "С уважением"))
        try await repo.upsert(Signature(id: .init("lf-2"), name: "Дом", body: "Привет"))

        await viewModel.load()

        XCTAssertEqual(viewModel.signatures.count, 2)
    }

    // MARK: - add

    func testAddCreatesNewSignature() async {
        await viewModel.add()

        XCTAssertEqual(viewModel.signatures.count, 1)
        XCTAssertEqual(viewModel.signatures[0].name, "Без названия")
        XCTAssertEqual(viewModel.signatures[0].body, "")
    }

    func testAddSelectsNewSignature() async {
        await viewModel.add()

        XCTAssertNotNil(viewModel.selectedID)
        XCTAssertEqual(viewModel.selectedID, viewModel.signatures.first?.id)
    }

    func testAddMultipleTimes() async {
        await viewModel.add()
        await viewModel.add()
        await viewModel.add()

        XCTAssertEqual(viewModel.signatures.count, 3)
    }

    // MARK: - delete

    func testDeleteRemovesSignature() async {
        await viewModel.add()
        let id = viewModel.signatures[0].id

        await viewModel.delete(id)

        XCTAssertTrue(viewModel.signatures.isEmpty)
    }

    func testDeleteSelectedClearsSelection() async {
        await viewModel.add()
        let id = viewModel.signatures[0].id
        viewModel.selectedID = id

        await viewModel.delete(id)

        XCTAssertNil(viewModel.selectedID)
    }

    func testDeleteNonSelectedKeepsSelection() async {
        await viewModel.add()
        await viewModel.add()

        let first = viewModel.signatures[0].id
        let second = viewModel.signatures[1].id
        viewModel.selectedID = second

        await viewModel.delete(first)

        XCTAssertEqual(viewModel.selectedID, second)
        XCTAssertEqual(viewModel.signatures.count, 1)
    }

    // MARK: - save

    func testSaveUpdatesNameAndBody() async {
        await viewModel.add()
        let id = viewModel.signatures[0].id
        viewModel.selectedID = id

        await viewModel.save(name: "Рабочая", body: "С уважением, Дмитрий", isDefault: false)

        XCTAssertEqual(viewModel.signatures[0].name, "Рабочая")
        XCTAssertEqual(viewModel.signatures[0].body, "С уважением, Дмитрий")
    }

    func testSaveWithIsDefaultSetsDefault() async {
        await viewModel.add()
        await viewModel.add()

        let first = viewModel.signatures[0].id
        let second = viewModel.signatures[1].id

        viewModel.selectedID = first
        await viewModel.save(name: "A", body: "a", isDefault: true)

        viewModel.selectedID = second
        await viewModel.save(name: "B", body: "b", isDefault: true)

        let defaults = viewModel.signatures.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults[0].id, second)
    }

    func testSaveWithNoSelectionIsNoOp() async {
        viewModel.selectedID = nil
        await viewModel.save(name: "X", body: "x", isDefault: false)
        XCTAssertTrue(viewModel.signatures.isEmpty)
    }

    // MARK: - selected computed

    func testSelectedReturnsCorrectSignature() async {
        await viewModel.add()
        let sig = viewModel.signatures[0]
        viewModel.selectedID = sig.id

        XCTAssertEqual(viewModel.selected?.id, sig.id)
    }

    func testSelectedNilWhenNoSelection() async {
        await viewModel.add()
        viewModel.selectedID = nil

        XCTAssertNil(viewModel.selected)
    }
}

// MARK: - ComposeViewModel Signature Tests

@MainActor
final class ComposeViewModelSignatureTests: XCTestCase {

    func testInitWithSignatureAppendsToBody() {
        let vm = ComposeViewModel(
            accountEmail: "user@example.com",
            defaultSignatureBody: "С уважением, Дмитрий"
        )
        XCTAssertEqual(vm.body, "\n\nС уважением, Дмитрий")
    }

    func testInitWithNilSignatureBodyIsEmpty() {
        let vm = ComposeViewModel(
            accountEmail: "user@example.com",
            defaultSignatureBody: nil
        )
        XCTAssertEqual(vm.body, "")
    }

    func testInitWithEmptySignatureBodyIsEmpty() {
        let vm = ComposeViewModel(
            accountEmail: "user@example.com",
            defaultSignatureBody: ""
        )
        XCTAssertEqual(vm.body, "")
    }

    func testMakeReplyWithSignature() {
        let message = Message(
            id: .init("m1"),
            accountID: .init("a1"),
            mailboxID: .init("mb1"),
            uid: 1,
            messageID: nil,
            threadID: nil,
            subject: "Привет",
            from: MailAddress(address: "alice@example.com", name: "Alice"),
            to: [MailAddress(address: "bob@example.com")],
            cc: [],
            date: Date(),
            preview: nil,
            size: 0,
            flags: [],
            importance: .unknown
        )

        let vm = ComposeViewModel.makeReply(
            to: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil,
            defaultSignatureBody: "Подпись"
        )

        XCTAssertTrue(vm.body.hasPrefix("\n\nПодпись"), "Body must start with signature")
        XCTAssertTrue(vm.body.contains("— Пересланное сообщение —"), "Body must contain quote")
    }

    func testMakeForwardWithSignature() {
        let message = Message(
            id: .init("m2"),
            accountID: .init("a1"),
            mailboxID: .init("mb1"),
            uid: 2,
            messageID: nil,
            threadID: nil,
            subject: "Тест",
            from: MailAddress(address: "alice@example.com", name: "Alice"),
            to: [],
            cc: [],
            date: Date(),
            preview: nil,
            size: 0,
            flags: [],
            importance: .unknown
        )

        let vm = ComposeViewModel.makeForward(
            of: message,
            accountEmail: "bob@example.com",
            accountDisplayName: nil,
            sendProvider: nil,
            draftSaver: nil,
            defaultSignatureBody: "Подпись"
        )

        XCTAssertTrue(vm.body.hasPrefix("\n\nПодпись"))
        XCTAssertEqual(vm.subject, "Fwd: Тест")
    }
}
#endif
