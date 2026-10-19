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

import Foundation
import AppKit
import IOKit

private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

/// One physical Openterface unit (video chip + control chip + its serial port) that
/// this process could attach to.
struct OpenterfaceDeviceCandidate: Identifiable {
    /// Stable identifier: the video chip location ID when available, otherwise the
    /// control chip location ID.
    let id: String
    let groupIndex: Int
    let videoDevice: USBDeviceInfo?
    let controlDevice: USBDeviceInfo?
    /// Callout path of the serial port that belongs to the control chip, resolved via IOKit.
    let serialPortPath: String?

    var videoLocationID: String? { videoDevice?.locationID }
    var controlLocationID: String? { controlDevice?.locationID }

    /// Short hub/port identifier such as "0x1134" – readable but still unique per port.
    var shortLocation: String {
        DeviceSelectionManager.shortLocationID(videoLocationID ?? controlLocationID ?? id)
    }

    /// Human readable label used in menus and pickers, e.g. "#1 Openterface (0x1134)".
    var displayName: String {
        let name = videoDevice?.productName ?? controlDevice?.productName ?? "Openterface"
        return "#\(groupIndex + 1) \(name) (\(shortLocation))"
    }

    /// Compact label appended to the window title, e.g. "#1 0x1134".
    var titleLabel: String {
        "#\(groupIndex + 1) \(shortLocation)"
    }
}

extension OpenterfaceDeviceCandidate: Equatable {
    static func == (lhs: OpenterfaceDeviceCandidate, rhs: OpenterfaceDeviceCandidate) -> Bool {
        lhs.id == rhs.id &&
        lhs.groupIndex == rhs.groupIndex &&
        lhs.videoLocationID == rhs.videoLocationID &&
        lhs.controlLocationID == rhs.controlLocationID &&
        lhs.serialPortPath == rhs.serialPortPath
    }
}

/// Tracks which Openterface unit this process is bound to.
///
/// Each process serves exactly one device. By default (no pin) the legacy behaviour is kept:
/// the first detected device group wins. A pin can come from the launch arguments
/// (`--video-location 0x00113400 --serial /dev/cu.usbmodem113201`) or from the UI
/// (Control ▸ Device menu, Settings ▸ Device & Connection). The pin is deliberately
/// held in memory only: `UserDefaults` is shared by every instance of the app, so
/// persisting it would make all instances fight over the same unit.
final class DeviceSelectionManager: ObservableObject {
    static let shared = DeviceSelectionManager()

    static let selectionDidChange = Notification.Name("DeviceSelectionDidChange")

    static let videoLocationArgument = "--video-location"
    static let serialPathArgument = "--serial"

    /// Device groups detected by the last USB scan, in a UI friendly form.
    @Published private(set) var candidates: [OpenterfaceDeviceCandidate] = []
    /// Location ID ("0x%08x") of the video chip this process is pinned to, if any.
    @Published private(set) var pinnedVideoLocationID: String?
    /// Serial port callout path this process is pinned to, if any.
    @Published private(set) var pinnedSerialPortPath: String?

    // Copies of the pins that can be read safely from background queues
    // (USB rescans and the serial connection loop run off the main thread).
    private let pinLock = NSLock()
    private var pinnedVideoLocationIDSnapshot: String?
    private var pinnedSerialPortPathSnapshot: String?

    // `applyLaunchArguments` runs before the dependency container (and thus the logger)
    // is set up, so its message is kept here and emitted on the first USB scan.
    private var pendingLaunchLogMessage: String?

    private init() {}

    // MARK: - Pin state

    var isPinned: Bool {
        pinnedVideoLocationID != nil || pinnedSerialPortPath != nil
    }

    /// Candidate that matches the current pin (nil when running in automatic mode or the
    /// pinned device is not connected).
    var pinnedCandidate: OpenterfaceDeviceCandidate? {
        guard isPinned else { return nil }
        return candidates.first { isActive($0) }
    }

    /// Candidate currently driving this process: the pinned one, or the first detected
    /// group in automatic mode (mirrors `USBDevicesManager.updateChipsetTypeFlag`).
    var activeCandidate: OpenterfaceDeviceCandidate? {
        isPinned ? pinnedCandidate : candidates.first
    }

    func isActive(_ candidate: OpenterfaceDeviceCandidate) -> Bool {
        if let video = pinnedVideoLocationID {
            return candidate.videoLocationID?.lowercased() == video.lowercased()
        }
        if let serial = pinnedSerialPortPath {
            return candidate.serialPortPath == serial
        }
        return candidates.first?.id == candidate.id
    }

