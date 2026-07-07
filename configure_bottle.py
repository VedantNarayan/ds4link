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
        new_sys_lines.append('"Enable IOHID"=dword:00000001')
        new_sys_lines.append('"Enable GCHelper"=dword:00000000')
        in_winebus_section = False
        new_sys_lines.append(line)
        continue
        
    if in_winebus_section:
        if strip_line.startswith('"DisableHidraw"='):
            new_sys_lines.append('"DisableHidraw"=dword:00000000')
        elif strip_line.startswith('"Enable SDL"='):
            new_sys_lines.append('"Enable SDL"=dword:00000000')
        elif (strip_line.startswith('"DisableInput"=') or 
              strip_line.startswith('"DisableInputServices"=') or 
              strip_line.startswith('"Enable IOHID"=') or 
              strip_line.startswith('"Enable GCHelper"=')):
            continue
        else:
            new_sys_lines.append(line)
    else:
        new_sys_lines.append(line)

with open(sys_reg_path, "w", encoding="utf-8") as f:
    f.write("\n".join(new_sys_lines) + "\n")
print("system.reg: Configured macOS raw IOHID backend and disabled SDL translation.")


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
            # Skip existing dinput8 setting to avoid duplicates
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
print("user.reg: Configured DLL override for dinput8 to native,builtin.")
