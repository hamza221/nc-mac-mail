// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Turns what somebody typed into an FTS5 `MATCH` expression.
///
/// This is the only place in the application where user text becomes SQL syntax, and it is
/// where the bugs would live. FTS5's expression grammar has operators (`AND`, `OR`, `NOT`,
/// `NEAR`), column filters (`subject : word`), grouping and prefix stars, so text pasted
/// straight in either fails with a syntax error or quietly means something the user did not
/// ask for. Typing `NOT` into a mail client means you are looking for the word "not".
///
/// The rule is therefore: **nothing the user types is ever a token of the grammar.** The
/// input is reduced to the words `unicode61` would have kept — letters and digits, nothing
/// else — and each of those becomes an FTS5 string literal, so `-`, `(`, `*`, `NOT` and an
/// emoji are all just separators. The only two things this builds out of the grammar are the
/// `*` that makes a term a prefix and the `AND` between terms.
enum FTS5MatchExpression {
    /// The most terms one expression will carry.
    ///
    /// Search runs per keystroke, and a paste into the field is one keystroke. FTS5 builds a
    /// tree per phrase and SQLite has a hard depth limit, so an unbounded expression turns a
    /// paste of a whole email into a thrown error on the way to the screen. Thirty-two is
    /// past anything anybody types and well short of that limit.
    static let maximumTerms = 32

    /// The expression for `text`, or nil when there is nothing to search for.
    ///
    /// Nil is the answer for empty input, whitespace, and for input that holds no character
    /// the tokeniser would keep — `---` or a lone emoji. The caller returns no results for
    /// nil, which is the point: an empty field must not match every message.
    static func build(from text: String) -> String? {
        let terms = self.terms(in: text).prefix(maximumTerms).compactMap(render)
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " AND ")
    }

    /// One chunk of the input: a bare word, or the words between two quotes.
    ///
    /// Both render as an FTS5 phrase, because a bare word is a phrase of one token. The only
    /// difference between them is the star.
    struct Term: Equatable {
        var text: String
        /// Whether the last token gets FTS5's `*`.
        ///
        /// True for a bare word, because people search as they type and the word is rarely
        /// finished. False for a phrase the user closed with a second quote: somebody who
        /// typed `"quarterly numbers"` asked for exactly that, and widening the last word
        /// would answer a different question. An *unclosed* phrase is still being typed, so
        /// it gets the star back — `"quick bro` finds "quick brown" on the way to
        /// `"quick brown"`.
        var isPrefix: Bool
    }

    /// Splits the input into phrases and bare words.
    ///
    /// A quote that is never closed ends the input instead of being an error, so the
    /// expression is complete after every keystroke of typing `"dragonfly inn"` rather than
    /// broken for the fourteen in the middle.
    static func terms(in text: String) -> [Term] {
        var terms: [Term] = []
        var current = ""
        var insidePhrase = false

        func flush(isPrefix: Bool) {
            defer { current = "" }
            guard !current.isEmpty else { return }
            terms.append(Term(text: current, isPrefix: isPrefix))
        }

        for character in text {
            if character == "\"" {
                // Closing quote: the phrase is finished, so it is taken literally. Opening
                // quote: whatever was being typed before it is a finished bare word.
                flush(isPrefix: !insidePhrase)
                insidePhrase.toggle()
            } else if !insidePhrase, character.isWhitespace {
                flush(isPrefix: true)
            } else {
                current.append(character)
            }
        }
        flush(isPrefix: true)
        return terms
    }

    /// One term as an FTS5 phrase, or nil when the tokeniser would find nothing in it.
    ///
    /// The nil case is what keeps `MATCH '""*'` — a syntax error — off the wire when somebody
    /// types a bare `-` or `(`.
    private static func render(_ term: Term) -> String? {
        let tokens = self.tokens(in: term.text)
        guard !tokens.isEmpty else { return nil }
        let body = tokens.joined(separator: " ")
        return term.isPrefix ? "\"\(body)\"*" : "\"\(body)\""
    }

    /// The term reduced to what `unicode61` would keep, with everything else as a separator.
    ///
    /// Doing the tokeniser's job before quoting rather than leaving the characters inside the
    /// literal is what makes the expression safe by construction: the only thing that reaches
    /// SQLite is letters, digits and single spaces, so there is no quote to escape and no
    /// terminator to smuggle in. A pasted NUL byte is the case that proves it — SQLite reads
    /// a MATCH expression up to the first one, so `hedgehog\u{0}census` inside a literal
    /// truncated to an unterminated string and FTS5 rejected the query.
    ///
    /// `unicode61`'s own rule is Unicode categories: letters and numbers are token characters
    /// and everything else separates. So an emoji, a dash and a bracket all vanish here
    /// exactly as they vanished on the way into the index, and a term made only of them can
    /// never match anything — no results is the honest answer, not an error.
    private static func tokens(in text: String) -> [String] {
        text.split { character in
            !character.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        }
        .map(String.init)
    }
}