    /// Thread-safe accessor used by `USBDevicesManager`.
    func currentPinnedVideoLocationID() -> String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return pinnedVideoLocationIDSnapshot
    }

    /// Thread-safe accessor used by `SerialPortManager`.
    func currentPinnedSerialPortPath() -> String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return pinnedSerialPortPathSnapshot
    }

    /// Suffix appended to the main window title so that several instances can be told apart.
    var windowTitleSuffix: String {
        guard isPinned else { return "" }
        if let candidate = pinnedCandidate {
            return " [\(candidate.titleLabel)]"
        }
        if let video = pinnedVideoLocationID {
            return " [\(DeviceSelectionManager.shortLocationID(video))]"
        }
        if let serial = pinnedSerialPortPath {
            return " [\((serial as NSString).lastPathComponent)]"
        }
        return ""
    }

    private func storePins(video: String?, serial: String?) {
        pinLock.lock()
        pinnedVideoLocationIDSnapshot = video
        pinnedSerialPortPathSnapshot = serial
        pinLock.unlock()

        let publish = {
            self.pinnedVideoLocationID = video
            self.pinnedSerialPortPath = serial
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    // MARK: - Launch arguments

    /// Reads `--video-location <id>` and `--serial <path>` (also the `=` forms) from the
    /// process arguments. Must be called before the first USB scan.
    func applyLaunchArguments(_ arguments: [String] = CommandLine.arguments) {
        var video: String?
        var serial: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let next: String? = index + 1 < arguments.count ? arguments[index + 1] : nil

            if argument == DeviceSelectionManager.videoLocationArgument, let value = next {
                video = DeviceSelectionManager.normalizeLocationID(value)
                index += 1
            } else if argument.hasPrefix(DeviceSelectionManager.videoLocationArgument + "=") {
                let value = String(argument.dropFirst(DeviceSelectionManager.videoLocationArgument.count + 1))
                video = DeviceSelectionManager.normalizeLocationID(value)
            } else if argument == DeviceSelectionManager.serialPathArgument, let value = next {
                serial = value
                index += 1
            } else if argument.hasPrefix(DeviceSelectionManager.serialPathArgument + "=") {
                serial = String(argument.dropFirst(DeviceSelectionManager.serialPathArgument.count + 1))
            }
            index += 1
        }

        guard video != nil || serial != nil else { return }
        storePins(video: video, serial: serial)
        pendingLaunchLogMessage = "Device pin from launch arguments: video=\(video ?? "auto") serial=\(serial ?? "auto")"
    }

    /// Accepts "0x1134", "0x00113400", "113400" or a decimal number and returns the
    /// canonical "0x%08x" form used by `USBDeviceInfo.locationID`.
    static func normalizeLocationID(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") {
            text = String(text.dropFirst(2))
            guard let value = UInt32(text, radix: 16) else { return nil }
            return String(format: "0x%08x", value)
        }
        if let decimal = UInt32(text) {
            return String(format: "0x%08x", decimal)
        }
        if let value = UInt32(text, radix: 16) {
            return String(format: "0x%08x", value)
        }
        return nil
    }

    /// Location prefix shared by every function of one physical unit.
    ///
    /// An Openterface unit is an internal USB hub whose children differ only in the last
    /// non-zero nibble of their location ID (e.g. hub 0x00113000, serial 0x00113200,
    /// video 0x00113400). Dropping that nibble gives a key ("0x00113") that is the same for
    /// the video chip and the control chip of one unit and different for a second unit
    /// plugged into the next port (0x00114…).
    static func unitPrefix(_ locationID: String) -> String {
        var text = locationID.lowercased()
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        while text.count > 1 && text.hasSuffix("0") { text.removeLast() }
        if text.count > 1 { text.removeLast() }
        return "0x" + text
    }

    /// "0x00113400" -> "0x1134"
    static func shortLocationID(_ locationID: String) -> String {
        var text = locationID.lowercased()
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        while text.count > 1 && text.hasSuffix("0") { text.removeLast() }
        return "0x" + text
    }

    // MARK: - Candidates

    /// Rebuilds the candidate list from `AppStatus.groupOpenterfaceDevices`.
    /// Safe to call from any thread; publishing happens on the main thread.
    func refreshCandidates(using usb: USBDevicesManager) {
        if let message = pendingLaunchLogMessage {
            pendingLaunchLogMessage = nil
            logger.log(content: message)
        }
        let serialByLocation = SerialPortLocator.usbLocationIDsByCalloutPath()

        // `AppStatus.groupOpenterfaceDevices` groups by hub prefix and can merge two units
        // that sit behind the same upstream hub, so units are paired here by location instead.
        let devices = AppStatus.USBDevices
        let videos = devices
            .filter { usb.isOpenterfaceVideoChipset(vendorId: $0.vendorID, productId: $0.productID) }
            .sorted { $0.locationID.lowercased() < $1.locationID.lowercased() }
        var controls = devices
            .filter { usb.isOpenterfaceControlChipset(vendorId: $0.vendorID, productId: $0.productID) }
            .sorted { $0.locationID.lowercased() < $1.locationID.lowercased() }

        var pairs: [(video: USBDeviceInfo?, control: USBDeviceInfo?)] = []
        for video in videos {
            let prefix = DeviceSelectionManager.unitPrefix(video.locationID)
            if let index = controls.firstIndex(where: { DeviceSelectionManager.unitPrefix($0.locationID) == prefix }) {
                pairs.append((video, controls.remove(at: index)))
            } else {
                pairs.append((video, nil))
            }
        }
        // Control chips without a video chip (e.g. a unit whose capture half is not enumerated yet)
        for control in controls {
            pairs.append((nil, control))
        }

        var built: [OpenterfaceDeviceCandidate] = []
        for (index, pair) in pairs.enumerated() {
            var serialPath: String?
            if let control = pair.control {
                serialPath = serialByLocation.first { $0.value.lowercased() == control.locationID.lowercased() }?.key
            }
            let id = pair.video?.locationID ?? pair.control?.locationID ?? "unit-\(index)"
            built.append(OpenterfaceDeviceCandidate(id: id,
                                                    groupIndex: index,
                                                    videoDevice: pair.video,
                                                    controlDevice: pair.control,
                                                    serialPortPath: serialPath))
        }

        let publish = {
            if self.candidates != built {
                self.candidates = built
            }
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    // MARK: - Selection

    /// Pins this process to `candidate` and reconnects video, HID and serial.
    func select(_ candidate: OpenterfaceDeviceCandidate) {
        logger.log(content: "Device selection: pin to \(candidate.displayName) video=\(candidate.videoLocationID ?? "-") serial=\(candidate.serialPortPath ?? "-")")
        storePins(video: candidate.videoLocationID, serial: candidate.serialPortPath)
        reconnectAfterSelectionChange()
    }

    /// Clears the pin and goes back to the legacy "first detected device" behaviour.
    func selectAutomatic() {
        guard isPinned else { return }
        logger.log(content: "Device selection: back to automatic")
        storePins(video: nil, serial: nil)
        reconnectAfterSelectionChange()
    }

    private func reconnectAfterSelectionChange() {
        let run = {
            let serialPortManager = SerialPortManager.shared
            let videoManager = VideoManager.shared
            let hidManager = HIDManager.shared

            // Tear down everything bound to the previous unit.
            serialPortManager.closeSerialPort()
            hidManager.closeHID()
            videoManager.resetVideoInputsForDeviceChange()

            // Re-resolve video/control chip devices with the new pin applied.
            USBDevicesManager.shared.update()

            // Bring the new unit up.
            hidManager.startHID()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                videoManager.prepareVideo()
                serialPortManager.tryConnectOpenterface()
            }

            NotificationCenter.default.post(name: DeviceSelectionManager.selectionDidChange, object: nil)
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    // MARK: - Multi instance helpers

    /// Launches another copy of this app pinned to `candidate`.
    func openInNewInstance(_ candidate: OpenterfaceDeviceCandidate, completion: ((Error?) -> Void)? = nil) {
        var arguments: [String] = []
        if let video = candidate.videoLocationID {
            arguments += [DeviceSelectionManager.videoLocationArgument, video]
        }
        if let serial = candidate.serialPortPath {
            arguments += [DeviceSelectionManager.serialPathArgument, serial]
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments

        logger.log(content: "Launching new instance for \(candidate.displayName) with arguments \(arguments)")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error = error {
                logger.log(content: "Failed to launch new instance: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion?(error) }
        }
    }

    /// Zero-based index of this process among the running instances of the app
    /// (0 for the first/only instance). Used to cascade windows so they do not overlap.
    static func runningInstanceOrdinal() -> Int {
        guard let bundleID = Bundle.main.bundleIdentifier else { return 0 }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return instances.firstIndex { $0.processIdentifier == myPID } ?? max(instances.count - 1, 0)
    }
}

/// Maps serial port callout paths (e.g. /dev/cu.usbmodem113201) to the USB location ID
/// of the device they belong to, by walking up the IORegistry from each IOSerialBSDClient.
enum SerialPortLocator {
    static func usbLocationIDsByCalloutPath() -> [String: String] {
        var result: [String: String] = [:]
        guard let matching = IOServiceMatching("IOSerialBSDClient") else { return result }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            if let locationID = usbLocationID(startingFrom: service) {
                result[path] = locationID
            }
        }
        return result
    }

    /// USB location ID ("0x%08x") of the serial port at `calloutPath`, if it is a USB device.
    static func usbLocationID(forCalloutPath calloutPath: String) -> String? {
        usbLocationIDsByCalloutPath()[calloutPath]
    }

    private static func usbLocationID(startingFrom service: io_object_t) -> String? {
        var current: io_object_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        // IOSerialBSDClient -> AppleUSB*Data -> IOUSBHostInterface -> IOUSBHostDevice.
        // Both the interface and the device carry the same "locationID" value.
        for _ in 0..<16 {
            if let number = IORegistryEntryCreateCFProperty(current, "locationID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return String(format: "0x%08x", number.uint32Value)
            }
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }
}
