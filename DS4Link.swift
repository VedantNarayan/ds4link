import Cocoa
import GameController
import CoreHaptics

// Global log writing function that writes to file, console, and UI
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
    AppDelegate.shared?.appendLog(message)
}

// Helpers for CrossOver bottles and DLL deployment
func getBottlesPath() -> URL {
    if let customPath = UserDefaults.standard.string(forKey: "customBottlesPath") {
        return URL(fileURLWithPath: customPath)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
}

func listBottles() -> [String] {
    let path = getBottlesPath()
    do {
        let contents = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }.map { $0.lastPathComponent }
    } catch {
        return []
    }
}

func getSteamCommonPath(bottleName: String) -> URL {
    let bottlePath = getBottlesPath().appendingPathComponent(bottleName)
    return bottlePath.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common")
}

func listGames(bottleName: String) -> [String] {
    let path = getSteamCommonPath(bottleName: bottleName)
    do {
        let contents = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }.map { $0.lastPathComponent }
    } catch {
        return []
    }
}

func patchRegistry(bottleName: String) -> Bool {
    let bottlePath = getBottlesPath().appendingPathComponent(bottleName)
    let sysReg = bottlePath.appendingPathComponent("system.reg")
    let userReg = bottlePath.appendingPathComponent("user.reg")
    
    guard FileManager.default.fileExists(atPath: sysReg.path) else { return false }
    guard FileManager.default.fileExists(atPath: userReg.path) else { return false }
    
    do {
        // 1. Patch system.reg (winebus backend settings)
        let sysContent = try String(contentsOf: sysReg, encoding: .utf8)
        let sysBackup = sysReg.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: sysBackup.path) {
            try sysContent.write(to: sysBackup, atomically: true, encoding: .utf8)
        }
        
        let sysLines = sysContent.components(separatedBy: .newlines)
        var newSysLines: [String] = []
        var inWinebus = false
        
        for line in sysLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "[System\\\\CurrentControlSet\\\\Services\\\\winebus]") {
                inWinebus = true
                newSysLines.append(line)
                continue
            } else if trimmed.starts(with: "[") && inWinebus {
                newSysLines.append("\"Enable IOHID\"=dword:00000001")
                newSysLines.append("\"Enable GCHelper\"=dword:00000000")
                inWinebus = false
                newSysLines.append(line)
                continue
            }
            
            if inWinebus {
                if trimmed.starts(with: "\"DisableHidraw\"=") {
                    newSysLines.append("\"DisableHidraw\"=dword:00000000")
                } else if trimmed.starts(with: "\"Enable SDL\"=") {
                    newSysLines.append("\"Enable SDL\"=dword:00000000")
                } else if trimmed.starts(with: "\"DisableInput\"=") ||
                            trimmed.starts(with: "\"DisableInputServices\"=") ||
                            trimmed.starts(with: "\"Enable IOHID\"=") ||
                            trimmed.starts(with: "\"Enable GCHelper\"=") {
                    continue
                } else {
                    newSysLines.append(line)
                }
            } else {
                newSysLines.append(line)
            }
        }
        try newSysLines.joined(separator: "\n").write(to: sysReg, atomically: true, encoding: .utf8)
        
        // 2. Patch user.reg (DLL overrides)
        let userContent = try String(contentsOf: userReg, encoding: .utf8)
        let userBackup = userReg.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: userBackup.path) {
            try userContent.write(to: userBackup, atomically: true, encoding: .utf8)
        }
        
        let userLines = userContent.components(separatedBy: .newlines)
        var newUserLines: [String] = []
        var inOverrides = false
        var dinput8Added = false
        var dxgiAdded = false
        
        for line in userLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "[Software\\\\Wine\\\\DllOverrides]") {
                inOverrides = true
                newUserLines.append(line)
                newUserLines.append("\"dinput8\"=\"native,builtin\"")
                newUserLines.append("\"dxgi\"=\"native,builtin\"")
                dinput8Added = true
                dxgiAdded = true
                continue
            } else if trimmed.starts(with: "[") && inOverrides {
                inOverrides = false
                newUserLines.append(line)
                continue
            }
            
            if inOverrides {
                if trimmed.starts(with: "\"dinput8\"=") || trimmed.starts(with: "\"dxgi\"=") {
                    continue
                } else {
                    newUserLines.append(line)
                }
            } else {
                newUserLines.append(line)
            }
        }
        
        if !dinput8Added || !dxgiAdded {
            newUserLines.append("")
            newUserLines.append("[Software\\\\Wine\\\\DllOverrides]")
            if !dinput8Added {
                newUserLines.append("\"dinput8\"=\"native,builtin\"")
            }
            if !dxgiAdded {
                newUserLines.append("\"dxgi\"=\"native,builtin\"")
            }
        }
        try newUserLines.joined(separator: "\n").write(to: userReg, atomically: true, encoding: .utf8)
        
        return true
    } catch {
        writeLog("[App] Registry configuration failed: \(error)")
        return false
    }
}

