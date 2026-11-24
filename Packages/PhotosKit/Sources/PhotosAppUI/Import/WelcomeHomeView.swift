// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import SwiftUI

/// The end of an import (SPEC §15.7): "Welcome home", the number of photos and videos counting up, the albums and
/// years, whether anything was lost, the photos fanned out behind, and what was left out and why. With Reduce Motion
/// the numbers and photos simply appear.
struct WelcomeHomeView: View {
    let summary: ImportSummary
    let previews: [Data]
    let reportURL: URL?
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                fan
                    .frame(height: 190)
                    .padding(.top, 16)
                VStack(spacing: 6) {
                    Text("Welcome home", bundle: .module, comment: "Import summary: headline when the import has finished.")
                        .font(.largeTitle.bold())
                        .fontDesign(.rounded)
                    Text(shown.formatted())
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(shown)))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text(summary.headline))
                    Text("photos and videos", bundle: .module, comment: "Import summary: under the big number.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(detailLine)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                verdict
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.8)
                if summary.sources.count > 1 || summary.sources.first?.source != .files {
                    sourceChips
                }
                details
                HStack(spacing: 12) {
                    if let reportURL {
                        ShareLink(item: reportURL) {
                            Label(
                                String(localized: "Share Report…", bundle: .module, comment: "Import summary: shares the report file."),
                                systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(String(localized: "Done", bundle: .module), action: done)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                if reportURL != nil {
                    Text(
                        "The report is also in \(summary.destination) on your Nextcloud.", bundle: .module,
                        comment: "Import summary: where the uploaded report is. The value is a folder path."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .task { await countUp() }
        .sensoryFeedback(.success, trigger: appeared)
    }

    /// "312 albums · from 2004 to 2026"
    var detailLine: String {
        var parts: [String] = []
        if summary.albums > 0 {
            parts.append(String(localized: "\(summary.albums) albums", bundle: .module))
        }
        if let years = summary.years {
            parts.append(
                years.lowerBound == years.upperBound
                    ? String(localized: "from \(String(years.lowerBound))", bundle: .module)
                    : String(localized: "from \(String(years.lowerBound)) to \(String(years.upperBound))", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var verdict: some View {
        if summary.nothingLost {
            Label(
                String(localized: "Nothing lost", bundle: .module, comment: "Import summary: every photo of the exports arrived."),
                systemImage: "checkmark.seal.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.green.opacity(0.12), in: Capsule())
            .symbolEffect(.bounce, value: appeared)
        } else {
            Label(
                String(
                    localized: "\(summary.notImported) not imported — see below", bundle: .module,
                    comment: "Import summary: some items did not arrive. The value is a number."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12), in: Capsule())
        }
    }

    /// One chip per source: in a row when they fit, otherwise two per line.
    var sourceChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) { chips }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder var chips: some View {
        ForEach(summary.sources) { entry in
            Label {
                Text("\(ImportSummary.title(of: entry.source)) \(entry.count.formatted())")
                    .lineLimit(1)
            } icon: {
                Image(systemName: ImportSourceStyle.symbol(entry.source))
            }
            .font(.footnote)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                line(String(localized: "Uploaded", bundle: .module), summary.uploaded)
                line(String(localized: "Already on your Nextcloud", bundle: .module, comment: "Import summary line."), summary.alreadyThere)
                if summary.copiesInExports > 0 {
                    line(
                        String(localized: "Copies imported once", bundle: .module, comment: "Import summary line."), summary.copiesInExports
                    )
                }
                if summary.favorites > 0 { line(String(localized: "Favourites", bundle: .module), summary.favorites) }
                if summary.captions > 0 {
                    line(String(localized: "Captions kept", bundle: .module, comment: "Import summary line."), summary.captions)
                }
                if summary.metadataAdded > 0 {
                    line(
                        String(localized: "Dates and places given back", bundle: .module, comment: "Import summary line."),
                        summary.metadataAdded)
                }
                if summary.archived > 0 {
                    line(
                        String(localized: "Hidden, now in the archive", bundle: .module, comment: "Import summary line."), summary.archived)
                }
            }
            .font(.callout)
            let reasons = summary.skipped.keys.sorted()
            if !reasons.isEmpty || summary.failed > 0 {
                Divider()
                Text("Left out", bundle: .module).font(.headline)
                ForEach(reasons, id: \.self) { reason in
                    DisclosureGroup {
                        ForEach(summary.skippedExamples[reason] ?? [], id: \.self) { name in
                            Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    } label: {
                        SkipReasonLabel(reason: reason, count: summary.skipped[reason] ?? 0)
                    }
                }
                if summary.failed > 0 {
                    DisclosureGroup {
                        ForEach(summary.failures.prefix(50), id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    } label: {
                        HStack {
                            Text("Could not be uploaded", bundle: .module).font(.callout)
                            Spacer()
                            Text(summary.failed.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func line(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }
    }

    /// Up to seven of the imported photos, fanned out like prints on a table.
    var fan: some View {
        let shownPreviews = Array(previews.suffix(7))
        return ZStack {
            if shownPreviews.isEmpty {
                Image(systemName: "house.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: appeared)
            }
            ForEach(Array(shownPreviews.enumerated()), id: \.offset) { offset, data in
                let middle = Double(shownPreviews.count - 1) / 2
                let position = Double(offset) - middle
                PreviewTile(data: data)
                    .scaleEffect(0.7)
                    .rotationEffect(.degrees(appeared || reduceMotion ? position * 8 : 0))
                    .offset(x: appeared || reduceMotion ? position * 30 : 0, y: appeared || reduceMotion ? abs(position) * 8 : 40)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.35).delay(Double(offset) * 0.06), value: appeared)
            }
        }
        .accessibilityHidden(true)
    }

    /// The number counts up in about a second and a half, quickly first and slowly at the end.
    func countUp() async {
        let target = summary.home
        if reduceMotion || target == 0 {
            shown = target
            appeared = true
            return
        }
        appeared = true
        let steps = 36
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(40))
            let progress = Double(step) / Double(steps)
            let eased = 1 - pow(1 - progress, 3)
            withAnimation(.snappy(duration: 0.2)) { shown = Int((Double(target) * eased).rounded()) }
        }
        shown = target
    }
}
