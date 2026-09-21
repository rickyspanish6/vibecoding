import AppKit

/// The Read Me window: the bundled README.md, rendered.
///
/// The markdown is walked line by line rather than handed to `AttributedString(markdown:)`
/// because the README leans on fenced blocks of ASCII art, and controlling the block
/// styling directly is what keeps those boxes aligned.
enum ReadMeWindow {
    private static var window: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 26, height: 24)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textStorage?.setAttributedString(render(source()))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 660, height: 720))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.documentView = text
        text.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 0)

        let w = NSWindow(contentRect: scroll.frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "SearchParty Watchdog Read Me"
        w.contentView = scroll
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    private static func source() -> String {
        guard let url = Bundle.main.url(forResource: "README", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Read Me\n\nThe Read Me is missing from this build."
        }
        return text
    }

    // MARK: Rendering

    private static let body = NSFont.systemFont(ofSize: 13)
    private static let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    private static let codeParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 10
        style.paragraphSpacing = 14
        style.lineSpacing = 1
        style.headIndent = 14
        style.firstLineHeadIndent = 14
        return style
    }()

    private static func paragraph(spacingBefore: CGFloat, spacingAfter: CGFloat,
                                  indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 2
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    private static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var codeBuffer: [String] = []
        var inCodeBlock = false
        // Markdown hard-wraps prose across several source lines; they have to be joined
        // back into one paragraph before styling, or the text cannot reflow with the
        // window and inline spans that straddle a line break never match.
        var pending: [String] = []
        var pendingIsBullet = false

        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            // Joined with U+2028 line separators, not newlines: a newline would end the
            // paragraph, so the block's paragraph spacing would open up between every
            // single row and pull the ASCII art apart.
            out.append(NSAttributedString(
                string: codeBuffer.joined(separator: "\u{2028}") + "\n",
                attributes: [.font: mono,
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .backgroundColor: NSColor.textColor.withAlphaComponent(0.05),
                             .paragraphStyle: codeParagraph]))
            codeBuffer = []
        }

        func flushParagraph() {
            guard !pending.isEmpty else { return }
            let text = inline(pending.joined(separator: " "))
            if pendingIsBullet { text.insert(NSAttributedString(string: "•  "), at: 0) }
            text.append(NSAttributedString(string: "\n"))
            text.addAttribute(.paragraphStyle,
                              value: paragraph(spacingBefore: 0,
                                               spacingAfter: pendingIsBullet ? 4 : 11,
                                               indent: pendingIsBullet ? 18 : 0),
                              range: NSRange(location: 0, length: text.length))
            out.append(text)
            pending = []
            pendingIsBullet = false
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                flushParagraph()
                inCodeBlock.toggle()
                if !inCodeBlock { flushCode() }
                continue
            }
            if inCodeBlock {
                codeBuffer.append(line)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else if line.hasPrefix("### ") {
                flushParagraph()
                out.append(heading(String(line.dropFirst(4)), size: 13, before: 16))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                out.append(heading(String(line.dropFirst(3)), size: 16, before: 22))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                out.append(heading(String(line.dropFirst(2)), size: 22, before: 0))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                pendingIsBullet = true
                pending.append(String(line.dropFirst(2)))
            } else {
                // A continuation of whatever block is open.
                pending.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        flushParagraph()
        flushCode()
        return out
    }

    private static func heading(_ text: String, size: CGFloat, before: CGFloat)
        -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph(spacingBefore: before, spacingAfter: 8),
        ])
    }

    /// Handles the two inline spans the README actually uses: `code` and **bold**.
    private static func inline(_ line: String) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(
            string: line, attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        for (pattern, attributes) in [
            ("`([^`]+)`", [NSAttributedString.Key.font: mono,
                           .foregroundColor: NSColor.systemPink]),
            ("\\*\\*([^*]+)\\*\\*", [NSAttributedString.Key.font:
                                        NSFont.systemFont(ofSize: 13, weight: .semibold)]),
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            // Back to front, so replacing a match cannot shift the ones not yet handled.
            for match in regex.matches(in: result.string,
                                       range: NSRange(location: 0, length: result.length)).reversed() {
                let inner = result.attributedSubstring(from: match.range(at: 1))
                let styled = NSMutableAttributedString(attributedString: inner)
                styled.addAttributes(attributes, range: NSRange(location: 0, length: styled.length))
                result.replaceCharacters(in: match.range, with: styled)
            }
        }
        return result
    }
}