func deploySteamDLL(bottleName: String) -> Bool {
    let bottlePath = getBottlesPath().appendingPathComponent(bottleName)
    let steamDir = bottlePath.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    guard FileManager.default.fileExists(atPath: steamDir.path) else { return false }
    
    let dest = steamDir.appendingPathComponent("dinput8.dll")
    guard let src = Bundle.main.path(forResource: "dinput8_32", ofType: "dll") else {
        writeLog("[App] Error: dinput8_32.dll not found in app bundle.")
        return false
    }
    
    do {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(atPath: src, toPath: dest.path)
        return true
    } catch {
        writeLog("[App] Failed to copy dinput8_32.dll: \(error)")
        return false
    }
}

func deployGameDLL(bottleName: String, gameName: String) -> Bool {
    let gameDir = getSteamCommonPath(bottleName: bottleName).appendingPathComponent(gameName)
    guard FileManager.default.fileExists(atPath: gameDir.path) else { return false }
    
    // Clean up any old dxgi/dinput8 DLLs
    let oldDxgi = gameDir.appendingPathComponent("dxgi.dll")
    let oldDxgiOrig = gameDir.appendingPathComponent("dxgi_original.dll")
    let oldDinput8 = gameDir.appendingPathComponent("dinput8.dll")
    try? FileManager.default.removeItem(at: oldDxgi)
    try? FileManager.default.removeItem(at: oldDxgiOrig)
    try? FileManager.default.removeItem(at: oldDinput8)
    
    let originalDest = gameDir.appendingPathComponent("steam_api64_original.dll")
    let dest = gameDir.appendingPathComponent("steam_api64.dll")
    
    guard let src = Bundle.main.path(forResource: "steam_api64", ofType: "dll") else {
        writeLog("[App] Error: steam_api64.dll not found in app bundle.")
        return false
    }
    
    do {
        // Backup the original steam_api64.dll from the game folder
        if FileManager.default.fileExists(atPath: dest.path) && !FileManager.default.fileExists(atPath: originalDest.path) {
            try FileManager.default.copyItem(atPath: dest.path, toPath: originalDest.path)
            writeLog("[App] Created backup steam_api64_original.dll")
        }
        
        // Copy our proxy
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(atPath: src, toPath: dest.path)
        writeLog("[App] Deployed steam_api64.dll proxy successfully.")
        return true
    } catch {
        writeLog("[App] Failed to deploy steam_api64.dll proxy: \(error)")
        return false
    }
}

func deployManualDLL(targetFolder: URL) -> Bool {
    let dest = targetFolder.appendingPathComponent("steam_api64.dll")
    let originalDest = targetFolder.appendingPathComponent("steam_api64_original.dll")
    
    // Clean up old dxgi/dinput8 DLLs
    let oldDxgi = targetFolder.appendingPathComponent("dxgi.dll")
    let oldDxgiOrig = targetFolder.appendingPathComponent("dxgi_original.dll")
    let oldDinput8 = targetFolder.appendingPathComponent("dinput8.dll")
    try? FileManager.default.removeItem(at: oldDxgi)
    try? FileManager.default.removeItem(at: oldDxgiOrig)
    try? FileManager.default.removeItem(at: oldDinput8)
    
    guard let src = Bundle.main.path(forResource: "steam_api64", ofType: "dll") else {
        writeLog("[App] Error: steam_api64.dll not found in app bundle.")
        return false
    }
    
    do {
        // Backup original steam_api64.dll
        if FileManager.default.fileExists(atPath: dest.path) && !FileManager.default.fileExists(atPath: originalDest.path) {
            try FileManager.default.copyItem(atPath: dest.path, toPath: originalDest.path)
            writeLog("[App] Created backup steam_api64_original.dll")
        }
        
        // Copy proxy
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(atPath: src, toPath: dest.path)
        writeLog("[App] Deployed manual steam_api64.dll proxy successfully.")
        return true
    } catch {
        writeLog("[App] Failed to copy manual steam_api64.dll: \(error)")
        return false
    }
}

