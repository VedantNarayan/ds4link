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
    case sonyFirstParty = "Sony First-Party (Decima/Insomniac)"
    case reEngine = "Capcom RE Engine"
    case forzaTech = "Turn 10 ForzaTech"
    case unity = "Unity Engine"
    case unrealEngine = "Unreal Engine"
    case standardDirectX = "Universal DirectX / Custom"
}

struct EngineProfile {
    let engine: GameEngineType
    let defaultGyroMode: Int       // 1 = Stick (Anti-Flicker), 2 = 1:1 Mouse (Aim L2)
    let enableTouchpadToMap: Bool  // Touchpad click -> Gamepad Map/Back
    let impulseTriggerHaptics: Bool// Synthesize trigger brake/throttle rumble
    let isolateDInput: Bool        // Prevent Player 2 ghost duplication
}

class EngineProfileManager {
    static let shared = EngineProfileManager()
    private(set) var activeEngine: GameEngineType = .standardDirectX
    private(set) var activeGameName: String = "Universal Game"
    
    func detectAndApplyProfile(for exeName: String, gameFolder: URL) {
        let nameLower = exeName.lowercased()
        let folderName = gameFolder.lastPathComponent.lowercased()
        
        var profile: EngineProfile
        
        // 1. Capcom RE Engine (Resident Evil 2/3/4/7/8, DMC5, Monster Hunter)
        if nameLower.contains("re2") || nameLower.contains("re3") || nameLower.contains("re4") ||
           nameLower.contains("re7") || nameLower.contains("re8") || nameLower.contains("devilmaycry") ||
           nameLower.contains("monsterhunter") || FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("re_chunk_000.pak").path) {
            profile = EngineProfile(engine: .reEngine, defaultGyroMode: 1, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = "Resident Evil / RE Engine Title"
        }
        // 2. Sony First-Party Games (Spider-Man, Miles Morales, Horizon, God of War, Tsushima, TLOU)
        else if nameLower.contains("spider") || nameLower.contains("miles") || nameLower.contains("horizon") ||
                nameLower.contains("godofwar") || nameLower.contains("tsushima") || nameLower.contains("tlou") ||
                nameLower.contains("uncharted") || nameLower.contains("returnal") {
            profile = EngineProfile(engine: .sonyFirstParty, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: true, isolateDInput: true)
            activeGameName = "PlayStation PC Port"
        }
        // 3. ForzaTech (Forza Horizon 4/5, Motorsport)
        else if nameLower.contains("forzahorizon") || nameLower.contains("forzamotorsport") || nameLower.contains("forza") {
            profile = EngineProfile(engine: .forzaTech, defaultGyroMode: 1, enableTouchpadToMap: false, impulseTriggerHaptics: true, isolateDInput: true)
            activeGameName = "Forza Horizon / Motorsport"
        }
        // 4. Unity Engine (We Were Here, Subnautica, Hollow Knight, Cuphead, etc.)
        else if FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("UnityPlayer.dll").path) ||
                folderName.contains("wewerehere") || folderName.contains("subnautica") {
            profile = EngineProfile(engine: .unity, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = folderName.capitalized
        }
        // 5. Unreal Engine (Jedi Survivor, Stalker 2, Black Myth, Avatar, Fortnite, etc.)
        else if FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("Engine").path) ||
                nameLower.contains("shipping") || nameLower.contains("avatar") {
            profile = EngineProfile(engine: .unrealEngine, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = "Unreal Engine Title"
        }
        // 6. Universal Default
        else {
            profile = EngineProfile(engine: .standardDirectX, defaultGyroMode: 2, enableTouchpadToMap: true, impulseTriggerHaptics: false, isolateDInput: true)
            activeGameName = exeName.replacingOccurrences(of: ".exe", with: "").capitalized
        }
        
        self.activeEngine = profile.engine
        GyroEngine.shared.gyroMode = profile.defaultGyroMode
        writeLog("[Engine-DNA] Auto-Configured for: \(profile.engine.rawValue) (\(activeGameName)) | Gyro: \(profile.defaultGyroMode == 1 ? "Stick (Anti-Flicker)" : "1:1 Mouse") | Touchpad: \(profile.enableTouchpadToMap)")
        
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
        
        // 3. Global System32 Driver Deployment (Anti-Cheat & Root-directory Isolation)
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

// MARK: - High-Rate Gyroscope Engine with Bluetooth Bandwidth Optimizer
class GyroEngine {
    static let shared = GyroEngine()
    private var gyroSocket: Int32 = -1
    private var gyroAddr = sockaddr_in()
    private var timer: DispatchSourceTimer?
    private var isStreaming = false
    
    // Deadband and Rate-Limiting State
    private var lastSentPitch: Int16 = 0
    private var lastSentYaw: Int16 = 0
    private var lastSentRoll: Int16 = 0
    private var idleCount: Int = 0
    
    var gyroMode: Int { // 0 = Off, 1 = Stick Emulation (Anti-Flicker), 2 = 1:1 Mouse Delta (Aim L2), 3 = 1:1 Mouse Delta (Always)
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
        t.schedule(deadline: .now(), repeating: .milliseconds(8)) // 120Hz
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
        
        // Deadband Filter
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

// MARK: - Apple CoreHaptics Engine with Impulse Trigger Synthesizer
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
        
        // Touchpad mapping (Touchpad button -> Gamepad Map/Back)
        controller.extendedGamepad?.buttonOptions?.pressedChangedHandler = { _, _, pressed in
            if pressed {
                writeLog("[Input] Touchpad / Options button pressed.")
            }
        }
        
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

// MARK: - Native macOS Menu Bar Popover Control Center
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 430))
        self.view = view
        view.wantsLayer = true
        
        // 1. Header Card
        let headerBox = createCardView(frame: NSRect(x: 14, y: 336, width: 312, height: 82))
        view.addSubview(headerBox)
        
        let iconView = NSImageView(frame: NSRect(x: 12, y: 28, width: 34, height: 34))
        iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1.0)
        headerBox.addSubview(iconView)
        
