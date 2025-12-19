import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var model: AppModel

    @AppStorage(AppSettingsKeys.showCredits) private var showCredits = true
    @AppStorage(AppSettingsKeys.maxVisibleModels) private var maxVisibleModels = 5
    @AppStorage(AppSettingsKeys.hiddenModelIdsJSON) private var hiddenModelIdsJSON = Data()

    private var snapshot: QuotaSnapshot? {
        model.snapshot
    }

    private var hiddenModelIds: Set<String> {
        guard !hiddenModelIdsJSON.isEmpty else {
            return []
        }
        if let decoded = try? JSONDecoder().decode([String].self, from: hiddenModelIdsJSON) {
            return Set(decoded)
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let message = model.lastErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isSignedIn {
                if let snapshot {
                    modelsSection(snapshot)
                } else {
                    Text(model.isRefreshing ? "Loading…" : "No data yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Sign in to show Antigravity usage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Antigravity")
                    .font(.title3)
                    .bold()

                Spacer(minLength: 12)

                Text(snapshot?.accountEmail ?? (model.isSignedIn ? "Signed in" : "Signed out"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(updatedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                if let plan = snapshot?.planLabel, !plan.isEmpty {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var updatedLabel: String {
        guard model.isSignedIn else {
            return ""
        }
        guard let date = snapshot?.timestamp else {
            return model.isRefreshing ? "Updating…" : "Not updated yet"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "Updated \(relative)"
    }

/*
    @ViewBuilder
    private func creditsSection(_ credits: PromptCredits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Credits")
                .font(.headline)

            Text("\(credits.available.formatted()) left")
                .font(.body)
                .monospacedDigit()
        }
    }
*/

    @ViewBuilder
    private func modelsSection(_ snapshot: QuotaSnapshot) -> some View {
        let pinned = model.pinnedModelId
        let filtered = snapshot.modelsSortedForDisplay.filter { quota in
            if let pinned, quota.modelId == pinned {
                return true
            }
            return !hiddenModelIds.contains(quota.modelId)
        }

        if filtered.isEmpty {
            Text("No models selected")
                .font(.subheadline)
            Text("Enable models in Settings → Advanced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let visible = Array(filtered.prefix(max(1, maxVisibleModels)))

            ForEach(visible) { quota in
                VStack(alignment: .leading, spacing: 6) {
                    Text(quota.label)
                        .font(.headline)
                        .lineLimit(1)

                    ProgressView(value: Double(quota.remainingPercent), total: 100)
                        .progressViewStyle(.linear)
                        .tint(quota.isExhausted ? .red : .teal)

                    HStack {
                        Text("\(quota.remainingPercent)% left")
                            .font(.subheadline)
                            .monospacedDigit()

                        Spacer()

                        Text(resetLabel(for: quota))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if filtered.count > visible.count {
                Text("Showing \(visible.count) of \(filtered.count) selected models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetLabel(for quota: ModelQuota) -> String {
        if let until = quota.timeUntilReset {
            return "Resets \(until)"
        }
        return ""
    }
}
