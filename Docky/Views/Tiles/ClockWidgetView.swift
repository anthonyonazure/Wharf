//
//  ClockWidgetView.swift
//  Wharf
//
//  Date and time in the dock, with the date brightening as the next calendar
//  event approaches.
//
//  The glow is the point. A clock tells you what time it is; it does not tell
//  you that something starts in four minutes. Encoding urgency as brightness
//  means the information arrives in peripheral vision, without reading.
//

import Combine
import SwiftUI

struct ClockWidgetView: View {
    let span: TileSpan

    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        // TimelineView rather than a Timer publisher: SwiftUI suspends it when
        // the view is off-screen or the display sleeps. An autoconnected
        // publisher keeps firing for the life of the process whether anyone is
        // looking at the clock or not.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            clockFace(now: context.date)
        }
    }

    @ViewBuilder
    private func clockFace(now: Date) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)

            VStack(spacing: 0) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: span == .one ? 13 : 16, weight: .semibold))
                    .monospacedDigit()

                if span != .one {
                    Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(dateColor(now: now))
                        .shadow(color: glowColor(now: now), radius: glowRadius(now: now))
                }
            }
            .padding(.horizontal, 4)
        }
        .help(nextEventDescription(now: now))
        .animation(.easeInOut(duration: 0.6), value: urgency(now: now))
    }

    // MARK: - Urgency

    /// 0 when nothing is close, 1 when the next event is starting.
    ///
    /// Ramps over the last 30 minutes rather than linearly across hours: an
    /// event four hours out should look identical to no event at all, or the
    /// glow becomes background noise and stops meaning anything.
    private func urgency(now: Date) -> Double {
        guard let event = calendar.nextEvent else { return 0 }
        let secondsAway = event.startDate.timeIntervalSince(now)

        // Already started, or starting now: full brightness until it is
        // clearly underway.
        guard secondsAway > 0 else {
            return secondsAway > -300 ? 1 : 0
        }

        let window: TimeInterval = 30 * 60
        guard secondsAway < window else { return 0 }
        return 1 - (secondsAway / window)
    }

    private func dateColor(now: Date) -> Color {
        let value = urgency(now: now)
        return value <= 0 ? .secondary : Color.orange.opacity(0.5 + 0.5 * value)
    }

    private func glowColor(now: Date) -> Color {
        .orange.opacity(urgency(now: now) * 0.9)
    }

    private func glowRadius(now: Date) -> CGFloat {
        urgency(now: now) * 6
    }

    private func nextEventDescription(now: Date) -> String {
        guard let event = calendar.nextEvent else { return "No upcoming events" }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return "\(event.title) — now" }
        return "\(event.title) — in \(minutes) min"
    }
}
