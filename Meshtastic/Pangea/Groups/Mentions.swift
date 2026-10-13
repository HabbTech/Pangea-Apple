//
//  Mentions.swift
//  Pangea
//
//  "@Sam Rivera" travels as plain text, so every Meshtastic app shows it fine.
//  Pangea turns names it recognises into links that open a DM with that
//  person's code filled in.
//

import SwiftUI
import CoreData

@MainActor
enum Mentions {

	struct Person {
		let name: String
		let num: Int64
	}

	private static var cache: [Person] = []
	private static var cacheDate = Date.distantPast
	private static let cacheLifetime: TimeInterval = 30

	/// Everyone with a usable name, longest first so "@Sam Rivera" wins over "@Sam".
	private static func people() -> [Person] {
		if Date().timeIntervalSince(cacheDate) < cacheLifetime { return cache }
		let context = PersistenceController.shared.container.viewContext
		let request = UserEntity.fetchRequest()
		request.predicate = NSPredicate(format: "longName != nil AND longName != ''")
		let myNum = Int64(UserDefaults.preferredPeripheralNum)
		let users = (try? context.fetch(request)) ?? []
		var people: [Person] = []
		for user in users where user.num != myNum {
			if let long = user.longName, long.count >= 2 { people.append(Person(name: long, num: user.num)) }
			if let short = user.shortName, short.count >= 2, short != user.longName { people.append(Person(name: short, num: user.num)) }
		}
		cache = people.sorted { $0.name.count > $1.name.count }
		cacheDate = Date()
		return cache
	}

	/// Wraps known "@Name" mentions in markdown links. Text inside existing links and
	/// `code spans` is left alone.
	static func linkify(_ markdown: String) -> String {
		guard markdown.contains("@") else { return markdown }
		return linkify(markdown, people: people())
	}

	/// - Parameter people: sorted longest name first. A name shared by two different
	///   people isn't linked, since there's no telling which one was meant.
	static func linkify(_ markdown: String, people: [Person]) -> String {
		guard !people.isEmpty else { return markdown }

		var result = ""
		var rest = Substring(markdown)
		var insideLink = false
		while let at = rest.firstIndex(where: { $0 == "@" || $0 == "[" || $0 == "]" || $0 == "`" || $0.isNewline }) {
			result += rest[..<at]
			let char = rest[at]
			if char == "`" {
				// A code span runs to the next run of exactly as many backticks (longer or
				// shorter runs inside it are part of the code); unclosed, it's just text.
				let run = rest[at...].prefix(while: { $0 == "`" })
				let after = rest[run.endIndex...]
				if let close = closingRun(in: after, length: run.count) {
					result += rest[at..<close]
					rest = rest[close...]
				} else {
					result += run
					rest = after
				}
				continue
			}
			if char.isNewline {
				// Link text never spans lines, so a stray "[" stops mattering here.
				insideLink = false
				result.append(char)
				rest = rest[rest.index(after: at)...]
				continue
			}
			if char != "@" {
				insideLink = char == "["
				result.append(char)
				rest = rest[rest.index(after: at)...]
				if char == "]", rest.first == "(" {
					// The link's target, e.g. the URL in "[url](url)", is copied untouched.
					let target = linkTarget(rest)
					result += target
					rest = rest[target.endIndex...]
				}
				continue
			}
			let afterAt = rest[rest.index(after: at)...]
			let precededByWord = result.last.map { $0.isLetter || $0.isNumber } ?? false
			let lowered = matchKey(afterAt.prefix(40))
			if !insideLink, !precededByWord,
			   let match = people.first(where: { lowered.hasPrefix(matchKey($0.name)) && endsWord(afterAt, length: $0.name.count) }),
			   !people.contains(where: { $0.num != match.num && matchKey($0.name) == matchKey(match.name) }) {
				// Markdown punctuation in a name (brackets, backticks, * and _) would end the
				// link text or style it; escaped, it shows as typed.
				let shown = afterAt.prefix(match.name.count).map { Self.markdownPunctuation.contains($0) ? "\\\($0)" : String($0) }.joined()
				let raw = PangeaCode.code(for: match.num).filter { $0 != "@" && $0 != "-" }
				result += "[@\(shown)](\(PangeaCode.scheme)://\(PangeaCode.contactHost)/\(raw))"
				rest = afterAt.dropFirst(match.name.count)
			} else {
				result.append("@")
				rest = afterAt
			}
		}
		result += rest
		return result
	}

