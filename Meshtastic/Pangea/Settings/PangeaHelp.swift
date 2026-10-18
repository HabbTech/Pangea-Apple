//
//  PangeaHelp.swift
//  Pangea
//
//  Help & Documentation: Pangea's own guides, read on the web so a correction reaches
//  everyone without an app update. Settings search finds them by the same list.
//

import SwiftUI

struct HelpGuide: Identifiable, Hashable {
	/// The page's path in the documentation repository, which is also its identity.
	let path: String
	let title: String
	let systemImage: String
	/// Words a search should find the page by, beyond its title.
	let keywords: [String]
	/// Radio configuration only Expert Mode shows; standard mode's search leaves these out.
	var expertOnly = false

	var id: String { path }
	var url: URL { PangeaHelp.page(path) }
}

enum PangeaHelp {
	static let repository = URL(string: "https://github.com/HabbTech/Pangea-Documentation")!
	static let reportProblem = URL(string: "https://github.com/HabbTech/Pangea-Documentation/issues/new/choose")!
	static let whatsNew = page("CHANGELOG.md")

	static func page(_ path: String) -> URL {
		repository.appending(path: "blob/main").appending(path: path)
	}

	static let guides: [HelpGuide] = [
		HelpGuide(path: "docs/getting-started.md", title: "Getting Started", systemImage: "flag",
				  keywords: ["install", "pair", "pairing", "setup", "radio", "bluetooth", "profile", "region"]),
		HelpGuide(path: "docs/messaging.md", title: "Messaging", systemImage: "bubble.left.and.bubble.right",
				  keywords: ["message", "chat", "code", "group", "everyone nearby", "mention", "delivered", "try again", "retry", "reply", "reaction"]),
		HelpGuide(path: "docs/map.md", title: "Map", systemImage: "map",
				  keywords: ["map", "location", "where", "gps", "nearby radios"]),
		HelpGuide(path: "docs/contacts-and-profiles.md", title: "Contacts & Profiles", systemImage: "person.crop.circle",
				  keywords: ["contact", "profile", "photo", "emoji", "nickname", "name"]),
		HelpGuide(path: "docs/privacy-and-security.md", title: "Privacy & Security", systemImage: "lock",
				  keywords: ["encryption", "encrypted", "private", "public", "key", "security"]),
		HelpGuide(path: "docs/settings.md", title: "Settings & Expert Mode", systemImage: "gearshape",
				  keywords: ["settings", "expert", "battery", "power", "appearance", "dark mode", "clear app data"]),
		HelpGuide(path: "docs/supported-hardware.md", title: "Supported Hardware", systemImage: "antenna.radiowaves.left.and.right",
				  keywords: ["hardware", "radio", "device", "firmware", "region", "buy"]),
		HelpGuide(path: "docs/limits.md", title: "Limits", systemImage: "gauge.with.dots.needle.33percent",
				  keywords: ["limit", "length", "size", "characters", "groups", "photo"]),
		HelpGuide(path: "docs/troubleshooting.md", title: "Troubleshooting", systemImage: "wrench.and.screwdriver",
				  keywords: ["problem", "not delivered", "won't connect", "pairing", "missing", "help"]),
		HelpGuide(path: "docs/faq.md", title: "FAQ", systemImage: "questionmark.bubble",
				  keywords: ["question", "faq", "range", "cost", "internet"]),
		HelpGuide(path: "docs/glossary.md", title: "Glossary", systemImage: "character.book.closed",
				  keywords: ["lora", "mesh", "hop", "hops", "channel", "node", "terms"]),

		HelpGuide(path: "docs/expert/connecting-radios.md", title: "Connecting Radios", systemImage: "antenna.radiowaves.left.and.right",
				  keywords: ["connect", "bluetooth", "ble", "wifi", "tcp", "usb", "serial", "switch radio", "pairing"], expertOnly: true),
		HelpGuide(path: "docs/expert/nodes.md", title: "Nodes", systemImage: "point.3.filled.connected.trianglepath.dotted",
				  keywords: ["node", "nodes", "trace route", "traceroute", "favorite", "ignore", "role", "hops"], expertOnly: true),
		HelpGuide(path: "docs/expert/map.md", title: "Map & Waypoints", systemImage: "map",
				  keywords: ["map", "waypoint", "offline map", "geofence", "overlay", "geojson", "coverage", "site planner"], expertOnly: true),
		HelpGuide(path: "docs/expert/signal-meter.md", title: "Signal Meter", systemImage: "cellularbars",
				  keywords: ["signal", "snr", "rssi", "bars", "strength"], expertOnly: true),
		HelpGuide(path: "docs/expert/telemetry.md", title: "Telemetry & Sensors", systemImage: "chart.xyaxis.line",
				  keywords: ["telemetry", "sensor", "battery", "environment", "air quality", "power", "detection sensor", "metrics"], expertOnly: true),
		HelpGuide(path: "docs/expert/local-mesh-discovery.md", title: "Local Mesh Discovery", systemImage: "dot.radiowaves.left.and.right",
				  keywords: ["discovery", "scan", "preset", "modem", "frequency", "slot"], expertOnly: true),
		HelpGuide(path: "docs/expert/firmware-updates.md", title: "Firmware Updates", systemImage: "arrow.up.arrow.down.square",
				  keywords: ["firmware", "update", "bootloader", "dfu", "uf2", "flash", "erase"], expertOnly: true),
		HelpGuide(path: "docs/expert/mqtt.md", title: "MQTT", systemImage: "dot.radiowaves.up.forward",
				  keywords: ["mqtt", "internet", "server", "broker", "gateway", "uplink", "downlink"], expertOnly: true),
		HelpGuide(path: "docs/expert/tak.md", title: "TAK", systemImage: "target",
				  keywords: ["tak", "atak", "itak", "cot", "cursor on target"], expertOnly: true),
		HelpGuide(path: "docs/expert/apple-watch.md", title: "Apple Watch", systemImage: "applewatch",
				  keywords: ["watch", "foxhunt", "compass", "direction"], expertOnly: true),
		HelpGuide(path: "docs/expert/units-and-locale.md", title: "Units & Language", systemImage: "ruler",
				  keywords: ["units", "metric", "imperial", "temperature", "distance", "language", "locale"], expertOnly: true),
		HelpGuide(path: "docs/expert/logs-and-storage.md", title: "Logs & File Storage", systemImage: "scroll",
				  keywords: ["logs", "debug", "export", "csv", "packet stream", "file storage", "app files", "database", "report"], expertOnly: true)
	]
}

