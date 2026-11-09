//
//  DiscoverCatalog.swift
//  RyukSign
//
//  Every app across the user's sources, one entry per bundle identifier.
//

import Foundation
import AltSourceKit

struct DiscoverItem: Identifiable, Hashable {
	let id: String
	let source: ASRepository
	let app: ASRepository.App
	let sourceName: String
	let isFromPinnedSource: Bool
	let category: DiscoverCategory?
	/// GitHub `owner/repo` the IPA is released from, when it is.
	let repository: String?
	let downloads: DownloadStat?

	var date: Date? { app.currentDate?.date }

	/// Listed recently with no earlier versions.
	var isNew: Bool {
		guard let date, (app.versions?.count ?? 1) <= 1 else { return false }
		return date > Date().addingTimeInterval(-DiscoverCatalog.newWindow)
	}

	func matches(_ query: String) -> Bool {
		guard !query.isEmpty else { return true }
		return [app.currentName, app.developer, app.subtitle, app.id, sourceName]
			.contains { $0?.localizedCaseInsensitiveContains(query) ?? false }
	}
}

/// Sources label categories freely ("photo-video", "EMU", "Games"), so they're
/// folded by a lowercase key and shown with a friendly name.
struct DiscoverCategory: Identifiable, Hashable {
	let id: String

	init?(_ raw: String?) {
		guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else {
			return nil
		}
		self.id = Self._aliases[key] ?? key
	}

	var title: String {
		if let known = Self._titles[id] { return known }
		return id
			.replacingOccurrences(of: "-", with: " ")
			.replacingOccurrences(of: "_", with: " ")
			.capitalized
	}

	var systemImage: String {
		Self._icons[id] ?? "square.grid.2x2"
	}

	private static let _aliases: [String: String] = [
		"emu": "emulators",
		"emulator": "emulators",
		"game": "games",
		"utility": "utilities",
		"tools": "utilities",
		"tweaked": "tweaks",
		"photo & video": "photo-video",
		"movies": "entertainment"
	]

	private static let _titles: [String: String] = [
		"developer": .localized("Developer"),
		"entertainment": .localized("Entertainment"),
		"games": .localized("Games"),
		"lifestyle": .localized("Lifestyle"),
		"other": .localized("Other"),
		"photo-video": .localized("Photo & Video"),
		"social": .localized("Social"),
		"utilities": .localized("Utilities"),
		"sideloading": .localized("Sideloading"),
		"emulators": .localized("Emulators"),
		"tweaks": .localized("Tweaks"),
		"32bit": .localized("32-bit")
	]

	private static let _icons: [String: String] = [
		"developer": "hammer",
		"entertainment": "play.tv",
		"games": "gamecontroller",
		"lifestyle": "heart",
		"other": "ellipsis.circle",
		"photo-video": "camera",
		"social": "bubble.left.and.bubble.right",
		"utilities": "wrench.and.screwdriver",
		"sideloading": "arrow.down.app",
		"emulators": "arcade.stick.console",
		"tweaks": "slider.horizontal.3",
		"ports": "shippingbox"
	]
}

enum DiscoverSort: String, CaseIterable {
	case name
	case recent
	case popular

	var title: String {
		switch self {
		case .name: .localized("Name")
		case .recent: .localized("Recently Updated")
		case .popular: .localized("Most Popular")
		}
	}

	var systemImage: String {
		switch self {
		case .name: "textformat"
		case .recent: "clock"
		case .popular: "chart.bar"
		}
	}
}

struct DiscoverCatalog {
	static let newWindow: TimeInterval = 14 * 24 * 60 * 60
	static let recentWindow: TimeInterval = 30 * 24 * 60 * 60

	let items: [DiscoverItem]
	/// Categories by app count, largest first.
	let categories: [(category: DiscoverCategory, count: Int)]

	static let empty = DiscoverCatalog(items: [], categories: [])

	init(items: [DiscoverItem], categories: [(category: DiscoverCategory, count: Int)]) {
		self.items = items
		self.categories = categories
	}