	/// Lowercased, with the curly quotes that sending turns straight (see `sendMessage`)
	/// made straight here too, so "@Sam’s Radio" still matches once it arrives as "Sam's".
	/// Each swap is one character for one, so lengths in the text and the name still line up.
	private static func matchKey<S: StringProtocol>(_ text: S) -> String {
		text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "”", with: "\"")
	}

	/// Every character CommonMark lets a backslash escape.
	private static let markdownPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

	/// The end of the first run of exactly `length` backticks in `text`.
	private static func closingRun(in text: Substring, length: Int) -> Substring.Index? {
		var index = text.startIndex
		while let start = text[index...].firstIndex(of: "`") {
			let run = text[start...].prefix(while: { $0 == "`" })
			if run.count == length { return run.endIndex }
			index = run.endIndex
		}
		return nil
	}

	/// "(…)" at the start of `text`, through its matching ")". If it never closes it isn't
	/// a link, so only the "(" is returned and the rest is still scanned for mentions.
	private static func linkTarget(_ text: Substring) -> Substring {
		var depth = 0
		for index in text.indices {
			switch text[index] {
			case "(": depth += 1
			case ")":
				depth -= 1
				if depth == 0 { return text[...index] }
			default: break
			}
		}
		return text.prefix(1)
	}

	private static func endsWord(_ text: Substring, length: Int) -> Bool {
		guard text.count > length else { return true }
		let next = text[text.index(text.startIndex, offsetBy: length)]
		return !(next.isLetter || next.isNumber)
	}

	// MARK: Suggestions

	/// The "@partial" being typed at the end of the message, if any.
	static func activeQuery(in text: String) -> String? {
		guard let at = text.lastIndex(of: "@") else { return nil }
		if at > text.startIndex {
			let before = text[text.index(before: at)]
			guard before.isWhitespace else { return nil }
		}
		let query = text[text.index(after: at)...]
		guard !query.contains("\n"), query.count <= 24 else { return nil }
		return String(query)
	}

	/// People who've posted in this channel first, then anyone else whose name matches.
	static func suggestions(for query: String, channel: ChannelEntity) -> [UserEntity] {
		let myNum = Int64(UserDefaults.preferredPeripheralNum)
		var seen = Set<Int64>()
		var ordered: [UserEntity] = []
		for message in channel.allPrivateMessages.reversed() {
			if let user = message.fromUser, user.num != myNum, seen.insert(user.num).inserted {
				ordered.append(user)
			}
		}
		let lower = query.lowercased()
		let matches: (UserEntity) -> Bool = { user in
			lower.isEmpty
				|| (user.longName?.lowercased().contains(lower) ?? false)
				|| (user.shortName?.lowercased().hasPrefix(lower) ?? false)
		}
		var result = ordered.filter(matches)
		if result.count < 5, !lower.isEmpty {
			let request = UserEntity.fetchRequest()
			request.predicate = NSPredicate(format: "longName CONTAINS[cd] %@ OR shortName BEGINSWITH[cd] %@", lower, lower)
			request.fetchLimit = 10
			let others = (try? PersistenceController.shared.container.viewContext.fetch(request)) ?? []
			result += others.filter { $0.num != myNum && !seen.contains($0.num) }
		}
		return Array(result.prefix(5))
	}

	static func insert(_ user: UserEntity, into text: String) -> String {
		guard let at = text.lastIndex(of: "@") else { return text }
		return String(text[..<at]) + "@" + (user.longName ?? user.shortName ?? "") + " "
	}
}

/// Row of name chips above the keyboard while typing "@…" in a group chat.
struct MentionSuggestionBar: View {
	@Binding var text: String
	let destination: MessageDestination

	var body: some View {
		if case let .channel(channel) = destination,
		   let query = Mentions.activeQuery(in: text) {
			let people = Mentions.suggestions(for: query, channel: channel)
			if !people.isEmpty {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(people, id: \.num) { user in
							Button {
								text = Mentions.insert(user, into: text)
							} label: {
								Text("@\(user.longName ?? user.shortName ?? "")")
									.font(.subheadline.weight(.medium))
									.padding(.horizontal, 12)
									.padding(.vertical, 6)
									.background(Color.accentColor.opacity(0.15), in: Capsule())
							}
							.buttonStyle(.plain)
						}
					}
					.padding(.horizontal, 15)
				}
				.padding(.top, 8)
			}
		}
	}
}