        controllerNameLabel = NSTextField(labelWithString: "DUALSHOCK 4")
        controllerNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        controllerNameLabel.textColor = .labelColor
        controllerNameLabel.frame = NSRect(x: 54, y: 56, width: 170, height: 18)
        headerBox.addSubview(controllerNameLabel)
        
        connectionSubLabel = NSTextField(labelWithString: "Bluetooth • Universal Auto-Hook")
        connectionSubLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        connectionSubLabel.textColor = .secondaryLabelColor
        connectionSubLabel.frame = NSRect(x: 54, y: 38, width: 170, height: 15)
        headerBox.addSubview(connectionSubLabel)
        
        engineBadge = NSTextField(labelWithString: "⚡ Engine: Universal Game")
        engineBadge.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        engineBadge.textColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
        engineBadge.frame = NSRect(x: 54, y: 20, width: 250, height: 14)
        headerBox.addSubview(engineBadge)
        
        audioStatusLabel = NSTextField(labelWithString: "🔊 Speaker: Requires USB")
        audioStatusLabel.font = NSFont.systemFont(ofSize: 9.0, weight: .regular)
        audioStatusLabel.textColor = .tertiaryLabelColor
        audioStatusLabel.frame = NSRect(x: 54, y: 6, width: 170, height: 13)
        headerBox.addSubview(audioStatusLabel)
        
