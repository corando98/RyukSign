//
//  InstallHistory.swift
//  RyukSign
//
//  Created by Ryuk
//

import Foundation

/// The apps RyukSign has installed on this device. iOS won't tell a
/// sandboxed app what else is installed, so this is what device updates
/// are checked against when there's no pairing connection.
@MainActor
enum InstallHistory {
	struct Entry: Codable {
		/// The installed bundle identifier, which signing may have changed.
		let identifier: String
		let originalIdentifier: String?
		let name: String?
		let version: String
		let date: Date
	}

	private static let _key = "RyukSign.installHistory"

	static var entries: [Entry] {
		guard
			let data = UserDefaults.standard.data(forKey: _key),
			let entries = try? JSONDecoder().decode([Entry].self, from: data)
		else {
			return []
		}
		return entries
	}

	static func record(_ app: AppInfoPresentable) {
		guard let identifier = app.identifier, let version = app.version else { return }

		let entry = Entry(
			identifier: identifier,
			originalIdentifier: app.originalIdentifier,
			name: app.name,
			version: version,
			date: Date()
		)
		_save(entries.filter { $0.identifier != identifier } + [entry])
	}

	/// Drops apps that are no longer installed.
	static func remove(_ identifiers: Set<String>) {
		guard !identifiers.isEmpty else { return }
		_save(entries.filter { !identifiers.contains($0.identifier) })
	}

	private static func _save(_ entries: [Entry]) {
		guard let data = try? JSONEncoder().encode(entries) else { return }
		UserDefaults.standard.set(data, forKey: _key)
	}
}