class HapticBridge: NSObject {
    static let shared = HapticBridge()
    
    private var leftEngine: CHHapticEngine?
    private var rightEngine: CHHapticEngine?
    private var leftPlayer: CHHapticPatternPlayer?
    private var rightPlayer: CHHapticPatternPlayer?
    private var currentController: GCController?
    
    private var targetLeft: Float = 0.0
    private var targetRight: Float = 0.0
    private let stateLock = NSLock()
    
    /// User-adjustable rumble intensity (0.0 to 1.0). Stored in UserDefaults.
    var rumbleIntensity: Float {
        get { UserDefaults.standard.float(forKey: "rumbleIntensity") }
        set { UserDefaults.standard.set(newValue, forKey: "rumbleIntensity") }
    }
    
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["rumbleIntensity": Float(0.25)])
    }
    
    var onControllerStatusChanged: ((String) -> Void)?
    
    override init() {
        super.init()
        writeLog("[App] HapticBridge init starting...")
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnect), name: .GCControllerDidDisconnect, object: nil)
        
        // Find already connected controller
        if let controller = GCController.controllers().first {
            writeLog("[App] Found already connected controller: \(controller.vendorName ?? "Unknown")")
            setupController(controller)
        }
    }
    
    @objc private func controllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            writeLog("[App] Controller connected: \(controller.vendorName ?? "Unknown")")
            setupController(controller)
        }
    }
    
    @objc private func controllerDidDisconnect(_ notification: Notification) {
        if let controller = notification.object as? GCController, controller == currentController {
            writeLog("[App] Controller disconnected: \(controller.vendorName ?? "Unknown")")
            clearController()
        }
    }
    
    private func setupController(_ controller: GCController) {
        currentController = controller
        guard let haptics = controller.haptics else {
            writeLog("[App] Controller \(controller.vendorName ?? "") does not support haptics.")
            onControllerStatusChanged?("Connected (No Haptics)")
            return
        }
        
        let localities = haptics.supportedLocalities
        writeLog("[App] Supported haptic localities: \(localities)")
        
        do {
            if localities.contains(.leftHandle) {
                leftEngine = haptics.createEngine(withLocality: .leftHandle)
            }
            if localities.contains(.rightHandle) {
                rightEngine = haptics.createEngine(withLocality: .rightHandle)
            }
            
            // Fallback to default locality if none specified
            if leftEngine == nil && rightEngine == nil, let firstLocality = localities.first {
                leftEngine = haptics.createEngine(withLocality: firstLocality)
                rightEngine = leftEngine
            }
            
            try leftEngine?.start()
            if rightEngine != leftEngine {
                try rightEngine?.start()
            }
            
            let name = controller.vendorName ?? "Wireless Controller"
            onControllerStatusChanged?("Connected: \(name)")
            writeLog("[App] Haptic engines initialized successfully for: \(name)")
        } catch {
            writeLog("[App] Haptic engine start failed: \(error)")
            onControllerStatusChanged?("Haptics Init Error")
        }
    }
    
    private func clearController() {
        writeLog("[App] Clearing controller...")
        leftEngine = nil
        rightEngine = nil
        leftPlayer = nil
        rightPlayer = nil
        currentController = nil
        onControllerStatusChanged?("Disconnected")
    }
    
    func updateRumbleTarget(left: Float, right: Float) {
        stateLock.lock()
        targetLeft = left
        targetRight = right
        lastUpdateTime = CACurrentMediaTime()
        stateLock.unlock()
        
        // Direct haptic update — no main queue dispatch for minimum latency
        setRumble(left: left, right: right)
        
        // Ensure watchdog timer is running
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
                writeLog("[App] Watchdog: No updates for 1s. Stopping rumble.")
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
        
        // Dead zone: ignore low rumble values (ambient noise floor)
        let deadZone: Float = 0.3
        let l = left < deadZone ? 0.0 : left
        let r = right < deadZone ? 0.0 : right
        
        do {
            // Apply non-linear curve: square root for more dynamic range
            // Then scale by user's rumble intensity preference
            let userScale = rumbleIntensity
            let lScaled = userScale < 0.01 ? 0.0 : (sqrt(l) * userScale)
            let rScaled = userScale < 0.01 ? 0.0 : (sqrt(r) * userScale)
            
            // Low sharpness = smooth, bassy rumble (like a real controller motor)
            let sharpnessValue: Float = 0.3
            
            // Fallback path (single engine for both sides)
            if leftEngine == rightEngine, let engine = leftEngine {
                let val = max(lScaled, rScaled)
                if leftPlayer == nil {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessValue)
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 3600.0)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    leftPlayer = try engine.makePlayer(with: pattern)
                    try leftPlayer?.start(atTime: 0)
                }
                let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: val, relativeTime: 0)
                try leftPlayer?.sendParameters([param], atTime: 0)
                return
            }
            
            // Main left/right handle path
            if let engine = leftEngine {
                if leftPlayer == nil {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessValue)
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 3600.0)
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
                    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessValue)
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 3600.0)
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
        writeLog("[App] Triggering controller rumble test (1.0 intensity for 1s)...")
        setRumble(left: 1.0, right: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.setRumble(left: 0.0, right: 0.0)
            writeLog("[App] Test rumble completed.")
        }
    }
    
    func controllerName() -> String {
        return currentController?.vendorName ?? "No Controller Connected"
    }
}

