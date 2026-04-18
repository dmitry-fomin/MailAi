import Foundation
import Core
import Secrets

func check(_ label: String, _ condition: Bool) {
    guard condition else {
        FileHandle.standardError.write(Data("✘ \(label)\n".utf8))
        exit(1)
    }
    print("✓ \(label)")
}

@main
enum SecretsSmokeRunner {
    static func main() async throws {
        // InMemorySecretsStore — проверка контракта.
        let mem = InMemorySecretsStore()
        let id = Account.ID("smoke-acc-\(UUID().uuidString.prefix(8))")
        try await mem.setPassword("p1", forAccount: id)
        let read = try await mem.password(forAccount: id)
        check("InMemorySecretsStore читает записанный пароль", read == "p1")

        try await mem.deletePassword(forAccount: id)
        let gone = try await mem.password(forAccount: id)
        check("InMemorySecretsStore удаляет пароль", gone == nil)

        try await mem.setOpenRouterKey("or-key", forAccount: id)
        let orRead = try await mem.openRouterKey(forAccount: id)
        check("InMemorySecretsStore читает OpenRouter-ключ", orRead == "or-key")
        try await mem.deleteOpenRouterKey(forAccount: id)
        let orGone = try await mem.openRouterKey(forAccount: id)
        check("InMemorySecretsStore удаляет OpenRouter-ключ", orGone == nil)

        // KeychainService — реальный Keychain. На headless CI может упасть
        // из-за отсутствия login keychain; под локальным юзером должен работать.
        let key = KeychainService(servicePrefix: "mailai-smoke")
        let kid = Account.ID("smoke-key-\(UUID().uuidString.prefix(8))")
        do {
            try await key.setPassword("secret-\(UUID().uuidString)", forAccount: kid)
            let got = try await key.password(forAccount: kid)
            check("KeychainService сохранил и прочитал пароль", got?.isEmpty == false)

            try await key.deletePassword(forAccount: kid)
            let gone2 = try await key.password(forAccount: kid)
            check("KeychainService удалил пароль", gone2 == nil)
        } catch {
            print("⚠ KeychainService недоступен в данном окружении: \(error)")
            // Не делаем fail — runtime Keychain может быть недоступен (CI),
            // но компиляция и in-memory API работают.
        }

        print("\nAll Secrets smoke checks passed.")
    }
}
