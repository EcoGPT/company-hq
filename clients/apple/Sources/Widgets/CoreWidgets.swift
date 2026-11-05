import SwiftUI
import WidgetKit

// My Tasks: one visual answer, a ring of everything assigned to you, and at
// most a few lines of what you are working on.

/// A widget's name, with its symbol in the widget's colour.
struct WidgetLabel: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .widgetAccentable()
            Text(title).secondaryText().lineLimit(1)
        }
    }
}

struct MyTasksView: View {
    let entry: SummaryEntry
    let family: WidgetFamily

    var body: some View {
        SummaryContent(entry: entry) { summary in
            switch family {
            case .systemSmall: small(summary.work)
            case .systemMedium: medium(summary.work)
            default: large(summary.work)
            }
        }
        .widgetURL(family == .systemSmall ? WidgetLink.mine.url : nil)
    }

    private var label: some View {
        WidgetLabel(symbol: "checklist", title: "My tasks", tint: Palette.accent)
    }

    private func small(_ work: WidgetSummary.Work) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 14) {
                TaskRing(work: work, lineWidth: 9).frame(width: 76, height: 76)
                StatusLegend(work: work, isCompact: true)
            }
        }
    }

    private func medium(_ work: WidgetSummary.Work) -> some View {
        let doing = work.tasks.filter(\.isInProgress)
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                label
                Spacer(minLength: 0)
                TaskRing(work: work, lineWidth: 10).frame(width: 92, height: 92)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(doing.prefix(3)) { TaskLine(task: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
        }
    }

    private func large(_ work: WidgetSummary.Work) -> some View {
        let rows = Array((work.tasks.filter(\.isInProgress) + work.tasks.filter(\.isBlocked)).prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            label
            HStack(alignment: .center, spacing: 22) {
                TaskRing(work: work, lineWidth: 11).frame(width: 104, height: 104)
                StatusLegend(work: work, isCompact: false)
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { TaskLine(task: $0) }
            }
            .padding(.top, 22)
            Spacer(minLength: 0)
        }
    }
}

/// Everything assigned to you as one ring: in progress, to do, blocked —
/// the total in the middle.
private struct TaskRing: View {
    let work: WidgetSummary.Work
    let lineWidth: CGFloat

    var body: some View {
        let total = Double(max(work.total, 1))
        // Clockwise from the top: in progress, then blocked, then to do.
        let parts: [(Double, Color)] = [
            (Double(work.inProgress), Palette.accent), (Double(work.blocked), Palette.warning),
            (Double(work.open), Palette.todo),
        ]
        let gap = work.total > 1 ? 0.014 : 0
        ZStack {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                let start = parts.prefix(index).reduce(0) { $0 + $1.0 } / total
                let end = start + part.0 / total
                if part.0 > 0 {
                    Circle()
                        .trim(from: start + gap / 2, to: max(start + gap / 2, end - gap / 2))
                        .stroke(part.1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: 0) {
                Text("\(work.total)").heroText(size: lineWidth * 2.9)
            }
        }
        .padding(lineWidth / 2)
        .widgetAccentable()
    }
}

private struct StatusLegend: View {
    let work: WidgetSummary.Work
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 10) {
            row(work.inProgress, "In progress", Palette.accent)
            row(work.open, "To do", Palette.todo)
            row(work.blocked, "Blocked", Palette.warning)
        }
    }

    private func row(_ value: Int, _ title: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(value)").primaryText().monospacedDigit()
            if !isCompact { Text(title).secondaryText() }
        }
    }
}

private struct TaskLine: View {
    let task: WidgetSummary.WorkTask

    var body: some View {
        HStack(spacing: 10) {
            TaskMark(task: task)
            Link(destination: WidgetLink.task(task.id).url) {
                Text(task.title).primaryText().lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
