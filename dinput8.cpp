#include <windows.h>

// Function pointer types for dinput8 exports
typedef HRESULT (WINAPI *DirectInput8Create_t)(HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);
typedef HRESULT (WINAPI *DllCanUnloadNow_t)();
typedef HRESULT (WINAPI *DllGetClassObject_t)(REFCLSID, REFIID, LPVOID *);
typedef HRESULT (WINAPI *DllRegisterServer_t)();
typedef HRESULT (WINAPI *DllUnregisterServer_t)();

static HMODULE hOrigDll = NULL;
static DirectInput8Create_t orig_DirectInput8Create = NULL;
static DllCanUnloadNow_t orig_DllCanUnloadNow = NULL;
static DllGetClassObject_t orig_DllGetClassObject = NULL;
static DllRegisterServer_t orig_DllRegisterServer = NULL;
static DllUnregisterServer_t orig_DllUnregisterServer = NULL;

static void LoadOriginalDll() {
    if (!hOrigDll) {
        char path[MAX_PATH];
        GetSystemDirectoryA(path, MAX_PATH);
        strcat(path, "\\dinput8.dll");
        hOrigDll = LoadLibraryA(path);
        if (hOrigDll) {
            orig_DirectInput8Create = (DirectInput8Create_t)GetProcAddress(hOrigDll, "DirectInput8Create");
            orig_DllCanUnloadNow = (DllCanUnloadNow_t)GetProcAddress(hOrigDll, "DllCanUnloadNow");
            orig_DllGetClassObject = (DllGetClassObject_t)GetProcAddress(hOrigDll, "DllGetClassObject");
            orig_DllRegisterServer = (DllRegisterServer_t)GetProcAddress(hOrigDll, "DllRegisterServer");
            orig_DllUnregisterServer = (DllUnregisterServer_t)GetProcAddress(hOrigDll, "DllUnregisterServer");
        }
    }
}

extern "C" __declspec(dllexport) HRESULT WINAPI DirectInput8Create(HINSTANCE hinst, DWORD dwVersion, REFIID riidltf, LPVOID *ppvOut, LPUNKNOWN punkOuter) {
    LoadOriginalDll();
    if (orig_DirectInput8Create) {
        return orig_DirectInput8Create(hinst, dwVersion, riidltf, ppvOut, punkOuter);
    }
    return E_FAIL;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllCanUnloadNow() {
    LoadOriginalDll();
    if (orig_DllCanUnloadNow) {
        return orig_DllCanUnloadNow();
    }
    return S_OK;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID *ppv) {
    LoadOriginalDll();
    if (orig_DllGetClassObject) {
        return orig_DllGetClassObject(rclsid, riid, ppv);
    }
    return E_FAIL;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllRegisterServer() {
    LoadOriginalDll();
    if (orig_DllRegisterServer) {
        return orig_DllRegisterServer();
    }
    return E_FAIL;
}

extern "C" __declspec(dllexport) HRESULT WINAPI DllUnregisterServer() {
    LoadOriginalDll();
    if (orig_DllUnregisterServer) {
        return orig_DllUnregisterServer();
    }
    return E_FAIL;
}

extern "C" BOOL WINAPI DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    return TRUE;
}
