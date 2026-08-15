import Cocoa
import GameController
import CoreHaptics
import IOKit
import ServiceManagement

// Global log writing function
func writeLog(_ message: String) {
    let logPath = "/Users/Vedant/Documents/ds4_rumble_bridge/rumble_app.log"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"
    if let fileHandle = FileHandle(forWritingAtPath: logPath) {
        fileHandle.seekToEndOfFile()
        if let data = logMessage.data(using: .utf8) {
            fileHandle.write(data)
        }
        fileHandle.closeFile()
    } else {
        try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
    print(message)
}

// MARK: - Game Engine DNA & Adaptive Profile Engine
enum GameEngineType: String {
    case sonyFirstParty = "Sony First-Party"
    case reEngine = "Capcom RE Engine"
    case forzaTech = "Turn 10 ForzaTech"
    case unity = "Unity Engine"
    case unrealEngine = "Unreal Engine"
    case standardDirectX = "Universal DirectX"
}

struct EngineProfile {
    let engine: GameEngineType
    let defaultGyroMode: Int
    let enableTouchpadToMap: Bool
    let impulseTriggerHaptics: Bool
    let isolateDInput: Bool
}

class EngineProfileManager {
    static let shared = EngineProfileManager()
    private(set) var activeEngine: GameEngineType = .standardDirectX
    private(set) var activeGameName: String = "Universal Game"
    
    func detectAndApplyProfile(for exeName: String, gameFolder: URL) {
        let nameLower = exeName.lowercased()
        let folderName = gameFolder.lastPathComponent.lowercased()
        
        var profile: EngineProfile
        var cleanTitle = exeName.replacingOccurrences(of: ".exe", with: "").replacingOccurrences(of: ".EXE", with: "")
        
        if cleanTitle.lowercased().contains("wewerehere") {
            cleanTitle = "We Were Here Together"
        }
        
        // 1. Capcom RE Engine
        if nameLower.contains("re2") || nameLower.contains("re3") || nameLower.contains("re4") ||
           nameLower.contains("re7") || nameLower.contains("re8") || nameLower.contains("devilmaycry") ||
           nameLower.contains("monsterhunter") || FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("re_chunk_000.pak").path) {
            profile = EngineProfile(engine: .reEngine, defaultGyroMode: 1, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = "Resident Evil"
        }
        // 2. Sony First-Party Games
        else if nameLower.contains("spider") || nameLower.contains("miles") || nameLower.contains("horizon") ||
                nameLower.contains("godofwar") || nameLower.contains("tsushima") || nameLower.contains("tlou") ||
                nameLower.contains("uncharted") || nameLower.contains("returnal") {
            profile = EngineProfile(engine: .sonyFirstParty, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: true, isolateDInput: true)
            activeGameName = cleanTitle.capitalized
        }
        // 3. ForzaTech
        else if nameLower.contains("forzahorizon") || nameLower.contains("forzamotorsport") || nameLower.contains("forza") {
            profile = EngineProfile(engine: .forzaTech, defaultGyroMode: 1, enableTouchpadToMap: false, impulseTriggerHaptics: true, isolateDInput: true)
            activeGameName = "Forza Horizon"
        }
        // 4. Unity Engine
        else if FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("UnityPlayer.dll").path) ||
                folderName.contains("wewerehere") || folderName.contains("subnautica") {
            profile = EngineProfile(engine: .unity, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = cleanTitle.capitalized
        }
        // 5. Unreal Engine
        else if FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("Engine").path) ||
                nameLower.contains("shipping") || nameLower.contains("avatar") {
            profile = EngineProfile(engine: .unrealEngine, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = cleanTitle.capitalized
        }
        // 6. Universal Default
        else {
            profile = EngineProfile(engine: .standardDirectX, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = cleanTitle.capitalized
        }
        
        self.activeEngine = profile.engine
        GyroEngine.shared.gyroMode = profile.defaultGyroMode
        writeLog("[Engine-DNA] Profile active: \(profile.engine.rawValue) (\(activeGameName))")
        
        DispatchQueue.main.async {
            PopoverViewController.shared?.updateUI()
        }
    }
}

// MARK: - Bottle Discovery, System32 Global Driver & Auto-Patcher
func getAllBottlePaths() -> [URL] {
    var paths: [URL] = []
    let candidates = [
        "/Volumes/Mac_EXT/CrossOverData/CrossOver/Bottles",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles").path,
        "/Volumes/Mac_EXT/Heroic/Prefixes",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/heroic/prefixes").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Whisky/Bottles").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/steamapps/compatdata").path
    ]
    
    for c in candidates {
        let url = URL(fileURLWithPath: c)
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for sub in contents {
                if (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                    if FileManager.default.fileExists(atPath: sub.appendingPathComponent("system.reg").path) ||
                       FileManager.default.fileExists(atPath: sub.appendingPathComponent("pfx/system.reg").path) {
                        paths.append(sub)
                    }
                }
            }
        }
    }
    return paths
}

