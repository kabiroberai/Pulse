// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Pulse
import CoreData
import Combine

#warning("reimplement filters (ConsoleSearchBarViewModel) should perform filter (or should it?)")
#warning("fix how isActiveSuggestion works")

final class ConsoleSearchBarViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var tokens: [ConsoleSearchToken] = []

    var parameters: ConsoleSearchParameters {
        ConsoleSearchParameters(searchTerm: text.trimmingCharacters(in: .whitespaces), tokens: tokens, options: .default)
    }

    var isEmpty: Bool {
        parameters.isEmpty
    }
}

#warning("replace isSearching with operation != nil")
#warning("remove filters and scropes from suggestions that are already used")

@available(iOS 15, tvOS 15, *)
final class ConsoleSearchViewModel: ObservableObject, ConsoleSearchOperationDelegate {
    private var entities: CurrentValueSubject<[NSManagedObject], Never>

    var isViewVisible = false {
        didSet {
            if !isViewVisible {
                operation?.cancel()
                operation = nil
            }
        }
    }

    @Published private(set) var results: [ConsoleSearchResultViewModel] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isNewResultsButtonShown = false

    @Published private(set)var isSpinnerNeeded = false
    @Published private(set)var isSearching = false

    @Published var recentSearches: [ConsoleSearchParameters] = []

    #warning("sort by confidence instead")
    var allSuggestions: [ConsoleSearchSuggestion] {
        (topSuggestions + suggestedScopes)
    }

    let searchBar: ConsoleSearchBarViewModel

    var toolbarTitle: String {
        if searchBar.isEmpty {
            return "Suggested Filters"
        } else {
            return "\(results.count) results"
        }
    }

    private var dirtyDate: Date?
    private var buffer: [ConsoleSearchResultViewModel] = []
    private var operation: ConsoleSearchOperation?
    private var refreshResultsOperation: ConsoleSearchOperation?

    @Published var topSuggestions: [ConsoleSearchSuggestion] = []
    @Published var suggestedScopes: [ConsoleSearchSuggestion] = []

    private let service = ConsoleSearchService()

    private var hosts: Set<String> = []
    private let queue = DispatchQueue(label: "com.github.pulse.console-search-view")
    private var cancellables: [AnyCancellable] = []
    private let context: NSManagedObjectContext

    init(entities: CurrentValueSubject<[NSManagedObject], Never>, store: LoggerStore, searchBar: ConsoleSearchBarViewModel) {
        self.entities = entities
        self.searchBar = searchBar
        self.context = store.newBackgroundContext()

        let text = searchBar.$text
            .map { $0.trimmingCharacters(in: .whitespaces ) }
            .removeDuplicates()

        Publishers.CombineLatest(text, searchBar.$tokens.removeDuplicates()).sink { [weak self] in
            self?.didUpdateSearchCriteria($0, $1)
        }.store(in: &cancellables)

        text
            .dropFirst()
            .receive(on: queue)
            .sink { [weak self] in self?.updateSearchTokens(for: $0) }
            .store(in: &cancellables)

        self.topSuggestions = makeDefaultSuggestedFilters()
        self.suggestedScopes = makeDefaultSuggestedScopes()

        recentSearches = getRecentSearches()

        entities
            .throttle(for: 3, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.didReloadEntities(for: $0) }
            .store(in: &cancellables)
    }

    // MARK: Search

    private func didUpdateSearchCriteria(_ searchText: String, _ tokens: [ConsoleSearchToken]) {
        isNewResultsButtonShown = false

        operation?.cancel()
        operation = nil

        let parameters = ConsoleSearchParameters(searchTerm: searchText, tokens: tokens, options: .default)
        startSearch(parameters: parameters)
    }

    private func startSearch(parameters: ConsoleSearchParameters) {
        guard !parameters.isEmpty else {
            isSearching = false
            results = []
            return
        }

        isSearching = true
        buffer = []

        // We want to continue showing old results for just a little bit longer
        // to prevent screen from flickering. If the search is slow, we'll just
        // remove the results eventually.
        if !results.isEmpty {
            dirtyDate = Date()
        }

        let operation = ConsoleSearchOperation(objectIDs: entities.value.map(\.objectID), parameters: parameters, service: service, context: context)
        operation.delegate = self
        operation.resume()
        self.operation = operation
    }

    func buttonShowMoreResultsTapped() {
        isSearching = true
        operation?.resume()
    }

    func buttonShowNewlyAddedSearchResultsTapped() {
        withAnimation {
            isNewResultsButtonShown = false
        }
        startSearch(parameters: searchBar.parameters)
    }

    // MARK: Refresh Results

    private func didReloadEntities(for entities: [NSManagedObject]) {
        checkForNewSearchMatches(for: entities)
    }

