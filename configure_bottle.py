import os
import shutil

# 1. Configure system.reg (winebus backend settings)
sys_reg_path = "/Volumes/Mac_EXT/CrossOverData/CrossOver/Bottles/Steam/system.reg"
sys_backup_path = sys_reg_path + ".bak"

if not os.path.exists(sys_backup_path):
    print(f"Creating system.reg backup at: {sys_backup_path}")
    shutil.copy2(sys_reg_path, sys_backup_path)

with open(sys_reg_path, "r", encoding="utf-8", errors="ignore") as f:
    sys_content = f.read()

sys_lines = sys_content.splitlines()
in_winebus_section = False
new_sys_lines = []

for line in sys_lines:
    strip_line = line.strip()
    if strip_line.startswith("[System\\\\CurrentControlSet\\\\Services\\\\winebus]"):
        in_winebus_section = True
        new_sys_lines.append(line)
        continue
    elif strip_line.startswith("[") and in_winebus_section:
        new_sys_lines.append('"Enable SDL"=dword:00000001')
        new_sys_lines.append('"Enable IOHID"=dword:00000000')
        new_sys_lines.append('"Enable GCHelper"=dword:00000000')
        in_winebus_section = False
        new_sys_lines.append(line)
        continue
        
    if in_winebus_section:
        if strip_line.startswith('"DisableHidraw"='):
            new_sys_lines.append('"DisableHidraw"=dword:00000000')
        elif (strip_line.startswith('"DisableInput"=') or 
              strip_line.startswith('"DisableInputServices"=') or 
              strip_line.startswith('"Enable SDL"=') or 
              strip_line.startswith('"Enable IOHID"=') or 
              strip_line.startswith('"Enable GCHelper"=')):
            continue
        else:
            new_sys_lines.append(line)
    else:
        new_sys_lines.append(line)

with open(sys_reg_path, "w", encoding="utf-8") as f:
    f.write("\n".join(new_sys_lines) + "\n")
print("system.reg: Configured macOS SDL backend (with Gyro support) and disabled IOHID/GCHelper.")


# 2. Configure user.reg (DLL overrides)
user_reg_path = "/Volumes/Mac_EXT/CrossOverData/CrossOver/Bottles/Steam/user.reg"
user_backup_path = user_reg_path + ".bak"

if not os.path.exists(user_backup_path):
    print(f"Creating user.reg backup at: {user_backup_path}")
    shutil.copy2(user_reg_path, user_backup_path)

with open(user_reg_path, "r", encoding="utf-8", errors="ignore") as f:
    user_content = f.read()

user_lines = user_content.splitlines()
in_override_section = False
new_user_lines = []
dinput8_added = False

for line in user_lines:
    strip_line = line.strip()
    if strip_line.startswith("[Software\\\\Wine\\\\DllOverrides]"):
        in_override_section = True
        new_user_lines.append(line)
        new_user_lines.append('"dinput8"="native,builtin"')
        dinput8_added = True
        continue
    elif strip_line.startswith("[") and in_override_section:
        in_override_section = False
        new_user_lines.append(line)
        continue
        
    if in_override_section:
        if strip_line.startswith('"dinput8"='):
            # Skip existing dinput8 overrides to avoid duplicates
            continue
        elif strip_line.startswith('"dxgi"='):
            # Explicitly remove dxgi override
            continue
        else:
            new_user_lines.append(line)
    else:
        new_user_lines.append(line)

# If section wasn't found at all, append it at the end
if not dinput8_added:
    new_user_lines.append("")
    new_user_lines.append("[Software\\\\Wine\\\\DllOverrides]")
    new_user_lines.append('"dinput8"="native,builtin"')

with open(user_reg_path, "w", encoding="utf-8") as f:
    f.write("\n".join(new_user_lines) + "\n")
print("user.reg: Configured DLL overrides for dinput8 to native,builtin.")


