import PortKeeperCore
import SwiftUI

struct ProfileDraft: Identifiable {
    let id = UUID()
    let originalName: String?
    var name: String
    var selectedTunnels: Set<String>
    var selectedGateways: Set<String>

    init(profile: Profile, originalName: String?) {
        self.originalName = originalName
        self.name = profile.name
        self.selectedTunnels = Set(profile.tunnels)
        self.selectedGateways = Set(profile.gateways)
    }

    static func newProfile(existing: [Profile]) -> ProfileDraft {
        let names = Set(existing.map(\.name))
        var name = "profile"
        var suffix = 2
        while names.contains(name) {
            name = "profile-\(suffix)"
            suffix += 1
        }
        return ProfileDraft(profile: Profile(name: name), originalName: nil)
    }

    func toProfile() throws -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DraftError("Profile name is required.")
        }
        guard !selectedTunnels.isEmpty || !selectedGateways.isEmpty else {
            throw DraftError("Pick at least one tunnel or gateway.")
        }
        return Profile(name: trimmed, tunnels: selectedTunnels.sorted(), gateways: selectedGateways.sorted())
    }
}

struct ProfileEditorSheet: View {
    @Binding var draft: ProfileDraft
    let tunnels: [TunnelConfig]
    let gatewayNames: [String]
    let existingProfileNames: [String]
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.originalName == nil ? "New Profile" : "Edit Profile")
                    .font(.system(size: 16, weight: .bold))
                Text("One click in the menu starts or stops everything in the profile.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Name")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    TextField("lab", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                if let nameProblem {
                    GridRow {
                        Color.clear.frame(width: 70, height: 1)
                        Label(nameProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    tunnelsSection
                    if !gatewayNames.isEmpty {
                        gatewaysSection
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            HStack(spacing: 10) {
                if draft.originalName != nil {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Text(selectionSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Validation & summary

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        if trimmedName.isEmpty {
            return "A name is required."
        }
        let taken = existingProfileNames.contains { $0 == trimmedName && $0 != draft.originalName }
        return taken ? "A profile named “\(trimmedName)” already exists." : nil
    }

    private var canSave: Bool {
        nameProblem == nil && !(draft.selectedTunnels.isEmpty && draft.selectedGateways.isEmpty)
    }

    private var selectionSummary: String {
        let tunnelCount = draft.selectedTunnels.count
        let gatewayCount = draft.selectedGateways.count
        if tunnelCount == 0 && gatewayCount == 0 {
            return "Select tunnels to include."
        }
        var parts: [String] = []
        if tunnelCount > 0 {
            parts.append("\(tunnelCount) tunnel\(tunnelCount == 1 ? "" : "s")")
        }
        if gatewayCount > 0 {
            parts.append("\(gatewayCount) gateway\(gatewayCount == 1 ? "" : "s")")
        }
        return "Includes " + parts.joined(separator: " and ") + "."
    }

    /// Gateways that selected tunnels route through (start implicitly anyway).
    private var impliedGateways: Set<String> {
        Set(tunnels.filter { draft.selectedTunnels.contains($0.name) }.compactMap(\.gateway))
    }

    // MARK: - Sections

    private var tunnelsSection: some View {
        sectionBox(
            title: "Tunnels",
            selectedCount: draft.selectedTunnels.count,
            totalCount: tunnels.count,
            onAll: { draft.selectedTunnels = Set(tunnels.map(\.name)) },
            onNone: { draft.selectedTunnels = [] }
        ) {
            if tunnels.isEmpty {
                Text("No tunnels configured yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tunnels) { tunnel in
                    selectableRow(
                        isSelected: draft.selectedTunnels.contains(tunnel.name),
                        title: tunnel.name,
                        subtitle: tunnelSubtitle(tunnel),
                        badge: tunnel.gateway.map { "via \($0)" }
                    ) {
                        toggle(tunnel.name, in: &draft.selectedTunnels)
                    }
                }
            }
        }
    }

    private var gatewaysSection: some View {
        sectionBox(
            title: "VPN Gateways",
            selectedCount: draft.selectedGateways.count,
            totalCount: gatewayNames.count,
            onAll: { draft.selectedGateways = Set(gatewayNames) },
            onNone: { draft.selectedGateways = [] }
        ) {
            Text("Gateways start automatically with their tunnels — include one here only so the profile also stops it.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.bottom, 2)
            ForEach(gatewayNames, id: \.self) { name in
                selectableRow(
                    isSelected: draft.selectedGateways.contains(name),
                    title: name,
                    subtitle: nil,
                    badge: impliedGateways.contains(name) ? "auto-starts with selected tunnels" : nil
                ) {
                    toggle(name, in: &draft.selectedGateways)
                }
            }
        }
    }

    private func tunnelSubtitle(_ tunnel: TunnelConfig) -> String {
        let route = tunnel.forwards.first.map { forward -> String in
            switch forward.kind {
            case .local: return "\(forward.listenPort) → \(forward.destinationPort.map(String.init) ?? "?")"
            case .remote: return "remote \(forward.listenPort)"
            case .dynamic: return "SOCKS \(forward.listenPort)"
            }
        } ?? ""
        return route.isEmpty ? tunnel.host : "\(tunnel.host) · \(route)"
    }

    private func toggle(_ item: String, in set: inout Set<String>) {
        if set.contains(item) {
            set.remove(item)
        } else {
            set.insert(item)
        }
    }

    // MARK: - Building blocks

    private func sectionBox<Content: View>(
        title: String,
        selectedCount: Int,
        totalCount: Int,
        onAll: @escaping () -> Void,
        onNone: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                Text("\(selectedCount)/\(totalCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if totalCount > 1 {
                    Button("All", action: onAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.burrowAccent)
                    Button("None", action: onNone)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.burrowAccent)
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Whole-row click target with checkmark, context line, and badge.
    private func selectableRow(
        isSelected: Bool,
        title: String,
        subtitle: String?,
        badge: String?,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.burrowAccent : Color.secondary.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(isSelected ? 0.92 : 0.75))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.burrowAccentHalo.opacity(0.45) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