class BSDUDPServer {
    private var socketFileDescriptor: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.antigravity.rumblebridge.udp", qos: .userInteractive)
    
    func start(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 {
            writeLog("[App] Socket creation failed")
            return
        }
        
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if bindResult < 0 {
            writeLog("[App] Socket bind failed on port \(port)")
            close(fd)
            return
        }
        
        self.socketFileDescriptor = fd
        self.isRunning = true
        writeLog("[App] UDP Server listening on port \(port)")
        
        queue.async { [weak self] in
            self?.runLoop()
        }
    }
    
    private func runLoop() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while isRunning {
            let bytesRead = recv(socketFileDescriptor, &buffer, buffer.count, 0)
            if bytesRead > 0 {
                if buffer[0] == 0x01 && bytesRead >= 3 {
                    let left = Float(buffer[1]) / 255.0
                    let right = Float(buffer[2]) / 255.0
                    HapticBridge.shared.updateRumbleTarget(left: left, right: right)
                } else {
                    let data = Data(buffer[0..<Int(bytesRead)])
                    if let msg = String(data: data, encoding: .utf8) {
                        writeLog("DLL: \(msg)")
                    }
                }
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

// Beautiful tabbed main view controller
class MainViewController: NSViewController {
    static var shared: MainViewController? = nil
    var tabView: NSTabView!
    var segmentedControl: NSSegmentedControl!
    
    // Tab 1: Bridge Monitor
    var statusLabel: NSTextField!
    var testButton: NSButton!
    var intensitySlider: NSSlider!
    var intensityLabel: NSTextField!
    var logScrollView: NSScrollView!
    var logTextView: NSTextView!
    var clearButton: NSButton!
    var quitButton: NSButton!
    
    // Tab 2: CrossOver Setup
    var bottlePopUp: NSPopUpButton!
    var configRegButton: NSButton!
    var installSteamBtn: NSButton!
    var gamesScrollView: NSScrollView!
    var gamesStackView: NSStackView!
    var manualDeployBtn: NSButton!
    
    override func loadView() {
        MainViewController.shared = self
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        self.view = view
        view.wantsLayer = true
        
        // 1. Create a modern Segmented Control at the top
        segmentedControl = NSSegmentedControl(labels: ["Bridge Monitor", "CrossOver Setup"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        segmentedControl.selectedSegment = 0
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmentedControl)
        
        // 2. Create NSTabView with NO tabs, NO border (fully handled by Segmented Control)
        tabView = NSTabView()
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabView)
        
        // Setup Tab 1: Controller Bridge
        let tab1 = NSTabViewItem(identifier: "bridge")
        let view1 = NSView()
        setupBridgeView(view1)
        tab1.view = view1
        tabView.addTabViewItem(tab1)
        
        // Setup Tab 2: CrossOver Setup
        let tab2 = NSTabViewItem(identifier: "setup")
        let view2 = NSView()
        setupCrossOverView(view2)
        tab2.view = view2
        tabView.addTabViewItem(tab2)
        
        // Constraints
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            segmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            segmentedControl.heightAnchor.constraint(equalToConstant: 24),
            
            tabView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 15),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -15)
        ])
    }
    
    @objc func segmentChanged(_ sender: NSSegmentedControl) {
        tabView.selectTabViewItem(at: sender.selectedSegment)
    }
    
    func setupBridgeView(_ parent: NSView) {
        statusLabel = NSTextField(labelWithString: "Controller: Checking...")
        statusLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        statusLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(statusLabel)
        
        testButton = NSButton(title: "Test Rumble", target: self, action: #selector(testRumbleClicked))
        testButton.bezelStyle = .rounded
        testButton.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(testButton)
        
        // Rumble Intensity Slider
        let sliderLabel = NSTextField(labelWithString: "Rumble Intensity:")
        sliderLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sliderLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        sliderLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(sliderLabel)
        
        intensitySlider = NSSlider(value: Double(HapticBridge.shared.rumbleIntensity * 100), minValue: 0, maxValue: 100, target: self, action: #selector(intensitySliderChanged(_:)))
        intensitySlider.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(intensitySlider)
        
        intensityLabel = NSTextField(labelWithString: "\(Int(HapticBridge.shared.rumbleIntensity * 100))%")
        intensityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        intensityLabel.textColor = NSColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
        intensityLabel.alignment = .right
        intensityLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(intensityLabel)
        
        logScrollView = NSScrollView()
        logScrollView.hasVerticalScroller = true
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.drawsBackground = false
        logScrollView.borderType = .noBorder
        
        logTextView = NSTextView()
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.textColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0) // Console blue
        logTextView.backgroundColor = NSColor(white: 0.0, alpha: 0.35)
        logTextView.font = NSFont.userFixedPitchFont(ofSize: 11)
        logTextView.minSize = NSSize(width: 0, height: 0)
        logTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.containerSize = NSSize(width: 410, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.widthTracksTextView = true
        
        logScrollView.documentView = logTextView
        parent.addSubview(logScrollView)
        
        clearButton = NSButton(title: "Clear Console", target: self, action: #selector(clearLogsClicked))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(clearButton)
        
        quitButton = NSButton(title: "Quit App", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .rounded
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(quitButton)
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -20),
            
            testButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            testButton.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            testButton.widthAnchor.constraint(equalToConstant: 180),
            testButton.heightAnchor.constraint(equalToConstant: 26),
            
            sliderLabel.topAnchor.constraint(equalTo: testButton.bottomAnchor, constant: 12),
            sliderLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            
            intensitySlider.centerYAnchor.constraint(equalTo: sliderLabel.centerYAnchor),
            intensitySlider.leadingAnchor.constraint(equalTo: sliderLabel.trailingAnchor, constant: 8),
            intensitySlider.trailingAnchor.constraint(equalTo: intensityLabel.leadingAnchor, constant: -8),
            
            intensityLabel.centerYAnchor.constraint(equalTo: sliderLabel.centerYAnchor),
            intensityLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            intensityLabel.widthAnchor.constraint(equalToConstant: 45),
            
            logScrollView.topAnchor.constraint(equalTo: sliderLabel.bottomAnchor, constant: 12),
            logScrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            logScrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            logScrollView.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -15),
            
            clearButton.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            clearButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
            clearButton.widthAnchor.constraint(equalToConstant: 120),
            clearButton.heightAnchor.constraint(equalToConstant: 26),
            
            quitButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            quitButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
            quitButton.widthAnchor.constraint(equalToConstant: 120),
            quitButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    
    func setupCrossOverView(_ parent: NSView) {
        let bottleLabel = NSTextField(labelWithString: "CrossOver Bottle:")
        bottleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        bottleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        bottleLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bottleLabel)
        
        bottlePopUp = NSPopUpButton()
        bottlePopUp.translatesAutoresizingMaskIntoConstraints = false
        bottlePopUp.target = self
        bottlePopUp.action = #selector(bottleSelected(_:))
        parent.addSubview(bottlePopUp)
        
        let browseBottlesBtn = NSButton(title: "Browse...", target: self, action: #selector(browseBottlesClicked))
        browseBottlesBtn.bezelStyle = .rounded
        browseBottlesBtn.controlSize = .small
        browseBottlesBtn.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(browseBottlesBtn)
        
        configRegButton = NSButton(title: "Configure Wine Registry", target: self, action: #selector(configRegClicked))
        configRegButton.bezelStyle = .rounded
        configRegButton.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(configRegButton)
        
        installSteamBtn = NSButton(title: "Install Steam Support", target: self, action: #selector(installSteamClicked))
        installSteamBtn.bezelStyle = .rounded
        installSteamBtn.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(installSteamBtn)
        
        let gamesLabel = NSTextField(labelWithString: "Detected Steam Games:")
        gamesLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        gamesLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        gamesLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(gamesLabel)
        
        gamesScrollView = NSScrollView()
        gamesScrollView.hasVerticalScroller = true
        gamesScrollView.translatesAutoresizingMaskIntoConstraints = false
        gamesScrollView.drawsBackground = true
        gamesScrollView.backgroundColor = NSColor(white: 0.05, alpha: 0.45) // Darker background for contrast
        gamesScrollView.borderType = .bezelBorder
        
        gamesStackView = NSStackView()
        gamesStackView.orientation = .vertical
        gamesStackView.alignment = .leading
        gamesStackView.spacing = 8
        gamesStackView.translatesAutoresizingMaskIntoConstraints = false
        gamesStackView.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        
        gamesScrollView.documentView = gamesStackView
        parent.addSubview(gamesScrollView)
        
        manualDeployBtn = NSButton(title: "Select Game Folder Manually...", target: self, action: #selector(manualDeployClicked))
        manualDeployBtn.bezelStyle = .rounded
        manualDeployBtn.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(manualDeployBtn)
        
        NSLayoutConstraint.activate([
            bottleLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10),
            bottleLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            
            bottlePopUp.centerYAnchor.constraint(equalTo: bottleLabel.centerYAnchor),
            bottlePopUp.leadingAnchor.constraint(equalTo: bottleLabel.trailingAnchor, constant: 10),
            bottlePopUp.trailingAnchor.constraint(equalTo: browseBottlesBtn.leadingAnchor, constant: -10),
            
            browseBottlesBtn.centerYAnchor.constraint(equalTo: bottleLabel.centerYAnchor),
            browseBottlesBtn.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            browseBottlesBtn.widthAnchor.constraint(equalToConstant: 80),
            
            configRegButton.topAnchor.constraint(equalTo: bottlePopUp.bottomAnchor, constant: 12),
            configRegButton.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            configRegButton.widthAnchor.constraint(equalToConstant: 215),
            configRegButton.heightAnchor.constraint(equalToConstant: 26),
            
            installSteamBtn.topAnchor.constraint(equalTo: bottlePopUp.bottomAnchor, constant: 12),
            installSteamBtn.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            installSteamBtn.widthAnchor.constraint(equalToConstant: 215),
            installSteamBtn.heightAnchor.constraint(equalToConstant: 26),
            
            gamesLabel.topAnchor.constraint(equalTo: configRegButton.bottomAnchor, constant: 20),
            gamesLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            
            gamesScrollView.topAnchor.constraint(equalTo: gamesLabel.bottomAnchor, constant: 8),
            gamesScrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            gamesScrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            gamesScrollView.bottomAnchor.constraint(equalTo: manualDeployBtn.topAnchor, constant: -12),
            
            gamesStackView.widthAnchor.constraint(equalTo: gamesScrollView.contentView.widthAnchor),
            
            manualDeployBtn.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 15),
            manualDeployBtn.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -15),
            manualDeployBtn.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
            manualDeployBtn.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        updateControllerStatus()
    }
    
    func refreshBottles() {
        bottlePopUp.removeAllItems()
        let bottles = listBottles()
        bottlePopUp.addItems(withTitles: bottles)
        if bottles.contains("Steam") {
            bottlePopUp.selectItem(withTitle: "Steam")
        }
        refreshGamesList()
    }
    
    func refreshGamesList() {
        for subview in gamesStackView.views {
            gamesStackView.removeView(subview)
            subview.removeFromSuperview()
        }
        
        guard let selectedBottle = bottlePopUp.titleOfSelectedItem else { return }
        let games = listGames(bottleName: selectedBottle)
        
        if games.isEmpty {
            let label = NSTextField(labelWithString: "No Steam games detected in this bottle.")
            label.font = NSFont.systemFont(ofSize: 12, weight: .light)
            label.textColor = NSColor(white: 0.7, alpha: 1.0)
            gamesStackView.addView(label, in: .top)
            return
        }
        
        for game in games {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fill
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            
            let label = NSTextField(labelWithString: game)
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = NSColor(white: 0.95, alpha: 1.0) // Highly readable crisp white
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addView(label, in: .leading)
            
            let dest = getSteamCommonPath(bottleName: selectedBottle).appendingPathComponent(game).appendingPathComponent("dxgi.dll")
            let isInstalled = FileManager.default.fileExists(atPath: dest.path)
            
            let statusLabel = NSTextField(labelWithString: isInstalled ? "Active" : "Not Active")
            statusLabel.textColor = isInstalled ? NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0) : NSColor(white: 0.7, alpha: 1.0)
            statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            row.addView(statusLabel, in: .trailing)
            
            let actionBtn = NSButton(title: isInstalled ? "Update" : "Install", target: self, action: #selector(installGameDllClicked(_:)))
            actionBtn.identifier = NSUserInterfaceItemIdentifier(game)
            actionBtn.bezelStyle = .rounded
            actionBtn.controlSize = .small
            row.addView(actionBtn, in: .trailing)
            
            gamesStackView.addView(row, in: .top)
            
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: gamesStackView.widthAnchor, constant: -20)
            ])
        }
    }
    
    @objc func bottleSelected(_ sender: NSPopUpButton) {
        refreshGamesList()
    }
    
    @objc func browseBottlesClicked() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select CrossOver Bottles Folder"
        
        openPanel.begin { [weak self] response in
            if response == .OK, let url = openPanel.url {
                UserDefaults.standard.set(url.path, forKey: "customBottlesPath")
                writeLog("[App] Custom bottles path selected: \(url.path)")
                self?.refreshBottles()
            }
        }
    }
    
    @objc func configRegClicked() {
        guard let selected = bottlePopUp.titleOfSelectedItem else { return }
        if patchRegistry(bottleName: selected) {
            writeLog("[App] Registry configuration successful for bottle: \(selected)")
            showDialog(message: "Registry configured successfully!", info: "Raw IOHID has been enabled and SDL translation has been disabled for bottle '\(selected)'.")
        } else {
            writeLog("[App] Registry configuration failed for bottle: \(selected)")
            showDialog(message: "Registry configuration failed", info: "Please ensure the bottle exists and has system.reg/user.reg files.")
        }
    }
    
    @objc func installSteamClicked() {
        guard let selected = bottlePopUp.titleOfSelectedItem else { return }
        if deploySteamDLL(bottleName: selected) {
            writeLog("[App] Copied dinput8_32.dll to Steam folder in bottle: \(selected)")
            showDialog(message: "Steam support installed successfully!", info: "Steam support installed! Please make sure to launch the game inside Steam with Steam Input set to 'Enable'.")
        } else {
            writeLog("[App] Failed to deploy Steam DLL in bottle: \(selected)")
            showDialog(message: "Steam support installation failed", info: "Please check if Steam is installed in the selected bottle.")
        }
    }
    
    @objc func installGameDllClicked(_ sender: NSButton) {
        guard let selectedBottle = bottlePopUp.titleOfSelectedItem else { return }
        guard let gameName = sender.identifier?.rawValue else { return }
        
        if deployGameDLL(bottleName: selectedBottle, gameName: gameName) {
            writeLog("[App] Successfully deployed 64-bit dxgi.dll to game: \(gameName)")
            showDialog(message: "DLL deployed successfully!", info: "Deployed proxy dxgi.dll to game: \(gameName)")
            refreshGamesList()
        } else {
            writeLog("[App] Failed to deploy DLL to game: \(gameName)")
            showDialog(message: "DLL deployment failed", info: "Please check logs for details.")
        }
    }
    
    @objc func manualDeployClicked() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Game Installation Directory"
        
        openPanel.begin { [weak self] response in
            if response == .OK, let url = openPanel.url {
                if deployManualDLL(targetFolder: url) {
                    writeLog("[App] Manually deployed 64-bit dxgi.dll to: \(url.path)")
                    self?.showDialog(message: "Manual DLL deployed successfully!", info: "Copied proxy dxgi.dll to: \(url.lastPathComponent)")
                    self?.refreshGamesList()
                } else {
                    writeLog("[App] Failed to manually deploy DLL to: \(url.path)")
                    self?.showDialog(message: "Manual deployment failed", info: "Please check logs for details.")
                }
            }
        }
    }
    
    func showDialog(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func updateControllerStatus() {
        let name = HapticBridge.shared.controllerName()
        statusLabel.stringValue = "Controller: \(name)"
        if name.contains("No Controller") {
            statusLabel.textColor = NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
        } else {
            statusLabel.textColor = NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        }
    }
    
    @objc func testRumbleClicked() {
        HapticBridge.shared.testRumble()
    }
    
    @objc func intensitySliderChanged(_ sender: NSSlider) {
        let pct = Float(sender.doubleValue) / 100.0
        HapticBridge.shared.rumbleIntensity = pct
        intensityLabel.stringValue = "\(Int(sender.doubleValue))%"
        
        // If slider set to 0, immediately stop any active rumble
        if pct < 0.01 {
            HapticBridge.shared.updateRumbleTarget(left: 0, right: 0)
        }
    }
    
    @objc func clearLogsClicked() {
        logTextView.string = ""
    }
    
    @objc func quitClicked() {
        AppDelegate.shared?.quit()
    }
    
    func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(text)\n"
        
        logTextView.textStorage?.append(NSAttributedString(string: line, attributes: [
            .foregroundColor: NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0),
            .font: NSFont.userFixedPitchFont(ofSize: 11)!
        ]))
        
        logTextView.scrollRangeToVisible(NSRange(location: logTextView.string.count, length: 0))
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var window: NSWindow?
    let server = BSDUDPServer()
    var mainVC: MainViewController?
    
    override init() {
        super.init()
        AppDelegate.shared = self
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        HapticBridge.registerDefaults()
        NSApp.setActivationPolicy(.regular)
        
        let rect = NSRect(x: 0, y: 0, width: 500, height: 530)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        let win = NSWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        win.title = "DS4Link"
        win.center()
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        
        let effectView = NSVisualEffectView(frame: rect)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .vibrantDark)
        
        // Add a premium dark tint overlay to dim the background, resolving brightness/contrast issues
        let tintView = NSView(frame: rect)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(white: 0.02, alpha: 0.4).cgColor
        effectView.addSubview(tintView)
        
        let vc = MainViewController()
        vc.view.frame = rect
        vc.view.autoresizingMask = [.width, .height]
        
        effectView.addSubview(vc.view)
        win.contentView = effectView
        
        self.window = win
        self.mainVC = vc
        
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        writeLog("[App] Main window displayed.")
        writeLog("[App] Starting BSDUDPServer on port 24680...")
        server.start(port: 24680)
        
        HapticBridge.shared.onControllerStatusChanged = { [weak self] status in
            writeLog("[App] Controller status: \(status)")
            DispatchQueue.main.async {
                self?.mainVC?.updateControllerStatus()
            }
        }
        
        mainVC?.refreshBottles()
        appendLog("[App] DS4Link UI initialized.")
    }
    
    func appendLog(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.mainVC?.appendLog(text)
        }
    }
    
    func quit() {
        server.stop()
        NSApplication.shared.terminate(nil)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Entry Point
setbuf(stdout, nil)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
