// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import Foundation

#warning("add confidence for HTTP method parser")
#warning("better you for quick suggestions of filters that takes less space")

// Search:
//
// - Search with confidence for filter names (and consume it) plus any remaining: symbols
// - If no matched (with high confidence?), search for values

// The patterns are set up with "guesses" around. So if the user enters incorrect
// range, it'll still try to "guess".
extension Parsers {
    static let filters: [Parser<(ConsoleSearchFilter, Confidence)>] = [
        filterStatusCode, filterHost, filterMethod
    ]

    static let filterStatusCode = oneOf(
            filterName("status code") <*> listOf(rangeOfInts(in: 100...500)),
            // If we find a value in 100...500 range, assign it 0.7 confidence and suggest it
            listOf(rangeOfInts(in: 100...500)).filter { !$0.isEmpty }.map { (0.7, $0) }
    ).map { confidence, values in
        (ConsoleSearchFilter.statusCode(.init(values: values)), confidence)
    }

#warning("suggest host enen if there is no match?")
    static let filterHost = (filterName("host") <*> listOf(host)).map { confidence, values in
        (ConsoleSearchFilter.host(.init(values: values)), confidence)
    }

    static let filterMethod = oneOf(
        filterName("method") <*> listOf(httpMethod),
        listOf(httpMethod).filter { !$0.isEmpty }.map { (0.7, $0) }
    ).map { confidence, values in
        (ConsoleSearchFilter.method(.init(values: values)), confidence)
    }

    static let host = char(from: .urlHostAllowed.subtracting(.init(charactersIn: ","))).oneOrMore.map { String($0) }

    static let httpMethod = oneOf(HTTPMethod.allCases.map { method in
        prefixIgnoringCase(method.rawValue).map { method }
    })

    /// Consumes a filter with the given name if it has high enough confidence.
    static func filterName(_ name: String) -> Parser<Confidence> {
        let words = name.split(separator: " ").map { String($0) }
        assert(!words.isEmpty)

        func fuzzy(_ word: String) -> Parser<Confidence> {
            char(from: .letters).oneOrMore
                .map { String($0).fuzzyMatch(word) }
                .filter { $0 > 0.6 }
        }

        // Try to match as many words as we can in any order
        let anyWords: Parser<Confidence> = oneOf(words.map { fuzzy($0) <* whitespaces }).oneOrMore.map {
            let confidences = Array($0.sorted())
            guard words.count > 1 else {
                return confidences[0]
            }
            guard confidences.count > 1 else {
                return Confidence(confidences[0].rawValue * 0.8)
            }
            let first = confidences[0].rawValue * 0.75 // This is the main contributor
            let remaining = confidences.dropFirst()
                .map { $0.rawValue }
                .reduce(0, +) * (0.25 / Float(confidences.count - 1))
            return Confidence(first + remaining)
        }
        return anyWords <* optional(":") <* whitespaces
    }

    static func rangeOfInts(in range: ClosedRange<Int>) -> Parser<ConsoleSearchRange<Int>> {
        rangeOfInts.filter {
            range.contains($0.lowerBound) && range.contains($0.upperBound)
        }
    }

    static let rangeOfInts: Parser<ConsoleSearchRange<Int>> = oneOf(
        zip(int, rangeModifier, int).map { lowerBound, modifier, upperBound in
            switch modifier {
            case .open: return .init(.open, lowerBound: lowerBound, upperBound: upperBound)
            case .closed: return .init(.closed, lowerBound: lowerBound, upperBound: upperBound)
            }
        },
        int.map(ConsoleSearchRange.init)
    )

    static let not: Parser<Bool> = optional(oneOf(prefixIgnoringCase("not"), "!") *> whitespaces)
        .map { $0 != nil }

    /// A comma or space separated list.
    static func listOf<T>(_ parser: Parser<T>) -> Parser<[T]> {
        (parser <* optional(",") <* whitespaces).zeroOrMore
    }

    static let rangeModifier: Parser<ConsoleSearchRangeModfier> = whitespaces *> oneOf(
        oneOf("-", "–", "<=", "...").map { _ in .closed }, // important: order
        oneOf("<", ".<", "..<").map { _ in .open },
        string("..").map { _ in .closed }
    ) <* whitespaces
}

enum HTTPMethod: String, Hashable, Codable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case connect = "CONNECT"
    case options = "OPTIONS"
    case trace = "TRACE"
}
