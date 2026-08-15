#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <xinput.h>
#include <stdio.h>
#include <math.h>
#include <stdint.h>

#pragma comment(lib, "ws2_32.lib")

// Globals
static HMODULE hSelfModule = NULL;
static HMODULE hOrigXInputDll = NULL;
static SOCKET udp_rumble_socket = INVALID_SOCKET;
static sockaddr_in rumble_server_addr;
static bool g_udp_initialized = false;
static CRITICAL_SECTION init_lock;

// Gyro Receiver Socket & State
static SOCKET udp_gyro_socket = INVALID_SOCKET;
static HANDLE hGyroThread = NULL;
static volatile bool g_gyro_running = false;

struct GyroPacket {
    uint8_t magic;         // 0x02 for gyro
    uint8_t mode;          // 0 = Off, 1 = Stick Emulation, 2 = 1:1 Mouse Delta (Aim L2), 3 = 1:1 Mouse Delta (Always)
    int16_t pitch_rate;    // degrees/sec * 100
    int16_t yaw_rate;      // degrees/sec * 100
    int16_t roll_rate;     // degrees/sec * 100
    int16_t sensitivity;   // 10 - 300 (default 100)
};

static volatile float g_gyro_pitch_delta = 0.0f;
static volatile float g_gyro_yaw_delta = 0.0f;
static volatile uint8_t g_gyro_mode = 0;
static volatile float g_gyro_sensitivity = 1.0f;
static volatile bool g_aim_trigger_active = false;

// Function pointers for original XInput functions
typedef DWORD (WINAPI *XInputGetState_t)(DWORD, XINPUT_STATE*);
typedef DWORD (WINAPI *XInputGetStateEx_t)(DWORD, XINPUT_STATE*);
typedef DWORD (WINAPI *XInputSetState_t)(DWORD, XINPUT_VIBRATION*);
typedef DWORD (WINAPI *XInputGetCapabilities_t)(DWORD, DWORD, XINPUT_CAPABILITIES*);
typedef void  (WINAPI *XInputEnable_t)(BOOL);
typedef DWORD (WINAPI *XInputGetDSoundAudioDeviceGuids_t)(DWORD, GUID*, GUID*);
typedef DWORD (WINAPI *XInputGetBatteryInformation_t)(DWORD, BYTE, XINPUT_BATTERY_INFORMATION*);
typedef DWORD (WINAPI *XInputGetKeystroke_t)(DWORD, DWORD, PXINPUT_KEYSTROKE);
typedef DWORD (WINAPI *XInputGetAudioDeviceIds_t)(DWORD, LPWSTR, UINT*, LPWSTR, UINT*);

static XInputGetState_t orig_XInputGetState = NULL;
static XInputGetStateEx_t orig_XInputGetStateEx = NULL;
static XInputSetState_t orig_XInputSetState = NULL;
static XInputGetCapabilities_t orig_XInputGetCapabilities = NULL;
static XInputEnable_t orig_XInputEnable = NULL;
static XInputGetDSoundAudioDeviceGuids_t orig_XInputGetDSoundAudioDeviceGuids = NULL;
static XInputGetBatteryInformation_t orig_XInputGetBatteryInformation = NULL;
static XInputGetKeystroke_t orig_XInputGetKeystroke = NULL;
static XInputGetAudioDeviceIds_t orig_XInputGetAudioDeviceIds = NULL;

static void InjectMouseDelta(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    INPUT input = {0};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_MOVE;
    input.mi.dx = dx;
    input.mi.dy = dy;
    SendInput(1, &input, sizeof(INPUT));
}

