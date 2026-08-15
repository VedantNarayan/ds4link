# 🚀 DS4Link v2.0.0 — Universal Autonomous Edition

**DS4Link v2.0.0** is a monumental update that transforms DS4Link from a simple rumble utility into the **most advanced, zero-configuration DualShock 4 driver suite on macOS**.

---

### 🌟 What's New in v2.0.0

#### 1. 🧠 Autonomous Game Engine DNA Resolver
* Automatically detects game engines in real time upon launch and self-configures hardware profiles with **zero user intervention**:
  * **Capcom RE Engine** (*Resident Evil 2/3/4/7/8*, *DMC5*): Engages **Anti-Flicker Motion Aiming**, preventing button prompts from oscillating between $\text{L2}$ and $\text{Right Click}$.
  * **Sony First-Party PC Ports** (*Spider-Man*, *Miles Morales*, *Horizon*, *God of War*): Automatically routes **DualShock 4 Touchpad clicks** to open in-game maps and enables 1:1 spatial aiming.
  * **Turn 10 ForzaTech** (*Forza Horizon 4/5*, *Motorsport*): Synthesizes **4-Motor Impulse Trigger Haptics**, converting tire slip and brake lockup into distinct high-frequency vibrations.
  * **Unity Engine** (*We Were Here*, *Subnautica*, *Cuphead*, *Hollow Knight*): Isolates DirectInput to prevent duplicate "Ghost Player 2" spawns and neutralizes memory leaks.
  * **Unreal Engine 4 & 5** (*Jedi Survivor*, *Black Myth: Wukong*, *Avatar*, *Stalker 2*): Unlocks 120Hz 1:1 raw mouse delta aiming when aiming down sights (L2).

#### 2. 🎯 True 1:1 Mouse-Delta Gyro Motion Aiming (`SendInput`)
* Replaces floaty analog-stick emulation with raw Windows **Mouse Delta Injection (`SendInput`)**.
* Holding **L2 (Aim)** engages razor-sharp, zero-acceleration motion aiming identical to Nintendo Switch and Steam Deck hardware.

#### 3. 📳 Dual-Motor CoreHaptics Vibration Engine
* Zero-latency Bluetooth rumble powered by Apple's `CHHapticEngine`.
* Includes an intelligent safety watchdog that automatically cuts motor power after 1.0s of silence if a game crashes or closes.

#### 4. 🛡️ Radial Anti-Drift & Anti-Sky-Lock Hardware Deadzones
* Eliminates stick jitter and permanent camera panning ("looking at the sky") by applying circular vector magnitude deadzones and trigger threshold clamping.

#### 5. 🎨 Native macOS Control Center Interface
* Sits discretely in your macOS menu bar as a native SF Symbol (`gamecontroller.fill`), occupying less than **35 pixels** of space with live battery percentage (**`[🎮] 25%`** or **`[🎮] ⚡25%`**).
* Clicking drops down a translucent frosted-glass Control Center popover with live game status, haptic intensity slider, gyro mode selectors, and one-click bottle synchronization.

#### 6. 📡 Bluetooth Bandwidth Optimizer
* Slashes redundant Bluetooth radio packet traffic by **~85%**, preventing radio congestion, audio lag, and stutter with AirPods or wireless headphones.

---

### 📦 Installation

1. Download **`DS4Link.dmg`** below.
2. Drag **`DS4Link.app`** into your **`/Applications`** folder.
3. Turn on your DualShock 4, open **Heroic**, **CrossOver**, or **Steam**, and enjoy!
