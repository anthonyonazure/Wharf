//
//  LayoutsWidgetView.swift
//  Wharf
//
//  The workspace-layout switcher, living in the dock.
//
//  Layouts only pay off if switching one is cheaper than dragging windows
//  around. A layout reachable from Settings is one nobody switches to, so the
//  switcher belongs where the pointer already is.
//

import SwiftUI

struct LayoutsWidgetView: View {
    let span: TileSpan

    @ObservedObject private var service = WorkspaceLayoutService.shared
    @State private var isShowingMenu = false
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        Button {
            isShowingMenu = true
        } label: {
            content
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingMenu, arrowEdge: .top) {
            menu
                .frame(width: 260)
                .padding(12)
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)

            VStack(spacing: 2) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: span == .one ? 16 : 20, weight: .medium))

                if span != .one {
                    Text(service.layouts.isEmpty ? "Layouts" : "\(service.layouts.count) saved")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Window Layouts")
                .font(.headline)

            if service.layouts.isEmpty {
                Text("Arrange your windows, then save the arrangement below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(service.layouts) { layout in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(layout.name)
                            Text("\(layout.placements.count) windows")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Restore") {
                            restore(layout)
                        }
                        .buttonStyle(.borderless)

                        Menu {
                            Button("Restore & Launch Missing Apps") {
                                restoreLaunching(layout)
                            }
                            Button("Overwrite with Current Windows") {
                                service.capture(name: layout.name)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                service.delete(layout)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            Divider()

            if isNaming {
                HStack {
                    TextField("Layout name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("Save Current Windows…") {
                    isNaming = true
                }
            }
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        service.capture(name: name)
        newName = ""
        isNaming = false
    }

    private func restore(_ layout: WorkspaceLayout) {
        service.restore(layout)
        isShowingMenu = false
    }

    /// Freshly launched apps have no window yet, so placement waits. Restoring
    /// immediately would move only what was already open and silently skip
    /// everything it just launched.
    private func restoreLaunching(_ layout: WorkspaceLayout) {
        isShowingMenu = false
        service.launchAndRestore(layout)
    }
}