static DWORD WINAPI GyroReceiverThread(LPVOID lpParam) {
    sockaddr_in bind_addr;
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(24681);
    bind_addr.sin_addr.s_addr = INADDR_ANY;

    udp_gyro_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (udp_gyro_socket == INVALID_SOCKET) return 0;

    DWORD timeout = 20;
    setsockopt(udp_gyro_socket, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout, sizeof(timeout));

    if (bind(udp_gyro_socket, (sockaddr*)&bind_addr, sizeof(bind_addr)) != 0) {
        closesocket(udp_gyro_socket);
        udp_gyro_socket = INVALID_SOCKET;
        return 0;
    }

    g_gyro_running = true;
    uint8_t buffer[64];

    while (g_gyro_running) {
        int bytes = recv(udp_gyro_socket, (char*)buffer, sizeof(buffer), 0);
        if (bytes >= (int)sizeof(GyroPacket)) {
            GyroPacket* p = (GyroPacket*)buffer;
            if (p->magic == 0x02) {
                g_gyro_mode = p->mode;
                g_gyro_sensitivity = (float)p->sensitivity / 100.0f;
                float pitch = ((float)p->pitch_rate / 100.0f) * g_gyro_sensitivity;
                float yaw = ((float)p->yaw_rate / 100.0f) * g_gyro_sensitivity;

                g_gyro_pitch_delta = pitch;
                g_gyro_yaw_delta = yaw;

                // Mode 2: 1:1 True Mouse-Delta Aiming when aiming (L2)
                // Mode 3: 1:1 True Mouse-Delta Aiming Always
                if ((g_gyro_mode == 2 && g_aim_trigger_active) || g_gyro_mode == 3) {
                    // Yaw controls horizontal (X), Pitch controls vertical (Y)
                    // Invert pitch for natural camera tilt
                    int m_dx = (int)(-yaw * 2.8f);
                    int m_dy = (int)(-pitch * 2.8f);
                    InjectMouseDelta(m_dx, m_dy);
                }
            }
        }
    }

    if (udp_gyro_socket != INVALID_SOCKET) {
        closesocket(udp_gyro_socket);
        udp_gyro_socket = INVALID_SOCKET;
    }
    return 0;
}

static void InitUDP() {
    if (g_udp_initialized) return;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
        udp_rumble_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        rumble_server_addr.sin_family = AF_INET;
        rumble_server_addr.sin_port = htons(24680);
        rumble_server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");

        hGyroThread = CreateThread(NULL, 0, GyroReceiverThread, NULL, 0, NULL);
        g_udp_initialized = true;
    }
}

static void SendRumbleUDP(BYTE left_motor, BYTE right_motor) {
    if (!g_udp_initialized) {
        InitUDP();
    }
    if (udp_rumble_socket != INVALID_SOCKET) {
        unsigned char packet[3];
        packet[0] = 0x01;
        packet[1] = left_motor;
        packet[2] = right_motor;
        sendto(udp_rumble_socket, (const char*)packet, 3, 0, (sockaddr*)&rumble_server_addr, sizeof(rumble_server_addr));
    }
}

