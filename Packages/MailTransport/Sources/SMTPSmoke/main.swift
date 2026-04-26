// SMTPSmoke — smoke-тест SMTP-клиента.
// Запуск: swift run SMTPSmoke
// Проверяет компиляцию и базовую логику парсинга ответов.
// Реальное подключение к SMTP-серверу НЕ выполняется.

import Foundation
import MailTransport

// MARK: - Тесты парсинга SMTPResponse

func testSMTPResponseParsing() {
    // Обычный ответ
    let ok = SMTPResponse.parse("250 OK")
    precondition(ok != nil, "Должен парсить '250 OK'")
    precondition(ok!.code == 250, "Код должен быть 250")
    precondition(ok!.text == "OK", "Текст должен быть 'OK'")
    precondition(!ok!.isContinuation, "Не continuation")

    // Многострочный ответ (continuation)
    let cont = SMTPResponse.parse("250-SIZE 35882577")
    precondition(cont != nil, "Должен парсить '250-SIZE 35882577'")
    precondition(cont!.code == 250, "Код должен быть 250")
    precondition(cont!.isContinuation, "Должен быть continuation")

    // Greeting
    let greeting = SMTPResponse.parse("220 smtp.gmail.com ESMTP")
    precondition(greeting != nil, "Должен парсить greeting")
    precondition(greeting!.code == 220, "Код greeting должен быть 220")

    // Ошибка аутентификации
    let authErr = SMTPResponse.parse("535 5.7.8 Username and Password not accepted")
    precondition(authErr != nil, "Должен парсить ошибку аутентификации")
    precondition(authErr!.code == 535, "Код ошибки auth должен быть 535")

    // DATA ready
    let dataReady = SMTPResponse.parse("354 End data with <CR><LF>.<CR><LF>")
    precondition(dataReady != nil, "Должен парсить 354")
    precondition(dataReady!.code == 354, "Код DATA должен быть 354")

    // Auth challenge
    let challenge = SMTPResponse.parse("334 VXNlcm5hbWU6")
    precondition(challenge != nil, "Должен парсить 334 challenge")
    precondition(challenge!.code == 334, "Код challenge должен быть 334")

    // Невалидная строка
    let invalid = SMTPResponse.parse("hello world")
    precondition(invalid == nil, "Невалидная строка должна давать nil")

    // Короткая строка
    let short = SMTPResponse.parse("22")
    precondition(short == nil, "Короткая строка должна давать nil")

    print("✅ SMTPResponse.parse — все проверки пройдены")
}

// MARK: - Тесты SMTPEndpoint

func testSMTPEndpointPresets() {
    let gmail = SMTPEndpoint.gmail()
    precondition(gmail.host == "smtp.gmail.com", "Gmail host")
    precondition(gmail.port == 587, "Gmail port")
    precondition(gmail.security == .startTLS, "Gmail security")

    let gmailTLS = SMTPEndpoint.gmailTLS()
    precondition(gmailTLS.port == 465, "Gmail TLS port")
    precondition(gmailTLS.security == .tls, "Gmail TLS security")

    let yandex = SMTPEndpoint.yandex()
    precondition(yandex.host == "smtp.yandex.com", "Yandex host")
    precondition(yandex.security == .startTLS, "Yandex security")

    print("✅ SMTPEndpoint presets — все проверки пройдены")
}

// MARK: - Тесты SMTPError

func testSMTPErrorEquality() {
    let e1 = SMTPError.connection("timeout")
    let e2 = SMTPError.connection("timeout")
    let e3 = SMTPError.connection("refused")
    let e4 = SMTPError.authentication("bad creds")

    precondition(e1 == e2, "Одинаковые ошибки должны быть равны")
    precondition(e1 != e3, "Разные тексты — разные ошибки")
    precondition(e1 != e4, "Разные категории — разные ошибки")

    // LocalizedError
    precondition(e1.errorDescription != nil, "Должно быть описание ошибки")

    print("✅ SMTPError equality — все проверки пройдены")
}

// MARK: - Тесты SMTPCredentials

func testSMTPCredentials() {
    let c1 = SMTPCredentials(username: "user@example.com", password: "pass")
    let c2 = SMTPCredentials(username: "user@example.com", password: "pass")
    let c3 = SMTPCredentials(username: "other@example.com", password: "pass")

    precondition(c1 == c2, "Одинаковые credentials")
    precondition(c1 != c3, "Разные credentials")
    precondition(c1.username == "user@example.com", "Username")

    print("✅ SMTPCredentials — все проверки пройдены")
}

// MARK: - Тесты category

func testSMTPResponseCategory() {
    precondition(SMTPResponse.parse("220 ready")!.category == .positiveCompletion)
    precondition(SMTPResponse.parse("250 OK")!.category == .positiveCompletion)
    precondition(SMTPResponse.parse("354 go ahead")!.category == .positiveIntermediate)
    precondition(SMTPResponse.parse("421 try later")!.category == .transientNegative)
    precondition(SMTPResponse.parse("550 rejected")!.category == .permanentNegative)

    // isSuccess
    precondition(SMTPResponse.parse("250 OK")!.isSuccess)
    precondition(SMTPResponse.parse("354 go")!.isSuccess)
    precondition(!SMTPResponse.parse("421 no")!.isSuccess)
    precondition(!SMTPResponse.parse("550 no")!.isSuccess)

    print("✅ SMTPResponse category — все проверки пройдены")
}

// MARK: - Запуск

func runAllTests() {
    print("🧪 SMTP Smoke Tests")
    print(String(repeating: "=", count: 40))

    testSMTPResponseParsing()
    testSMTPEndpointPresets()
    testSMTPErrorEquality()
    testSMTPCredentials()
    testSMTPResponseCategory()

    print(String(repeating: "=", count: 40))
    print("✅ Все SMTP smoke-тесты пройдены!")
}

runAllTests()
