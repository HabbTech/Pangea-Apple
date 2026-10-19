// MARK: Color+Brand
//
//  Color+Brand.swift
//  Meshtastic
//
//  Meshtastic brand color tokens derived from the official design standards.
//  https://raw.githubusercontent.com/meshtastic/design/refs/heads/master/standards/meshtastic_design_standards_latest.md
//
//  System color shadows (.primary, .secondary) ensure every existing
//  call-site picks up the branded palette with no per-file changes.

import SwiftUI

// MARK: - System Color Shadows

extension Color {

	/// Branded accent — shadows SwiftUI `Color.accentColor`. The `AccentColor` asset: Pangea
	/// Ember #C2410C in light mode, Fossil Light #F26A2E in dark mode; with Increase Contrast,
	/// #A8380A and #F58A5C. Same values as `Color.pangeaPrimary`.
	///
	/// This is the accent for text and glyphs, and it is the app-wide tint, so plain buttons,
	/// toolbar items, links and tab labels all use it.
	static var accentColor: Color { Color("AccentColor") }

	/// The accent as a fill under white text: prominent buttons, message bubbles, badges.
	/// Pangea: Ember #C2410C in both modes, the colour of the user's own bubbles. White on
	/// Fossil #F05511 is only 3.5:1; on Ember it is 5.2:1.
	static let accentFill = Color("Colors/MeshtasticAccent")

	/// Branded primary text — shadows SwiftUI `Color.primary`
	/// Neutral 700 #3D3E50 light / Neutral 50 #F5F6FA dark
	static let primary = Color("Colors/MeshtasticPrimary")

	/// Branded secondary — shadows SwiftUI `Color.secondary`
	/// Neutral 300 #B8BAC8 light / Neutral 600 #555668 dark
	static let secondary = Color("Colors/MeshtasticSecondary")

	/// On-surface variant for descriptive/secondary text (timestamps, previews)
	/// NV 600 #5C5E78 light / NV 300 #BDBFCF dark — WCAG AA compliant
	static let onSurfaceVariant = Color("Colors/MeshtasticOnSurfaceVariant")

	/// Branded success green — shadows SwiftUI `Color.green`
	/// Green 600 #3FB86D light / Green 500 #67EA94 dark
	static let green = Color("Colors/MeshtasticSuccess")

	/// Branded warning amber — shadows SwiftUI `Color.orange`
	/// Warning #E8A33E both modes
	static let orange = Color("Colors/MeshtasticWarning")

	/// Branded error red — shadows SwiftUI `Color.red`
	/// Error #E05252 both modes
	static let red = Color("Colors/MeshtasticError")

	/// Branded blue — shadows SwiftUI `Color.blue`
	/// Info #5C6BC0 both modes
	static let blue = Color("Colors/MeshtasticInfo")

	/// Message search/jump highlight wash — warning amber #E8A33E with baked
	/// per-mode alpha (0.20 light / 0.32 dark) so it composites to a warm cream
	/// on light lists and a readable gold on dark, instead of the muddy olive
	/// that translucent system yellow produced over black.
	static let messageHighlight = Color("Colors/MeshtasticHighlight")
}
