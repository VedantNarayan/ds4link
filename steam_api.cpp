#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <setupapi.h>
#include <string>
#include <cstdint>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "setupapi.lib")

// Globals
HMODULE hOrigSteamApiDll = NULL;
HMODULE hMySelf = NULL;

typedef void* (__cdecl *SteamInternal_FindOrCreateUserInterface_t)(int, const char*);
SteamInternal_FindOrCreateUserInterface_t orig_SteamInternal_FindOrCreateUserInterface = NULL;

// UDP Client Socket
SOCKET udp_socket = INVALID_SOCKET;
sockaddr_in server_addr;

void WriteLog(const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    
    FILE* f = fopen("ds4link_proxy.log", "a");
    if (f) {
        fprintf(f, "%s", buf);
        fclose(f);
    }
    OutputDebugStringA(buf);
}

void InitUDP() {
    WSADATA wsa;
    WSAStartup(MAKEWORD(2,2), &wsa);
    udp_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(24680);
    server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
}

// Send rumble values to macOS CoreHaptics server via UDP
static void SendRumbleUDP(BYTE left_motor, BYTE right_motor) {
    unsigned char packet[3];
    packet[0] = 0x01;
    packet[1] = left_motor;
    packet[2] = right_motor;
    sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
}

// ============================================================================
// Direct SetupAPI DualShock 4 Synthesizer (VID 0x054C, PID 0x09CC with &IG_00)
// This gives native PlayStation 4 button glyphs in Decima / Sony / Nixxes engines!
// ============================================================================

static const wchar_t g_VirtualXUSBPath[] = L"\\\\?\\hid#vid_054c&pid_09cc&ig_00#0000#{ec87f1e3-c13b-4100-b5f3-0ee462bd6b9f}";
static const wchar_t g_VirtualHardwareId[] = L"USB\\VID_054C&PID_09CC&IG_00\0USB\\VID_054C&PID_09CC\0";
static const wchar_t g_VirtualDeviceDesc[] = L"Wireless Controller";
static const wchar_t g_VirtualInstanceId[] = L"USB\\VID_054C&PID_09CC&IG_00\\0000";
static const GUID k_GUID_NULL = { 0, 0, 0, { 0, 0, 0, 0, 0, 0, 0, 0 } };

BOOL WINAPI Hooked_SetupDiEnumDeviceInfo(HDEVINFO DeviceInfoSet, DWORD MemberIndex, PSP_DEVINFO_DATA DeviceInfoData) {
    if (MemberIndex == 0 && DeviceInfoData) {
        DeviceInfoData->cbSize = sizeof(SP_DEVINFO_DATA);
        DeviceInfoData->ClassGuid = k_GUID_NULL;
        DeviceInfoData->DevInst = 1;
        DeviceInfoData->Reserved = 0x1337;
        WriteLog("[SetupAPI Direct] SetupDiEnumDeviceInfo MemberIndex 0 -> Injected Virtual DualShock 4\n");
        return TRUE;
    }
    SetLastError(ERROR_NO_MORE_ITEMS);
    return FALSE;
}

BOOL WINAPI Hooked_SetupDiEnumDeviceInterfaces(HDEVINFO DeviceInfoSet, PSP_DEVINFO_DATA DeviceInfoData, const GUID* InterfaceClassGuid, DWORD MemberIndex, PSP_DEVICE_INTERFACE_DATA DeviceInterfaceData) {
    if (MemberIndex == 0 && DeviceInterfaceData) {
        DeviceInterfaceData->cbSize = sizeof(SP_DEVICE_INTERFACE_DATA);
        DeviceInterfaceData->InterfaceClassGuid = InterfaceClassGuid ? *InterfaceClassGuid : k_GUID_NULL;
        DeviceInterfaceData->Flags = SPINT_ACTIVE;
        DeviceInterfaceData->Reserved = 0x1337;
        WriteLog("[SetupAPI Direct] Injected Virtual DualShock 4 interface at MemberIndex 0\n");
        return TRUE;
    }
    SetLastError(ERROR_NO_MORE_ITEMS);
    return FALSE;
}