    private func checkForNewSearchMatches(for entities: [NSManagedObject]) {
        guard isViewVisible else {
            return // Off-screen
        }
        guard operation == nil && refreshResultsOperation == nil else {
            return // Let's wait until the next refresh
        }
        guard !isNewResultsButtonShown else {
            return // We already know there are new results
        }
        let operation = ConsoleSearchOperation(objectIDs: entities.map(\.objectID), parameters: searchBar.parameters, service: service, context: context)
        operation.delegate = self
        operation.resume()
        self.refreshResultsOperation = operation
    }

    // MARK: ConsoleSearchOperationDelegate

    func searchOperation(_ operation: ConsoleSearchOperation, didAddResults results: [ConsoleSearchResultViewModel]) {
        if operation === self.operation {
            if let dirtyDate = dirtyDate {
                self.buffer += results
                if Date().timeIntervalSince(dirtyDate) > 0.2 {
                    self.dirtyDate = nil
                    self.results = buffer
                    self.buffer = []
                }
            } else {
                self.results += results
            }
        } else if operation === self.refreshResultsOperation {
            // If the first element changed, that should be enough of the
            // indicator that there are new search matches. We can assume
            // that the messages are only ever inserted at the top and skip
            // a ton of work.
            if results.first?.entity.objectID !== self.results.first?.entity.objectID {
                withAnimation {
                    self.isNewResultsButtonShown = true
                }
            }
            self.refreshResultsOperation?.cancel()
            self.refreshResultsOperation = nil
        }
    }

    func searchOperationDidFinish(_ operation: ConsoleSearchOperation, hasMore: Bool) {
        if operation === self.operation {
            self.operation = nil
            isSearching = false
            if dirtyDate != nil {
                self.dirtyDate = nil
                self.results = buffer
            }
            self.hasMore = hasMore
        } else if operation === self.refreshResultsOperation {
            self.refreshResultsOperation = nil
        }
    }

    // MARK: Recent Searches

    func onSubmitSearch() {
        if let suggestion = topSuggestions.first, isActionable(suggestion) {
            suggestion.onTap()
            return
        }
        #warning("do we need this?")
        let searchTerm = searchBar.text.trimmingCharacters(in: .whitespaces)
        guard !searchTerm.isEmpty else {
            return
        }
        convertCurrentSearchTextToToken()
        addRecentSearch(searchBar.parameters)
        saveRecentSearches()
    }

    private func convertCurrentSearchTextToToken() {
        let searchTerm = searchBar.text.trimmingCharacters(in: .whitespaces)
        guard !searchTerm.isEmpty else { return }
        searchBar.text = ""
        searchBar.tokens.append(.text(searchTerm))
    }

