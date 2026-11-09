import SwiftUI

struct GuideView: View {
    let guide: GuideID
    @State private var content: GuideContent?
    @State private var isLoading = true

    private var definition: GuideDefinition { GuideDefinition(id: guide) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(definition.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let content {
                    GuideMarkdownView(text: content.text)
                    GuideSourceFooter(content: content)
                } else if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("가이드를 불러오는 중…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(definition.title)
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ExternalLinkOpener.openTrusted(
                        LumaURLs.guideHTML(language: GuideCatalog.languageCode, id: guide.rawValue)
                    )
                } label: {
                    Label("GitHub에서 보기", systemImage: "safari")
                }
            }
        }
        .task(id: guide) {
            isLoading = true
            content = await GuideStore.shared.content(for: guide, language: GuideCatalog.languageCode)
            isLoading = false
        }
    }
}

private struct GuideSourceFooter: View {
    let content: GuideContent

    private var label: String {
        switch content.source {
        case .remote: return "GitHub 최신 가이드"
        case .cache: return "저장된 가이드"
        case .fallback: return "내장 도움말"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.top, 8)
            HStack(spacing: 6) {
                Image(systemName: content.source == .remote ? "checkmark.icloud" : "internaldrive")
                Text(label)
                if let fetchedAt = content.fetchedAt {
                    Text("·")
                    Text(fetchedAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            Text("문서 내용은 Luma Music GitHub 저장소에서 관리됩니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct GuideMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = GuideBlock.parse(text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: GuideBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                .padding(.top, level == 1 ? 0 : 4)
        case .paragraph(let text):
            Text(inline(text))
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        Text(inline(item)).font(.body).lineSpacing(2).textSelection(.enabled)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(LumaColors.accent.opacity(0.65)).frame(width: 3)
                Text(inline(text)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.vertical, 4)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .image(let alt, let url):
            if LumaURLs.isTrustedGitHubURL(url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    case .failure:
                        Text(alt).font(.caption).foregroundStyle(.secondary)
                    default:
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
            } else if !alt.isEmpty {
                Text(alt).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        // Remote Markdown links are not navigable from the document body. The trusted
        // GitHub action in the toolbar is the only external destination.
        let linkedRanges = attributed.runs.compactMap { $0.link == nil ? nil : $0.range }
        for range in linkedRanges { attributed[range].link = nil }
        return attributed
    }
}

private enum GuideBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case quote(String)
    case code(String)
    case image(alt: String, url: URL)

    static func parse(_ text: String) -> [GuideBlock] {
        var blocks: [GuideBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph(); flushBullets()
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph(); flushBullets()
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph(); flushBullets()
                let level = min(3, line.prefix(while: { $0 == "#" }).count)
                blocks.append(.heading(level: level, text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph(); flushBullets()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }
            if let image = imageBlock(line) {
                flushParagraph(); flushBullets()
                blocks.append(image)
                continue
            }
            flushBullets()
            paragraph.append(line)
        }
        flushParagraph(); flushBullets()
        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func imageBlock(_ line: String) -> GuideBlock? {
        guard line.hasPrefix("!["), let close = line.firstIndex(of: "]"),
              line.index(after: close) < line.endIndex, line[line.index(after: close)] == "(",
              line.hasSuffix(")") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
        let urlStart = line.index(close, offsetBy: 2)
        let urlText = String(line[urlStart..<line.index(before: line.endIndex)])
        guard let url = URL(string: urlText) else { return nil }
        return .image(alt: alt, url: url)
    }
}
