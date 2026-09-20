// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

import SwiftUI

struct ContentView: View {
	@Bindable var model: Model

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if let failure = model.failure {
				Text(failure)
					.foregroundStyle(.red)
					.textSelection(.enabled)
			} else {
				controls
				Divider()
				sentences
				button
				problems
			}
		}
		.padding(20)
		.frame(width: 420, alignment: .leading)
		.navigationTitle(model.title)
	}

	/// Every entry under its own name, read out of the translation itself, so
	/// that nobody has to recognize their language written in one they cannot
	/// read yet.
	private var controls: some View {
		Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
			GridRow {
				Text(model.languageLabel)
				Picker("", selection: $model.index) {
					ForEach(Array(model.languages.enumerated()), id: \.offset) { entry in
						Text(entry.element).tag(entry.offset)
					}
				}
				.labelsHidden()
			}
			GridRow {
				Text(model.countLabel)
				// Step through 0, 1, 2, 5 and 22 with Polish chosen:
				// four different forms, and nothing in this program
				// knows there is more than one.
				Stepper(value: $model.count, in: 0...999) {
					Text(model.count.formatted())
						.monospacedDigit()
				}
				.frame(width: 120)
			}
		}
	}

	private var sentences: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(model.welcome)
			Text(model.newPhotos)
			Text(model.shared)
			Text(model.storage)
		}
		.fixedSize(horizontal: false, vertical: true)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var button: some View {
		Button(model.buttonLabel) { model.useSystemLanguage() }
			.help(model.buttonHelp)
	}

	/// What the formatting complained about, which in a finished application
	/// would go to a log and is on screen here because seeing it is the
	/// point. None of it stopped anything.
	@ViewBuilder
	private var problems: some View {
		if !model.problems.isEmpty {
			Text(model.problems.joined(separator: "\n"))
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}