# 3. Disable Steam's raw HID rumble for Horizon Forbidden West in localconfig.vdf
localconfig_path = "/Volumes/Mac_EXT/CrossOverData/CrossOver/Bottles/Steam/drive_c/program files (x86)/Steam/userdata/1122884104/config/localconfig.vdf"
if os.path.exists(localconfig_path):
    with open(localconfig_path, "r", encoding="utf-8", errors="ignore") as f:
        lc_content = f.read()
    
    # Add app 2109700 with rumble disabled if not present
    if '"2109700"' not in lc_content:
        # Insert before the closing brace of the "apps" block
        lc_content = lc_content.replace(
            '\t}\n\t"controller_config"',
            '\t\t"2109700"\n\t\t{\n\t\t\t"UseSteamControllerConfig"\t\t"2"\n\t\t\t"SteamControllerRumble"\t\t"0"\n\t\t\t"SteamControllerRumbleIntensity"\t\t"0"\n\t\t}\n\t}\n\t"controller_config"'
        )
    else:
        # If app exists, set rumble to 0
        import re
        # Match the 2109700 block and replace rumble settings
        lc_content = re.sub(
            r'("2109700"\s*\{[^}]*"SteamControllerRumble"\s*")([^"]*)',
            r'\g<1>0',
            lc_content
        )
        lc_content = re.sub(
            r'("2109700"\s*\{[^}]*"SteamControllerRumbleIntensity"\s*")([^"]*)',
            r'\g<1>0',
            lc_content
        )
    
    # Also disable rumble globally for all existing apps
    lc_content = lc_content.replace('"SteamControllerRumble"\t\t"-1"', '"SteamControllerRumble"\t\t"0"')
    
    with open(localconfig_path, "w", encoding="utf-8") as f:
        f.write(lc_content)
    print("localconfig.vdf: Disabled SteamControllerRumble for all apps including Horizon Forbidden West.")
else:
    print(f"WARNING: localconfig.vdf not found at {localconfig_path}")


# 4. Set SDL environment variables in Wine's registry to disable PS4 rumble at the SDL level
#    This prevents the Steam client process from sending raw HID rumble reports through Wine's kernel.
env_section_marker = "[System\\\\CurrentControlSet\\\\Control\\\\Session Manager\\\\Environment]"

with open(sys_reg_path, "r", encoding="utf-8", errors="ignore") as f:
    sys_content2 = f.read()

sdl_vars = {
    '"SDL_JOYSTICK_HIDAPI_PS4_RUMBLE"': '"0"',
    '"SDL_JOYSTICK_HIDAPI_PS5_RUMBLE"': '"0"',
}

sys_lines2 = sys_content2.splitlines()
in_env_section = False
env_section_found = False
new_sys_lines2 = []
added_sdl = False

for line in sys_lines2:
    strip_line = line.strip()
    if "Session Manager" in strip_line and "Environment" in strip_line:
        in_env_section = True
        env_section_found = True
        new_sys_lines2.append(line)
        continue
    elif strip_line.startswith("[") and in_env_section:
        # Add SDL vars before leaving section
        if not added_sdl:
            for key, val in sdl_vars.items():
                new_sys_lines2.append(f'{key}={val}')
            added_sdl = True
        in_env_section = False
        new_sys_lines2.append(line)
        continue

    if in_env_section:
        # Skip existing SDL rumble vars to avoid duplicates
        skip = False
        for key in sdl_vars:
            if strip_line.startswith(key.split('"')[1]):
                skip = True
                break
            if key.strip('"') in strip_line:
                skip = True
                break
        if not skip:
            new_sys_lines2.append(line)
    else:
        new_sys_lines2.append(line)

if not env_section_found:
    # Create the environment section at end of file
    new_sys_lines2.append("")
    new_sys_lines2.append("[System\\\\CurrentControlSet\\\\Control\\\\Session Manager\\\\Environment]")
    for key, val in sdl_vars.items():
        new_sys_lines2.append(f'{key}={val}')

with open(sys_reg_path, "w", encoding="utf-8") as f:
    f.write("\n".join(new_sys_lines2) + "\n")
print("system.reg: Set SDL_JOYSTICK_HIDAPI_PS4_RUMBLE=0 and SDL_JOYSTICK_HIDAPI_PS5_RUMBLE=0 to block raw HID rumble.")
