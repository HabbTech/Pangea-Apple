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
/// `accentFill` to fill a shape under white text. In Pangea both are Fossil.
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

	/// Pangea: the fill under white text (the user's own bubbles, prominent buttons, badges) is
	/// Fossil #F05511 in both appearances, as the bubbles were before the palette merge.
	@Test("the fill accent is Fossil in both appearances")
	func fillAccentIsFossilInBothAppearances() {
		// Reads Color.accentFill itself.
		let light = luminance(resolved(.accentFill, dark: false))
		let dark = luminance(resolved(.accentFill, dark: true))
		#expect(abs(light - dark) < 0.01)
		#expect(abs(light - luminance(UIColor(red: 0xF0 / 255, green: 0x55 / 255, blue: 0x11 / 255, alpha: 1))) < 0.01)
	}

	/// White text and links on the fill (own bubbles: links there are white, underlined) stay
	/// at least 3:1, the large-text floor Fossil has always met (about 3.3:1). A later palette
	/// change that darkens or lightens the fill past that fails here.
	@Test("white on the fill accent stays at least 3:1")
	func whiteOnFillAccentKeepsContrast() {
		for dark in [false, true] {
			let fill = luminance(resolved(.accentFill, dark: dark))
			let ratio = (1.0 + 0.05) / (fill + 0.05)
			#expect(ratio >= 3.0, "white on accentFill is \(ratio):1 (dark: \(dark))")
		}
	}

	/// Pangea: the app-wide accent is the Fossil brand orange (#F05511) in both appearances,
	/// unlike upstream's cobalt, which lightens in dark mode.
	@Test("the text accent is Fossil in both appearances")
	func textAccentIsFossilInBothAppearances() {
		guard let light = resolved(asset: Self.textAccentAsset, dark: false),
			  let dark = resolved(asset: Self.textAccentAsset, dark: true) else {
			Issue.record("\(Self.textAccentAsset) missing"); return
		}
		#expect(abs(luminance(light) - luminance(dark)) < 0.01)
		#expect(abs(luminance(light) - luminance(UIColor(red: 0xF0 / 255, green: 0x55 / 255, blue: 0x11 / 255, alpha: 1))) < 0.01)
	}
	#endif
}