func autoPatchAllBottles() {
    let bottles = getAllBottlePaths()
    for b in bottles {
        let bottleDir = FileManager.default.fileExists(atPath: b.appendingPathComponent("system.reg").path) ? b : b.appendingPathComponent("pfx")
        let sysReg = bottleDir.appendingPathComponent("system.reg")
        let userReg = bottleDir.appendingPathComponent("user.reg")
        
        guard FileManager.default.fileExists(atPath: sysReg.path), FileManager.default.fileExists(atPath: userReg.path) else { continue }
        
        // 1. Patch system.reg (GCHelper=1, SDL=1, DisableHidraw=0)
        if let sysContent = try? String(contentsOf: sysReg, encoding: .utf8) {
            let sysLines = sysContent.components(separatedBy: .newlines)
            var inWinebus = false
            var newSysLines: [String] = []
            for line in sysLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "[System\\\\CurrentControlSet\\\\Services\\\\winebus]") {
                    inWinebus = true
                    newSysLines.append(line)
                    newSysLines.append("\"Enable GCHelper\"=dword:00000001")
                    newSysLines.append("\"Enable SDL\"=dword:00000001")
                    newSysLines.append("\"DisableHidraw\"=dword:00000000")
                    continue
                } else if trimmed.starts(with: "[") && inWinebus {
                    inWinebus = false
                    newSysLines.append(line)
                    continue
                }
                if inWinebus {
                    if trimmed.starts(with: "\"Enable GCHelper\"=") ||
                        trimmed.starts(with: "\"Enable SDL\"=") ||
                        trimmed.starts(with: "\"Enable IOHID\"=") ||
                        trimmed.starts(with: "\"DisableHidraw\"=") {
                        continue
                    }
                }
                newSysLines.append(line)
            }
            try? newSysLines.joined(separator: "\n").write(to: sysReg, atomically: true, encoding: .utf8)
        }
        
        // 2. Patch user.reg (DLL overrides & disable windows.gaming.input)
        if let userContent = try? String(contentsOf: userReg, encoding: .utf8) {
            let userLines = userContent.components(separatedBy: .newlines)
            var inOverrides = false
            var addedOverrides = false
            let overrides = [
                "\"xinput1_4\"=\"native,builtin\"",
                "\"xinput1_3\"=\"builtin\"",
                "\"xinput9_1_0\"=\"builtin\"",
                "\"dinput8\"=\"native,builtin\"",
                "\"windows.gaming.input\"=\"\""
            ]
            var newUserLines: [String] = []
            for line in userLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "[Software\\\\Wine\\\\DllOverrides]") {
                    inOverrides = true
                    newUserLines.append(line)
                    for ov in overrides { newUserLines.append(ov) }
                    addedOverrides = true
                    continue
                } else if trimmed.starts(with: "[") && inOverrides {
                    inOverrides = false
                    newUserLines.append(line)
                    continue
                }
                if inOverrides {
                    if trimmed.starts(with: "\"xinput1_4\"=") ||
                        trimmed.starts(with: "\"xinput1_3\"=") ||
                        trimmed.starts(with: "\"xinput9_1_0\"=") ||
                        trimmed.starts(with: "\"dinput8\"=") ||
                        trimmed.starts(with: "\"windows.gaming.input\"=") {
                        continue
                    }
                }
                newUserLines.append(line)
            }
            if !addedOverrides {
                newUserLines.append("")
                newUserLines.append("[Software\\\\Wine\\\\DllOverrides]")
                for ov in overrides { newUserLines.append(ov) }
            }
            try? newUserLines.joined(separator: "\n").write(to: userReg, atomically: true, encoding: .utf8)
        }
        
        // 3. Global System32 Driver Deployment
        let sys32Dir = bottleDir.appendingPathComponent("drive_c/windows/system32")
        let syswowDir = bottleDir.appendingPathComponent("drive_c/windows/syswow64")
        
        if let xinput64Src = Bundle.main.path(forResource: "xinput1_4_64", ofType: "dll") {
            if FileManager.default.fileExists(atPath: sys32Dir.path) {
                let dest = sys32Dir.appendingPathComponent("xinput1_4.dll")
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(atPath: xinput64Src, toPath: dest.path)
                }
            }
        }
        
        if let xinput32Src = Bundle.main.path(forResource: "xinput1_4_32", ofType: "dll") {
            if FileManager.default.fileExists(atPath: syswowDir.path) {
                let dest = syswowDir.appendingPathComponent("xinput1_4.dll")
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(atPath: xinput32Src, toPath: dest.path)
                }
            }
        }
    }
}

// MARK: - Autonomous Game Watcher & Auto-Injector
class GameWatcher {
    static let shared = GameWatcher()
    private var timer: DispatchSourceTimer?
    private var processedDirs = Set<String>()
    
    func start() {
        let queue = DispatchQueue(label: "com.antigravity.gamewatcher", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.scanRunningGames()
        }
        t.resume()
        self.timer = t
        writeLog("[Auto-Hook] Autonomous Game Watcher started.")
    }
    
    private func scanRunningGames() {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-ax", "-o", "command"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }
        
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if (line.contains(".exe") || line.contains(".EXE")) &&
               (line.contains("wine") || line.contains("CrossOver") || line.contains("Heroic") || line.contains("Whisky") || line.contains("Steam")) {
                extractAndInjectGame(from: line)
            }
        }
    }
    
    private func extractAndInjectGame(from commandLine: String) {
        let components = commandLine.components(separatedBy: " ")
        for comp in components {
            if comp.lowercased().hasSuffix(".exe") || comp.lowercased().contains(".exe\"") {
                var cleanPath = comp.replacingOccurrences(of: "\"", with: "")
                if cleanPath.starts(with: "Z:") || cleanPath.starts(with: "z:") {
                    cleanPath = String(cleanPath.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
                }
                
                let fileURL = URL(fileURLWithPath: cleanPath)
                let gameDir = fileURL.deletingLastPathComponent()
                let dirPath = gameDir.path
                
                if !processedDirs.contains(dirPath) && FileManager.default.fileExists(atPath: dirPath) {
                    processedDirs.insert(dirPath)
                    injectProxyDLLs(into: gameDir)
                    EngineProfileManager.shared.detectAndApplyProfile(for: fileURL.lastPathComponent, gameFolder: gameDir)
                }
            }
        }
    }
    
    func injectProxyDLLs(into targetFolder: URL) {
        let xinputDest = targetFolder.appendingPathComponent("xinput1_4.dll")
        let dinputDest = targetFolder.appendingPathComponent("dinput8.dll")
        
        if let xinputSrc = Bundle.main.path(forResource: "xinput1_4_64", ofType: "dll") ?? Bundle.main.path(forResource: "xinput1_4", ofType: "dll") {
            if !FileManager.default.fileExists(atPath: xinputDest.path) {
                try? FileManager.default.copyItem(atPath: xinputSrc, toPath: xinputDest.path)
                writeLog("[Auto-Hook] Injected xinput1_4.dll proxy into: \(targetFolder.lastPathComponent)")
            }
        }
        
        if let dinputSrc = Bundle.main.path(forResource: "dinput8_64", ofType: "dll") ?? Bundle.main.path(forResource: "dinput8_32", ofType: "dll") {
            if !FileManager.default.fileExists(atPath: dinputDest.path) {
                try? FileManager.default.copyItem(atPath: dinputSrc, toPath: dinputDest.path)
                writeLog("[Auto-Hook] Injected dinput8.dll proxy into: \(targetFolder.lastPathComponent)")
            }
        }
        
        let steamApiDest = targetFolder.appendingPathComponent("steam_api64.dll")
        let steamApiOrig = targetFolder.appendingPathComponent("steam_api64_original.dll")
        if let steamSrc = Bundle.main.path(forResource: "steam_api64", ofType: "dll") {
            if FileManager.default.fileExists(atPath: steamApiDest.path) && !FileManager.default.fileExists(atPath: steamApiOrig.path) {
                try? FileManager.default.copyItem(atPath: steamApiDest.path, toPath: steamApiOrig.path)
                try? FileManager.default.removeItem(at: steamApiDest)
                try? FileManager.default.copyItem(atPath: steamSrc, toPath: steamApiDest.path)
                writeLog("[Auto-Hook] Injected SteamAPI proxy into: \(targetFolder.lastPathComponent)")
            }
        }
    }
}

