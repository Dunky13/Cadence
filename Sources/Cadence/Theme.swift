import AppKit
import SwiftUI
import LaunchCore

enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.93, green: 0.55, blue: 0.36, alpha: 1)
            : NSColor(red: 0.69, green: 0.29, blue: 0.13, alpha: 1)
    })
    static let green = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.37, green: 0.74, blue: 0.53, alpha: 1)
            : NSColor(red: 0.15, green: 0.43, blue: 0.29, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let separator = Color.primary.opacity(0.08)
}

extension JobStatus {
    var title: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .disabled: return "Disabled"
        case .unloaded: return "Not loaded"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .running: return Theme.green
        case .waiting: return .secondary
        case .disabled: return .secondary
        case .unloaded: return Theme.accent
        case .unknown: return .orange
        }
    }
}

struct StatusLabel: View {
    let job: LaunchJob
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(job.status.color).frame(width: 5, height: 5)
            Text(job.status.title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(job.status.color)
        .accessibilityElement(children: .combine)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.1)
            .foregroundStyle(.secondary)
    }
}

struct EmptyMessage: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
                .padding(.bottom, 3)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
