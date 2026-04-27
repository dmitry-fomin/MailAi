// MIMESmoke — smoke-тест MIME-компоновщика.
// Запуск: swift run MIMESmoke
// Проверяет компиляцию и базовую логику MIMEComposer.

import Foundation
import MailTransport

// MARK: - Вспомогательные функции

/// Проверяет, что сообщение содержит указанный заголовок.
func assertHasHeader(_ message: String, _ header: String) {
    precondition(message.contains(header), "Expected header not found: \(header)")
}

/// Проверяет, что сообщение НЕ содержит указанную строку.
func assertNotContains(_ message: String, _ text: String) {
    precondition(!message.contains(text), "Unexpected text found: \(text)")
}

// MARK: - Тест: ASCII subject

func testASCIISubject() {
    let msg = MIMEComposer.compose(
        from: "alice@example.com",
        recipients: MIMEComposer.Recipients(to: ["bob@example.com"], cc: [], bcc: []),
        subject: "Hello World",
        body: "Test body"
    )

    // Subject должен быть без кодирования
    assertHasHeader(msg, "Subject: Hello World")

    // Обязательные заголовки
    assertHasHeader(msg, "From: alice@example.com")
    assertHasHeader(msg, "To: bob@example.com")
    assertHasHeader(msg, "Message-ID: <")
    assertHasHeader(msg, "Content-Type: text/plain; charset=utf-8")
    assertHasHeader(msg, "Content-Transfer-Encoding: quoted-printable")

    // Date заголовок должен содержать год
    let year = Calendar.current.component(.year, from: Date())
    assertHasHeader(msg, "Date: ")
    assertHasHeader(msg, String(year))

    // Bcc НЕ должен появляться в заголовках
    assertNotContains(msg, "Bcc:")

    // Cc НЕ должен появляться (массив пуст)
    assertNotContains(msg, "Cc:")

    // Тело — простой ASCII, QP passthrough
    precondition(msg.contains("Test body"), "Тело должно содержать 'Test body'")

    print("✅ ASCII subject — все проверки пройдены")
}

// MARK: - Тест: Russian subject (RFC 2047)

func testRussianSubject() {
    let russianSubject = "Привет мир"
    let msg = MIMEComposer.compose(
        from: "alice@example.com",
        recipients: MIMEComposer.Recipients(to: ["bob@example.com"], cc: ["charlie@example.com"], bcc: ["secret@example.com"]),
        subject: russianSubject,
        body: "Тестовое письмо"
    )

    // Subject должен быть RFC 2047 encoded-word
    assertHasHeader(msg, "Subject: =?utf-8?B?")
    assertHasHeader(msg, "?=")

    // Декодируем и проверяем, что subject правильный
    // Формат: =?utf-8?B?<base64>?=
    if let range = msg.range(of: "Subject: "),
       let eol = msg[range.upperBound...].firstIndex(of: "\r") {
        let subjectLine = String(msg[range.upperBound..<eol])
        // Извлекаем base64 между =?utf-8?B? и ?=
        if let b64Start = subjectLine.range(of: "=?utf-8?B?"),
           let b64End = subjectLine.range(of: "?=", range: b64Start.upperBound..<subjectLine.endIndex) {
            let b64 = String(subjectLine[b64Start.upperBound..<b64End.lowerBound])
            if let decoded = Data(base64Encoded: b64),
               let decodedStr = String(data: decoded, encoding: .utf8) {
                precondition(decodedStr == russianSubject,
                    "Декодированный subject '\(decodedStr)' должен быть '\(russianSubject)'")
            } else {
                preconditionFailure("Не удалось декодировать base64 subject")
            }
        }
    }

    // Cc должен присутствовать (массив непуст)
    assertHasHeader(msg, "Cc: charlie@example.com")

    // Bcc не должен быть в заголовках
    assertNotContains(msg, "Bcc:")

    // Тело содержит QP-encoded кириллицу
    assertNotContains(msg, "Тестовое письмо")  // raw UTF-8 не должен быть в QP-выводе
    // Кириллические символы кодируются как =D0=AF и т.д.
    precondition(msg.contains("="), "QP-encoded тело должно содержать =XX последовательности")

    print("✅ Russian subject (RFC 2047) — все проверки пройдены")
}

// MARK: - Тест: Quoted-Printable кодирование

func testQuotedPrintableBasic() {
    // Простой ASCII — passthrough
    let msg1 = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: "Hello"
    )
    precondition(msg1.contains("Hello"), "Простой ASCII должен проходить без изменений в QP")

    // Знак = должен кодироваться как =3D
    let msg2 = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: "key=value"
    )
    precondition(msg2.contains("key=3Dvalue"), "'=' должен кодироваться как '=3D'")

    // Точка в начале строки (должна проходить — не dot-stuffing на этом уровне)
    let msg3 = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: ".hello"
    )
    precondition(msg3.contains(".hello"), "Точка в начале тела должна проходить QP")

    print("✅ QP basic encoding — все проверки пройдены")
}

func testQuotedPrintableNonASCII() {
    // Кириллица: каждый не-ASCII байт → =XX
    let msg = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: "А"
    )
    // 'А' в UTF-8 = D0 90 → =D0=90
    precondition(msg.contains("=D0=90"), "Кириллический 'А' должен быть =D0=90 в QP")

    // Emoji: 🎉 = F0 9F 8E 89 → =F0=9F=8E=89
    let msgEmoji = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: "🎉"
    )
    precondition(msgEmoji.contains("=F0=9F=8E=89"), "Emoji должен быть корректно QP-закодирован")

    print("✅ QP non-ASCII encoding — все проверки пройдены")
}

