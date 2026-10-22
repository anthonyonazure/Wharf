//
//  CommandBarWindowController.swift
//  Wharf
//
//  Shows the Command Bar: a borderless, non-activating panel centered near
//  the top of the screen under the pointer, styled like the Start Menu
//  (dock glass, the dock's tint, 12 point continuous corners). Being
//  non-activating is what lets menu commands and snaps land on the app the
//  user was in. See CommandBarService for the logic.
//

import AppKit
import Carbon
import Combine
import SwiftUI

final class CommandBarWindowController: NSWindowController {
    static let shared = CommandBarWindowController()

    private let service = CommandBarService.shared
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private let panelSize = NSSize(width: 640, height: 480)

    private init() {
        let panel = CommandBarPanel()
        panel.contentViewController = NSHostingController(rootView: CommandBarView())
        panel.setContentSize(NSSize(width: 640, height: 480))
        super.init(window: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func start() {
        service.start()
        service.$isPresented
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPresented in
                isPresented ? self?.present() : self?.hide()
            }
            .store(in: &cancellables)
    }

    private func present() {
        guard let panel = window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = CGPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.maxY - visible.height * 0.18 - panelSize.height
            )
            panel.setFrame(CGRect(origin: origin, size: panelSize).integral, display: true)
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private func hide() {
        removeMonitors()
        window?.orderOut(nil)
    }

    /// Arrows, Return, Tab and Escape are taken before the text field sees
    /// them; everything else is typed into the field.
    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.service.cancel()
            case kVK_DownArrow:
                self.service.moveSelection(by: 1)
            case kVK_UpArrow:
                self.service.moveSelection(by: -1)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.service.runSelected()
            case kVK_Tab:
                self.service.toggleActions()
            default:
                return event
            }
            return nil
        }

        let dismissIfOutside: () -> Void = { [weak self] in
            guard let self, let panel = self.window, panel.isVisible,
                  !panel.frame.contains(NSEvent.mouseLocation) else { return }
            DispatchQueue.main.async { self.service.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            dismissIfOutside()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            dismissIfOutside()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.service.dismiss()
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, localClickMonitor, globalClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        localClickMonitor = nil
        globalClickMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

private final class CommandBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Shadows come from SwiftUI, as in the Start Menu, to avoid the
        // hairline AppKit draws around a transparent panel.
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    }

    /// Spotlight's pattern: key for typing without activating Wharf.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct CommandBarView: View {
    @ObservedObject private var service = CommandBarService.shared
    @Bindable private var preferences = DockyPreferences.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                field
                if !service.results.isEmpty || service.showsActions {
                    Divider()
                    if service.showsActions, let result = service.selectedResult {
                        actionList(for: result)
                    } else {
                        resultList
                    }
                    Divider()
                    footer
                }
            }
            .background {
                // Same layering as the dock chrome and the Start Menu so the
                // bar follows the user's tint color and opacity.
                Color.clear
                    .dockyGlass(in: shape)
                    .overlay {
                        shape.fill(Color(nsColor: preferences.effectiveWindowTintColor))
                            .opacity(preferences.effectiveWindowTintOpacity)
                    }
                    .dockyGlassBorder(in: shape)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear { fieldFocused = true }
        .onChange(of: service.isPresented) { presented in
            if presented { fieldFocused = true }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 17, weight: .medium))
            TextField("Search apps, windows, files and commands, or type a sum", text: $service.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($fieldFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(service.results.enumerated()), id: \.element.id) { index, result in
                        row(result, selected: index == service.selectedIndex)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { service.run(result) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .onChange(of: service.selectedIndex) { index in
                guard service.results.indices.contains(index) else { return }
                proxy.scrollTo(service.results[index].id)
            }
        }
    }

    private func row(_ result: CommandBarResult, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: result.symbolName ?? "questionmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 14, weight: result.kind == .calculation || result.kind == .conversion ? .semibold : .regular))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let accessory = result.accessory {
                Text(accessory)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(result.kind.label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : .clear)
        }
    }

    private func actionList(for result: CommandBarResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions for \(result.title)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            ForEach(Array(result.actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 10) {
                    Image(systemName: action.symbolName)
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text(action.title)
                        .font(.system(size: 14))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(index == service.actionIndex ? Color.accentColor.opacity(0.28) : .clear)
                }
                .contentShape(Rectangle())
                .onTapGesture { service.run(result, actionAt: index) }
            }
        }
        .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            hint("Return", service.showsActions ? "Run" : "Open")
            hint("Tab", service.showsActions ? "Back" : "Actions")
            hint("Esc", "Close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}