BOOL WINAPI Hooked_SetupDiGetDeviceInterfaceDetailW(HDEVINFO DeviceInfoSet, PSP_DEVICE_INTERFACE_DATA DeviceInterfaceData, PSP_DEVICE_INTERFACE_DETAIL_DATA_W DeviceInterfaceDetailData, DWORD DeviceInterfaceDetailDataSize, PDWORD RequiredSize, PSP_DEVINFO_DATA DeviceInfoData) {
    DWORD needed = (DWORD)(sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W) + (wcslen(g_VirtualXUSBPath) + 1) * sizeof(wchar_t));
    if (RequiredSize) *RequiredSize = needed;
    
    if (DeviceInterfaceDetailData && DeviceInterfaceDetailDataSize >= sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) {
        wcscpy(DeviceInterfaceDetailData->DevicePath, g_VirtualXUSBPath);
    }
    
    if (DeviceInfoData) {
        DeviceInfoData->cbSize = sizeof(SP_DEVINFO_DATA);
        DeviceInfoData->ClassGuid = k_GUID_NULL;
        DeviceInfoData->DevInst = 1;
        DeviceInfoData->Reserved = 0x1337;
    }
    WriteLog("[SetupAPI Direct] Provided Virtual DualShock 4 DevicePath: %ls\n", g_VirtualXUSBPath);
    return TRUE;
}

BOOL WINAPI Hooked_SetupDiGetDeviceRegistryPropertyW(HDEVINFO DeviceInfoSet, PSP_DEVINFO_DATA DeviceInfoData, DWORD Property, PDWORD PropertyRegDataType, PBYTE PropertyBuffer, DWORD PropertyBufferSize, PDWORD RequiredSize) {
    const wchar_t* pStr = NULL;
    DWORD bytesNeeded = 0;
    
    if (Property == SPDRP_HARDWAREID) {
        pStr = g_VirtualHardwareId;
        bytesNeeded = sizeof(g_VirtualHardwareId);
        if (PropertyRegDataType) *PropertyRegDataType = REG_MULTI_SZ;
    } else {
        pStr = g_VirtualDeviceDesc;
        bytesNeeded = sizeof(g_VirtualDeviceDesc);
        if (PropertyRegDataType) *PropertyRegDataType = REG_SZ;
    }
    
    if (RequiredSize) *RequiredSize = bytesNeeded;
    if (PropertyBuffer && PropertyBufferSize >= bytesNeeded) {
        memcpy(PropertyBuffer, pStr, bytesNeeded);
    }
    WriteLog("[SetupAPI Direct] Provided Property %d: %ls\n", Property, pStr);
    return TRUE;
}

BOOL WINAPI Hooked_SetupDiGetDeviceInstanceIdW(HDEVINFO DeviceInfoSet, PSP_DEVINFO_DATA DeviceInfoData, PWSTR DeviceInstanceId, DWORD DeviceInstanceIdSize, PDWORD RequiredSize) {
    DWORD needed = (DWORD)(wcslen(g_VirtualInstanceId) + 1);
    if (RequiredSize) *RequiredSize = needed;
    if (DeviceInstanceId && DeviceInstanceIdSize >= needed) {
        wcscpy(DeviceInstanceId, g_VirtualInstanceId);
    }
    WriteLog("[SetupAPI Direct] Provided DeviceInstanceId: %ls\n", g_VirtualInstanceId);
    return TRUE;
}

static void DirectPatchSetupAPI(HMODULE hMainExe) {
    if (!hMainExe) return;
    uintptr_t base = (uintptr_t)hMainExe;
    
    DWORD oldProtect;
    if (VirtualProtect((void*)(base + 0x174b960), 0x50, PAGE_READWRITE, &oldProtect)) {
        *(void**)(base + 0x174b960) = (void*)Hooked_SetupDiEnumDeviceInfo;
        *(void**)(base + 0x174b970) = (void*)Hooked_SetupDiEnumDeviceInterfaces;
        *(void**)(base + 0x174b980) = (void*)Hooked_SetupDiGetDeviceRegistryPropertyW;
        *(void**)(base + 0x174b988) = (void*)Hooked_SetupDiGetDeviceInterfaceDetailW;
        *(void**)(base + 0x174b998) = (void*)Hooked_SetupDiGetDeviceInstanceIdW;
        VirtualProtect((void*)(base + 0x174b960), 0x50, oldProtect, &oldProtect);
        WriteLog("[SetupAPI Direct] Successfully patched Horizon SetupAPI IAT at base %p + 0x174b960\n", hMainExe);
    }
}

// ============================================================================
// RawInput Spoofing (DualShock 4 VID 0x054C, PID 0x09CC)
// ============================================================================

typedef UINT (WINAPI *GetRawInputDeviceInfoW_t)(HANDLE, UINT, LPVOID, PUINT);
typedef UINT (WINAPI *GetRawInputDeviceInfoA_t)(HANDLE, UINT, LPVOID, PUINT);

static GetRawInputDeviceInfoW_t pRealGetRawInputDeviceInfoW = NULL;
static GetRawInputDeviceInfoA_t pRealGetRawInputDeviceInfoA = NULL;

