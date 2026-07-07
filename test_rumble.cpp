#include <windows.h>
#include <stdio.h>
#include <initguid.h>
#include <dinput.h>

typedef HRESULT (WINAPI *DirectInput8Create_t)(HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);

int main() {
    printf("Loading local dinput8.dll...\n");
    HMODULE hDll = LoadLibraryA("dinput8.dll");
    if (!hDll) {
        printf("Error: Failed to load dinput8.dll! Error code: %lu\n", GetLastError());
        return 1;
    }
    
    char path[MAX_PATH] = {0};
    GetModuleFileNameA(hDll, path, MAX_PATH);
    printf("Success: Loaded dinput8.dll from: %s (Handle: %p)\n", path, (void*)hDll);
    
    printf("Resolving DirectInput8Create export...\n");
    DirectInput8Create_t pDirectInput8Create = (DirectInput8Create_t)GetProcAddress(hDll, "DirectInput8Create");
    if (!pDirectInput8Create) {
        printf("Error: Failed to resolve DirectInput8Create!\n");
        FreeLibrary(hDll);
        return 1;
    }
    printf("Resolved DirectInput8Create address: %p\n", (void*)pDirectInput8Create);
    
    printf("Calling DirectInput8Create to trigger hooking engine...\n");
    LPVOID pDInput = NULL;
    HRESULT hr = pDirectInput8Create(GetModuleHandle(NULL), DIRECTINPUT_VERSION, IID_IDirectInput8W, &pDInput, NULL);
    printf("DirectInput8Create returned: 0x%08lX\n", hr);
    
    printf("Simulating opening controller handle...\n");
    HANDLE hFile = CreateFileW(L"\\\\?\\hid#vid_054c&pid_09cc#fake_controller_handle", 
                               GENERIC_WRITE, FILE_SHARE_WRITE, NULL, 
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
                               
    if (hFile == INVALID_HANDLE_VALUE) {
        printf("Error: CreateFileW failed! Error code: %lu\n", GetLastError());
        if (pDInput) {
            ((IUnknown*)pDInput)->Release();
        }
        FreeLibrary(hDll);
        return 1;
    }
    printf("Success: Controller handle opened: %p\n", hFile);
    
    BYTE report[64] = {0};
    report[0] = 0x05; 
    report[1] = 0xFF; 
    report[4] = 0x00; 
    report[5] = 0xFF; 
    
    printf("Sending vibration command to left motor (maximum intensity)...\n");
    DWORD written = 0;
    BOOL res = WriteFile(hFile, report, sizeof(report), &written, NULL);
    if (res) {
        printf("Success: WriteFile returned TRUE, bytes written: %lu\n", written);
    } else {
        printf("Error: WriteFile failed! Error code: %lu\n", GetLastError());
    }
    
    printf("Vibrating for 1.5 seconds...\n");
    Sleep(1500);
    
    printf("Stopping vibration...\n");
    report[5] = 0x00; 
    res = WriteFile(hFile, report, sizeof(report), &written, NULL);
    if (res) {
        printf("Success: WriteFile (stop) returned TRUE\n");
    } else {
        printf("Error: WriteFile (stop) failed!\n");
    }
    
    Sleep(500);
    
    printf("Closing controller handle...\n");
    CloseHandle(hFile);
    
    if (pDInput) {
        ((IUnknown*)pDInput)->Release();
    }
    FreeLibrary(hDll);
    printf("Vibration test complete!\n");
    return 0;
}
