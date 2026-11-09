//
//  DiscoverCellViews.swift
//  RyukSign
//

import SwiftUI
import AltSourceKit
import NukeUI

// MARK: - Card
/// A carousel card: large icon, name, blurb and the get button.
struct DiscoverCardView: View {
	let item: DiscoverItem
	var showsWeeklyDownloads = false

	private var _footnote: String {
		if showsWeeklyDownloads, let recent = item.downloads?.recent {
			return .localized("%@ this week", arguments: recent.formatted(.number.notation(.compactName)))
		}
		return item.sourceName
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top) {
				DiscoverIconView(url: item.app.iconURL, size: 60)
				Spacer(minLength: 8)
				DiscoverBadgeView(item: item)
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(item.app.currentName)
					.font(.headline)
					.lineLimit(1)
				Text(item.app.currentDescription ?? item.sourceName)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(2, reservesSpace: true)
			}

			HStack {
				Text(_footnote)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Spacer(minLength: 8)
				DownloadButtonView(app: item.app)
			}
		}
		.padding(14)
		.frame(width: 250)
		.background(
			RoundedRectangle(cornerRadius: 20, style: .continuous)
				.fill(Color(.secondarySystemBackground))
		)
		.contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
	}
}

// MARK: - Row
struct DiscoverRowView: View {
	let item: DiscoverItem

	private var _subtitle: String {
		let downloads = item.downloads.map {
			String.localized("%@ downloads", arguments: $0.total.formatted(.number.notation(.compactName)))
		}
		return [item.app.currentVersion, item.app.developer ?? item.sourceName, downloads]
			.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: " • ")
	}

	var body: some View {
		HStack(spacing: 14) {
			DiscoverIconView(url: item.app.iconURL, size: 58)

			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(item.app.currentName)
						.font(.headline)
						.lineLimit(1)
					if item.isNew {
						DiscoverBadgeView(item: item)
					}
				}
				Text(_subtitle)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				if let blurb = item.app.currentDescription {
					Text(blurb)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}

			Spacer(minLength: 8)
			DownloadButtonView(app: item.app)
		}
		.contentShape(Rectangle())
	}
}

// MARK: - Pieces
struct DiscoverBadgeView: View {
	let item: DiscoverItem

	private static let _relative: RelativeDateTimeFormatter = {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .short
		return formatter
	}()

	var body: some View {
		if item.isNew {
			Text(.localized("NEW"))
				.font(.caption2.weight(.heavy))
				.padding(.horizontal, 7)
				.padding(.vertical, 3)
				.foregroundStyle(.white)
				.background(Capsule().fill(Color.accentColor))
		} else if let date = item.date {
			Text(Self._relative.localizedString(for: date, relativeTo: Date()))
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
	}
}

struct DiscoverIconView: View {
	let url: URL?
	let size: CGFloat

	var body: some View {
		if let url {
			LazyImage(url: url) { state in
				if let image = state.image {
					image.appIconStyle(size: size)
				} else {
					_placeholder
				}
			}
			.frame(width: size, height: size)
		} else {
			_placeholder
		}
	}

	private var _placeholder: some View {
		Image("App_Unknown").appIconStyle(size: size)
	}
}
