import SwiftUI

/// Renders the model's Markdown: headings, lists, quotes, code blocks, tables and rules, with the
/// inline syntax (bold, italics, code, links) left to `AttributedString`.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Markdown.blocks(in: text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: Markdown.Block

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(Self.font(forHeading: level))
                .padding(.top, level <= 2 ? 4 : 0)

        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: item.marker)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(Markdown.inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(Markdown.inline(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let code):
            CodeBlockView(language: language, code: code)

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(Markdown.inline(cell)).bold()
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(0..<header.count, id: \.self) { column in
                                Text(Markdown.inline(column < row.count ? row[column] : ""))
                            }
                        }
                    }
                }
                .font(.subheadline)
                .padding(12)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .rule:
            Divider()
        }
    }

    private static func font(forHeading level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language.isEmpty ? "code" : language)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum Markdown {
    struct ListItem: Hashable {
        var marker: String
        var text: String
        var level: Int
    }

    enum Block: Hashable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case list([ListItem])
        case quote(String)
        case code(language: String, code: String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func blocks(in text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
            } else if let fence = fence(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
            } else if let heading = heading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
            } else if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
            } else if index + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[index + 1]) {
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !current.isEmpty, current.contains("|") else { break }
                    rows.append(cells(current))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else if listItem(line) != nil {
                var items: [ListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index]) {
                        items.append(item)
                    } else {
                        let current = lines[index].trimmingCharacters(in: .whitespaces)
                        // A line that goes on with the item above.
                        guard !current.isEmpty, !items.isEmpty, startsBlock(current) == false,
                              lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t")
                        else { break }
                        items[items.count - 1].text += "\n" + current
                    }
                    index += 1
                }
                blocks.append(.list(items))
            } else {
                var paragraph: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if current.isEmpty || (!paragraph.isEmpty && (startsBlock(current) || listItem(lines[index]) != nil)) {
                        break
                    }
                    paragraph.append(current)
                    index += 1
                }
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }

    private static func fence(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.contains("|") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") { line.removeLast() }
        return line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }

        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            var text = String(rest.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") {
                marker = "☐"
                text.removeFirst(4)
            } else if text.lowercased().hasPrefix("[x] ") {
                marker = "☑︎"
                text.removeFirst(4)
            }
            return ListItem(marker: marker, text: text, level: indent / 2)
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " "
        else { return nil }
        return ListItem(marker: "\(digits).", text: String(afterDigits.dropFirst(2)), level: indent / 2)
    }

    private static func startsBlock(_ trimmed: String) -> Bool {
        fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">")
    }
}
