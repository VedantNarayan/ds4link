#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <dinput.h>
#include <stdio.h>

#pragma comment(lib, "ws2_32.lib")

static HMODULE hOrigDInputDll = NULL;
static SOCKET udp_socket = INVALID_SOCKET;
static sockaddr_in server_addr;
static bool g_udp_initialized = false;

static void InitUDP() {
    if (g_udp_initialized) return;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
        udp_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        server_addr.sin_family = AF_INET;
        server_addr.sin_port = htons(24680);
        server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
        g_udp_initialized = true;
    }
}

static void SendRumbleUDP(BYTE left, BYTE right) {
    if (!g_udp_initialized) InitUDP();
    if (udp_socket != INVALID_SOCKET) {
        unsigned char packet[3];
        packet[0] = 0x01;
        packet[1] = left;
        packet[2] = right;
        sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
    }
}

typedef HRESULT (WINAPI *DirectInput8Create_t)(HINSTANCE, DWORD, REFIID, LPVOID*, LPUNKNOWN);
static DirectInput8Create_t orig_DirectInput8Create = NULL;

static void LoadOriginalDll() {
    if (hOrigDInputDll) return;
    char sysDir[MAX_PATH];
    GetSystemDirectoryA(sysDir, MAX_PATH);
    char dllPath[MAX_PATH];
    snprintf(dllPath, sizeof(dllPath), "%s\\dinput8.dll", sysDir);
    hOrigDInputDll = LoadLibraryA(dllPath);
    if (hOrigDInputDll) {
        orig_DirectInput8Create = (DirectInput8Create_t)GetProcAddress(hOrigDInputDll, "DirectInput8Create");
    }
}

extern "C" {

__declspec(dllexport) HRESULT WINAPI DirectInput8Create(HINSTANCE hinst, DWORD dwVersion, REFIID riidltf, LPVOID* ppvOut, LPUNKNOWN punkOuter) {
    LoadOriginalDll();
    if (orig_DirectInput8Create) {
        return orig_DirectInput8Create(hinst, dwVersion, riidltf, ppvOut, punkOuter);
    }
    return DIERR_NOTINITIALIZED;
}

__declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(void) {
    return S_OK;
}

__declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID* ppv) {
    LoadOriginalDll();
    typedef HRESULT (WINAPI *DllGetClassObject_t)(REFCLSID, REFIID, LPVOID*);
    DllGetClassObject_t orig = (DllGetClassObject_t)GetProcAddress(hOrigDInputDll, "DllGetClassObject");
    if (orig) return orig(rclsid, riid, ppv);
    return CLASS_E_CLASSNOTAVAILABLE;
}

__declspec(dllexport) HRESULT WINAPI DllRegisterServer(void) {
    return S_OK;
}

__declspec(dllexport) HRESULT WINAPI DllUnregisterServer(void) {
    return S_OK;
}

__declspec(dllexport) BOOL WINAPI DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hModule);
        InitUDP();
    }
    return TRUE;
}

}