/// The guides as links, standard ones first and Expert Mode's after. Reached from Expert
/// Mode's Settings row; standard mode has About Pangea's Documentation link.
struct PangeaHelpView: View {
	@State private var searchText: String

	/// Opens already filtered when Settings search passes along what the user typed.
	init(initialSearch: String = "") {
		_searchText = State(initialValue: initialSearch)
	}

	private var matches: [HelpGuide] {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return PangeaHelp.guides }
		return PangeaHelp.guides.filter { guide in
			guide.title.localizedStandardContains(query) || guide.keywords.contains { $0.localizedStandardContains(query) }
		}
	}

	var body: some View {
		let standard = matches.filter { !$0.expertOnly }
		let expert = matches.filter(\.expertOnly)
		List {
			if !standard.isEmpty {
				Section("Guides") {
					ForEach(standard) { HelpGuideLink(guide: $0) }
				}
			}
			if !expert.isEmpty {
				Section("Expert Mode") {
					ForEach(expert) { HelpGuideLink(guide: $0) }
				}
			}
			if searchText.isEmpty {
				Section {
					HelpLinkRow(title: "What's New", systemImage: "sparkles", url: PangeaHelp.whatsNew)
					HelpLinkRow(title: "Report a Problem", systemImage: "exclamationmark.bubble", url: PangeaHelp.reportProblem)
				} footer: {
					Text("Guides open in your browser.")
				}
			}
		}
		.overlay {
			if standard.isEmpty && expert.isEmpty {
				ContentUnavailableView.search(text: searchText)
			}
		}
		.navigationTitle("Help & Documentation")
		.navigationBarTitleDisplayMode(.large)
		.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search guides")
	}
}

struct HelpGuideLink: View {
	let guide: HelpGuide

	var body: some View {
		HelpLinkRow(title: guide.title, systemImage: guide.systemImage, url: guide.url)
	}
}

private struct HelpLinkRow: View {
	let title: String
	let systemImage: String
	let url: URL

	var body: some View {
		Link(destination: url) {
			HStack {
				Label(title, systemImage: systemImage)
				Spacer(minLength: 8)
				Image(systemName: "arrow.up.forward")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.tertiary)
					.accessibilityHidden(true)
			}
			.contentShape(Rectangle())
		}
		.foregroundStyle(.primary)
		.accessibilityHint("Opens in your browser")
	}
}