    private func getRecentSearches() -> [ConsoleSearchParameters] {
        ConsoleSettings.shared.recentSearches.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([ConsoleSearchParameters].self, from: $0)
        } ?? []
    }

    private func saveRecentSearches() {
        guard let data = (try? JSONEncoder().encode(recentSearches)),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        ConsoleSettings.shared.recentSearches = string
    }

    func selectRecentSearch(_ parameters: ConsoleSearchParameters) {
//        searchBar.text = parameters.searchTerm
//        searchBar.tokens = parameters.tokens
    }

    func clearRecentSearchess() {
        recentSearches = []
        saveRecentSearches()
    }

    private func addRecentSearch(_ parameters: ConsoleSearchParameters) {
//        var recentSearches = self.recentSearches
//        while let index = recentSearches.firstIndex(where: { $0.searchTerm == parameters.searchTerm }) {
//            recentSearches.remove(at: index)
//        }
//        recentSearches.insert(parameters, at: 0)
//        if recentSearches.count > 10 {
//            recentSearches.removeLast(recentSearches.count - 10)
//        }
    }

    // MARK: Suggested Tokens

    private func updateSearchTokens(for searchText: String) {
        guard #available(iOS 16, tvOS 16, *) else { return }

#warning("dont show full suggestions when have search results ")
#warning("fix keybord cursor jumping")
#warning("easier way to manage these suggestions")
#warning("add suggestions based on input, e.g. input range")
#warning("finish this prototype")
#warning("different styles for filters and completions")
#warning("dont show suggestion when its not specific enough")
#warning("search like in xcode with first letter only")
#warning("make it all case insensitive")
#warning("if you are only entering values, what to suggest?")
#warning("filtes and scopes in separate categories")

#warning("TODO: priorize direct matches")

        let topSuggestions: [ConsoleSearchSuggestion]
        let suggestedScopes: [ConsoleSearchSuggestion]
        if searchText.isEmpty {
            topSuggestions = makeDefaultSuggestedFilters()
            suggestedScopes = makeDefaultSuggestedScopes()
        } else {
            topSuggestions = makeTopSuggestions(searchText: searchText)
            suggestedScopes = []
        }
        DispatchQueue.main.async {
            self.topSuggestions = topSuggestions
            self.suggestedScopes = suggestedScopes
        }
    }

    private func makeTopSuggestions(searchText: String) -> [ConsoleSearchSuggestion] {
        let filters = Parsers.filters
            .compactMap { try? $0.parse(searchText) }
            .sorted(by: { $0.1 > $1.1 }) // Sort by confidence

        let scopes: [(ConsoleSearchScope, Confidence)] = ConsoleSearchScope.allEligibleScopes.compactMap {
            guard let confidence = try? Parsers.filterName($0.title).parse(searchText) else { return nil }
            return ($0, confidence)
        }

        let allSuggestions = filters.map {
            (makeSuggestion(for: $0.0), $0.1)
        } + scopes.map {
            (makeSuggestion(for: $0.0), $0.1)
        }

        let plainSearchSuggestion = ConsoleSearchSuggestion(text: {
            AttributedString("Contains: ") { $0.foregroundColor = .primary } +
            AttributedString(searchText) { $0.foregroundColor = .blue }
        }(), onTap: {
            self.convertCurrentSearchTextToToken()
        })

        return Array(allSuggestions
            .sorted(by: { $0.1 > $1.1 }) // Sort by confidence
            .map { $0.0 }.prefix(3)) + [plainSearchSuggestion]
    }

    private func makeDefaultSuggestedFilters() -> [ConsoleSearchSuggestion] {
        return [
            ConsoleSearchFilter.statusCode(.init(values: [])),
            ConsoleSearchFilter.host(.init(values: [])),
            ConsoleSearchFilter.method(.init(values: []))
        ].map(makeSuggestion)
    }

    private func makeDefaultSuggestedScopes() -> [ConsoleSearchSuggestion] {
        ConsoleSearchScope.allEligibleScopes.map(makeSuggestion)
    }

    private func makeSuggestion(for filter: ConsoleSearchFilter) -> ConsoleSearchSuggestion {
        var string = AttributedString(filter.name + ": ") { $0.foregroundColor = .primary }
        let values = filter.valuesDescriptions
        if values.isEmpty {
            string.append(filter.valueExample) { $0.foregroundColor = .secondary }
        } else {
            for (index, description) in values.enumerated() {
                string.append(description) { $0.foregroundColor = .blue }
                if index < values.endIndex - 1 {
                    string.append(", ") { $0.foregroundColor = .secondary }
                }
            }
        }
        return ConsoleSearchSuggestion(text: string) {
            if values.isEmpty {
                self.searchBar.text = filter.name + ": "
            } else {
                self.searchBar.text = ""
                self.searchBar.tokens.append(.filter(filter))
            }
        }
    }

    private func makeSuggestion(for scope: ConsoleSearchScope) -> ConsoleSearchSuggestion {
        var string = AttributedString("Search in ") { $0.foregroundColor = .primary }
        string.append(scope.title) { $0.foregroundColor = .blue }
        return ConsoleSearchSuggestion(text: string) {
            self.searchBar.text = ""
            self.searchBar.tokens.append(.scope(scope))
        }
    }

    #warning("this should be work only if parameters are there")
    func isActionable(_ suggestion: ConsoleSearchSuggestion) -> Bool {
        topSuggestions.count == 1 && suggestion.id == topSuggestions[0].id
    }
}

@available(iOS 15, tvOS 15, *)
struct ConsoleSearchSuggestion: Identifiable {
    let id = UUID()
    let text: AttributedString
    var onTap: () -> Void
}

@available(iOS 15, tvOS 15, *)
struct ConsoleSearchResultViewModel: Identifiable {
    var id: NSManagedObjectID { entity.objectID }
    let entity: NSManagedObject
    let occurences: [ConsoleSearchOccurence]
}

struct ConsoleSearchParameters: Equatable, Hashable, Codable {
    var filters: [ConsoleSearchFilter] = []
    var scopes: [ConsoleSearchScope] = []
    var searchTerms: [String] = []
    let options: StringSearchOptions

    init(searchTerm: String, tokens: [ConsoleSearchToken], options: StringSearchOptions) {
        if !searchTerm.trimmingCharacters(in: .whitespaces).isEmpty {
            self.searchTerms.append(searchTerm)
        }
        for token in tokens {
            switch token {
            case .filter(let filter): self.filters.append(filter)
            case .scope(let scope): self.scopes.append(scope)
            case .text(let string): self.searchTerms.append(string)
            }
        }
        if self.scopes.isEmpty {
            self.scopes = ConsoleSearchScope.allCases
        }
        self.options = options
    }

    var isEmpty: Bool {
        filters.isEmpty && searchTerms.isEmpty
    }
}
