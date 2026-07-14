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
    
    FILE* f = fopen("Z:\\Users\\Vedant\\Documents\\ds4_rumble_bridge\\rumble_hook.log", "a");
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

bool g_Initialized = false;
CRITICAL_SECTION init_lock;

void SafeInitialize() {
    EnterCriticalSection(&init_lock);
    if (g_Initialized) {
        LeaveCriticalSection(&init_lock);
        return;
    }
    InitUDP();
    WriteLog("[SteamAPI DLL] Hook initialized successfully.\n");
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
// These capture rumble values and send them via UDP to our CoreHaptics server.
// We do NOT call the original function — this prevents Steam from sending
// any raw HID rumble reports through Wine's kernel to the physical controller.
// ============================================================================

void __cdecl Hooked_TriggerVibration(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    SendRumbleUDP(usLeftSpeed / 256, usRightSpeed / 256);
    // Call original with ZERO motors to keep Steam's internal state consistent
    // (safe now — no IAT hooks interfering with HID writes)
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
// Patches ISteamInput/ISteamController vtables to intercept TriggerVibration.
// This is the ONLY hook — no IAT hooks for WriteFile, CreateFileW, etc.
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
            if (vtable && vtable[29] != (void*)Hooked_TriggerVibration) {
                real_TriggerVibration = (SteamInputTriggerVibration_t)vtable[29];
                real_TriggerVibrationExtended = (SteamInputTriggerVibrationExtended_t)vtable[30];
                
                DWORD oldProtect;
                VirtualProtect(&vtable[29], 2 * sizeof(void*), PAGE_READWRITE, &oldProtect);
                vtable[29] = (void*)Hooked_TriggerVibration;
                vtable[30] = (void*)Hooked_TriggerVibrationExtended;
                VirtualProtect(&vtable[29], 2 * sizeof(void*), oldProtect, &oldProtect);
                
                WriteLog("[SteamAPI DLL] Patched ISteamInput vtable for %s (TriggerVibration + Extended)\n", pszInterfaceVersion);
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
                
                WriteLog("[SteamAPI DLL] Patched ISteamController vtable for %s (TriggerVibration)\n", pszInterfaceVersion);
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
        DeleteFileA("Z:\\Users\\Vedant\\Documents\\ds4_rumble_bridge\\rumble_hook.log");
    }
    
    if (!hOrigSteamApiDll) {
        char path[MAX_PATH];
        if (hMySelf && GetModuleFileNameA(hMySelf, path, MAX_PATH)) {
            char* lastSlash = strrchr(path, '\\');
            if (!lastSlash) {
                lastSlash = strrchr(path, '/');
            }
            if (lastSlash) {
                strcpy(lastSlash + 1, "steam_api64_original.dll");
                hOrigSteamApiDll = LoadLibraryA(path);
                if (hOrigSteamApiDll) {
                    WriteLog("[SteamAPI DLL] Loaded steam_api64_original.dll from: %s\n", path);
                } else {
                    WriteLog("[SteamAPI DLL] Error: Failed to load steam_api64_original.dll from: %s (error %lu)\n", path, GetLastError());
                }
            }
        }
        
        if (!hOrigSteamApiDll) {
            hOrigSteamApiDll = LoadLibraryA("steam_api64_original.dll");
            if (hOrigSteamApiDll) {
                WriteLog("[SteamAPI DLL] Loaded steam_api64_original.dll (relative)\n");
            } else {
                WriteLog("[SteamAPI DLL] Fatal: Could not load steam_api64_original.dll (error %lu)\n", GetLastError());
                return;
            }
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