static void EnsureUser32Pointers() {
    if (!pRealGetRawInputDeviceInfoW) {
        HMODULE hUser32 = GetModuleHandleA("user32.dll");
        if (!hUser32) hUser32 = LoadLibraryA("user32.dll");
        if (hUser32) {
            pRealGetRawInputDeviceInfoW = (GetRawInputDeviceInfoW_t)GetProcAddress(hUser32, "GetRawInputDeviceInfoW");
            pRealGetRawInputDeviceInfoA = (GetRawInputDeviceInfoA_t)GetProcAddress(hUser32, "GetRawInputDeviceInfoA");
        }
    }
}

UINT WINAPI Hooked_GetRawInputDeviceInfoW(HANDLE hDevice, UINT uiCommand, LPVOID pData, PUINT pcbSize) {
    EnsureUser32Pointers();
    if (!pRealGetRawInputDeviceInfoW) return (UINT)-1;

    UINT res = pRealGetRawInputDeviceInfoW(hDevice, uiCommand, pData, pcbSize);
    if (res != (UINT)-1 && pData) {
        if (uiCommand == RIDI_DEVICEINFO) {
            PRID_DEVICE_INFO pInfo = (PRID_DEVICE_INFO)pData;
            if (pInfo->dwType == RIM_TYPEHID) {
                pInfo->hid.dwVendorId = 0x054C;  // Sony
                pInfo->hid.dwProductId = 0x09CC; // DualShock 4 Wireless Controller
            }
        }
    }
    return res;
}

UINT WINAPI Hooked_GetRawInputDeviceInfoA(HANDLE hDevice, UINT uiCommand, LPVOID pData, PUINT pcbSize) {
    EnsureUser32Pointers();
    if (!pRealGetRawInputDeviceInfoA) return (UINT)-1;

    UINT res = pRealGetRawInputDeviceInfoA(hDevice, uiCommand, pData, pcbSize);
    if (res != (UINT)-1 && pData) {
        if (uiCommand == RIDI_DEVICEINFO) {
            PRID_DEVICE_INFO pInfo = (PRID_DEVICE_INFO)pData;
            if (pInfo->dwType == RIM_TYPEHID) {
                pInfo->hid.dwVendorId = 0x054C;  // Sony
                pInfo->hid.dwProductId = 0x09CC; // DualShock 4 Wireless Controller
            }
        }
    }
    return res;
}

static void PatchUser32IAT(HMODULE hMainExe) {
    if (!hMainExe) return;
    uintptr_t base = (uintptr_t)hMainExe;
    
    DWORD oldProtect;
    if (VirtualProtect((void*)(base + 0x174bb90), 0x10, PAGE_READWRITE, &oldProtect)) {
        *(void**)(base + 0x174bb90) = (void*)Hooked_GetRawInputDeviceInfoW;
        VirtualProtect((void*)(base + 0x174bb90), 0x10, oldProtect, &oldProtect);
        WriteLog("[User32 Direct] Successfully patched GetRawInputDeviceInfoW at base + 0x174bb90\n");
    }
}

bool g_Initialized = false;
CRITICAL_SECTION init_lock;

void SafeInitialize() {
    EnterCriticalSection(&init_lock);
    if (g_Initialized) {
        LeaveCriticalSection(&init_lock);
        return;
    }
    InitUDP();
    EnsureUser32Pointers();
    DirectPatchSetupAPI(GetModuleHandle(NULL));
    PatchUser32IAT(GetModuleHandle(NULL));
    WriteLog("[SteamAPI DLL] DualShock 4 Native Glyph & Gamepad Synthesizer initialized.\n");
    g_Initialized = true;
    LeaveCriticalSection(&init_lock);
}

void EnsureOrigInitialized() {
    if (!g_Initialized) {
        SafeInitialize();
    }
}

// ============================================================================
// ISteamInput / ISteamController vtable hooks
// ============================================================================

void __cdecl Hooked_TriggerVibration(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
}

void __cdecl Hooked_TriggerVibrationExtended(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed, unsigned short usLeftTriggerSpeed, unsigned short usRightTriggerSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
}

void __cdecl Hooked_ControllerTriggerVibration(void* self, uint64_t controllerHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
}

int __cdecl Hooked_GetInputTypeForHandle(void* self, uint64_t inputHandle) {
    return 5; // k_ESteamInputType_PS4Controller (DualShock 4)
}

int __cdecl Hooked_GetConnectedControllers(void* self, uint64_t* handlesOut) {
    if (handlesOut) {
        handlesOut[0] = 1;
    }
    return 1;
}