static void LoadOriginalDll() {
    if (hOrigXInputDll && hOrigXInputDll != hSelfModule) return;
    
    char sysDir[MAX_PATH];
    GetSystemDirectoryA(sysDir, MAX_PATH);
    
    char dllPath[MAX_PATH];
    snprintf(dllPath, sizeof(dllPath), "%s\\xinput1_3.dll", sysDir);
    HMODULE hMod = LoadLibraryExA(dllPath, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!hMod || hMod == hSelfModule) {
        snprintf(dllPath, sizeof(dllPath), "%s\\xinput9_1_0.dll", sysDir);
        hMod = LoadLibraryExA(dllPath, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    }
    
    if (hMod && hMod != hSelfModule) {
        hOrigXInputDll = hMod;
        orig_XInputGetState = (XInputGetState_t)GetProcAddress(hOrigXInputDll, "XInputGetState");
        orig_XInputGetStateEx = (XInputGetStateEx_t)GetProcAddress(hOrigXInputDll, "XInputGetStateEx");
        orig_XInputSetState = (XInputSetState_t)GetProcAddress(hOrigXInputDll, "XInputSetState");
        orig_XInputGetCapabilities = (XInputGetCapabilities_t)GetProcAddress(hOrigXInputDll, "XInputGetCapabilities");
        orig_XInputEnable = (XInputEnable_t)GetProcAddress(hOrigXInputDll, "XInputEnable");
        orig_XInputGetDSoundAudioDeviceGuids = (XInputGetDSoundAudioDeviceGuids_t)GetProcAddress(hOrigXInputDll, "XInputGetDSoundAudioDeviceGuids");
        orig_XInputGetBatteryInformation = (XInputGetBatteryInformation_t)GetProcAddress(hOrigXInputDll, "XInputGetBatteryInformation");
        orig_XInputGetKeystroke = (XInputGetKeystroke_t)GetProcAddress(hOrigXInputDll, "XInputGetKeystroke");
        orig_XInputGetAudioDeviceIds = (XInputGetAudioDeviceIds_t)GetProcAddress(hOrigXInputDll, "XInputGetAudioDeviceIds");
        
        // Ordinals fallback
        if (!orig_XInputGetState) orig_XInputGetState = (XInputGetState_t)GetProcAddress(hOrigXInputDll, (LPCSTR)100);
        if (!orig_XInputSetState) orig_XInputSetState = (XInputSetState_t)GetProcAddress(hOrigXInputDll, (LPCSTR)101);
        if (!orig_XInputGetCapabilities) orig_XInputGetCapabilities = (XInputGetCapabilities_t)GetProcAddress(hOrigXInputDll, (LPCSTR)102);
        if (!orig_XInputEnable) orig_XInputEnable = (XInputEnable_t)GetProcAddress(hOrigXInputDll, (LPCSTR)103);
    }
}

// Anti-drift, axis stabilization, and Gyro blending filters
static void SanitizeAndBlendGamepadState(XINPUT_GAMEPAD* pGamepad) {
    if (!pGamepad) return;

    // 1. Left Thumbstick deadzone filtering
    float lx = (float)pGamepad->sThumbLX;
    float ly = (float)pGamepad->sThumbLY;
    float lMag = sqrtf(lx * lx + ly * ly);
    if (lMag < (float)XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE) {
        pGamepad->sThumbLX = 0;
        pGamepad->sThumbLY = 0;
    }

    // 2. Right Thumbstick deadzone & anti-spin / anti-sky look filtering
    float rx = (float)pGamepad->sThumbRX;
    float ry = (float)pGamepad->sThumbRY;
    float rMag = sqrtf(rx * rx + ry * ry);
    if (rMag < (float)XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE) {
        rx = 0.0f;
        ry = 0.0f;
        pGamepad->sThumbRX = 0;
        pGamepad->sThumbRY = 0;
    }

    // 3. Trigger thresholds
    if (pGamepad->bLeftTrigger < XINPUT_GAMEPAD_TRIGGER_THRESHOLD) {
        pGamepad->bLeftTrigger = 0;
        g_aim_trigger_active = false;
    } else {
        g_aim_trigger_active = true;
    }
    
    if (pGamepad->bRightTrigger < XINPUT_GAMEPAD_TRIGGER_THRESHOLD) {
        pGamepad->bRightTrigger = 0;
    }

    // 4. Gyro Stick Emulation (Mode 1: Stick Blending)
    if (g_gyro_mode == 1) {
        float gyro_x_input = g_gyro_yaw_delta * 120.0f;
        float gyro_y_input = g_gyro_pitch_delta * 120.0f;

        float final_rx = rx + gyro_x_input;
        float final_ry = ry + gyro_y_input;

        if (final_rx > 32767.0f) final_rx = 32767.0f;
        if (final_rx < -32768.0f) final_rx = -32768.0f;
        if (final_ry > 32767.0f) final_ry = 32767.0f;
        if (final_ry < -32768.0f) final_ry = -32768.0f;

        pGamepad->sThumbRX = (SHORT)final_rx;
        pGamepad->sThumbRY = (SHORT)final_ry;
    }
}

extern "C" {

__declspec(dllexport) DWORD WINAPI XInputGetState(DWORD dwUserIndex, XINPUT_STATE* pState) {
    LoadOriginalDll();
    if (orig_XInputGetState && orig_XInputGetState != (XInputGetState_t)XInputGetState) {
        DWORD result = orig_XInputGetState(dwUserIndex, pState);
        if (result == ERROR_SUCCESS && pState) {
            SanitizeAndBlendGamepadState(&pState->Gamepad);
        }
        return result;
    }
    return ERROR_DEVICE_NOT_CONNECTED;
}

__declspec(dllexport) DWORD WINAPI XInputGetStateEx(DWORD dwUserIndex, XINPUT_STATE* pState) {
    LoadOriginalDll();
    if (orig_XInputGetStateEx && orig_XInputGetStateEx != (XInputGetStateEx_t)XInputGetStateEx) {
        DWORD result = orig_XInputGetStateEx(dwUserIndex, pState);
        if (result == ERROR_SUCCESS && pState) {
            SanitizeAndBlendGamepadState(&pState->Gamepad);
        }
        return result;
    }
    return XInputGetState(dwUserIndex, pState);
}

__declspec(dllexport) DWORD WINAPI XInputSetState(DWORD dwUserIndex, XINPUT_VIBRATION* pVibration) {
    if (pVibration) {
        BYTE left = (BYTE)(pVibration->wLeftMotorSpeed / 256);
        BYTE right = (BYTE)(pVibration->wRightMotorSpeed / 256);
        SendRumbleUDP(left, right);
    }
    LoadOriginalDll();
    if (orig_XInputSetState && orig_XInputSetState != (XInputSetState_t)XInputSetState) {
        return orig_XInputSetState(dwUserIndex, pVibration);
    }
    return ERROR_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI XInputGetCapabilities(DWORD dwUserIndex, DWORD dwFlags, XINPUT_CAPABILITIES* pCapabilities) {
    LoadOriginalDll();
    if (orig_XInputGetCapabilities && orig_XInputGetCapabilities != (XInputGetCapabilities_t)XInputGetCapabilities) {
        return orig_XInputGetCapabilities(dwUserIndex, dwFlags, pCapabilities);
    }
    return ERROR_DEVICE_NOT_CONNECTED;
}

__declspec(dllexport) void WINAPI XInputEnable(BOOL enable) {
    LoadOriginalDll();
    if (orig_XInputEnable && orig_XInputEnable != (XInputEnable_t)XInputEnable) {
        orig_XInputEnable(enable);
    }
}

__declspec(dllexport) DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD dwUserIndex, GUID* pDSoundRenderGuid, GUID* pDSoundCaptureGuid) {
    LoadOriginalDll();
    if (orig_XInputGetDSoundAudioDeviceGuids) {
        return orig_XInputGetDSoundAudioDeviceGuids(dwUserIndex, pDSoundRenderGuid, pDSoundCaptureGuid);
    }
    return ERROR_DEVICE_NOT_CONNECTED;
}

__declspec(dllexport) DWORD WINAPI XInputGetBatteryInformation(DWORD dwUserIndex, BYTE devType, XINPUT_BATTERY_INFORMATION* pBatteryInformation) {
    LoadOriginalDll();
    if (orig_XInputGetBatteryInformation) {
        return orig_XInputGetBatteryInformation(dwUserIndex, devType, pBatteryInformation);
    }
    if (pBatteryInformation) {
        pBatteryInformation->BatteryType = BATTERY_TYPE_ALKALINE;
        pBatteryInformation->BatteryLevel = BATTERY_LEVEL_FULL;
        return ERROR_SUCCESS;
    }
    return ERROR_DEVICE_NOT_CONNECTED;
}

__declspec(dllexport) DWORD WINAPI XInputGetKeystroke(DWORD dwUserIndex, DWORD dwReserved, PXINPUT_KEYSTROKE pKeystroke) {
    LoadOriginalDll();
    if (orig_XInputGetKeystroke) {
        return orig_XInputGetKeystroke(dwUserIndex, dwReserved, pKeystroke);
    }
    return ERROR_EMPTY;
}

__declspec(dllexport) DWORD WINAPI XInputGetAudioDeviceIds(DWORD dwUserIndex, LPWSTR pRenderDeviceId, UINT* pRenderCount, LPWSTR pCaptureDeviceId, UINT* pCaptureCount) {
    LoadOriginalDll();
    if (orig_XInputGetAudioDeviceIds) {
        return orig_XInputGetAudioDeviceIds(dwUserIndex, pRenderDeviceId, pRenderCount, pCaptureDeviceId, pCaptureCount);
    }
    return ERROR_DEVICE_NOT_CONNECTED;
}

__declspec(dllexport) BOOL WINAPI DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    switch (ul_reason_for_call) {
        case DLL_PROCESS_ATTACH:
            hSelfModule = hModule;
            DisableThreadLibraryCalls(hModule);
            InitializeCriticalSection(&init_lock);
            InitUDP();
            break;
        case DLL_PROCESS_DETACH:
            DeleteCriticalSection(&init_lock);
            g_gyro_running = false;
            if (udp_gyro_socket != INVALID_SOCKET) {
                closesocket(udp_gyro_socket);
                udp_gyro_socket = INVALID_SOCKET;
            }
            if (udp_rumble_socket != INVALID_SOCKET) {
                closesocket(udp_rumble_socket);
                udp_rumble_socket = INVALID_SOCKET;
            }
            WSACleanup();
            break;
    }
    return TRUE;
}

}
