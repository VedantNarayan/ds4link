#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <string>
#include <cstdint>

#pragma comment(lib, "ws2_32.lib")

// Globals
HMODULE hOrigSteamApiDll = NULL;
HMODULE hMySelf = NULL;

typedef void* (__cdecl *SteamInternal_FindOrCreateUserInterface_t)(int, const char*);
SteamInternal_FindOrCreateUserInterface_t orig_SteamInternal_FindOrCreateUserInterface = NULL;

// ISteamInput / ISteamController vtable hook types
typedef void (__cdecl *SteamInputTriggerVibration_t)(void*, uint64_t, unsigned short, unsigned short);
typedef void (__cdecl *SteamInputTriggerVibrationExtended_t)(void*, uint64_t, unsigned short, unsigned short, unsigned short, unsigned short);

SteamInputTriggerVibration_t real_TriggerVibration = NULL;
SteamInputTriggerVibrationExtended_t real_TriggerVibrationExtended = NULL;
SteamInputTriggerVibration_t real_ControllerTriggerVibration = NULL;

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

// ============================================================================
// RawInput Spoofing (Converts Sony VID 0x054C -> Microsoft VID 0x045E)
// This permanently forces Sony Decima / PC ports to use standard XInput
// instead of locking into broken Bluetooth LibScePad in Wine.
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
                if (pInfo->hid.dwVendorId == 0x054C || pInfo->hid.dwVendorId == 1356) {
                    WriteLog("[RawInput Hook] Spoofed Sony RawInput VID 0x054C -> 0x045E (Xbox 360)\n");
                    pInfo->hid.dwVendorId = 0x045E;  // Microsoft
                    pInfo->hid.dwProductId = 0x028E; // Xbox 360 Controller
                }
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
                if (pInfo->hid.dwVendorId == 0x054C || pInfo->hid.dwVendorId == 1356) {
                    WriteLog("[RawInput Hook] Spoofed Sony RawInput VID 0x054C -> 0x045E (Xbox 360)\n");
                    pInfo->hid.dwVendorId = 0x045E;  // Microsoft
                    pInfo->hid.dwProductId = 0x028E; // Xbox 360 Controller
                }
            }
        }
    }
    return res;
}

static void PatchModuleIAT(HMODULE hMod) {
    if (!hMod) return;
    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)hMod;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS)((BYTE*)hMod + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir.VirtualAddress == 0 || dir.Size == 0) return;
    
    PIMAGE_IMPORT_DESCRIPTOR desc = (PIMAGE_IMPORT_DESCRIPTOR)((BYTE*)hMod + dir.VirtualAddress);
    for (; desc->Name != 0; desc++) {
        const char* name = (const char*)((BYTE*)hMod + desc->Name);
        if (_stricmp(name, "user32.dll") == 0) {
            PIMAGE_THUNK_DATA thunk = (PIMAGE_THUNK_DATA)((BYTE*)hMod + desc->FirstThunk);
            PIMAGE_THUNK_DATA origThunk = (PIMAGE_THUNK_DATA)((BYTE*)hMod + (desc->OriginalFirstThunk ? desc->OriginalFirstThunk : desc->FirstThunk));
            for (; thunk->u1.Function != 0; thunk++, origThunk++) {
                if (!IMAGE_SNAP_BY_ORDINAL(origThunk->u1.Ordinal)) {
                    PIMAGE_IMPORT_BY_NAME importByName = (PIMAGE_IMPORT_BY_NAME)((BYTE*)hMod + origThunk->u1.AddressOfData);
                    if (strcmp((const char*)importByName->Name, "GetRawInputDeviceInfoW") == 0) {
                        DWORD oldProtect;
                        VirtualProtect(&thunk->u1.Function, sizeof(void*), PAGE_READWRITE, &oldProtect);
                        thunk->u1.Function = (ULONG_PTR)Hooked_GetRawInputDeviceInfoW;
                        VirtualProtect(&thunk->u1.Function, sizeof(void*), oldProtect, &oldProtect);
                        WriteLog("[IAT Patch] Hooked GetRawInputDeviceInfoW in module %p\n", hMod);
                    }
                    else if (strcmp((const char*)importByName->Name, "GetRawInputDeviceInfoA") == 0) {
                        DWORD oldProtect;
                        VirtualProtect(&thunk->u1.Function, sizeof(void*), PAGE_READWRITE, &oldProtect);
                        thunk->u1.Function = (ULONG_PTR)Hooked_GetRawInputDeviceInfoA;
                        VirtualProtect(&thunk->u1.Function, sizeof(void*), oldProtect, &oldProtect);
                        WriteLog("[IAT Patch] Hooked GetRawInputDeviceInfoA in module %p\n", hMod);
                    }
                }
            }
        }
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
    PatchModuleIAT(GetModuleHandle(NULL));
    HMODULE hFullGame = GetModuleHandleA("fullgame.dll");
    if (hFullGame) {
        PatchModuleIAT(hFullGame);
    }
    WriteLog("[SteamAPI DLL] Hook & Safe RawInput Spoofing initialized successfully.\n");
    g_Initialized = true;
    LeaveCriticalSection(&init_lock);
}

