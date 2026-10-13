//
//  KeychainHelper.swift
//  Pangea
//
//  Copyright(c) Garth Vander Houwen 6/17/25.
//
import Foundation
import Security

class KeychainHelper {

	static let standard = KeychainHelper()

	/// The start of every radio private key's keychain key (Settings → Security backs them up);
	/// Clear App Data removes the ones not synced through iCloud Keychain.
	static let privateKeyPrefix = "PrivateKeyNode"

	private init() {}

	func save(
		key: String,
		value: String,
		service: String = Bundle.main.bundleIdentifier!,
		accessibility: CFString = kSecAttrAccessibleWhenUnlocked,
		synchronizable: Bool = true
	) -> OSStatus {
		let data = value.data(using: .utf8)!

		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
			kSecValueData as String: data,
			kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
			kSecAttrAccessible as String: accessibility
		]

		// Match the deletion scope to the write scope so save-with-synchronizable=false
		// doesn't leave a stale synchronizable=true item behind.
		let deleteQuery: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
			kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
		]
		SecItemDelete(deleteQuery as CFDictionary)

		let status = SecItemAdd(query as CFDictionary, nil)
		return status
	}

	func read(
		key: String,
		service: String = Bundle.main.bundleIdentifier!,
		synchronizable: Bool = true
	) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
			kSecReturnData as String: kCFBooleanTrue!,
			kSecMatchLimit as String: kSecMatchLimitOne,
			kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
		]

		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)

		if status == errSecSuccess {
			if let data = item as? Data {
				return String(data: data, encoding: .utf8)
			}
		}
		return nil
	}

	func delete(
		key: String,
		service: String = Bundle.main.bundleIdentifier!,
		synchronizable: Bool = true
	) -> OSStatus {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
			kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
		]

		let status = SecItemDelete(query as CFDictionary)
		return status
	}

	/// Deletes every item of `service` kept on this device only whose key starts with `prefix`.
	/// Items synced through iCloud Keychain stay, as they do across a reinstall: deleting one
	/// here would delete it from the user's other devices too.
	/// - Returns: false if one of them couldn't be deleted.
	@discardableResult
	func deleteAllLocal(withPrefix prefix: String, service: String = Bundle.main.bundleIdentifier!) -> Bool {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrSynchronizable as String: kCFBooleanFalse!,
			kSecReturnAttributes as String: kCFBooleanTrue!,
			kSecMatchLimit as String: kSecMatchLimitAll
		]
		var items: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &items)
		guard status == errSecSuccess else { return status == errSecItemNotFound }
		var deletedAll = true
		for item in (items as? [[String: Any]]) ?? [] {
			guard let key = item[kSecAttrAccount as String] as? String, key.hasPrefix(prefix) else { continue }
			let deleteQuery: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: key,
				kSecAttrSynchronizable as String: kCFBooleanFalse!
			]
			let deleted = SecItemDelete(deleteQuery as CFDictionary)
			if deleted != errSecSuccess && deleted != errSecItemNotFound { deletedAll = false }
		}
		return deletedAll
	}
}
