//
//  DocumentationSearch.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 9/13/26.
//
import Foundation

/// The documentation, searchable from the same field as the settings.
///
/// A user searching "hops" may want to change the setting or to understand what a
/// hop is. Both answers are offered — settings first, then documentation under its
/// own heading.
///
/// Pangea: the pages are Pangea's own guides (`PangeaHelp.guides`), which open on the
/// web, rather than the mesh firmware's bundled documentation.
enum DocumentationSearch {

	typealias Page = HelpGuide

	static var pages: [Page] { PangeaHelp.guides }

	/// Pages matching `query`, best first. Expert Mode's guides only when it's on.
	///
	/// Documentation is never de-emphasised: a page reads the same whether or not a
	/// radio is connected, so the reasons that dim a settings result do not apply.
	static func search(_ query: String, expertMode: Bool) -> [Page] {
		rank(query, in: pages.filter { expertMode || !$0.expertOnly })
	}

	/// The ranking half, over an explicit page list, so it can be tested without
	/// depending on what the bundle happens to contain.
	static func rank(_ query: String, in pages: [Page]) -> [Page] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count >= SettingsSearchEngine.minimumQueryLength else { return [] }

		return pages
			.compactMap { page -> (Page, Int)? in
				var score = 0
				if page.title.localizedStandardCompare(trimmed) == .orderedSame {
					score += 1000
				} else if page.title.localizedStandardContains(trimmed) {
					score += 250
				}
				if page.keywords.contains(where: { $0.localizedStandardContains(trimmed) }) {
					score += 100
				}
				return score > 0 ? (page, score) : nil
			}
			// Ties break by title, so the order never depends on how the file was read.
			.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
			.map(\.0)
	}
}