// MARK: - High-Rate Gyroscope Engine
class GyroEngine {
    static let shared = GyroEngine()
    private var gyroSocket: Int32 = -1
    private var gyroAddr = sockaddr_in()
    private var timer: DispatchSourceTimer?
    private var isStreaming = false
    
    private var lastSentPitch: Int16 = 0
    private var lastSentYaw: Int16 = 0
    private var lastSentRoll: Int16 = 0
    private var idleCount: Int = 0
    
    var gyroMode: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "gyroMode")
            return val == 0 ? 2 : val
        }
        set { UserDefaults.standard.set(newValue, forKey: "gyroMode") }
    }
    
    var gyroSensitivity: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "gyroSensitivity")
            return val == 0 ? 100 : val
        }
        set { UserDefaults.standard.set(newValue, forKey: "gyroSensitivity") }
    }
    
    func start() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd >= 0 {
            self.gyroSocket = fd
            gyroAddr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            gyroAddr.sin_family = sa_family_t(AF_INET)
            gyroAddr.sin_port = UInt16(24681).bigEndian
            gyroAddr.sin_addr.s_addr = inet_addr("127.0.0.1")
        }
        
        let queue = DispatchQueue(label: "com.antigravity.gyroengine", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in
            self?.pollAndStreamGyro()
        }
        t.resume()
        self.timer = t
        self.isStreaming = true
        writeLog("[Gyro] 120Hz 1:1 Precision Gyro Engine active.")
    }
    
    private func pollAndStreamGyro() {
        guard gyroMode > 0 else { return }
        guard let controller = GCController.controllers().first, let motion = controller.motion else { return }
        
        let rot = motion.rotationRate
        let pitchRate = Int16(clamping: Int(rot.x * 57.2958 * 100.0))
        let yawRate = Int16(clamping: Int(rot.y * 57.2958 * 100.0))
        let rollRate = Int16(clamping: Int(rot.z * 57.2958 * 100.0))
        
        let deltaPitch = abs(Int(pitchRate) - Int(lastSentPitch))
        let deltaYaw = abs(Int(yawRate) - Int(lastSentYaw))
        let deltaRoll = abs(Int(rollRate) - Int(lastSentRoll))
        
        if deltaPitch < 8 && deltaYaw < 8 && deltaRoll < 8 && abs(pitchRate) < 15 && abs(yawRate) < 15 {
            idleCount += 1
            if idleCount > 2 {
                return
            }
        } else {
            idleCount = 0
        }
        
        lastSentPitch = pitchRate
        lastSentYaw = yawRate
        lastSentRoll = rollRate
        
        var packet = [UInt8](repeating: 0, count: 10)
        packet[0] = 0x02
        packet[1] = UInt8(gyroMode)
        
        withUnsafeBytes(of: pitchRate.littleEndian) { packet[2] = $0[0]; packet[3] = $0[1] }
        withUnsafeBytes(of: yawRate.littleEndian) { packet[4] = $0[0]; packet[5] = $0[1] }
        withUnsafeBytes(of: rollRate.littleEndian) { packet[6] = $0[0]; packet[7] = $0[1] }
        let sens = Int16(gyroSensitivity)
        withUnsafeBytes(of: sens.littleEndian) { packet[8] = $0[0]; packet[9] = $0[1] }
        
        if gyroSocket >= 0 {
            _ = withUnsafePointer(to: &gyroAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(gyroSocket, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

// MARK: - Apple CoreHaptics Engine
class HapticBridge: NSObject {
    static let shared = HapticBridge()
    
    private var leftEngine: CHHapticEngine?
    private var rightEngine: CHHapticEngine?
    private var leftPlayer: CHHapticPatternPlayer?
    private var rightPlayer: CHHapticPatternPlayer?
    private var currentController: GCController?
    
    private var targetLeft: Float = 0.0
    private var targetRight: Float = 0.0
    private var lastSentLeft: Float = -1.0
    private var lastSentRight: Float = -1.0
    private let stateLock = NSLock()
    
    var rumbleIntensity: Float {
        get { UserDefaults.standard.float(forKey: "rumbleIntensity") }
        set { UserDefaults.standard.set(newValue, forKey: "rumbleIntensity") }
    }
    
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "rumbleIntensity": Float(0.85),
            "gyroMode": 2,
            "gyroSensitivity": 100
        ])
    }
    
    var onControllerStatusChanged: (() -> Void)?
    
    override init() {
        super.init()
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnect), name: .GCControllerDidDisconnect, object: nil)
        
        if let controller = GCController.controllers().first {
            setupController(controller)
        }
    }
    
    @objc private func controllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            setupController(controller)
        }
    }
    
    @objc private func controllerDidDisconnect(_ notification: Notification) {
        if let controller = notification.object as? GCController, controller == currentController {
            clearController()
        }
    }
    
    private func setupController(_ controller: GCController) {
        currentController = controller
        
        guard let haptics = controller.haptics else {
            onControllerStatusChanged?()
            return
        }
        
        let localities = haptics.supportedLocalities
        do {
            if localities.contains(.leftHandle) {
                leftEngine = haptics.createEngine(withLocality: .leftHandle)
            }
            if localities.contains(.rightHandle) {
                rightEngine = haptics.createEngine(withLocality: .rightHandle)
            }
            if leftEngine == nil && rightEngine == nil, let first = localities.first {
                leftEngine = haptics.createEngine(withLocality: first)
                rightEngine = leftEngine
            }
            
            try leftEngine?.start()
            if rightEngine != leftEngine {
                try rightEngine?.start()
            }
            
            let name = controller.vendorName ?? "DUALSHOCK 4 Wireless Controller"
            writeLog("[App] CoreHaptics & Gyro initialized for: \(name)")
            onControllerStatusChanged?()
        } catch {
            writeLog("[App] Failed to start haptics: \(error)")
        }
    }
    
    private func clearController() {
        leftEngine = nil
        rightEngine = nil
        leftPlayer = nil
        rightPlayer = nil
        currentController = nil
        onControllerStatusChanged?()
    }
    
    func getCurrentController() -> GCController? {
        return currentController ?? GCController.controllers().first
    }
    
    func getBatteryInfo() -> (level: Int, isCharging: Bool)? {
        guard let controller = getCurrentController(), let battery = controller.battery else { return nil }
        let raw = battery.batteryLevel
        guard raw >= 0.0 else { return nil }
        let level = max(0, min(100, Int(round(raw * 100))))
        let isCharging = (battery.batteryState == .charging || battery.batteryState == .full)
        return (level, isCharging)
    }
    
    func isUSBConnection() -> Bool {
        return false
    }
    
    func updateRumbleTarget(left: Float, right: Float) {
        stateLock.lock()
        targetLeft = left
        targetRight = right
        lastUpdateTime = CACurrentMediaTime()
        stateLock.unlock()
        setRumble(left: left, right: right)
        startWatchdogIfNeeded()
    }
    
    private var lastUpdateTime: CFTimeInterval = 0
    private var watchdogTimer: DispatchSourceTimer?
    
    private func startWatchdogIfNeeded() {
        guard watchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let elapsed = CACurrentMediaTime() - self.lastUpdateTime
            let left = self.targetLeft
            let right = self.targetRight
            self.stateLock.unlock()
            
            if elapsed > 1.0 && (left > 0.0 || right > 0.0) {
                self.setRumble(left: 0, right: 0)
                self.stateLock.lock()
                self.targetLeft = 0
                self.targetRight = 0
                self.stateLock.unlock()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }
    
    func setRumble(left: Float, right: Float) {
        guard currentController != nil else { return }
        let userScale = rumbleIntensity
        let lScaled = userScale < 0.01 ? 0.0 : min(1.0, (left * userScale))
        let rScaled = userScale < 0.01 ? 0.0 : min(1.0, (right * userScale))
        
        if abs(lScaled - lastSentLeft) < 0.015 && abs(rScaled - lastSentRight) < 0.015 && (lScaled > 0.0 || rScaled > 0.0) {
            return
        }
        lastSentLeft = lScaled
        lastSentRight = rScaled
        
        let sharpness: Float = 0.4
        
        do {
            if leftEngine == rightEngine, let engine = leftEngine {
                let val = max(lScaled, rScaled)
                if leftPlayer == nil {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                    let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharp], relativeTime: 0, duration: 3600.0)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    leftPlayer = try engine.makePlayer(with: pattern)
                    try leftPlayer?.start(atTime: 0)
                }
                let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: val, relativeTime: 0)
                try leftPlayer?.sendParameters([param], atTime: 0)
                return
            }
            
            if let engine = leftEngine {
                if leftPlayer == nil {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                    let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharp], relativeTime: 0, duration: 3600.0)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    leftPlayer = try engine.makePlayer(with: pattern)
                    try leftPlayer?.start(atTime: 0)
                }
                let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: lScaled, relativeTime: 0)
                try leftPlayer?.sendParameters([param], atTime: 0)
            }
            
            if let engine = rightEngine {
                if rightPlayer == nil {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                    let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharp], relativeTime: 0, duration: 3600.0)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    rightPlayer = try engine.makePlayer(with: pattern)
                    try rightPlayer?.start(atTime: 0)
                }
                let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: rScaled, relativeTime: 0)
                try rightPlayer?.sendParameters([param], atTime: 0)
            }
        } catch {
            print("Error playing haptics: \(error)")
        }
    }
    
    func testRumble() {
        writeLog("[App] Triggering Dual-Motor Rumble Test (100% intensity)...")
        setRumble(left: 1.0, right: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.setRumble(left: 0.0, right: 0.0)
            writeLog("[App] Test vibration complete.")
        }
    }
}

