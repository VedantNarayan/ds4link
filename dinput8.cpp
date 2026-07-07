#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>
#include <set>
#include <string>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>

#pragma comment(lib, "ws2_32.lib")

// Proxy structures and function types for dinput8.dll
typedef HRESULT (WINAPI *DirectInput8Create_t)(HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);
DirectInput8Create_t orig_DirectInput8Create = NULL;
HMODULE hOrigDll = NULL;

void WriteLog(const char* format, ...) {
    char buf[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
    
    FILE* f = fopen("Z:\\Users\\Vedant\\Documents\\ds4_rumble_bridge\\rumble_hook.log", "a");
    if (f) {
        fprintf(f, "%s", buf);
        fclose(f);
    }
    
    OutputDebugStringA(buf);
}

void LoadOriginalDll() {
    if (!hOrigDll) {
        char path[MAX_PATH];
        GetSystemDirectoryA(path, MAX_PATH);
        strcat(path, "\\dinput8.dll");
        hOrigDll = LoadLibraryA(path);
        if (hOrigDll) {
            orig_DirectInput8Create = (DirectInput8Create_t)GetProcAddress(hOrigDll, "DirectInput8Create");
            WriteLog("[DLL] Success: Loaded original dinput8.dll and resolved DirectInput8Create\n");
        } else {
            WriteLog("[DLL] Error: Failed to load original dinput8.dll\n");
        }
    }
}

// Hooking Code
std::set<HANDLE> controller_handles;
CRITICAL_SECTION handles_lock;

std::set<HMODULE> hooked_modules;
CRITICAL_SECTION hooking_lock;
bool g_Initialized = false;

SOCKET udp_socket = INVALID_SOCKET;
sockaddr_in server_addr;

void InitUDP() {
    WSADATA wsa;
    WSAStartup(MAKEWORD(2,2), &wsa);
    udp_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(24680);
    server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
}

typedef HANDLE (WINAPI *CreateFileW_t)(LPCWSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
typedef BOOL (WINAPI *WriteFile_t)(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
typedef BOOL (WINAPI *CloseHandle_t)(HANDLE);
typedef FARPROC (WINAPI *GetProcAddress_t)(HMODULE, LPCSTR);
typedef BOOLEAN (__stdcall *HidD_SetOutputReport_t)(HANDLE, PVOID, ULONG);
typedef BOOLEAN (__stdcall *HidD_SetFeature_t)(HANDLE, PVOID, ULONG);

// Steam Input vtable hooking typedefs
typedef void (__cdecl *SteamInputTriggerVibration_t)(void*, uint64_t, unsigned short, unsigned short);
typedef void (__cdecl *SteamInputTriggerVibrationExtended_t)(void*, uint64_t, unsigned short, unsigned short, unsigned short, unsigned short);
typedef void* (__cdecl *SteamInternal_FindOrCreateUserInterface_t)(int, const char*);

// XInput structures
typedef struct _XINPUT_VIBRATION {
    WORD wLeftMotorSpeed;
    WORD wRightMotorSpeed;
} XINPUT_VIBRATION, *PXINPUT_VIBRATION;
typedef DWORD (WINAPI *XInputSetState_t)(DWORD, PXINPUT_VIBRATION);

// LoadLibrary structures
typedef HMODULE (WINAPI *LoadLibraryA_t)(LPCSTR);
typedef HMODULE (WINAPI *LoadLibraryW_t)(LPCWSTR);
typedef HMODULE (WINAPI *LoadLibraryExA_t)(LPCSTR, HANDLE, DWORD);
typedef HMODULE (WINAPI *LoadLibraryExW_t)(LPCWSTR, HANDLE, DWORD);
typedef BOOL (WINAPI *DeviceIoControl_t)(HANDLE, DWORD, LPVOID, DWORD, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);

CreateFileW_t orig_CreateFileW = NULL;
WriteFile_t orig_WriteFile = NULL;
CloseHandle_t orig_CloseHandle = NULL;
GetProcAddress_t orig_GetProcAddress = NULL;
HidD_SetOutputReport_t orig_HidD_SetOutputReport = NULL;
HidD_SetFeature_t orig_HidD_SetFeature = NULL;
XInputSetState_t orig_XInputSetState = NULL;
LoadLibraryA_t orig_LoadLibraryA = NULL;
LoadLibraryW_t orig_LoadLibraryW = NULL;
LoadLibraryExA_t orig_LoadLibraryExA = NULL;
LoadLibraryExW_t orig_LoadLibraryExW = NULL;
DeviceIoControl_t orig_DeviceIoControl = NULL;

SteamInternal_FindOrCreateUserInterface_t orig_SteamInternal_FindOrCreateUserInterface = NULL;
void** original_vtable = NULL;
SteamInputTriggerVibration_t real_TriggerVibration = NULL;
SteamInputTriggerVibrationExtended_t real_TriggerVibrationExtended = NULL;
SteamInputTriggerVibration_t real_ControllerTriggerVibration = NULL;

void SafeInitialize() {
    EnterCriticalSection(&hooking_lock);
    if (g_Initialized) {
        LeaveCriticalSection(&hooking_lock);
        return;
    }
    HMODULE hKernel32 = GetModuleHandleA("kernel32.dll");
    if (hKernel32) {
        orig_CreateFileW = (CreateFileW_t)GetProcAddress(hKernel32, "CreateFileW");
        orig_WriteFile = (WriteFile_t)GetProcAddress(hKernel32, "WriteFile");
        orig_CloseHandle = (CloseHandle_t)GetProcAddress(hKernel32, "CloseHandle");
        orig_GetProcAddress = (GetProcAddress_t)GetProcAddress(hKernel32, "GetProcAddress");
        orig_LoadLibraryA = (LoadLibraryA_t)GetProcAddress(hKernel32, "LoadLibraryA");
        orig_LoadLibraryW = (LoadLibraryW_t)GetProcAddress(hKernel32, "LoadLibraryW");
        orig_LoadLibraryExA = (LoadLibraryExA_t)GetProcAddress(hKernel32, "LoadLibraryExA");
        orig_LoadLibraryExW = (LoadLibraryExW_t)GetProcAddress(hKernel32, "LoadLibraryExW");
        orig_DeviceIoControl = (DeviceIoControl_t)GetProcAddress(hKernel32, "DeviceIoControl");
    }
    InitUDP();
    DeleteFileA("Z:\\Users\\Vedant\\Documents\\ds4_rumble_bridge\\rumble_hook.log");
    WriteLog("[DLL] DLL Initialized successfully.\n");
    g_Initialized = true;
    LeaveCriticalSection(&hooking_lock);
}

void EnsureOrigInitialized() {
    if (!g_Initialized) {
        SafeInitialize();
    }
}

void PerformHooking();
void HookModule(HMODULE hMod);
BOOL WINAPI DetourCloseHandle(HANDLE hObject);
BOOL WINAPI DetourDeviceIoControl(HANDLE hDevice, DWORD dwIoControlCode, LPVOID lpInBuffer, DWORD nInBufferSize, LPVOID lpOutBuffer, DWORD nOutBufferSize, LPDWORD lpBytesReturned, LPOVERLAPPED lpOverlapped);

void* __cdecl DetourSteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* pszInterfaceVersion);
void __cdecl Hooked_TriggerVibration(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed);
void __cdecl Hooked_TriggerVibrationExtended(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed, unsigned short usLeftTriggerSpeed, unsigned short usRightTriggerSpeed);
void __cdecl Hooked_ControllerTriggerVibration(void* self, uint64_t controllerHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed);

HMODULE WINAPI DetourLoadLibraryA(LPCSTR lpLibFileName) {
    EnsureOrigInitialized();
    HMODULE hMod = orig_LoadLibraryA(lpLibFileName);
    if (hMod) {
        HookModule(hMod);
    }
    return hMod;
}

HMODULE WINAPI DetourLoadLibraryW(LPCWSTR lpLibFileName) {
    EnsureOrigInitialized();
    HMODULE hMod = orig_LoadLibraryW(lpLibFileName);
    if (hMod) {
        HookModule(hMod);
    }
    return hMod;
}

HMODULE WINAPI DetourLoadLibraryExA(LPCSTR lpLibFileName, HANDLE hFile, DWORD dwFlags) {
    EnsureOrigInitialized();
    HMODULE hMod = orig_LoadLibraryExA(lpLibFileName, hFile, dwFlags);
    if (hMod) {
        HookModule(hMod);
    }
    return hMod;
}

HMODULE WINAPI DetourLoadLibraryExW(LPCWSTR lpLibFileName, HANDLE hFile, DWORD dwFlags) {
    EnsureOrigInitialized();
    HMODULE hMod = orig_LoadLibraryExW(lpLibFileName, hFile, dwFlags);
    if (hMod) {
        HookModule(hMod);
    }
    return hMod;
}

HANDLE WINAPI DetourCreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile) {
    EnsureOrigInitialized();
    
    if (lpFileName) {
        std::wstring name(lpFileName);
        
        // Mock testing handle remains supported for verify tests
        if (name.find(L"fake_controller_handle") != std::wstring::npos) {
            WriteLog("[DLL] DetourCreateFileW called: %S\n", lpFileName);
            HANDLE hMock = (HANDLE)0x12345678;
            EnterCriticalSection(&handles_lock);
            controller_handles.insert(hMock);
            LeaveCriticalSection(&handles_lock);
            WriteLog("[DLL] DetourCreateFileW: Matched fake_controller_handle, returning mock %p\n", hMock);
            return hMock;
        }
        
        // Check if it's a Sony PlayStation controller path (VID: 0x054C)
        if (name.find(L"vid_054c") != std::wstring::npos || name.find(L"VID_054C") != std::wstring::npos) {
            WriteLog("[DLL] DetourCreateFileW called: %S\n", lpFileName);
            DWORD modifiedAccess = dwDesiredAccess;
            if (modifiedAccess & GENERIC_WRITE) {
                modifiedAccess &= ~GENERIC_WRITE;
            }
            if (modifiedAccess & FILE_WRITE_DATA) {
                modifiedAccess &= ~FILE_WRITE_DATA;
            }
            modifiedAccess |= GENERIC_READ;

            HANDLE hFile = orig_CreateFileW(lpFileName, modifiedAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
            
            if (hFile != INVALID_HANDLE_VALUE) {
                EnterCriticalSection(&handles_lock);
                controller_handles.insert(hFile);
                LeaveCriticalSection(&handles_lock);
                
                WriteLog("[DLL] DetourCreateFileW: Successfully opened real controller handle %p (modified access from 0x%08X to 0x%08X)\n", hFile, dwDesiredAccess, modifiedAccess);
                
                char buf[128];
                snprintf(buf, sizeof(buf), "OPEN_REAL_HANDLE:%p", hFile);
                sendto(udp_socket, buf, strlen(buf), 0, (sockaddr*)&server_addr, sizeof(server_addr));
            } else {
                DWORD err = GetLastError();
                WriteLog("[DLL] DetourCreateFileW: Failed to open real controller %S, err=%lu\n", lpFileName, err);
                
                char buf[256];
                snprintf(buf, sizeof(buf), "OPEN_FAILED:%S (err=%lu)", lpFileName, err);
                sendto(udp_socket, buf, strlen(buf), 0, (sockaddr*)&server_addr, sizeof(server_addr));
            }
            return hFile;
        }
    }
    return orig_CreateFileW(lpFileName, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
}

BOOL WINAPI DetourWriteFile(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite, LPDWORD lpNumberOfBytesWritten, LPOVERLAPPED lpOverlapped) {
    EnsureOrigInitialized();
    
    bool is_controller = false;
    EnterCriticalSection(&handles_lock);
    if (controller_handles.find(hFile) != controller_handles.end()) {
        is_controller = true;
    }
    LeaveCriticalSection(&handles_lock);
    
    if (is_controller) {
        WriteLog("[DLL] DetourWriteFile called for controller handle %p, size=%lu\n", hFile, nNumberOfBytesToWrite);
        if (nNumberOfBytesToWrite > 0 && lpBuffer) {
            BYTE* buf = (BYTE*)lpBuffer;
            BYTE left_motor = 0;
            BYTE right_motor = 0;
            bool has_rumble = false;
            
            if (buf[0] == 0x05 && nNumberOfBytesToWrite >= 6) {
                right_motor = buf[4];
                left_motor = buf[5];
                has_rumble = true;
            } else if (buf[0] == 0x11 && nNumberOfBytesToWrite >= 9) {
                right_motor = buf[7];
                left_motor = buf[8];
                has_rumble = true;
            }
            
            if (has_rumble) {
                WriteLog("[DLL] DetourWriteFile: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
                unsigned char packet[3];
                packet[0] = 0x01;
                packet[1] = left_motor;
                packet[2] = right_motor;
                sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
            }
        }
        
        BOOL ret = orig_WriteFile(hFile, lpBuffer, nNumberOfBytesToWrite, lpNumberOfBytesWritten, lpOverlapped);
        if (!ret) {
            DWORD err = GetLastError();
            if (err == ERROR_ACCESS_DENIED || err == ERROR_INVALID_PARAMETER || err == ERROR_INVALID_FUNCTION) {
                WriteLog("[DLL] DetourWriteFile: Original write failed (err=%lu), mocking success.\n", err);
                if (lpNumberOfBytesWritten) {
                    *lpNumberOfBytesWritten = nNumberOfBytesToWrite;
                }
                return TRUE;
            }
            WriteLog("[DLL] DetourWriteFile: Original write failed with err=%lu\n", err);
        }
        return ret;
    }
    return orig_WriteFile(hFile, lpBuffer, nNumberOfBytesToWrite, lpNumberOfBytesWritten, lpOverlapped);
}

BOOLEAN __stdcall DetourHidD_SetOutputReport(HANDLE HidDeviceObject, PVOID ReportBuffer, ULONG ReportBufferLength) {
    EnsureOrigInitialized();
    
    bool is_controller = false;
    EnterCriticalSection(&handles_lock);
    if (controller_handles.find(HidDeviceObject) != controller_handles.end()) {
        is_controller = true;
    }
    LeaveCriticalSection(&handles_lock);
    
    if (is_controller && ReportBuffer && ReportBufferLength > 0) {
        BYTE* buf = (BYTE*)ReportBuffer;
        BYTE left_motor = 0;
        BYTE right_motor = 0;
        bool has_rumble = false;
        
        if (buf[0] == 0x05 && ReportBufferLength >= 6) {
            right_motor = buf[4];
            left_motor = buf[5];
            has_rumble = true;
        } else if (buf[0] == 0x11 && ReportBufferLength >= 9) {
            right_motor = buf[7];
            left_motor = buf[8];
            has_rumble = true;
        }
        
        if (has_rumble) {
            WriteLog("[DLL] DetourHidD_SetOutputReport: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
            unsigned char packet[3];
            packet[0] = 0x01;
            packet[1] = left_motor;
            packet[2] = right_motor;
            sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
        }
        
        if (orig_HidD_SetOutputReport) {
            BOOLEAN ret = orig_HidD_SetOutputReport(HidDeviceObject, ReportBuffer, ReportBufferLength);
            if (!ret) {
                WriteLog("[DLL] DetourHidD_SetOutputReport: Original failed, mocking success.\n");
                return TRUE;
            }
            return ret;
        }
        return TRUE;
    }
    
    if (orig_HidD_SetOutputReport) {
        return orig_HidD_SetOutputReport(HidDeviceObject, ReportBuffer, ReportBufferLength);
    }
    return FALSE;
}

BOOLEAN __stdcall DetourHidD_SetFeature(HANDLE HidDeviceObject, PVOID ReportBuffer, ULONG ReportBufferLength) {
    EnsureOrigInitialized();
    
    bool is_controller = false;
    EnterCriticalSection(&handles_lock);
    if (controller_handles.find(HidDeviceObject) != controller_handles.end()) {
        is_controller = true;
    }
    LeaveCriticalSection(&handles_lock);
    
    if (is_controller && ReportBuffer && ReportBufferLength > 0) {
        BYTE* buf = (BYTE*)ReportBuffer;
        BYTE left_motor = 0;
        BYTE right_motor = 0;
        bool has_rumble = false;
        
        if (buf[0] == 0x05 && ReportBufferLength >= 6) {
            right_motor = buf[4];
            left_motor = buf[5];
            has_rumble = true;
        } else if (buf[0] == 0x11 && ReportBufferLength >= 9) {
            right_motor = buf[7];
            left_motor = buf[8];
            has_rumble = true;
        }
        
        if (has_rumble) {
            WriteLog("[DLL] DetourHidD_SetFeature: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
            unsigned char packet[3];
            packet[0] = 0x01;
            packet[1] = left_motor;
            packet[2] = right_motor;
            sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
        }
        
        if (orig_HidD_SetFeature) {
            BOOLEAN ret = orig_HidD_SetFeature(HidDeviceObject, ReportBuffer, ReportBufferLength);
            if (!ret) {
                WriteLog("[DLL] DetourHidD_SetFeature: Original failed, mocking success.\n");
                return TRUE;
            }
            return ret;
        }
        return TRUE;
    }
    
    if (orig_HidD_SetFeature) {
        return orig_HidD_SetFeature(HidDeviceObject, ReportBuffer, ReportBufferLength);
    }
    return FALSE;
}

DWORD WINAPI DetourXInputSetState(DWORD dwUserIndex, PXINPUT_VIBRATION pVibration) {
    EnsureOrigInitialized();
    
    if (pVibration) {
        BYTE left_motor = pVibration->wLeftMotorSpeed / 256;
        BYTE right_motor = pVibration->wRightMotorSpeed / 256;
        WriteLog("[DLL] DetourXInputSetState: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
        
        unsigned char packet[3];
        packet[0] = 0x01;
        packet[1] = left_motor;
        packet[2] = right_motor;
        sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
    }
    
    if (orig_XInputSetState) {
        return orig_XInputSetState(dwUserIndex, pVibration);
    }
    return 0; // Success
}

FARPROC WINAPI DetourGetProcAddress(HMODULE hModule, LPCSTR lpProcName) {
    EnsureOrigInitialized();
    
    FARPROC proc = orig_GetProcAddress(hModule, lpProcName);
    if (proc && lpProcName && (ULONG_PTR)lpProcName > 0xFFFF) {
        if (strcmp(lpProcName, "HidD_SetOutputReport") == 0) {
            orig_HidD_SetOutputReport = (HidD_SetOutputReport_t)proc;
            return (FARPROC)DetourHidD_SetOutputReport;
        }
        else if (strcmp(lpProcName, "HidD_SetFeature") == 0) {
            orig_HidD_SetFeature = (HidD_SetFeature_t)proc;
            return (FARPROC)DetourHidD_SetFeature;
        }
        else if (strcmp(lpProcName, "XInputSetState") == 0) {
            orig_XInputSetState = (XInputSetState_t)proc;
            return (FARPROC)DetourXInputSetState;
        }
        else if (strcmp(lpProcName, "CreateFileW") == 0) {
            return (FARPROC)DetourCreateFileW;
        }
        else if (strcmp(lpProcName, "WriteFile") == 0) {
            return (FARPROC)DetourWriteFile;
        }
        else if (strcmp(lpProcName, "CloseHandle") == 0) {
            return (FARPROC)DetourCloseHandle;
        }
        else if (strcmp(lpProcName, "DeviceIoControl") == 0) {
            return (FARPROC)DetourDeviceIoControl;
        }
        else if (strcmp(lpProcName, "SteamInternal_FindOrCreateUserInterface") == 0) {
            orig_SteamInternal_FindOrCreateUserInterface = (SteamInternal_FindOrCreateUserInterface_t)proc;
            return (FARPROC)DetourSteamInternal_FindOrCreateUserInterface;
        }
    }
    return proc;
}

BOOL WINAPI DetourCloseHandle(HANDLE hObject) {
    EnsureOrigInitialized();
    
    bool found = false;
    EnterCriticalSection(&handles_lock);
    if (controller_handles.find(hObject) != controller_handles.end()) {
        controller_handles.erase(hObject);
        found = true;
    }
    LeaveCriticalSection(&handles_lock);
    
    if (found) {
        WriteLog("[DLL] DetourCloseHandle: Closing controller handle %p\n", hObject);
        if ((ULONG_PTR)hObject == 0x12345678) {
            return TRUE;
        }
    }
    return orig_CloseHandle(hObject);
}

BOOL WINAPI DetourDeviceIoControl(HANDLE hDevice, DWORD dwIoControlCode, LPVOID lpInBuffer, DWORD nInBufferSize, LPVOID lpOutBuffer, DWORD nOutBufferSize, LPDWORD lpBytesReturned, LPOVERLAPPED lpOverlapped) {
    EnsureOrigInitialized();
    
    bool is_controller = false;
    EnterCriticalSection(&handles_lock);
    if (controller_handles.find(hDevice) != controller_handles.end()) {
        is_controller = true;
    }
    LeaveCriticalSection(&handles_lock);
    
    if (is_controller) {
        if (dwIoControlCode == 0xb0191 || dwIoControlCode == 0xb0195 || dwIoControlCode == 0xb0199) {
            WriteLog("[DLL] DetourDeviceIoControl: Intercepted HID write IOCTL 0x%X, size=%lu\n", dwIoControlCode, nInBufferSize);
            if (lpInBuffer && nInBufferSize > 0) {
                BYTE* buf = (BYTE*)lpInBuffer;
                BYTE left_motor = 0;
                BYTE right_motor = 0;
                bool has_rumble = false;
                
                if (buf[0] == 0x05 && nInBufferSize >= 6) {
                    right_motor = buf[4];
                    left_motor = buf[5];
                    has_rumble = true;
                } else if (buf[0] == 0x11 && nInBufferSize >= 9) {
                    right_motor = buf[7];
                    left_motor = buf[8];
                    has_rumble = true;
                }
                
                if (has_rumble) {
                    WriteLog("[DLL] DetourDeviceIoControl: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
                    unsigned char packet[3];
                    packet[0] = 0x01;
                    packet[1] = left_motor;
                    packet[2] = right_motor;
                    sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
                }
            }
        }
        
        BOOL ret = orig_DeviceIoControl(hDevice, dwIoControlCode, lpInBuffer, nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped);
        if (!ret) {
            DWORD err = GetLastError();
            if (err == ERROR_ACCESS_DENIED || err == ERROR_INVALID_PARAMETER || err == ERROR_INVALID_FUNCTION) {
                WriteLog("[DLL] DetourDeviceIoControl: Original IOCTL failed (err=%lu), mocking success.\n", err);
                if (lpBytesReturned) {
                    *lpBytesReturned = nOutBufferSize;
                }
                return TRUE;
            }
            WriteLog("[DLL] DetourDeviceIoControl: Original IOCTL failed with err=%lu\n", err);
        }
        return ret;
    }
    
    return orig_DeviceIoControl(hDevice, dwIoControlCode, lpInBuffer, nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped);
}

// IAT Hooking engine
void HookIATAll(HMODULE hModule, const char* funcName, void* newFunc, void** origFunc) {
    if (!hModule) return;
    PIMAGE_DOS_HEADER dosHeader = (PIMAGE_DOS_HEADER)hModule;
    if (dosHeader->e_magic != IMAGE_DOS_SIGNATURE) return;
    
    PIMAGE_NT_HEADERS ntHeaders = (PIMAGE_NT_HEADERS)((BYTE*)hModule + dosHeader->e_lfanew);
    if (ntHeaders->Signature != IMAGE_NT_SIGNATURE) return;
    
    PIMAGE_IMPORT_DESCRIPTOR importDesc = (PIMAGE_IMPORT_DESCRIPTOR)((BYTE*)hModule + 
        ntHeaders->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
        
    if (ntHeaders->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size == 0) return;
    
    for (; importDesc->Name; importDesc++) {
        const char* dllName = (const char*)((BYTE*)hModule + importDesc->Name);
        DWORD intOffset = importDesc->OriginalFirstThunk ? importDesc->OriginalFirstThunk : importDesc->FirstThunk;
        PIMAGE_THUNK_DATA thunkIAT = (PIMAGE_THUNK_DATA)((BYTE*)hModule + importDesc->FirstThunk);
        PIMAGE_THUNK_DATA thunkINT = (PIMAGE_THUNK_DATA)((BYTE*)hModule + intOffset);
        
        for (; thunkIAT->u1.Function; thunkIAT++, thunkINT++) {
            const char* importFuncName = NULL;
            if (IMAGE_SNAP_BY_ORDINAL(thunkINT->u1.Ordinal) == FALSE) {
                PIMAGE_IMPORT_BY_NAME importByName = (PIMAGE_IMPORT_BY_NAME)((BYTE*)hModule + thunkINT->u1.AddressOfData);
                importFuncName = (const char*)importByName->Name;
            }
            
            if (importFuncName && strcmp(importFuncName, funcName) == 0) {
                if (thunkIAT->u1.Function != (ULONGLONG)newFunc) {
                    WriteLog("[DLL] HookIATAll: Found import %s in DLL %s, redirecting...\n", funcName, dllName);
                    DWORD oldProtect;
                    VirtualProtect(&thunkIAT->u1.Function, sizeof(void*), PAGE_READWRITE, &oldProtect);
                    if (origFunc && !*origFunc) {
                        *origFunc = (void*)thunkIAT->u1.Function;
                    }
                    thunkIAT->u1.Function = (ULONGLONG)newFunc;
                    VirtualProtect(&thunkIAT->u1.Function, sizeof(void*), oldProtect, &oldProtect);
                }
            }
        }
    }
}

#include <tlhelp32.h>

void HookModule(HMODULE hMod) {
    if (!hMod) return;

    // Skip Windows/Wine system libraries for safety
    char path[MAX_PATH];
    if (GetModuleFileNameA(hMod, path, MAX_PATH)) {
        if (strstr(path, "\\windows\\") != NULL || 
            strstr(path, "\\Windows\\") != NULL ||
            strstr(path, "/windows/") != NULL ||
            strstr(path, "/Windows/") != NULL) {
            return;
        }
    }

    EnterCriticalSection(&hooking_lock);
    if (hooked_modules.find(hMod) != hooked_modules.end()) {
        LeaveCriticalSection(&hooking_lock);
        return;
    }
    hooked_modules.insert(hMod);
    LeaveCriticalSection(&hooking_lock);

    HookIATAll(hMod, "CreateFileW", (void*)DetourCreateFileW, NULL);
    HookIATAll(hMod, "WriteFile", (void*)DetourWriteFile, NULL);
    HookIATAll(hMod, "CloseHandle", (void*)DetourCloseHandle, NULL);
    HookIATAll(hMod, "GetProcAddress", (void*)DetourGetProcAddress, NULL);
    HookIATAll(hMod, "LoadLibraryA", (void*)DetourLoadLibraryA, NULL);
    HookIATAll(hMod, "LoadLibraryW", (void*)DetourLoadLibraryW, NULL);
    HookIATAll(hMod, "LoadLibraryExA", (void*)DetourLoadLibraryExA, NULL);
    HookIATAll(hMod, "LoadLibraryExW", (void*)DetourLoadLibraryExW, NULL);
    HookIATAll(hMod, "DeviceIoControl", (void*)DetourDeviceIoControl, NULL);
    HookIATAll(hMod, "HidD_SetOutputReport", (void*)DetourHidD_SetOutputReport, NULL);
    HookIATAll(hMod, "HidD_SetFeature", (void*)DetourHidD_SetFeature, NULL);
    HookIATAll(hMod, "XInputSetState", (void*)DetourXInputSetState, NULL);
    HookIATAll(hMod, "SteamInternal_FindOrCreateUserInterface", (void*)DetourSteamInternal_FindOrCreateUserInterface, (void**)&orig_SteamInternal_FindOrCreateUserInterface);
}

void __cdecl Hooked_TriggerVibration(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    BYTE left_motor = usLeftSpeed / 256;
    BYTE right_motor = usRightSpeed / 256;
    WriteLog("[DLL] Hooked_TriggerVibration: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
    
    unsigned char packet[3];
    packet[0] = 0x01;
    packet[1] = left_motor;
    packet[2] = right_motor;
    sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
    
    if (real_TriggerVibration) {
        real_TriggerVibration(self, inputHandle, usLeftSpeed, usRightSpeed);
    }
}

void __cdecl Hooked_TriggerVibrationExtended(void* self, uint64_t inputHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed, unsigned short usLeftTriggerSpeed, unsigned short usRightTriggerSpeed) {
    EnsureOrigInitialized();
    BYTE left_motor = usLeftSpeed / 256;
    BYTE right_motor = usRightSpeed / 256;
    WriteLog("[DLL] Hooked_TriggerVibrationExtended: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
    
    unsigned char packet[3];
    packet[0] = 0x01;
    packet[1] = left_motor;
    packet[2] = right_motor;
    sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
    
    if (real_TriggerVibrationExtended) {
        real_TriggerVibrationExtended(self, inputHandle, usLeftSpeed, usRightSpeed, usLeftTriggerSpeed, usRightTriggerSpeed);
    }
}

void __cdecl Hooked_ControllerTriggerVibration(void* self, uint64_t controllerHandle, unsigned short usLeftSpeed, unsigned short usRightSpeed) {
    EnsureOrigInitialized();
    BYTE left_motor = usLeftSpeed / 256;
    BYTE right_motor = usRightSpeed / 256;
    WriteLog("[DLL] Hooked_ControllerTriggerVibration: Sending rumble left=%d, right=%d\n", left_motor, right_motor);
    
    unsigned char packet[3];
    packet[0] = 0x01;
    packet[1] = left_motor;
    packet[2] = right_motor;
    sendto(udp_socket, (const char*)packet, 3, 0, (sockaddr*)&server_addr, sizeof(server_addr));
    
    if (real_ControllerTriggerVibration) {
        real_ControllerTriggerVibration(self, controllerHandle, usLeftSpeed, usRightSpeed);
    }
}

void* __cdecl DetourSteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* pszInterfaceVersion) {
    EnsureOrigInitialized();
    void* pInterface = NULL;
    if (orig_SteamInternal_FindOrCreateUserInterface) {
        pInterface = orig_SteamInternal_FindOrCreateUserInterface(hSteamUser, pszInterfaceVersion);
    }
    
    if (pszInterfaceVersion) {
        WriteLog("[DLL] SteamInternal_FindOrCreateUserInterface requested: %s -> %p\n", pszInterfaceVersion, pInterface);
    }
    
    if (pInterface && pszInterfaceVersion) {
        if (strstr(pszInterfaceVersion, "STEAMINPUT_INTERFACE_VERSION") != NULL) {
            void** vtable = *(void***)pInterface;
            if (vtable && vtable[29] != (void*)Hooked_TriggerVibration) {
                original_vtable = vtable;
                real_TriggerVibration = (SteamInputTriggerVibration_t)vtable[29];
                real_TriggerVibrationExtended = (SteamInputTriggerVibrationExtended_t)vtable[30];
                
                DWORD oldProtect;
                VirtualProtect(&vtable[29], 2 * sizeof(void*), PAGE_READWRITE, &oldProtect);
                vtable[29] = (void*)Hooked_TriggerVibration;
                vtable[30] = (void*)Hooked_TriggerVibrationExtended;
                VirtualProtect(&vtable[29], 2 * sizeof(void*), oldProtect, &oldProtect);
                
                WriteLog("[DLL] SteamInternal_FindOrCreateUserInterface: Successfully patched original ISteamInput vtable in-place for version %s!\n", pszInterfaceVersion);
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
                
                WriteLog("[DLL] SteamInternal_FindOrCreateUserInterface: Successfully patched original ISteamController vtable in-place for version %s!\n", pszInterfaceVersion);
            }
        }
    }
    return pInterface;
}

void PerformHooking() {
    EnsureOrigInitialized();

    static bool initial_hook_done = false;
    if (initial_hook_done) return;

    EnterCriticalSection(&hooking_lock);
    if (initial_hook_done) {
        LeaveCriticalSection(&hooking_lock);
        return;
    }
    initial_hook_done = true;
    LeaveCriticalSection(&hooking_lock);

    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (hSnapshot != INVALID_HANDLE_VALUE) {
        MODULEENTRY32 me;
        me.dwSize = sizeof(me);
        if (Module32First(hSnapshot, &me)) {
            do {
                HookModule(me.hModule);
            } while (Module32Next(hSnapshot, &me));
        }
        CloseHandle(hSnapshot);
    }
}

extern "C" __declspec(dllexport) HRESULT WINAPI DirectInput8Create(HINSTANCE hinst, DWORD dwVersion, REFIID riidltf, LPVOID *ppvOut, LPUNKNOWN punkOuter) {
    WriteLog("[DLL] DirectInput8Create called\n");
    LoadOriginalDll();
    PerformHooking();
    if (orig_DirectInput8Create) {
        return orig_DirectInput8Create(hinst, dwVersion, riidltf, ppvOut, punkOuter);
    }
    return E_FAIL;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllCanUnloadNow() {
    LoadOriginalDll();
    PerformHooking();
    typedef HRESULT (WINAPI *DllCanUnloadNow_t)();
    DllCanUnloadNow_t orig = (DllCanUnloadNow_t)GetProcAddress(hOrigDll, "DllCanUnloadNow");
    return orig ? orig() : S_OK;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID *ppv) {
    LoadOriginalDll();
    PerformHooking();
    typedef HRESULT (WINAPI *DllGetClassObject_t)(REFCLSID, REFIID, LPVOID *);
    DllGetClassObject_t orig = (DllGetClassObject_t)GetProcAddress(hOrigDll, "DllGetClassObject");
    return orig ? orig(rclsid, riid, ppv) : E_FAIL;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllRegisterServer() {
    LoadOriginalDll();
    PerformHooking();
    typedef HRESULT (WINAPI *DllRegisterServer_t)();
    DllRegisterServer_t orig = (DllRegisterServer_t)GetProcAddress(hOrigDll, "DllRegisterServer");
    return orig ? orig() : E_FAIL;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllUnregisterServer() {
    LoadOriginalDll();
    PerformHooking();
    typedef HRESULT (WINAPI *DllUnregisterServer_t)();
    DllUnregisterServer_t orig = (DllUnregisterServer_t)GetProcAddress(hOrigDll, "DllUnregisterServer");
    return orig ? orig() : E_FAIL;
}

extern "C" BOOL WINAPI DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    switch (ul_reason_for_call) {
        case DLL_PROCESS_ATTACH:
            InitializeCriticalSection(&handles_lock);
            InitializeCriticalSection(&hooking_lock);
            SafeInitialize();
            PerformHooking();
            break;
        case DLL_PROCESS_DETACH:
            DeleteCriticalSection(&handles_lock);
            DeleteCriticalSection(&hooking_lock);
            if (udp_socket != INVALID_SOCKET) {
                closesocket(udp_socket);
            }
            WSACleanup();
            break;
    }
    return TRUE;
}
