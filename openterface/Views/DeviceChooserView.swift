/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import SwiftUI
import AppKit

/// Sheet shown at launch when more than one free Openterface unit is connected, so the
/// user can pick the unit this window should drive. Also reachable from Control ▸ Device.
struct DeviceChooserView: View {
    @ObservedObject private var deviceSelection = DeviceSelectionManager.shared
    @State private var selectedID: String?

    let onUse: (OpenterfaceDeviceCandidate) -> Void
    let onKeepAutomatic: () -> Void

    private var selectableCandidates: [OpenterfaceDeviceCandidate] {
        deviceSelection.candidates
    }

    private func isInUse(_ candidate: OpenterfaceDeviceCandidate) -> Bool {
        deviceSelection.unitKeysInUseByOtherInstances.contains(candidate.unitKey)
            && deviceSelection.activeCandidate?.id != candidate.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select a Device")
                .font(.title2)
                .bold()

            Text("Several Openterface units are connected. Choose the one this window should use. Other units can be opened later from Control ▸ Device ▸ Open in New Instance.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(selectableCandidates) { candidate in
                    let inUse = isInUse(candidate)
                    Button(action: {
                        if !inUse { selectedID = candidate.id }
                    }) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedID == candidate.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(inUse ? .secondary : .accentColor)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: candidate.displayName)
                                        .fontWeight(.medium)
                                    if inUse {
                                        Text("(in use by another instance)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    } else if deviceSelection.activeCandidate?.id == candidate.id {
                                        Text("(current)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text(verbatim: "Video \(candidate.videoLocationID ?? "-")  ·  \(candidate.serialPortPath ?? "-")")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(selectedID == candidate.id ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(inUse)
                }
            }

            HStack {
                Button("Keep Automatic") { onKeepAutomatic() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use This Device") {
                    if let id = selectedID, let candidate = selectableCandidates.first(where: { $0.id == id }) {
                        onUse(candidate)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 480, maxWidth: 640, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if selectedID == nil {
                selectedID = deviceSelection.activeCandidate?.id
                    ?? selectableCandidates.first { !isInUse($0) }?.id
            }
        }
    }
}

/// Presents `DeviceChooserView` as a sheet on the main window.
final class DeviceChooserPresenter {
    static let shared = DeviceChooserPresenter()

    private var sheetWindow: NSWindow?
    private var didOfferAtLaunch = false
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }

    private init() {}

    /// Called once shortly after launch: offer the chooser when this instance is not pinned
    /// and at least two units are free to pick from.
    func offerAtLaunchIfNeeded() {
        guard !didOfferAtLaunch else { return }
        didOfferAtLaunch = true

        let selection = DeviceSelectionManager.shared
        guard !selection.isPinned else { return }
        let free = selection.candidates.filter { !selection.unitKeysInUseByOtherInstances.contains($0.unitKey) }
        guard free.count >= 2 else { return }

        logger.log(content: "Several free Openterface units detected (\(free.count)); showing device chooser")
        present()
    }

    func present() {
        guard sheetWindow == nil else { return }
        guard let mainWindow = NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains(UserSettings.shared.mainWindownName) == true }) else {
            logger.log(content: "Device chooser: no main window to attach to")
            return
        }

        let view = DeviceChooserView(
            onUse: { [weak self] candidate in
                DeviceSelectionManager.shared.select(candidate)
                self?.close()
            },
            onKeepAutomatic: { [weak self] in
                self?.close()
            }
        )
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = String(localized: "Select a Device")
        window.contentView = hosting
        let fitting = hosting.fittingSize
        window.setContentSize(NSSize(width: max(fitting.width, 480), height: max(fitting.height, 200)))
        window.isReleasedWhenClosed = false
        sheetWindow = window

        mainWindow.beginSheet(window) { [weak self] _ in
            self?.sheetWindow = nil
        }
    }

    private func close() {
        guard let window = sheetWindow else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        sheetWindow = nil
    }
}