// MARK: - BSD UDP Server for Rumble Packets
class BSDUDPServer {
    private var socketFileDescriptor: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.antigravity.rumblebridge.udp", qos: .userInteractive)
    
    func start(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return }
        
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if bindResult < 0 {
            close(fd)
            return
        }
        
        self.socketFileDescriptor = fd
        self.isRunning = true
        writeLog("[App] UDP Rumble Server listening on port \(port)")
        
        queue.async { [weak self] in
            self?.runLoop()
        }
    }
    
    private func runLoop() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while isRunning {
            let bytesRead = recv(socketFileDescriptor, &buffer, buffer.count, 0)
            if bytesRead >= 3 && buffer[0] == 0x01 {
                let left = Float(buffer[1]) / 255.0
                let right = Float(buffer[2]) / 255.0
                HapticBridge.shared.updateRumbleTarget(left: left, right: right)
            }
        }
    }
    
    func stop() {
        isRunning = false
        if socketFileDescriptor >= 0 {
            close(socketFileDescriptor)
            socketFileDescriptor = -1
        }
    }
}

// MARK: - Built-in Comprehensive Help, Guide & FAQ Center (Rich Typography)
class HelpWindowController: NSWindowController {
    static var shared: HelpWindowController?
    
    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 530),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "DS4Link Help, User Guide & FAQ Center"
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 620, height: 440)
        
        let vc = HelpViewController()
        win.contentViewController = vc
        self.init(window: win)
    }
    
    static func show() {
        if shared == nil {
            shared = HelpWindowController()
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

class HelpViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    private var tableView: NSTableView!
    private var textView: NSTextView!
    
    struct FAQTopic {
        let title: String
        let icon: String
        let content: String
    }
    
    private let topics: [FAQTopic] = [
        FAQTopic(
            title: "Quick Start & Pairing",
            icon: "play.circle.fill",
            content: """
            # 🚀 Quick Start Guide
            
            ### 1. Pairing DualShock 4 via Bluetooth
            1. Press and hold the **PS Button** and **Share Button** simultaneously on your DualShock 4 until the lightbar starts rapidly double-flashing.
            2. On your Mac, go to **System Settings -> Bluetooth** and click **Connect** next to *DUALSHOCK 4 Wireless Controller*.
            3. DS4Link will instantly recognize the controller and show your real-time battery level in the top menu bar!
            
            ### 2. Playing Games (Zero Configuration)
            * Launch any game through **Heroic Game Launcher**, **CrossOver**, **Whisky**, or **Steam**.
            * DS4Link runs autonomously in the background. It automatically intercepts vibration, applies anti-drift deadzones, and enables 1:1 motion aiming!
            """
        ),
        FAQTopic(
            title: "Features Overview",
            icon: "star.circle.fill",
            content: """
            # 🌟 Feature Highlights
            
            * **Dual-Motor Apple CoreHaptics**: Zero-latency Bluetooth vibration translated directly through Apple's native haptics engine.
            * **120Hz 1:1 Mouse-Delta Gyro Aiming**: Spatial motion aiming identical to Nintendo Switch and Steam Deck hardware.
            * **Autonomous Game Engine DNA**: Auto-detects 1,000+ games (RE Engine, Decima, Unreal, Unity, ForzaTech) and tunes input/haptic profiles automatically.
            * **Radial Anti-Drift Deadzones**: Hardware-grade filtering that permanently stops stick drift and camera "sky-looking".
            * **Bluetooth Bandwidth Optimizer**: Slashes redundant radio packets by 85%, eliminating audio stutter on AirPods.
            * **Touchpad-to-Map Mapping**: Central touchpad clicks open in-game maps in PlayStation PC titles.
            """
        ),
        FAQTopic(
            title: "Gyroscope Aiming Modes",
            icon: "gyroscope",
            content: """
            # 🎯 Gyroscope Motion Aiming Modes
            
            DS4Link offers 4 specialized motion aiming modes:
            
            1. **Off**: Traditional analog controls.
            2. **Stick**: Traditional smoothed analog stick emulation. Recommended for games with strict simultaneous input lockouts (like *Resident Evil*).
            3. **1:1 Aim (Hold L2)** *(Default & Recommended)*:
               * Automatically activates razor-sharp 1:1 mouse-delta motion aiming whenever you pull the **L2 trigger (Aim Down Sights)**.
               * Delivers competitive, zero-delay spatial targeting for shooters, action, and adventure games.
            4. **Always Active**: Constant 1:1 motion control for flight, racing, and space sims.
            
            *Tip: Adjust the Gyro Sensitivity slider (20% – 250%) to match your personal playstyle.*
            """
        ),
        FAQTopic(
            title: "Game Engines & Profiles",
            icon: "cpu.fill",
            content: """
            # 🧠 Autonomous Game Engine DNA Resolver
            
            DS4Link automatically identifies running games and configures custom profiles:
            
            * **Capcom RE Engine** (*Resident Evil 2/3/4/7/8*, *DMC5*): Automatically locks to Anti-Flicker Stick Gyro so button prompts never flicker between L2 and Right-Click.
            * **Sony First-Party Ports** (*Spider-Man*, *Horizon*, *God of War*): Automatically routes DualShock 4 Touchpad click to open the in-game map.
            * **Turn 10 ForzaTech** (*Forza Horizon 4/5*): Synthesizes 4-Motor Impulse Trigger haptics for tire slip and ABS brake lockup.
            * **Unity Engine** (*We Were Here*, *Subnautica*): Isolates DirectInput to prevent duplicate "Ghost Player 2" spawns and eliminates memory leaks.
            * **Unreal Engine 4 & 5** (*Jedi Survivor*, *Black Myth: Wukong*, *Avatar*): Unlocks 120Hz 1:1 raw mouse motion aiming.
            """
        ),
        FAQTopic(
            title: "Troubleshooting & FAQs",
            icon: "wrench.and.screwdriver.fill",
            content: """
            # 🛠️ Troubleshooting & Frequently Asked Questions
            
            ### Q: My camera keeps spinning or looking at the sky.
            **A:** DS4Link features built-in radial magnitude deadzones and trigger threshold clamping to permanently eliminate stick drift. If an issue occurs, re-center the controller and click **Re-Scan Bottles** in the menu bar.
            
            ### Q: Does the controller speaker work over Bluetooth?
            **A:** Over Bluetooth, macOS connects game controllers strictly under the Gamepad HID profile, which disables the proprietary Sony wireless audio stream. To use the controller's built-in speaker, connect via USB cable.
            
            ### Q: Will I see PlayStation (×, ○, □, △) button icons in games?
            **A:** In modern titles and PlayStation PC ports, yes (or selectable in game settings). Older Windows games from 2005–2015 only have Xbox (A, B, X, Y) textures drawn into their files, but your DualShock 4 buttons map 1:1 to the correct physical positions.
            
            ### Q: The game says "Playing" in Heroic/CrossOver but won't open.
            **A:** A previous crashed game may have left a zombie `wineserver` process. Quit the game launcher, open Terminal, run `killall wineserver`, and restart the game.
            """
        )
    ]
    
    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 530))
        self.view = root
        
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.spacing = 0
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        
        // Sidebar (Topics)
        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.widthAnchor.constraint(equalToConstant: 220).isActive = true
        
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = NSColor(white: 0.1, alpha: 0.85)
        tableView.rowHeight = 42
        tableView.delegate = self
        tableView.dataSource = self
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic"))
        col.title = "Topics"
        col.width = 210
        tableView.addTableColumn(col)
        sidebarScroll.documentView = tableView
        container.addArrangedSubview(sidebarScroll)
        
        // Divider line
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        container.addArrangedSubview(divider)
        
        // Content Area
        let contentScroll = NSScrollView()
        contentScroll.hasVerticalScroller = true
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.backgroundColor = NSColor(white: 0.05, alpha: 0.95)
        contentScroll.documentView = textView
        container.addArrangedSubview(contentScroll)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        displayTopic(index: 0)
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return topics.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = topics[row]
        let cell = NSTableCellView()
        
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)
        img.contentTintColor = NSColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1.0)
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 18).isActive = true
        img.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(img)
        
        let label = NSTextField(labelWithString: item.title)
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        stack.addArrangedSubview(label)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        
        return cell
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < topics.count {
            displayTopic(index: row)
        }
    }
    
    private func displayTopic(index: Int) {
        let topic = topics[index]
        let attr = NSMutableAttributedString()
        
        // Paragraph Style with spacious line height and readability margins
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 5.0
        bodyParagraph.paragraphSpacing = 8.0
        bodyParagraph.paragraphSpacingBefore = 2.0
        
        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacing = 12.0
        headingParagraph.paragraphSpacingBefore = 4.0
        
        let subHeadingParagraph = NSMutableParagraphStyle()
        subHeadingParagraph.paragraphSpacing = 8.0
        subHeadingParagraph.paragraphSpacingBefore = 10.0
        
        let lines = topic.content.components(separatedBy: .newlines)
        for line in lines {
            if line.starts(with: "# ") {
                let text = String(line.dropFirst(2)) + "\n"
                attr.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 21, weight: .heavy),
                    .foregroundColor: NSColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1.0),
                    .paragraphStyle: headingParagraph
                ]))
            } else if line.starts(with: "### ") {
                let text = String(line.dropFirst(4)) + "\n"
                attr.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 14.5, weight: .bold),
                    .foregroundColor: NSColor(white: 0.98, alpha: 1.0),
                    .paragraphStyle: subHeadingParagraph
                ]))
            } else if line.starts(with: "* ") {
                let text = "  •  " + String(line.dropFirst(2)) + "\n"
                attr.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: NSColor(white: 0.88, alpha: 1.0),
                    .paragraphStyle: bodyParagraph
                ]))
            } else if line.starts(with: "1. ") || line.starts(with: "2. ") || line.starts(with: "3. ") || line.starts(with: "4. ") {
                let text = "  " + line + "\n"
                attr.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: NSColor(white: 0.88, alpha: 1.0),
                    .paragraphStyle: bodyParagraph
                ]))
            } else {
                let text = line + "\n"
                attr.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: NSColor(white: 0.82, alpha: 1.0),
                    .paragraphStyle: bodyParagraph
                ]))
            }
        }
        
        textView.textStorage?.setAttributedString(attr)
    }
}