uint64_t __cdecl Hooked_GetControllerForGamepadIndex(void* self, int nIndex) {
    if (nIndex == 0) return 1;
    return 0;
}

int __cdecl Hooked_GetGamepadIndexForController(void* self, uint64_t inputHandle) {
    if (inputHandle == 1) return 0;
    return -1;
}

// ============================================================================
// SteamInternal_FindOrCreateUserInterface detour
// ============================================================================

void* __cdecl DetourSteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* pszInterfaceVersion) {
    EnsureOrigInitialized();

    void* pInterface = NULL;
    if (orig_SteamInternal_FindOrCreateUserInterface) {
        pInterface = orig_SteamInternal_FindOrCreateUserInterface(hSteamUser, pszInterfaceVersion);
    }
    
    if (pszInterfaceVersion) {
        WriteLog("[SteamAPI DLL] SteamInternal_FindOrCreateUserInterface requested: %s -> %p\n", pszInterfaceVersion, pInterface);
    }
    
    if (pInterface && pszInterfaceVersion) {
        if (strstr(pszInterfaceVersion, "SteamInput") != NULL) {
            void** vtable = *(void***)pInterface;
            if (vtable) {
                DWORD oldProtect;
                VirtualProtect(&vtable[0], 50 * sizeof(void*), PAGE_READWRITE, &oldProtect);
                
                vtable[6] = (void*)Hooked_GetConnectedControllers;
                vtable[30] = (void*)Hooked_TriggerVibration;
                vtable[37] = (void*)Hooked_GetInputTypeForHandle;
                
                VirtualProtect(&vtable[0], 50 * sizeof(void*), oldProtect, &oldProtect);
                WriteLog("[SteamAPI DLL] Patched ISteamInput vtable (vtable[37]=GetInputTypeForHandle->PS4) for %s\n", pszInterfaceVersion);
            }
        }
        else if (strstr(pszInterfaceVersion, "SteamController") != NULL) {
            void** vtable = *(void***)pInterface;
            if (vtable) {
                DWORD oldProtect;
                VirtualProtect(&vtable[0], 40 * sizeof(void*), PAGE_READWRITE, &oldProtect);
                vtable[3] = (void*)Hooked_GetConnectedControllers;
                vtable[23] = (void*)Hooked_ControllerTriggerVibration;
                vtable[26] = (void*)Hooked_GetInputTypeForHandle;
                VirtualProtect(&vtable[0], 40 * sizeof(void*), oldProtect, &oldProtect);
                WriteLog("[SteamAPI DLL] Patched ISteamController vtable (vtable[26]=GetInputTypeForHandle->PS4) for %s\n", pszInterfaceVersion);
            }
        }
    }
    return pInterface;
}

// ============================================================================
// DLL Entry Points
// ============================================================================

void LoadOriginalSteamApiDll() {
    if (!hOrigSteamApiDll) {
        wchar_t path[MAX_PATH];
        if (hMySelf && GetModuleFileNameW(hMySelf, path, MAX_PATH)) {
            wchar_t* lastSlash = wcsrchr(path, L'\\');
            if (!lastSlash) {
                lastSlash = wcsrchr(path, L'/');
            }
            if (lastSlash) {
                wcscpy(lastSlash + 1, L"steam_api64_original.dll");
                hOrigSteamApiDll = LoadLibraryW(path);
                if (hOrigSteamApiDll) {
                    WriteLog("[SteamAPI DLL] Loaded steam_api64_original.dll via Unicode path.\n");
                }
            }
        }
        
        if (!hOrigSteamApiDll) {
            hOrigSteamApiDll = LoadLibraryW(L"steam_api64_original.dll");
        }
        
        orig_SteamInternal_FindOrCreateUserInterface = (SteamInternal_FindOrCreateUserInterface_t)GetProcAddress(hOrigSteamApiDll, "SteamInternal_FindOrCreateUserInterface");
    }
}

extern "C" __declspec(dllexport) void* __cdecl SteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* pszInterfaceVersion) {
    LoadOriginalSteamApiDll();
    return DetourSteamInternal_FindOrCreateUserInterface(hSteamUser, pszInterfaceVersion);
}

extern "C" BOOL WINAPI DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    switch (ul_reason_for_call) {
        case DLL_PROCESS_ATTACH:
            hMySelf = hModule;
            InitializeCriticalSection(&init_lock);
            EnsureOrigInitialized();
            break;
        case DLL_PROCESS_DETACH:
            DeleteCriticalSection(&init_lock);
            if (udp_socket != INVALID_SOCKET) {
                closesocket(udp_socket);
            }
            WSACleanup();
            break;
    }
    return TRUE;
}
