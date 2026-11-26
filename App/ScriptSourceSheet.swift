import SwiftUI
import UIKit

struct ScriptSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let script: LocalScript

    var body: some View {
        NavigationView {
            ScriptSourceTextView(source: script.source)
                .navigationTitle(Text(verbatim: script.name))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

private struct ScriptSourceTextView: UIViewRepresentable {
    let source: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .systemBackground
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.accessibilityLabel = "JavaScript 源码"
        view.attributedText = JavaScriptHighlighting.attributedSource(source)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

enum JavaScriptHighlighting {
    // Match complete comments and strings before looking for keywords or numbers inside the source.
    private static let tokens = try! NSRegularExpression(pattern: #"""
        (?<comment>\A\x23! [^\r\n]* | //[^\r\n]* | /\*(?:[^*]|\*(?!/))*+(?:\*/|\z))
        | (?<string>"(?:\\[\s\S]|[^"\\\r\n])*+"? | '(?:\\[\s\S]|[^'\\\r\n])*+'? | `(?:\\[\s\S]|[^`\\])*+`?)
        | (?<keyword>(?<![\w$])(?:as|async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|from|function|if|import|in|instanceof|let|new|null|of|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|with|yield)(?![\w$]))
        | (?<number>(?<![\w$])(?:0[xX][a-fA-F\d](?:_?[a-fA-F\d])*n?|0[bB][01](?:_?[01])*n?|0[oO][0-7](?:_?[0-7])*n?|\d(?:_?\d)*n|(?:\d(?:_?\d)*(?:\.(?:\d(?:_?\d)*)?)?|\.\d(?:_?\d)*)(?:[eE][+-]?\d(?:_?\d)*)?)(?![\w$]))
        """#, options: .allowCommentsAndWhitespace)

    @MainActor
    static func attributedSource(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.label
        ])
        let colors: [(String, UIColor)] = [
            ("comment", .secondaryLabel),
            ("string", .systemRed),
            ("keyword", .systemPurple),
            ("number", .systemBlue)
        ]
        tokens.enumerateMatches(in: source, range: NSRange(location: 0, length: result.length)) { match, _, _ in
            guard let match else { return }
            for (name, color) in colors {
                let range = match.range(withName: name)
                if range.location != NSNotFound {
                    result.addAttribute(.foregroundColor, value: color, range: range)
                    break
                }
            }
        }
        return result
    }
}
