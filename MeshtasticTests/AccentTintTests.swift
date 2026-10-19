//
//  AccentTintTests.swift
//  MeshtasticTests
//
//  Copyright(c) Garth Vander Houwen 9/8/26.
//

import Testing
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import Meshtastic

/// The app carries two accents: `accentColor` to draw text and glyphs on a surface, and
/// `accentFill` to fill a shape under white text. In Pangea the fill is Ember, and the text
/// accent is Ember in light mode and Fossil in dark mode.
@Suite("Accent tint")
struct AccentTintTests {

	#if canImport(UIKit)
	/// The text accent by asset name rather than through `Color.accentColor`. The brand extension
	/// shadows SwiftUI's `accentColor`, which resolves inside the app but is ambiguous from here,
	/// where both declarations are visible. `accentFill` has no such clash and is read directly.
	private static let textAccentAsset = "AccentColor"

	private func resolved(_ color: Color, dark: Bool) -> UIColor {
		UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
	}

	private func resolved(asset: String, dark: Bool) -> UIColor? {
		UIColor(named: asset)?.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
	}

	private func luminance(_ color: UIColor) -> CGFloat {
		var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		color.getRed(&r, green: &g, blue: &b, alpha: &a)
		func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
		return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
	}

	private func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
		(max(a, b) + 0.05) / (min(a, b) + 0.05)
	}

	private static let ember = UIColor(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255, alpha: 1)
	private static let fossil = UIColor(red: 0xF0 / 255, green: 0x55 / 255, blue: 0x11 / 255, alpha: 1)

	/// Pangea: the fill under white text (the user's own bubbles, prominent buttons, badges) is
	/// Ember #C2410C in both appearances. White on Fossil itself is only 3.5:1.
	@Test("the fill accent is Ember in both appearances")
	func fillAccentIsEmberInBothAppearances() {
		// Reads Color.accentFill itself.
		let light = luminance(resolved(.accentFill, dark: false))
		let dark = luminance(resolved(.accentFill, dark: true))
		#expect(abs(light - dark) < 0.01)
		#expect(abs(light - luminance(Self.ember)) < 0.01)
	}

	/// White text and links on the fill (own bubbles: links there are white, underlined) meet
	/// WCAG AA for body text, 4.5:1. A palette change that lightens the fill past that fails here.
	@Test("white on the fill accent meets 4.5:1")
	func whiteOnFillAccentKeepsContrast() {
		for dark in [false, true] {
			let contrast = ratio(1.0, luminance(resolved(.accentFill, dark: dark)))
			#expect(contrast >= 4.5, "white on accentFill is \(contrast):1 (dark: \(dark))")
		}
	}

	/// Pangea: the text accent is Ember in light mode and Fossil in dark mode, so orange text
	/// reads at 4.5:1 or better on the system backgrounds of each.
	@Test("the text accent is Ember in light mode and Fossil in dark mode")
	func textAccentMeetsContrastInBothAppearances() {
		guard let light = resolved(asset: Self.textAccentAsset, dark: false),
			  let dark = resolved(asset: Self.textAccentAsset, dark: true) else {
			Issue.record("\(Self.textAccentAsset) missing"); return
		}
		#expect(abs(luminance(light) - luminance(Self.ember)) < 0.01)
		#expect(abs(luminance(dark) - luminance(Self.fossil)) < 0.01)
		let white = luminance(.white)
		let darkCard = luminance(UIColor.secondarySystemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
		#expect(ratio(luminance(light), white) >= 4.5)
		#expect(ratio(luminance(dark), darkCard) >= 4.5)
	}

	/// The tint the app sets on its windows matches the text accent.
	@Test("the app tint matches the text accent")
	func appTintMatchesTextAccent() {
		for dark in [false, true] {
			guard let asset = resolved(asset: Self.textAccentAsset, dark: dark) else { continue }
			#expect(abs(luminance(resolved(.pangeaPrimary, dark: dark)) - luminance(asset)) < 0.01)
		}
	}
	#endif
}
