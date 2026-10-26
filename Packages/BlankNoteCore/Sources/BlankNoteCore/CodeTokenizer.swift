import Foundation

/// Light syntax colouring for fenced code blocks: keywords, strings, numbers and comments.
/// It works line by line and is deliberately forgiving rather than exact for any one language.
enum CodeTokenizer {
    static func tokens(in line: String, offset: Int, language: String) -> [StyledRange] {
        let chars = Array(line.utf16)
        var spans: [StyledRange] = []
        let hashComments = hashCommentLanguages.contains(language)
        let slashComments = !noSlashCommentLanguages.contains(language)
        let dashComments = language == "sql" || language == "lua" || language == "haskell"
        let keywords = keywordsByLanguage[language] ?? commonKeywords
        var i = 0

        func add(_ start: Int, _ end: Int, _ style: MarkdownStyle) {
            spans.append(.init(NSRange(location: offset + start, length: end - start), style))
        }
        func at(_ index: Int) -> UInt16? { index < chars.count ? chars[index] : nil }

        while i < chars.count {
            let c = chars[i]
            // Comments run to the end of the line.
            if (slashComments && c == slash && at(i + 1) == slash) || (hashComments && c == hash)
                || (dashComments && c == dash && at(i + 1) == dash) {
                add(i, chars.count, .codeComment)
                break
            }
            if slashComments, c == slash, at(i + 1) == star {
                var end = i + 2
                while end < chars.count, !(chars[end] == star && at(end + 1) == slash) { end += 1 }
                end = min(end + 2, chars.count)
                add(i, end, .codeComment)
                i = end
                continue
            }
            if c == doubleQuote || c == singleQuote || c == backtick {
                var end = i + 1
                while end < chars.count, chars[end] != c {
                    end += chars[end] == backslash ? 2 : 1
                }
                end = min(end + 1, chars.count)
                add(i, end, .codeString)
                i = end
                continue
            }
            if isDigit(c), i == 0 || !isWordCharacter(chars[i - 1]) {
                var end = i + 1
                while end < chars.count, isWordCharacter(chars[end]) || chars[end] == dot { end += 1 }
                add(i, end, .codeNumber)
                i = end
                continue
            }
            if isWordCharacter(c) {
                var end = i + 1
                while end < chars.count, isWordCharacter(chars[end]) { end += 1 }
                if i == 0 || chars[i - 1] != dot, keywords.contains(String(decoding: chars[i..<end], as: UTF16.self)) {
                    add(i, end, .codeKeyword)
                }
                i = end
                continue
            }
            i += 1
        }
        return spans
    }

    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let star = UInt16(UInt8(ascii: "*"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let dash = UInt16(UInt8(ascii: "-"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let doubleQuote = UInt16(UInt8(ascii: "\""))
    private static let singleQuote = UInt16(UInt8(ascii: "'"))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    private static func isWordCharacter(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
    }

    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "ruby", "rb", "sh", "bash", "zsh", "shell", "console", "yaml", "yml", "toml",
        "perl", "r", "elixir", "ex", "make", "makefile", "dockerfile", "nix", "powershell", "ps1", "conf", "ini",
    ]
    private static let noSlashCommentLanguages: Set<String> = hashCommentLanguages.union(["sql", "lua", "haskell", "html", "xml", "css", "json", "markdown", "md"])

    private static let commonKeywords = Set<String>([
        "func", "function", "fn", "def", "class", "struct", "enum", "protocol", "interface", "trait", "impl", "extension",
        "let", "var", "const", "val", "mut", "static", "final", "public", "private", "internal", "protected", "export",
        "import", "from", "package", "use", "module", "return", "if", "else", "elif", "guard", "switch", "case", "match",
        "default", "for", "while", "repeat", "do", "in", "of", "break", "continue", "try", "catch", "throw", "throws",
        "finally", "async", "await", "yield", "new", "self", "this", "super", "nil", "null", "None", "true", "false",
        "True", "False", "and", "or", "not", "is", "as", "where", "type", "typealias", "lambda", "with", "pass",
        "go", "defer", "chan", "select", "void", "int", "bool", "string", "override", "init", "deinit",
        "some", "any", "inout", "extends", "implements", "abstract", "readonly", "declare", "namespace",
    ])

    private static let keywordsByLanguage: [String: Set<String>] = [
        "sql": [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP",
            "ALTER", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER",
            "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "PRIMARY", "KEY", "DISTINCT", "UNION", "IS", "IN", "LIKE",
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop",
            "join", "left", "on", "and", "or", "not", "null", "as", "order", "by", "group", "limit",
        ],
        "json": ["true", "false", "null"],
        "yaml": ["true", "false", "null", "yes", "no"],
        "yml": ["true", "false", "null", "yes", "no"],
    ]
}
