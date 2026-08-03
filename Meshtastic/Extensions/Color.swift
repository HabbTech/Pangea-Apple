//
//  Color.swift
//  Pangea
//
//  Copyright Garth Vander Houwen 4/25/23.
//

import Foundation
import SwiftUI
import UIKit

extension Color {

	/// Initialize a Color from a hex string (e.g., "#FF0000" or "FF0000")
	init(hex: String) {
		let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
		var int: UInt64 = 0
		Scanner(string: hex).scanHexInt64(&int)

		let a, r, g, b: UInt64
		switch hex.count {
		case 3: // RGB (12-bit)
			(a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
		case 6: // RGB (24-bit)
			(a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
		case 8: // ARGB (32-bit)
			(a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
		default:
			(a, r, g, b) = (255, 0, 0, 0)
		}

		self.init(
			.sRGB,
			red: Double(r) / 255,
			green: Double(g) / 255,
			blue: Double(b) / 255,
			opacity: Double(a) / 255
		)
	}
	///  Returns a boolean for a SwiftUI Color to determine what color of text to use
	/// - Returns: true if the color is light
	func isLight() -> Bool {
		guard let components = cgColor?.components, components.count > 2 else {return false}
		let brightness = ((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000
		return (brightness > 0.5)
	}
	public static let magenta = Color(red: 0.50, green: 0.00, blue: 0.00)

	// MARK: - Pangea brand palette
	//
	// Mirrors the Android palette so both platforms speak the same brand. Bright
	// Fossil fails WCAG as text, so the readable roles are darkened (light) and
	// lightened (dark) exactly like Android's M3 primary family.

	/// The brand mark itself, `#F05511`. Launcher/splash/hero graphics and decorative
	/// accents only — never as text on a light surface, never with white text on top.
	public static let pangeaFossil = Color(hex: "F05511")

	/// The app tint. Held at Fossil itself in both appearances so the brand hue reads
	/// identically light and dark, rather than the darkened/lightened M3 primary pair.
	public static let pangeaPrimary = Color(light: 0xF05511, dark: 0xF05511)

	/// M3 `primaryContainer`: decorative fills behind `pangeaOnPrimaryContainer`.
	public static let pangeaPrimaryContainer = Color(light: 0xFFDBCB, dark: 0x7A2E04)

	/// M3 `onPrimaryContainer`: text and icons drawn on `pangeaPrimaryContainer`.
	public static let pangeaOnPrimaryContainer = Color(light: 0x3B0900, dark: 0xFFDBCB)

	/// M3 `tertiary`: `#2855A8` light / `#B0BFF0` dark. Stays blue so Expert Mode
	/// captions read as a distinct signal rather than more brand orange.
	public static let pangeaTertiary = Color(light: 0x2855A8, dark: 0xB0BFF0)

	/// Builds an appearance-aware color from a light and a dark hex value.
	private init(light: UInt32, dark: UInt32) {
		self.init(UIColor { traits in
			UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
		})
	}
}

extension UIColor {
	///  Returns a boolean indicating if a color is light
	/// - Returns: true if the color is light
	func isLight() -> Bool {
		guard let components = cgColor.components, components.count > 2 else {return false}
		let brightness = ((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000
		return (brightness > 0.5)
	}
	///  Returns a UInt32 from a UIColor
	/// - Returns: UInt32
	var hex: UInt32 {
		   var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		   getRed(&red, green: &green, blue: &blue, alpha: &alpha)
		   var value: UInt32 = 0
		   value += UInt32(1.0 * 255) << 24
		   value += UInt32(red   * 255) << 16
		   value += UInt32(green * 255) << 8
		   value += UInt32(blue  * 255)
		   return value
	}
	///  Returns a UIColor from a UInt32 value
	/// - Parameter hex: UInt32 value  to convert to a color
	/// - Returns: UIColor
	convenience init(hex: UInt32) {
		let red = CGFloat((hex & 0xFF0000) >> 16)
		let green = CGFloat((hex & 0x00FF00) >> 8)
		let blue = CGFloat((hex & 0x0000FF))
		self.init(red: red/255.0, green: green/255.0, blue: blue/255.0, alpha: 1.0)
	}
}
