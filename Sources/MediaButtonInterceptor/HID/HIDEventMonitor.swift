import Foundation
import IOKit.hid

final class HIDEventMonitor {
    var onButtonEvent: ((ButtonEvent) -> Bool)?
    var onLog: ((String) -> Void)?
    var onDevicesChanged: (([HIDDeviceSummary]) -> Void)?

    private var manager: IOHIDManager?
    private var configuration = AppConfiguration()
    private var deviceSummaries: [UInt: HIDDeviceSummary] = [:]
    private var exclusiveDevices: [UInt: IOHIDDevice] = [:]

    func start(configuration: AppConfiguration) {
        stop()

        guard configuration.enableHIDMonitor else {
            return
        }

        self.configuration = configuration

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        IOHIDManagerSetDeviceMatchingMultiple(manager, Self.matchingDictionaries() as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchingCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovalCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        onLog?("HID manager open result: \(openResult)")
        refreshConnectedDevices()
    }

    func stop() {
        for (_, device) in exclusiveDevices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }

        exclusiveDevices.removeAll()
        deviceSummaries.removeAll()

        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        manager = nil
        onDevicesChanged?([])
    }

    private func refreshConnectedDevices() {
        guard let manager else {
            onDevicesChanged?([])
            return
        }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            onDevicesChanged?([])
            return
        }

        for device in devices {
            register(device: device)
        }

        publishDeviceSummaries()
    }

    private func register(device: IOHIDDevice) {
        let key = Self.deviceKey(device)
        let summary = Self.summary(for: device, isExclusive: exclusiveDevices[key] != nil)
        deviceSummaries[key] = summary
        onLog?(
            "HID device discovered: product=\(summary.productName) manufacturer=\(summary.manufacturer.isEmpty ? "-" : summary.manufacturer) transport=\(summary.transport.isEmpty ? "-" : summary.transport) vendor=\(summary.vendorID) productID=\(summary.productID) targeted=\(shouldTarget(summary: summary) ? "yes" : "no")"
        )

        if configuration.enableExclusiveBoseCapture, shouldTarget(summary: summary), exclusiveDevices[key] == nil {
            IOHIDDeviceRegisterInputValueCallback(device, Self.inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if result == kIOReturnSuccess {
                exclusiveDevices[key] = device
                deviceSummaries[key] = Self.summary(for: device, isExclusive: true)
                onLog?("Exclusive HID capture enabled for \(summary.productName)")
            } else {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                onLog?("Exclusive HID capture failed for \(summary.productName) with status \(result)")
            }
        }
    }

    private func unregister(device: IOHIDDevice) {
        let key = Self.deviceKey(device)

        if let exclusive = exclusiveDevices.removeValue(forKey: key) {
            IOHIDDeviceUnscheduleFromRunLoop(exclusive, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(exclusive, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }

        deviceSummaries.removeValue(forKey: key)
        publishDeviceSummaries()
    }

    private func handleInput(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let integerValue = IOHIDValueGetIntegerValue(value)
        let deviceKey = Self.deviceKey(device)
        let summary = deviceSummaries[deviceKey] ?? Self.summary(for: device, isExclusive: false)

        guard shouldTarget(summary: summary) else {
            return
        }

        let route: InputSourceRoute = exclusiveDevices[deviceKey] == nil ? .hid : .hidExclusive
        guard let event = InputEventDecoding.decodeHID(
            usagePage: usagePage,
            usage: usage,
            value: integerValue,
            deviceName: summary.productName,
            route: route
        ) else {
            if Self.shouldLogUnknownUsage(page: usagePage, usage: usage) {
                onLog?(
                    "Observed unknown HID usage from \(summary.productName): route=\(route.rawValue) usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(integerValue)"
                )
            }
            return
        }

        onLog?(
            "Observed HID event: button=\(event.button.displayName) state=\(event.isDown ? "down" : "up") route=\(route.rawValue) raw={\(event.rawDescription)} device=\(summary.productName)"
        )
        let shouldConsume = onButtonEvent?(event) ?? false
        if shouldConsume, exclusiveDevices[deviceKey] != nil, event.isDown {
            onLog?("Exclusive HID event consumed: \(event.button.displayName) from \(summary.productName)")
        }
    }

    private func shouldTarget(summary: HIDDeviceSummary) -> Bool {
        let filter = configuration.boseNameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else {
            return true
        }

        let haystack = "\(summary.manufacturer) \(summary.productName) \(summary.transport)"
        return haystack.localizedCaseInsensitiveContains(filter)
    }

    private func publishDeviceSummaries() {
        let summaries = deviceSummaries.values.sorted { left, right in
            left.productName.localizedCaseInsensitiveCompare(right.productName) == .orderedAscending
        }
        onDevicesChanged?(summaries)
    }

    private static func matchingDictionaries() -> [[String: Int]] {
        [
            [
                kIOHIDDeviceUsagePageKey as String: Int(kHIDPage_Consumer),
                kIOHIDDeviceUsageKey as String: Int(kHIDUsage_Csmr_ConsumerControl)
            ],
            [
                kIOHIDDeviceUsagePageKey as String: Int(kHIDPage_GenericDesktop),
                kIOHIDDeviceUsageKey as String: Int(kHIDUsage_GD_SystemControl)
            ],
            [
                kIOHIDDeviceUsagePageKey as String: Int(kHIDPage_Telephony),
                kIOHIDDeviceUsageKey as String: Int(kHIDUsage_Tfon_Phone)
            ]
        ]
    }

    private static func summary(for device: IOHIDDevice, isExclusive: Bool) -> HIDDeviceSummary {
        let productName = stringProperty(device: device, key: kIOHIDProductKey as CFString)
        let manufacturer = stringProperty(device: device, key: kIOHIDManufacturerKey as CFString)
        let transport = stringProperty(device: device, key: kIOHIDTransportKey as CFString)
        let vendorID = intProperty(device: device, key: kIOHIDVendorIDKey as CFString)
        let productID = intProperty(device: device, key: kIOHIDProductIDKey as CFString)

        return HIDDeviceSummary(
            id: "\(vendorID):\(productID):\(productName):\(transport)",
            productName: productName.isEmpty ? "Unknown HID Device" : productName,
            manufacturer: manufacturer,
            transport: transport,
            vendorID: vendorID,
            productID: productID,
            isExclusive: isExclusive
        )
    }

    private static func stringProperty(device: IOHIDDevice, key: CFString) -> String {
        guard let value = IOHIDDeviceGetProperty(device, key) else {
            return ""
        }

        if let stringValue = value as? String {
            return stringValue
        }

        return ""
    }

    private static func intProperty(device: IOHIDDevice, key: CFString) -> Int {
        guard let value = IOHIDDeviceGetProperty(device, key) else {
            return 0
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return 0
    }

    private static func deviceKey(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private static func shouldLogUnknownUsage(page: Int, usage: Int) -> Bool {
        switch page {
        case 0x01, 0x0B, 0x0C:
            return usage != 0
        default:
            return false
        }
    }

    private static let deviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<HIDEventMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.register(device: device)
        monitor.publishDeviceSummaries()
    }

    private static let deviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<HIDEventMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.unregister(device: device)
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let monitor = Unmanaged<HIDEventMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handleInput(value: value)
    }
}