void EnsureOrigInitialized() {
    if (!g_Initialized) {
        SafeInitialize();
    }
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
// ISteamInput / ISteamController vtable hooks
// ============================================================================

void __cdecl Hooked_TriggerVibration(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
    if (real_TriggerVibration) {
        real_TriggerVibration(self, inputHandle, 0, 0);
    }
}

void __cdecl Hooked_TriggerVibrationExtended(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed, unsigned short usLeftTriggerSpeed, unsigned short usRightTriggerSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
    if (real_TriggerVibrationExtended) {
        real_TriggerVibrationExtended(self, inputHandle, 0, 0, 0, 0);
    }
}

void __cdecl Hooked_ControllerTriggerVibration(void* self, uint64_t controllerHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
    if (real_ControllerTriggerVibration) {
        real_ControllerTriggerVibration(self, controllerHandle, 0, 0);
    }
}

// ============================================================================
// SteamInternal_FindOrCreateUserInterface detour
// ============================================================================

void* __cdecl DetourSteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* pszInterfaceVersion) {
    EnsureOrigInitialized();
    
    // Check if fullgame.dll loaded dynamically and patch it
    HMODULE hFullGame = GetModuleHandleA("fullgame.dll");
    if (hFullGame) {
        PatchModuleIAT(hFullGame);
    }

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
            if (vtable && vtable[29] != (void*)Hooked_TriggerVibration) {
                real_TriggerVibration = (SteamInputTriggerVibration_t)vtable[29];
                real_TriggerVibrationExtended = (SteamInputTriggerVibrationExtended_t)vtable[30];
                
                DWORD oldProtect;
                VirtualProtect(&vtable[29], 2 * sizeof(void*), PAGE_READWRITE, &oldProtect);
                vtable[29] = (void*)Hooked_TriggerVibration;
                vtable[30] = (void*)Hooked_TriggerVibrationExtended;
                VirtualProtect(&vtable[29], 2 * sizeof(void*), oldProtect, &oldProtect);
                
                WriteLog("[SteamAPI DLL] Patched ISteamInput vtable for %s\n", pszInterfaceVersion);
            }
        }
        else if (strstr(pszInterfaceVersion, "SteamController") != NULL) {
            void** vtable = *(void***)pInterface;
            if (vtable && vtable[23] != (void*)Hooked_ControllerTriggerVibration) {
                real_ControllerTriggerVibration = (SteamInputTriggerVibration_t)vtable[23];
                
                DWORD oldProtect;
                VirtualProtect(&vtable[23], sizeof(void*), PAGE_READWRITE, &oldProtect);
                vtable[23] = (void*)Hooked_ControllerTriggerVibration;
                VirtualProtect(&vtable[23], sizeof(void*), oldProtect, &oldProtect);
                
                WriteLog("[SteamAPI DLL] Patched ISteamController vtable for %s\n", pszInterfaceVersion);
            }
        }
    }
    return pInterface;
}

// ============================================================================
// DLL Entry Points
// ============================================================================

void LoadOriginalSteamApiDll() {
    static bool log_cleared = false;
    if (!log_cleared) {
        log_cleared = true;
        DeleteFileA("ds4link_proxy.log");
    }
    
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