	/// Keeps the newest listing of each app. Ties go to a pinned source, then by
	/// source name, so rebuilding from the same data always gives the same result.
	@MainActor
	init(sources: [AltSource: ASRepository], pinned: PinnedSourcesManager, stats: DiscoverDownloadStats) {
		var byID: [String: DiscoverItem] = [:]

		for (source, repository) in sources {
			let sourceID = PinnedSourcesManager.identifier(for: source)
			guard !RyukSignAPI.isSourceExcluded(sourceID) else { continue }

			let isPinned = pinned.isPinned(source)
			let sourceName = repository.name ?? source.name ?? .localized("Unknown")

			for app in repository.apps where app.currentDownloadUrl != nil {
				let id = app.id.flatMap { $0.isEmpty ? nil : $0 } ?? app.currentUniqueId
				let github = DiscoverDownloadStats.repository(for: app.currentDownloadUrl)
				let item = DiscoverItem(
					id: id,
					source: repository,
					app: app,
					sourceName: sourceName,
					isFromPinnedSource: isPinned,
					category: DiscoverCategory(app.category),
					repository: github,
					downloads: stats.stat(for: github)
				)

				if let existing = byID[id], !Self._prefers(item, over: existing) {
					continue
				}
				byID[id] = item
			}
		}

		items = byID.values.sorted(by: Self._byName)

		var counts: [DiscoverCategory: Int] = [:]
		for item in items {
			if let category = item.category { counts[category, default: 0] += 1 }
		}
		categories = counts
			.map { (category: $0.key, count: $0.value) }
			.sorted { $0.count != $1.count ? $0.count > $1.count : $0.category.title < $1.category.title }
	}

	/// Newest first, from pinned sources.
	var fromPinnedSources: [DiscoverItem] {
		items.filter(\.isFromPinnedSource).sorted(by: Self._newestFirst)
	}

	/// Released or updated in the last 30 days, newest first.
	var recentlyUpdated: [DiscoverItem] {
		let cutoff = Date().addingTimeInterval(-Self.recentWindow)
		return items
			.filter { ($0.date ?? .distantPast) > cutoff }
			.sorted(by: Self._newestFirst)
	}

	/// Most downloaded in the last week. Apps sharing a GitHub repository share
	/// its count, so only the first of them is listed.
	var hot: [DiscoverItem] {
		var seen = Set<String>()
		return items
			.filter { ($0.downloads?.recent ?? 0) > 0 }
			.sorted { lhs, rhs in
				let l = lhs.downloads?.recent ?? 0, r = rhs.downloads?.recent ?? 0
				return l != r ? l > r : Self._byName(lhs, rhs)
			}
			.filter { seen.insert($0.repository ?? $0.id).inserted }
	}

	/// GitHub repositories to fetch counts for: pinned and recent apps first.
	var repositories: [String] {
		let priority = fromPinnedSources + recentlyUpdated + items
		return priority.compactMap(\.repository)
	}

	func sorted(_ items: [DiscoverItem], by sort: DiscoverSort) -> [DiscoverItem] {
		switch sort {
		case .name:
			return items
		case .recent:
			return items.sorted(by: Self._newestFirst)
		case .popular:
			// Apps without a count keep name order after the counted ones.
			return items.sorted { lhs, rhs in
				let l = lhs.downloads?.total ?? -1, r = rhs.downloads?.total ?? -1
				return l != r ? l > r : Self._byName(lhs, rhs)
			}
		}
	}

	/// Same set of apps, versions and counts, so swapping in a rebuild changes nothing on screen.
	var signature: Int {
		var hasher = Hasher()
		for item in items {
			hasher.combine(item.id)
			hasher.combine(item.app.currentVersion)
			hasher.combine(item.sourceName)
			hasher.combine(item.downloads)
		}
		return hasher.finalize()
	}

	@MainActor
	private static func _prefers(_ item: DiscoverItem, over existing: DiscoverItem) -> Bool {
		let checker = AppUpdateChecker.shared
		if checker.hasUpdate(installedVersion: existing.app.currentVersion, sourceVersion: item.app.currentVersion) {
			return true
		}
		if checker.hasUpdate(installedVersion: item.app.currentVersion, sourceVersion: existing.app.currentVersion) {
			return false
		}
		if item.isFromPinnedSource != existing.isFromPinnedSource {
			return item.isFromPinnedSource
		}
		return item.sourceName.localizedStandardCompare(existing.sourceName) == .orderedAscending
	}

	private static func _byName(_ lhs: DiscoverItem, _ rhs: DiscoverItem) -> Bool {
		switch lhs.app.currentName.localizedCaseInsensitiveCompare(rhs.app.currentName) {
		case .orderedAscending: return true
		case .orderedDescending: return false
		case .orderedSame: return lhs.id < rhs.id
		}
	}

	private static func _newestFirst(_ lhs: DiscoverItem, _ rhs: DiscoverItem) -> Bool {
		let l = lhs.date ?? .distantPast, r = rhs.date ?? .distantPast
		return l != r ? l > r : _byName(lhs, rhs)
	}
}