func testQuotedPrintableLineLength() {
    // Длинная строка — должны быть soft breaks (=\r\n)
    let longBody = String(repeating: "A", count: 200)
    let msg = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: longBody
    )

    // Извлекаем тело (после двойного CRLF)
    let headerEnd = msg.range(of: "\r\n\r\n")!
    let body = String(msg[headerEnd.upperBound...])

    // Проверяем, что никакая строка не длиннее 76 символов
    let lines = body.components(separatedBy: "\r\n")
    for (i, line) in lines.enumerated() {
        // Последняя строка может быть пустой (trailing CRLF)
        if i == lines.count - 1 && line.isEmpty { continue }
        precondition(line.count <= 76,
            "QP строка \(i) длиннее 76 символов: \(line.count) — '\(line.prefix(80))'")
    }

    // Soft break должен присутствовать (200 > 76)
    precondition(body.contains("=\r\n"), "Длинная строка должна содержать soft breaks")

    // Восстановление: убираем soft breaks — должны получить 200 A
    let restored = body
        .replacingOccurrences(of: "=\r\n", with: "")
        .replacingOccurrences(of: "\r\n", with: "")
    precondition(restored == longBody,
        "Восстановленное тело должно совпадать с оригиналом. Получено: \(restored.count) символов")

    print("✅ QP line length — все проверки пройдены")
}

func testQuotedPrintableTrailingSpace() {
    // Пробел перед переносом строки → =20
    let msg = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: "hello \nworld"
    )
    // Пробел перед \n должен быть закодирован как =20
    precondition(msg.contains("=20"), "Пробел перед переносом строки должен быть =20")

    // Таб перед переносом строки → =09
    let msgTab = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "Test",
        body: "hello\t\nworld"
    )
    precondition(msgTab.contains("=09"), "Таб перед переносом строки должен быть =09")

    print("✅ QP trailing space/tab — все проверки пройдены")
}

// MARK: - Тест: Несколько получателей

func testMultipleRecipients() {
    let msg = MIMEComposer.compose(
        from: "alice@example.com",
        recipients: MIMEComposer.Recipients(to: ["bob@example.com", "carol@example.com"], cc: ["dave@example.com", "eve@example.com"], bcc: ["secret@example.com"]),
        subject: "Multi",
        body: "Hi all"
    )

    assertHasHeader(msg, "To: bob@example.com, carol@example.com")
    assertHasHeader(msg, "Cc: dave@example.com, eve@example.com")
    assertNotContains(msg, "Bcc:")
    assertHasHeader(msg, "Subject: Multi")

    print("✅ Multiple recipients — все проверки пройдены")
}

// MARK: - Тест: Структура сообщения

func testMessageStructure() {
    let msg = MIMEComposer.compose(
        from: "alice@example.com",
        recipients: MIMEComposer.Recipients(to: ["bob@example.com"], cc: [], bcc: []),
        subject: "Structure test",
        body: "body text"
    )

    // Заголовки и тело разделены \r\n\r\n
    let parts = msg.components(separatedBy: "\r\n\r\n")
    precondition(parts.count >= 2, "Сообщение должно содержать заголовки и тело, разделённые пустой строкой")

    let headerBlock = parts[0]
    let bodyBlock = parts.dropFirst().joined(separator: "\r\n\r\n")

    // Заголовки — каждый на отдельной строке
    let headers = headerBlock.components(separatedBy: "\r\n")
    precondition(headers.count >= 6, "Должно быть минимум 6 заголовков (Message-ID, Date, From, To, Subject, Content-Type, Content-Transfer-Encoding)")

    // Порядок заголовков
    precondition(headers[0].hasPrefix("Message-ID:"), "Первый заголовок — Message-ID")
    precondition(headers[1].hasPrefix("Date:"), "Второй заголовок — Date")
    precondition(headers[2].hasPrefix("From:"), "Третий заголовок — From")
    precondition(headers[3].hasPrefix("To:"), "Четвёртый заголовок — To")
    precondition(headers[4].hasPrefix("Subject:"), "Пятый заголовок — Subject")

    // Тело присутствует
    precondition(bodyBlock.contains("body text"), "Тело должно содержать 'body text'")

    print("✅ Message structure — все проверки пройдены")
}

// MARK: - Тест: CRLF разделители

func testCRLFSeparators() {
    let msg = MIMEComposer.compose(
        from: "a@b.com",
        recipients: MIMEComposer.Recipients(to: ["c@d.com"], cc: [], bcc: []),
        subject: "CRLF test",
        body: "line1\nline2"
    )

    // Не должно быть голых \n без предшествующего \r
    // Ищем \n не preceded by \r
    precondition(!msg.contains("\r\n\r\n\r\n"), "Не должно быть тройных CRLF")

    // Все переносы строк должны быть CRLF
    // Проверяем, что нет голых \n (без \r перед ним)
    let strippedCR = msg.replacingOccurrences(of: "\r\n", with: "")
    precondition(!strippedCR.contains("\n"), "Не должно быть голых LF без предшествующего CR")
    precondition(!strippedCR.contains("\r"), "Не должно быть голых CR без следующего LF")

    print("✅ CRLF separators — все проверки пройдены")
}

// MARK: - Запуск

func runAllTests() {
    print("🧪 MIME Composer Smoke Tests")
    print(String(repeating: "=", count: 40))

    testASCIISubject()
    testRussianSubject()
    testQuotedPrintableBasic()
    testQuotedPrintableNonASCII()
    testQuotedPrintableLineLength()
    testQuotedPrintableTrailingSpace()
    testMultipleRecipients()
    testMessageStructure()
    testCRLFSeparators()

    print(String(repeating: "=", count: 40))
    print("✅ Все MIME Composer smoke-тесты пройдены!")
}

runAllTests()
