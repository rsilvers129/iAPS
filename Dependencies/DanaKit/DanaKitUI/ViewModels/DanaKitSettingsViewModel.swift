//
//  DanaKitSettingsViewModel.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 03/01/2024.
//  Copyright © 2024 Randall Knutson. All rights reserved.
//

import SwiftUI
import LoopKit
import HealthKit
import os.log

class DanaKitSettingsViewModel : ObservableObject {
    @Published var showingDeleteConfirmation = false
    @Published var showingTimeSyncConfirmation = false
    @Published var basalButtonText: String = ""
    @Published var bolusSpeed: BolusSpeed
    @Published var isUpdatingPumpState: Bool = false
    @Published var isSyncing: Bool = false
    @Published var lastSync: Date? = nil
    @Published var batteryLevel: Double = 0
    @Published var showingSilentTone: Bool = false
    @Published var silentTone: Bool = false
    @Published var basalProfile: String = "A"
    
    @Published var showPumpTimeSyncWarning: Bool = false
    @Published var pumpTime: Date? = nil
    
    @Published var reservoirLevelWarning: Double
    @Published var reservoirLevel: Double?
    @Published var isSuspended: Bool = false
    @Published var basalRate: Double?
    
    private let log = Logger(category: "SettingsView")
    private(set) var insulineType: InsulinType
    private(set) var pumpManager: DanaKitPumpManager?
    private var didFinish: (() -> Void)?
    private(set) var userOptionsView: DanaKitUserSettingsView

    public var pumpModel: String {
        self.pumpManager?.state.getFriendlyDeviceName() ?? ""
    }
    
    
    
    public var deviceName: String? {
        self.pumpManager?.state.deviceName
    }
    
    public var hardwareModel: UInt8? {
        self.pumpManager?.state.hwModel
    }
    
    public var firmwareVersion: UInt8? {
        self.pumpManager?.state.pumpProtocol
    }

    
    let basalRateFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()
    
    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()
    
