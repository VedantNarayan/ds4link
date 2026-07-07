import os
import subprocess

image_path = "/Users/Vedant/.gemini/antigravity/brain/e37f62cf-42ba-4d9f-ad4d-ba98ae1c0eac/ds4link_icon_1783451459866.jpg"
iconset_path = "AppIcon.iconset"
output_icns = "AppIcon.icns"

# Create iconset folder
os.makedirs(iconset_path, exist_ok=True)

# Standard macOS icon sizes and names
sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

print("Resizing icons...")
for size, name in sizes:
    dest = os.path.join(iconset_path, name)
    # Use sips to resize and convert to png
    cmd = ["sips", "-s", "format", "png", "--resampleHeightWidth", str(size), str(size), image_path, "--out", dest]
    subprocess.run(cmd, stdout=subprocess.DEVNULL)

print("Compiling iconset to icns...")
cmd_compile = ["iconutil", "-c", "icns", iconset_path, "-o", output_icns]
subprocess.run(cmd_compile)

# Cleanup iconset
import shutil
shutil.rmtree(iconset_path)
print("Success! Created AppIcon.icns")