        batteryBadge = NSTextField(labelWithString: "25%")
        batteryBadge.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        batteryBadge.alignment = .center
        batteryBadge.textColor = NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1.0)
        batteryBadge.backgroundColor = NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 0.15)
        batteryBadge.drawsBackground = true
        batteryBadge.wantsLayer = true
        batteryBadge.layer?.cornerRadius = 6
        batteryBadge.layer?.masksToBounds = true
        batteryBadge.frame = NSRect(x: 232, y: 36, width: 68, height: 22)
        headerBox.addSubview(batteryBadge)
        
        // 2. Haptics Card
        let hapticsCard = createCardView(frame: NSRect(x: 14, y: 236, width: 312, height: 90))
        view.addSubview(hapticsCard)
        
        let hapTitle = NSTextField(labelWithString: "CoreHaptics Dual-Motor Rumble")
        hapTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        hapTitle.textColor = .secondaryLabelColor
        hapTitle.frame = NSRect(x: 12, y: 64, width: 200, height: 16)
        hapticsCard.addSubview(hapTitle)
        
        intensityLabel = NSTextField(labelWithString: "\(Int(HapticBridge.shared.rumbleIntensity * 100))%")
        intensityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        intensityLabel.alignment = .right
        intensityLabel.textColor = .labelColor
        intensityLabel.frame = NSRect(x: 240, y: 64, width: 60, height: 16)
        hapticsCard.addSubview(intensityLabel)
        
        intensitySlider = NSSlider(value: Double(HapticBridge.shared.rumbleIntensity * 100), minValue: 0, maxValue: 100, target: self, action: #selector(intensityChanged(_:)))
        intensitySlider.controlSize = .small
        intensitySlider.frame = NSRect(x: 12, y: 38, width: 288, height: 18)
        hapticsCard.addSubview(intensitySlider)
        
        let testBtn = NSButton(title: "Test Vibration", target: self, action: #selector(testRumbleClicked))
        testBtn.bezelStyle = .inline
        testBtn.controlSize = .mini
        testBtn.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        testBtn.frame = NSRect(x: 12, y: 12, width: 288, height: 20)
        hapticsCard.addSubview(testBtn)
        
        // 3. Gyro Card
        let gyroCard = createCardView(frame: NSRect(x: 14, y: 124, width: 312, height: 102))
        view.addSubview(gyroCard)
        
        let gyroTitle = NSTextField(labelWithString: "Adaptive Gyro Aiming")
        gyroTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        gyroTitle.textColor = .secondaryLabelColor
        gyroTitle.frame = NSRect(x: 12, y: 76, width: 200, height: 16)
        gyroCard.addSubview(gyroTitle)
        
        gyroSensLabel = NSTextField(labelWithString: "\(GyroEngine.shared.gyroSensitivity)%")
        gyroSensLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        gyroSensLabel.alignment = .right
        gyroSensLabel.textColor = .labelColor
        gyroSensLabel.frame = NSRect(x: 240, y: 76, width: 60, height: 16)
        gyroCard.addSubview(gyroSensLabel)
        
        gyroSegment = NSSegmentedControl(labels: ["Off", "Stick", "1:1 Mouse (L2)", "Mouse Always"], trackingMode: .selectOne, target: self, action: #selector(gyroSegmentChanged(_:)))
        gyroSegment.selectedSegment = GyroEngine.shared.gyroMode
        gyroSegment.controlSize = .small
        gyroSegment.frame = NSRect(x: 12, y: 46, width: 288, height: 22)
        gyroCard.addSubview(gyroSegment)
        
        gyroSensitivitySlider = NSSlider(value: Double(GyroEngine.shared.gyroSensitivity), minValue: 20, maxValue: 250, target: self, action: #selector(gyroSensChanged(_:)))
        gyroSensitivitySlider.controlSize = .small
        gyroSensitivitySlider.frame = NSRect(x: 12, y: 16, width: 288, height: 18)
        gyroCard.addSubview(gyroSensitivitySlider)
        
        // 4. Footer Actions
        let syncBtn = NSButton(title: "Re-Scan Bottles", target: self, action: #selector(syncBottlesClicked))
        syncBtn.bezelStyle = .rounded
        syncBtn.controlSize = .small
        syncBtn.frame = NSRect(x: 14, y: 46, width: 150, height: 26)
        view.addSubview(syncBtn)
        
        let logsBtn = NSButton(title: "Open Console", target: self, action: #selector(openLogsClicked))
        logsBtn.bezelStyle = .rounded
        logsBtn.controlSize = .small
        logsBtn.frame = NSRect(x: 176, y: 46, width: 150, height: 26)
        view.addSubview(logsBtn)
        
        let quitBtn = NSButton(title: "Quit Driver", target: self, action: #selector(quitClicked))
        quitBtn.bezelStyle = .inline
        quitBtn.controlSize = .small
        quitBtn.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        quitBtn.frame = NSRect(x: 14, y: 14, width: 312, height: 20)
        view.addSubview(quitBtn)
    }
    
    private func createCardView(frame: NSRect) -> NSView {
        let box = NSView(frame: frame)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.6).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
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
            batteryBadge.stringValue = "Off"
            batteryBadge.textColor = .secondaryLabelColor
            batteryBadge.backgroundColor = NSColor(white: 0.5, alpha: 0.15)
            connectionSubLabel.stringValue = "Turn on DualShock 4"
            engineBadge.stringValue = "⚡ Engine: Waiting for Game..."
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
            batteryBadge.stringValue = "\(chargeIcon)\(batt.level)%"
            batteryBadge.textColor = batt.level <= 15 ? NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0) : NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1.0)
            AppDelegate.shared?.updateStatusIcon(connected: true, batteryPct: batt.level, isCharging: batt.isCharging)
        } else {
            batteryBadge.stringValue = "Ready"
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
        pop.contentSize = NSSize(width: 340, height: 430)
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