    private let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }
    
    public init(_ pumpManager: DanaKitPumpManager?, _ didFinish: (() -> Void)?) {
        self.pumpManager = pumpManager
        self.didFinish = didFinish
        
        self.userOptionsView = DanaKitUserSettingsView(viewModel: DanaKitUserSettingsViewModel(self.pumpManager))
        
        self.insulineType = self.pumpManager?.state.insulinType ?? .novolog
        self.bolusSpeed = self.pumpManager?.state.bolusSpeed ?? .speed12
        self.lastSync = self.pumpManager?.state.lastStatusDate
        self.reservoirLevel = self.pumpManager?.state.reservoirLevel
        self.isSuspended = self.pumpManager?.state.isPumpSuspended ?? false
        self.pumpTime = self.pumpManager?.state.pumpTime
        self.batteryLevel = self.pumpManager?.state.batteryRemaining ?? 0
        self.silentTone = self.pumpManager?.state.useSilentTones ?? false
        self.reservoirLevelWarning = Double(self.pumpManager?.state.lowReservoirRate ?? 20)
        self.basalProfile = transformBasalProfile(self.pumpManager?.basalProfileNumber ?? 0)
        self.showPumpTimeSyncWarning = shouldShowTimeWarning(pumpTime: self.pumpTime, syncedAt: self.pumpManager?.state.pumpTimeSyncedAt)
        updateBasalRate()
        
        self.basalButtonText = self.updateBasalButtonText()
        
        self.pumpManager?.addStateObserver(self, queue: .main)
    }
    
    func stopUsingDana() {
        self.pumpManager?.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.didFinish?()
            }
        }
    }
    
    func didChangeInsulinType(_ newType: InsulinType?) {
        guard let type = newType else {
            return
        }
        
        self.pumpManager?.state.insulinType = type
        self.insulineType = type
    }
    
    func getLogs() -> String {
        return log.getDebugLogs()
    }
    
    func formatDate(_ date: Date?) -> String {
        guard let date = date else {
            return ""
        }
        
        return self.dateFormatter().string(from: date)
    }
    
    func didBolusSpeedChanged(_ bolusSpeed: BolusSpeed) {
        self.pumpManager?.state.bolusSpeed = bolusSpeed
        self.pumpManager?.notifyStateDidChange()
        self.bolusSpeed = bolusSpeed
    }
    
    func syncData() {
        guard let pumpManager = self.pumpManager else {
            return
        }
        
        DispatchQueue.main.async {
            self.isSyncing = true
        }
        
        pumpManager.syncPump { date in
            DispatchQueue.main.async {
                self.isSyncing = false
                self.lastSync = date
            }
        }
    }
    
    func syncPumpTime() {
        guard let pumpManager = self.pumpManager else {
            return
        }
        
        self.isSyncing = true
        pumpManager.syncPumpTime(completion: { error in
            self.syncData()
        })
    }
    
    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity, for: .internationalUnit()) ?? ""
    }
    
    func toggleSilentTone() {
        guard let pumpManager = self.pumpManager else {
            return
        }
        
        pumpManager.state.useSilentTones = !self.silentTone
        self.silentTone = pumpManager.state.useSilentTones
    }
    
    func suspendResumeButtonPressed() {
        self.isUpdatingPumpState = true
        
        if self.pumpManager?.state.isPumpSuspended ?? false {
            self.pumpManager?.resumeDelivery{ error in
                DispatchQueue.main.async {
                    self.basalButtonText = self.updateBasalButtonText()
                    self.isUpdatingPumpState = false
                }
                
                // Check if action failed, otherwise skip state sync
                guard error == nil else {
                    self.log.error("\(#function): failed to resume delivery. Error: \(error!.localizedDescription)")
                    return
                }
            }
            
            return
        }
        
        if self.pumpManager?.state.isTempBasalInProgress ?? false {
            // Stop temp basal
            self.pumpManager?.enactTempBasal(unitsPerHour: 0, for: 0, completion: { error in
                DispatchQueue.main.async {
                    self.basalButtonText = self.updateBasalButtonText()
                    self.isUpdatingPumpState = false
                }
                
                // Check if action failed, otherwise skip state sync
                guard error == nil else {
                    self.log.error("\(#function): failed to stop temp basal. Error: \(error!.localizedDescription)")
                    return
                }
            })
            
            return
        }
        
        self.pumpManager?.suspendDelivery(completion: { error in
            DispatchQueue.main.async {
                self.basalButtonText = self.updateBasalButtonText()
                self.isUpdatingPumpState = false
            }
            
            // Check if action failed, otherwise skip state sync
            guard error == nil else {
                self.log.error("\(#function): failed to suspend delivery. Error: \(error!.localizedDescription)")
                return
            }
        })
    }
    
    private func updateBasalButtonText() -> String {
        if self.pumpManager?.state.isPumpSuspended ?? false {
            return LocalizedString("Resume delivery", comment: "Dana settings resume delivery")
        }
        
        if self.pumpManager?.state.isTempBasalInProgress ?? false {
            return LocalizedString("Stop temp basal", comment: "Dana settings stop temp basal")
        }
        
        return LocalizedString("Suspend delivery", comment: "Dana settings suspend delivery")
    }
    
    private func shouldShowTimeWarning(pumpTime: Date?, syncedAt: Date?) -> Bool {
        guard let pumpTime = pumpTime, let syncedAt = syncedAt else {
            return false
        }
        
        // Allow a 1 min diff in time
        return abs(syncedAt.timeIntervalSince1970 - pumpTime.timeIntervalSince1970) > 60
    }
    
    private func transformBasalProfile(_ index: UInt8) -> String {
        if index == 0 {
            return "A"
        } else if index == 1 {
            return "B"
        } else if index == 2 {
            return "C"
        } else {
            return "D"
        }
    }
    
    private func updateBasalRate() {
        guard let pumpManager = self.pumpManager else {
            self.basalRate = 0
            return
        }
        
        if pumpManager.state.basalDeliveryOrdinal == .tempBasal && pumpManager.state.basalDeliveryDate + (pumpManager.state.tempBasalDuration ?? 0) < Date.now {
            self.basalRate = pumpManager.state.tempBasalUnits ?? 0
        } else {
            self.basalRate = pumpManager.currentBaseBasalRate
        }
    }
}

extension DanaKitSettingsViewModel: StateObserver {
    func stateDidUpdate(_ state: DanaKitPumpManagerState, _ oldState: DanaKitPumpManagerState) {
        self.insulineType = state.insulinType ?? .novolog
        self.bolusSpeed = state.bolusSpeed
        self.lastSync = state.lastStatusDate
        self.reservoirLevel = state.reservoirLevel
        self.isSuspended = state.isPumpSuspended
        self.pumpTime = self.pumpManager?.state.pumpTime
        self.batteryLevel = self.pumpManager?.state.batteryRemaining ?? 0
        self.silentTone = self.pumpManager?.state.useSilentTones ?? false
        self.basalProfile = transformBasalProfile(self.pumpManager?.basalProfileNumber ?? 0)
        self.showPumpTimeSyncWarning = shouldShowTimeWarning(pumpTime: self.pumpTime, syncedAt: self.pumpManager?.state.pumpTimeSyncedAt)
        updateBasalRate()
        
        self.basalButtonText = self.updateBasalButtonText()
    }
    
    func deviceScanDidUpdate(_ device: DanaPumpScan) {
        // Don't do anything here. We are not scanning for a new pump
    }
}
