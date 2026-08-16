//
//  LayoutRulesSettingsView.swift
//  Wharf
//
//  Rules that fire a saved layout on their own.
//

import SwiftUI

struct LayoutRulesSettingsView: View {
    @ObservedObject private var engine = LayoutTriggerEngine.shared
    @ObservedObject private var layouts = WorkspaceLayoutService.shared

    @State private var selectedLayout = ""
    @State private var triggerKind = TriggerKind.timeOfDay
    @State private var hour = 8
    @State private var minute = 0
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var minutesBefore = 5
    @State private var appBundleID = ""
    @State private var launchesMissingApps = true

    private enum TriggerKind: String, CaseIterable, Identifiable {
        case timeOfDay, beforeEvent, appActivated, displayChanged
        var id: String { rawValue }
        var title: String {
            switch self {
            case .timeOfDay: "At a time of day"
            case .beforeEvent: "Before a calendar event"
            case .appActivated: "When an app comes forward"
            case .displayChanged: "When displays change"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                if engine.rules.isEmpty {
                    Text("No rules yet. A rule restores one of your saved layouts automatically, so the desk rearranges itself when the day moves on instead of when you remember to.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } else {
                    ForEach(engine.rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.layoutName).font(.headline)
                                Text(rule.trigger.describedInPlainEnglish)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { newValue in
                                    var updated = rule
                                    updated.isEnabled = newValue
                                    engine.update(updated)
                                }
                            ))
                            .labelsHidden()
                            Button("Delete", role: .destructive) { engine.delete(rule) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Rules")
            }

            Section {
                if layouts.layouts.isEmpty {
                    Text("Save a layout first, in the Layouts pane.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Layout", selection: $selectedLayout) {
                        ForEach(layouts.layouts) { layout in
                            Text(layout.name).tag(layout.name)
                        }
                    }

                    Picker("When", selection: $triggerKind) {
                        ForEach(TriggerKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    switch triggerKind {
                    case .timeOfDay:
                        HStack {
                            Stepper("Hour: \(hour)", value: $hour, in: 0...23)
                            Stepper("Minute: \(minute)", value: $minute, in: 0...59)
                        }
                        weekdayPicker
                    case .beforeEvent:
                        Stepper("Minutes before: \(minutesBefore)", value: $minutesBefore, in: 1...60)
                    case .appActivated:
                        TextField("Bundle identifier (e.g. com.microsoft.VSCode)", text: $appBundleID)
                            .textFieldStyle(.roundedBorder)
                    case .displayChanged:
                        Text("Fires when a monitor is connected or disconnected, after things settle.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Launch missing apps first", isOn: $launchesMissingApps)

                    Button("Add Rule", action: addRule)
                        .disabled(selectedLayout.isEmpty && layouts.layouts.isEmpty)
                }
            } header: {
                Text("New Rule")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if selectedLayout.isEmpty { selectedLayout = layouts.layouts.first?.name ?? "" }
        }
    }

    @ViewBuilder
    private var weekdayPicker: some View {
        HStack {
            ForEach(1...7, id: \.self) { day in
                let symbols = Calendar.current.shortWeekdaySymbols
                Toggle(symbols[day - 1], isOn: Binding(
                    get: { weekdays.contains(day) },
                    set: { on in
                        if on { weekdays.insert(day) } else { weekdays.remove(day) }
                    }
                ))
                .toggleStyle(.button)
            }
        }
    }

    private func addRule() {
        let name = selectedLayout.isEmpty ? (layouts.layouts.first?.name ?? "") : selectedLayout
        guard !name.isEmpty else { return }

        let trigger: LayoutTrigger = switch triggerKind {
        case .timeOfDay: .timeOfDay(hour: hour, minute: minute, weekdays: weekdays.sorted())
        case .beforeEvent: .beforeCalendarEvent(minutesBefore: minutesBefore)
        case .appActivated: .appActivated(bundleIdentifier: appBundleID.trimmingCharacters(in: .whitespaces))
        case .displayChanged: .displayConfigurationChanged
        }

        if case let .appActivated(bundleID) = trigger, bundleID.isEmpty { return }

        engine.add(
            LayoutRule(
                id: UUID().uuidString,
                layoutName: name,
                trigger: trigger,
                isEnabled: true,
                launchesMissingApps: launchesMissingApps
            )
        )
    }
}