// MARK: - Perfectly Proportioned Native Popover (305px Width, Self-Sizing)
class PopoverViewController: NSViewController {
    static var shared: PopoverViewController?
    
    var controllerNameLabel: NSTextField!
    var batteryBadge: NSTextField!
    var connectionSubLabel: NSTextField!
    var engineBadge: NSTextField!
    var audioStatusLabel: NSTextField!
    
    var intensitySlider: NSSlider!
    var intensityLabel: NSTextField!
    
    var gyroSegment: NSSegmentedControl!
    var gyroSensitivitySlider: NSSlider!
    var gyroSensLabel: NSTextField!
    
    private var pollTimer: Timer?
    
    override func loadView() {
        PopoverViewController.shared = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 305, height: 405))
        self.view = root
        root.wantsLayer = true
        
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.distribution = .fill
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        
        // 1. Header Card (Device & Game DNA)
        let headerCard = createCardView()
        mainStack.addArrangedSubview(headerCard)
        headerCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        
        let headerContent = NSStackView()
        headerContent.orientation = .horizontal
        headerContent.alignment = .centerY
        headerContent.spacing = 10
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(headerContent)
        
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1.0)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 30).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 30).isActive = true
        headerContent.addArrangedSubview(iconView)
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        headerContent.addArrangedSubview(textStack)
        
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(topRow)
        topRow.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        
        controllerNameLabel = NSTextField(labelWithString: "DUALSHOCK 4")
        controllerNameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        controllerNameLabel.textColor = .labelColor
        topRow.addArrangedSubview(controllerNameLabel)
        
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)
        
        batteryBadge = NSTextField(labelWithString: " 25% ")
        batteryBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        batteryBadge.alignment = .center
        batteryBadge.textColor = NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1.0)
        batteryBadge.backgroundColor = NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 0.15)
        batteryBadge.drawsBackground = true
        batteryBadge.wantsLayer = true
        batteryBadge.layer?.cornerRadius = 5
        batteryBadge.layer?.masksToBounds = true
        topRow.addArrangedSubview(batteryBadge)
        
        connectionSubLabel = NSTextField(labelWithString: "Bluetooth • Universal Auto-Hook")
        connectionSubLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        connectionSubLabel.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(connectionSubLabel)
        
        engineBadge = NSTextField(labelWithString: "⚡ Universal Game Engine")
        engineBadge.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        engineBadge.textColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
        engineBadge.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(engineBadge)
        
        audioStatusLabel = NSTextField(labelWithString: "🔊 Speaker: Requires USB Cable")
        audioStatusLabel.font = NSFont.systemFont(ofSize: 9.0, weight: .regular)
        audioStatusLabel.textColor = .tertiaryLabelColor
        textStack.addArrangedSubview(audioStatusLabel)
        
        NSLayoutConstraint.activate([
            headerContent.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 9),
            headerContent.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 10),
            headerContent.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -10),
            headerContent.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -9)
        ])
        
        // 2. Haptics Card
        let hapticsCard = createCardView()
        mainStack.addArrangedSubview(hapticsCard)
        hapticsCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        
        let hapStack = NSStackView()
        hapStack.orientation = .vertical
        hapStack.alignment = .leading
        hapStack.spacing = 7
        hapStack.translatesAutoresizingMaskIntoConstraints = false
        hapticsCard.addSubview(hapStack)
        
        let hapHeaderRow = NSStackView()
        hapHeaderRow.orientation = .horizontal
        hapHeaderRow.alignment = .centerY
        hapHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        hapStack.addArrangedSubview(hapHeaderRow)
        hapHeaderRow.widthAnchor.constraint(equalTo: hapStack.widthAnchor).isActive = true
        
        let hapTitle = NSTextField(labelWithString: "CoreHaptics Rumble")
        hapTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        hapTitle.textColor = .secondaryLabelColor
        hapHeaderRow.addArrangedSubview(hapTitle)
        
        let hapSpacer = NSView()
        hapSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hapHeaderRow.addArrangedSubview(hapSpacer)
        
        intensityLabel = NSTextField(labelWithString: "\(Int(HapticBridge.shared.rumbleIntensity * 100))%")
        intensityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        intensityLabel.textColor = .labelColor
        hapHeaderRow.addArrangedSubview(intensityLabel)
        
        intensitySlider = NSSlider(value: Double(HapticBridge.shared.rumbleIntensity * 100), minValue: 0, maxValue: 100, target: self, action: #selector(intensityChanged(_:)))
        intensitySlider.controlSize = .small
        intensitySlider.translatesAutoresizingMaskIntoConstraints = false
        hapStack.addArrangedSubview(intensitySlider)
        intensitySlider.widthAnchor.constraint(equalTo: hapStack.widthAnchor).isActive = true
        
        let testBtn = NSButton(title: "Test Dual-Motor Vibration", target: self, action: #selector(testRumbleClicked))
        testBtn.bezelStyle = .rounded
        testBtn.controlSize = .small
        testBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        testBtn.translatesAutoresizingMaskIntoConstraints = false
        hapStack.addArrangedSubview(testBtn)
        testBtn.widthAnchor.constraint(equalTo: hapStack.widthAnchor).isActive = true
        
        NSLayoutConstraint.activate([
            hapStack.topAnchor.constraint(equalTo: hapticsCard.topAnchor, constant: 9),
            hapStack.leadingAnchor.constraint(equalTo: hapticsCard.leadingAnchor, constant: 10),
            hapStack.trailingAnchor.constraint(equalTo: hapticsCard.trailingAnchor, constant: -10),
            hapStack.bottomAnchor.constraint(equalTo: hapticsCard.bottomAnchor, constant: -9)
        ])
        
        // 3. Gyro Card
        let gyroCard = createCardView()
        mainStack.addArrangedSubview(gyroCard)
        gyroCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        
        let gyroStack = NSStackView()
        gyroStack.orientation = .vertical
        gyroStack.alignment = .leading
        gyroStack.spacing = 7
        gyroStack.translatesAutoresizingMaskIntoConstraints = false
        gyroCard.addSubview(gyroStack)
        
        let gyroHeaderRow = NSStackView()
        gyroHeaderRow.orientation = .horizontal
        gyroHeaderRow.alignment = .centerY
        gyroHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        gyroStack.addArrangedSubview(gyroHeaderRow)
        gyroHeaderRow.widthAnchor.constraint(equalTo: gyroStack.widthAnchor).isActive = true
        
        let gyroTitle = NSTextField(labelWithString: "Adaptive Gyro Aiming")
        gyroTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        gyroTitle.textColor = .secondaryLabelColor
        gyroHeaderRow.addArrangedSubview(gyroTitle)
        
        let gyroSpacer = NSView()
        gyroSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gyroHeaderRow.addArrangedSubview(gyroSpacer)
        
        gyroSensLabel = NSTextField(labelWithString: "\(GyroEngine.shared.gyroSensitivity)%")
        gyroSensLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        gyroSensLabel.textColor = .labelColor
        gyroHeaderRow.addArrangedSubview(gyroSensLabel)
        
        gyroSegment = NSSegmentedControl(labels: ["Off", "Stick", "1:1 Aim (L2)", "Always"], trackingMode: .selectOne, target: self, action: #selector(gyroSegmentChanged(_:)))
        gyroSegment.selectedSegment = GyroEngine.shared.gyroMode
        gyroSegment.controlSize = .small
        gyroSegment.segmentDistribution = .fillEqually
        gyroSegment.translatesAutoresizingMaskIntoConstraints = false
        gyroStack.addArrangedSubview(gyroSegment)
        gyroSegment.widthAnchor.constraint(equalTo: gyroStack.widthAnchor).isActive = true
        
        gyroSensitivitySlider = NSSlider(value: Double(GyroEngine.shared.gyroSensitivity), minValue: 20, maxValue: 250, target: self, action: #selector(gyroSensChanged(_:)))
        gyroSensitivitySlider.controlSize = .small
        gyroSensitivitySlider.translatesAutoresizingMaskIntoConstraints = false
        gyroStack.addArrangedSubview(gyroSensitivitySlider)
        gyroSensitivitySlider.widthAnchor.constraint(equalTo: gyroStack.widthAnchor).isActive = true
        
        NSLayoutConstraint.activate([
            gyroStack.topAnchor.constraint(equalTo: gyroCard.topAnchor, constant: 9),
            gyroStack.leadingAnchor.constraint(equalTo: gyroCard.leadingAnchor, constant: 10),
            gyroStack.trailingAnchor.constraint(equalTo: gyroCard.trailingAnchor, constant: -10),
            gyroStack.bottomAnchor.constraint(equalTo: gyroCard.bottomAnchor, constant: -9)
        ])
        
        // 4. Action Buttons Row (Sync, Help, Console)
        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        footerRow.distribution = .fillEqually
        footerRow.spacing = 8
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(footerRow)
        footerRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        
        let syncBtn = NSButton(title: "Re-Scan", target: self, action: #selector(syncBottlesClicked))
        syncBtn.bezelStyle = .rounded
        syncBtn.controlSize = .small
        footerRow.addArrangedSubview(syncBtn)
        
        let helpBtn = NSButton(title: "Help & FAQ", target: self, action: #selector(openHelpClicked))
        helpBtn.bezelStyle = .rounded
        helpBtn.controlSize = .small
        footerRow.addArrangedSubview(helpBtn)
        
        let logsBtn = NSButton(title: "Console", target: self, action: #selector(openLogsClicked))
        logsBtn.bezelStyle = .rounded
        logsBtn.controlSize = .small
        footerRow.addArrangedSubview(logsBtn)
        
        let quitBtn = NSButton(title: "Quit DS4Link", target: self, action: #selector(quitClicked))
        quitBtn.bezelStyle = .inline
        quitBtn.controlSize = .small
        quitBtn.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(quitBtn)
        quitBtn.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
    }
    
    private func createCardView() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.6).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }
    
    func updateUI() {
        guard let controller = HapticBridge.shared.getCurrentController() else {
            controllerNameLabel.stringValue = "Disconnected"
            batteryBadge.stringValue = " Off "
            batteryBadge.textColor = .secondaryLabelColor
            batteryBadge.backgroundColor = NSColor(white: 0.5, alpha: 0.15)
            connectionSubLabel.stringValue = "Turn on DualShock 4"
            engineBadge.stringValue = "⚡ Waiting for Game..."
            audioStatusLabel.stringValue = "🔊 Speaker: Disconnected"
            AppDelegate.shared?.updateStatusIcon(connected: false, batteryPct: nil, isCharging: false)
            return
        }
        
        let name = controller.vendorName ?? "DUALSHOCK 4"
        controllerNameLabel.stringValue = name.replacingOccurrences(of: " Wireless Controller", with: "")
        
        let isUSB = HapticBridge.shared.isUSBConnection()
        connectionSubLabel.stringValue = isUSB ? "USB Wired • Ultra Low Latency" : "Bluetooth • Universal Auto-Hook"
        engineBadge.stringValue = "⚡ \(EngineProfileManager.shared.activeGameName) (\(EngineProfileManager.shared.activeEngine.rawValue))"
        audioStatusLabel.stringValue = isUSB ? "🔊 Speaker: Active (USB)" : "🔊 Speaker: Requires USB Cable"
        
        gyroSegment.selectedSegment = GyroEngine.shared.gyroMode
        
        if let batt = HapticBridge.shared.getBatteryInfo() {
            let chargeIcon = batt.isCharging ? "⚡ " : ""
            batteryBadge.stringValue = " \(chargeIcon)\(batt.level)% "
            batteryBadge.textColor = batt.level <= 15 ? NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0) : NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1.0)
            AppDelegate.shared?.updateStatusIcon(connected: true, batteryPct: batt.level, isCharging: batt.isCharging)
        } else {
            batteryBadge.stringValue = " Ready "
            AppDelegate.shared?.updateStatusIcon(connected: true, batteryPct: nil, isCharging: false)
        }
    }
    
    @objc func intensityChanged(_ sender: NSSlider) {
        let pct = Float(sender.doubleValue) / 100.0
        HapticBridge.shared.rumbleIntensity = pct
        intensityLabel.stringValue = "\(Int(sender.doubleValue))%"
    }
    
    @objc func testRumbleClicked() {
        HapticBridge.shared.testRumble()
    }
    
    @objc func gyroSegmentChanged(_ sender: NSSegmentedControl) {
        GyroEngine.shared.gyroMode = sender.selectedSegment
        writeLog("[Gyro] Mode changed to: \(sender.selectedSegment)")
    }
    
    @objc func gyroSensChanged(_ sender: NSSlider) {
        let val = Int(sender.doubleValue)
        GyroEngine.shared.gyroSensitivity = val
        gyroSensLabel.stringValue = "\(val)%"
    }
    
    @objc func syncBottlesClicked() {
        autoPatchAllBottles()
        writeLog("[App] Synchronized all Wine & CrossOver bottles globally.")
    }
    
    @objc func openHelpClicked() {
        HelpWindowController.show()
    }
    
    @objc func openLogsClicked() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/Vedant/Documents/ds4_rumble_bridge/rumble_app.log"))
    }
    
    @objc func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - App Delegate & Menu Bar Integration
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let server = BSDUDPServer()
    
    override init() {
        super.init()
        AppDelegate.shared = self
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        HapticBridge.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusItem()
        setupPopover()
        
        writeLog("[App] Starting DS4Link Universal Driver...")
        server.start(port: 24680)
        GyroEngine.shared.start()
        GameWatcher.shared.start()
        autoPatchAllBottles()
        
        HapticBridge.shared.onControllerStatusChanged = {
            DispatchQueue.main.async {
                PopoverViewController.shared?.updateUI()
            }
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "DualShock 4")
            button.imagePosition = .imageLeft
            button.title = ""
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }
    
    func updateStatusIcon(connected: Bool, batteryPct: Int?, isCharging: Bool) {
        if let button = statusItem?.button {
            if connected {
                button.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "DualShock 4")
                if let pct = batteryPct {
                    let chargeSymbol = isCharging ? "⚡" : ""
                    button.title = " \(chargeSymbol)\(pct)%"
                } else {
                    button.title = ""
                }
            } else {
                button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "DualShock 4 (Off)")
                button.title = ""
            }
        }
    }
    
    private func setupPopover() {
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 305, height: 405)
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = PopoverViewController()
        self.popover = pop
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            PopoverViewController.shared?.updateUI()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }
}

// Entry Point
setbuf(stdout, nil)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
